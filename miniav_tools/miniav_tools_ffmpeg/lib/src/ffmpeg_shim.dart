/// Native bindings to the `miniav_tools_ffmpeg_shim` code asset, built by
/// `hook/build.dart` against `tool/shim_c/shim.c`.
///
/// The shim exposes AVCodecContext fields (`hw_device_ctx`, `hw_frames_ctx`)
/// that FFmpeg's AVOption API does not surface, plus a few struct field
/// setters needed by the Stage B zero-copy hardware encode path.
///
/// If the shim asset is unavailable on the current platform (e.g. the
/// build hook skipped it because the FFmpeg auto-download failed) the
/// runtime calls below will throw — guard usage with [FfmpegShim.tryLoad].
@DefaultAsset('package:miniav_tools_ffmpeg/ffmpeg_shim.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffmpeg_bindings.dart' as bindings;
import 'ffmpeg_log.dart';

// =============================================================================
// External shim entry points (resolved via the native asset registered by
// hook/build.dart with the name `miniav_tools_ffmpeg_shim`).
// =============================================================================

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'miniav_shim_set_hw_device_ctx',
)
external void _setHwDeviceCtx(Pointer<Void> ctx, Pointer<Void> ref);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'miniav_shim_set_hw_frames_ctx',
)
external void _setHwFramesCtx(Pointer<Void> ctx, Pointer<Void> ref);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_hwframes_data',
)
external Pointer<Void> _hwFramesData(Pointer<Void> ref);

@Native<Void Function(Pointer<Void>, Int32, Int32, Int32, Int32, Int32)>(
  symbol: 'miniav_shim_hwframes_set_params',
)
external void _hwFramesSetParams(
  Pointer<Void> ctx,
  int format,
  int swFormat,
  int width,
  int height,
  int initialPoolSize,
);

@Native<Pointer<Void> Function(Pointer<Void>)>(symbol: 'miniav_shim_hwdev_data')
external Pointer<Void> _hwDevData(Pointer<Void> ref);

/// Windows-only. Symbol is missing from POSIX shim builds; never call
/// outside `Platform.isWindows`.
@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_dev_set_device',
)
external void _d3d11SetDevice(
  Pointer<Void> hwdevCtx,
  Pointer<Void> id3d11Device,
);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_dev_get_device',
)
external Pointer<Void> _d3d11GetDevice(Pointer<Void> hwdevCtx);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_dev_get_context',
)
external Pointer<Void> _d3d11GetContext(Pointer<Void> hwdevCtx);

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_open_shared_handle',
)
external Pointer<Void> _d3d11OpenSharedHandle(
  Pointer<Void> id3d11Device,
  Pointer<Void> ntHandle,
);

@Native<
  Void Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<Void>,
    Uint32,
  )
>(symbol: 'miniav_shim_d3d11_copy_resource')
external void _d3d11CopyResource(
  Pointer<Void> device,
  Pointer<Void> immediateContext,
  Pointer<Void> dstTex,
  int dstSubresource,
  Pointer<Void> srcTex,
  int srcSubresource,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_d3d11_release')
external void _d3d11Release(Pointer<Void> iunknown);

/// Windows-only. Returns the DXGI `VendorId` of the adapter backing an
/// `ID3D11Device*` (e.g. `0x8086` Intel, `0x10DE` NVIDIA, `0x1002` AMD).
/// Returns `0` on failure (null pointer, QueryInterface failure, etc.).
@Native<Uint32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_get_vendor_id',
)
external int _d3d11GetVendorId(Pointer<Void> id3d11Device);

/// Windows-only. Ensures the calling thread is in the COM MTA apartment.
/// Required before opening h264_mf / h264_qsv / hevc_mf / hevc_qsv encoders
/// from a Dart isolate (Flutter's UI thread is STA by default).
///
/// Returns 0 on success (now MTA, or already MTA), -1 if the thread is
/// pinned to STA and cannot be changed.
@Native<Int32 Function()>(symbol: 'miniav_shim_ensure_mta')
external int _ensureMta();

/// Sets [AVFrame.hw_frames_ctx] on a native AVFrame (used for QSV hwframe
/// mapping). The ref is av_buffer_ref'd internally; pass [nullptr] to clear.
@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'miniav_shim_av_frame_set_hw_frames_ctx',
)
external void _avFrameSetHwFramesCtx(
  Pointer<Void> frame,
  Pointer<Void> hwFramesCtxRef,
);

/// Windows-only. Creates a sibling ID3D11Device on the same DXGI adapter as
/// [existingDevice] but with D3D11_CREATE_DEVICE_VIDEO_SUPPORT enabled.
@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_d3d11_create_video_device_for',
)
external Pointer<Void> _d3d11CreateVideoDeviceFor(Pointer<Void> existingDevice);
// ---- D3D11 VideoProcessor — BGRA→NV12 for Intel QSV/MF zero-copy path ----
//
// Intel QSV (h264_qsv) and MediaFoundation (h264_mf) require NV12 input.
// The VideoProcessor converts BGRA→NV12 in GPU memory using the driver's
// hardware CSC unit.  All symbols are Windows-only.

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Uint32, Uint32)>(
  symbol: 'miniav_shim_d3d11_vp_create',
)
external Pointer<Void> _d3d11VpCreate(
  Pointer<Void> id3d11Device,
  Pointer<Void> id3d11Context,
  int width,
  int height,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_d3d11_vp_destroy')
external void _d3d11VpDestroy(Pointer<Void> vpCtx);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    Int32,
    Int32,
    Pointer<Void>,
  )
>(symbol: 'miniav_shim_d3d11_vp_bgra_to_nv12')
external int _d3d11VpBgraToNv12(
  Pointer<Void> vpCtx,
  Pointer<Void> vpDevice,
  Pointer<Void> vpContext,
  Pointer<Void> srcBgraTex,
  int crossDevice,
  int dstSubresource,
  Pointer<Void> dstNv12Tex,
);

/// Sets [BindFlags] on an [AVD3D11VAFramesContext] before
/// [av_hwframe_ctx_init]. For VideoProcessor output: include
/// `D3D11_BIND_RENDER_TARGET (0x20)`. For QSV/MF encode: also include
/// `D3D11_BIND_VIDEO_ENCODER (0x400)`. Must be called after
/// `av_hwframe_ctx_alloc` and before `av_hwframe_ctx_init`. Windows-only.
@Native<Void Function(Pointer<Void>, Uint32)>(
  symbol: 'miniav_shim_d3d11va_frames_set_bind_flags',
)
external void _d3d11vaFramesSetBindFlags(Pointer<Void> hwFramesRef, int flags);
// ---- Test-only helpers (Windows; safe no-op linkage on POSIX) ----------
//
// These produce an NT-shared BGRA D3D11 texture without depending on miniav.
// Used by `test/d3d11_hw_encoder_test.dart`. Calling them on a non-Windows
// or non-shim build will throw at lookup time; guard with `Platform.isWindows`
// + `FfmpegShim.tryLoad`.

@Native<Pointer<Void> Function(Uint32, Uint32)>(
  symbol: 'miniav_shim_test_create_shared_bgra',
)
external Pointer<Void> _testCreateSharedBgra(int width, int height);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_test_texture_handle',
)
external Pointer<Void> _testTextureHandle(Pointer<Void> t);

@Native<Int32 Function(Pointer<Void>, Uint32)>(
  symbol: 'miniav_shim_test_fill_bgra',
)
external int _testFillBgra(Pointer<Void> t, int tag);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_test_destroy')
external void _testDestroy(Pointer<Void> t);

// ---- macOS / iOS: VideoToolbox interop ----------------------------------
//
// Bound on every platform (as opaque symbols) but only callable on Apple
// targets — the shim only exports them under `__APPLE__`. Callers must
// guard with `Platform.isMacOS || Platform.isIOS` AND `FfmpegShim.tryLoad`.

@Native<Int32 Function(Pointer<Void>, Pointer<Void>, Int32, Int32)>(
  symbol: 'miniav_shim_vt_attach_pixelbuffer',
)
external int _vtAttachPixelbuffer(
  Pointer<Void> avframe,
  Pointer<Void> cvpixelbuf,
  int width,
  int height,
);

@Native<Pointer<Void> Function(Pointer<Void>, Uint32)>(
  symbol: 'miniav_shim_vt_pixbuf_from_iosurface',
)
external Pointer<Void> _vtPixbufFromIosurface(
  Pointer<Void> iosurface,
  int osTypePixfmt,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_vt_pixbuf_release')
external void _vtPixbufRelease(Pointer<Void> cvpixelbuf);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_vt_pixbuf_width')
external int _vtPixbufWidth(Pointer<Void> cvpixelbuf);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_vt_pixbuf_height')
external int _vtPixbufHeight(Pointer<Void> cvpixelbuf);

@Native<Uint32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_vt_pixbuf_pixel_format',
)
external int _vtPixbufPixelFormat(Pointer<Void> cvpixelbuf);

// ---- Linux: VAAPI / DRM-PRIME interop -----------------------------------

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Int32>,
    Int32,
    Pointer<Int64>,
    Pointer<Int64>,
    Pointer<Int64>,
    Int32,
    Int32,
    Uint32,
    Uint64,
    Pointer<Void>,
  )
>(symbol: 'miniav_shim_vaapi_map_dmabuf')
external int _vaapiMapDmabuf(
  Pointer<Void> vaapiHwframesRef,
  Pointer<Int32> fds,
  int nbFds,
  Pointer<Int64> sizes,
  Pointer<Int64> offsets,
  Pointer<Int64> pitches,
  int width,
  int height,
  int drmFourcc,
  int modifier,
  Pointer<Void> outVaapiFrame,
);

// ---- Android: AHardwareBuffer interop -----------------------------------

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_ahb_lock_read',
)
external Pointer<Void> _ahbLockRead(Pointer<Void> ahb);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_ahb_lock_address',
)
external Pointer<Void> _ahbLockAddress(Pointer<Void> lock);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_ahb_lock_stride')
external int _ahbLockStride(Pointer<Void> lock);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_ahb_lock_width')
external int _ahbLockWidth(Pointer<Void> lock);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_ahb_lock_height')
external int _ahbLockHeight(Pointer<Void> lock);

@Native<Uint32 Function(Pointer<Void>)>(symbol: 'miniav_shim_ahb_lock_format')
external int _ahbLockFormat(Pointer<Void> lock);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_ahb_unlock')
external void _ahbUnlock(Pointer<Void> lock);

// ---- Audio encoder helpers (cross-platform) -----------------------------

@Native<Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int64)>(
  symbol: 'miniav_shim_codec_set_audio_params',
)
external int _codecSetAudioParams(
  Pointer<Void> ctx,
  int sampleFmt,
  int sampleRate,
  int channels,
  int bitRate,
);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_codec_get_frame_size',
)
external int _codecGetFrameSize(Pointer<Void> ctx);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_codec_pick_sample_fmt',
)
external int _codecPickSampleFmt(Pointer<Void> codec);

@Native<Int32 Function(Pointer<Void>, Int32)>(
  symbol: 'miniav_shim_codec_supports_sample_fmt',
)
external int _codecSupportsSampleFmt(Pointer<Void> codec, int sampleFmt);

@Native<Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32)>(
  symbol: 'miniav_shim_audio_frame_setup',
)
external int _audioFrameSetup(
  Pointer<Void> frame,
  int sampleFmt,
  int sampleRate,
  int channels,
  int nbSamples,
);

@Native<Void Function(Pointer<Void>, Int64)>(
  symbol: 'miniav_shim_audio_frame_set_pts',
)
external void _audioFrameSetPts(Pointer<Void> frame, int pts);

// ---- Decoder helpers (cross-platform) ------------------------------------

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_codec_set_extradata',
)
external int _codecSetExtradata(Pointer<Void> ctx, Pointer<Uint8> data, int size);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_frame_sample_rate',
)
external int _frameSampleRate(Pointer<Void> frame);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_frame_nb_channels',
)
external int _frameNbChannels(Pointer<Void> frame);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_frame_colorspace',
)
external int _frameColorspace(Pointer<Void> frame);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'miniav_shim_frame_color_range',
)
external int _frameColorRange(Pointer<Void> frame);

// ---- Demux byte pipe + open helpers (cross-platform, ABI v15) -------------

@Native<Pointer<Void> Function(Int64)>(symbol: 'miniav_shim_bytepipe_create')
external Pointer<Void> _bytepipeCreate(int capacity);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_bytepipe_write',
)
external int _bytepipeWrite(Pointer<Void> pipe, Pointer<Uint8> data, int len);

@Native<Int64 Function(Pointer<Void>)>(symbol: 'miniav_shim_bytepipe_buffered')
external int _bytepipeBuffered(Pointer<Void> pipe);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_bytepipe_close')
external void _bytepipeClose(Pointer<Void> pipe);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_bytepipe_destroy')
external void _bytepipeDestroy(Pointer<Void> pipe);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_bytepipe_read',
)
external int _bytepipeRead(Pointer<Void> pipe, Pointer<Uint8> dst, int maxLen);

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_avio_out_pipe_create',
)
external Pointer<Void> _avioOutPipeCreate(Pointer<Void> pipe);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_avio_out_free')
external void _avioOutFree(Pointer<Void> avio);

@Native<Pointer<Void> Function()>(symbol: 'miniav_shim_memsink_create')
external Pointer<Void> _memsinkCreate();

@Native<Pointer<Void> Function(Pointer<Void>)>(
  symbol: 'miniav_shim_avio_out_memsink_create',
)
external Pointer<Void> _avioOutMemsinkCreate(Pointer<Void> sink);

@Native<Int64 Function(Pointer<Void>)>(symbol: 'miniav_shim_memsink_size')
external int _memsinkSize(Pointer<Void> sink);

@Native<Int32 Function(Pointer<Void>, Int64, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_memsink_read',
)
external int _memsinkRead(
  Pointer<Void> sink,
  int offset,
  Pointer<Uint8> dst,
  int maxLen,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_memsink_destroy')
external void _memsinkDestroy(Pointer<Void> sink);

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)>(
  symbol: 'miniav_shim_open_input_pipe',
)
external Pointer<Void> _openInputPipe(Pointer<Void> pipe, Pointer<Int32> err);

@Native<Pointer<Void> Function(Pointer<Utf8>, Pointer<Int32>)>(
  symbol: 'miniav_shim_open_input_url',
)
external Pointer<Void> _openInputUrl(Pointer<Utf8> url, Pointer<Int32> err);

@Native<Pointer<Void> Function(Pointer<Uint8>, Int64, Pointer<Int32>)>(
  symbol: 'miniav_shim_open_input_bytes',
)
external Pointer<Void> _openInputBytes(
  Pointer<Uint8> data,
  int len,
  Pointer<Int32> err,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_close_input')
external void _closeInput(Pointer<Void> fmt);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_close_input_bytes')
external void _closeInputBytes(Pointer<Void> fmt);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_fmt_nb_streams')
external int _fmtNbStreams(Pointer<Void> fmt);

@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  symbol: 'miniav_shim_fmt_stream',
)
external Pointer<Void> _fmtStream(Pointer<Void> fmt, int index);

@Native<Int64 Function(Pointer<Void>)>(symbol: 'miniav_shim_fmt_duration_us')
external int _fmtDurationUs(Pointer<Void> fmt);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_fmt_is_seekable')
external int _fmtIsSeekable(Pointer<Void> fmt);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_par_sample_rate')
external int _parSampleRate(Pointer<Void> par);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_par_nb_channels')
external int _parNbChannels(Pointer<Void> par);

@Native<Uint32 Function()>(symbol: 'miniav_shim_avcodec_version')
external int _avcodecVersion();

@Native<Uint32 Function()>(symbol: 'miniav_shim_abi_version')
external int _abiVersion();

// The Media Foundation hardware decoder (miniav_shim_mfdec_*) moved to the
// standalone, FFmpeg-free miniav_tools_codecs_native asset — see
// miniav_tools_codecs/lib/src/codecs_native.dart.

// ---- FFmpeg log forwarding (v8+) ----------------------------------------
//
// Dart cannot bind av_log_set_callback directly (va_list is not expressible
// in dart:ffi). The shim wraps it: we pass a simple (int level, char* msg)
// callback and the shim formats + forwards each av_log call.

/// Native function type for the Dart-side FFmpeg log callback.
typedef _FfmpegLogCbNative = Void Function(Int32 level, Pointer<Char> message);

@Native<Void Function(Pointer<NativeFunction<_FfmpegLogCbNative>>)>(
  symbol: 'miniav_shim_set_ffmpeg_log_callback',
)
external void _setFfmpegLogCallback(
  Pointer<NativeFunction<_FfmpegLogCbNative>> cb,
);

@Native<Void Function(Int32)>(symbol: 'miniav_shim_set_ffmpeg_log_level')
external void _setFfmpegLogLevel(int level);

@Native<Void Function(Pointer<Char>)>(symbol: 'miniav_shim_free_log_message')
external void _freeLogMessage(Pointer<Char> msg);

// =============================================================================
// Public façade
// =============================================================================

/// Façade around the native shim. Use [tryLoad] to obtain an instance —
/// returns `null` if the shim asset isn't bundled (Stage B unavailable).
class FfmpegShim {
  FfmpegShim._();

  /// Currently expected shim ABI. Bump in lock-step with `shim.c`.
  static const int kExpectedAbiVersion = 18;

  static FfmpegShim? _instance;
  static bool _attemptedLoad = false;

  /// Returns the shim if the native asset is loadable and ABI-compatible,
  /// otherwise `null`. Cached after the first call.
  ///
  /// NOTE: the shim DLL imports avcodec/avutil. On Windows those imports are
  /// resolved at load time (not lazily). If FFmpeg has not yet been loaded
  /// via `ensureFFmpegLoaded()` / `tryLoadFFmpeg()`, the shim load will fail
  /// because the OS DLL search path doesn't include the auto-downloader's
  /// cache directory. We detect that case via [bindings.tryLoadFFmpeg] and
  /// return `null` WITHOUT caching the failure, so a later call (after
  /// FFmpeg has been loaded) can succeed.
  static FfmpegShim? tryLoad() {
    if (_instance != null) return _instance;
    if (_attemptedLoad) return null;
    // Don't poison the cache if FFmpeg isn't loaded yet — the shim's
    // imports won't resolve and we'd permanently disable Stage B.
    if (!bindings.tryLoadFFmpeg()) return null;
    _attemptedLoad = true;
    try {
      final abi = _abiVersion();
      if (abi != kExpectedAbiVersion) {
        ffmpegToolsLog(
          MiniAVLogLevel.error,
          'miniav_tools_ffmpeg: shim reports ABI $abi, expected '
          '$kExpectedAbiVersion. Rebuild with `dart pub get` (or '
          '`flutter clean && flutter pub get`) to refresh the build hook.',
        );
        return null;
      }
      return _instance = FfmpegShim._();
    } catch (_) {
      // Native asset not loadable — Stage B simply unavailable.
      return null;
    }
  }

  /// True if [tryLoad] has succeeded.
  static bool get isAvailable => _instance != null;

  /// Test hook.
  static void resetForTests() {
    _instance = null;
    _attemptedLoad = false;
  }

  // ---- Wrappers -------------------------------------------------------------

  void setHwDeviceCtx(Pointer<Void> ctx, Pointer<Void> ref) =>
      _setHwDeviceCtx(ctx, ref);

  void setHwFramesCtx(Pointer<Void> ctx, Pointer<Void> ref) =>
      _setHwFramesCtx(ctx, ref);

  /// Sets [AVFrame.hw_frames_ctx] on a native AVFrame pointer so that
  /// [av_hwframe_map] can resolve the target hwframes context for mapping
  /// a D3D11VA frame to a derived QSV frame.
  void avFrameSetHwFramesCtx(
    Pointer<Void> frame,
    Pointer<Void> hwFramesCtxRef,
  ) => _avFrameSetHwFramesCtx(frame, hwFramesCtxRef);

  /// Windows-only.  Ensures the calling thread is in the COM MTA apartment
  /// (a hard requirement for `h264_mf` / `h264_qsv` / `hevc_mf` / `hevc_qsv`
  /// encoder init).  No-op on non-Windows or when COM is already MTA.
  /// Returns 0 on success, -1 if the thread is locked into STA.
  int ensureMta() {
    if (!Platform.isWindows) return 0;
    return _ensureMta();
  }

  Pointer<Void> hwFramesData(Pointer<Void> ref) => _hwFramesData(ref);

  void hwFramesSetParams(
    Pointer<Void> ctx, {
    required int format,
    required int swFormat,
    required int width,
    required int height,
    required int initialPoolSize,
  }) =>
      _hwFramesSetParams(ctx, format, swFormat, width, height, initialPoolSize);

  Pointer<Void> hwDevData(Pointer<Void> ref) => _hwDevData(ref);

  /// Windows-only. Asserts on other platforms — call sites should already
  /// guard with `Platform.isWindows`.
  void d3d11SetDevice(Pointer<Void> hwdevCtx, Pointer<Void> id3d11Device) {
    assert(Platform.isWindows, 'd3d11SetDevice is Windows-only');
    _d3d11SetDevice(hwdevCtx, id3d11Device);
  }

  /// Returns the ID3D11Device* that FFmpeg either accepted (via setter)
  /// or allocated when `av_hwdevice_ctx_init` was called with a NULL
  /// device. Windows-only.
  Pointer<Void> d3d11GetDevice(Pointer<Void> hwdevCtx) {
    assert(Platform.isWindows, 'd3d11GetDevice is Windows-only');
    return _d3d11GetDevice(hwdevCtx);
  }

  /// Returns the ID3D11DeviceContext* (immediate context) belonging to
  /// the FFmpeg-owned D3D11Device. Windows-only.
  Pointer<Void> d3d11GetContext(Pointer<Void> hwdevCtx) {
    assert(Platform.isWindows, 'd3d11GetContext is Windows-only');
    return _d3d11GetContext(hwdevCtx);
  }

  /// Opens a process-shared DXGI NT HANDLE on `id3d11Device`. Returns the
  /// opened ID3D11Texture2D* or `nullptr` on failure. Caller MUST release
  /// the returned pointer with [d3d11Release]. Windows-only.
  Pointer<Void> d3d11OpenSharedHandle(
    Pointer<Void> id3d11Device,
    Pointer<Void> ntHandle,
  ) {
    assert(Platform.isWindows, 'd3d11OpenSharedHandle is Windows-only');
    return _d3d11OpenSharedHandle(id3d11Device, ntHandle);
  }

  /// GPU-only `ID3D11DeviceContext::CopySubresourceRegion` followed by a
  /// `D3D11_QUERY_EVENT` fence + Flush + bounded poll, ensuring the copy
  /// has actually executed on the GPU before returning. This is mandatory
  /// before handing the destination texture to NVENC/AMF/QSV — those
  /// engines do NOT serialise with the calling immediate context.
  ///
  /// Use explicit subresources because FFmpeg's D3D11VA hwframes pool is a
  /// `Texture2DArray` (one texture, ArraySize = pool size); the slice
  /// index lives in `AVFrame::data[1]` cast through `intptr_t`. All
  /// arguments belong to the same FFmpeg-owned D3D11 device. Windows-only.
  void d3d11CopyResource(
    Pointer<Void> device,
    Pointer<Void> immediateContext,
    Pointer<Void> dstTex,
    int dstSubresource,
    Pointer<Void> srcTex,
    int srcSubresource,
  ) {
    assert(Platform.isWindows, 'd3d11CopyResource is Windows-only');
    _d3d11CopyResource(
      device,
      immediateContext,
      dstTex,
      dstSubresource,
      srcTex,
      srcSubresource,
    );
  }

  /// `IUnknown::Release(p)`. Windows-only.
  void d3d11Release(Pointer<Void> p) {
    assert(Platform.isWindows, 'd3d11Release is Windows-only');
    _d3d11Release(p);
  }

  /// Returns the DXGI `VendorId` of the adapter backing [id3d11Device]
  /// (e.g. `0x8086` Intel, `0x10DE` NVIDIA, `0x1002` AMD). Returns `0` on
  /// failure. Windows-only.
  int d3d11GetVendorId(Pointer<Void> id3d11Device) {
    assert(Platform.isWindows, 'd3d11GetVendorId is Windows-only');
    return _d3d11GetVendorId(id3d11Device);
  }

  /// Creates a sibling `ID3D11Device` on the same DXGI adapter as
  /// [existingDevice] but with `D3D11_CREATE_DEVICE_VIDEO_SUPPORT` enabled.
  ///
  /// MediaFoundation MFTs require this flag on the device they use to encode.
  /// Dawn/WebGPU devices omit it (it has overhead and is useless for
  /// graphics/compute). Since both devices live on the same adapter,
  /// `OpenSharedResource1` on NT handles succeeds from either device.
  ///
  /// The caller MUST release the returned pointer with [d3d11Release] once it
  /// is no longer needed (after `d3d11SetDevice` — which AddRefs internally —
  /// or after an `av_hwdevice_ctx_init` error). Returns `nullptr` on failure.
  /// Windows-only.
  Pointer<Void> d3d11CreateVideoDeviceFor(Pointer<Void> existingDevice) {
    assert(Platform.isWindows, 'd3d11CreateVideoDeviceFor is Windows-only');
    return _d3d11CreateVideoDeviceFor(existingDevice);
  }

  // ---- D3D11 VideoProcessor — BGRA→NV12 ----------------------------------

  /// Create a VideoProcessor context for BGRA→NV12 GPU color-space conversion.
  /// [id3d11Device] must have `D3D11_CREATE_DEVICE_VIDEO_SUPPORT` (the sibling
  /// device from [d3d11CreateVideoDeviceFor]). Returns `nullptr` on failure.
  /// Must be destroyed with [d3d11VpDestroy]. Windows-only.
  Pointer<Void> d3d11VpCreate(
    Pointer<Void> id3d11Device,
    Pointer<Void> id3d11Context,
    int width,
    int height,
  ) {
    assert(Platform.isWindows, 'd3d11VpCreate is Windows-only');
    return _d3d11VpCreate(id3d11Device, id3d11Context, width, height);
  }

  /// Destroy a VideoProcessor context created by [d3d11VpCreate]. Windows-only.
  void d3d11VpDestroy(Pointer<Void> vpCtx) {
    assert(Platform.isWindows, 'd3d11VpDestroy is Windows-only');
    _d3d11VpDestroy(vpCtx);
  }

  /// GPU BGRA→NV12 color-space conversion via D3D11 VideoProcessor.
  ///
  /// [srcBgraTex] is the BGRA source `ID3D11Texture2D*`.
  /// [crossDevice]: if `true`, `srcBgraTex` is on a different device (e.g.
  /// Dawn's) and the shim will import it via `IDXGIResource::GetSharedHandle +
  /// OpenSharedResource` (requires `D3D11_RESOURCE_MISC_SHARED`).  If `false`,
  /// `srcBgraTex` is already on the VP device.
  /// [dstSubresource] is the `Texture2DArray` slice index from `AVFrame::data[1]`.
  /// [dstNv12Tex] is the `Texture2DArray` `ID3D11Texture2D*` from `AVFrame::data[0]`.
  ///
  /// Returns 0 on success, negative on failure. Windows-only.
  int d3d11VpBgraToNv12(
    Pointer<Void> vpCtx,
    Pointer<Void> vpDevice,
    Pointer<Void> vpContext,
    Pointer<Void> srcBgraTex, {
    required bool crossDevice,
    required int dstSubresource,
    required Pointer<Void> dstNv12Tex,
  }) {
    assert(Platform.isWindows, 'd3d11VpBgraToNv12 is Windows-only');
    return _d3d11VpBgraToNv12(
      vpCtx,
      vpDevice,
      vpContext,
      srcBgraTex,
      crossDevice ? 1 : 0,
      dstSubresource,
      dstNv12Tex,
    );
  }

  /// Sets `BindFlags` on an `AVD3D11VAFramesContext` before
  /// `av_hwframe_ctx_init`. Include `D3D11_BIND_RENDER_TARGET (0x20)` to
  /// allow VideoProcessor output views, and `D3D11_BIND_VIDEO_ENCODER (0x400)`
  /// for QSV/MF encode. Windows-only.
  void d3d11vaFramesSetBindFlags(Pointer<Void> hwFramesRef, int bindFlags) {
    assert(Platform.isWindows, 'd3d11vaFramesSetBindFlags is Windows-only');
    _d3d11vaFramesSetBindFlags(hwFramesRef, bindFlags);
  }

  /// **Test-only** — create a producer-side ID3D11Device + a BGRA
  /// NT-shareable Texture2D (1 mip, 1 slice). Returns an opaque handle to
  /// the test-texture struct, or `nullptr` on failure. Caller MUST pair
  /// every successful call with [testDestroyTexture]. Windows-only.
  Pointer<Void> testCreateSharedBgra(int width, int height) {
    assert(Platform.isWindows, 'testCreateSharedBgra is Windows-only');
    return _testCreateSharedBgra(width, height);
  }

  /// **Test-only** — returns the duplicated NT HANDLE (as `Pointer<Void>`)
  /// for the texture created via [testCreateSharedBgra]. The handle is
  /// owned by the test-texture struct — do NOT call CloseHandle on it.
  Pointer<Void> testTextureHandle(Pointer<Void> t) {
    assert(Platform.isWindows, 'testTextureHandle is Windows-only');
    return _testTextureHandle(t);
  }

  /// **Test-only** — fill the test texture with a deterministic BGRA
  /// pattern parameterised by [tag] (used as the red channel of checker
  /// squares; lets a test verify per-frame uniqueness). Returns 0 on
  /// success, negative on failure.
  int testFillBgra(Pointer<Void> t, int tag) {
    assert(Platform.isWindows, 'testFillBgra is Windows-only');
    return _testFillBgra(t, tag);
  }

  /// **Test-only** — release the test texture, its device, immediate
  /// context, and the duplicated NT HANDLE.
  void testDestroyTexture(Pointer<Void> t) {
    assert(Platform.isWindows, 'testDestroyTexture is Windows-only');
    _testDestroy(t);
  }

  // ---- VideoToolbox (macOS / iOS) -----------------------------------------

  /// Attach a `CVPixelBufferRef` to an `AVFrame` as `AV_PIX_FMT_VIDEOTOOLBOX`.
  /// The frame retains its own reference; the caller can release theirs
  /// after this call. Returns 0 on success. Apple-only.
  int vtAttachPixelbuffer(
    Pointer<Void> avframe,
    Pointer<Void> cvpixelbuf, {
    required int width,
    required int height,
  }) {
    assert(
      Platform.isMacOS || Platform.isIOS,
      'vtAttachPixelbuffer is Apple-only',
    );
    return _vtAttachPixelbuffer(avframe, cvpixelbuf, width, height);
  }

  /// Wrap an existing `IOSurfaceRef` in a fresh `CVPixelBufferRef`
  /// (zero-copy). Caller owns one retain — release with [vtPixbufRelease]
  /// or hand to [vtAttachPixelbuffer] (which retains internally).
  Pointer<Void> vtPixbufFromIosurface(
    Pointer<Void> iosurface, {
    int osTypePixfmt = 0,
  }) {
    assert(
      Platform.isMacOS || Platform.isIOS,
      'vtPixbufFromIosurface is Apple-only',
    );
    return _vtPixbufFromIosurface(iosurface, osTypePixfmt);
  }

  void vtPixbufRelease(Pointer<Void> cvpixelbuf) {
    assert(Platform.isMacOS || Platform.isIOS, 'vtPixbufRelease is Apple-only');
    _vtPixbufRelease(cvpixelbuf);
  }

  int vtPixbufWidth(Pointer<Void> cvpixelbuf) => _vtPixbufWidth(cvpixelbuf);
  int vtPixbufHeight(Pointer<Void> cvpixelbuf) => _vtPixbufHeight(cvpixelbuf);
  int vtPixbufPixelFormat(Pointer<Void> cvpixelbuf) =>
      _vtPixbufPixelFormat(cvpixelbuf);

  // ---- VAAPI / DRM-PRIME (Linux) ------------------------------------------

  /// Import up to 4 dmabuf FDs into a VAAPI hwframe via DRM-PRIME direct
  /// mapping (no GPU copy). Populates [outVaapiFrame] which is then ready
  /// for `avcodec_send_frame`. Returns 0 on success, negative AVERROR
  /// otherwise. Linux-only (non-Android).
  int vaapiMapDmabuf({
    required Pointer<Void> vaapiHwframesRef,
    required Pointer<Int32> fds,
    required int nbFds,
    required Pointer<Int64> sizes,
    required Pointer<Int64> offsets,
    required Pointer<Int64> pitches,
    required int width,
    required int height,
    required int drmFourcc,
    required int modifier,
    required Pointer<Void> outVaapiFrame,
  }) {
    assert(Platform.isLinux, 'vaapiMapDmabuf is Linux-only (non-Android)');
    return _vaapiMapDmabuf(
      vaapiHwframesRef,
      fds,
      nbFds,
      sizes,
      offsets,
      pitches,
      width,
      height,
      drmFourcc,
      modifier,
      outVaapiFrame,
    );
  }

  // ---- AHardwareBuffer (Android) ------------------------------------------

  /// Lock an `AHardwareBuffer*` for CPU read; returns an opaque lock
  /// handle, or `nullptr` on failure. Must be paired with [ahbUnlock].
  /// Android-only (API 26+).
  Pointer<Void> ahbLockRead(Pointer<Void> ahb) {
    assert(Platform.isAndroid, 'ahbLockRead is Android-only');
    return _ahbLockRead(ahb);
  }

  Pointer<Void> ahbLockAddress(Pointer<Void> lock) => _ahbLockAddress(lock);
  int ahbLockStride(Pointer<Void> lock) => _ahbLockStride(lock);
  int ahbLockWidth(Pointer<Void> lock) => _ahbLockWidth(lock);
  int ahbLockHeight(Pointer<Void> lock) => _ahbLockHeight(lock);
  int ahbLockFormat(Pointer<Void> lock) => _ahbLockFormat(lock);

  void ahbUnlock(Pointer<Void> lock) {
    assert(Platform.isAndroid, 'ahbUnlock is Android-only');
    _ahbUnlock(lock);
  }

  int avcodecVersion() => _avcodecVersion();
  int abiVersion() => _abiVersion();

  // ---- Audio encoder helpers (cross-platform) -----------------------------

  /// Configure sample_fmt + sample_rate + ch_layout (default mask) +
  /// bit_rate on an AVCodecContext. Returns 0 on success, negative
  /// AVERROR on failure.
  int codecSetAudioParams(
    Pointer<Void> ctx, {
    required int sampleFmt,
    required int sampleRate,
    required int channels,
    required int bitRate,
  }) => _codecSetAudioParams(ctx, sampleFmt, sampleRate, channels, bitRate);

  /// Read the encoder's required samples-per-channel per frame after
  /// `avcodec_open2`. Returns 0 if the codec has no fixed frame size.
  int codecGetFrameSize(Pointer<Void> ctx) => _codecGetFrameSize(ctx);

  /// Returns the encoder's preferred sample format (the first entry in
  /// `codec->sample_fmts`), or -1 if unavailable.
  int codecPickSampleFmt(Pointer<Void> codec) => _codecPickSampleFmt(codec);

  /// Returns true if the codec lists `sampleFmt` in its supported set.
  bool codecSupportsSampleFmt(Pointer<Void> codec, int sampleFmt) =>
      _codecSupportsSampleFmt(codec, sampleFmt) != 0;

  /// Configure an audio AVFrame and call `av_frame_get_buffer`. Returns 0
  /// on success.
  int audioFrameSetup(
    Pointer<Void> frame, {
    required int sampleFmt,
    required int sampleRate,
    required int channels,
    required int nbSamples,
  }) => _audioFrameSetup(frame, sampleFmt, sampleRate, channels, nbSamples);

  /// Set just `AVFrame::pts`.
  void audioFrameSetPts(Pointer<Void> frame, int pts) =>
      _audioFrameSetPts(frame, pts);

  // ---- Decoder helpers (cross-platform) ------------------------------------

  /// Copy [bytes] into `ctx->extradata` (av_mallocz'd with the decode-side
  /// padding, owned by the codec context). Call BEFORE `avcodec_open2`.
  /// Returns 0 on success, negative AVERROR on failure.
  int codecSetExtradata(Pointer<Void> ctx, Uint8List bytes) {
    final buf = calloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      return _codecSetExtradata(ctx, buf, bytes.length);
    } finally {
      calloc.free(buf);
    }
  }

  /// `AVFrame::sample_rate` of a decoded audio frame (0 if unset).
  int frameSampleRate(Pointer<Void> frame) => _frameSampleRate(frame);

  /// `AVFrame::ch_layout.nb_channels` of a decoded audio frame (0 if unset).
  int frameNbChannels(Pointer<Void> frame) => _frameNbChannels(frame);

  /// `AVFrame::colorspace` of a decoded video frame — raw AVColorSpace enum
  /// (BT709=1, UNSPECIFIED=2, BT470BG=5, SMPTE170M=6, BT2020=9/10).
  int frameColorspace(Pointer<Void> frame) => _frameColorspace(frame);

  /// `AVFrame::color_range` — raw AVColorRange enum (UNSPECIFIED=0,
  /// MPEG/limited=1, JPEG/full=2).
  int frameColorRange(Pointer<Void> frame) => _frameColorRange(frame);

  // ---- Demux byte pipe + open helpers --------------------------------------

  /// Allocate a blocking byte pipe (see shim.c). [capacityBytes] <= 0 picks
  /// the 16 MiB default. Returns nullptr on OOM.
  Pointer<Void> bytepipeCreate(int capacityBytes) =>
      _bytepipeCreate(capacityBytes);

  /// Feed bytes. Returns bytes accepted (may be short when the ring is
  /// full — retry the remainder later), or -1 if the pipe is closed.
  /// Never blocks; safe from any isolate.
  int bytepipeWrite(Pointer<Void> pipe, Uint8List data, int offset, int len) {
    final buf = calloc<Uint8>(len);
    try {
      buf.asTypedList(len).setRange(0, len, data, offset);
      return _bytepipeWrite(pipe, buf, len);
    } finally {
      calloc.free(buf);
    }
  }

  /// Bytes currently buffered (feed-side backpressure signal).
  int bytepipeBuffered(Pointer<Void> pipe) => _bytepipeBuffered(pipe);

  /// Signal end-of-stream AND unblock a reader waiting for data. Idempotent.
  /// Call before closing a demuxer whose worker may be starved.
  void bytepipeClose(Pointer<Void> pipe) => _bytepipeClose(pipe);

  /// Non-blocking drain (output-pipe side): copies up to [scratch].length
  /// bytes into [scratch], returns the count (0 when empty).
  int bytepipeRead(Pointer<Void> pipe, Pointer<Uint8> scratch, int maxLen) =>
      _bytepipeRead(pipe, scratch, maxLen);

  /// Writable AVIOContext over a byte pipe (muxing to bytes/callback
  /// outputs). Free with [avioOutFree], never `avio_closep`.
  Pointer<Void> avioOutPipeCreate(Pointer<Void> pipe) =>
      _avioOutPipeCreate(pipe);

  void avioOutFree(Pointer<Void> avio) => _avioOutFree(avio);

  // ---- Seekable in-memory output sink (BytesMuxerOutput) -------------------

  Pointer<Void> memsinkCreate() => _memsinkCreate();

  /// Writable + SEEKABLE AVIOContext over a memory sink (plain MP4's moov
  /// rewrite / +faststart need seeks). Free with [avioOutFree].
  Pointer<Void> avioOutMemsinkCreate(Pointer<Void> sink) =>
      _avioOutMemsinkCreate(sink);

  int memsinkSize(Pointer<Void> sink) => _memsinkSize(sink);

  /// Copy the finished container out of the sink.
  Uint8List memsinkTakeBytes(Pointer<Void> sink) {
    final size = _memsinkSize(sink);
    final out = Uint8List(size);
    if (size == 0) return out;
    final scratch = calloc<Uint8>(size);
    try {
      final n = _memsinkRead(sink, 0, scratch, size);
      out.setRange(0, n < 0 ? 0 : n, scratch.asTypedList(size));
      return out;
    } finally {
      calloc.free(scratch);
    }
  }

  void memsinkDestroy(Pointer<Void> sink) => _memsinkDestroy(sink);

  /// Free the pipe. Only after the demuxer using it is closed.
  void bytepipeDestroy(Pointer<Void> pipe) => _bytepipeDestroy(pipe);

  /// Open + probe a demuxer over a byte pipe. Returns (fmtCtx, 0) or
  /// (nullptr, negative AVERROR).
  (Pointer<Void>, int) openInputPipe(Pointer<Void> pipe) {
    final err = calloc<Int32>();
    try {
      final fmt = _openInputPipe(pipe, err);
      return (fmt, err.value);
    } finally {
      calloc.free(err);
    }
  }

  /// Open + probe a demuxer over a file path / URL.
  (Pointer<Void>, int) openInputUrl(String url) {
    final p = url.toNativeUtf8();
    final err = calloc<Int32>();
    try {
      final fmt = _openInputUrl(p, err);
      return (fmt, err.value);
    } finally {
      calloc.free(p);
      calloc.free(err);
    }
  }

  /// Open + probe a demuxer over a fully-buffered container. The shim keeps
  /// a C-owned COPY of [bytes] (freed by [closeInputBytes]) and exposes it
  /// through a SEEKABLE AVIO — moov-at-end MP4s work.
  (Pointer<Void>, int) openInputBytes(Uint8List bytes) {
    final buf = calloc<Uint8>(bytes.length);
    final err = calloc<Int32>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final fmt = _openInputBytes(buf, bytes.length, err);
      return (fmt, err.value);
    } finally {
      calloc.free(buf);
      calloc.free(err);
    }
  }

  /// Close either open flavour (frees the custom AVIO for pipe inputs).
  void closeInput(Pointer<Void> fmt) => _closeInput(fmt);

  /// Close a [openInputBytes]-opened input (also frees the C data copy).
  void closeInputBytes(Pointer<Void> fmt) => _closeInputBytes(fmt);

  int fmtNbStreams(Pointer<Void> fmt) => _fmtNbStreams(fmt);
  Pointer<Void> fmtStream(Pointer<Void> fmt, int index) =>
      _fmtStream(fmt, index);

  /// Container duration in µs, or -1 when unknown (live pipes).
  int fmtDurationUs(Pointer<Void> fmt) => _fmtDurationUs(fmt);
  bool fmtIsSeekable(Pointer<Void> fmt) => _fmtIsSeekable(fmt) != 0;

  /// `AVCodecParameters` audio fields (beyond the Dart-mapped prefix).
  int parSampleRate(Pointer<Void> par) => _parSampleRate(par);
  int parNbChannels(Pointer<Void> par) => _parNbChannels(par);

  // ---- FFmpeg log forwarding (v8+) ----------------------------------------

  /// Active log NativeCallable — kept alive while a callback is registered.
  NativeCallable<_FfmpegLogCbNative>? _ffmpegLogCallable;

  /// Set the FFmpeg log level using av_log_set_level.
  ///
  /// Standard AV_LOG_* constants: `quiet=-8`, `error=16`, `warning=24`,
  /// `info=32`, `verbose=40`, `debug=48`.
  void setFfmpegLogLevel(int avLevel) => _setFfmpegLogLevel(avLevel);

  /// Decode a null-terminated C string from native memory using
  /// [Utf8Decoder.allowMalformed] so that FFmpeg log messages that contain
  /// non-UTF-8 bytes (e.g. Latin-1 filenames on Windows) never throw.
  static String _decodeCString(Pointer<Char> ptr) {
    if (ptr.address == 0) return '';
    final bytes = ptr.cast<Uint8>();
    var len = 0;
    while (bytes[len] != 0) len++;
    final data = Uint8List.view(bytes.asTypedList(len).buffer, 0, len);
    return const Utf8Decoder(allowMalformed: true).convert(data);
  }

  /// Install (or replace) a callback that receives formatted FFmpeg log
  /// lines. [callback] receives the AV_LOG_* level integer and the already-
  /// formatted message string. Pass `null` to restore FFmpeg's default logger
  /// (which writes to native stderr — not visible in most Flutter apps).
  ///
  /// The callback is dispatched on the Dart event loop via a `listener`
  /// NativeCallable, so it is safe to run arbitrary Dart code (e.g. forward
  /// to a logging framework — avoid `dart:io` `stderr`, which throws an
  /// uncatchable async error in console-less Windows GUI apps).
  void setFfmpegLogCallback(
    void Function(int level, String message)? callback,
  ) {
    final old = _ffmpegLogCallable;
    _ffmpegLogCallable = null;

    if (callback == null) {
      _setFfmpegLogCallback(Pointer.fromAddress(0));
      old?.close();
      return;
    }

    final nc = NativeCallable<_FfmpegLogCbNative>.listener((
      int level,
      Pointer<Char> msg,
    ) {
      final str = _decodeCString(msg).trimRight();
      // C++ heap-allocated this copy so the pointer stays valid across the
      // async NativeCallable.listener dispatch.  Free it after consuming.
      _freeLogMessage(msg);
      callback(level, str);
    });
    _setFfmpegLogCallback(nc.nativeFunction);
    _ffmpegLogCallable = nc;
    old?.close();
  }
}
