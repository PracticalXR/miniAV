/// FFmpeg encoder benchmarks.
///
/// Measures:
///   1. Software libx264 encode throughput at 480p / 1080p / 4K.
///   2. (Optional) Hardware encode throughput for every detected vendor at 1080p.
///   3. Muxer write throughput — how fast packets can be muxed to memory.
///
/// Run:
///   dart run benchmark/encoder_bench.dart
///
/// Environment:
///   MINIAV_TOOLS_FFMPEG_NETTEST=1   Allow auto-downloading FFmpeg (requires network).
///   BENCH_HW=1                      Also run hardware encoder benchmarks.
///   BENCH_MUXER=1                   Also run muxer throughput benchmark.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generates a synthetic RGBA gradient frame.
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
// Sync/async bridge for benchmark_harness
// ---------------------------------------------------------------------------

/// Async benchmark base that measures wall-clock time for [runAsync].
abstract class AsyncBenchmarkBase {
  final String name;
  const AsyncBenchmarkBase(this.name);

  Future<void> runAsync();
  Future<void> setupAsync() async {}
  Future<void> teardownAsync() async {}

  Future<void> measureAsync() async {
    await setupAsync();
    // Warm-up
    for (var i = 0; i < 3; i++) {
      await runAsync();
    }
    // Measure
    const measureRuns = 20;
    final sw = Stopwatch()..start();
    for (var i = 0; i < measureRuns; i++) {
      await runAsync();
    }
    sw.stop();
    final avgMs = sw.elapsedMilliseconds / measureRuns;
    print(
      '$name: ${avgMs.toStringAsFixed(1)} ms/frame  '
      '(${(1000 / avgMs).toStringAsFixed(1)} fps)',
    );
    await teardownAsync();
  }
}

// ---------------------------------------------------------------------------
// Software encoder benchmarks
// ---------------------------------------------------------------------------

class _SoftwareEncoderBench extends AsyncBenchmarkBase {
  final int width;
  final int height;
  final Uint8List _frame;

  late PlatformEncoder _enc;

  _SoftwareEncoderBench(this.width, this.height)
    : _frame = _makeGradient(width, height),
      super('libx264 ${width}x$height');

  @override
  Future<void> setupAsync() async {
    final backend = FfmpegBackend();
    _enc = (await backend.createEncoder(
      EncoderConfig(
        codec: VideoCodec.h264,
        width: width,
        height: height,
        bitrateBps: 4_000_000,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        hwAccel: HwAccelPreference.forbidden,
        backendOptions: const {'preset': 'ultrafast', 'tune': 'zerolatency'},
      ),
    ))!;
  }

  @override
  Future<void> runAsync() async {
    await _enc.encode(
      CpuFrameSource(
        bytes: _frame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: width,
        height: height,
        timestampUs: 0,
      ),
    );
  }

  @override
  Future<void> teardownAsync() async {
    await _enc.flush();
    await _enc.close();
  }
}

// ---------------------------------------------------------------------------
// Hardware encoder benchmarks
// ---------------------------------------------------------------------------

class _HwEncoderBench extends AsyncBenchmarkBase {
  final HwEncoderVendor vendor;
  final int width;
  final int height;
  final Uint8List _frame;

  late FfmpegHwEncoder _enc;

  _HwEncoderBench(this.vendor, this.width, this.height)
    : _frame = _makeGradient(width, height),
      super('${vendor.name} ${width}x$height');

  @override
  Future<void> setupAsync() async {
    _enc = FfmpegHwEncoder.openWith(
      EncoderConfig(
        codec: VideoCodec.h264,
        width: width,
        height: height,
        bitrateBps: 4_000_000,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        hwAccel: HwAccelPreference.required,
        rateControl: RateControl.vbr,
        bFrameCount: 0,
      ),
      vendor,
    );
  }

  @override
  Future<void> runAsync() async {
    await _enc.encode(
      CpuFrameSource(
        bytes: _frame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: width,
        height: height,
        timestampUs: 0,
      ),
    );
  }

  @override
  Future<void> teardownAsync() async {
    await _enc.flush();
    await _enc.close();
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  final canLoad = tryLoadFFmpeg();
  final netAllowed = Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1';
  if (!canLoad && !netAllowed) {
    print(
      'FFmpeg not found. Set MINIAV_TOOLS_FFMPEG_NETTEST=1 to auto-download.',
    );
    exit(1);
  }
  print('Loading FFmpeg...');
  await ensureFFmpegLoaded();
  print('FFmpeg loaded.\n');

  // ------------------------------------------------------------------
  // Software encoder throughput — three resolutions
  // ------------------------------------------------------------------
  print('=== Software encoder (libx264, ultrafast) ===');
  await _SoftwareEncoderBench(640, 480).measureAsync();
  await _SoftwareEncoderBench(1920, 1080).measureAsync();
  await _SoftwareEncoderBench(3840, 2160).measureAsync();

  // ------------------------------------------------------------------
  // Hardware encoder throughput (opt-in)
  // ------------------------------------------------------------------
  if (Platform.environment['BENCH_HW'] == '1') {
    print('\n=== Hardware encoder (${Platform.operatingSystem}) ===');
    final vendors = ffmpegHwVendorsAvailable();
    if (vendors.isEmpty) {
      print('  No HW encoder vendors detected — skipping.');
    } else {
      for (final v in vendors) {
        try {
          await _HwEncoderBench(v, 1920, 1080).measureAsync();
        } on CodecInitException catch (e) {
          print('  ${v.name}: init failed — ${e.message}');
        }
      }
    }
  }

  // ------------------------------------------------------------------
  // Muxer write throughput (opt-in)
  // ------------------------------------------------------------------
  if (Platform.environment['BENCH_MUXER'] == '1') {
    print('\n=== Muxer write throughput ===');
    await _runMuxerBench();
  }
}

Future<void> _runMuxerBench() async {
  const w = 1920;
  const h = 1080;
  const frameCount = 300;

  final backend = FfmpegBackend();
  final enc = (await backend.createEncoder(
    const EncoderConfig(
      codec: VideoCodec.h264,
      width: w,
      height: h,
      bitrateBps: 8_000_000,
      frameRateNumerator: 60,
      frameRateDenominator: 1,
      hwAccel: HwAccelPreference.forbidden,
      backendOptions: {'preset': 'ultrafast', 'tune': 'zerolatency'},
    ),
  ))!;

  // Collect enough packets to have extraData (first keyframe).
  final initFrame = _makeGradient(w, h);
  EncodedPacket? firstPkt;
  for (var i = 0; i < 5; i++) {
    firstPkt = await enc.encode(
      CpuFrameSource(
        bytes: initFrame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: i * 16667,
      ),
    );
    if (firstPkt != null) break;
  }
  if (firstPkt == null || enc.extraData == null) {
    print('  Could not prime encoder — skipping muxer bench.');
    await enc.close();
    return;
  }

  final muxer = (await backend.createMuxer(
    MuxerConfig(
      container: Container.mp4,
      output: MuxerOutput.bytes(),
      tracks: [
        VideoTrackInfo(
          codec: VideoCodec.h264,
          width: w,
          height: h,
          frameRateNumerator: 60,
          frameRateDenominator: 1,
          extraData: enc.extraData!,
        ),
      ],
    ),
  ))!;
  await muxer.writeHeader();

  // Pre-encode packets.
  final packets = <EncodedPacket>[];
  for (var i = 0; i < frameCount; i++) {
    final pkt = await enc.encode(
      CpuFrameSource(
        bytes: initFrame,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: (i + 5) * 16667,
      ),
    );
    if (pkt != null) packets.add(pkt);
  }
  for (final pkt in await enc.flush()) {
    packets.add(pkt);
  }
  await enc.close();

  // Measure mux write rate.
  final sw = Stopwatch()..start();
  for (final pkt in packets) {
    await muxer.writePacket(pkt);
  }
  await muxer.finish();
  sw.stop();

  final pktCount = packets.length;
  final avgMicros = sw.elapsedMicroseconds / pktCount;
  print(
    'FfmpegMuxer write: ${avgMicros.toStringAsFixed(1)} µs/packet  '
    '($pktCount packets, ${sw.elapsedMilliseconds} ms total)',
  );
}
