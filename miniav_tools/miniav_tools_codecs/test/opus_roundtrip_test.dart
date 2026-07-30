/// First-party libopus decode test: encode Opus with FFmpeg (a convenient
/// packet source — the DECODER under test is FFmpeg-free), then decode with the
/// codecs `OpusAudioDecoder` and assert sane interleaved-f32 PCM geometry.
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

const int kSampleRate = 48000;
const int kChannels = 2;
const int kFrame = 960; // 20 ms @ 48 kHz — an Opus frame size

Uint8List _sineF32(int startFrame, int frameCount) {
  final out = Float32List(frameCount * kChannels);
  for (var i = 0; i < frameCount; i++) {
    final t = startFrame + i;
    final v = math.sin(2 * math.pi * 440.0 * t / kSampleRate) * 0.25;
    for (var c = 0; c < kChannels; c++) {
      out[i * kChannels + c] = v;
    }
  }
  return out.buffer.asUint8List();
}

void main() {
  group('OpusAudioDecoder (first-party libopus)', () {
    setUpAll(() async {
      await ensureFFmpegLoaded(); // only for the encode side (packet source)
    });

    test('decodes FFmpeg-encoded Opus packets to interleaved f32 PCM',
        () async {
      // --- encode (FFmpeg) → Opus packets + OpusHead extradata -------------
      final enc = await FfmpegBackend().createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: kSampleRate,
          channels: kChannels,
          bitrateBps: 128000,
        ),
      );
      expect(enc, isNotNull, reason: 'FFmpeg Opus encoder unavailable');
      final packets = <EncodedPacket>[];
      for (var i = 0; i < 50; i++) {
        packets.addAll(await enc!.encode(
          pcm: _sineF32(i * kFrame, kFrame),
          format: MiniAVAudioFormat.f32,
          frameCount: kFrame,
          ptsUs: (i * kFrame * 1000000) ~/ kSampleRate,
        ));
      }
      packets.addAll(await enc!.flush());
      final head = enc.extraData?.bytes;
      await enc.close();
      expect(packets, isNotEmpty, reason: 'encoder produced no Opus packets');

      // --- decode (first-party libopus, FFmpeg-free) ------------------------
      final dec = await OpusBackend().createAudioDecoder(
        AudioDecoderConfig(
          codec: AudioCodec.opus,
          extraData: head,
          sampleRate: kSampleRate,
          channels: kChannels,
        ),
      );
      expect(dec, isNotNull);

      var totalFrames = 0;
      var maxAbs = 0.0;
      for (final p in packets) {
        for (final chunk in await dec!.decode(p)) {
          expect(chunk.sampleRate, kSampleRate);
          expect(chunk.channels, kChannels);
          expect(chunk.samples.length, chunk.frameCount * kChannels);
          totalFrames += chunk.frameCount;
          for (final s in chunk.samples) {
            final a = s.abs();
            if (a > maxAbs) maxAbs = a;
          }
        }
      }
      for (final chunk in await dec!.flush()) {
        totalFrames += chunk.frameCount;
      }
      await dec.close();

      // ~1 s of audio (Opus adds a little decoder delay); values in-range and
      // non-silent (the 440 Hz sine peaks near 0.25).
      expect(totalFrames, greaterThan(kSampleRate ~/ 2),
          reason: 'too few frames decoded ($totalFrames)');
      expect(maxAbs, greaterThan(0.05), reason: 'decoded PCM is ~silent');
      expect(maxAbs, lessThanOrEqualTo(1.0), reason: 'PCM out of [-1,1]');
    });
  });
}
