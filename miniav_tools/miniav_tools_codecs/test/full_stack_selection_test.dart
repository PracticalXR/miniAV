// Proves the WHOLE first-party audio + container stack is selectable over
// FFmpeg. Registers the EXACT set miniav_player's backend_register_native.dart
// registers (MF + Opus + PCM + framing + FFmpeg) and checks the negotiator
// routes every first-party codec/container to its first-party backend — both by
// default and with FFmpeg explicitly excluded.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show registerFfmpegBackend;
import 'package:test/test.dart';

/// Build a tiny valid Ogg/Opus stream (header pages + one dummy audio packet).
Future<Uint8List> _oggBytes() async {
  final mux = OggMuxer.open(MuxerConfig(
    container: Container.ogg,
    output: MuxerOutput.bytes(),
    tracks: const [
      AudioTrackInfo(codec: AudioCodec.opus, sampleRate: 48000, channels: 2),
    ],
  ));
  await mux.writeHeader();
  await mux.writePacket(
    EncodedPacket(data: Uint8List.fromList([0xFC, 1, 2, 3]), ptsUs: 0, dtsUs: 0),
  );
  await mux.finish();
  return Uint8List.fromList(mux.getBytes()!);
}

Future<Uint8List> _wavBytes() async {
  final mux = WavMuxer.open(MuxerConfig(
    container: Container.wav,
    output: MuxerOutput.bytes(),
    tracks: const [
      AudioTrackInfo(codec: AudioCodec.pcmS16le, sampleRate: 48000, channels: 2),
    ],
  ));
  await mux.writeHeader();
  await mux.writePacket(
    EncodedPacket(data: Uint8List(64), ptsUs: 0, dtsUs: 0),
  );
  await mux.finish();
  return Uint8List.fromList(mux.getBytes()!);
}

void main() {
  // EXACTLY the player's registration order.
  setUpAll(() {
    registerMfDecodeBackend();
    registerOpusBackend();
    registerPcmBackend();
    registerContainerFramingBackend();
    registerFfmpegBackend();
  });

  final excl = BackendPreference.excluded({'ffmpeg'});

  group('audio codecs route first-party', () {
    test('Opus decode + encode → opus', () async {
      final d = await MiniAVTools.createAudioDecoder(
        const AudioDecoderConfig(codec: AudioCodec.opus),
        preference: excl,
      );
      expect(d.backendName, 'opus');
      await d.close();

      final e = await MiniAVTools.createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
          bitrateBps: 96000,
        ),
        preference: excl,
      );
      expect(e.backendName, 'opus');
      await e.close();
    });

    test('PCM decode + encode → pcm (both default and ffmpeg-excluded)',
        () async {
      for (final pref in [BackendPreference.auto, excl]) {
        final d = await MiniAVTools.createAudioDecoder(
          const AudioDecoderConfig(
            codec: AudioCodec.pcmS16le,
            sampleRate: 48000,
            channels: 2,
          ),
          preference: pref,
        );
        expect(d.backendName, 'pcm');
        await d.close();
      }
      final e = await MiniAVTools.createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.pcmF32le,
          sampleRate: 48000,
          channels: 2,
          bitrateBps: 0,
        ),
      );
      expect(e.backendName, 'pcm');
      await e.close();
    });
  });

  group('containers route first-party', () {
    test('Ogg demux → container_framing (default + excluded)', () async {
      final ogg = await _oggBytes();
      for (final pref in [BackendPreference.auto, excl]) {
        final dm = await MiniAVTools.createDemuxer(
          DemuxerConfig(
            container: Container.ogg,
            input: DemuxerInput.bytes(ogg),
          ),
          preference: pref,
        );
        expect(dm.backendName, 'container_framing');
        final t = dm.tracks.single as AudioTrackInfo;
        expect(t.codec, AudioCodec.opus);
        await dm.close();
      }
    });

    test('WAV demux → container_framing', () async {
      final wav = await _wavBytes();
      final dm = await MiniAVTools.createDemuxer(
        DemuxerConfig(
          container: Container.wav,
          input: DemuxerInput.bytes(wav),
        ),
        preference: excl,
      );
      expect(dm.backendName, 'container_framing');
      await dm.close();
    });

    test('Ogg mux → container_framing', () async {
      final m = await MiniAVTools.createMuxer(
        MuxerConfig(
          container: Container.ogg,
          output: MuxerOutput.bytes(),
          tracks: const [
            AudioTrackInfo(
              codec: AudioCodec.opus,
              sampleRate: 48000,
              channels: 2,
            ),
          ],
        ),
        preference: excl,
      );
      expect(m.backendName, 'container_framing');
      await m.close();
    });

    test('MP4 demux + mux are both first-party (P2.3)', () async {
      final fw = ContainerFramingBackend();
      expect(fw.supportsDemux(Container.mp4), isTrue); // Mp4Demuxer
      expect(fw.supportsMux(Container.mp4), isTrue); // Mp4Muxer
    });
  });
}
