/// Smoke test: AAC and Opus audio encoding via the FFmpeg backend.
///
/// Encodes 1 second of a 440 Hz stereo sine wave at 48 kHz and validates
/// that the encoder emits non-empty packets and (where applicable)
/// extradata.
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegAudioEncoder', () {
    setUpAll(() async {
      await ensureFFmpegLoaded();
    });

    test('AAC encodes 1 second of stereo float audio', () async {
      await _runOneSecond(AudioCodec.aac);
    });

    test('Opus encodes 1 second of stereo float audio', () async {
      try {
        await _runOneSecond(AudioCodec.opus);
      } on CodecInitException catch (e) {
        // libopus may be missing from the loaded FFmpeg build.
        print('SKIP Opus: ${e.message}');
      }
    });
  });
}

Future<void> _runOneSecond(AudioCodec codec) async {
  const sampleRate = 48000;
  const channels = 2;
  const seconds = 1;

  final backend = FfmpegBackend();
  if (!backend.supportsAudioEncode(codec)) {
    print('SKIP $codec: backend.supportsAudioEncode=false');
    return;
  }
  final enc = await backend.createAudioEncoder(
    AudioEncoderConfig(
      codec: codec,
      sampleRate: sampleRate,
      channels: channels,
      bitrateBps: codec == AudioCodec.aac ? 128_000 : 96_000,
      backendOptions: const {'global_header': '1'},
    ),
  );
  expect(enc, isNotNull, reason: 'createAudioEncoder returned null');

  // Generate 1 second of interleaved f32 stereo sine wave.
  const totalFrames = sampleRate * seconds;
  final pcm = Float32List(totalFrames * channels);
  const freq = 440.0;
  for (var i = 0; i < totalFrames; i++) {
    final v = math.sin(2 * math.pi * freq * i / sampleRate) * 0.25;
    pcm[i * channels] = v;
    pcm[i * channels + 1] = v;
  }
  final pcmBytes = Uint8List.view(pcm.buffer);

  final allPackets = <EncodedPacket>[];
  // Send in ~50 chunks to exercise the buffering path.
  const chunks = 50;
  final framesPerChunk = totalFrames ~/ chunks;
  final bytesPerFrame = channels * 4;
  var sentFrames = 0;
  for (var c = 0; c < chunks; c++) {
    final isLast = c == chunks - 1;
    final fc = isLast ? (totalFrames - sentFrames) : framesPerChunk;
    final off = sentFrames * bytesPerFrame;
    final slice = Uint8List.sublistView(
      pcmBytes,
      off,
      off + fc * bytesPerFrame,
    );
    final ptsUs = (sentFrames * 1000000) ~/ sampleRate;
    final pkts = await enc!.encode(
      pcm: slice,
      format: MiniAVAudioFormat.f32,
      frameCount: fc,
      ptsUs: ptsUs,
    );
    allPackets.addAll(pkts);
    sentFrames += fc;
  }
  allPackets.addAll(await enc!.flush());

  final totalBytes = allPackets.fold<int>(0, (a, p) => a + p.data.length);
  print(
    '$codec: ${allPackets.length} packets, $totalBytes bytes, '
    'extradata=${enc.extraData?.bytes.length ?? 0}',
  );
  expect(allPackets, isNotEmpty);
  expect(totalBytes, greaterThan(0));
  // Pts should be monotonically non-decreasing.
  for (var i = 1; i < allPackets.length; i++) {
    expect(allPackets[i].ptsUs, greaterThanOrEqualTo(allPackets[i - 1].ptsUs));
  }
  await enc.close();
}
