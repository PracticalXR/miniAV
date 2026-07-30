// P1.1: first-party libopus ENCODE — completes the FFmpeg-free Opus round-trip.
// Encodes a tone via OpusBackend (FFmpeg EXCLUDED) and decodes it back with the
// first-party OpusAudioDecoder, proving a full Opus encode+decode path with
// zero FFmpeg in the process (libopus is static-linked into codecs_native).
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerOpusBackend, OpusAudioDecoder;
import 'package:test/test.dart';

void main() {
  setUpAll(registerOpusBackend);

  test('Opus encode→decode round-trip is FFmpeg-free and audible', () async {
    const sr = 48000;
    const ch = 2;
    const frames = 48000; // 1 second == exactly 50 × 20 ms Opus frames
    final src = Float32List(frames * ch);
    for (var i = 0; i < frames; i++) {
      final v = 0.3 * math.sin(2 * math.pi * 440 * i / sr);
      src[i * ch] = v;
      src[i * ch + 1] = v;
    }

    final enc = await MiniAVTools.createAudioEncoder(
      const AudioEncoderConfig(
        codec: AudioCodec.opus,
        sampleRate: sr,
        channels: ch,
        bitrateBps: 96000,
      ),
      preference: BackendPreference.excluded({'ffmpeg'}), // prove FFmpeg-free
    );
    expect(enc.backendName, 'opus');

    final packets = <EncodedPacket>[
      ...await enc.encode(
        pcm: Uint8List.view(src.buffer),
        format: MiniAVAudioFormat.f32,
        frameCount: frames,
        ptsUs: 0,
      ),
      ...await enc.flush(),
    ];
    final head = enc.platform.extraData;
    await enc.close();

    expect(packets.length, inInclusiveRange(48, 52)); // ~50 frames
    expect(head, isNotNull);
    expect(head!.bytes.sublist(0, 8), 'OpusHead'.codeUnits);
    expect(head.audioCodec, AudioCodec.opus);

    // Decode the packets back with the first-party libopus decoder.
    final dec = await OpusAudioDecoder.open(
      const AudioDecoderConfig(
        codec: AudioCodec.opus,
        sampleRate: sr,
        channels: ch,
      ),
    );
    expect(dec, isNotNull);
    var total = 0;
    var maxAbs = 0.0;
    for (final p in packets) {
      for (final d in await dec!.decode(p)) {
        total += d.frameCount;
        for (final s in d.samples) {
          final a = s.abs();
          if (a > maxAbs) maxAbs = a;
        }
      }
    }
    await dec!.close();

    // Opus is lossy, but the tone must survive: ~all frames back + audible.
    expect(total, greaterThan((frames * 0.9).round()));
    expect(maxAbs, greaterThan(0.1));
    expect(maxAbs, lessThanOrEqualTo(1.0));
  });
}
