// Throughput benchmark for the minigpu AV1 encoder pipeline.
//
// Encodes N frames at the given resolution and reports:
//   - cold-start latency (first frame, includes pipeline build)
//   - steady-state per-frame latency (mean / p50 / p95)
//   - encoded throughput (frames/s, MB/s of bitstream)
//
// Usage:
//   dart run bin/bench_av1.dart [WxH] [frames] [warmup]
//
// Examples:
//   dart run bin/bench_av1.dart 256x256 64 8
//   dart run bin/bench_av1.dart 1280x720 30 4
//
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart' show Minigpu;

Future<int> main(List<String> argv) async {
  // Silence native log spam (ERROR only); each log line is a synchronous
  // stderr write and dominates the all-skip path at small resolutions.
  Minigpu.setLogCallback(null, level: 3);

  final res = argv.isNotEmpty ? argv[0] : '256x256';
  final n = argv.length >= 2 ? int.parse(argv[1]) : 64;
  final warmup = argv.length >= 3 ? int.parse(argv[2]) : 8;

  final parts = res.toLowerCase().split('x');
  if (parts.length != 2) {
    stderr.writeln('bad res "$res"; expected WxH');
    return 2;
  }
  final w = int.parse(parts[0]);
  final h = int.parse(parts[1]);
  if (w % 64 != 0 || h % 64 != 0) {
    stderr.writeln('WARN: $w x $h not multiple of 64; encoder may refuse');
  }

  final backend = MinigpuBackend();
  final cfg = EncoderConfig(
    codec: VideoCodec.av1,
    width: w,
    height: h,
    bitrateBps: 0,
    frameRateNumerator: 60,
    frameRateDenominator: 1,
    inputPixelFormat: MiniAVPixelFormat.rgba32,
  );

  final enc = await backend.createEncoder(cfg);
  if (enc == null) {
    stderr.writeln('encoder unavailable');
    return 2;
  }

  // Allocate a single input buffer; reuse to avoid GC noise.
  final input = Uint8List(w * h * 4);
  // Fill with a non-trivial gradient so encoder doesn't short-circuit
  // (currently meaningless for the all-skip path but exercises the GPU).
  for (var i = 0; i < input.length; i += 4) {
    final px = (i >> 2);
    final x = px % w;
    final y = px ~/ w;
    input[i + 0] = (x * 255 ~/ w) & 0xFF;
    input[i + 1] = (y * 255 ~/ h) & 0xFF;
    input[i + 2] = ((x + y) * 255 ~/ (w + h)) & 0xFF;
    input[i + 3] = 255;
  }

  Future<EncodedPacket?> oneFrame(int idx) {
    return enc.encode(
      CpuFrameSource(
        bytes: input,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: idx * (1000000 ~/ 60),
      ),
    );
  }

  // --- cold start (includes pipeline build & shader compile) ---
  final coldSw = Stopwatch()..start();
  final firstPkt = await oneFrame(0);
  coldSw.stop();
  final coldMs = coldSw.elapsedMicroseconds / 1000.0;
  final firstSize = firstPkt?.data.length ?? 0;

  // --- warmup ---
  for (var i = 1; i <= warmup; i++) {
    await oneFrame(i);
  }

  // --- measured loop ---
  final latencies = <double>[];
  var totalBytes = 0;
  final wall = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    final p = await oneFrame(warmup + 1 + i);
    sw.stop();
    if (p != null) totalBytes += p.data.length;
    latencies.add(sw.elapsedMicroseconds / 1000.0);
  }
  wall.stop();
  await enc.close();

  latencies.sort();
  double pct(double q) =>
      latencies[(latencies.length * q).clamp(0, latencies.length - 1).toInt()];
  final mean = latencies.fold<double>(0, (a, b) => a + b) / latencies.length;
  final p50 = pct(0.50);
  final p95 = pct(0.95);
  final p99 = pct(0.99);

  final wallS = wall.elapsedMicroseconds / 1e6;
  final fps = n / wallS;
  final mbps = (totalBytes * 8 / 1e6) / wallS;

  stdout
    ..writeln('=== AV1 minigpu encoder benchmark ===')
    ..writeln('resolution     : ${w}x$h')
    ..writeln('warmup frames  : $warmup')
    ..writeln('measured frames: $n')
    ..writeln(
      'cold start     : ${coldMs.toStringAsFixed(2)} ms '
      '(first packet ${firstSize}B)',
    )
    ..writeln('per-frame mean : ${mean.toStringAsFixed(3)} ms')
    ..writeln('per-frame p50  : ${p50.toStringAsFixed(3)} ms')
    ..writeln('per-frame p95  : ${p95.toStringAsFixed(3)} ms')
    ..writeln('per-frame p99  : ${p99.toStringAsFixed(3)} ms')
    ..writeln('throughput     : ${fps.toStringAsFixed(1)} fps')
    ..writeln(
      'bitstream avg  : '
      '${(totalBytes / n).toStringAsFixed(1)} B/frame '
      '(${mbps.toStringAsFixed(3)} Mb/s)',
    );
  return 0;
}
