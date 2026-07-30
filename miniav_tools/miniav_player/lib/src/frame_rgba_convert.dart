/// Native (dart:ffi) YUV->RGBA for the CPU present fallback. Isolated behind a
/// conditional import so `video_presenter.dart` — which is compiled for web too
/// — never pulls `dart:ffi` into a web build (see the `_stub` twin). The actual
/// per-pixel convert runs in C ([CpuFrameConverter]); this is a thin adapter.
library;

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart'
    show DecodedPixelLayout, YuvColorMatrix;
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show CpuFrameConverter, YuvPlanar;

/// Wraps the C converter. Reused across frames (keeps native scratch buffers
/// alive), so the video hot path incurs no per-frame native allocation.
class YuvRgbaConverter {
  final CpuFrameConverter _c = CpuFrameConverter();

  /// Convert tightly-packed I420 -> RGBA8888. The returned [Uint8List] is a
  /// VIEW over native memory, valid until the next convert / [dispose] — the
  /// caller must consume it (hand it to `decodeImageFromPixels`, which copies)
  /// before converting the next frame. The presenter's single-frame-in-flight
  /// scheduling guarantees this.
  Uint8List i420ToRgba(Uint8List yuv, int width, int height) =>
      _c.i420ToRgba(yuv, width, height);

  /// Convert any supported [layout] -> RGBA8888 (view over native memory; see
  /// [i420ToRgba]). [fullRange] + [matrix] select the coefficient set.
  Uint8List toRgba(DecodedPixelLayout layout, Uint8List yuv, int width,
      int height,
      {bool fullRange = false, YuvColorMatrix matrix = YuvColorMatrix.bt601}) {
    switch (layout) {
      case DecodedPixelLayout.nv12:
        return _c.nv12ToRgba(yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.p010:
        return _c.p010ToRgba(yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i420:
        return _c.planarToRgba(YuvPlanar.i420, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i422:
        return _c.planarToRgba(YuvPlanar.i422, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i444:
        return _c.planarToRgba(YuvPlanar.i444, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i420p10:
        return _c.planarToRgba(YuvPlanar.i420p10, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i422p10:
        return _c.planarToRgba(YuvPlanar.i422p10, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.i444p10:
        return _c.planarToRgba(YuvPlanar.i444p10, yuv, width, height,
            fullRange: fullRange, matrix: matrix);
      case DecodedPixelLayout.rgba:
        return yuv; // already packed RGBA8888 — nothing to convert
    }
  }

  void dispose() => _c.dispose();
}
