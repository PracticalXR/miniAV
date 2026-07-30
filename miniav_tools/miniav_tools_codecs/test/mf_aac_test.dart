// P2.2: first-party OS AAC decode + encode via Media Foundation (Windows).
// PCM → AAC → PCM round-trip, FFmpeg-free. Skips where no AAC MFT / non-Windows.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show MfAacEncoder, MfAacDecoder, registerAacBackend;
import 'package:miniav_tools_codecs/src/codecs_native.dart'
    show mfaacEncHasMft, mfaacDecHasMft;
import 'package:test/test.dart';

void main() {
  var haveAac = false;
  setUpAll(() {
    if (Platform.isWindows) {
      try {
        haveAac = mfaacEncHasMft() != 0 && mfaacDecHasMft() != 0;
      } catch (_) {}
    }
    registerAacBackend();
  });

  test('AAC encode→decode round-trip (MF, FFmpeg-free)', () async {
    if (!Platform.isWindows || !haveAac) {
      markTestSkipped('MF AAC MFT not available');
      return;
    }
    const sr = 48000, ch = 2, frames = 48000; // 1 second
    final src = Float32List(frames * ch);
    for (var i = 0; i < frames; i++) {
      final v = 0.3 * math.sin(2 * math.pi * 440 * i / sr);
      src[i * ch] = v;
      src[i * ch + 1] = v;
    }

    final enc = await MfAacEncoder.open(const AudioEncoderConfig(
      codec: AudioCodec.aac,
      sampleRate: sr,
      channels: ch,
      bitrateBps: 128000,
    ));
    expect(enc, isNotNull);
    final packets = <EncodedPacket>[
      ...await enc!.encode(
        pcm: Uint8List.view(src.buffer),
        format: MiniAVAudioFormat.f32,
        frameCount: frames,
        ptsUs: 0,
      ),
      ...await enc.flush(),
    ];
    final asc = enc.extraData;
    await enc.close();
    expect(packets, isNotEmpty, reason: 'encoder produced AAC access units');
    expect(asc, isNotNull, reason: 'encoder exposes an AudioSpecificConfig');

    final dec = await MfAacDecoder.open(AudioDecoderConfig(
      codec: AudioCodec.aac,
      sampleRate: sr,
      channels: ch,
      extraData: asc!.bytes,
    ));
    expect(dec, isNotNull);
    final d = dec!;
    var total = 0;
    var maxAbs = 0.0;
    void take(Iterable<DecodedAudio> chunks) {
      for (final c in chunks) {
        total += c.frameCount;
        for (final s in c.samples) {
          final a = s.abs();
          if (a > maxAbs) maxAbs = a;
        }
      }
    }

    for (final p in packets) {
      take(await d.decode(p));
    }
    take(await d.flush());
    await d.close();

    // AAC is lossy + adds encoder-delay priming, so exact counts vary; the tone
    // must survive and roughly all the audio must come back.
    expect(total, greaterThan(40000), reason: '~1 s of PCM back');
    expect(maxAbs, greaterThan(0.1), reason: 'the 440 Hz tone survives');
    expect(maxAbs, lessThanOrEqualTo(1.01));
  });

  test('facade prefers mf_aac for AAC encode with FFmpeg excluded', () async {
    if (!Platform.isWindows || !haveAac) {
      markTestSkipped('MF AAC MFT not available');
      return;
    }
    final e = await MiniAVTools.createAudioEncoder(
      const AudioEncoderConfig(
        codec: AudioCodec.aac,
        sampleRate: 48000,
        channels: 2,
        bitrateBps: 128000,
      ),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(e.backendName, 'mf_aac');
    await e.close();
  });
}
