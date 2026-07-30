/// minigpu MJPEG encoder benchmarks.
///
/// Measures pure-GPU WGSL MJPEG encode throughput at several resolutions
/// and quality settings.  No native libraries required — only a WebGPU
/// adapter.
///
/// Run:
///   dart run benchmark/mjpeg_bench.dart
///
/// The benchmark skips gracefully when no WebGPU adapter is available (e.g.,
/// headless CI without a GPU).
library;

import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _makeGradient(int w, int h) {
  final buf = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      buf[i] = (x * 255 ~/ w) & 0xff;
      buf[i + 1] = (y * 255 ~/ h) & 0xff;
      buf[i + 2] = ((x + y) * 127 ~/ (w + h)) & 0xff;
      buf[i + 3] = 255;
    }
  }
  return buf;
}

// ---------------------------------------------------------------------------
// Benchmark runner
// ---------------------------------------------------------------------------

Future<void> _benchMjpeg(int w, int h, int quality) async {
  const label = 'MJPEG';
  final tag = '${w}x$h q$quality';

  final backend = MinigpuBackend();
  final enc = await backend.createEncoder(
    EncoderConfig(
      codec: VideoCodec.mjpeg,
      width: w,
      height: h,
      bitrateBps: 0,
      frameRateNumerator: 60,
      frameRateDenominator: 1,
      inputPixelFormat: MiniAVPixelFormat.rgba32,
      crfQuality: quality,
    ),
  );

  if (enc == null) {
    print('  $label $tag: SKIP (encoder not available — GPU likely absent)');
    return;
  }

  final frame = _makeGradient(w, h);

  // Warm-up
  for (var i = 0; i < 3; i++) {
    await enc.encode(
      CpuFrameSource(
        bytes: frame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: 0,
      ),
    );
  }

  // Measure
  const measureRuns = 20;
  final sw = Stopwatch()..start();
  int? lastSize;
  for (var i = 0; i < measureRuns; i++) {
    final pkt = await enc.encode(
      CpuFrameSource(
        bytes: frame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: i * 16667,
      ),
    );
    lastSize ??= pkt?.data.length;
  }
  sw.stop();
  await enc.close();

  final avgMs = sw.elapsedMilliseconds / measureRuns;
  final fps = 1000 / avgMs;
  final sizeStr = lastSize != null ? '~${lastSize ~/ 1024} KB/frame' : '';
  print(
    '$label $tag: ${avgMs.toStringAsFixed(1)} ms/frame  '
    '(${fps.toStringAsFixed(1)} fps)  $sizeStr',
  );
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== minigpu MJPEG encoder (pure-WGSL) ===\n');

  // Resolution sweep at mid-quality (CRF 23)
  print('--- Resolution sweep (quality CRF 23) ---');
  await _benchMjpeg(320, 240, 23);
  await _benchMjpeg(640, 480, 23);
  await _benchMjpeg(1280, 720, 23);
  await _benchMjpeg(1920, 1080, 23);

  // Quality sweep at 1080p
  print('\n--- Quality sweep (1920x1080) ---');
  await _benchMjpeg(1920, 1080, 1); // best quality
  await _benchMjpeg(1920, 1080, 10);
  await _benchMjpeg(1920, 1080, 23); // balanced
  await _benchMjpeg(1920, 1080, 31); // smallest file
}
