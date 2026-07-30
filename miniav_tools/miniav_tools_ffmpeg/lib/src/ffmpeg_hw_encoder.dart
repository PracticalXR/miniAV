/// Generic FFmpeg hardware-encoder wrapper (Stage A — packed RGB / NV12
/// software input, GPU does the colour conversion + entropy coding).
///
/// Covers all the major desktop / mobile vendors:
///
/// | Vendor          | Encoder names                                     | Input fmt  | Notes                          |
/// |-----------------|---------------------------------------------------|------------|--------------------------------|
/// | NVIDIA NVENC    | h264_nvenc / hevc_nvenc / av1_nvenc               | bgr0/rgb0  | preset p1..p7, tune hq/ll/ull  |
/// | AMD AMF (Win)   | h264_amf / hevc_amf / av1_amf                     | nv12/bgra  | usage=transcoding/ultralowlat. |
/// | Intel QSV       | h264_qsv / hevc_qsv / av1_qsv / vp9_qsv           | nv12/bgra  | preset veryfast..veryslow      |
/// | Apple VideoTb.  | h264_videotoolbox / hevc_videotoolbox             | nv12       | realtime=1, allow_sw=1         |
/// | MediaFoundation | h264_mf / hevc_mf (Win, ARM64 useful)             | nv12       | auto MFT (sw fallback ok)      |
/// | V4L2 M2M        | h264_v4l2m2m / hevc_v4l2m2m (Linux/RPi)           | nv12       |                                |
///
/// **Resolution caps** (typical, varies by GPU generation):
/// - h264_nvenc / h264_amf / h264_qsv: 4096
/// - hevc / av1 variants: 8192
///
/// Use [FfmpegHwEncoder.open] directly, or let [FfmpegBackend.createEncoder]
/// pick the best available vendor. For widths > 4096 (e.g. 5120 ultrawide),
/// callers should request `VideoCodec.hevc` instead of `h264`.
library;

import 'dart:ffi';
import 'dart:typed_data';
import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:minigpu_platform_interface/minigpu_platform_interface.dart'
    show MinigpuPlatform, PlatformBuffer, PlatformComputeShader, BufferDataType;

import 'ffmpeg_encoder.dart' show address;
import 'ffmpeg_ffi.dart';
import 'ffmpeg_log.dart';
import 'ffmpeg_muxer.dart' show FfmpegEncoderBridge;
import 'ffmpeg_shim.dart';
import 'pixel_convert.dart';

/// Hardware encoder vendor / FFmpeg backend family.
enum HwEncoderVendor {
  /// NVIDIA NVENC (`*_nvenc`). Windows + Linux. Requires NVIDIA driver +
  /// `nvEncodeAPI64.dll` / `libnvidia-encode.so`.
  nvenc,

  /// AMD AMF (`*_amf`). Windows; AMD driver provides `amfrt64.dll`.
  amf,

  /// Intel Quick Sync Video (`*_qsv`). Windows + Linux; requires libmfx /
  /// oneVPL runtime.
  qsv,

  /// Apple VideoToolbox (`*_videotoolbox`). macOS / iOS.
  videotoolbox,

  /// Windows Media Foundation (`*_mf`). Useful as a generic fallback on
  /// Windows ARM64 / older systems where the vendor SDKs aren't present.
  mediafoundation,

  /// Linux V4L2 mem2mem (`*_v4l2m2m`). Raspberry Pi / RK35xx / etc.
  v4l2m2m,
}

/// What pixel format the encoder consumes from us.
enum _HwInputFmt {
  /// 4-bpp packed RGB with padding alpha. NVENC native input.
  /// FFmpeg name: "bgr0" / "rgb0".
  bgr0,

  /// Planar 4:2:0 with interleaved UV. AMF / QSV / VT / MF / V4L2 native.
  nv12,
}

/// Per-vendor + per-codec spec table.
class _HwSpec {
  final HwEncoderVendor vendor;
  final VideoCodec codec;
  final String encoderName;
  final _HwInputFmt inputFmt;

  /// Hardware width cap (typical; older parts may be lower).
  final int maxWidth;

  /// Hardware height cap.
  final int maxHeight;

  /// Default options to apply unless overridden in [EncoderConfig.backendOptions].
  final Map<String, String> defaults;

  const _HwSpec({
    required this.vendor,
    required this.codec,
    required this.encoderName,
    required this.inputFmt,
    required this.maxWidth,
    required this.maxHeight,
    required this.defaults,
  });
}

const List<_HwSpec> _hwSpecs = [
  // ─────────── NVENC ───────────
  _HwSpec(
    vendor: HwEncoderVendor.nvenc,
    codec: VideoCodec.h264,
    encoderName: 'h264_nvenc',
    inputFmt: _HwInputFmt.bgr0,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'preset': 'p4', 'tune': 'hq'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.nvenc,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_nvenc',
    inputFmt: _HwInputFmt.bgr0,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'p4', 'tune': 'hq'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.nvenc,
    codec: VideoCodec.av1,
    encoderName: 'av1_nvenc',
    inputFmt: _HwInputFmt.bgr0,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'p4', 'tune': 'hq'},
  ),

  // ─────────── AMD AMF ───────────
  _HwSpec(
    vendor: HwEncoderVendor.amf,
    codec: VideoCodec.h264,
    encoderName: 'h264_amf',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'usage': 'transcoding', 'quality': 'balanced'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.amf,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_amf',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'usage': 'transcoding', 'quality': 'balanced'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.amf,
    codec: VideoCodec.av1,
    encoderName: 'av1_amf',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'usage': 'transcoding', 'quality': 'balanced'},
  ),

  // ─────────── Intel QSV ───────────
  _HwSpec(
    vendor: HwEncoderVendor.qsv,
    codec: VideoCodec.h264,
    encoderName: 'h264_qsv',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'preset': 'medium'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.qsv,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_qsv',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'medium'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.qsv,
    codec: VideoCodec.av1,
    encoderName: 'av1_qsv',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'preset': 'medium'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.qsv,
    codec: VideoCodec.vp9,
    encoderName: 'vp9_qsv',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {},
  ),

  // ─────────── Apple VideoToolbox ───────────
  _HwSpec(
    vendor: HwEncoderVendor.videotoolbox,
    codec: VideoCodec.h264,
    encoderName: 'h264_videotoolbox',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {'realtime': '1', 'allow_sw': '1'},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.videotoolbox,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_videotoolbox',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {'realtime': '1', 'allow_sw': '1'},
  ),

  // ─────────── Windows Media Foundation ───────────
  // NOTE: we deliberately do NOT default `hw_encoding=1`. MediaFoundation is
  // the LAST entry in the probe order, so it is only ever reached when no
  // vendor HW encoder (NVENC/QSV/AMF) is present — exactly the machines that
  // have no hardware MFT. Forcing `hw_encoding=1` there enumerates hardware
  // MFTs only and fails. Leaving it unset lets MF pick its **software** H.264
  // MFT ("H264 Encoder MFT"), which is the genuine CPU fallback now that the
  // LGPL build has no libx264. Callers that specifically want the hardware
  // MFT can still pass `backendOptions: {'hw_encoding': '1'}`.
  _HwSpec(
    vendor: HwEncoderVendor.mediafoundation,
    codec: VideoCodec.h264,
    encoderName: 'h264_mf',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.mediafoundation,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_mf',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    // The Windows "HEVCVideoExtensionEncoder" software MFT is unreliable
    // (E_FAIL on input) — HEVC via MF realistically needs a hardware MFT, so
    // there is no dependable HEVC CPU fallback in the LGPL build. Auto-select
    // anyway so a HW MFT is used when present.
    defaults: {},
  ),

  // ─────────── Linux V4L2 M2M ───────────
  _HwSpec(
    vendor: HwEncoderVendor.v4l2m2m,
    codec: VideoCodec.h264,
    encoderName: 'h264_v4l2m2m',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 4096,
    maxHeight: 4096,
    defaults: {},
  ),
  _HwSpec(
    vendor: HwEncoderVendor.v4l2m2m,
    codec: VideoCodec.hevc,
    encoderName: 'hevc_v4l2m2m',
    inputFmt: _HwInputFmt.nv12,
    maxWidth: 8192,
    maxHeight: 8192,
    defaults: {},
  ),
];

/// Default vendor probe order. Adjust per platform at runtime.
const List<HwEncoderVendor> _defaultVendorOrder = [
  HwEncoderVendor.nvenc,
  HwEncoderVendor.qsv,
  HwEncoderVendor.amf,
  HwEncoderVendor.videotoolbox,
  HwEncoderVendor.mediafoundation,
  HwEncoderVendor.v4l2m2m,
];

/// Returns a vendor-probe order biased to the current platform's most
/// likely native encoder first. Keeps every vendor in the list as a
/// fallback so unusual configs (e.g. NVIDIA on Linux, Parallels on macOS)
/// still pick something sensible.
///
/// - **Windows**: NVENC \u2192 AMF \u2192 QSV \u2192 MediaFoundation (vendor-native
///   runtimes win; MF is universal fallback).
/// - **macOS / iOS**: VideoToolbox first \u2014 it's the only HW encoder Apple
///   ships, and it accepts CVPixelBuffer/IOSurface zero-copy from
///   AVCaptureSession + ScreenCaptureKit.
/// - **Linux**: NVENC (discrete NVIDIA) \u2192 QSV (Intel) \u2192 VAAPI / V4L2 M2M.
///   VAAPI is exposed by FFmpeg through dedicated `*_vaapi` codecs which
///   `_hwSpecs` does not yet enumerate; surface them when added.
/// - **Android**: V4L2 M2M (MediaCodec interop happens through a separate
///   path; not in this list).
List<HwEncoderVendor> _platformVendorOrder() {
  if (Platform.isWindows) {
    return const [
      HwEncoderVendor.nvenc,
      HwEncoderVendor.amf,
      HwEncoderVendor.qsv,
      HwEncoderVendor.mediafoundation,
    ];
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return const [HwEncoderVendor.videotoolbox];
  }
  if (Platform.isLinux) {
    return const [
      HwEncoderVendor.nvenc,
      HwEncoderVendor.qsv,
      HwEncoderVendor.v4l2m2m,
    ];
  }
  if (Platform.isAndroid) {
    return const [HwEncoderVendor.v4l2m2m];
  }
  return _defaultVendorOrder;
}

/// Adapter-aware CPU-fed HW vendor probe order, derived from the DXGI vendor
/// of [d3d11DeviceHandle] (the recorder's Dawn/capture device address; 0 =
/// unknown → [_platformVendorOrder]).
///
/// Intended for the isolate-hosted CPU-fed encoder, which loops these in
/// order. Differences from the plain platform order:
///   * The adapter's native vendor comes first (AMD→AMF*, Intel→QSV,
///     NVIDIA→NVENC), so we don't burn a doomed cross-vendor `avcodec_open2`.
///   * On AMD, **MediaFoundation is preferred over AMF**: FFmpeg's
///     `h264_amf` silently encodes black on some AMD drivers with the CPU-fed
///     NV12 input, whereas `h264_mf` routes through the AMD hardware MFT (or
///     the Microsoft software MFT as a safe fallback). AMF is kept last as a
///     best-effort.
/// MediaFoundation is always appended as the universal Windows fallback.
List<HwEncoderVendor> hwVendorOrderForDevice(int d3d11DeviceHandle) {
  if (!Platform.isWindows || d3d11DeviceHandle == 0) {
    return _platformVendorOrder();
  }
  final shim = FfmpegShim.tryLoad();
  if (shim == null) return _platformVendorOrder();
  final vid = shim.d3d11GetVendorId(
    Pointer<Void>.fromAddress(d3d11DeviceHandle),
  );
  switch (vid) {
    case 0x1002: // AMD — MF before AMF (h264_amf can encode black on AMD).
      return const [HwEncoderVendor.mediafoundation, HwEncoderVendor.amf];
    case 0x8086: // Intel
      return const [HwEncoderVendor.qsv, HwEncoderVendor.mediafoundation];
    case 0x10DE: // NVIDIA
      return const [HwEncoderVendor.nvenc, HwEncoderVendor.mediafoundation];
    default:
      return _platformVendorOrder();
  }
}

/// Returns true if the named encoder is registered in the loaded FFmpeg.
/// Cheap — pure name lookup, does NOT initialise hardware.
bool _encoderPresent(Ffmpeg ff, String name) {
  final p = name.toNativeUtf8();
  try {
    return ff.avcodecFindEncoderByName(p) != address(0);
  } finally {
    calloc.free(p);
  }
}

/// Look up [_HwSpec] by vendor + codec.
_HwSpec? _findSpec(HwEncoderVendor vendor, VideoCodec codec) {
  for (final s in _hwSpecs) {
    if (s.vendor == vendor && s.codec == codec) return s;
  }
  return null;
}

/// Scan all vendors + codecs in [_hwSpecs] and return every encoder name
/// that is registered in the loaded FFmpeg (presence != functional, but a
/// good cheap filter).
List<HwEncoderVendor> ffmpegHwVendorsAvailable() {
  final ff = Ffmpeg.instance();
  if (ff == null) return const [];
  final seen = <HwEncoderVendor>{};
  for (final s in _hwSpecs) {
    if (seen.contains(s.vendor)) continue;
    if (_encoderPresent(ff, s.encoderName)) seen.add(s.vendor);
  }
  return seen.toList(growable: false);
}

/// Returns `true` if any hardware encoder for [codec] is registered.
bool ffmpegHwEncoderAvailable(VideoCodec codec) {
  final ff = Ffmpeg.instance();
  if (ff == null) return false;
  for (final s in _hwSpecs) {
    if (s.codec == codec && _encoderPresent(ff, s.encoderName)) return true;
  }
  return false;
}

/// Pick the best available [_HwSpec] for [codec], honouring a vendor
/// preference list (most-preferred first). Returns null if nothing matches.
/// Defaults to the platform-biased order from [_platformVendorOrder].
_HwSpec? _pickSpec(
  Ffmpeg ff,
  VideoCodec codec, {
  List<HwEncoderVendor>? order,
}) {
  final probe = order ?? _platformVendorOrder();
  for (final v in probe) {
    final spec = _findSpec(v, codec);
    if (spec == null) continue;
    if (_encoderPresent(ff, spec.encoderName)) return spec;
  }
  return null;
}

/// A generic FFmpeg hardware encoder.
///
/// Accepts CPU `RGBA32` / `BGRA32` frames (or `MiniAVBufferSource` with the
/// same). Internally either:
/// * feeds them directly to the encoder as `bgr0` (NVENC), or
/// * converts to `nv12` first (AMF / QSV / VideoToolbox / MF / V4L2).
///
/// True zero-copy from a D3D11 / DMA-BUF / IOSurface texture is Stage B.
// WGSL bilinear scale kernel (identical to gpu_screen_processor.dart).
// Works for both downscale and upscale.  Inputs: src u32[], dst u32[],
// params{srcW,srcH,dstW,dstH} u32[4].
const _kScaleWgsl = r'''
struct Params {
  srcW     : u32,
  srcH     : u32,
  dstW     : u32,
  dstH     : u32,
};
@group(0) @binding(0) var<storage, read_write> src    : array<u32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;
fn unpack(p:u32)->vec4<f32>{
  return vec4<f32>(f32(p&0xFFu),f32((p>>8u)&0xFFu),f32((p>>16u)&0xFFu),f32((p>>24u)&0xFFu))/255.0;
}
fn pack(c:vec4<f32>)->u32{
  let q=clamp(c,vec4<f32>(0.0),vec4<f32>(1.0))*255.0+vec4<f32>(0.5);
  return u32(q.x)|(u32(q.y)<<8u)|(u32(q.z)<<16u)|(u32(q.w)<<24u);
}
fn rd(x:u32,y:u32)->vec4<f32>{
  return unpack(src[clamp(y,0u,params.srcH-1u)*params.srcW+clamp(x,0u,params.srcW-1u)]);
}
@compute @workgroup_size(8,8,1)
fn main(@builtin(global_invocation_id) gid:vec3<u32>){
  if(gid.x>=params.dstW||gid.y>=params.dstH){return;}
  let sx=(f32(gid.x)+0.5)*f32(params.srcW)/f32(params.dstW)-0.5;
  let sy=(f32(gid.y)+0.5)*f32(params.srcH)/f32(params.dstH)-0.5;
  let x0=u32(max(i32(sx),0));let y0=u32(max(i32(sy),0));
  let x1=min(x0+1u,params.srcW-1u);let y1=min(y0+1u,params.srcH-1u);
  let tx=fract(sx);let ty=fract(sy);
  dst[gid.y*params.dstW+gid.x]=pack(mix(mix(rd(x0,y0),rd(x1,y0),tx),mix(rd(x0,y1),rd(x1,y1),tx),ty));
}
''';

class FfmpegHwEncoder implements PlatformEncoder, FfmpegEncoderBridge {
  FfmpegHwEncoder._(
    this._ff,
    this._cfg,
    this._spec,
    this._codecCtx,
    this._frame,
    this._packet, {
    bool hasGpu = false,
  }) : _hasGpu = hasGpu;

  final Ffmpeg _ff;
  final EncoderConfig _cfg;
  final _HwSpec _spec;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVFrame> _frame;
  final Pointer<AVPacket> _packet;

  /// Whether a minigpu platform context is available for GPU compute rescale.
  final bool _hasGpu;

  // GPU compute rescale cache — only used when [_hasGpu] is true.
  // Recreated whenever the source dimensions change.
  PlatformComputeShader? _gpuScaleShader;
  PlatformBuffer? _gpuSrcBuf;
  PlatformBuffer? _gpuDstBuf;
  PlatformBuffer? _gpuParamsBuf;
  int _gpuScaleSrcW = 0;
  int _gpuScaleSrcH = 0;

  bool _closed = false;
  int _nextPts = 0;
  CodecExtraData? _extraData;
  bool _forceKeyframe = false;
  bool _loggedRescale = false;

  HwEncoderVendor get vendor => _spec.vendor;
  String get encoderName => _spec.encoderName;

  /// Open the best-available HW encoder for [cfg.codec], picking among
  /// vendors using [vendorOrder]. [gpu] is an optional minigpu
  /// [Object] (a `Minigpu` instance in practice) used to accelerate
  /// mid-stream resolution rescaling on GPU rather than in Dart.
  /// When null the encoder falls back to pure-Dart bilinear rescaling.
  /// Pass the value of [BackendContext.sharedGpu] from the caller.
  /// When unspecified, defaults to a
  /// platform-biased order: Windows → NVENC/AMF/QSV/MF; macOS → VT;
  /// Linux → NVENC/QSV/V4L2; Android → V4L2. Throws [CodecInitException]
  /// when nothing matches or init fails.
  static FfmpegHwEncoder open(
    EncoderConfig cfg, {
    List<HwEncoderVendor>? vendorOrder,
    Object? gpu,
  }) {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg-hw',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    final probe = vendorOrder ?? _platformVendorOrder();
    final spec = _pickSpec(ff, cfg.codec, order: probe);
    if (spec == null) {
      throw CodecInitException(
        'ffmpeg-hw',
        'No hardware encoder available for ${cfg.codec}. '
            'Tried vendors: ${probe.join(', ')}.',
      );
    }
    return openWith(cfg, spec.vendor, gpu: gpu);
  }

  /// Open a specific vendor's encoder for [cfg.codec]. Throws if that
  /// combination isn't supported or the encoder isn't present in the loaded
  /// FFmpeg build.
  static FfmpegHwEncoder openWith(
    EncoderConfig cfg,
    HwEncoderVendor vendor, {
    Object? gpu,
  }) {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg-hw',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    // QSV (libmfx) and MediaFoundation both need MTA on Windows.  Flutter's
    // UI isolate is STA by default; elevate the current thread before init.
    if (Platform.isWindows &&
        (vendor == HwEncoderVendor.qsv ||
            vendor == HwEncoderVendor.mediafoundation)) {
      FfmpegShim.tryLoad()?.ensureMta();
    }
    final spec = _findSpec(vendor, cfg.codec);
    if (spec == null) {
      throw CodecInitException(
        'ffmpeg-hw',
        '$vendor does not support ${cfg.codec} in this binding',
      );
    }
    if (cfg.width > spec.maxWidth || cfg.height > spec.maxHeight) {
      throw CodecInitException(
        'ffmpeg-hw',
        '${spec.encoderName} max resolution is '
            '${spec.maxWidth}x${spec.maxHeight}; requested '
            '${cfg.width}x${cfg.height}. Use ${cfg.codec == VideoCodec.h264 ? "VideoCodec.hevc" : "a software encoder"}.',
      );
    }
    if (!_encoderPresent(ff, spec.encoderName)) {
      throw CodecInitException(
        'ffmpeg-hw',
        '${spec.encoderName} is not present in this FFmpeg build',
      );
    }

    final namePtr = spec.encoderName.toNativeUtf8();
    Pointer<AVCodec> codec;
    try {
      codec = ff.avcodecFindEncoderByName(namePtr);
    } finally {
      calloc.free(namePtr);
    }

    final codecCtx = ff.avcodecAllocContext3(codec);
    if (codecCtx == address(0)) {
      throw const CodecInitException(
        'ffmpeg-hw',
        'avcodec_alloc_context3 returned NULL',
      );
    }

    try {
      _configureCtx(ff, codecCtx, cfg, spec);

      final ret = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (ret < 0) {
        throw CodecInitException(
          'ffmpeg-hw',
          'avcodec_open2(${spec.encoderName}) failed: '
              '${ff.strError(ret)} ($ret). '
              'Driver / runtime may be missing or busy.',
        );
      }

      final frame = ff.avFrameAlloc();
      final packet = ff.avPacketAlloc();
      if (frame == address(0) || packet == address(0)) {
        throw const CodecInitException(
          'ffmpeg-hw',
          'av_frame_alloc / av_packet_alloc returned NULL',
        );
      }

      final pixName = _inputFmtName(spec.inputFmt);
      final pixPtr = pixName.toNativeUtf8();
      final pixFmt = ff.avGetPixFmtByName(pixPtr);
      calloc.free(pixPtr);
      if (pixFmt < 0) {
        throw CodecInitException(
          'ffmpeg-hw',
          'av_get_pix_fmt("$pixName") returned -1',
        );
      }
      frame.ref
        ..width = cfg.width
        ..height = cfg.height
        ..format = pixFmt;

      final r = ff.avFrameGetBuffer(frame, 32);
      if (r < 0) {
        throw CodecInitException(
          'ffmpeg-hw',
          'av_frame_get_buffer($pixName) failed: ${ff.strError(r)}',
        );
      }

      return FfmpegHwEncoder._(
        ff,
        cfg,
        spec,
        codecCtx,
        frame,
        packet,
        hasGpu: gpu != null,
      ).._loadExtraData();
    } catch (_) {
      final ptr = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
      ff.avcodecFreeContext(ptr);
      calloc.free(ptr);
      rethrow;
    }
  }

  static String _inputFmtName(_HwInputFmt f) {
    switch (f) {
      case _HwInputFmt.bgr0:
        return 'bgr0';
      case _HwInputFmt.nv12:
        return 'nv12';
    }
  }

  static void _configureCtx(
    Ffmpeg ff,
    Pointer<AVCodecContext> ctx,
    EncoderConfig cfg,
    _HwSpec spec,
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
            'ffmpeg-hw',
            'av_opt_set_q($key=$num/$den): ${ff.strError(ret)} ($ret)',
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
            'ffmpeg-hw',
            'av_opt_set_int($key=$val): ${ff.strError(r)} ($r)',
          );
        }
      } finally {
        calloc.free(k);
      }
    }

    setStr('video_size', '${cfg.width}x${cfg.height}');

    final pixName = _inputFmtName(spec.inputFmt);
    final pixPtr = pixName.toNativeUtf8();
    final pixFmt = ff.avGetPixFmtByName(pixPtr);
    calloc.free(pixPtr);
    if (pixFmt < 0) {
      throw CodecInitException(
        'ffmpeg-hw',
        'av_get_pix_fmt("$pixName") returned -1',
      );
    }
    final k = 'pixel_format'.toNativeUtf8();
    try {
      final r = ff.avOptSetPixelFmt(ctxV, k, pixFmt, 1 /* SEARCH_CHILDREN */);
      if (r < 0) {
        throw CodecInitException(
          'ffmpeg-hw',
          'av_opt_set_pixel_fmt(pixel_format=$pixName/$pixFmt) failed: '
              '${ff.strError(r)} ($r)',
        );
      }
    } finally {
      calloc.free(k);
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

    // Common rate-control mapping. Vendor-specific knobs (e.g. NVENC `rc`,
    // AMF `usage`, QSV `preset`) come from spec.defaults below.
    final defaults = <String, String>{...spec.defaults};

    if (cfg.rateControl == RateControl.crf && cfg.crfQuality != null) {
      switch (spec.vendor) {
        case HwEncoderVendor.nvenc:
          defaults['rc'] = 'constqp';
          defaults['qp'] = cfg.crfQuality!.toString();
          break;
        case HwEncoderVendor.qsv:
          defaults['global_quality'] = cfg.crfQuality!.toString();
          break;
        case HwEncoderVendor.amf:
          defaults['rc'] = 'cqp';
          defaults['qp_i'] = cfg.crfQuality!.toString();
          defaults['qp_p'] = cfg.crfQuality!.toString();
          break;
        case HwEncoderVendor.videotoolbox:
          defaults['q'] = cfg.crfQuality!.toString();
          break;
        case HwEncoderVendor.mediafoundation:
        case HwEncoderVendor.v4l2m2m:
          // No standard CRF mapping; bitrate target still applies.
          break;
      }
    } else if (cfg.rateControl == RateControl.vbr) {
      switch (spec.vendor) {
        case HwEncoderVendor.nvenc:
          defaults.putIfAbsent('rc', () => 'vbr');
          break;
        case HwEncoderVendor.amf:
          defaults.putIfAbsent('rc', () => 'vbr_peak');
          break;
        default:
          break;
      }
    } else if (cfg.rateControl == RateControl.cbr) {
      switch (spec.vendor) {
        case HwEncoderVendor.nvenc:
          defaults.putIfAbsent('rc', () => 'cbr');
          break;
        case HwEncoderVendor.amf:
          defaults.putIfAbsent('rc', () => 'cbr');
          break;
        default:
          break;
      }
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
    var src = _frameToRgba(frame);
    if (src.width != _cfg.width || src.height != _cfg.height) {
      // Capture resolution changed mid-stream (e.g. game launched at a
      // different size than the desktop).  The encoder's SPS/PPS were
      // baked in at open-time and cannot change, so rescale the input
      // frame to the encoder's fixed dimensions.  Bilinear is a cheap
      // safety-net; the GPU path normally handles this via shader scale.
      if (!_loggedRescale) {
        _loggedRescale = true;
        // ignore: avoid_print
        print(
          '[ffmpeg-hw] rescaling input ${src.width}x${src.height} -> '
          '${_cfg.width}x${_cfg.height} (capture resolution changed)',
        );
      }
      src = _hasGpu
          ? (await _gpuRescaleRgba(src, _cfg.width, _cfg.height))
          : _bilinearRescaleRgba(src, _cfg.width, _cfg.height);
    }

    final mw = _ff.avFrameMakeWritable(_frame);
    if (mw < 0) {
      throw CodecRuntimeException(
        'ffmpeg-hw',
        'av_frame_make_writable: ${_ff.strError(mw)}',
      );
    }

    final f = _frame.ref;

    switch (_spec.inputFmt) {
      case _HwInputFmt.bgr0:
        _copyPackedRgb(f, src);
        break;
      case _HwInputFmt.nv12:
        _copyAsNv12(f, src);
        break;
    }

    f.pts = _nextPts++;
    f.pictType = _forceKeyframe ? 1 /* AV_PICTURE_TYPE_I */ : 0;
    _forceKeyframe = false;

    final sendRet = _ff.avcodecSendFrame(_codecCtx, _frame);
    if (sendRet < 0 && sendRet != kAvErrorEAgain) {
      throw CodecRuntimeException(
        'ffmpeg-hw',
        'avcodec_send_frame: ${_ff.strError(sendRet)} ($sendRet)',
      );
    }
    return _drainOne();
  }

  void _copyPackedRgb(AVFrame f, _PreparedRgba src) {
    final dstStride = f.linesize0;
    final rowBytes = src.width * 4;
    final dstView = f.data0.asTypedList(dstStride * src.height);
    if (src.srcStride == dstStride) {
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
  }

  void _copyAsNv12(AVFrame f, _PreparedRgba src) {
    // Convert source → I420 then pack U/V planes into NV12 interleaved chroma.
    final yuv = toYuv420p(
      src: src.bytes,
      format: src.sourceFormat,
      width: src.width,
      height: src.height,
      strides: src.planeStrides ?? [src.srcStride],
    );

    // Y plane → data0 (linesize0 may be padded).
    final yStride = f.linesize0;
    final yDst = f.data0.asTypedList(yStride * src.height);
    for (var row = 0; row < src.height; row++) {
      yDst.setRange(
        row * yStride,
        row * yStride + src.width,
        yuv.y,
        row * src.width,
      );
    }

    // UV interleaved → data1 (linesize1 in bytes).
    final cw = src.width ~/ 2;
    final ch = src.height ~/ 2;
    final uvStride = f.linesize1;
    final uvDst = f.data1.asTypedList(uvStride * ch);
    for (var row = 0; row < ch; row++) {
      final dstBase = row * uvStride;
      final srcBase = row * cw;
      for (var col = 0; col < cw; col++) {
        uvDst[dstBase + col * 2] = yuv.u[srcBase + col];
        uvDst[dstBase + col * 2 + 1] = yuv.v[srcBase + col];
      }
    }
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final ret = _ff.avcodecSendFrame(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg-hw',
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

  // CPU-fed HW encoder repacks RGBA to NV12 itself; it does not take YUV420P.
  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Release GPU compute rescale resources.
    _gpuScaleShader?.destroy();
    _gpuScaleShader = null;
    _gpuSrcBuf?.destroy();
    _gpuSrcBuf = null;
    _gpuDstBuf?.destroy();
    _gpuDstBuf = null;
    _gpuParamsBuf?.destroy();
    _gpuParamsBuf = null;
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

  @override
  Pointer<AVCodecContext> get nativeCodecContext => _codecCtx;

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-hw', 'encoder closed');
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
        'ffmpeg-hw',
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

  /// Default per-pixel byte count for first-plane stride fallback.
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

  /// Pack non-contiguous miniav planes into a single byte buffer suitable
  /// for [toYuv420p]. NV12: Y plane then UV plane. I420: Y then U then V.
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
            'ffmpeg-hw',
            'HW encoder accepts RGBA32/BGRA32/YUY2/NV12/I420 CPU frames; got $fmt',
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
            bgra: fmt == MiniAVPixelFormat.bgra32,
            sourceFormat: fmt,
            planeStrides: src.strideBytes,
          );
        }
        final bgraBytes = toBgra32(
          src: src.bytes,
          format: fmt,
          width: src.width,
          height: src.height,
          strides: src.strideBytes,
        );
        return _PreparedRgba(
          bytes: bgraBytes,
          width: src.width,
          height: src.height,
          srcStride: src.width * 4,
          bgra: true,
          sourceFormat: MiniAVPixelFormat.bgra32,
        );
      case MiniAVBufferSource():
        final video = src.buffer.data;
        if (video is! MiniAVVideoBuffer) {
          throw const CodecRuntimeException('ffmpeg-hw', 'expected video');
        }
        final fmt = video.pixelFormat;
        if (!_kSupportedCpuFormats.contains(fmt)) {
          throw CodecRuntimeException(
            'ffmpeg-hw',
            'HW encoder accepts RGBA32/BGRA32/YUY2/NV12/I420 MiniAV buffers; '
                'got $fmt',
          );
        }
        if (video.planes.isEmpty || video.planes[0] == null) {
          throw const CodecRuntimeException(
            'ffmpeg-hw',
            'MiniAVBufferSource: plane[0] was null — likely a GPU-backed buffer',
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
            bgra: fmt == MiniAVPixelFormat.bgra32,
            sourceFormat: fmt,
            planeStrides: video.strideBytes,
          );
        }
        final bgraBytes = toBgra32(
          src: bytes,
          format: fmt,
          width: video.width,
          height: video.height,
          strides: video.strideBytes,
        );
        return _PreparedRgba(
          bytes: bgraBytes,
          width: video.width,
          height: video.height,
          srcStride: video.width * 4,
          bgra: true,
          sourceFormat: MiniAVPixelFormat.bgra32,
        );
      default:
        throw CodecRuntimeException(
          'ffmpeg-hw',
          'HW encoder accepts CpuFrameSource / MiniAVBufferSource (CPU plane) only. '
              'Got: ${src.runtimeType}.',
        );
    }
  }

  /// GPU-compute bilinear rescale using the minigpu WebGPU backend.
  ///
  /// Creates (and caches) a compute shader + three GPU buffers on the first
  /// call for a given src dimension, then dispatches the scale kernel and
  /// reads the result back to CPU.  Buffers are recreated only when the
  /// source dimensions change; the encoder's dst dimensions are fixed at
  /// open time so [_gpuDstBuf] is never reallocated.
  ///
  /// Falls back to [_bilinearRescaleRgba] on any GPU error so the encode
  /// loop stays alive even if WebGPU becomes unavailable mid-session.
  Future<_PreparedRgba> _gpuRescaleRgba(
    _PreparedRgba src,
    int dstW,
    int dstH,
  ) async {
    final srcW = src.width;
    final srcH = src.height;
    final gpu = MinigpuPlatform.instance;
    try {
      // (Re)allocate src-side buffer and shader when source dims change.
      if (_gpuScaleShader == null ||
          srcW != _gpuScaleSrcW ||
          srcH != _gpuScaleSrcH) {
        _gpuScaleShader?.destroy();
        _gpuSrcBuf?.destroy();
        _gpuParamsBuf?.destroy();

        _gpuScaleShader = gpu.createComputeShader()
          ..loadKernelString(_kScaleWgsl);
        _gpuSrcBuf = gpu.createBuffer(srcW * srcH * 4, BufferDataType.uint8);
        _gpuParamsBuf = gpu.createBuffer(16, BufferDataType.uint8);
        _gpuDstBuf ??= gpu.createBuffer(dstW * dstH * 4, BufferDataType.uint8);

        _gpuScaleSrcW = srcW;
        _gpuScaleSrcH = srcH;
      }

      // Upload source RGBA/BGRA pixels.
      await _gpuSrcBuf!.write(
        src.bytes,
        srcW * srcH,
        dataType: BufferDataType.uint8,
      );

      // Upload params: srcW, srcH, dstW, dstH (4×u32 LE).
      final params = ByteData(16)
        ..setUint32(0, srcW, Endian.little)
        ..setUint32(4, srcH, Endian.little)
        ..setUint32(8, dstW, Endian.little)
        ..setUint32(12, dstH, Endian.little);
      await _gpuParamsBuf!.write(
        params.buffer.asUint8List(),
        16,
        dataType: BufferDataType.uint8,
      );

      // Bind and dispatch.
      _gpuScaleShader!
        ..setBuffer(0, _gpuSrcBuf!)
        ..setBuffer(1, _gpuDstBuf!)
        ..setBuffer(2, _gpuParamsBuf!);
      const kGroup = 8;
      await _gpuScaleShader!.dispatch(
        (dstW + kGroup - 1) ~/ kGroup,
        (dstH + kGroup - 1) ~/ kGroup,
        1,
      );

      // Readback.
      final output = Uint8List(dstW * dstH * 4);
      await _gpuDstBuf!.read(
        output,
        dstW * dstH,
        dataType: BufferDataType.uint8,
      );

      return _PreparedRgba(
        bytes: output,
        width: dstW,
        height: dstH,
        srcStride: dstW * 4,
        bgra: src.bgra,
        sourceFormat: src.sourceFormat,
      );
    } catch (e) {
      ffmpegToolsLog(
        MiniAVLogLevel.warn,
        '[ffmpeg-hw] GPU rescale error ($e); falling back to Dart bilinear',
      );
      return _bilinearRescaleRgba(src, dstW, dstH);
    }
  }

  /// Bilinear resample a packed 32-bpp (RGBA / BGRA) [_PreparedRgba] buffer
  /// to [dstW] × [dstH].  Used as a safety-net when the capture source
  /// resolution diverges from the encoder's fixed dimensions; the GPU
  /// path (Stage B) handles this via shader scale.  Pure Dart (no sws
  /// FFI dependency).  Channel order is preserved.
  _PreparedRgba _bilinearRescaleRgba(_PreparedRgba src, int dstW, int dstH) {
    final srcW = src.width;
    final srcH = src.height;
    final srcStride = src.srcStride;
    final srcBytes = src.bytes;
    final dstStride = dstW * 4;
    final dst = Uint8List(dstStride * dstH);

    // Map dst pixel centre to src coordinates.  Guard against 1-pixel
    // sources to avoid div-by-zero.
    final xRatio = srcW > 1 ? (srcW - 1) / dstW : 0.0;
    final yRatio = srcH > 1 ? (srcH - 1) / dstH : 0.0;

    for (var y = 0; y < dstH; y++) {
      final fy = (y + 0.5) * yRatio;
      var y0 = fy.floor();
      if (y0 < 0) y0 = 0;
      if (y0 > srcH - 1) y0 = srcH - 1;
      var y1 = y0 + 1;
      if (y1 > srcH - 1) y1 = srcH - 1;
      final wy = fy - y0;
      final row0Base = y0 * srcStride;
      final row1Base = y1 * srcStride;
      final dstBase = y * dstStride;

      for (var x = 0; x < dstW; x++) {
        final fx = (x + 0.5) * xRatio;
        var x0 = fx.floor();
        if (x0 < 0) x0 = 0;
        if (x0 > srcW - 1) x0 = srcW - 1;
        var x1 = x0 + 1;
        if (x1 > srcW - 1) x1 = srcW - 1;
        final wx = fx - x0;

        final i00 = row0Base + x0 * 4;
        final i01 = row0Base + x1 * 4;
        final i10 = row1Base + x0 * 4;
        final i11 = row1Base + x1 * 4;
        final dstIdx = dstBase + x * 4;

        for (var c = 0; c < 4; c++) {
          final v00 = srcBytes[i00 + c].toDouble();
          final v01 = srcBytes[i01 + c].toDouble();
          final v10 = srcBytes[i10 + c].toDouble();
          final v11 = srcBytes[i11 + c].toDouble();
          final top = v00 + (v01 - v00) * wx;
          final bot = v10 + (v11 - v10) * wx;
          final v = top + (bot - top) * wy;
          dst[dstIdx + c] = v.round().clamp(0, 255);
        }
      }
    }

    return _PreparedRgba(
      bytes: dst,
      width: dstW,
      height: dstH,
      srcStride: dstStride,
      bgra: src.bgra,
      sourceFormat: src.sourceFormat,
    );
  }
}

class _PreparedRgba {
  final Uint8List bytes;
  final int width;
  final int height;
  final int srcStride;

  /// True when [bytes] is BGRA32 (false for RGBA32 *and* for non-packed YUV).
  final bool bgra;

  /// Original pixel format of [bytes].
  final MiniAVPixelFormat sourceFormat;

  /// Per-plane strides (used by NV12 / I420 / YUY2 sources). For packed RGBA/BGRA
  /// sources [srcStride] alone is enough.
  final List<int>? planeStrides;
  const _PreparedRgba({
    required this.bytes,
    required this.width,
    required this.height,
    required this.srcStride,
    required this.bgra,
    required this.sourceFormat,
    this.planeStrides,
  });
}

const int _avNoPts = -0x8000000000000000;

/// Exposes [FfmpegHwEncoder]'s bilinear rescale algorithm for unit testing.
///
/// [src] is a flat RGBA/BGRA buffer with dimensions [srcW]×[srcH]. Returns a
/// flat buffer of [dstW]×[dstH] in the same channel order.
@visibleForTesting
Uint8List bilinearRescaleRgbaForTest(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  // Re-use the private implementation via a throw-away _PreparedRgba wrapper.
  final prepared = _PreparedRgba(
    bytes: src,
    width: srcW,
    height: srcH,
    srcStride: srcW * 4,
    bgra: false,
    sourceFormat: MiniAVPixelFormat.rgba32,
  );
  // We need a FfmpegHwEncoder instance to call the instance method, but the
  // algorithm is pure and only depends on the src buffer — so we extract it
  // as a standalone free function here.
  return _bilinearRescaleStandalone(prepared, dstW, dstH).bytes;
}

/// Standalone bilinear rescale used by [bilinearRescaleRgbaForTest].
Uint8List _bilinearFreeFunction(
  Uint8List srcBytes,
  int srcW,
  int srcH,
  int srcStride,
  int dstW,
  int dstH,
) {
  final dstStride = dstW * 4;
  final dst = Uint8List(dstStride * dstH);
  final xRatio = srcW > 1 ? (srcW - 1) / dstW : 0.0;
  final yRatio = srcH > 1 ? (srcH - 1) / dstH : 0.0;
  for (var y = 0; y < dstH; y++) {
    final fy = (y + 0.5) * yRatio;
    var y0 = fy.floor().clamp(0, srcH - 1);
    var y1 = (y0 + 1).clamp(0, srcH - 1);
    final wy = fy - y0;
    final row0Base = y0 * srcStride;
    final row1Base = y1 * srcStride;
    final dstBase = y * dstStride;
    for (var x = 0; x < dstW; x++) {
      final fx = (x + 0.5) * xRatio;
      var x0 = fx.floor().clamp(0, srcW - 1);
      var x1 = (x0 + 1).clamp(0, srcW - 1);
      final wx = fx - x0;
      final i00 = row0Base + x0 * 4;
      final i01 = row0Base + x1 * 4;
      final i10 = row1Base + x0 * 4;
      final i11 = row1Base + x1 * 4;
      final dstIdx = dstBase + x * 4;
      for (var c = 0; c < 4; c++) {
        final top =
            srcBytes[i00 + c] + (srcBytes[i01 + c] - srcBytes[i00 + c]) * wx;
        final bot =
            srcBytes[i10 + c] + (srcBytes[i11 + c] - srcBytes[i10 + c]) * wx;
        dst[dstIdx + c] = (top + (bot - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return dst;
}

_PreparedRgba _bilinearRescaleStandalone(
  _PreparedRgba src,
  int dstW,
  int dstH,
) {
  final dst = _bilinearFreeFunction(
    src.bytes,
    src.width,
    src.height,
    src.srcStride,
    dstW,
    dstH,
  );
  return _PreparedRgba(
    bytes: dst,
    width: dstW,
    height: dstH,
    srcStride: dstW * 4,
    bgra: src.bgra,
    sourceFormat: src.sourceFormat,
  );
}
