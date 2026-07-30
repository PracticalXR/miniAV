import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/src/yuv_rgba_reference.dart';

/// Forward reference: the encode side's RGBA→YUV420P (BT.601 limited,
/// ×8192 fixed point) — copied verbatim from the recorder's
/// `GpuYuv420Converter` CPU twin (`pixel_convert.dart`) so this test pins
/// the player's decode math against what miniAV encoders actually produce.
Uint8List rgbaToYuv420pReference(Uint8List rgba, int w, int h) {
  final ySize = w * h;
  final cw = w >> 1;
  final ch = h >> 1;
  final out = Uint8List(ySize + 2 * cw * ch);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      out[y * w + x] =
          ((2105 * r + 4128 * g + 803 * b + 131072 + 4096) >> 13).clamp(0, 255);
    }
  }
  for (var cy = 0; cy < ch; cy++) {
    for (var cx = 0; cx < cw; cx++) {
      var rSum = 0, gSum = 0, bSum = 0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final i = ((cy * 2 + dy) * w + cx * 2 + dx) * 4;
          rSum += rgba[i];
          gSum += rgba[i + 1];
          bSum += rgba[i + 2];
        }
      }
      final r = rSum >> 2, g = gSum >> 2, b = bSum >> 2;
      out[ySize + cy * cw + cx] =
          ((-1212 * r - 2384 * g + 3596 * b + 1048576 + 4096) >> 13)
              .clamp(0, 255);
      out[ySize + cw * ch + cy * cw + cx] =
          ((3596 * r - 3015 * g - 581 * b + 1048576 + 4096) >> 13)
              .clamp(0, 255);
    }
  }
  return out;
}

void main() {
  test('known colors decode correctly', () {
    // 2x2 uniform blocks: limited-range black / white / mid-grey.
    Uint8List yuvUniform(int y, int u, int v) {
      final buf = Uint8List(4 + 1 + 1);
      buf.fillRange(0, 4, y);
      buf[4] = u;
      buf[5] = v;
      return buf;
    }

    final black = yuv420pToRgba8(yuvUniform(16, 128, 128), 2, 2);
    expect(black.sublist(0, 4), [0, 0, 0, 255]);

    final white = yuv420pToRgba8(yuvUniform(235, 128, 128), 2, 2);
    expect(white.sublist(0, 4), [255, 255, 255, 255]);

    final grey = yuv420pToRgba8(yuvUniform(126, 128, 128), 2, 2);
    // (126-16)*298 + 128 >> 8 = 128.
    expect(grey.sublist(0, 4), [128, 128, 128, 255]);
  });

  test('alpha is opaque and out-of-gamut clamps', () {
    // Y=235 with extreme chroma must clamp into [0,255] without wrapping.
    final buf = Uint8List(6)
      ..fillRange(0, 4, 235)
      ..[4] = 255
      ..[5] = 255;
    final rgba = yuv420pToRgba8(buf, 2, 2);
    for (var p = 0; p < 4; p++) {
      expect(rgba[p * 4 + 3], 255);
      for (var c = 0; c < 3; c++) {
        expect(rgba[p * 4 + c], inInclusiveRange(0, 255));
      }
    }
  });

  test('encode→decode round trip stays within codec tolerance', () {
    // Uniform 2x2 blocks so 4:2:0 chroma subsampling is lossless and only
    // the matrix round trip is measured.
    const w = 64, h = 64;
    final rng = Random(42);
    final rgba = Uint8List(w * h * 4);
    for (var by = 0; by < h; by += 2) {
      for (var bx = 0; bx < w; bx += 2) {
        final r = rng.nextInt(256), g = rng.nextInt(256), b = rng.nextInt(256);
        for (var dy = 0; dy < 2; dy++) {
          for (var dx = 0; dx < 2; dx++) {
            final i = ((by + dy) * w + bx + dx) * 4;
            rgba[i] = r;
            rgba[i + 1] = g;
            rgba[i + 2] = b;
            rgba[i + 3] = 255;
          }
        }
      }
    }
    final yuv = rgbaToYuv420pReference(rgba, w, h);
    final back = yuv420pToRgba8(yuv, w, h);
    var maxErr = 0;
    for (var i = 0; i < rgba.length; i++) {
      if (i % 4 == 3) continue; // alpha
      final e = (rgba[i] - back[i]).abs();
      if (e > maxErr) maxErr = e;
    }
    // Limited-range 8-bit BT.601 forward+inverse: quantization loses up to
    // ~2 LSB through the 219/224-step ranges.
    expect(maxErr, lessThanOrEqualTo(3), reason: 'max round-trip error');
  });

  test('rejects odd dimensions and short buffers', () {
    expect(() => yuv420pToRgba8(Uint8List(6), 3, 2), throwsArgumentError);
    expect(() => yuv420pToRgba8(Uint8List(5), 2, 2), throwsArgumentError);
  });
}
