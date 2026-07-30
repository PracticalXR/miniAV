// P1.2: pure-Dart raw-PCM decode+encode (pcmS16le / pcmF32le) through the
// facade — proves PCM has a real, FFmpeg-free path (it previously had NONE:
// FFmpeg's audio codec map threw on PCM).
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerPcmBackend;
import 'package:test/test.dart';

Float32List _sine(int frames, int channels) {
  final s = Float32List(frames * channels);
  for (var i = 0; i < frames; i++) {
    final v = 0.5 * math.sin(2 * math.pi * 1000 * i / 48000);
    for (var c = 0; c < channels; c++) {
      s[i * channels + c] = v;
    }
  }
  return s;
}

void main() {
  setUpAll(registerPcmBackend);

  const frames = 4800;
  const channels = 2;

  test('pcmF32le round-trips byte-exactly through the facade', () async {
    final src = _sine(frames, channels);

    final enc = await MiniAVTools.createAudioEncoder(
      const AudioEncoderConfig(
        codec: AudioCodec.pcmF32le,
        sampleRate: 48000,
        channels: channels,
        bitrateBps: 0,
      ),
    );
    expect(enc.backendName, 'pcm');
    final pkts = await enc.encode(
      pcm: Uint8List.view(src.buffer),
      format: MiniAVAudioFormat.f32,
      frameCount: frames,
      ptsUs: 0,
    );
    await enc.close();
    expect(pkts, hasLength(1));

    final dec = await MiniAVTools.createAudioDecoder(
      const AudioDecoderConfig(
        codec: AudioCodec.pcmF32le,
        sampleRate: 48000,
        channels: channels,
      ),
    );
    expect(dec.backendName, 'pcm');
    final out = await dec.decode(pkts.first);
    await dec.close();

    expect(out, hasLength(1));
    final d = out.first;
    expect(d.frameCount, frames);
    expect(d.channels, channels);
    expect(d.sampleRate, 48000);
    for (var i = 0; i < src.length; i++) {
      expect(d.samples[i], closeTo(src[i], 1e-6));
    }
  });

  test('pcmS16le round-trips within 16-bit quantization', () async {
    final src = _sine(frames, channels);

    final enc = await MiniAVTools.createAudioEncoder(
      const AudioEncoderConfig(
        codec: AudioCodec.pcmS16le,
        sampleRate: 48000,
        channels: channels,
        bitrateBps: 0,
      ),
    );
    final pkts = await enc.encode(
      pcm: Uint8List.view(src.buffer),
      format: MiniAVAudioFormat.f32,
      frameCount: frames,
      ptsUs: 123,
    );
    await enc.close();
    expect(pkts, hasLength(1));
    // s16 = 2 bytes/sample.
    expect(pkts.first.data.lengthInBytes, frames * channels * 2);
    expect(pkts.first.ptsUs, 123);

    final dec = await MiniAVTools.createAudioDecoder(
      const AudioDecoderConfig(
        codec: AudioCodec.pcmS16le,
        sampleRate: 48000,
        channels: channels,
      ),
    );
    final out = await dec.decode(pkts.first);
    await dec.close();

    final d = out.first;
    expect(d.frameCount, frames);
    for (var i = 0; i < src.length; i++) {
      // 16-bit quantization error is <= 1 LSB ~= 1/32768.
      expect(d.samples[i], closeTo(src[i], 1.0 / 32768.0));
    }
  });

  test('empty packet decodes to nothing (no crash)', () async {
    final dec = await MiniAVTools.createAudioDecoder(
      const AudioDecoderConfig(
        codec: AudioCodec.pcmF32le,
        sampleRate: 48000,
        channels: 2,
      ),
    );
    final out = await dec.decode(
      EncodedPacket(data: Uint8List(0), ptsUs: 0, dtsUs: 0),
    );
    await dec.close();
    expect(out, isEmpty);
  });
}
