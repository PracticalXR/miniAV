/// Pure-Dart YUV <-> RGBA8888 converters — the no-FFI twin of the native C
/// converter (miniav_tools_codecs `frame_convert.c`), byte-identical to it in
/// both directions (asserted by the codecs package's
/// `test/rgba_yuv_convert_test.dart`).
///
/// Lives in the platform interface (pure Dart, zero deps, no build hooks) so
/// ANY consumer — web builds, pure-Dart codecs (livetensor's gsplats reference
/// path), backend packages — can share the one canonical colour contract
/// without dragging in FFI or minigpu. The accelerated twins (C via
/// [CpuFrameConverter], GPU WGSL) live in `miniav_tools_codecs`; on native hot
/// paths prefer those (the C loop is ~10-20x faster per 1080p frame).
///
/// The `...Async` variants yield to the event loop between row chunks so a
/// long conversion on the UI isolate (web has no cheap isolates) doesn't jank
/// a frame.
library;

import 'dart:typed_data';

import '../platform_codec.dart' show YuvColorMatrix;

import 'color_coeffs.dart';

/// Tightly-packed I420 planes (chroma dims `(w+1)~/2 x (h+1)~/2`).
typedef I420Planes = ({Uint8List y, Uint8List u, Uint8List v});

int _clamp255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Convert I420 planes -> packed RGBA8888 (alpha 255), or BGRA8888 with
/// [bgra]. Plane strides are in bytes (<=0 = tightly packed). Writes into
/// [out] when provided (must hold `width*height*4`); otherwise allocates.
/// Byte-identical to the C `miniav_i420_to_rgba` for every matrix/range.
Uint8List dartI420ToRgba(
  Uint8List y,
  Uint8List u,
  Uint8List v,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
  int strideY = 0,
  int strideU = 0,
  int strideV = 0,
  Uint8List? out,
}) {
  final rgba = _prepOut(out, width, height);
  _planarRows(y, u, v, width, height, 0, height, 1, 1,
      YuvRgbCoeffs.of(matrix, fullRange: fullRange), rgba, bgra,
      strideY: strideY, strideU: strideU, strideV: strideV);
  return rgba;
}

/// Convert I422 planes (chroma half-width, FULL height — e.g. deinterleaved
/// YUY2) -> packed RGBA8888/BGRA8888. Same contract as [dartI420ToRgba];
/// byte-identical to the C `miniav_i422_to_rgba`.
Uint8List dartI422ToRgba(
  Uint8List y,
  Uint8List u,
  Uint8List v,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
  int strideY = 0,
  int strideU = 0,
  int strideV = 0,
  Uint8List? out,
}) {
  final rgba = _prepOut(out, width, height);
  _planarRows(y, u, v, width, height, 0, height, 1, 0,
      YuvRgbCoeffs.of(matrix, fullRange: fullRange), rgba, bgra,
      strideY: strideY, strideU: strideU, strideV: strideV);
  return rgba;
}

/// [dartI420ToRgba] that yields to the event loop every [chunkRows] rows.
Future<Uint8List> dartI420ToRgbaAsync(
  Uint8List y,
  Uint8List u,
  Uint8List v,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
  Uint8List? out,
  int chunkRows = 32,
}) async {
  final rgba = _prepOut(out, width, height);
  final k = YuvRgbCoeffs.of(matrix, fullRange: fullRange);
  for (var y0 = 0; y0 < height; y0 += chunkRows) {
    if (y0 > 0) await Future<void>.delayed(Duration.zero);
    final y1 = (y0 + chunkRows < height) ? y0 + chunkRows : height;
    _planarRows(y, u, v, width, height, y0, y1, 1, 1, k, rgba, bgra);
  }
  return rgba;
}

/// Convert packed RGBA8888 (or BGRA8888 with [bgra]) -> tightly-packed I420
/// planes. [srcStrideBytes] is the source row stride (<=0 = tight, 4*width) —
/// capture APIs (DXGI, V4L2) often pad rows.
///
/// Chroma is the rounded average of each 2x2 RGB cell (edge samples replicate
/// for odd dims), converted once per chroma sample — matching the C
/// `miniav_rgba_to_i420` byte-for-byte. Writes into ([outY],[outU],[outV])
/// when all three are provided; otherwise allocates.
I420Planes dartRgbaToI420(
  Uint8List rgba,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
  int srcStrideBytes = 0,
  Uint8List? outY,
  Uint8List? outU,
  Uint8List? outV,
}) {
  final planes = _prepPlanes(outY, outU, outV, width, height);
  final k = RgbaYuvCoeffs.of(matrix, fullRange: fullRange);
  final stride = srcStrideBytes > 0 ? srcStrideBytes : width * 4;
  _lumaRows(rgba, stride, width, 0, height, k, planes.y, bgra);
  final ch = (height + 1) >> 1;
  _chromaRows(rgba, stride, width, height, 0, ch, k, planes.u, planes.v, bgra);
  return planes;
}

/// [dartRgbaToI420] that yields to the event loop every [chunkRows] luma rows.
Future<I420Planes> dartRgbaToI420Async(
  Uint8List rgba,
  int width,
  int height, {
  bool fullRange = false,
  YuvColorMatrix matrix = YuvColorMatrix.bt601,
  bool bgra = false,
  int srcStrideBytes = 0,
  Uint8List? outY,
  Uint8List? outU,
  Uint8List? outV,
  int chunkRows = 32,
}) async {
  final planes = _prepPlanes(outY, outU, outV, width, height);
  final k = RgbaYuvCoeffs.of(matrix, fullRange: fullRange);
  final stride = srcStrideBytes > 0 ? srcStrideBytes : width * 4;
  for (var y0 = 0; y0 < height; y0 += chunkRows) {
    if (y0 > 0) await Future<void>.delayed(Duration.zero);
    final y1 = (y0 + chunkRows < height) ? y0 + chunkRows : height;
    _lumaRows(rgba, stride, width, y0, y1, k, planes.y, bgra);
  }
  final ch = (height + 1) >> 1;
  final chromaChunk = (chunkRows + 1) >> 1;
  for (var c0 = 0; c0 < ch; c0 += chromaChunk) {
    await Future<void>.delayed(Duration.zero);
    final c1 = (c0 + chromaChunk < ch) ? c0 + chromaChunk : ch;
    _chromaRows(
        rgba, stride, width, height, c0, c1, k, planes.u, planes.v, bgra);
  }
  return planes;
}

Uint8List _prepOut(Uint8List? out, int width, int height) {
  final need = width * height * 4;
  if (out != null && out.length < need) {
    throw ArgumentError('out too small: ${out.length} < $need');
  }
  return out ?? Uint8List(need);
}

I420Planes _prepPlanes(
    Uint8List? outY, Uint8List? outU, Uint8List? outV, int width, int height) {
  final cw = (width + 1) >> 1;
  final ch = (height + 1) >> 1;
  final ySize = width * height;
  final cSize = cw * ch;
  if (outY != null && outU != null && outV != null) {
    if (outY.length < ySize || outU.length < cSize || outV.length < cSize) {
      throw ArgumentError('plane buffers too small for ${width}x$height');
    }
    return (y: outY, u: outU, v: outV);
  }
  return (y: Uint8List(ySize), u: Uint8List(cSize), v: Uint8List(cSize));
}

// Shared planar YUV->RGBA row loop; cShiftX/cShiftY encode the chroma
// subsampling (1,1 = 4:2:0; 1,0 = 4:2:2). Mirrors frame_convert.c `conv()`.
void _planarRows(
  Uint8List yP,
  Uint8List uP,
  Uint8List vP,
  int w,
  int h,
  int rowStart,
  int rowEnd,
  int cShiftX,
  int cShiftY,
  YuvRgbCoeffs k,
  Uint8List rgba,
  bool bgra, {
  int strideY = 0,
  int strideU = 0,
  int strideV = 0,
}) {
  final cw = cShiftX == 1 ? (w + 1) >> 1 : w;
  final sy = strideY > 0 ? strideY : w;
  final su = strideU > 0 ? strideU : cw;
  final sv = strideV > 0 ? strideV : cw;
  final ri = bgra ? 2 : 0;
  final bi = bgra ? 0 : 2;
  var di = rowStart * w * 4;
  for (var y = rowStart; y < rowEnd; y++) {
    final yRow = y * sy;
    final uRow = (y >> cShiftY) * su;
    final vRow = (y >> cShiftY) * sv;
    for (var x = 0; x < w; x++) {
      final c = yP[yRow + x] - k.yOff;
      final cx = x >> cShiftX;
      final d = uP[uRow + cx] - 128;
      final e = vP[vRow + cx] - 128;
      final yy = c * k.yMul + 128;
      rgba[di + ri] = _clamp255((yy + k.rV * e) >> 8);
      rgba[di + 1] = _clamp255((yy - k.gU * d - k.gV * e) >> 8);
      rgba[di + bi] = _clamp255((yy + k.bU * d) >> 8);
      rgba[di + 3] = 255;
      di += 4;
    }
  }
}

void _lumaRows(Uint8List rgba, int stride, int w, int rowStart, int rowEnd,
    RgbaYuvCoeffs k, Uint8List yOut, bool bgra) {
  final ri = bgra ? 2 : 0;
  final bi = bgra ? 0 : 2;
  for (var y = rowStart; y < rowEnd; y++) {
    var si = y * stride;
    var di = y * w;
    for (var x = 0; x < w; x++) {
      final r = rgba[si + ri], g = rgba[si + 1], b = rgba[si + bi];
      yOut[di++] =
          _clamp255(((k.yR * r + k.yG * g + k.yB * b + 128) >> 8) + k.yOff);
      si += 4;
    }
  }
}

void _chromaRows(Uint8List rgba, int stride, int w, int h, int cRowStart,
    int cRowEnd, RgbaYuvCoeffs k, Uint8List uOut, Uint8List vOut, bool bgra) {
  final ri = bgra ? 2 : 0;
  final bi = bgra ? 0 : 2;
  final cw = (w + 1) >> 1;
  for (var cy = cRowStart; cy < cRowEnd; cy++) {
    final y0 = cy * 2;
    final y1 = (y0 + 1 < h) ? y0 + 1 : y0; // replicate last row when h is odd
    var di = cy * cw;
    for (var cx = 0; cx < cw; cx++) {
      final x0 = cx * 2;
      final x1 = (x0 + 1 < w) ? x0 + 1 : x0; // replicate last column
      final i00 = y0 * stride + x0 * 4;
      final i01 = y0 * stride + x1 * 4;
      final i10 = y1 * stride + x0 * 4;
      final i11 = y1 * stride + x1 * 4;
      // Rounded 2x2 box average of the RGB cell, then one conversion.
      final r = (rgba[i00 + ri] + rgba[i01 + ri] + rgba[i10 + ri] +
              rgba[i11 + ri] + 2) >>
          2;
      final g = (rgba[i00 + 1] + rgba[i01 + 1] + rgba[i10 + 1] + rgba[i11 + 1] +
              2) >>
          2;
      final b = (rgba[i00 + bi] + rgba[i01 + bi] + rgba[i10 + bi] +
              rgba[i11 + bi] + 2) >>
          2;
      uOut[di] = _clamp255(((k.uR * r + k.uG * g + k.uB * b + 128) >> 8) + 128);
      vOut[di] = _clamp255(((k.vR * r + k.vG * g + k.vB * b + 128) >> 8) + 128);
      di++;
    }
  }
}
