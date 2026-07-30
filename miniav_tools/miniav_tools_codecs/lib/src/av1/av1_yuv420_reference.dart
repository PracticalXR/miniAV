/// CPU reference implementation for the BT.709 limited-range RGB→YUV420
/// converter, mirroring [av1_yuv420_stage.dart]. Used by tests to validate
/// the GPU output bit-for-bit (modulo float rounding).
library;

import 'dart:typed_data';

import 'av1_yuv420_stage.dart' show Yuv420Layout;

/// Convert a packed RGBA float buffer (length = width*height*4, values in
/// [0,255]) to a planar YUV420 Float32 buffer matching the layout produced
/// by the GPU shader.
Float32List rgbaToYuv420Bt709LimitedCpu({
  required Float32List rgba,
  required int width,
  required int height,
}) {
  if (width.isOdd || height.isOdd) {
    throw ArgumentError('YUV420 requires even width/height');
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError('rgba length ${rgba.length} != ${width * height * 4}');
  }
  final layout = Yuv420Layout(width, height);
  final out = Float32List(layout.totalFloats);

  double clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v);
  double y(double r, double g, double b) =>
      clamp255(16.0 + 0.18259 * r + 0.61423 * g + 0.06201 * b);
  double cb(double r, double g, double b) =>
      clamp255(128.0 + (-0.10068) * r + (-0.33857) * g + 0.43922 * b);
  double cr(double r, double g, double b) =>
      clamp255(128.0 + 0.43922 * r + (-0.39895) * g + (-0.04027) * b);

  for (var cy = 0; cy < layout.uvHeight; cy++) {
    for (var cx = 0; cx < layout.uvWidth; cx++) {
      final uvIdx = cy * layout.uvWidth + cx;
      final x0 = cx * 2;
      final y0 = cy * 2;
      var rSum = 0.0, gSum = 0.0, bSum = 0.0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final x = x0 + dx;
          final yy = y0 + dy;
          final i = (yy * width + x) * 4;
          final r = rgba[i + 0];
          final g = rgba[i + 1];
          final b = rgba[i + 2];
          rSum += r;
          gSum += g;
          bSum += b;
          out[yy * width + x] = y(r, g, b);
        }
      }
      final rAvg = rSum * 0.25;
      final gAvg = gSum * 0.25;
      final bAvg = bSum * 0.25;
      out[layout.ySize + uvIdx] = cb(rAvg, gAvg, bAvg);
      out[layout.ySize + layout.uvSize + uvIdx] = cr(rAvg, gAvg, bAvg);
    }
  }
  return out;
}
