/// Byte-parity test for [GpuYuv420Converter] (now the canonical
/// `GpuRgbaToYuv420Converter` from miniav_tools_codecs): the compute shader
/// must produce output byte-identical to the shared pure-Dart reference
/// (`dartRgbaToI420`, itself byte-exact against the C converter) — one
/// canonical BT.601-limited encode-side conversion across CPU, C and GPU.
///
/// Runs the real minigpu compute path headless on the VM. Skips gracefully if a
/// GPU/Dawn device is unavailable in the environment.
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show dartRgbaToI420;
import 'package:miniav_recorder/src/gpu_yuv420_converter.dart';
import 'package:test/test.dart';

Uint8List _syntheticRgba(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  final rng = math.Random(0xA51);
  int b255(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i + 0] = b255(x * 255 / (w - 1) + (rng.nextDouble() - 0.5) * 8);
      rgba[i + 1] = b255(y * 255 / (h - 1) + (rng.nextDouble() - 0.5) * 8);
      rgba[i + 2] = b255((x + y) * 255 / (w + h - 2) + (rng.nextDouble() - 0.5) * 8);
      rgba[i + 3] = 255;
    }
  }
  // A few pure-color 2x2 cells so chroma averaging is exercised on hard edges.
  void cell(int cx, int cy, int r, int g, int b) {
    for (var dy = 0; dy < 2; dy++) {
      for (var dx = 0; dx < 2; dx++) {
        final i = ((cy + dy) * w + cx + dx) * 4;
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 255;
      }
    }
  }

  cell(0, 0, 255, 0, 0);
  cell(10, 10, 0, 255, 0);
  cell(20, 20, 0, 0, 255);
  cell(40, 28, 255, 255, 255);
  cell(50, 4, 16, 16, 16);
  return rgba;
}

void main() {
  group('GpuYuv420Converter (minigpu BT.601)', () {
    test('GPU YUV420P is byte-identical to the CPU reference', () async {
      await Recorder.ensureSharedGpu();
      final gpu = Recorder.sharedGpu;
      if (gpu == null) {
        markTestSkipped('No GPU/Dawn device available in this environment');
        return;
      }

      const w = 64;
      const h = 32;
      final rgba = _syntheticRgba(w, h);
      final expected = dartRgbaToI420(rgba, w, h);

      final conv = GpuYuv420Converter(gpu);
      final gotY = Uint8List(GpuYuv420Converter.ySize(w, h));
      final gotU = Uint8List(GpuYuv420Converter.uvSize(w, h));
      final gotV = Uint8List(GpuYuv420Converter.uvSize(w, h));
      try {
        await conv.convertFromBytes(
          rgba,
          w,
          h,
          outY: gotY,
          outU: gotU,
          outV: gotV,
        );

        expect(gotY, equals(expected.y), reason: 'Y plane mismatch');
        expect(gotU, equals(expected.u), reason: 'U plane mismatch');
        expect(gotV, equals(expected.v), reason: 'V plane mismatch');
      } finally {
        conv.dispose();
      }
    });

    test('odd dimensions edge-replicate to match the CPU reference',
        () async {
      await Recorder.ensureSharedGpu();
      final gpu = Recorder.sharedGpu;
      if (gpu == null) {
        markTestSkipped('No GPU/Dawn device available in this environment');
        return;
      }
      const w = 63, h = 31;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i++) {
        rgba[i] = (i * 37) & 0xff;
      }
      final expected = dartRgbaToI420(rgba, w, h);
      final conv = GpuYuv420Converter(gpu);
      addTearDown(conv.dispose);
      final gotY = Uint8List(GpuYuv420Converter.ySize(w, h));
      final gotU = Uint8List(GpuYuv420Converter.uvSize(w, h));
      final gotV = Uint8List(GpuYuv420Converter.uvSize(w, h));
      await conv.convertFromBytes(rgba, w, h,
          outY: gotY, outU: gotU, outV: gotV);
      expect(gotY, equals(expected.y));
      expect(gotU, equals(expected.u));
      expect(gotV, equals(expected.v));
    });
  });
}
