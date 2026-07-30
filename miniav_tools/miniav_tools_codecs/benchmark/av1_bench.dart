/// minigpu AV1 encoder benchmarks.
///
/// Sweeps encode throughput across resolutions to expose where time is
/// spent (GPU YUV stage + readback vs CPU MSAC tile-group emission) and
/// to track the impact of moving stages onto minigpu.
///
/// Frame dimensions are constrained to multiples of 64 because the tile
/// group walker emits a complete 64×64 superblock partition tree.
///
/// Run:
///   dart run benchmark/av1_bench.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
// ignore: implementation_imports
import 'package:miniav_tools_codecs/src/av1/minigpu_av1_pipeline.dart'
    show MinigpuAv1Pipeline;
// ignore: implementation_imports
import 'package:miniav_tools_codecs/src/gpu_codec_pipeline.dart'
    show GpuCodecEncoder;
import 'package:minigpu/minigpu.dart' show Minigpu;

Uint8List _makeGradient(int w, int h, int frameIdx) {
  final buf = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      buf[i] = ((x * 200) ~/ (w - 1)) & 0xff;
      buf[i + 1] = ((y * 200) ~/ (h - 1)) & 0xff;
      buf[i + 2] = ((x + y + frameIdx * 8) & 0x7f);
      buf[i + 3] = 255;
    }
  }
  return buf;
}

Future<void> _bench(int w, int h, {int warmup = 2, int runs = 10}) async {
  final tag = '${w}x$h';
  final backend = MinigpuBackend();
  final enc = await backend.createEncoder(
    EncoderConfig(
      codec: VideoCodec.av1,
      width: w,
      height: h,
      bitrateBps: 0,
      frameRateNumerator: 30,
      frameRateDenominator: 1,
      inputPixelFormat: MiniAVPixelFormat.rgba32,
    ),
  );
  if (enc == null) {
    print('  AV1 $tag: SKIP (encoder not available)');
    return;
  }

  // Warmup
  for (var i = 0; i < warmup; i++) {
    await enc.encode(
      CpuFrameSource(
        bytes: _makeGradient(w, h, i),
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: i * 33333,
      ),
    );
  }

  // Measure: each iteration uses a fresh gradient so the source DCs vary.
  final sw = Stopwatch()..start();
  int totalBytes = 0;
  double sumResidualMs = 0, sumPackTotalMs = 0, sumBytesToFloatMs = 0;
  double sumUploadMs = 0, sumRunOnceMs = 0, sumDownloadMs = 0;
  for (var i = 0; i < runs; i++) {
    final pkt = await enc.encode(
      CpuFrameSource(
        bytes: _makeGradient(w, h, i + warmup),
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: (i + warmup) * 33333,
      ),
    );
    if (pkt != null) totalBytes += pkt.data.length;
    if (enc is GpuCodecEncoder) {
      final pipeline = enc.pipeline;
      if (pipeline is MinigpuAv1Pipeline) {
        sumResidualMs += pipeline.lastResidualMs;
        sumPackTotalMs += pipeline.lastPackTotalMs;
        sumBytesToFloatMs += pipeline.lastBytesToFloatMs;
      }
      sumUploadMs += enc.lastUploadMs;
      sumRunOnceMs += enc.lastRunOnceMs;
      sumDownloadMs += enc.lastDownloadMs;
    }
  }
  sw.stop();
  await enc.close();

  final avgMs = sw.elapsedMilliseconds / runs;
  final fps = avgMs > 0 ? 1000 / avgMs : double.infinity;
  final avgBytes = totalBytes / runs;
  final mbps = (avgBytes * 8 * 30) / 1e6;
  final avgResidualMs = sumResidualMs / runs;
  final avgPackMs = sumPackTotalMs / runs;
  final avgB2fMs = sumBytesToFloatMs / runs;
  print(
    'AV1 $tag: ${avgMs.toStringAsFixed(1)} ms/frame  '
    '(${fps.toStringAsFixed(1)} fps)  '
    '${(avgBytes / 1024).toStringAsFixed(1)} KB/frame  '
    '(~${mbps.toStringAsFixed(2)} Mbps @ 30fps)',
  );
  if (avgResidualMs > 0) {
    final gpuAndRestMs = avgMs - avgPackMs;
    print(
      '  breakdown: gpu+xfer ${gpuAndRestMs.toStringAsFixed(1)} ms  '
      'pack ${avgPackMs.toStringAsFixed(1)} ms  '
      '(residual ${avgResidualMs.toStringAsFixed(1)} ms, '
      'bytes2float ${avgB2fMs.toStringAsFixed(1)} ms)',
    );
    final avgUp = sumUploadMs / runs;
    final avgRun = sumRunOnceMs / runs;
    final avgDl = sumDownloadMs / runs;
    print(
      '    gpu sub:  upload ${avgUp.toStringAsFixed(1)} ms  '
      'runOnce ${avgRun.toStringAsFixed(1)} ms  '
      'enc-dl ${avgDl.toStringAsFixed(1)} ms',
    );
  }
}

Future<void> main() async {
  if (Platform.environment['MGPU_VERBOSE'] != '1') {
    Minigpu.setLogCallback(null, level: 3);
  }
  print('=== minigpu AV1 encoder ===\n');
  print('--- Resolution sweep (intra-only, base_q_idx=32) ---');
  await _bench(64, 64);
  await _bench(256, 256);
  await _bench(512, 512);
  await _bench(1024, 1024);
  await _bench(1920, 1088);
  // Native poller keeps VM alive; explicit exit unblocks the script.
  exit(0);
}
