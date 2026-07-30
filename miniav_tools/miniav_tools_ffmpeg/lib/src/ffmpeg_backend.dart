/// FFmpeg [MiniAVToolsBackend] implementation.
///
/// Phase A (current): software libx264 / libopenh264 / etc. via libavcodec.
/// Phase B (planned): NVENC / QSV / AMF hardware encoders with D3D11VA
///                    zero-copy from miniav GPU buffers.
/// Phase C (planned): MP4 / MKV muxer and demuxer via libavformat.
library;

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_audio_decoder.dart';
import 'ffmpeg_audio_encoder.dart';
import 'ffmpeg_bindings.dart' as ffi;
import 'ffmpeg_d3d11_hw_encoder.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_demuxer.dart';
import 'ffmpeg_encoder.dart';
import 'isolate_decoder.dart';
import 'isolate_demuxer.dart';
import 'isolate_software_encoder.dart';
import 'ffmpeg_hw_encoder.dart';
import 'ffmpeg_log.dart';
import 'ffmpeg_muxer.dart';

class FfmpegBackend extends MiniAVToolsBackend {
  static const String backendName = 'ffmpeg';

  /// FFmpeg generally has the broadest codec coverage, so it bids high by
  /// default. Users can lower this via
  /// [MiniAVToolsPlatform.setBackendPriority] if a more specialised backend
  /// (e.g. minigpu MJPEG, WebCodecs) should win.
  static const int defaultPriority = 50;

  @override
  String get name => backendName;

  @override
  int get priority => _priority;
  int _priority = defaultPriority;

  /// Mutable priority (used by tests + the registry).
  // ignore: use_setters_to_change_properties
  void setPriority(int p) => _priority = p;

  /// Lazily probe FFmpeg availability the first time we're asked.
  bool? _available;
  bool get _isAvailable => _available ??= ffi.tryLoadFFmpeg();

  /// Async ensure: triggers an auto-download if libs are not already
  /// resolvable. Throws [CodecInitException] when libs cannot be obtained.
  Future<void> _ensureAvailable() async {
    if (_isAvailable) return;
    final ok = await ffi.ensureFFmpegLoaded();
    _available = ok;
    if (!ok) {
      throw const CodecInitException(
        backendName,
        'FFmpeg shared libraries not found and auto-download did not '
        'succeed. Install FFmpeg, set FFMPEG_LIB_DIR, or check your '
        'network connection. Set MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1 '
        'to silence this attempt.',
      );
    }
  }

  // --- Warmup ---------------------------------------------------------------

  static const _kTaskFfmpegDownload = 'Downloading FFmpeg';

  @override
  Stream<WarmupProgress> warmup() {
    if (_isAvailable) return const Stream.empty();

    final ctrl = StreamController<WarmupProgress>();

    ffi
        .ensureFFmpegLoaded(
          onDownloadProgress: (int received, int total) {
            ctrl.add(
              WarmupProgress(
                backendName: name,
                task: _kTaskFfmpegDownload,
                isDone: false,
                bytesReceived: received,
                // Some HTTP responses omit Content-Length (-1 sentinel).
                totalBytes: total < 0 ? null : total,
              ),
            );
          },
        )
        .then(
          (ok) {
            _available = ok;
            ctrl.add(
              WarmupProgress(
                backendName: name,
                task: _kTaskFfmpegDownload,
                isDone: true,
                error: ok ? null : 'FFmpeg auto-download failed or is disabled',
              ),
            );
          },
          onError: (Object e) {
            ctrl.add(
              WarmupProgress(
                backendName: name,
                task: _kTaskFfmpegDownload,
                isDone: true,
                error: e,
              ),
            );
          },
        )
        .whenComplete(ctrl.close);

    return ctrl.stream;
  }

  // --- Capabilities ---------------------------------------------------------

  static const _swEncode = <VideoCodec>{
    VideoCodec.h264, // libx264
    VideoCodec.hevc, // libx265
    VideoCodec.vp9,
    VideoCodec.vp8,
    VideoCodec.av1, // libaom-av1 / libsvtav1
    VideoCodec.mjpeg,
    VideoCodec.prores,
  };

  static const _hwEncode = <VideoCodec>{
    VideoCodec.h264, // h264_nvenc, h264_qsv, h264_amf, h264_videotoolbox
    VideoCodec.hevc,
    VideoCodec.av1, // av1_nvenc on Ada+, av1_qsv on Arc+
  };

  /// Video codecs the FFmpeg software decoder actually maps
  /// (`_videoCodecToAvId` in ffmpeg_decoder.dart). Kept in lock-step with that
  /// switch so the negotiator never selects FFmpeg for a codec it will then
  /// throw on at open. ProRes is deliberately absent: its decoder isn't wired
  /// and its 4:2:2/10-bit output needs the pixel-format work (a later phase);
  /// advertising it caused a negotiate-then-CodecInitException crash.
  static const _swDecode = <VideoCodec>{
    VideoCodec.h264,
    VideoCodec.hevc,
    VideoCodec.mjpeg,
    VideoCodec.vp8,
    VideoCodec.vp9,
    VideoCodec.av1,
  };

  /// Capabilities are advertised optimistically: the FFmpeg backend can
  /// always satisfy these requests *given network access*. The actual lib
  /// load happens lazily inside `create*` via [_ensureAvailable].
  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) =>
      hwAccel ? _hwEncode.contains(codec) : _swEncode.contains(codec);

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) =>
      _swDecode.contains(codec);

  @override
  bool supportsAudioEncode(AudioCodec codec) =>
      codec == AudioCodec.aac || codec == AudioCodec.opus;

  @override
  bool supportsAudioDecode(AudioCodec codec) => true;

  @override
  bool supportsMux(Container container) => true;

  @override
  bool supportsDemux(Container container) => true;

  /// Frame sources we can consume directly. CPU and miniav-buffer-CPU work
  /// everywhere; the GPU-handle sources gate on platform because the
  /// underlying FFmpeg hwcontext is only meaningful on its native OS.
  ///
  /// - **Windows**: D3D11 NT-handle (Stage B zero-copy via NVENC/AMF/QSV/MF).
  /// - **macOS / iOS**: CVPixelBuffer (VideoToolbox zero-copy with IOSurface
  ///   passed through `data[3]` as `AV_PIX_FMT_VIDEOTOOLBOX`).
  /// - **Linux**: dmabuf FD (VAAPI / V4L2 M2M zero-copy).
  /// - **Android**: AHardwareBuffer (MediaCodec via `*_mediacodec` codecs).
  ///
  /// All zero-copy paths fall back to a CPU upload if the requested codec
  /// has no matching HW encoder in the loaded FFmpeg build.
  @override
  Set<FrameSourceKind> get acceptedFrameSources {
    final base = <FrameSourceKind>{
      FrameSourceKind.cpu,
      FrameSourceKind.miniavBufferCpu,
    };
    if (Platform.isWindows) {
      base.addAll(const {
        FrameSourceKind.miniavBufferD3D11,
        FrameSourceKind.d3d11Texture,
      });
    } else if (Platform.isMacOS || Platform.isIOS) {
      base.addAll(const {
        FrameSourceKind.miniavBufferMetal,
        FrameSourceKind.cvPixelBuffer,
      });
    } else if (Platform.isLinux) {
      base.addAll(const {
        FrameSourceKind.miniavBufferDmabuf,
        FrameSourceKind.dmabuf,
      });
    } else if (Platform.isAndroid) {
      base.add(FrameSourceKind.miniavBufferAHardwareBuffer);
    }
    return base;
  }

  // --- Factories ------------------------------------------------------------

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async {
    if (!_swEncode.contains(config.codec) &&
        !_hwEncode.contains(config.codec)) {
      return null;
    }
    await _ensureAvailable();

    // Resolve the request to something this FFmpeg build can actually encode.
    // The LGPL build has no software HEVC and H.264 tops out at 4096px, so
    // HEVC-without-hardware and >4096px H.264 both fall back to a downscaled
    // H.264 stream. Must run AFTER _ensureAvailable() so HW probing is valid.
    // Both the HW and software encoders rescale oversized capture frames to
    // their configured size, so callers can keep feeding full-resolution
    // frames after this substitution.
    final resolved = _resolveEncodableConfig(config);
    if (resolved.codec != config.codec ||
        resolved.width != config.width ||
        resolved.height != config.height) {
      ffmpegToolsLog(
        MiniAVLogLevel.info,
        '[ffmpeg] createEncoder: ${config.codec} '
        '${config.width}x${config.height} is not directly encodable in this '
        '(LGPL) build — falling back to ${resolved.codec} '
        '${resolved.width}x${resolved.height} (downscale + H.264).',
      );
    }
    config = resolved;

    // Stage A hardware path: try every supported vendor (NVENC > QSV > AMF
    // > VideoToolbox > MediaFoundation > V4L2) for h264 / hevc / av1 when
    // the user asked for hwAccel and an encoder is available in this
    // FFmpeg build. Falls back to software if hwAccel is `preferred`
    // (best-effort) and nothing matches. `required` propagates the failure.
    final wantHw =
        config.hwAccel == HwAccelPreference.preferred ||
        config.hwAccel == HwAccelPreference.required;
    if (wantHw && _hwEncode.contains(config.codec)) {
      // Stage B opt-in: caller asked for zero-copy via either:
      //   (a) `backendOptions['zerocopy'] == '1'` (legacy direct callers), or
      //   (b) a [BackendContext] with `preferZeroCopy: true` AND a non-zero
      //       `d3d11DeviceHandle` (the recorder uses this path).
      // When (b) is taken we hand the existing D3D11 device into the
      // encoder so its output texture lives on the same device as the
      // caller's GPU pipeline (Dawn) — that's what makes the path actually
      // zero-copy end-to-end (no `OpenSharedResource1` round-trip).
      final zerocopyOpt = config.backendOptions['zerocopy'] == '1';
      final ctxZeroCopy =
          context != null &&
          context.preferZeroCopy &&
          context.d3d11DeviceHandle != 0 &&
          Platform.isWindows;
      if (zerocopyOpt || ctxZeroCopy) {
        if (!ffmpegD3d11EncoderAvailable(config.codec)) {
          if (zerocopyOpt) {
            throw CodecInitException(
              backendName,
              'zerocopy=1 requested but no D3D11VA encoder is available for '
              '${config.codec} (need NVENC/AMF/QSV/MF in this FFmpeg build, '
              'plus the miniav_tools_ffmpeg shim).',
            );
          }
          // Context-driven zero-copy is best-effort — just fall through.
          ffmpegToolsLog(
            MiniAVLogLevel.warn,
            '[ffmpeg] createEncoder: D3D11 zero-copy skipped — no D3D11VA '
            'encoder available for ${config.codec} in this FFmpeg build.',
          );
        } else {
          try {
            final enc = FfmpegD3d11HwEncoder.open(
              config,
              existingD3d11Device: ctxZeroCopy ? context.d3d11DeviceHandle : 0,
              // Both the ctxZeroCopy path (Minigpu SharedOutputTexture) and the
              // legacy zerocopy=1 path (raw DXGI capture) deliver
              // DXGI_FORMAT_B8G8R8A8_UNORM textures.  SharedOutputTexture is
              // created with DXGI_FORMAT_B8G8R8A8_UNORM in minigpu_external.cpp;
              // the buffer→texture WGSL writes to bgra8unorm storage.
              // Default sourceTextureFormat (bgra) is correct for both paths.
            );
            ffmpegToolsLog(
              MiniAVLogLevel.info,
              '[ffmpeg] createEncoder: D3D11 zero-copy encoder opened '
              '(${enc.runtimeType}) for ${config.codec} '
              '${config.width}x${config.height}'
              '${ctxZeroCopy ? " [injected device 0x${context.d3d11DeviceHandle.toRadixString(16)}]" : " [new device]"}',
            );
            return enc;
          } on CodecInitException catch (e) {
            // Strict opt-in (a) — propagate. Context opt-in (b) — fall back.
            if (zerocopyOpt) rethrow;
            ffmpegToolsLog(
              MiniAVLogLevel.warn,
              '[ffmpeg] createEncoder: D3D11 zero-copy failed ($e) — '
              'falling back to Stage A NVENC/software.',
            );
          }
        }
      }
      // The CPU-fed Stage A hardware attempt now happens on the worker isolate
      // below — it needs the MTA apartment (QSV / MediaFoundation), which the
      // STA UI isolate cannot provide, and it must not block the UI thread.
      // Fall through.
    }

    // Isolate-hosted encoder. On a dedicated worker isolate it opens either a
    // CPU-fed hardware encoder (when hardware was requested) or the software
    // encoder — whichever succeeds. Two reasons this must be off the calling
    // isolate:
    //   1. The synchronous libav encode is tens of ms/frame at 720p+, which
    //      reads as an app freeze while recording.
    //   2. QSV / MediaFoundation encoder init requires the COM MTA apartment;
    //      Flutter's UI isolate is STA (`miniav_shim_ensure_mta` →
    //      RPC_E_CHANGED_MODE), so those vendors can ONLY init on the worker's
    //      fresh OS thread. This is what lets CPU-fed HW encode work at all in
    //      a Flutter app.
    // Frames cross as TransferableTypedData (~1 ms at 720p).
    //
    // Escape hatch: backendOptions {'sw_isolate': '0'} keeps the legacy
    // in-isolate path (used by tests that poke encoder internals directly).
    if (config.backendOptions['sw_isolate'] != '0') {
      final hwAvail = wantHw && ffmpegHwEncoderAvailable(config.codec);
      if (wantHw &&
          !hwAvail &&
          config.hwAccel == HwAccelPreference.required) {
        throw CodecInitException(
          backendName,
          'No hardware encoder for ${config.codec} present in the loaded '
          'FFmpeg build (hwAccel=required). Vendors checked: NVENC, QSV, '
          'AMF, VideoToolbox, MediaFoundation, V4L2.',
        );
      }
      // Adapter-aware CPU-fed vendor order (e.g. MF before AMF on AMD), or
      // null for a software-only worker.
      final order = hwAvail
          ? hwVendorOrderForDevice(context?.d3d11DeviceHandle ?? 0)
          : null;
      final enc = await IsolateSoftwareEncoder.open(
        config,
        hwVendorOrder: order,
        requireHardware:
            order != null && config.hwAccel == HwAccelPreference.required,
      );
      ffmpegToolsLog(
        MiniAVLogLevel.info,
        '[ffmpeg] createEncoder: isolate encoder '
        '[${enc.activeEncoderDescription}] for ${config.codec} '
        '${config.width}x${config.height}',
      );
      return enc;
    }

    // sw_isolate == '0': legacy in-isolate path (tests). Try the CPU-fed HW
    // encoder on the calling isolate, then in-isolate software.
    if (wantHw && ffmpegHwEncoderAvailable(config.codec)) {
      try {
        final enc = FfmpegHwEncoder.open(config, gpu: context?.sharedGpu);
        ffmpegToolsLog(
          MiniAVLogLevel.info,
          '[ffmpeg] createEncoder: Stage A HW encoder opened '
          '(${enc.runtimeType}) for ${config.codec} '
          '${config.width}x${config.height}',
        );
        return enc;
      } on CodecInitException catch (e) {
        if (config.hwAccel == HwAccelPreference.required) rethrow;
        ffmpegToolsLog(
          MiniAVLogLevel.warn,
          '[ffmpeg] createEncoder: Stage A HW encoder failed ($e) — '
          'falling back to software.',
        );
      }
    } else if (wantHw && config.hwAccel == HwAccelPreference.required) {
      throw CodecInitException(
        backendName,
        'No hardware encoder for ${config.codec} present in the loaded '
        'FFmpeg build (hwAccel=required). Vendors checked: NVENC, QSV, '
        'AMF, VideoToolbox, MediaFoundation, V4L2.',
      );
    }
    final enc = FfmpegSoftwareEncoder.open(config);
    ffmpegToolsLog(
      MiniAVLogLevel.info,
      '[ffmpeg] createEncoder: software encoder opened '
      '(${enc.runtimeType}) for ${config.codec} '
      '${config.width}x${config.height}',
    );
    return enc;
  }

  /// Hardware H.264 encoders (NVENC/QSV/AMF/MF/VT) and the LGPL build's
  /// software H.264 (libopenh264) all top out at 4096px per side. HEVC/AV1 go
  /// higher (8192px), which is why captures above this promote to HEVC when a
  /// HW HEVC encoder exists.
  static const int kH264MaxDimension = 4096;

  /// Resolve a requested encoder [config] to one the loaded FFmpeg build can
  /// actually produce, applying the "downscale + H.264" fallback:
  ///
  ///  * **HEVC with no hardware HEVC encoder** — the LGPL build has no software
  ///    HEVC (no libx265; the Windows HEVC software MFT returns E_FAIL), so
  ///    substitute H.264, which every HW vendor plus the MediaFoundation
  ///    software MFT and libopenh264 can produce.
  ///  * **H.264 above 4096px** (requested directly, or substituted above) —
  ///    downscale, preserving aspect ratio with even dimensions, to fit within
  ///    [kH264MaxDimension] on the longer side.
  ///
  /// AV1 is left untouched: SVT-AV1 software handles arbitrary resolution, so
  /// an explicit AV1 request keeps full resolution even with no HW AV1.
  ///
  /// The encoder built from the returned config rescales oversized capture
  /// frames to its configured size, so callers keep feeding full-size frames.
  ///
  /// Requires FFmpeg to be loaded (HW probing); call after [_ensureAvailable].
  static EncoderConfig _resolveEncodableConfig(EncoderConfig config) {
    var codec = config.codec;

    // No software HEVC in the LGPL build → fall back to H.264 when no hardware
    // HEVC encoder is present.
    if (codec == VideoCodec.hevc &&
        !ffmpegHwEncoderAvailable(VideoCodec.hevc)) {
      codec = VideoCodec.h264;
    }

    var width = config.width;
    var height = config.height;
    if (codec == VideoCodec.h264 &&
        (width > kH264MaxDimension || height > kH264MaxDimension)) {
      final longer = width > height ? width : height;
      final scale = kH264MaxDimension / longer;
      width = (width * scale).floor();
      height = (height * scale).floor();
      // 4:2:0 encoders require even dimensions.
      if (width.isOdd) width -= 1;
      if (height.isOdd) height -= 1;
    }

    if (codec == config.codec &&
        width == config.width &&
        height == config.height) {
      return config;
    }
    return config.copyWith(codec: codec, width: width, height: height);
  }

  /// Test hook for [_resolveEncodableConfig].
  @visibleForTesting
  static EncoderConfig resolveEncodableConfigForTest(EncoderConfig config) =>
      _resolveEncodableConfig(config);

  /// Pick the best [VideoCodec] for the given resolution + HW preference.
  ///
  /// On HW paths, H.264 is capped at 4096px wide on every shipping vendor
  /// (NVENC, QSV, AMF, VT). For ultrawide / 4K+ captures we transparently
  /// promote to HEVC, which all of those vendors support up to 8192px.
  /// Caller can pass [preferred] to express intent (e.g. user explicitly
  /// asked for AV1).
  static VideoCodec bestCodecForResolution({
    required int width,
    required int height,
    required bool hwAccel,
    VideoCodec preferred = VideoCodec.h264,
  }) {
    if (!hwAccel) return preferred;
    if (preferred == VideoCodec.h264 && (width > 4096 || height > 4096)) {
      return VideoCodec.hevc;
    }
    return preferred;
  }

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async {
    await _ensureAvailable();
    // Isolate-hosted by default — the synchronous libav decode is tens of
    // ms/frame at 1080p+, which would freeze a Flutter UI isolate. Escape
    // hatch mirrors createEncoder: backendOptions {'sw_isolate': '0'} keeps
    // the legacy in-isolate path (tests that poke decoder internals).
    if (config.backendOptions['sw_isolate'] != '0') {
      return IsolateVideoDecoder.open(config);
    }
    return FfmpegSoftwareDecoder.open(config);
  }

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) async {
    if (!supportsAudioDecode(config.codec)) return null;
    await _ensureAvailable();
    if (config.backendOptions['sw_isolate'] != '0') {
      return IsolateAudioDecoder.open(config);
    }
    return FfmpegAudioDecoder.open(config);
  }

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async {
    await _ensureAvailable();
    return FfmpegMuxer.open(config);
  }

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async {
    await _ensureAvailable();
    // Isolate-hosted by default: av_read_frame is synchronous FFI, and on
    // live byte-pipe inputs it BLOCKS until the transport delivers — it must
    // never run on a UI isolate. Escape hatch mirrors the codecs:
    // backendOptions {'sw_isolate': '0'} for tests (file/bytes only — the
    // reader can never starve on those).
    if (config.backendOptions['sw_isolate'] == '0') {
      return switch (config.input) {
        FileDemuxerInput f => FfmpegDemuxer.openUrl(f.path),
        BytesDemuxerInput b => FfmpegDemuxer.openBytes(b.bytes),
        StreamDemuxerInput _ => throw const CodecInitException(
          backendName,
          'byteStream input requires the isolate-hosted demuxer '
              "(remove backendOptions {'sw_isolate': '0'})",
        ),
      };
    }
    return IsolateDemuxer.open(config);
  }

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) async {
    if (!supportsAudioEncode(config.codec)) return null;
    await _ensureAvailable();
    return FfmpegAudioEncoder.open(config);
  }
}
