// P1.3: pure-Dart WAV + Ogg + ADTS framing. Proves .wav / .opus files can be
// written and read with ZERO libavformat, and that malformed input fails
// gracefully (no crash).
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

MuxerConfig _mux(Container c, AudioTrackInfo t) =>
    MuxerConfig(container: c, output: MuxerOutput.bytes(), tracks: [t]);

Future<List<EncodedPacket>> _readAll(PlatformDemuxer d) async {
  final out = <EncodedPacket>[];
  for (var p = await d.readPacket(); p != null; p = await d.readPacket()) {
    out.add(p);
  }
  return out;
}

void main() {
  group('WAV (RIFF)', () {
    test('PCM s16le round-trips mux → demux byte-exactly', () async {
      final track = const AudioTrackInfo(
        codec: AudioCodec.pcmS16le,
        sampleRate: 48000,
        channels: 2,
      );
      final pcm = Uint8List(4800 * 2 * 2);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (i * 7) & 0xFF;
      }

      final mux = WavMuxer.open(_mux(Container.wav, track));
      await mux.writeHeader();
      await mux.writePacket(EncodedPacket(data: pcm, ptsUs: 0, dtsUs: 0));
      await mux.finish();
      final bytes = Uint8List.fromList(mux.getBytes()!);

      final dm = WavDemuxer.open(bytes);
      final t = dm.tracks.single as AudioTrackInfo;
      expect(t.codec, AudioCodec.pcmS16le);
      expect(t.sampleRate, 48000);
      expect(t.channels, 2);
      expect(dm.durationUs, closeTo(4800 * 1000000 ~/ 48000, 1));

      final got = BytesBuilder();
      for (final p in await _readAll(dm)) {
        got.add(p.data);
      }
      expect(got.toBytes(), pcm);
    });
  });

  group('Ogg (Opus)', () {
    setUpAll(registerOpusBackend);

    test('Opus record → Ogg → read → decode is fully FFmpeg-free', () async {
      const sr = 48000, ch = 2, frames = 48000; // 1 s = 50 × 20 ms frames
      final src = Float32List(frames * ch);
      for (var i = 0; i < frames; i++) {
        final v = 0.3 * math.sin(2 * math.pi * 440 * i / sr);
        src[i * ch] = v;
        src[i * ch + 1] = v;
      }

      // Encode (first-party libopus, FFmpeg excluded).
      final enc = await MiniAVTools.createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: sr,
          channels: ch,
          bitrateBps: 96000,
        ),
        preference: BackendPreference.excluded({'ffmpeg'}),
      );
      final opusPkts = <EncodedPacket>[
        ...await enc.encode(
          pcm: Uint8List.view(src.buffer),
          format: MiniAVAudioFormat.f32,
          frameCount: frames,
          ptsUs: 0,
        ),
        ...await enc.flush(),
      ];
      final head = enc.platform.extraData!;
      await enc.close();

      // Mux → Ogg bytes.
      final mux = OggMuxer.open(_mux(
        Container.ogg,
        AudioTrackInfo(
          codec: AudioCodec.opus,
          sampleRate: sr,
          channels: ch,
          extraData: head,
        ),
      ));
      await mux.writeHeader();
      for (final p in opusPkts) {
        await mux.writePacket(p);
      }
      await mux.finish();
      final ogg = Uint8List.fromList(mux.getBytes()!);
      expect(ogg.sublist(0, 4), 'OggS'.codeUnits);

      // Demux — must recover EXACTLY the audio packets (headers skipped).
      final dm = OggDemuxer.open(ogg);
      final t = dm.tracks.single as AudioTrackInfo;
      expect(t.codec, AudioCodec.opus);
      expect(t.channels, 2);
      expect(t.extraData!.bytes.sublist(0, 8), 'OpusHead'.codeUnits);

      final demuxed = await _readAll(dm);
      expect(demuxed.length, opusPkts.length,
          reason: 'de-lacing + 2 header-packet skip must be exact');
      for (var i = 0; i < demuxed.length; i++) {
        expect(demuxed[i].data, opusPkts[i].data);
      }

      // Decode back — audible.
      final dec = await OpusAudioDecoder.open(const AudioDecoderConfig(
        codec: AudioCodec.opus,
        sampleRate: sr,
        channels: ch,
      ));
      var total = 0;
      var maxAbs = 0.0;
      for (final p in demuxed) {
        for (final d in await dec!.decode(p)) {
          total += d.frameCount;
          for (final s in d.samples) {
            final a = s.abs();
            if (a > maxAbs) maxAbs = a;
          }
        }
      }
      await dec!.close();
      expect(total, greaterThan((frames * 0.9).round()));
      expect(maxAbs, greaterThan(0.1));
    });

    test('facade createDemuxer picks the first-party framing backend', () async {
      registerContainerFramingBackend();
      // Minimal valid Ogg: OpusHead page + one empty EOS page via the muxer.
      final mux = OggMuxer.open(_mux(
        Container.ogg,
        const AudioTrackInfo(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
        ),
      ));
      await mux.writeHeader();
      await mux.writePacket(EncodedPacket(
        data: Uint8List.fromList([0xFC, 1, 2, 3]),
        ptsUs: 0,
        dtsUs: 0,
      ));
      await mux.finish();
      final ogg = Uint8List.fromList(mux.getBytes()!);

      final dm = await MiniAVTools.createDemuxer(
        DemuxerConfig(
          container: Container.ogg,
          input: DemuxerInput.bytes(ogg),
        ),
        preference: BackendPreference.excluded({'ffmpeg'}),
      );
      expect(dm.backendName, 'container_framing');
      expect(dm.capability?.container, Container.ogg);
      await dm.close();
    });
  });

  group('ADTS (AAC)', () {
    test('AAC payloads round-trip mux → demux with a valid ASC', () async {
      const track = AudioTrackInfo(
        codec: AudioCodec.aac,
        sampleRate: 44100,
        channels: 2,
      );
      final payloads = <Uint8List>[
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList(List.generate(300, (i) => i & 0xFF)),
        Uint8List.fromList([9, 9]),
      ];

      final mux = AdtsMuxer.open(_mux(Container.adts, track));
      await mux.writeHeader();
      for (final p in payloads) {
        await mux.writePacket(EncodedPacket(data: p, ptsUs: 0, dtsUs: 0));
      }
      final adts = Uint8List.fromList(mux.getBytes()!);

      final dm = AdtsDemuxer.open(adts);
      final t = dm.tracks.single as AudioTrackInfo;
      expect(t.codec, AudioCodec.aac);
      expect(t.sampleRate, 44100);
      expect(t.channels, 2);
      expect(t.extraData, isNotNull); // AudioSpecificConfig

      final got = await _readAll(dm);
      expect(got.length, payloads.length);
      for (var i = 0; i < payloads.length; i++) {
        expect(got[i].data, payloads[i]);
      }
    });
  });

  group('malformed input fails gracefully (no crash)', () {
    test('WAV', () {
      expect(() => WavDemuxer.open(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<CodecInitException>()));
      expect(() => WavDemuxer.open(Uint8List(64)),
          throwsA(isA<CodecInitException>()));
    });
    test('Ogg', () {
      expect(() => OggDemuxer.open(Uint8List(50)),
          throwsA(isA<CodecInitException>()));
      // "OggS" header but a segment table claiming more than the buffer holds.
      final bad = Uint8List(28)..setRange(0, 4, 'OggS'.codeUnits);
      bad[26] = 200; // 200 segments, none present
      expect(() => OggDemuxer.open(bad),
          throwsA(isA<CodecInitException>()));
    });
    test('ADTS', () {
      expect(() => AdtsDemuxer.open(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0])),
          throwsA(isA<CodecInitException>()));
    });
  });
}
