/// FFmpeg hardware encoder paths (Stage A: NVENC with RGB0 software input).
///
/// NVENC accepts a number of pixel formats directly, including `RGB0` /
/// `BGR0` (32-bpp packed RGB with a padding byte). This encoder accepts a
/// CPU `RGBA` byte buffer (typically produced by minigpu's
/// `VideoTexture.toRGBA().read()`) and feeds it to `h264_nvenc` /
/// `hevc_nvenc` / `av1_nvenc` as `RGB0`. NVENC does the colour-space
/// conversion + entropy coding entirely on the GPU.
///
/// This is **not** zero-copy: the RGBA bytes are uploaded from system
/// memory to the encoder's CUDA context per frame. It avoids the two big
/// CPU costs (RGBA→YUV420P conversion in software + libx264 entropy
/// coding) and is typically 5–10× faster than `libx264 ultrafast` at high
/// resolutions.
///
/// Stage B (planned) will switch to `AV_PIX_FMT_D3D11` with an
/// `AVHWFramesContext`, taking the `SharedOutputTexture` directly without
/// any system-memory round-trip.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_encoder.dart' show address;
import 'ffmpeg_ffi.dart';
import 'ffmpeg_muxer.dart' show FfmpegEncoderBridge;
import 'pixel_convert.dart' show toBgra32;

/// AVPixelFormat.rgb0 in libavutil 60 (FFmpeg 8.x). 32-bpp packed:
/// R, G, B, X (alpha byte ignored). Byte-identical to `AV_PIX_FMT_RGBA`
/// on the wire — the only difference is that NVENC accepts RGB0 in its
/// input format whitelist while it does not accept RGBA.
const int _avPixFmtRgb0 = 76;

/// AVPixelFormat.bgr0 in libavutil 60.
const int _avPixFmtBgr0 = 78;

/// Pick the FFmpeg encoder name for a hardware codec.
String? _nvencEncoderName(VideoCodec codec) {
  switch (codec) {
    case VideoCodec.h264:
      return 'h264_nvenc';
    case VideoCodec.hevc:
      return 'hevc_nvenc';
    case VideoCodec.av1:
      return 'av1_nvenc';
    default:
      return null;
  }
}

// ignore: unused_element
int _videoCodecToAvId(VideoCodec codec) {
  switch (codec) {
    case VideoCodec.h264:
      return AVCodecId.h264;
    case VideoCodec.hevc:
      return AVCodecId.hevc;
    case VideoCodec.av1:
      return AVCodecId.av1;
    default:
      throw CodecInitException(
        'ffmpeg-nvenc',
        'Unsupported VideoCodec.$codec for NVENC',
      );
  }
}

/// Returns true if `h264_nvenc` (or any NVENC encoder) is available in the
/// loaded FFmpeg build. Cheap to call — looks up the encoder by name.
bool ffmpegNvencAvailable() {
  final ff = Ffmpeg.instance();
  if (ff == null) return false;
  final name = 'h264_nvenc'.toNativeUtf8();
  try {
    return ff.avcodecFindEncoderByName(name) != address(0);
  } finally {
    calloc.free(name);
  }
}

/// Hardware H.264/HEVC/AV1 encoder via NVENC.
///
/// Accepts `CpuFrameSource` (or `MiniAVBufferSource` with CPU plane) where
/// `bytes` is RGBA8 row-major with stride `width * 4`. Throws on any other
/// frame source — Stage B will add `D3D11TextureFrameSource` support.
class FfmpegNvencEncoder implements PlatformEncoder, FfmpegEncoderBridge {
  FfmpegNvencEncoder._(
    this._ff,
    this._cfg,
    this._codecCtx,
    this._frame,
    this._packet,
  );

  final Ffmpeg _ff;
  final EncoderConfig _cfg;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVFrame> _frame;
  final Pointer<AVPacket> _packet;

  bool _closed = false;
  int _nextPts = 0;
  CodecExtraData? _extraData;
  bool _forceKeyframe = false;

  /// Build + open an NVENC encoder. Throws [CodecInitException] on any
  /// failure (encoder not present, unsupported codec, GPU init failure).
  static FfmpegNvencEncoder open(EncoderConfig cfg) {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg-nvenc',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }

    final encoderName = _nvencEncoderName(cfg.codec);
    if (encoderName == null) {
      throw CodecInitException(
        'ffmpeg-nvenc',
        'No NVENC encoder for ${cfg.codec}',
      );
    }

    final namePtr = encoderName.toNativeUtf8();
    Pointer<AVCodec> codec;
    try {
      codec = ff.avcodecFindEncoderByName(namePtr);
    } finally {
      calloc.free(namePtr);
    }
    if (codec == address(0)) {
      throw CodecInitException(
        'ffmpeg-nvenc',
        '$encoderName not present in this FFmpeg build (no NVIDIA GPU '
            'support compiled in, or libnvidia-encode not loadable)',
      );
    }

    final codecCtx = ff.avcodecAllocContext3(codec);
    if (codecCtx == address(0)) {
      throw const CodecInitException(
        'ffmpeg-nvenc',
        'avcodec_alloc_context3 returned NULL',
      );
    }

    try {
      _configureCtx(ff, codecCtx, cfg);

      final ret = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (ret < 0) {
        throw CodecInitException(
          'ffmpeg-nvenc',
          'avcodec_open2($encoderName) failed: ${ff.strError(ret)} ($ret). '
              'Common causes: no NVIDIA GPU present, driver too old for '
              'requested codec/profile, or another process holds the NVENC '
              'session limit.',
        );
      }

      final frame = ff.avFrameAlloc();
      final packet = ff.avPacketAlloc();
      if (frame == address(0) || packet == address(0)) {
        throw const CodecInitException(
          'ffmpeg-nvenc',
          'av_frame_alloc / av_packet_alloc returned NULL',
        );
      }

      // Pre-configure the AVFrame as RGB0 of the encoder's dimensions.
      // NVENC takes 4 bytes per pixel; libavutil aligns rows to 32 bytes by
      // default which produces a contiguous buffer for typical widths
      // (multiples of 8). We always re-check the actual linesize at copy
      // time so non-multiple-of-8 widths still work.
      final rgb0Name = 'rgb0'.toNativeUtf8();
      final rgb0Fmt = ff.avGetPixFmtByName(rgb0Name);
      calloc.free(rgb0Name);
      if (rgb0Fmt < 0) {
        throw const CodecInitException(
          'ffmpeg-nvenc',
          'av_get_pix_fmt("rgb0") returned -1; this libavutil does not '
              'know about RGB0',
        );
      }
      frame.ref
        ..width = cfg.width
        ..height = cfg.height
        ..format = rgb0Fmt;

      final r = ff.avFrameGetBuffer(frame, 32);
      if (r < 0) {
        throw CodecInitException(
          'ffmpeg-nvenc',
          'av_frame_get_buffer(RGB0) failed: ${ff.strError(r)}',
        );
      }

      return FfmpegNvencEncoder._(ff, cfg, codecCtx, frame, packet)
        .._loadExtraData();
    } catch (_) {
      final ptr = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
      ff.avcodecFreeContext(ptr);
      calloc.free(ptr);
      rethrow;
    }
  }

  static void _configureCtx(
    Ffmpeg ff,
    Pointer<AVCodecContext> ctx,
    EncoderConfig cfg,
  ) {
    final ctxV = ctx.cast<Void>();
    void setStr(String key, String val) {
      final k = key.toNativeUtf8();
      final v = val.toNativeUtf8();
      try {
        ff.avOptSet(ctxV, k, v, 0);
      } finally {
        calloc.free(k);
        calloc.free(v);
      }
    }

    void setQ(String key, int num, int den) {
      final k = key.toNativeUtf8();
      final r = calloc<AVRational>();
      r.ref
        ..num = num
        ..den = den;
      try {
        final ret = ff.avOptSetQ(ctxV, k, r.ref, 0);
        if (ret < 0) {
          throw CodecInitException(
            'ffmpeg-nvenc',
            'av_opt_set_q($key=$num/$den) failed: ${ff.strError(ret)} ($ret)',
          );
        }
      } finally {
        calloc.free(k);
        calloc.free(r);
      }
    }

    void setIntStrict(String key, int val) {
      final k = key.toNativeUtf8();
      try {
        final r = ff.avOptSetInt(ctxV, k, val, 0);
        if (r < 0) {
          throw CodecInitException(
            'ffmpeg-nvenc',
            'av_opt_set_int($key=$val) failed: ${ff.strError(r)} ($r)',
          );
        }
      } finally {
        calloc.free(k);
      }
    }

    setStr('video_size', '${cfg.width}x${cfg.height}');
    // Resolve "rgb0" → AVPixelFormat enum value at runtime (the numeric
    // value of `AV_PIX_FMT_RGB0` shifts across major libavutil releases).
    final rgb0Name = 'rgb0'.toNativeUtf8();
    final rgb0Fmt = ff.avGetPixFmtByName(rgb0Name);
    calloc.free(rgb0Name);
    if (rgb0Fmt < 0) {
      throw const CodecInitException(
        'ffmpeg-nvenc',
        'av_get_pix_fmt("rgb0") returned -1; this libavutil does not '
            'know about RGB0',
      );
    }
    // Use the dedicated PIXEL_FMT setter — av_opt_set_int does not dispatch
    // to AV_OPT_TYPE_PIXEL_FMT on AVCodecContext.
    {
      // The option name on AVCodecContext is "pixel_format" (the C struct
      // field is `pix_fmt` but libavcodec/options_table.c registers it
      // under "pixel_format").
      final k = 'pixel_format'.toNativeUtf8();
      try {
        final r = ff.avOptSetPixelFmt(
          ctxV,
          k,
          rgb0Fmt,
          1 /* SEARCH_CHILDREN */,
        );
        if (r < 0) {
          throw CodecInitException(
            'ffmpeg-nvenc',
            'av_opt_set_pixel_fmt(pixel_format=rgb0/$rgb0Fmt) failed: '
                '${ff.strError(r)} ($r)',
          );
        }
      } finally {
        calloc.free(k);
      }
    }
    setIntStrict('b', cfg.bitrateBps);
    if (cfg.gopLength > 0) {
      setIntStrict('g', cfg.gopLength);
    }
    setIntStrict('bf', cfg.bFrameCount);
    setQ('time_base', cfg.frameRateDenominator, cfg.frameRateNumerator);

    final fr = calloc<AVRational>();
    fr.ref
      ..num = cfg.frameRateNumerator
      ..den = cfg.frameRateDenominator;
    final frKey = 'framerate'.toNativeUtf8();
    ff.avOptSetQ(ctxV, frKey, fr.ref, 0);
    calloc.free(frKey);
    calloc.free(fr);

    if (cfg.backendOptions['global_header'] == '1') {
      setStr('flags', '+global_header');
    }

    // Sensible NVENC defaults for screen-capture / low-latency capture.
    // Callers can override any of these via [EncoderConfig.backendOptions].
    final defaults = <String, String>{
      'preset': 'p4', // balanced quality/speed (NVENC v8+).
      'tune': 'hq', // hq | ll | ull | lossless
      'rc': cfg.rateControl == RateControl.crf ? 'constqp' : 'vbr',
    };
    if (cfg.rateControl == RateControl.crf && cfg.crfQuality != null) {
      // NVENC uses qp 0–51; crfQuality maps directly.
      defaults['qp'] = cfg.crfQuality!.toString();
    }

    defaults.forEach((k, v) {
      if (!cfg.backendOptions.containsKey(k)) setStr(k, v);
    });
    cfg.backendOptions.forEach((k, v) {
      if (k == 'global_header') return;
      setStr(k, v);
    });
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> requestKeyframe() async {
    _forceKeyframe = true;
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _checkOpen();
    final src = _frameToRgba(frame);
    if (src.width != _cfg.width || src.height != _cfg.height) {
      throw CodecRuntimeException(
        'ffmpeg-nvenc',
        'Frame size ${src.width}x${src.height} != encoder size '
            '${_cfg.width}x${_cfg.height}',
      );
    }

    final mw = _ff.avFrameMakeWritable(_frame);
    if (mw < 0) {
      throw CodecRuntimeException(
        'ffmpeg-nvenc',
        'av_frame_make_writable: ${_ff.strError(mw)}',
      );
    }

    // Copy RGBA src into AVFrame.data[0] honouring linesize.
    final f = _frame.ref;
    final dstStride = f.linesize0;
    final rowBytes = src.width * 4;
    final dstView = f.data0.asTypedList(dstStride * src.height);
    if (src.srcStride == dstStride) {
      // Fast path: contiguous copy.
      dstView.setAll(0, src.bytes);
    } else {
      for (var row = 0; row < src.height; row++) {
        dstView.setRange(
          row * dstStride,
          row * dstStride + rowBytes,
          src.bytes,
          row * src.srcStride,
        );
      }
    }

    f.pts = _nextPts++;
    f.pictType = _forceKeyframe ? 1 /* AV_PICTURE_TYPE_I */ : 0;
    _forceKeyframe = false;

    final sendRet = _ff.avcodecSendFrame(_codecCtx, _frame);
    if (sendRet < 0 && sendRet != kAvErrorEAgain) {
      throw CodecRuntimeException(
        'ffmpeg-nvenc',
        'avcodec_send_frame: ${_ff.strError(sendRet)} ($sendRet)',
      );
    }
    return _drainOne();
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final ret = _ff.avcodecSendFrame(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg-nvenc',
        'avcodec_send_frame(NULL): ${_ff.strError(ret)}',
      );
    }
    final out = <EncodedPacket>[];
    while (true) {
      final pkt = _drainOne();
      if (pkt == null) break;
      out.add(pkt);
    }
    return out;
  }

  @override
  bool get supportsGpuBufferInput => false;

  // NVENC (CPU-fed) wants packed RGB/BGR0, not YUV420P planes.
  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final fp = calloc<Pointer<AVFrame>>()..value = _frame;
    final pp = calloc<Pointer<AVPacket>>()..value = _packet;
    final cp = calloc<Pointer<AVCodecContext>>()..value = _codecCtx;
    try {
      _ff.avFrameFree(fp);
      _ff.avPacketFree(pp);
      _ff.avcodecFreeContext(cp);
    } finally {
      calloc.free(fp);
      calloc.free(pp);
      calloc.free(cp);
    }
  }

  /// Internal accessor for the muxer.
  @override
  Pointer<AVCodecContext> get nativeCodecContext => _codecCtx;

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-nvenc', 'encoder closed');
    }
  }

  void _loadExtraData() {
    final params = _ff.avcodecParametersAlloc();
    if (params == address(0)) return;
    final pp = calloc<Pointer<AVCodecParameters>>()..value = params;
    try {
      final r = _ff.avcodecParametersFromContext(params, _codecCtx);
      if (r < 0) return;
      final ref = params.ref;
      if (ref.extradataSize > 0 && ref.extradata != address(0)) {
        final bytes = Uint8List(ref.extradataSize);
        bytes.setAll(0, ref.extradata.asTypedList(ref.extradataSize));
        _extraData = CodecExtraData.video(_cfg.codec, bytes);
      }
    } finally {
      _ff.avcodecParametersFree(pp);
      calloc.free(pp);
    }
  }

  EncodedPacket? _drainOne() {
    final ret = _ff.avcodecReceivePacket(_codecCtx, _packet);
    if (ret == kAvErrorEAgain || ret == kAvErrorEof) return null;
    if (ret < 0) {
      throw CodecRuntimeException(
        'ffmpeg-nvenc',
        'avcodec_receive_packet: ${_ff.strError(ret)} ($ret)',
      );
    }
    final p = _packet.ref;
    final bytes = Uint8List(p.size);
    final src = p.data.asTypedList(p.size);
    bytes.setRange(0, p.size, src);

    final usPerFrame =
        (1000000 * _cfg.frameRateDenominator) ~/ _cfg.frameRateNumerator;
    final pktOut = EncodedPacket(
      data: bytes,
      ptsUs: p.pts * usPerFrame,
      dtsUs: (p.dts == _avNoPts ? p.pts : p.dts) * usPerFrame,
      durationUs: p.duration * usPerFrame,
      isKeyframe: (p.flags & kPktFlagKey) != 0,
    );
    _ff.avPacketUnref(_packet);
    return pktOut;
  }

  static const _kSupportedCpuFormats = {
    MiniAVPixelFormat.rgba32,
    MiniAVPixelFormat.bgra32,
    MiniAVPixelFormat.yuy2,
    MiniAVPixelFormat.nv12,
    MiniAVPixelFormat.i420,
  };

  static int _defaultRowStride(MiniAVPixelFormat fmt, int width) {
    switch (fmt) {
      case MiniAVPixelFormat.rgba32:
      case MiniAVPixelFormat.bgra32:
        return width * 4;
      case MiniAVPixelFormat.yuy2:
        return width * 2;
      case MiniAVPixelFormat.nv12:
      case MiniAVPixelFormat.i420:
        return width;
      default:
        return width;
    }
  }

  static Uint8List _flattenPlanes(
    MiniAVVideoBuffer video,
    MiniAVPixelFormat fmt,
  ) {
    final w = video.width;
    final h = video.height;
    switch (fmt) {
      case MiniAVPixelFormat.nv12:
        final ySize = w * h;
        final uvSize = w * (h ~/ 2);
        final out = Uint8List(ySize + uvSize);
        out.setRange(0, ySize, video.planes[0]!);
        if (video.planes.length > 1 && video.planes[1] != null) {
          out.setRange(ySize, ySize + uvSize, video.planes[1]!);
        }
        return out;
      case MiniAVPixelFormat.i420:
        final ySize = w * h;
        final cSize = (w ~/ 2) * (h ~/ 2);
        final out = Uint8List(ySize + 2 * cSize);
        out.setRange(0, ySize, video.planes[0]!);
        if (video.planes.length > 1 && video.planes[1] != null) {
          out.setRange(ySize, ySize + cSize, video.planes[1]!);
        }
        if (video.planes.length > 2 && video.planes[2] != null) {
          out.setRange(ySize + cSize, ySize + 2 * cSize, video.planes[2]!);
        }
        return out;
      default:
        return video.planes[0]!;
    }
  }

  _PreparedRgba _frameToRgba(FrameSource src) {
    switch (src) {
      case CpuFrameSource():
        final fmt = src.pixelFormat;
        if (!_kSupportedCpuFormats.contains(fmt)) {
          throw CodecRuntimeException(
            'ffmpeg-nvenc',
            'NVENC accepts RGBA32/BGRA32/YUY2/NV12/I420 CPU frames; got $fmt',
          );
        }
        final stride0 = (src.strideBytes != null && src.strideBytes!.isNotEmpty)
            ? src.strideBytes!.first
            : _defaultRowStride(fmt, src.width);
        if (fmt == MiniAVPixelFormat.rgba32 ||
            fmt == MiniAVPixelFormat.bgra32) {
          return _PreparedRgba(
            bytes: src.bytes,
            width: src.width,
            height: src.height,
            srcStride: stride0,
          );
        }
        final bgra = toBgra32(
          src: src.bytes,
          format: fmt,
          width: src.width,
          height: src.height,
          strides: src.strideBytes,
        );
        return _PreparedRgba(
          bytes: bgra,
          width: src.width,
          height: src.height,
          srcStride: src.width * 4,
        );
      case MiniAVBufferSource():
        final video = src.buffer.data;
        if (video is! MiniAVVideoBuffer) {
          throw const CodecRuntimeException(
            'ffmpeg-nvenc',
            'expected video buffer',
          );
        }
        final fmt = video.pixelFormat;
        if (!_kSupportedCpuFormats.contains(fmt)) {
          throw CodecRuntimeException(
            'ffmpeg-nvenc',
            'NVENC accepts RGBA32/BGRA32/YUY2/NV12/I420 MiniAV buffers; '
                'got $fmt',
          );
        }
        if (video.planes.isEmpty || video.planes[0] == null) {
          throw const CodecRuntimeException(
            'ffmpeg-nvenc',
            'MiniAVBufferSource: plane[0] was null — likely GPU-backed buffer',
          );
        }
        final bytes =
            (fmt == MiniAVPixelFormat.nv12 || fmt == MiniAVPixelFormat.i420)
            ? _flattenPlanes(video, fmt)
            : video.planes[0]!;
        final stride0 = video.strideBytes.isNotEmpty
            ? video.strideBytes.first
            : _defaultRowStride(fmt, video.width);
        if (fmt == MiniAVPixelFormat.rgba32 ||
            fmt == MiniAVPixelFormat.bgra32) {
          return _PreparedRgba(
            bytes: bytes,
            width: video.width,
            height: video.height,
            srcStride: stride0,
          );
        }
        final bgra = toBgra32(
          src: bytes,
          format: fmt,
          width: video.width,
          height: video.height,
          strides: video.strideBytes,
        );
        return _PreparedRgba(
          bytes: bgra,
          width: video.width,
          height: video.height,
          srcStride: video.width * 4,
        );
      default:
        throw CodecRuntimeException(
          'ffmpeg-nvenc',
          'NVENC accepts CpuFrameSource / MiniAVBufferSource (CPU plane) only. '
              'Got: ${src.runtimeType}.',
        );
    }
  }
}

class _PreparedRgba {
  final Uint8List bytes;
  final int width;
  final int height;
  final int srcStride;
  const _PreparedRgba({
    required this.bytes,
    required this.width,
    required this.height,
    required this.srcStride,
  });
}

const int _avNoPts = -0x8000000000000000;

/// Test hook: reads the actual `AV_PIX_FMT_BGR0` value for the loaded
/// libavutil. Unused right now (we hardcode `RGB0=76` for FFmpeg 8.x) but
/// kept here so that follow-ups can swap to runtime detection if we ever
/// need to support libavutil 59 or earlier.
// ignore: unused_element
int _bgrZeroFormat() => _avPixFmtBgr0;
