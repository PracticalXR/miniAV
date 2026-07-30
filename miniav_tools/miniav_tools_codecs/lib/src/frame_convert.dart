/// CPU YUV -> RGBA8888 conversion for the player's cross-platform present
/// fallback. The per-pixel colour math runs in native C ([codecs_native]) —
/// ~1-2 ms per 1080p frame vs the ~20-50 ms a Dart loop would cost, which is
/// the difference between a smooth fallback and a janked UI isolate.
///
/// Two ways to use it:
///   - [cpuI420ToRgba] / [cpuNv12ToRgba]: one-shot, allocate-and-free per call
///     (fine for tests / occasional frames).
///   - [CpuFrameConverter]: a reusable converter that keeps its native scratch
///     buffers alive across frames — the hot path (a video keeps calling it at
///     30-60 fps and should NOT malloc/free every frame).
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show YuvColorMatrix;

import 'codecs_native.dart' as native;

export 'codecs_native.dart' show YuvPlanar;

/// [YuvColorMatrix] -> the C converter's matrix id (frame_convert.c `pick()`).
/// Explicit map (not `.index`) so an enum reorder can't silently change colour.
int _matrixId(YuvColorMatrix m) => switch (m) {
      YuvColorMatrix.bt601 => 0,
      YuvColorMatrix.bt709 => 1,
      YuvColorMatrix.bt2020 => 2,
    };

/// Convert a tightly-packed three-plane YUV buffer ([layout]) to a fresh
/// RGBA8888 [Uint8List] of length `width*height*4`. [fullRange] selects
/// JPEG-range coefficients (yuvj*); [matrix] the YCbCr matrix.
Uint8List cpuPlanarToRgba(
  native.YuvPlanar layout,
  Uint8List yuv,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
}) {
  final c = CpuFrameConverter();
  try {
    return Uint8List.fromList(c.planarToRgba(layout, yuv, width, height,
        fullRange: fullRange, matrix: matrix));
  } finally {
    c.dispose();
  }
}

/// Convert a tightly-packed P010 buffer (10-bit NV12: Y plane then interleaved
/// UV plane, 16-bit LE samples with the value in the HIGH bits) to a fresh
/// RGBA8888 [Uint8List] of length `width*height*4`.
Uint8List cpuP010ToRgba(
  Uint8List p010,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
}) {
  final c = CpuFrameConverter();
  try {
    return Uint8List.fromList(c.p010ToRgba(p010, width, height,
        fullRange: fullRange, matrix: matrix));
  } finally {
    c.dispose();
  }
}

/// Convert a tightly-packed I420 (YUV420P) buffer to a fresh RGBA8888
/// [Uint8List] of length `width*height*4`.
///
/// [yuv] layout: Y (`width*height`), then U (`cw*ch`), then V (`cw*ch`), where
/// `cw = (width+1)~/2`, `ch = (height+1)~/2` — the tightly-packed planar layout
/// the software decoders and the MF NV12->I420 map produce.
Uint8List cpuI420ToRgba(Uint8List yuv, int width, int height) {
  final c = CpuFrameConverter();
  try {
    return Uint8List.fromList(c.i420ToRgba(yuv, width, height));
  } finally {
    c.dispose();
  }
}

/// Convert packed RGBA8888 to fresh tightly-packed I420 planes (the
/// encode-side inverse — see `RgbaYuvCoeffs` for the coefficient contract).
({Uint8List y, Uint8List u, Uint8List v}) cpuRgbaToI420(
  Uint8List rgba,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
}) {
  final c = CpuFrameConverter();
  try {
    final p = c.rgbaToI420(rgba, width, height,
        fullRange: fullRange, matrix: matrix, bgra: bgra);
    return (
      y: Uint8List.fromList(p.y),
      u: Uint8List.fromList(p.u),
      v: Uint8List.fromList(p.v),
    );
  } finally {
    c.dispose();
  }
}

/// Convert a tightly-packed NV12 buffer (Y plane then interleaved UV plane) to
/// a fresh RGBA8888 [Uint8List] of length `width*height*4`.
Uint8List cpuNv12ToRgba(Uint8List nv12, int width, int height) {
  final c = CpuFrameConverter();
  try {
    return Uint8List.fromList(c.nv12ToRgba(nv12, width, height));
  } finally {
    c.dispose();
  }
}

/// A reusable CPU YUV->RGBA converter. Holds native input + output scratch
/// buffers and grows them as needed, so repeated same-size frames incur no
/// per-frame allocation. NOT thread/isolate safe — one per consumer.
///
/// The [Uint8List] returned by [i420ToRgba] / [nv12ToRgba] is a VIEW over the
/// converter's native output buffer: valid only until the next convert call or
/// [dispose]. Copy it (or hand it straight to `decodeImageFromPixels`, which
/// copies) before the next frame. This is what lets the player avoid an extra
/// heap copy on the hot path.
class CpuFrameConverter {
  Pointer<Uint8> _in = nullptr;
  int _inCap = 0;
  Pointer<Uint8> _out = nullptr;
  int _outCap = 0;
  bool _disposed = false;

  void _ensureIn(int bytes) {
    if (_inCap >= bytes) return;
    if (_in != nullptr) calloc.free(_in);
    _in = calloc<Uint8>(bytes);
    _inCap = bytes;
  }

  void _ensureOut(int bytes) {
    if (_outCap >= bytes) return;
    if (_out != nullptr) calloc.free(_out);
    _out = calloc<Uint8>(bytes);
    _outCap = bytes;
  }

  /// Convert a tightly-packed three-plane YUV buffer ([layout]) -> RGBA8888.
  /// Returns a view over the native output buffer (see class doc — copy before
  /// the next call). [fullRange] selects JPEG-range coefficients (yuvj*).
  Uint8List planarToRgba(
    native.YuvPlanar layout,
    Uint8List yuv,
    int width,
    int height, {
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
  }) {
    _checkAlive();
    final (ySizeB, uSizeB, vSizeB) = _planeBytes(layout, width, height);
    final need = ySizeB + uSizeB + vSizeB;
    if (yuv.length < need) {
      throw ArgumentError(
        '$layout buffer too small: ${yuv.length} < $need for ${width}x$height',
      );
    }
    _ensureIn(need);
    _in.asTypedList(need).setRange(0, need, yuv);
    final outBytes = width * height * 4;
    _ensureOut(outBytes);
    native.planarToRgba(
      layout,
      _in,
      _in + ySizeB,
      _in + (ySizeB + uSizeB),
      width,
      height,
      _out,
      fullRange: fullRange,
      matrix: _matrixId(matrix),
    );
    return _out.asTypedList(outBytes);
  }

  /// Byte sizes of the (Y, U, V) planes for a tightly-packed [layout].
  static (int, int, int) _planeBytes(
      native.YuvPlanar layout, int w, int h) {
    final cw = (w + 1) >> 1;
    final ch = (h + 1) >> 1;
    return switch (layout) {
      native.YuvPlanar.i420 => (w * h, cw * ch, cw * ch),
      native.YuvPlanar.i422 => (w * h, cw * h, cw * h),
      native.YuvPlanar.i444 => (w * h, w * h, w * h),
      native.YuvPlanar.i420p10 => (2 * w * h, 2 * cw * ch, 2 * cw * ch),
      native.YuvPlanar.i422p10 => (2 * w * h, 2 * cw * h, 2 * cw * h),
      native.YuvPlanar.i444p10 => (2 * w * h, 2 * w * h, 2 * w * h),
    };
  }

  /// Convert tightly-packed I420 -> RGBA8888 (convenience for [planarToRgba]).
  Uint8List i420ToRgba(Uint8List yuv, int width, int height,
          {bool fullRange = false,
          YuvColorMatrix matrix = YuvColorMatrix.bt601}) =>
      planarToRgba(native.YuvPlanar.i420, yuv, width, height,
          fullRange: fullRange, matrix: matrix);

  /// Convert tightly-packed NV12 -> RGBA8888. Returns a view over the native
  /// output buffer (see class doc — copy before the next call).
  Uint8List nv12ToRgba(Uint8List nv12, int width, int height,
      {bool fullRange = false, YuvColorMatrix matrix = YuvColorMatrix.bt601}) {
    _checkAlive();
    final ch = (height + 1) >> 1;
    final ySize = width * height;
    final uvSize = width * ch; // interleaved: cw pairs * 2 bytes = width bytes/row
    final need = ySize + uvSize;
    if (nv12.length < need) {
      throw ArgumentError(
        'NV12 buffer too small: ${nv12.length} < $need for ${width}x$height',
      );
    }
    _ensureIn(need);
    _in.asTypedList(need).setRange(0, need, nv12);
    final outBytes = width * height * 4;
    _ensureOut(outBytes);
    native.nv12ToRgba(_in, _in + ySize, width, height, _out,
        fullRange: fullRange, matrix: _matrixId(matrix));
    return _out.asTypedList(outBytes);
  }

  /// Convert tightly-packed P010 (10-bit NV12: Y then interleaved UV, 16-bit LE
  /// samples with the value in the HIGH bits) -> RGBA8888. Returns a view over
  /// the native output buffer (see class doc — copy before the next call).
  Uint8List p010ToRgba(Uint8List p010, int width, int height,
      {bool fullRange = false, YuvColorMatrix matrix = YuvColorMatrix.bt601}) {
    _checkAlive();
    final ch = (height + 1) >> 1;
    final ySize = 2 * width * height;
    final uvSize = 2 * width * ch; // 16-bit interleaved pairs: 2*w bytes/row
    final need = ySize + uvSize;
    if (p010.length < need) {
      throw ArgumentError(
        'P010 buffer too small: ${p010.length} < $need for ${width}x$height',
      );
    }
    _ensureIn(need);
    _in.asTypedList(need).setRange(0, need, p010);
    final outBytes = width * height * 4;
    _ensureOut(outBytes);
    native.p010ToRgba(_in, _in + ySize, width, height, _out,
        fullRange: fullRange, matrix: _matrixId(matrix));
    return _out.asTypedList(outBytes);
  }

  /// Convert packed RGBA8888 -> tightly-packed I420 planes (the encode-side
  /// inverse; chroma = rounded 2x2 box average, see `RgbaYuvCoeffs`). The
  /// returned plane views live in the converter's native output buffer —
  /// valid only until the next convert call or [dispose], same contract as
  /// the forward converters.
  ({Uint8List y, Uint8List u, Uint8List v}) rgbaToI420(
      Uint8List rgba, int width, int height,
      {bool fullRange = false,
      YuvColorMatrix matrix = YuvColorMatrix.bt601,
      bool bgra = false}) {
    _checkAlive();
    final need = width * height * 4;
    if (rgba.length < need) {
      throw ArgumentError(
        'RGBA buffer too small: ${rgba.length} < $need for ${width}x$height',
      );
    }
    final cw = (width + 1) >> 1;
    final ch = (height + 1) >> 1;
    final ySize = width * height;
    final cSize = cw * ch;
    _ensureIn(need);
    _in.asTypedList(need).setRange(0, need, rgba);
    _ensureOut(ySize + 2 * cSize);
    native.rgbaToI420(
      _in,
      width,
      height,
      _out,
      _out + ySize,
      _out + (ySize + cSize),
      fullRange: fullRange,
      matrix: _matrixId(matrix),
      bgra: bgra,
    );
    return (
      y: _out.asTypedList(ySize),
      u: (_out + ySize).asTypedList(cSize),
      v: (_out + (ySize + cSize)).asTypedList(cSize),
    );
  }

  void _checkAlive() {
    if (_disposed) throw StateError('CpuFrameConverter used after dispose()');
  }

  /// Free the native scratch buffers. Any previously returned view is invalid
  /// after this.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_in != nullptr) calloc.free(_in);
    if (_out != nullptr) calloc.free(_out);
    _in = nullptr;
    _out = nullptr;
  }
}
