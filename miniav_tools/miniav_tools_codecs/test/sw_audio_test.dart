// P4.2: first-party SW audio decode — MP3 (dr_mp3), FLAC (dr_flac), Vorbis
// (stb_vorbis). Decodes real fixtures (ffmpeg-encoded 0.25s 440Hz stereo tones
// under test/assets/) to audible 48k stereo PCM, all FFmpeg-free.
@TestOn('vm')
library;

import 'dart:io';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerSwAudioBackend, SwAudioDecoder;
import 'package:test/test.dart';

Future<DecodedAudio> _decodeFile(AudioCodec codec, String path) async {
  final bytes = await File(path).readAsBytes();
  final dec = await SwAudioDecoder.open(AudioDecoderConfig(codec: codec));
  expect(dec, isNotNull, reason: '$codec should open');
  await dec!.decode(EncodedPacket(data: bytes, ptsUs: 0, dtsUs: 0));
  final out = await dec.flush();
  await dec.close();
  expect(out, isNotEmpty, reason: '$codec should decode to PCM');
  return out.first;
}

void main() {
  setUpAll(registerSwAudioBackend);

  final cases = <(AudioCodec, String, String)>[
    (AudioCodec.mp3, 'test/assets/tone.mp3', 'MP3'),
    (AudioCodec.flac, 'test/assets/tone.flac', 'FLAC'),
    (AudioCodec.vorbis, 'test/assets/tone.ogg', 'Vorbis'),
  ];

  for (final (codec, path, name) in cases) {
    test('$name decodes FFmpeg-free to audible 48k stereo PCM', () async {
      final d = await _decodeFile(codec, path);
      expect(d.sampleRate, 48000);
      expect(d.channels, 2);
      expect(d.frameCount, greaterThan(8000)); // ~0.25 s @ 48 kHz = 12000
      var maxAbs = 0.0;
      for (final s in d.samples) {
        final a = s.abs();
        if (a > maxAbs) maxAbs = a;
      }
      // The fixtures are a 440 Hz tone at ~-21 dB (ffmpeg sine default ≈ 0.088
      // peak, verified via volumedetect) — clearly non-silent, well below clip.
      expect(maxAbs, greaterThan(0.05), reason: 'a tone, not silence');
      expect(maxAbs, lessThanOrEqualTo(1.01));
    });
  }

  test('facade picks sw_audio for MP3 with FFmpeg excluded', () async {
    final dec = await MiniAVTools.createAudioDecoder(
      const AudioDecoderConfig(codec: AudioCodec.mp3),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(dec.backendName, 'sw_audio');
    await dec.close();
  });
}
