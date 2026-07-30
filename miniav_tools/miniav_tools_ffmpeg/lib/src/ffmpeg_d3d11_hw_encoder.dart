/// Stage B — true zero-copy D3D11VA hardware encoder.
///
/// Accepts D3D11-backed frames (a `D3D11TextureFrameSource`, or a
/// `MiniAVBufferSource` whose `contentType == gpuD3D11Handle`) and feeds
/// them to an `*_amf` / `*_qsv` / `*_mf` encoder via `AV_PIX_FMT_D3D11`
/// without ever touching system memory.
///
/// Pipeline per frame:
/// 1. Capture produces an NT-shared D3D11 texture (`MiniAVBuffer`).
/// 2. We `OpenSharedResource1` it on FFmpeg's own `ID3D11Device`.
/// 3. We `CopyResource` it into a pool texture allocated by FFmpeg's
///    `AVHWFramesContext` (BGRA → no colour-space conversion).
/// 4. The pool AVFrame is sent to the encoder; the encoder driver
///    (AMF / Intel Media SDK / MediaFoundation) consumes the texture
///    on the GPU and produces an encoded packet.
///
/// **Vendors covered here:**
/// - NVENC — accepts `AV_PIX_FMT_D3D11` natively via NVENC's DirectX
///   resource path (`NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX`). No CUDA needed.
/// - AMF — AMD's encoder runtime; native D3D11 surface input.
/// - QSV — Intel Media SDK; needs a *derived* `qsv` hwframes context
///   chained from D3D11VA (handled by [openWith]).
/// - MediaFoundation — universal Windows fallback (vendor MFT under the
///   hood; usually slower than the dedicated runtimes above).
///
/// **Skipped here (Apple/Linux/Android-only)**: VideoToolbox, VAAPI,
/// V4L2 M2M, MediaCodec — those live in their own platform encoder files.
///
/// **Why this is faster than Stage A** (NVENC `bgr0` upload):
/// Stage A copies `width × height × 4` bytes across the PCIe bus per frame
/// (~29 MB at 5K). Stage B does a pure intra-GPU `CopyResource`. At 5K60 the
/// difference is ~1.7 GB/s of CPU→GPU bandwidth completely eliminated.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_encoder.dart' show address;
import 'ffmpeg_ffi.dart';
import 'ffmpeg_log.dart';
import 'ffmpeg_muxer.dart' show FfmpegEncoderBridge;
import 'ffmpeg_shim.dart';

/// FFmpeg pixel-format enum value for `AV_PIX_FMT_D3D11` (libavutil 60).
/// Resolved by name at init — falls back to a hard-coded literal only if
/// the lookup fails (which would indicate a libavutil without D3D11VA
/// support, in which case the encoder won't open anyway).
const int _avPixFmtD3d11Fallback = 174;

/// Encoder vendors that natively consume `AV_PIX_FMT_D3D11`.
enum D3d11HwVendor { nvenc, amf, qsv, mediafoundation }

// DXGI adapter VendorId constants — used to filter the vendor probe order
// to only candidates compatible with the injected D3D11 device's adapter.
const int _dxgiVendorIntel = 0x8086;
const int _dxgiVendorNvidia = 0x10DE;
const int _dxgiVendorAmd = 0x1002;

/// Returns the D3D11VA vendor probe order for a specific DXGI adapter vendor.
///
/// Restricts open/warm-up attempts to only the IHV-native vendor plus the
/// universal MediaFoundation fallback. This avoids spending time opening
/// h264_nvenc with an Intel device (fast failure, but still wasteful and
/// noisy in logs) and prevents unnecessary VIDEO_SUPPORT sibling creation for
/// vendors that can never work on this adapter.
///
/// Returns [_defaultD3d11Order] for unknown vendors so no probe is skipped.
List<D3d11HwVendor> _vendorOrderForDxgiVendor(int dxgiVendorId) {
  switch (dxgiVendorId) {
    case _dxgiVendorIntel:
      return [D3d11HwVendor.qsv, D3d11HwVendor.mediafoundation];
    case _dxgiVendorNvidia:
      return [D3d11HwVendor.nvenc, D3d11HwVendor.mediafoundation];
    case _dxgiVendorAmd:
      return [D3d11HwVendor.amf, D3d11HwVendor.mediafoundation];
    default:
      return _defaultD3d11Order; // unknown adapter — try everything
  }
}

/// DXGI pixel layout of the source textures the encoder will receive in
/// `encode()`. Determines the `sw_format` of FFmpeg's hwframes pool, which
/// in turn dictates the DXGI format of the pool textures —
/// `CopySubresourceRegion` cannot copy across format type-groups, so this
/// MUST match the source layout exactly.
///
/// - [bgra] — `DXGI_FORMAT_B8G8R8A8_UNORM` (miniav DXGI screen capture).
/// - [rgba] — `DXGI_FORMAT_R8G8B8A8_UNORM` (minigpu `SharedOutputTexture`,
///   the standard WebGPU `rgba8unorm` storage texture format).
enum D3d11HwSourceFormat { bgra, rgba }

class _D3d11Spec {
  final D3d11HwVendor vendor;
  final VideoCodec codec;
  final String encoderName;
  final int maxWidth;
  final int maxHeight;
  final Map<String, String> defaults;

  const _D3d11Spec({
    required this.vendor,
    required this.codec,
    required this.encoderName,
    required this.maxWidth,
    required this.maxHeight,
    required this.defaults,
  });
}

const List<_D3d11Spec> _d3d11Specs = [
  // ─── NVIDIA NVENC ─────────────────────────────────────────────────────────
  // NVENC accepts AV_PIX_FMT_D3D11 directly — the wrapper registers each
  // pool texture with the NVENC session via NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX.
  // Preset 'p4' = balanced quality/speed; tune 'll' = low-latency; rc 'cbr'
  // matches the encoder's expectations for screen-share / live workloads.
  _D3d11Spec(
    vendor: D3d11HwVendor.nvenc,
    codec: VideoCodec.h264,
    encoderName: 'h264_nvenc',
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'preset': 'p4', 'tune': 'll', 'rc': 'cbr'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.nvenc,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_nvenc',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'p4', 'tune': 'll', 'rc': 'cbr'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.nvenc,
    codec: VideoCodec.av1,
    encoderName: 'av1_nvenc',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'p4', 'tune': 'll', 'rc': 'cbr'},
  ),

  // ─── AMD AMF ──────────────────────────────────────────────────────────────
  _D3d11Spec(
    vendor: D3d11HwVendor.amf,
    codec: VideoCodec.h264,
    encoderName: 'h264_amf',
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'usage': 'transcoding', 'quality': 'speed'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.amf,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_amf',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'usage': 'transcoding', 'quality': 'speed'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.amf,
    codec: VideoCodec.av1,
    encoderName: 'av1_amf',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'usage': 'transcoding', 'quality': 'speed'},
  ),

  // ─── Intel QSV ────────────────────────────────────────────────────────────
  _D3d11Spec(
    vendor: D3d11HwVendor.qsv,
    codec: VideoCodec.h264,
    encoderName: 'h264_qsv',
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'preset': 'veryfast'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.qsv,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_qsv',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'veryfast'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.qsv,
    codec: VideoCodec.av1,
    encoderName: 'av1_qsv',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'veryfast'},
  ),

  // ─── Windows Media Foundation (universal fallback on Windows) ────────────
  _D3d11Spec(
    vendor: D3d11HwVendor.mediafoundation,
    codec: VideoCodec.h264,
    encoderName: 'h264_mf',
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'hw_encoding': '1'},
  ),
  _D3d11Spec(
    vendor: D3d11HwVendor.mediafoundation,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_mf',
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'hw_encoding': '1'},
  ),
];

/// Default vendor probe order: NVENC → AMF → QSV → MediaFoundation.
/// The first three are vendor-native fast paths (one per GPU vendor);
/// MF is the generic Windows fallback and typically slowest. Each vendor
/// will only succeed on its matching GPU, so this order safely covers all
/// three IHVs without relying on runtime detection of the adapter vendor.
const List<D3d11HwVendor> _defaultD3d11Order = [
  D3d11HwVendor.nvenc,
  D3d11HwVendor.amf,
  D3d11HwVendor.qsv,
  D3d11HwVendor.mediafoundation,
];

bool _encoderPresent(Ffmpeg ff, String name) {
  final p = name.toNativeUtf8();
  try {
    return ff.avcodecFindEncoderByName(p) != address(0);
  } finally {
    calloc.free(p);
  }
}

_D3d11Spec? _findSpec(D3d11HwVendor vendor, VideoCodec codec) {
  for (final s in _d3d11Specs) {
    if (s.vendor == vendor && s.codec == codec) return s;
  }
  return null;
}

_D3d11Spec? _pickSpec(
  Ffmpeg ff,
  VideoCodec codec, {
  List<D3d11HwVendor> order = _defaultD3d11Order,
}) {
  for (final v in order) {
    final spec = _findSpec(v, codec);
    if (spec == null) continue;
    if (_encoderPresent(ff, spec.encoderName)) return spec;
  }
  return null;
}

/// Returns the list of D3D11VA-compatible vendors registered in the loaded
/// FFmpeg build. Cheap — only does name lookups, does not init any GPU.
List<D3d11HwVendor> ffmpegD3d11VendorsAvailable() {
  if (!Platform.isWindows) return const [];
  final ff = Ffmpeg.instance();
  if (ff == null) return const [];
  final seen = <D3d11HwVendor>{};
  for (final s in _d3d11Specs) {
    if (seen.contains(s.vendor)) continue;
    if (_encoderPresent(ff, s.encoderName)) seen.add(s.vendor);
  }
  return seen.toList(growable: false);
}

/// Returns true if any D3D11VA encoder for [codec] is registered AND the
/// shim is loaded. Stage B is otherwise unavailable.
bool ffmpegD3d11EncoderAvailable(VideoCodec codec) {
  if (!Platform.isWindows) return false;
  if (FfmpegShim.tryLoad() == null) return false;
  final ff = Ffmpeg.instance();
  if (ff == null) return false;
  for (final s in _d3d11Specs) {
    if (s.codec == codec && _encoderPresent(ff, s.encoderName)) return true;
  }
  return false;
}

/// Eagerly triggers D3D11VA vendor SDK initialization without blocking the
/// caller. Call this as soon as the shared D3D11 device is available (e.g.
/// right after `ensureSharedGpu`). The vendors (h264_qsv, h264_mf, etc.)
/// each require a one-time driver-side startup — MFStartup, DXVA session
/// creation, MFX session init — that is triggered as a side effect of the
/// first `avcodec_open2` call, even when that call fails. By firing these
/// attempts in the background before recording starts, the vendor SDKs are
/// warm by the time [ffmpegD3d11EncoderCompatibleWith] runs its real probe,
/// preventing cold-start fallback to CPU on the very first session.
///
/// All failures are silently ignored — this is purely a side-effect trigger.
/// The function is a no-op on non-Windows or when no vendors are registered.
void ffmpegD3d11WarmUp(int existingD3d11Device) {
  if (!Platform.isWindows) return;
  if (existingD3d11Device == 0) return;
  if (FfmpegShim.tryLoad() == null) return;
  final ff = Ffmpeg.instance();
  if (ff == null) return;

  // Determine which vendors are worth warming up for this specific adapter.
  // E.g. on an Intel iGPU: only qsv + mediafoundation; skip nvenc/amf entirely.
  final shim = FfmpegShim.tryLoad()!;
  final dxgiVendorId = shim.d3d11GetVendorId(
    Pointer<Void>.fromAddress(existingD3d11Device),
  );
  if (dxgiVendorId == 0) {
    ffmpegToolsLog(
      MiniAVLogLevel.warn,
      '[ffmpeg-d3d11] ffmpegD3d11WarmUp: '
      'IDXGIDevice::QueryInterface returned 0 for '
      'device=0x${existingD3d11Device.toRadixString(16)} — vendor ID '
      'unknown; warming all registered vendors.',
    );
  }
  final compatibleOrder = _vendorOrderForDxgiVendor(dxgiVendorId);

  // Fire one open attempt per registered vendor that is also compatible with
  // this adapter, unawaited. Each attempt loads the vendor DLL and inits its
  // global state. We use h264 as the probe codec (always present when the
  // vendor is available).
  final vendors = ffmpegD3d11VendorsAvailable()
      .where(compatibleOrder.contains)
      .toList();
  if (vendors.isEmpty) {
    // No adapter-compatible vendors exist in this FFmpeg build — log and
    // bail so we don't pollute the log with NVENC/AMF errors against the
    // wrong adapter.
    ffmpegToolsLog(
      MiniAVLogLevel.info,
      '[ffmpeg-d3d11] ffmpegD3d11WarmUp: no adapter-compatible vendors '
      'present in this FFmpeg build for '
      'vendorID=0x${dxgiVendorId.toRadixString(16)} '
      '(device=0x${existingD3d11Device.toRadixString(16)}). '
      'Available: ${ffmpegD3d11VendorsAvailable().map((v) => v.name).join(', ')}. '
      'Zero-copy warm-up skipped.',
    );
    return;
  }
  ffmpegToolsLog(
    MiniAVLogLevel.info,
    '[ffmpeg-d3d11] ffmpegD3d11WarmUp: triggering background SDK init for '
    '${vendors.map((v) => v.name).join(', ')} '
    '(device=0x${existingD3d11Device.toRadixString(16)}, '
    'vendorID=0x${dxgiVendorId.toRadixString(16)})',
  );
  // Each vendor gets its own unawaited future so they run concurrently.
  for (final vendor in vendors) {
    final spec = _d3d11Specs.firstWhere(
      (s) => s.vendor == vendor && s.codec == VideoCodec.h264,
      orElse: () => _d3d11Specs.firstWhere((s) => s.vendor == vendor),
    );
    Future(() async {
      FfmpegD3d11HwEncoder? enc;
      try {
        enc = FfmpegD3d11HwEncoder.open(
          EncoderConfig(
            codec: spec.codec,
            width: 256,
            height: 256,
            bitrateBps: 500_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            bFrameCount: 0,
            hwAccel: HwAccelPreference.required,
            rateControl: RateControl.vbr,
          ),
          existingD3d11Device: existingD3d11Device,
          vendorOrder: [vendor],
        );
        // Success — SDK is already warm. Close cleanly so resources are freed.
        await enc.close();
        enc = null;
        ffmpegToolsLog(
          MiniAVLogLevel.info,
          '[ffmpeg-d3d11] ffmpegD3d11WarmUp: ${vendor.name} opened '
          'successfully — SDK is warm.',
        );
      } catch (_) {
        // Expected on first call — the failure itself triggers initialization.
        if (enc != null) {
          try {
            await enc.close();
          } catch (_) {}
        }
      }
    });
  }
}

/// Returns [true] if at least one D3D11VA vendor can successfully open an
/// encoder for [codec] when [existingD3d11Device] is injected as the
/// `ID3D11Device*` that the encoder must use.
///
/// Unlike [ffmpegD3d11EncoderAvailable], which only checks that encoder
/// symbols are registered in the FFmpeg build, this function **actually
/// tries to open** a minimal encoder to verify runtime adapter
/// compatibility. This distinguishes between "NVENC symbols exist" (fast
/// symbol check) and "NVENC can open on THIS device" (which fails when the
/// injected device is on a different GPU vendor — e.g. an Intel iGPU device
/// passed to the NVENC path).
///
/// The probe is slightly more expensive than the symbol check (~50–200 ms
/// first call) but prevents a false-positive "GPU zero-copy mode" decision
/// in the recorder when the Dawn/WebGPU device is on an Intel iGPU and
/// only NVENC/AMF encoders are registered.
///
/// Returns [true] without probing when [existingD3d11Device] is 0 (no
/// injected device — the encoder is free to create its own D3D11 device on
/// any adapter, so adapter compatibility is not a concern here).
Future<bool> ffmpegD3d11EncoderCompatibleWith(
  VideoCodec codec,
  int existingD3d11Device,
) async {
  if (!ffmpegD3d11EncoderAvailable(codec)) return false;
  if (existingD3d11Device == 0) return true;

  // Restrict the vendor probe order to only IHV-compatible vendors.
  // E.g. on Intel iGPU (vendorID=0x8086): only [qsv, mediafoundation].
  // This avoids wasted NVENC/AMF open attempts (and noisy stderr) on a
  // device those vendors can never use.
  final shim =
      FfmpegShim.tryLoad()!; // already validated by ffmpegD3d11EncoderAvailable
  final dxgiVendorId = shim.d3d11GetVendorId(
    Pointer<Void>.fromAddress(existingD3d11Device),
  );
  if (dxgiVendorId == 0) {
    ffmpegToolsLog(
      MiniAVLogLevel.warn,
      '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
      'IDXGIDevice::QueryInterface returned 0 for '
      'device=0x${existingD3d11Device.toRadixString(16)} — vendor ID '
      'unknown; probing all registered vendors. '
      'If NVENC/AMF errors follow, this is why.',
    );
  }
  final vendorOrder = _vendorOrderForDxgiVendor(dxgiVendorId);

  // Fast-fail: if no vendor in the adapter-filtered order is actually
  // present in this FFmpeg build, skip the entire probe.  Without this,
  // the loop below burns ~400 ms × 2 attempts per absent vendor before
  // returning false, and the warmup fires NVENC/AMF probes against the
  // wrong adapter — generating log noise that looks like real failures.
  //
  // Example: Dawn on Intel iGPU (vendorID=0x8086) → vendorOrder=[qsv, mf],
  // but the FFmpeg build only ships h264_nvenc / h264_amf → intersection
  // is empty → return false immediately.
  final presentVendors = ffmpegD3d11VendorsAvailable().toSet().intersection(
    vendorOrder.toSet(),
  );
  if (presentVendors.isEmpty) {
    ffmpegToolsLog(
      MiniAVLogLevel.warn,
      '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
      'no adapter-compatible vendors present in this FFmpeg build '
      '(adapter vendorID=0x${dxgiVendorId.toRadixString(16)}, '
      'needed: ${vendorOrder.map((v) => v.name).join(', ')}, '
      'available: ${ffmpegD3d11VendorsAvailable().map((v) => v.name).join(', ')}). '
      'Zero-copy is unavailable; CPU path will be used.',
    );
    return false;
  }

  // Re-order the candidates so adapter-compatible ones come first and we
  // still respect priority, but never attempt vendors missing from the build.
  final effectiveVendorOrder = vendorOrder
      .where(presentVendors.contains)
      .toList(growable: false);
  ffmpegToolsLog(
    MiniAVLogLevel.debug,
    '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
    'vendorID=0x${dxgiVendorId.toRadixString(16)}, '
    'probing vendors: ${effectiveVendorOrder.map((v) => v.name).join(', ')}',
  );

  // Probe at 256×256 — large enough to satisfy every vendor's minimum
  // dimension constraint (NVENC HEVC requires ≥ 144×144, others are smaller).
  final probeConfig = EncoderConfig(
    codec: codec,
    width: 256,
    height: 256,
    bitrateBps: 500_000,
    frameRateNumerator: 30,
    frameRateDenominator: 1,
    bFrameCount: 0,
    hwAccel: HwAccelPreference.required,
    rateControl: RateControl.vbr,
  );

  // Iterate vendors in priority order, probing each one individually.
  //
  // Using open() (which returns the first that opens) and then probing is
  // WRONG: if open() picks QSV but the frame-format probe fails, the old
  // code returned false immediately without ever trying MediaFoundation.
  //
  // Per-vendor iteration means:
  //   • CodecInitException (open fails) → retry once (400 ms cold-start
  //     window), then continue to the next vendor.
  //   • _probeAcceptsHwFrame returns false (encoder opens but rejects the
  //     pool's pixel format) → close and continue to the next vendor.
  //   • First vendor whose probe succeeds → return true.
  outer:
  for (final vendor in effectiveVendorOrder) {
    for (var attempt = 0; attempt < 2; attempt++) {
      FfmpegD3d11HwEncoder? enc;
      try {
        enc = FfmpegD3d11HwEncoder.openWith(
          probeConfig,
          vendor,
          existingD3d11Device: existingD3d11Device,
        );
        // CRITICAL: openWith() succeeding only proves the codec context
        // initialised — it does NOT prove the vendor accepts our pool's
        // pixel format.  Send one pool-allocated hwframe through the encoder
        // to confirm end-to-end compatibility before committing to this
        // vendor for the real recording.
        final accepted = enc._probeAcceptsHwFrame();
        await enc.close();
        enc = null;
        if (!accepted) {
          ffmpegToolsLog(
            MiniAVLogLevel.info,
            '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
            '${vendor.name} opened but rejected pool-allocated frame '
            '(pixel-format incompatible). Trying next vendor.',
          );
          continue outer; // try the next vendor, don't give up
        }
        return true; // this vendor is fully compatible
      } on CodecInitException catch (e) {
        if (enc != null) {
          try {
            await enc.close();
          } catch (_) {
            /* best effort */
          }
          enc = null;
        }
        if (attempt == 0) {
          // The first failure triggered the vendor SDK's global cold-start
          // (MFStartup / DXVA session / MFX session init).  Wait 400 ms so
          // the driver has time to finish before the second attempt.
          ffmpegToolsLog(
            MiniAVLogLevel.debug,
            '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
            '${vendor.name} attempt 1 failed ($e) — '
            'waiting 400 ms for SDK cold-start, then retrying.',
          );
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue; // retry same vendor
        }
        // Second failure: this vendor is genuinely incompatible or missing.
        ffmpegToolsLog(
          MiniAVLogLevel.debug,
          '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
          '${vendor.name} attempt 2 also failed ($e) — trying next vendor.',
        );
        continue outer;
      } catch (e) {
        if (enc != null) {
          try {
            await enc.close();
          } catch (_) {
            /* best effort */
          }
          enc = null;
        }
        ffmpegToolsLog(
          MiniAVLogLevel.warn,
          '[ffmpeg-d3d11] ffmpegD3d11EncoderCompatibleWith: '
          '${vendor.name} threw unexpected error ($e) — trying next vendor.',
        );
        continue outer;
      }
    }
  }
  return false; // no vendor was compatible
}

/// True zero-copy D3D11VA hardware encoder. See library doc-comment for
/// pipeline details.
class FfmpegD3d11HwEncoder implements PlatformEncoder, FfmpegEncoderBridge {
  FfmpegD3d11HwEncoder._(
    this._ff,
    this._shim,
    this._cfg,
    this._spec,
    this._codecCtx,
    this._packet,
    this._hwDeviceRef,
    this._hwFramesRef,
    this._d3dDevice,
    this._d3dContext,
    this._d3dPixFmt,
    this._qsvHwDeviceRef,
    this._qsvHwFramesRef,
    this._vpContext,
  );

  final Ffmpeg _ff;
  final FfmpegShim _shim;
  final EncoderConfig _cfg;
  final _D3d11Spec _spec;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVPacket> _packet;

  /// `AVBufferRef*` to the FFmpeg-owned `AVHWDeviceContext` (D3D11VA).
  Pointer<Void> _hwDeviceRef;

  /// `AVBufferRef*` to the FFmpeg-owned `AVHWFramesContext` (pool of
  /// `width × height` BGRA D3D11 textures used for CopySubresourceRegion).
  Pointer<Void> _hwFramesRef;

  /// `ID3D11Device*` owned by FFmpeg (we don't AddRef/Release — FFmpeg
  /// keeps the only strong ref via [_hwDeviceRef]).
  final Pointer<Void> _d3dDevice;

  /// `ID3D11DeviceContext*` (immediate context) on the same device.
  final Pointer<Void> _d3dContext;

  /// Resolved hardware pixel format value for the codec context.
  /// For most vendors: `AV_PIX_FMT_D3D11`. For QSV: `AV_PIX_FMT_QSV`.
  final int _d3dPixFmt;

  /// QSV-only: `AVBufferRef*` to the derived QSV `AVHWDeviceContext`.
  /// `nullptr` for non-QSV vendors.
  Pointer<Void> _qsvHwDeviceRef;

  /// QSV-only: `AVBufferRef*` to the derived QSV `AVHWFramesContext`.
  /// Set on the codec ctx; `nullptr` for non-QSV vendors.
  Pointer<Void> _qsvHwFramesRef;

  /// D3D11 VideoProcessor context for BGRA→NV12 GPU color conversion.
  /// Non-null only when vendor == QSV or MF (Intel iGPU path).
  /// Created during [openWith]; destroyed in [close].
  Pointer<Void> _vpContext;

  bool _closed = false;
  int _nextPts = 0;
  CodecExtraData? _extraData;
  bool _forceKeyframe = false;

  D3d11HwVendor get vendor => _spec.vendor;
  String get encoderName => _spec.encoderName;

  /// The `ID3D11Device*` address used by this encoder (owned by FFmpeg).
  ///
  /// Use this when you need to create or import a texture on the **same**
  /// D3D11 device — required for [D3D11TextureFrameSource], whose
  /// `texturePtr` must be a `ID3D11Texture2D*` on the encoder's device.
  int get d3dDeviceAddress => _d3dDevice.address;

  /// Open the best D3D11VA encoder for [cfg.codec].
  ///
  /// Vendor selection order:
  ///   * If [vendorOrder] is given, it is honoured verbatim.
  ///   * Otherwise, when [existingD3d11Device] is injected, the order is
  ///     derived from that device's DXGI adapter vendor — AMF-first on AMD,
  ///     QSV-first on Intel, NVENC-first on NVIDIA (plus MediaFoundation as
  ///     the universal fallback) — so we never waste a cross-vendor
  ///     `avcodec_open2` on an adapter the vendor can't use (e.g. attempting
  ///     NVENC on an AMD iGPU, which fails with "no encode device" and only
  ///     adds log noise before falling through to AMF).
  ///   * With no device and no explicit order, the global default
  ///     (NVENC → AMF → QSV → MediaFoundation) is used.
  ///
  /// Throws [CodecInitException] on every failure mode (no compatible vendor,
  /// shim missing, GPU init failure). Callers that want a graceful fall-back
  /// to Stage A should catch this and try `FfmpegHwEncoder.open(cfg)`.
  static FfmpegD3d11HwEncoder open(
    EncoderConfig cfg, {
    List<D3d11HwVendor>? vendorOrder,
    int existingD3d11Device = 0,
    D3d11HwSourceFormat sourceTextureFormat = D3d11HwSourceFormat.bgra,
  }) {
    if (!Platform.isWindows) {
      throw const CodecInitException(
        'ffmpeg-d3d11',
        'D3D11VA encoder is Windows-only',
      );
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      throw const CodecInitException(
        'ffmpeg-d3d11',
        'miniav_tools_ffmpeg shim is not loadable — Stage B unavailable. '
            'Run `dart pub get` to rebuild the native asset.',
      );
    }
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg-d3d11',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    // Resolve the vendor order: explicit caller order wins; else derive it
    // from the injected device's adapter IHV so the native encoder is tried
    // first (AMD→AMF, Intel→QSV, NVIDIA→NVENC); else the global default.
    final List<D3d11HwVendor> effectiveOrder;
    if (vendorOrder != null) {
      effectiveOrder = vendorOrder;
    } else if (existingD3d11Device != 0) {
      final vid = shim.d3d11GetVendorId(
        Pointer<Void>.fromAddress(existingD3d11Device),
      );
      effectiveOrder = _vendorOrderForDxgiVendor(vid);
      ffmpegToolsLog(
        MiniAVLogLevel.debug,
        '[ffmpeg-d3d11] open: injected device vendorID='
        '0x${vid.toRadixString(16)} → vendor order '
        '${effectiveOrder.map((v) => v.name).join(' → ')}',
      );
    } else {
      effectiveOrder = _defaultD3d11Order;
    }
    // Try each vendor in priority order. A vendor whose encoder *symbol*
    // exists may still fail at runtime (e.g. AMF on a non-AMD GPU, QSV
    // without an Intel iGPU). Fall through to the next on CodecInitException.
    final attempted = <String>[];
    Object? lastError;
    StackTrace? lastStack;
    for (final vendor in effectiveOrder) {
      final spec = _findSpec(vendor, cfg.codec);
      if (spec == null || !_encoderPresent(ff, spec.encoderName)) {
        attempted.add('${vendor.name}(missing)');
        continue;
      }
      try {
        return openWith(
          cfg,
          vendor,
          existingD3d11Device: existingD3d11Device,
          sourceTextureFormat: sourceTextureFormat,
        );
      } on CodecInitException catch (e, st) {
        attempted.add('${vendor.name}(${e.message})');
        lastError = e;
        lastStack = st;
      } catch (e, st) {
        attempted.add('${vendor.name}($e)');
        lastError = e;
        lastStack = st;
      }
    }
    throw CodecInitException(
      'ffmpeg-d3d11',
      'No working D3D11VA encoder for ${cfg.codec}. Tried: '
          '${attempted.join(' | ')}. Last error: $lastError'
          '${lastStack != null ? '\n$lastStack' : ''}',
    );
  }

  /// Open a specific [vendor] for [cfg.codec].
  ///
  /// [existingD3d11Device] — optional `ID3D11Device*` pointer (as an [int]
  /// address) to inject into FFmpeg's D3D11VA device context instead of
  /// letting FFmpeg create its own device.  Use this when you need both
  /// the encoder and an external GPU API (e.g. Dawn/WebGPU) to operate on
  /// the **same DXGI adapter**, which is required for D3D12→D3D11 NT-handle
  /// texture sharing.  FFmpeg takes ownership (calls `Release()` on cleanup).
  static FfmpegD3d11HwEncoder openWith(
    EncoderConfig cfg,
    D3d11HwVendor vendor, {
    int existingD3d11Device = 0,
    D3d11HwSourceFormat sourceTextureFormat = D3d11HwSourceFormat.bgra,
  }) {
    if (!Platform.isWindows) {
      throw const CodecInitException(
        'ffmpeg-d3d11',
        'D3D11VA encoder is Windows-only',
      );
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      throw const CodecInitException(
        'ffmpeg-d3d11',
        'miniav_tools_ffmpeg shim is not loadable',
      );
    }
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException('ffmpeg-d3d11', 'FFmpeg not loaded');
    }
    // QSV (h264_qsv / hevc_qsv) and MediaFoundation (h264_mf / hevc_mf)
    // both require the calling thread to be in the COM MTA apartment.
    // Flutter's UI isolate is STA by default; this elevates the current
    // thread to MTA before the encoder init touches MFX or IMFTransform.
    // Other vendors (NVENC, AMF) tolerate either apartment.
    if (vendor == D3d11HwVendor.qsv ||
        vendor == D3d11HwVendor.mediafoundation) {
      shim.ensureMta();
    }
    final spec = _findSpec(vendor, cfg.codec);
    if (spec == null) {
      throw CodecInitException(
        'ffmpeg-d3d11',
        '$vendor does not support ${cfg.codec}',
      );
    }
    if (cfg.width > spec.maxWidth || cfg.height > spec.maxHeight) {
      throw CodecInitException(
        'ffmpeg-d3d11',
        '${spec.encoderName} max ${spec.maxWidth}x${spec.maxHeight}, '
            'requested ${cfg.width}x${cfg.height}',
      );
    }
    if (!_encoderPresent(ff, spec.encoderName)) {
      throw CodecInitException(
        'ffmpeg-d3d11',
        '${spec.encoderName} not present in this FFmpeg build',
      );
    }

    // 1) Create (or inject) a D3D11VA hardware device.
    //
    // QSV uses a standalone MFXLoad-based init path (see the try block below)
    // and does NOT go through D3D11 device injection.  hwDeviceRef is set to
    // nullptr here and replaced by the standalone init.
    //
    // For NVENC / AMF / MediaFoundation, when `existingD3d11Device` is
    // non-zero we use the alloc+set+init path so that FFmpeg's D3D11 device
    // is on the SAME DXGI adapter as an external GPU API (e.g. Dawn/WebGPU).
    // Cross-adapter NT-handle sharing always fails with E_INVALIDARG;
    // same-adapter sharing works fine.
    //
    // When no device is provided we fall back to av_hwdevice_ctx_create with
    // a NULL device string so FFmpeg picks adapter 0 (the display adapter).
    Pointer<Void> hwDeviceRef;
    if (vendor == D3d11HwVendor.qsv) {
      // Placeholder — replaced with D3D11VA-from-QSV in the try block.
      hwDeviceRef = nullptr;
    } else if (existingD3d11Device != 0) {
      // Allocate an empty AV_HWDEVICE_TYPE_D3D11VA context, inject the
      // caller's ID3D11Device, then initialise (FFmpeg creates a context).
      //
      // For MediaFoundation the injected device must have been created with
      // D3D11_CREATE_DEVICE_VIDEO_SUPPORT, which Dawn/WebGPU devices lack.
      // We create a sibling device on the SAME adapter with that flag, inject
      // it instead, and release our local ref immediately (d3d11SetDevice
      // AddRefs, so FFmpeg holds the only remaining ref).
      // NT handle sharing is adapter-scoped, so OpenSharedResource1 on the
      // Dawn-originated textures still succeeds from the sibling device.
      final Pointer<Void> deviceToInject;
      Pointer<Void>? siblingToRelease;
      if (vendor == D3d11HwVendor.mediafoundation) {
        final sibling = shim.d3d11CreateVideoDeviceFor(
          Pointer<Void>.fromAddress(existingD3d11Device),
        );
        if (sibling == nullptr) {
          throw CodecInitException(
            'ffmpeg-d3d11',
            '$vendor: failed to create VIDEO_SUPPORT sibling device '
                'on the injected adapter. The driver may not support '
                'D3D11_CREATE_DEVICE_VIDEO_SUPPORT on this GPU.',
          );
        }
        deviceToInject = sibling;
        siblingToRelease = sibling;
      } else {
        deviceToInject = Pointer<Void>.fromAddress(existingD3d11Device);
      }

      final allocRef = ff.avHwdeviceCtxAlloc(kAvHwdeviceTypeD3d11Va);
      if (allocRef == nullptr) {
        if (siblingToRelease != null) shim.d3d11Release(siblingToRelease);
        throw const CodecInitException(
          'ffmpeg-d3d11',
          'av_hwdevice_ctx_alloc(D3D11VA) returned NULL',
        );
      }
      shim.d3d11SetDevice(allocRef, deviceToInject);
      // d3d11SetDevice AddRefs internally — release our own ref to the
      // sibling device (if any) so FFmpeg is the sole owner.
      if (siblingToRelease != null) shim.d3d11Release(siblingToRelease);

      final initRet = ff.avHwdeviceCtxInit(allocRef);
      if (initRet < 0) {
        // av_buffer_unref to free the alloc
        final rp = calloc<Pointer<Void>>()..value = allocRef;
        ff.avBufferUnref(rp);
        calloc.free(rp);
        throw CodecInitException(
          'ffmpeg-d3d11',
          'av_hwdevice_ctx_init(D3D11VA, injected device): '
              '${ff.strError(initRet)} ($initRet)',
        );
      }
      hwDeviceRef = allocRef;
    } else {
      // Let FFmpeg pick adapter 0 (the display adapter).
      final outRef = calloc<Pointer<Void>>();
      final createRet = ff.avHwdeviceCtxCreate(
        outRef,
        kAvHwdeviceTypeD3d11Va,
        nullptr,
        nullptr,
        0,
      );
      hwDeviceRef = outRef.value;
      calloc.free(outRef);
      if (createRet < 0 || hwDeviceRef == nullptr) {
        throw CodecInitException(
          'ffmpeg-d3d11',
          'av_hwdevice_ctx_create(D3D11VA): ${ff.strError(createRet)} '
              '($createRet). No D3D11-capable adapter or driver too old.',
        );
      }
    }

    Pointer<Void> hwFramesRef = nullptr;
    Pointer<Void> qsvHwDeviceRef = nullptr;
    Pointer<Void> qsvHwFramesRef = nullptr;
    Pointer<AVCodecContext> codecCtx = nullptr;
    Pointer<AVPacket> packet = nullptr;

    try {
      // --- QSV standalone init -------------------------------------------
      // QSV uses MFXLoad (oneVPL API) rather than the legacy MFXInitEx +
      // MFXVideoCORE_SetHandle(D3D11_DEVICE) path.  MFXLoad works with both
      // libmfx (legacy MSDK) and oneVPL (Intel 12th-gen+ / Arc GPUs which
      // ship WITHOUT legacy libmfx).  The injection path uses MFXInitEx and
      // therefore always fails on oneVPL-only systems.
      //
      // We create a standalone QSV device first, then derive D3D11VA from it
      // (reverse direction).  hwDeviceRef becomes D3D11VA-from-QSV so that
      // d3dDevice/Context, the hwFrames NV12 pool, and the VideoProcessor are
      // all on QSV's own D3D11 device.
      //
      // Source textures (SharedOutputTexture) carry D3D11_RESOURCE_MISC_SHARED
      // so the VP blit opens them cross-device via GetSharedHandle +
      // OpenSharedResource — no adapter restriction.
      if (vendor == D3d11HwVendor.qsv) {
        final qsvStandaloneOut = calloc<Pointer<Void>>();
        final qsvStandaloneRet = ff.avHwdeviceCtxCreate(
          qsvStandaloneOut,
          kAvHwdeviceTypeQsv,
          nullptr,
          nullptr,
          0,
        );
        qsvHwDeviceRef = qsvStandaloneOut.value;
        calloc.free(qsvStandaloneOut);
        if (qsvStandaloneRet < 0 || qsvHwDeviceRef == nullptr) {
          throw CodecInitException(
            'ffmpeg-d3d11',
            'av_hwdevice_ctx_create(QSV standalone): '
                '${ff.strError(qsvStandaloneRet)} ($qsvStandaloneRet). '
                'Install Intel graphics driver (includes VPL / MSDK runtime).',
          );
        }

        // Derive D3D11VA from QSV (reverse direction).  This exposes QSV's
        // internal D3D11 device so hwFrames + VP are allocated on it.
        final d3d11vaFromQsvOut = calloc<Pointer<Void>>();
        final d3d11vaFromQsvRet = ff.avHwdeviceCtxCreateDerived(
          d3d11vaFromQsvOut,
          kAvHwdeviceTypeD3d11Va,
          qsvHwDeviceRef,
          0,
        );
        hwDeviceRef = d3d11vaFromQsvOut.value;
        calloc.free(d3d11vaFromQsvOut);
        if (d3d11vaFromQsvRet < 0 || hwDeviceRef == nullptr) {
          throw CodecInitException(
            'ffmpeg-d3d11',
            'av_hwdevice_ctx_create_derived(D3D11VA from QSV): '
                '${ff.strError(d3d11vaFromQsvRet)} ($d3d11vaFromQsvRet).',
          );
        }
        ffmpegToolsLog(
          MiniAVLogLevel.debug,
          '[ffmpeg-d3d11] QSV standalone init OK: '
          'hwDeviceRef(D3D11VA)=0x${hwDeviceRef.address.toRadixString(16)} '
          'qsvHwDeviceRef=0x${qsvHwDeviceRef.address.toRadixString(16)}',
        );
      }

      final d3dDevice = shim.d3d11GetDevice(hwDeviceRef);
      final d3dContext = shim.d3d11GetContext(hwDeviceRef);
      if (d3dDevice == nullptr || d3dContext == nullptr) {
        throw const CodecInitException(
          'ffmpeg-d3d11',
          'shim could not retrieve ID3D11Device/Context from FFmpeg-owned '
              'AVHWDeviceContext (corrupt or wrong-platform shim build)',
        );
      }
      ffmpegToolsLog(
        MiniAVLogLevel.debug,
        '[ffmpeg-d3d11] openWith: d3dDevice=0x${d3dDevice.address.toRadixString(16)} '
        '${vendor == D3d11HwVendor.qsv
            ? "[QSV standalone — Intel device via MFXLoad]"
            : existingD3d11Device != 0
            ? (vendor == D3d11HwVendor.mediafoundation ? "[VIDEO_SUPPORT sibling — same adapter as Dawn GPU]" : "[injected — same device as Dawn GPU]")
            : "[FFmpeg-created — display adapter (adapter 0)]"}'
        '\n  Compare with [minigpu_external] ID3D11Device and [shim] luid= logs.',
      );

      // Resolve AV_PIX_FMT_D3D11 dynamically (enum values shift between
      // libavutil majors). Fall back to the documented value if name lookup
      // fails — that path also fails the encoder open, which is fine.
      final d3dName = 'd3d11'.toNativeUtf8();
      var d3dPixFmt = ff.avGetPixFmtByName(d3dName);
      calloc.free(d3dName);
      if (d3dPixFmt < 0) d3dPixFmt = _avPixFmtD3d11Fallback;

      // SW-format: the DXGI texture format for the hwframes pool.
      //
      // For NVENC / AMF: use BGRA (or RGBA) to match the source texture format
      // exactly.  CopySubresourceRegion requires matching DXGI format groups,
      // so src and dst must be the same.
      //
      // For QSV / MediaFoundation (Intel iGPU): those encoders reject BGRA
      // frames at avcodec_send_frame (AVERROR_EXTERNAL).  They require NV12.
      // We allocate an NV12 pool and use a D3D11 VideoProcessor to convert
      // BGRA→NV12 in GPU memory.  The VP runs on the VIDEO_SUPPORT sibling
      // device, making the Intel GPU do the full encode path without ever
      // touching system RAM.
      final needsNv12ForVp =
          vendor == D3d11HwVendor.qsv ||
          vendor == D3d11HwVendor.mediafoundation ||
          // AMF: BGRA D3D11 input is broken on real AMD hardware — AMD iGPUs
          // reject BGRA frames at avcodec_send_frame ("Unknown error"), and
          // some dGPU/driver combos accept them but silently encode black.
          // AMF's native input format is NV12, so always feed it through the
          // same VideoProcessor BGRA→NV12 path QSV/MF use (fixed-function,
          // no shader-core cost).
          vendor == D3d11HwVendor.amf;
      final swFmtName = needsNv12ForVp
          ? 'nv12'
          : (sourceTextureFormat == D3d11HwSourceFormat.rgba ? 'rgba' : 'bgra');
      final swNamePtr = swFmtName.toNativeUtf8();
      final bgraFmt = ff.avGetPixFmtByName(swNamePtr);
      calloc.free(swNamePtr);
      if (bgraFmt < 0) {
        throw CodecInitException(
          'ffmpeg-d3d11',
          'av_get_pix_fmt("$swFmtName") failed',
        );
      }
      // 2) Allocate + init the hwframes pool against the hwdev context.
      //
      // For the VP (NV12) path the pool's bind flags are driver-sensitive:
      // Intel wants SHADER_RESOURCE|RENDER_TARGET|DECODER|VIDEO_ENCODER, but
      // AMD rejects the DECODER|RENDER_TARGET combination with E_INVALIDARG
      // (0x80070057), and some drivers also balk at VIDEO_ENCODER. Rather
      // than hard-coding per-vendor tables, try flag sets from richest to
      // minimal (RENDER_TARGET is the hard requirement — VP writes to it),
      // re-allocating the frames ctx per attempt (a failed init poisons it).
      final bindFlagCandidates = !needsNv12ForVp
          ? const <int?>[null] // BGRA pool: FFmpeg's defaults, single attempt
          : <int>[
              if (vendor != D3d11HwVendor.amf)
                0x08 | 0x20 | 0x200 | 0x400, // Intel-tuned combo (QSV/MF)
              0x08 | 0x20 | 0x400, // SR | RT | VIDEO_ENCODER
              0x08 | 0x20, // SR | RT (minimum for VP output)
            ];
      var framesInit = -1;
      for (final bindFlags in bindFlagCandidates) {
        hwFramesRef = ff.avHwframeCtxAlloc(hwDeviceRef);
        if (hwFramesRef == nullptr) {
          throw const CodecInitException(
            'ffmpeg-d3d11',
            'av_hwframe_ctx_alloc returned NULL',
          );
        }
        final framesData = shim.hwFramesData(hwFramesRef);
        shim.hwFramesSetParams(
          framesData,
          format: d3dPixFmt,
          swFormat: bgraFmt,
          width: cfg.width,
          height: cfg.height,
          // Pool size must cover encoder reorder + our own in-flight count.
          // 8 is the FFmpeg-recommended floor for typical low-latency configs.
          initialPoolSize: 8,
        );
        if (bindFlags != null) {
          shim.d3d11vaFramesSetBindFlags(hwFramesRef, bindFlags);
        }
        framesInit = ff.avHwframeCtxInit(hwFramesRef);
        if (framesInit >= 0) {
          if (needsNv12ForVp && bindFlags != bindFlagCandidates.first) {
            ffmpegToolsLog(
              MiniAVLogLevel.info,
              '[ffmpeg-d3d11] NV12 pool init succeeded with reduced bind '
              'flags 0x${bindFlags!.toRadixString(16)} (driver rejected the '
              'richer combination).',
            );
          }
          break;
        }
        // Failed — free the poisoned ctx and try the next flag set.
        final rp = calloc<Pointer<Void>>()..value = hwFramesRef;
        ff.avBufferUnref(rp);
        calloc.free(rp);
        hwFramesRef = nullptr;
        ffmpegToolsLog(
          MiniAVLogLevel.debug,
          '[ffmpeg-d3d11] av_hwframe_ctx_init failed with bind flags '
          '${bindFlags != null ? "0x${bindFlags.toRadixString(16)}" : "(default)"}: '
          '${ff.strError(framesInit)} ($framesInit).',
        );
      }
      if (framesInit < 0 || hwFramesRef == nullptr) {
        throw CodecInitException(
          'ffmpeg-d3d11',
          'av_hwframe_ctx_init: ${ff.strError(framesInit)} ($framesInit). '
              '${needsNv12ForVp ? "NV12 D3D11 pool init failed with every bind-flag set — VP BGRA→NV12 path unavailable." : "Likely BGRA D3D11 textures unsupported on this adapter."}',
        );
      }

      // Create VideoProcessor for BGRA→NV12 when using the QSV/MF path.
      // The VP runs on the VIDEO_SUPPORT sibling device (d3dDevice here is
      // the sibling, not Dawn's device) and converts BGRA screen frames to
      // NV12 entirely in GPU memory.
      Pointer<Void> vpContext = nullptr;
      if (needsNv12ForVp) {
        vpContext = shim.d3d11VpCreate(
          d3dDevice,
          d3dContext,
          cfg.width,
          cfg.height,
        );
        if (vpContext == nullptr) {
          throw const CodecInitException(
            'ffmpeg-d3d11',
            'D3D11 VideoProcessor creation failed for BGRA→NV12 conversion. '
                'The VIDEO_SUPPORT sibling device may not support VideoProcessor '
                'on this adapter. GPU path unavailable; use CPU encoder instead.',
          );
        }
        ffmpegToolsLog(
          MiniAVLogLevel.info,
          '[ffmpeg-d3d11] openWith: VideoProcessor BGRA→NV12 created for '
          '${spec.encoderName} — Intel iGPU GPU zero-copy path active.',
        );
      }

      // QSV requires a derived QSV hwdevice + hwframes context layered on top
      // of the D3D11VA hwdevice + hwframes context.  The derived QSV hwframes
      // pool shares the same D3D11 textures as the D3D11VA pool, so
      // CopySubresourceRegion targets the D3D11VA frame and the QSV encoder
      // reads the same memory via the mfxFrameSurface1 wrapper.
      var codecPixFmt = d3dPixFmt; // overridden to QSV pixel fmt for QSV vendor
      var codecHwFramesRef = hwFramesRef; // overridden to QSV frames for QSV

      if (spec.vendor == D3d11HwVendor.qsv) {
        // Resolve AV_PIX_FMT_QSV dynamically.
        final qsvFmtNamePtr = 'qsv'.toNativeUtf8();
        final qsvPixFmt = ff.avGetPixFmtByName(qsvFmtNamePtr);
        calloc.free(qsvFmtNamePtr);
        if (qsvPixFmt < 0) {
          throw const CodecInitException(
            'ffmpeg-d3d11',
            'av_get_pix_fmt("qsv") returned -1 — QSV is not compiled into '
                'this FFmpeg build',
          );
        }

        // qsvHwDeviceRef was set in the standalone init block above.
        // Derive QSV hwframes from D3D11VA hwframes — the derived pool shares
        // the same D3D11 NV12 textures allocated on QSV's own device.
        final qsvFramesOut = calloc<Pointer<Void>>();
        final qsvFramesRet = ff.avHwframeCtxCreateDerived(
          qsvFramesOut,
          qsvPixFmt,
          qsvHwDeviceRef,
          hwFramesRef,
          0,
        );
        qsvHwFramesRef = qsvFramesOut.value;
        calloc.free(qsvFramesOut);
        if (qsvFramesRet < 0 || qsvHwFramesRef == nullptr) {
          throw CodecInitException(
            'ffmpeg-d3d11',
            'av_hwframe_ctx_create_derived(QSV): '
                '${ff.strError(qsvFramesRet)} ($qsvFramesRet)',
          );
        }

        codecPixFmt = qsvPixFmt;
        codecHwFramesRef = qsvHwFramesRef;
      }

      // 3) Allocate + configure the encoder's AVCodecContext.
      final namePtr = spec.encoderName.toNativeUtf8();
      Pointer<AVCodec> codec;
      try {
        codec = ff.avcodecFindEncoderByName(namePtr);
      } finally {
        calloc.free(namePtr);
      }
      codecCtx = ff.avcodecAllocContext3(codec);
      if (codecCtx == address(0)) {
        throw const CodecInitException(
          'ffmpeg-d3d11',
          'avcodec_alloc_context3 returned NULL',
        );
      }

      _configureCtx(ff, codecCtx, cfg, spec, codecPixFmt);

      // Hand the codec ctx its own ref to the hwframes context. The shim
      // calls av_buffer_ref internally — we keep `hwFramesRef` for cleanup.
      // For QSV, the codec ctx gets the derived QSV hwframes; D3D11VA hwframes
      // are kept separately for av_hwframe_get_buffer in encode().
      shim.setHwFramesCtx(codecCtx.cast<Void>(), codecHwFramesRef);

      final openRet = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (openRet < 0) {
        throw CodecInitException(
          'ffmpeg-d3d11',
          'avcodec_open2(${spec.encoderName}) failed: '
              '${ff.strError(openRet)} ($openRet). The vendor runtime '
              '(amfrt64.dll / libmfx / mfreadwrite.dll) may be missing or '
              'incompatible.',
        );
      }

      packet = ff.avPacketAlloc();
      if (packet == address(0)) {
        throw const CodecInitException(
          'ffmpeg-d3d11',
          'av_packet_alloc returned NULL',
        );
      }

      final enc = FfmpegD3d11HwEncoder._(
        ff,
        shim,
        cfg,
        spec,
        codecCtx,
        packet,
        hwDeviceRef,
        hwFramesRef,
        d3dDevice,
        d3dContext,
        codecPixFmt,
        qsvHwDeviceRef,
        qsvHwFramesRef,
        vpContext,
      ).._loadExtraData();
      // Ownership of refs / codec ctx / packet is now in the instance.
      hwDeviceRef = nullptr;
      hwFramesRef = nullptr;
      qsvHwDeviceRef = nullptr;
      qsvHwFramesRef = nullptr;
      codecCtx = nullptr;
      packet = nullptr;
      return enc;
    } catch (_) {
      // Best-effort cleanup of partially-initialised state.
      if (packet != nullptr) {
        final pp = calloc<Pointer<AVPacket>>()..value = packet;
        ff.avPacketFree(pp);
        calloc.free(pp);
      }
      if (codecCtx != nullptr) {
        final cp = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
        ff.avcodecFreeContext(cp);
        calloc.free(cp);
      }
      // Release derived QSV refs before base D3D11VA refs (derived must be
      // freed first so the base retains a positive ref count).
      if (qsvHwFramesRef != nullptr) {
        final wrap = calloc<Pointer<Void>>()..value = qsvHwFramesRef;
        ff.avBufferUnref(wrap);
        calloc.free(wrap);
      }
      if (qsvHwDeviceRef != nullptr) {
        final wrap = calloc<Pointer<Void>>()..value = qsvHwDeviceRef;
        ff.avBufferUnref(wrap);
        calloc.free(wrap);
      }
      if (hwFramesRef != nullptr) {
        final rp = calloc<Pointer<Pointer<Void>>>().cast<Pointer<Void>>();
        // av_buffer_unref takes AVBufferRef** — wrap manually.
        final wrap = calloc<Pointer<Void>>()..value = hwFramesRef;
        ff.avBufferUnref(wrap);
        calloc.free(wrap);
        calloc.free(rp);
      }
      if (hwDeviceRef != nullptr) {
        final wrap = calloc<Pointer<Void>>()..value = hwDeviceRef;
        ff.avBufferUnref(wrap);
        calloc.free(wrap);
      }
      rethrow;
    }
  }

  static void _configureCtx(
    Ffmpeg ff,
    Pointer<AVCodecContext> ctx,
    EncoderConfig cfg,
    _D3d11Spec spec,
    int d3dPixFmt,
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

    void setIntStrict(String key, int val) {
      final k = key.toNativeUtf8();
      try {
        final r = ff.avOptSetInt(ctxV, k, val, 0);
        if (r < 0) {
          throw CodecInitException(
            'ffmpeg-d3d11',
            'av_opt_set_int($key=$val): ${ff.strError(r)} ($r)',
          );
        }
      } finally {
        calloc.free(k);
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
            'ffmpeg-d3d11',
            'av_opt_set_q($key=$num/$den): ${ff.strError(ret)} ($ret)',
          );
        }
      } finally {
        calloc.free(k);
        calloc.free(r);
      }
    }

    setStr('video_size', '${cfg.width}x${cfg.height}');

    // Pixel format MUST be the hardware enum AV_PIX_FMT_D3D11 — that is
    // how the codec knows to consume textures rather than CPU planes.
    final pkKey = 'pixel_format'.toNativeUtf8();
    try {
      final r = ff.avOptSetPixelFmt(ctxV, pkKey, d3dPixFmt, 1);
      if (r < 0) {
        throw CodecInitException(
          'ffmpeg-d3d11',
          'av_opt_set_pixel_fmt(d3d11): ${ff.strError(r)} ($r)',
        );
      }
    } finally {
      calloc.free(pkKey);
    }

    setIntStrict('b', cfg.bitrateBps);
    if (cfg.gopLength > 0) setIntStrict('g', cfg.gopLength);
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

    final defaults = <String, String>{...spec.defaults};
    if (cfg.rateControl == RateControl.crf && cfg.crfQuality != null) {
      switch (spec.vendor) {
        case D3d11HwVendor.nvenc:
          // NVENC: 'cq' is constant-quality VBR, 'qp' is fixed-QP CQP.
          // Use cq for CRF semantics (target visual quality, variable bps).
          defaults['rc'] = 'vbr';
          defaults['cq'] = cfg.crfQuality!.toString();
          break;
        case D3d11HwVendor.qsv:
          defaults['global_quality'] = cfg.crfQuality!.toString();
          break;
        case D3d11HwVendor.amf:
          defaults['rc'] = 'cqp';
          defaults['qp_i'] = cfg.crfQuality!.toString();
          defaults['qp_p'] = cfg.crfQuality!.toString();
          break;
        case D3d11HwVendor.mediafoundation:
          break;
      }
    } else if (cfg.rateControl == RateControl.vbr) {
      if (spec.vendor == D3d11HwVendor.amf) {
        defaults.putIfAbsent('rc', () => 'vbr_peak');
      } else if (spec.vendor == D3d11HwVendor.nvenc) {
        defaults['rc'] = 'vbr';
      }
    } else if (cfg.rateControl == RateControl.cbr) {
      if (spec.vendor == D3d11HwVendor.amf) {
        defaults.putIfAbsent('rc', () => 'cbr');
      } else if (spec.vendor == D3d11HwVendor.nvenc) {
        defaults['rc'] = 'cbr';
      }
    }

    defaults.forEach((k, v) {
      if (!cfg.backendOptions.containsKey(k)) setStr(k, v);
    });
    cfg.backendOptions.forEach((k, v) {
      if (k == 'global_header' || k == 'zerocopy') return;
      setStr(k, v);
    });
  }

  // --- PlatformEncoder ------------------------------------------------------

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> requestKeyframe() async {
    _forceKeyframe = true;
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _checkOpen();

    // There are two ways the caller can supply a GPU-side D3D11 texture:
    //
    //   (A) D3D11TextureFrameSource: `texturePtr` is an already-opened
    //       ID3D11Texture2D* that lives on the SAME ID3D11Device as this
    //       encoder. We use it directly — no OpenSharedResource1.
    //
    //   (B) MiniAVBufferSource (gpuD3D11Handle): `nativeHandles[0]` is an
    //       NT HANDLE for a process-shared D3D11 texture. We must call
    //       OpenSharedResource1 to materialise it on our own device, and
    //       Release the resulting interface after the per-frame copy.
    //
    // In both cases we do GPU-only CopySubresourceRegion + fence into a
    // pool-allocated AVFrame, then send to the codec.
    Pointer<Void> srcTex = nullptr;
    bool ownsSrcTex = false; // true => Release after use
    int subresource = 0;

    switch (frame) {
      case D3D11TextureFrameSource():
        if (frame.texturePtr == 0) {
          throw const CodecRuntimeException(
            'ffmpeg-d3d11',
            'D3D11TextureFrameSource has null texturePtr',
          );
        }
        srcTex = Pointer<Void>.fromAddress(frame.texturePtr);
        subresource = frame.subresourceIndex;
        ownsSrcTex = false;
        break;
      case MiniAVBufferSource():
        final ntHandle = _extractNtHandle(frame);
        if (ntHandle == nullptr) {
          throw const CodecRuntimeException(
            'ffmpeg-d3d11',
            'MiniAVBufferSource for D3D11 zero-copy encoder requires '
                'contentType=gpuD3D11Handle and a non-null NT handle in '
                'nativeHandles[0].',
          );
        }
        subresource = _extractSubresourceIndex(frame);
        // Open the NT-shared handle on FFmpeg's device. Each open returns
        // a fresh ID3D11Texture2D* with refcount 1 — we MUST Release it
        // before the next frame (failing to do so leaks GPU memory and
        // eventually crashes the driver after a few thousand frames).
        srcTex = _shim.d3d11OpenSharedHandle(_d3dDevice, ntHandle);
        if (srcTex == nullptr) {
          throw const CodecRuntimeException(
            'ffmpeg-d3d11',
            'OpenSharedResource1 failed — handle may be from a different '
                'D3D11 adapter or already closed',
          );
        }
        ownsSrcTex = true;
        break;
      default:
        throw const CodecRuntimeException(
          'ffmpeg-d3d11',
          'D3D11 zero-copy encoder requires a D3D11TextureFrameSource OR a '
              'MiniAVBufferSource with contentType=gpuD3D11Handle. Use '
              'FfmpegHwEncoder for CPU-input frames.',
        );
    }

    if (frame.width != _cfg.width || frame.height != _cfg.height) {
      if (ownsSrcTex) _shim.d3d11Release(srcTex);
      throw CodecRuntimeException(
        'ffmpeg-d3d11',
        'Frame ${frame.width}x${frame.height} != encoder '
            '${_cfg.width}x${_cfg.height}',
      );
    }

    Pointer<AVFrame> hwFrame = nullptr;
    Pointer<AVFrame> qsvFrame = nullptr;
    try {
      hwFrame = _ff.avFrameAlloc();
      if (hwFrame == address(0)) {
        throw const CodecRuntimeException(
          'ffmpeg-d3d11',
          'av_frame_alloc returned NULL',
        );
      }

      // av_hwframe_get_buffer pulls a free pool texture into the AVFrame.
      // After this call: data[0]=ID3D11Texture2D*, data[1]=subresource idx
      // (as integer cast to pointer), hw_frames_ctx is bound to D3D11VA frames.
      final gb = _ff.avHwframeGetBuffer(_hwFramesRef, hwFrame, 0);
      if (gb < 0) {
        throw CodecRuntimeException(
          'ffmpeg-d3d11',
          'av_hwframe_get_buffer: ${_ff.strError(gb)} ($gb). Pool exhausted '
              '— consumer is not draining packets fast enough.',
        );
      }

      // Pure GPU copy (NVENC/AMF) or VideoProcessor BGRA→NV12 blt (QSV/MF).
      final dstTex = hwFrame.ref.data0.cast<Void>();
      final dstSlice = hwFrame.ref.data1.address;
      if (_vpContext != nullptr) {
        // Intel QSV/MF path: D3D11 VideoProcessor converts BGRA→NV12 on the
        // VIDEO_SUPPORT sibling device.
        //
        // D3D11TextureFrameSource: srcTex is on Dawn's ID3D11Device (different
        // from the sibling).  The shim opens it via GetSharedHandle +
        // OpenSharedResource internally (cross_device=1).  Requires
        // D3D11_RESOURCE_MISC_SHARED on the SharedOutputTexture (see
        // minigpu_external.cpp create_shared_output_texture).
        //
        // MiniAVBufferSource: srcTex is already on the sibling device (opened
        // via OpenSharedResource1 / NT handle above).  cross_device=0.
        final vpRet = _shim.d3d11VpBgraToNv12(
          _vpContext,
          _d3dDevice,
          _d3dContext,
          srcTex,
          crossDevice:
              !ownsSrcTex, // ownsSrcTex=true → srcTex on sibling already
          dstSubresource: dstSlice,
          dstNv12Tex: dstTex,
        );
        if (vpRet < 0) {
          throw CodecRuntimeException(
            'ffmpeg-d3d11',
            'D3D11 VideoProcessor BGRA→NV12 blt failed: $vpRet. '
                'Check shim logs for hr= detail.',
          );
        }
      } else {
        _shim.d3d11CopyResource(
          _d3dDevice,
          _d3dContext,
          dstTex,
          dstSlice,
          srcTex,
          subresource,
        );
      }

      // For QSV: the encoder needs a QSV-format frame (mfxFrameSurface1
      // wrapper) rather than a raw D3D11VA frame.  We map the D3D11VA frame
      // to a new QSV frame that references the same underlying texture via
      // the derived hwframes relationship.  The copy above has already written
      // into the D3D11VA texture, so the QSV frame automatically sees it.
      Pointer<AVFrame> frameToSend;
      if (_qsvHwFramesRef != nullptr) {
        qsvFrame = _ff.avFrameAlloc();
        if (qsvFrame == address(0)) {
          throw const CodecRuntimeException(
            'ffmpeg-d3d11',
            'av_frame_alloc for QSV frame returned NULL',
          );
        }
        // Set hw_frames_ctx on qsvFrame so av_hwframe_map can resolve the
        // QSV hwframes context (needed to pick the correct mapping path).
        _shim.avFrameSetHwFramesCtx(qsvFrame.cast<Void>(), _qsvHwFramesRef);
        final mapRet = _ff.avHwframeMap(
          qsvFrame,
          hwFrame,
          kAvHwframeMapRead | kAvHwframeMapDirect,
        );
        if (mapRet < 0) {
          throw CodecRuntimeException(
            'ffmpeg-d3d11',
            'av_hwframe_map(D3D11VA→QSV): ${_ff.strError(mapRet)} ($mapRet)',
          );
        }
        frameToSend = qsvFrame;
      } else {
        frameToSend = hwFrame;
      }

      frameToSend.ref
        ..width = _cfg.width
        ..height = _cfg.height
        ..format = _d3dPixFmt
        ..pts = _nextPts++
        ..pictType = _forceKeyframe ? 1 /* AV_PICTURE_TYPE_I */ : 0;
      _forceKeyframe = false;

      final sendRet = _ff.avcodecSendFrame(_codecCtx, frameToSend);
      if (sendRet < 0 && sendRet != kAvErrorEAgain) {
        throw CodecRuntimeException(
          'ffmpeg-d3d11',
          'avcodec_send_frame: ${_ff.strError(sendRet)} ($sendRet)',
        );
      }
    } finally {
      if (qsvFrame != nullptr) {
        _ff.avFrameUnref(qsvFrame);
        final fp = calloc<Pointer<AVFrame>>()..value = qsvFrame;
        _ff.avFrameFree(fp);
        calloc.free(fp);
      }
      if (hwFrame != nullptr) {
        _ff.avFrameUnref(hwFrame);
        final fp = calloc<Pointer<AVFrame>>()..value = hwFrame;
        _ff.avFrameFree(fp);
        calloc.free(fp);
      }
      if (ownsSrcTex && srcTex != nullptr) {
        _shim.d3d11Release(srcTex);
      }
    }

    return _drainOne();
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final ret = _ff.avcodecSendFrame(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg-d3d11',
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

  /// Probe whether the opened encoder will actually ACCEPT a frame from
  /// the hwframes pool. This is meaningfully different from "the codec
  /// opened successfully": on Intel iGPUs h264_qsv / h264_mf typically
  /// require NV12 input and reject our BGRA pool with AVERROR_EXTERNAL on
  /// every avcodec_send_frame, even though avcodec_open2 returned 0.
  ///
  /// We allocate a single pool frame (no source-texture copy needed —
  /// uninitialised contents are fine for input-format validation), set
  /// width/height/format/pts/hw_frames_ctx, then call avcodec_send_frame.
  /// AVERROR_EXTERNAL or any other negative non-EAGAIN return ⇒ vendor
  /// rejects this input format ⇒ caller should fall back to CPU.
  ///
  /// Returns true on send success or EAGAIN (encoder accepted but
  /// internal buffer full — still indicates format compatibility).
  bool _probeAcceptsHwFrame() {
    if (_closed) return false;
    Pointer<AVFrame> hwFrame = nullptr;
    Pointer<AVFrame> qsvFrame = nullptr;
    try {
      hwFrame = _ff.avFrameAlloc();
      if (hwFrame == address(0)) return false;
      final gb = _ff.avHwframeGetBuffer(_hwFramesRef, hwFrame, 0);
      if (gb < 0) return false;

      Pointer<AVFrame> frameToSend;
      if (_qsvHwFramesRef != nullptr) {
        qsvFrame = _ff.avFrameAlloc();
        if (qsvFrame == address(0)) return false;
        _shim.avFrameSetHwFramesCtx(qsvFrame.cast<Void>(), _qsvHwFramesRef);
        final mapRet = _ff.avHwframeMap(
          qsvFrame,
          hwFrame,
          kAvHwframeMapRead | kAvHwframeMapDirect,
        );
        if (mapRet < 0) return false;
        frameToSend = qsvFrame;
      } else {
        frameToSend = hwFrame;
      }

      frameToSend.ref
        ..width = _cfg.width
        ..height = _cfg.height
        ..format = _d3dPixFmt
        ..pts = 0;

      final sendRet = _ff.avcodecSendFrame(_codecCtx, frameToSend);
      if (sendRet == 0 || sendRet == kAvErrorEAgain) {
        // Drain any packet the encoder may have produced so the codec
        // state is clean on close (best effort — ignore errors).
        try {
          _ff.avcodecReceivePacket(_codecCtx, _packet);
          _ff.avPacketUnref(_packet);
        } catch (_) {
          /* ignore */
        }
        // Send EOF so flush() during close() doesn't hit a weird state.
        try {
          _ff.avcodecSendFrame(_codecCtx, nullptr);
          while (_ff.avcodecReceivePacket(_codecCtx, _packet) >= 0) {
            _ff.avPacketUnref(_packet);
          }
        } catch (_) {
          /* ignore */
        }
        return true;
      }
      ffmpegToolsLog(
        MiniAVLogLevel.info,
        '[ffmpeg-d3d11] _probeAcceptsHwFrame(${_spec.encoderName}): '
        'avcodec_send_frame returned $sendRet (${_ff.strError(sendRet)}). '
        'Vendor likely refuses BGRA D3D11 input — falling back to CPU.',
      );
      return false;
    } catch (e) {
      ffmpegToolsLog(
        MiniAVLogLevel.warn,
        '[ffmpeg-d3d11] _probeAcceptsHwFrame(${_spec.encoderName}) threw: $e',
      );
      return false;
    } finally {
      if (qsvFrame != nullptr) {
        _ff.avFrameUnref(qsvFrame);
        final fp = calloc<Pointer<AVFrame>>()..value = qsvFrame;
        _ff.avFrameFree(fp);
        calloc.free(fp);
      }
      if (hwFrame != nullptr) {
        _ff.avFrameUnref(hwFrame);
        final fp = calloc<Pointer<AVFrame>>()..value = hwFrame;
        _ff.avFrameFree(fp);
        calloc.free(fp);
      }
    }
  }

  @override
  bool get supportsGpuBufferInput => false;

  // D3D11 zero-copy encoder consumes an RGBA D3D11 texture, not YUV420P planes.
  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pp = calloc<Pointer<AVPacket>>()..value = _packet;
    final cp = calloc<Pointer<AVCodecContext>>()..value = _codecCtx;
    try {
      _ff.avPacketFree(pp);
      _ff.avcodecFreeContext(cp);
    } finally {
      calloc.free(pp);
      calloc.free(cp);
    }
    // Destroy VideoProcessor context before releasing D3D11 device refs.
    if (_vpContext != nullptr) {
      _shim.d3d11VpDestroy(_vpContext);
      _vpContext = nullptr;
    }
    // Release derived QSV refs before base D3D11VA refs.
    if (_qsvHwFramesRef != nullptr) {
      final wrap = calloc<Pointer<Void>>()..value = _qsvHwFramesRef;
      _ff.avBufferUnref(wrap);
      calloc.free(wrap);
      _qsvHwFramesRef = nullptr;
    }
    if (_qsvHwDeviceRef != nullptr) {
      final wrap = calloc<Pointer<Void>>()..value = _qsvHwDeviceRef;
      _ff.avBufferUnref(wrap);
      calloc.free(wrap);
      _qsvHwDeviceRef = nullptr;
    }
    if (_hwFramesRef != nullptr) {
      final wrap = calloc<Pointer<Void>>()..value = _hwFramesRef;
      _ff.avBufferUnref(wrap);
      calloc.free(wrap);
      _hwFramesRef = nullptr;
    }
    if (_hwDeviceRef != nullptr) {
      final wrap = calloc<Pointer<Void>>()..value = _hwDeviceRef;
      _ff.avBufferUnref(wrap);
      calloc.free(wrap);
      _hwDeviceRef = nullptr;
    }
  }

  @override
  Pointer<AVCodecContext> get nativeCodecContext => _codecCtx;

  // --- Internals ------------------------------------------------------------

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-d3d11', 'encoder closed');
    }
  }

  Pointer<Void> _extractNtHandle(FrameSource src) {
    switch (src) {
      case D3D11TextureFrameSource():
        return Pointer<Void>.fromAddress(src.texturePtr);
      case MiniAVBufferSource():
        if (src.buffer.contentType != MiniAVBufferContentType.gpuD3D11Handle) {
          return nullptr;
        }
        final video = src.buffer.data;
        if (video is! MiniAVVideoBuffer) return nullptr;
        if (video.nativeHandles.isEmpty) return nullptr;
        final h = video.nativeHandles.first;
        if (h is Pointer) return h.cast<Void>();
        if (h is int) return Pointer<Void>.fromAddress(h);
        return nullptr;
      default:
        return nullptr;
    }
  }

  int _extractSubresourceIndex(FrameSource src) {
    switch (src) {
      case D3D11TextureFrameSource():
        return src.subresourceIndex;
      case MiniAVBufferSource():
        // miniav exposes subresource_index per plane in the C struct, but
        // the Dart wrapper does not propagate it today (planes[0].offset
        // is set instead for DXGI). Default to 0 — the screen capture
        // backend always uses subresource 0.
        return 0;
      default:
        return 0;
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
        'ffmpeg-d3d11',
        'avcodec_receive_packet: ${_ff.strError(ret)} ($ret)',
      );
    }
    final p = _packet.ref;
    final bytes = Uint8List(p.size);
    final src = p.data.asTypedList(p.size);
    bytes.setRange(0, p.size, src);

    final usPerFrame =
        (1000000 * _cfg.frameRateDenominator) ~/ _cfg.frameRateNumerator;
    final pkt = EncodedPacket(
      data: bytes,
      ptsUs: p.pts * usPerFrame,
      dtsUs: (p.dts == _avNoPts ? p.pts : p.dts) * usPerFrame,
      durationUs: p.duration * usPerFrame,
      isKeyframe: (p.flags & kPktFlagKey) != 0,
    );
    _ff.avPacketUnref(_packet);
    return pkt;
  }
}

const int _avNoPts = -0x8000000000000000;
