/// The unified GPU planar YUV→RGBA converter must be BYTE-IDENTICAL to the
/// native C converter (`cpuPlanarToRgba`) for every planar layout × range — the
/// C path is itself byte-exact-tested against the fixed-point reference
/// (`frame_convert_test.dart`), so transitively the GPU output equals the
/// reference. This is what lets the player present 4:2:2/4:4:4/10-bit/full-range
/// frames on the GPU with confidence.
///
/// Runs under `dart test` (Dawn inits in the test isolate on this dev box). If
/// Dawn can't init in this environment the whole group skips cleanly.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_codecs/gpu.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart';
import 'package:test/test.dart';

// DecodedPixelLayout (GPU converter's type) → YuvPlanar (C converter's type).
YuvPlanar _cpuPlanar(DecodedPixelLayout l) => switch (l) {
      DecodedPixelLayout.i420 => YuvPlanar.i420,
      DecodedPixelLayout.i422 => YuvPlanar.i422,
      DecodedPixelLayout.i444 => YuvPlanar.i444,
      DecodedPixelLayout.i420p10 => YuvPlanar.i420p10,
      DecodedPixelLayout.i422p10 => YuvPlanar.i422p10,
      DecodedPixelLayout.i444p10 => YuvPlanar.i444p10,
      DecodedPixelLayout.nv12 ||
      DecodedPixelLayout.p010 ||
      DecodedPixelLayout.rgba =>
        throw ArgumentError('nv12/p010/rgba not planar YUV'),
    };

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
  group('unified GPU planar converter == C (byte-exact)', () {
    late Minigpu gpu;
    GpuPlanarYuvToRgbaConverter? conv;
    var gpuOk = false;

    setUpAll(() async {
      try {
        Minigpu.preferDisplayAdapter();
        gpu = Minigpu();
        await gpu.init();
        conv = GpuPlanarYuvToRgbaConverter(gpu);
        gpuOk = true;
      } catch (e) {
        gpuOk = false;
        // ignore: avoid_print
        print('GPU-PLANAR-DIAG: Dawn init failed, skipping — $e');
      }
    });

    tearDownAll(() async {
      if (!gpuOk) return;
      conv?.dispose();
      await gpu.destroy();
    });

    const layouts = [
      DecodedPixelLayout.i420,
      DecodedPixelLayout.i422,
      DecodedPixelLayout.i444,
      DecodedPixelLayout.i420p10,
      DecodedPixelLayout.i422p10,
      DecodedPixelLayout.i444p10,
    ];

    for (final layout in layouts) {
      for (final full in [false, true]) {
        test('$layout fullRange=$full', () async {
          if (!gpuOk) {
            markTestSkipped('Dawn/minigpu unavailable in this environment');
            return;
          }
          const w = 64, h = 48; // even dims (the player only feeds even frames)
          final size = GpuPlanarYuvToRgbaConverter.yuvSize(layout, w, h);
          final yuv = _rand(size, 0x51 + layout.index * 7 + (full ? 1 : 0));

          final got = await conv!
              .convertAndRead(yuv, w, h, layout: layout, fullRange: full);
          final want = cpuPlanarToRgba(_cpuPlanar(layout), yuv, w, h,
              fullRange: full);

          expect(got.length, want.length);
          expect(got, equals(want),
              reason: 'GPU output diverged from the C reference for '
                  '$layout fullRange=$full');
        });
      }
    }

    test('bt709 GPU == C for i420 + i420p10 (limited + full)', () async {
      if (!gpuOk) {
        markTestSkipped('Dawn/minigpu unavailable in this environment');
        return;
      }
      for (final layout in [
        DecodedPixelLayout.i420,
        DecodedPixelLayout.i420p10,
      ]) {
        for (final full in [false, true]) {
          const w = 32, h = 16;
          final size = GpuPlanarYuvToRgbaConverter.yuvSize(layout, w, h);
          final yuv = _rand(size, 0x709 + layout.index + (full ? 3 : 0));
          final got = await conv!.convertAndRead(yuv, w, h,
              layout: layout,
              fullRange: full,
              matrix: YuvColorMatrix.bt709);
          final want = cpuPlanarToRgba(_cpuPlanar(layout), yuv, w, h,
              fullRange: full, matrix: YuvColorMatrix.bt709);
          expect(got, equals(want), reason: 'bt709 $layout full=$full');
        }
      }
    });

    test('bt2020 GPU == C for i420 (limited + full)', () async {
      if (!gpuOk) {
        markTestSkipped('Dawn/minigpu unavailable in this environment');
        return;
      }
      for (final full in [false, true]) {
        const w = 32, h = 16;
        final size =
            GpuPlanarYuvToRgbaConverter.yuvSize(DecodedPixelLayout.i420, w, h);
        final yuv = _rand(size, 0x2020 + (full ? 1 : 0));
        final got = await conv!.convertAndRead(yuv, w, h,
            fullRange: full, matrix: YuvColorMatrix.bt2020);
        final want = cpuPlanarToRgba(YuvPlanar.i420, yuv, w, h,
            fullRange: full, matrix: YuvColorMatrix.bt2020);
        expect(got, equals(want), reason: 'bt2020 full=$full');
      }
    });

    test('i420 limited across sizes reuses the shader (no leak/mismatch)',
        () async {
      if (!gpuOk) {
        markTestSkipped('Dawn/minigpu unavailable in this environment');
        return;
      }
      for (final (w, h) in const [(16, 16), (64, 48), (32, 32)]) {
        final size = GpuPlanarYuvToRgbaConverter.yuvSize(
            DecodedPixelLayout.i420, w, h);
        final yuv = _rand(size, 0x900 + w);
        final got = await conv!.convertAndRead(yuv, w, h);
        final want = cpuPlanarToRgba(YuvPlanar.i420, yuv, w, h);
        expect(got, equals(want), reason: 'i420 ${w}x$h');
      }
    });
  });
}
