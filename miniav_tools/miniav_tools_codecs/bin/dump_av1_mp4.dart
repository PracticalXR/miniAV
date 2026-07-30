// Standalone dev helper: produce one AV1 MP4 to a path passed on argv[0]
// (or `out.mp4` in cwd by default) so we can feed it to external tools
// like ffprobe / dav1d.
//
// Usage:  dart run bin/dump_av1_mp4.dart [output_path] [num_frames]
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart' show Minigpu;

Future<void> main(List<String> argv) async {
  // Silence the [mgpu INFO] / [mgpu WARN] firehose from the native layer.
  // Set MGPU_VERBOSE=1 to keep the default verbosity for debugging.
  if (Platform.environment['MGPU_VERBOSE'] != '1') {
    Minigpu.setLogCallback(null, level: 3); // 3 = ERROR only
  }

  final outPath = argv.isNotEmpty ? argv[0] : 'out.mp4';
  final frames = argv.length >= 2 ? int.parse(argv[1]) : 5;
  final w = argv.length >= 3 ? int.parse(argv[2]) : 64;
  final h = argv.length >= 4 ? int.parse(argv[3]) : 64;
  final crf = argv.length >= 5 ? int.parse(argv[4]) : null;
  final gop = argv.length >= 6 ? int.parse(argv[5]) : 0;

  final exitCode = await _run(outPath, frames, w, h, crf, gop);

  // Force termination: the native WebGPU device + poller thread keep the
  // dart VM alive indefinitely after main() returns, which manifests as a
  // terminal hang. exit() short-circuits cleanup, which is fine for a
  // dev harness — the OS reclaims everything.
  exit(exitCode);
}

Future<int> _run(
  String outPath,
  int frames,
  int w,
  int h,
  int? crf,
  int gop,
) async {
  final backend = MinigpuBackend();
  final cfg = EncoderConfig(
    codec: VideoCodec.av1,
    width: w,
    height: h,
    bitrateBps: 0,
    frameRateNumerator: 30,
    frameRateDenominator: 1,
    crfQuality: crf,
    gopLength: gop,
    inputPixelFormat: MiniAVPixelFormat.rgba32,
  );
  final enc = await backend.createEncoder(cfg);
  if (enc == null) {
    stderr.writeln('no encoder');
    return 2;
  }
  final pkts = <EncodedPacket>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < frames; i++) {
    // Gradient + animated stripes so the encoder actually sees non-zero
    // residual and exercises the br_tok path.  Black bars at the edges
    // keep DC excursions inside ±14 (kMaxLevel) of the DC predictor.
    final buf = Uint8List(w * h * 4);
    var rngState = 0x2545F491 ^ i;
    int rnd() {
      rngState ^= (rngState << 13) & 0xFFFFFFFF;
      rngState ^= rngState >> 17;
      rngState ^= (rngState << 5) & 0xFFFFFFFF;
      return rngState & 0xFF;
    }

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        // High-frequency checkerboard + noise: hardest case for AC coding.
        final cb = ((x ^ y) & 1) == 0 ? 220 : 20;
        buf[o + 0] = (cb + rnd() - 128).clamp(0, 255);
        buf[o + 1] = rnd().clamp(0, 255);
        buf[o + 2] = ((x * 4) ^ (y * 4) ^ rnd()).clamp(0, 255);
        buf[o + 3] = 255;
      }
    }
    final p = await enc.encode(
      CpuFrameSource(
        bytes: buf,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: i * 33333,
      ),
    );
    if (p != null) pkts.add(p);
  }
  sw.stop();
  final perFrame = frames > 0 ? sw.elapsedMilliseconds / frames : 0;
  stdout.writeln(
    'encoded $frames frame(s) in ${sw.elapsedMilliseconds}ms '
    '(${perFrame.toStringAsFixed(1)} ms/frame, crf=${crf ?? "default"})',
  );
  final extra = enc.extraData;
  await enc.close();

  final mux = await backend.createMuxer(
    MuxerConfig(
      container: Container.mp4,
      output: MuxerOutput.file(outPath),
      tracks: [
        VideoTrackInfo(
          codec: VideoCodec.av1,
          width: w,
          height: h,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          extraData: extra,
        ),
      ],
    ),
  );
  await mux!.writeHeader();
  for (final p in pkts) {
    await mux.writePacket(p);
  }
  await mux.finish();
  await mux.close();
  stdout.writeln('wrote $outPath (${pkts.length} samples)');
  return 0;
}
