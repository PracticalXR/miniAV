/// The GPU RGBA->YUV420 converter must be BYTE-IDENTICAL to the pure-Dart
/// reference (`dartRgbaToI420`), which is itself byte-exact against the C
/// converter (`rgba_yuv_convert_test.dart`) — so all three encode-side
/// implementations share one canonical output. Skips cleanly when Dawn can't
/// init. Run with `--concurrency=1` alongside the other GPU suites.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_codecs/gpu.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart';
import 'package:test/test.dart';

Uint8List _rand(int n, int seed) {
  final b = Uint8List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (s >> 8) & 0xff;
  }
  return b;
}

void main() {
  group('GPU RGBA->YUV420 == pure-Dart (byte-exact)', () {
    late Minigpu gpu;
    GpuRgbaToYuv420Converter? conv;
    var gpuOk = false;

    setUpAll(() async {
      try {
        Minigpu.preferDisplayAdapter();
        gpu = Minigpu();
        await gpu.init();
        conv = GpuRgbaToYuv420Converter(gpu);
        gpuOk = true;
      } catch (e) {
        gpuOk = false;
        // ignore: avoid_print
        print('GPU-RGBA-YUV-DIAG: Dawn init failed, skipping — $e');
      }
    });

    tearDownAll(() async {
      if (!gpuOk) return;
      conv?.dispose();
      await gpu.destroy();
    });

    const combos = [
      (YuvColorMatrix.bt601, false),
      (YuvColorMatrix.bt601, true),
      (YuvColorMatrix.bt709, false),
      (YuvColorMatrix.bt2020, true),
    ];

    for (final (m, full) in combos) {
      test('$m fullRange=$full 64x48', () async {
        if (!gpuOk) return markTestSkipped('no GPU');
        const w = 64, h = 48;
        final rgba = _rand(w * h * 4, 0xBEEF);
        final ref = dartRgbaToI420(rgba, w, h, matrix: m, fullRange: full);
        final outY = Uint8List(GpuRgbaToYuv420Converter.ySize(w, h));
        final outU = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
        final outV = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
        await conv!.convertFromBytes(rgba, w, h,
            outY: outY, outU: outU, outV: outV, matrix: m, fullRange: full);
        expect(outY, equals(ref.y));
        expect(outU, equals(ref.u));
        expect(outV, equals(ref.v));
      });
    }

    test('odd dims 33x17 (edge replicate) == pure-Dart', () async {
      if (!gpuOk) return markTestSkipped('no GPU');
      const w = 33, h = 17;
      final rgba = _rand(w * h * 4, 0x0DD);
      final ref = dartRgbaToI420(rgba, w, h);
      final outY = Uint8List(GpuRgbaToYuv420Converter.ySize(w, h));
      final outU = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
      final outV = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
      await conv!
          .convertFromBytes(rgba, w, h, outY: outY, outU: outU, outV: outV);
      expect(outY, equals(ref.y));
      expect(outU, equals(ref.u));
      expect(outV, equals(ref.v));
    });

    test('matrix/range switch mid-stream reconfigures correctly', () async {
      if (!gpuOk) return markTestSkipped('no GPU');
      const w = 32, h = 32;
      final rgba = _rand(w * h * 4, 7);
      for (final (m, full) in combos) {
        final ref = dartRgbaToI420(rgba, w, h, matrix: m, fullRange: full);
        final outY = Uint8List(w * h);
        final outU = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
        final outV = Uint8List(GpuRgbaToYuv420Converter.uvSize(w, h));
        await conv!.convertFromBytes(rgba, w, h,
            outY: outY, outU: outU, outV: outV, matrix: m, fullRange: full);
        expect(outY, equals(ref.y), reason: '$m full=$full');
        expect(outU, equals(ref.u), reason: '$m full=$full');
        expect(outV, equals(ref.v), reason: '$m full=$full');
      }
    });
  });
}
