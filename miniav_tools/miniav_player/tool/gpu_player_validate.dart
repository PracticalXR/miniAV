/// GPU YUV420P→RGBA8 lockstep validation: the UNIFIED planar WGSL kernel
/// (miniav_tools_codecs/gpu.dart) vs the CPU reference, byte-exact.
///
/// Run from the package root on a machine with a working Dawn adapter:
///
///     dart run tool/gpu_player_validate.dart
///
/// This is a `tool/` main-isolate program (NOT a `dart test`) because Dawn
/// cannot initialize inside `dart test` isolates on the dev box — same
/// pattern as gsplats420's `gpu_v9_validate.dart`. Flutter is not imported
/// anywhere in this entry point's graph.
///
/// Trap check baked in (see gsplats420 GPU-encode memory): a WGSL compile
/// error can be SILENT — readbacks just return zeros. We content-verify
/// every output against the CPU reference, and the all-zero case fails the
/// black-frame guard, so a non-compiling kernel cannot pass.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:minigpu/minigpu.dart';
import 'package:miniav_tools/miniav_tools.dart' show DecodedPixelLayout;
import 'package:miniav_tools_codecs/gpu.dart';
import 'package:miniav_player/src/yuv_rgba_reference.dart';

Uint8List _uniform(int w, int h, int y, int u, int v) {
  final ySize = w * h;
  final uvSize = (w >> 1) * (h >> 1);
  final buf = Uint8List(ySize + 2 * uvSize);
  buf.fillRange(0, ySize, y);
  buf.fillRange(ySize, ySize + uvSize, u);
  buf.fillRange(ySize + uvSize, buf.length, v);
  return buf;
}

Uint8List _gradient(int w, int h) {
  final ySize = w * h;
  final cw = w >> 1;
  final ch = h >> 1;
  final buf = Uint8List(ySize + 2 * cw * ch);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      buf[y * w + x] = ((x + y) * 255) ~/ (w + h);
    }
  }
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      buf[ySize + y * cw + x] = (x * 255) ~/ cw;
      buf[ySize + cw * ch + y * cw + x] = (y * 255) ~/ ch;
    }
  }
  return buf;
}

Uint8List _random(int w, int h, int seed) {
  final rng = Random(seed);
  final buf = Uint8List(
      GpuPlanarYuvToRgbaConverter.yuvSize(DecodedPixelLayout.i420, w, h));
  for (var i = 0; i < buf.length; i++) {
    buf[i] = rng.nextInt(256);
  }
  return buf;
}

Future<void> main() async {
  final gpu = Minigpu();
  await gpu.init();
  final converter = GpuPlanarYuvToRgbaConverter(gpu);

  final cases = <(String, int, int, Uint8List)>[
    ('uniform-black 64x64', 64, 64, _uniform(64, 64, 16, 128, 128)),
    ('uniform-white 64x64', 64, 64, _uniform(64, 64, 235, 128, 128)),
    ('chroma-extremes 64x64', 64, 64, _uniform(64, 64, 128, 255, 0)),
    ('gradient 322x242 (non-multiple-of-8)', 322, 242, _gradient(322, 242)),
    ('random 128x72', 128, 72, _random(128, 72, 1)),
    ('random 640x360', 640, 360, _random(640, 360, 2)),
    ('gradient 1920x1080', 1920, 1080, _gradient(1920, 1080)),
  ];

  var failures = 0;
  for (final (name, w, h, yuv) in cases) {
    final sw = Stopwatch()..start();
    final gpuOut = await converter.convertAndRead(yuv, w, h);
    final gpuMs = sw.elapsedMicroseconds / 1000.0;
    final cpuOut = yuv420pToRgba8(yuv, w, h);

    // Silent-kernel guard: a non-compiled shader reads back zeros.
    final anyNonZero = gpuOut.any((b) => b != 0);
    if (!anyNonZero) {
      stdout.writeln('FAIL $name — GPU output is all zeros '
          '(kernel likely failed to compile; check stderr for '
          '"uncaptured Validation")');
      failures++;
      continue;
    }

    var diffs = 0;
    var firstDiff = -1;
    for (var i = 0; i < cpuOut.length; i++) {
      if (gpuOut[i] != cpuOut[i]) {
        diffs++;
        if (firstDiff < 0) firstDiff = i;
      }
    }
    if (diffs == 0) {
      stdout.writeln(
        'PASS $name — byte-exact (${cpuOut.length} bytes, '
        'gpu ${gpuMs.toStringAsFixed(2)} ms)',
      );
    } else {
      final px = firstDiff ~/ 4;
      stdout.writeln(
        'FAIL $name — $diffs differing bytes; first at byte $firstDiff '
        '(pixel ${px % w},${px ~/ w} ch ${firstDiff % 4}): '
        'gpu=${gpuOut[firstDiff]} cpu=${cpuOut[firstDiff]}',
      );
      failures++;
    }
  }

  converter.dispose();
  await gpu.destroy();
  if (failures > 0) {
    stdout.writeln('\n$failures case(s) FAILED');
    exit(1);
  }
  stdout.writeln('\nAll ${cases.length} cases byte-exact — GPU==CPU.');
}
