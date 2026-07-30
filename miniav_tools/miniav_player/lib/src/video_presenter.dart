/// GPU YUV420P → RGBA8 conversion + zero-copy presentation via minigpu_view,
/// with a CPU-readback fallback for platforms/adapters that have no zero-copy
/// present.
///
/// The fast path per frame:
///   1. ONE GPU upload of the decoded YUV420P planes (1.5 B/px — the only
///      CPU→GPU pixel traffic in the player), then a WGSL dispatch converts
///      to packed RGBA8 in a GPU storage buffer
///      ([GpuPlanarYuvToRgbaConverter] — byte-exact vs the CPU reference).
///   2. `SharedOutputTexture.copyFromBufferAsync` — GPU→GPU copy into the
///      shared D3D11 texture.
///   3. `MinigpuPreviewController.present` hands Flutter the texture HANDLE;
///      the raster thread samples it directly. Zero readback anywhere.
///
/// Resources ping-pong across two texture/buffer slots (the two-frame steady
/// state from the minigpu_view design): Flutter samples slot A while slot B
/// is written. The scheduler guarantees a single frame in flight.
///
/// FALLBACK: on a platform/adapter where `createSharedOutputTexture` returns
/// null (no minigpu_view zero-copy present plugin yet — macOS / Linux / Android
/// / iOS today), the presenter switches to [usingCpuFallback]: it converts the
/// YUV planes to RGBA in native C ([YuvRgbaConverter], ~1-2 ms/1080p — NOT a
/// Dart loop that would jank the UI isolate) and publishes a `ui.Image` via
/// [fallbackImage] for a plain `RawImage` to paint. Slower than zero-copy, but
/// it makes the player RUN everywhere instead of throwing.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:miniav_tools/miniav_tools.dart'
    show DecodedPixelLayout, YuvColorMatrix;
import 'package:miniav_tools_codecs/gpu.dart' show GpuPlanarYuvToRgbaConverter;
import 'package:minigpu/minigpu.dart';
import 'package:minigpu_view/minigpu_view.dart';

import 'frame_rgba_convert.dart'
    if (dart.library.js_interop) 'frame_rgba_convert_stub.dart';
import 'gpu_nv12_converter.dart';

/// Timing breakdown of the last presented frame, milliseconds.
class PresenterTimings {
  double convertMs = 0;
  double copyMs = 0;
  double presentMs = 0;
}

/// A borrowed EXTERNAL D3D11 shared RGBA texture (owned by a codec, not by the
/// presenter) as a minigpu_view present source. `texPtr` is the
/// `ID3D11Texture2D*`; `sharedHandle` the legacy DXGI shared HANDLE ANGLE
/// opens. Build it via [makeSharedTexturePreviewSource].
class _ExternalSharedTextureSource extends PreviewSource {
  const _ExternalSharedTextureSource(
      this.sharedHandle, this.texPtr, this.w, this.h);
  final int sharedHandle, texPtr, w, h;

  @override
  PreviewSourceKind get kind => PreviewSourceKind.nativeSharedTexture;

  @override
  ui.Size get size => ui.Size(w.toDouble(), h.toDouble());

  @override
  Map<String, Object?> toChannelMessage() => {
        'handle': texPtr,
        'sharedHandle': sharedHandle,
        'width': w,
        'height': h,
        'pixelFormat': 'rgba8',
      };
}

/// A minigpu_view [PreviewSource] for an EXTERNAL, already-RGBA D3D11 shared
/// texture — one a codec composes RGBA into and hands out as (legacy DXGI)
/// [sharedHandle] + `ID3D11Texture2D*` [texPtr]. Present it straight through a
/// [MinigpuPreviewController.present] (no minigpu compute / no presenter
/// needed). Centralises the nativeSharedTexture wiring consumers used to
/// hand-roll (livetensor gsplats, gui_bench).
PreviewSource makeSharedTexturePreviewSource(
        int sharedHandle, int texPtr, int width, int height) =>
    _ExternalSharedTextureSource(sharedHandle, texPtr, width, height);

class VideoFramePresenter {
  VideoFramePresenter(Minigpu gpu, this._controller)
    : _gpu = gpu,
      _converter = GpuPlanarYuvToRgbaConverter(gpu);

  final Minigpu _gpu;
  final MinigpuPreviewController _controller;

  /// One unified WGSL converter for every planar layout (i420/i422/i444 + 10-bit)
  /// in limited or full range — byte-identical to the C reference.
  final GpuPlanarYuvToRgbaConverter _converter;

  /// Lazily created on the first hardware (D3D11 NV12) frame — caches the
  /// NV12→RGBA shader + output buffers across frames.
  GpuNv12TextureToRgbaConverter? _nv12Converter;

  final List<SharedOutputTexture?> _textures = [null, null];
  int _slot = 0;
  int _w = 0;
  int _h = 0;
  bool _disposed = false;

  // --- CPU present fallback (no zero-copy shared-texture support) ------------
  bool _cpuFallback = false;
  YuvRgbaConverter? _cpuConv;

  // Reusable RGBA upload buffer for the GPU path's non-I420 (C-converted)
  // layouts — written from the C output, then copied into the shared texture.
  Buffer? _rgbaUpload;
  int _rgbaUploadBytes = 0;

  /// True once the presenter has fallen back to CPU YUV→RGBA + [fallbackImage]
  /// because this platform/adapter has no zero-copy shared-texture present.
  /// Determined lazily on the first frame.
  bool get usingCpuFallback => _cpuFallback;

  /// The most recently presented frame as a `ui.Image`, published only in
  /// [usingCpuFallback] mode (null otherwise, and null until the first CPU
  /// frame). A widget listens to this and paints it (see `MiniavPlayerView`).
  /// The presenter owns and disposes the image it replaces.
  final ValueNotifier<ui.Image?> fallbackImage = ValueNotifier<ui.Image?>(null);

  final PresenterTimings timings = PresenterTimings();

  /// The present currently in flight (convert → GPU copy → present). Held so
  /// [dispose] can wait for the native GPU work to finish before destroying
  /// the textures it operates on — otherwise a `close()` mid-present frees a
  /// texture out from under an outstanding async copy (use-after-free).
  Future<void>? _inFlight;

  /// Ensures the two ping-pong shared output textures exist for wxh. Returns
  /// `true` when they are ready (zero-copy path), or `false` after switching to
  /// [usingCpuFallback] — which happens the first time
  /// `createSharedOutputTexture` returns null (this platform/adapter has no
  /// zero-copy present). Once in fallback, stays there.
  bool _ensureTextures(int w, int h) {
    if (_cpuFallback) return false;
    if (_textures[0] != null && w == _w && h == _h) return true;
    for (var i = 0; i < 2; i++) {
      _textures[i]?.destroy();
      _textures[i] = null;
    }
    for (var i = 0; i < 2; i++) {
      final tex = _gpu.createSharedOutputTexture(w, h);
      if (tex == null) {
        // No zero-copy present on this platform/adapter → CPU fallback. Undo
        // any partial allocation and leave _w/_h unset so a later frame after
        // (a hypothetical) recovery re-checks.
        for (var j = 0; j < i; j++) {
          _textures[j]?.destroy();
          _textures[j] = null;
        }
        _cpuFallback = true;
        return false;
      }
      _textures[i] = tex;
    }
    _w = w;
    _h = h;
    return true;
  }

  /// Convert + present one tightly-packed planar YUV frame ([layout] +
  /// [fullRange] select the converter). The scheduler serialises calls (single
  /// frame in flight); slots ping-pong so the texture Flutter is sampling is
  /// never written.
  Future<void> presentYuv420p(
    Uint8List yuv,
    int w,
    int h, {
    DecodedPixelLayout layout = DecodedPixelLayout.i420,
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
  }) {
    if (_disposed) return Future<void>.value();
    final f = _present0(yuv, w, h, layout, fullRange, matrix);
    _inFlight = f;
    return f.whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
  }

  Future<void> _present0(Uint8List yuv, int w, int h, DecodedPixelLayout layout,
      bool fullRange, YuvColorMatrix matrix) async {
    if (!_ensureTextures(w, h)) {
      await _presentCpu(yuv, w, h, layout, fullRange, matrix);
      return;
    }
    final slot = _slot;
    _slot ^= 1;
    final tex = _textures[slot]!;

    final sw = Stopwatch()..start();
    final Buffer rgbaBuf;
    if (layout == DecodedPixelLayout.nv12 ||
        layout == DecodedPixelLayout.p010) {
      // Semi-planar (interleaved UV) doesn't fit the planar kernel — rare as a
      // CPU layout (the HW path handles NV12/P010 as textures); C-convert +
      // upload.
      rgbaBuf = await _cpuConvertToGpu(yuv, w, h, layout, fullRange, matrix);
    } else {
      // All planar layouts (i420/i422/i444 + 10-bit, limited/full) run fully on
      // the GPU through one unified WGSL kernel — zero readback.
      rgbaBuf = await _converter.convert(yuv, w, h,
          layout: layout, fullRange: fullRange, matrix: matrix, slot: slot);
    }
    timings.convertMs = sw.elapsedMicroseconds / 1000.0;

    sw.reset();
    await tex.copyFromBufferAsync(rgbaBuf);
    timings.copyMs = sw.elapsedMicroseconds / 1000.0;

    sw.reset();
    await _controller.present(tex.asPreviewSource());
    timings.presentMs = sw.elapsedMicroseconds / 1000.0;
  }

  /// C-convert [layout] YUV → RGBA and upload into a reusable GPU buffer.
  Future<Buffer> _cpuConvertToGpu(Uint8List yuv, int w, int h,
      DecodedPixelLayout layout, bool fullRange, YuvColorMatrix matrix) async {
    final conv = _cpuConv ??= YuvRgbaConverter();
    final rgba =
        conv.toRgba(layout, yuv, w, h, fullRange: fullRange, matrix: matrix);
    final bytes = w * h * 4;
    var buf = _rgbaUpload;
    if (buf == null || _rgbaUploadBytes != bytes) {
      buf?.destroy();
      buf = _gpu.createBuffer(bytes, BufferDataType.uint8);
      _rgbaUpload = buf;
      _rgbaUploadBytes = bytes;
    }
    await buf.write(rgba, bytes, dataType: BufferDataType.uint8);
    return buf;
  }

  /// CPU fallback for [presentYuv420p]: convert the planar YUV to RGBA in native
  /// C, wrap as a `ui.Image`, and publish via [fallbackImage]. No minigpu
  /// present. The scheduler serialises calls, so the converter's native output
  /// view stays valid until `decodeImageFromPixels` has consumed it.
  Future<void> _presentCpu(Uint8List yuv, int w, int h,
      DecodedPixelLayout layout, bool fullRange, YuvColorMatrix matrix) async {
    final sw = Stopwatch()..start();
    final conv = _cpuConv ??= YuvRgbaConverter();
    final rgba =
        conv.toRgba(layout, yuv, w, h, fullRange: fullRange, matrix: matrix);
    timings.convertMs = sw.elapsedMicroseconds / 1000.0;
    timings.copyMs = 0;

    sw.reset();
    final img = await _decodeRgbaImage(rgba, w, h);
    if (_disposed) {
      img.dispose(); // raced with dispose(); don't publish onto a dead notifier
      return;
    }
    final prev = fallbackImage.value;
    fallbackImage.value = img;
    _scheduleImageDispose(prev);
    timings.presentMs = sw.elapsedMicroseconds / 1000.0;
  }

  /// Dispose a replaced fallback image AFTER the next frame — a `RenderImage`
  /// may still reference it until the frame that swaps in the new image paints,
  /// and disposing a still-painted `ui.Image` faults the raster thread.
  void _scheduleImageDispose(ui.Image? image) {
    if (image == null) return;
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) => image.dispose());
    binding.scheduleFrame(); // ensure the callback runs even if idle
  }

  Future<ui.Image> _decodeRgbaImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  /// Convert + present one hardware-decoded NV12 D3D11 texture, referenced by
  /// its shared NT handle. Imports the texture into Dawn and runs the NV12→RGBA
  /// compute pass entirely on the GPU — no CPU readback of the decoded frame.
  /// The handle stays owned by the decoder (worker isolate) until the scheduler
  /// releases it via `onDone` after this present completes.
  Future<void> presentD3D11Nv12(int sharedHandle, int w, int h) {
    if (_disposed) return Future<void>.value();
    final f = _presentD3d11(sharedHandle, w, h);
    _inFlight = f;
    return f.whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
  }

  /// Present an EXTERNAL, already-RGBA D3D11 shared texture — a codec that
  /// composes RGBA directly into its own shared texture (e.g. livetensor's
  /// gsplats GPU decoder) and hands out the (legacy DXGI) [sharedHandle] +
  /// `ID3D11Texture2D*` [texPtr]. No import/convert/copy: the handle is handed
  /// straight to the preview controller. Centralises the nativeSharedTexture
  /// PreviewSource so consumers don't hand-roll it.
  Future<void> presentD3D11Rgba(int sharedHandle, int texPtr, int w, int h) {
    if (_disposed) return Future<void>.value();
    final f = _controller
        .present(_ExternalSharedTextureSource(sharedHandle, texPtr, w, h));
    _inFlight = f;
    return f.whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
  }

  Future<void> _presentD3d11(int sharedHandle, int w, int h) async {
    if (!_ensureTextures(w, h)) {
      // A GPU texture handle can't go through the CPU (bytes) fallback without a
      // readback path, which doesn't exist here. This combination shouldn't
      // occur: D3D11 handles are Windows-only, where zero-copy present works.
      throw StateError(
        'CPU present fallback cannot accept a D3D11 texture handle — no '
        'zero-copy present available on this platform/adapter',
      );
    }
    final slot = _slot;
    _slot ^= 1;
    final tex = _textures[slot]!;

    final sw = Stopwatch()..start();
    final vtex = _gpu.importVideoFrame(
      ExternalVideoBuffer(
        contentType: ExternalContentType.d3d11SharedHandle,
        pixelFormat: ExternalPixelFormat.nv12,
        width: w,
        height: h,
        planes: [
          ExternalPlane(dataPtr: sharedHandle, width: w, height: h,
              strideBytes: 0),
        ],
      ),
    );
    if (vtex == null) {
      throw StateError(
        'importVideoFrame(d3d11 NV12) returned null — Dawn shared-handle / '
        'multi-planar import unavailable on this adapter',
      );
    }
    // Convert via the cached converter (shader + output buffers reused across
    // frames) — the dispatch awaits GPU completion, so the imported texture is
    // safe to release right after. rgbaBuf is a borrowed ping-pong buffer owned
    // by the converter (do NOT destroy it here).
    final conv = _nv12Converter ??= GpuNv12TextureToRgbaConverter(_gpu);
    final Buffer rgbaBuf;
    try {
      rgbaBuf = await conv.convert(vtex, w, h, slot: slot);
    } finally {
      vtex.destroy();
    }
    timings.convertMs = sw.elapsedMicroseconds / 1000.0;

    sw.reset();
    await tex.copyFromBufferAsync(rgbaBuf);
    timings.copyMs = sw.elapsedMicroseconds / 1000.0;

    sw.reset();
    await _controller.present(tex.asPreviewSource());
    timings.presentMs = sw.elapsedMicroseconds / 1000.0;
  }

  /// Release GPU resources. The [MinigpuPreviewController] is owned by the
  /// caller (it may outlive the presenter to keep the last frame on screen).
  ///
  /// Awaits any in-flight present FIRST so we never `destroy()` a texture
  /// while an outstanding async GPU copy/present still references it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _inFlight;
    } catch (_) {
      // A failed present must not block texture teardown.
    }
    _inFlight = null;
    _converter.dispose();
    _nv12Converter?.dispose();
    _nv12Converter = null;
    _cpuConv?.dispose();
    _cpuConv = null;
    _rgbaUpload?.destroy();
    _rgbaUpload = null;
    // Release the last image, but DO NOT dispose the notifier itself: it is
    // exposed publicly (MiniavPlayer.videoFallbackImage) and a widget may still
    // be — or become — subscribed (the controller/view can outlive the
    // presenter). Disposing it would make a later addListener throw. The
    // notifier is cheap and is collected with the player once no one holds it.
    fallbackImage.value?.dispose();
    fallbackImage.value = null;
    for (var i = 0; i < 2; i++) {
      _textures[i]?.destroy();
      _textures[i] = null;
    }
  }
}
