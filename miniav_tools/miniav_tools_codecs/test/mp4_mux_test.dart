// P2.3 (mux half): the general Mp4Muxer (H.264/HEVC/AV1 video + AAC/Opus audio).
// Round-trips through Mp4Demuxer — which also exercises the demuxer's avc1/avcC
// + mp4a/esds + Opus/dOps paths that the AV1-muxer round-trip didn't. FFmpeg-free.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

Future<Uint8List> _mux(List<TrackInfo> tracks,
    List<EncodedPacket> packets) async {
  final m = Mp4Muxer.open(MuxerConfig(
    container: Container.mp4,
    output: MuxerOutput.bytes(),
    tracks: tracks,
  ));
  await m.writeHeader();
  for (final p in packets) {
    await m.writePacket(p);
  }
  await m.finish();
  return Uint8List.fromList(m.getBytes()!);
}

List<Uint8List> _fakePackets(int count, int seed) => [
      for (var i = 0; i < count; i++)
        Uint8List.fromList(List.generate(8 + i, (j) => (seed + i * 13 + j) & 0xFF)),
    ];

void main() {
  test('H.264 + AAC round-trips mux → demux (avcC + esds→ASC)', () async {
    final avcC = Uint8List.fromList([1, 0x64, 0, 0x1f, 0xff, 0xe1]); // fake avcC
    final video = _fakePackets(4, 3);
    final audio = _fakePackets(6, 100);

    final mp4 = await _mux(
      [
        VideoTrackInfo(
          codec: VideoCodec.h264,
          width: 640,
          height: 360,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          extraData: CodecExtraData.video(VideoCodec.h264, avcC),
        ),
        const AudioTrackInfo(
          codec: AudioCodec.aac,
          sampleRate: 44100,
          channels: 2,
        ),
      ],
      [
        for (var i = 0; i < video.length; i++)
          EncodedPacket(
              data: video[i],
              ptsUs: i * 33333,
              dtsUs: i * 33333,
              isKeyframe: i == 0,
              trackIndex: 0),
        for (var i = 0; i < audio.length; i++)
          EncodedPacket(
              data: audio[i], ptsUs: i * 23219, dtsUs: i * 23219, trackIndex: 1),
      ],
    );

    final dm = Mp4Demuxer.open(mp4);
    expect(dm.tracks.length, 2);
    final vt = dm.tracks[0] as VideoTrackInfo;
    expect(vt.codec, VideoCodec.h264);
    expect(vt.width, 640);
    expect(vt.height, 360);
    expect(vt.extraData!.bytes, avcC);
    final at = dm.tracks[1] as AudioTrackInfo;
    expect(at.codec, AudioCodec.aac);
    expect(at.sampleRate, 44100);
    expect(at.channels, 2);
    expect(at.extraData, isNotNull);

    final gotV = <EncodedPacket>[];
    final gotA = <EncodedPacket>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      (p.trackIndex == 0 ? gotV : gotA).add(p);
    }
    await dm.close();
    expect(gotV.map((p) => p.data), video);
    expect(gotA.map((p) => p.data), audio);
    expect(gotV.first.isKeyframe, isTrue);
  });

  test('Opus-in-MP4 round-trips (Opus/dOps → OpusHead)', () async {
    final audio = _fakePackets(5, 7);
    final mp4 = await _mux(
      const [
        AudioTrackInfo(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
        ),
      ],
      [
        for (var i = 0; i < audio.length; i++)
          EncodedPacket(data: audio[i], ptsUs: i * 20000, dtsUs: i * 20000),
      ],
    );

    final dm = Mp4Demuxer.open(mp4);
    final at = dm.tracks.single as AudioTrackInfo;
    expect(at.codec, AudioCodec.opus);
    expect(at.channels, 2);
    // dOps → OpusHead reconstruction.
    expect(at.extraData!.bytes.sublist(0, 8), 'OpusHead'.codeUnits);
    expect(at.extraData!.bytes[9], 2); // channels

    final got = <Uint8List>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      got.add(p.data);
    }
    await dm.close();
    expect(got, audio);
  });

  test('facade picks Mp4Muxer for Container.mp4 mux over FFmpeg', () async {
    registerContainerFramingBackend();
    final m = await MiniAVTools.createMuxer(
      MuxerConfig(
        container: Container.mp4,
        output: MuxerOutput.bytes(),
        tracks: [
          VideoTrackInfo(
            codec: VideoCodec.h264,
            width: 320,
            height: 240,
            frameRateNumerator: 25,
            frameRateDenominator: 1,
            extraData:
                CodecExtraData.video(VideoCodec.h264, Uint8List.fromList([1, 2, 3])),
          ),
        ],
      ),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(m.backendName, 'container_framing');
    expect(m.capability?.container, Container.mp4);
    await m.close();
  });

  test('unsupported codec (VP9) is rejected → FFmpeg fallback', () {
    expect(
      () => Mp4Muxer.open(MuxerConfig(
        container: Container.mp4,
        output: MuxerOutput.bytes(),
        tracks: [
          VideoTrackInfo(
            codec: VideoCodec.vp9,
            width: 320,
            height: 240,
            frameRateNumerator: 25,
            frameRateDenominator: 1,
            extraData: CodecExtraData.video(VideoCodec.vp9, Uint8List.fromList([1])),
          ),
        ],
      )),
      throwsA(isA<CodecInitException>()),
    );
  });

  test('.m4a (audio-only MP4) round-trips + facade selects container_framing',
      () async {
    final payloads = [
      Uint8List.fromList([1, 2, 3, 4]),
      Uint8List.fromList([5, 6, 7]),
    ];
    final mux = Mp4Muxer.open(MuxerConfig(
      container: Container.m4a,
      output: MuxerOutput.bytes(),
      tracks: const [
        AudioTrackInfo(codec: AudioCodec.aac, sampleRate: 44100, channels: 2),
      ],
    ));
    await mux.writeHeader();
    for (var i = 0; i < payloads.length; i++) {
      await mux.writePacket(EncodedPacket(
          data: payloads[i], ptsUs: i * 23219, dtsUs: i * 23219, trackIndex: 0));
    }
    await mux.finish();

    final dm = Mp4Demuxer.open(Uint8List.fromList(mux.getBytes()!));
    expect((dm.tracks.single as AudioTrackInfo).codec, AudioCodec.aac);
    final got = <Uint8List>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      got.add(p.data);
    }
    await dm.close();
    expect(got, payloads);

    // The facade routes .m4a mux to the first-party framing backend.
    registerContainerFramingBackend();
    final m = await MiniAVTools.createMuxer(
      MuxerConfig(
        container: Container.m4a,
        output: MuxerOutput.bytes(),
        tracks: const [
          AudioTrackInfo(codec: AudioCodec.aac, sampleRate: 44100, channels: 2),
        ],
      ),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(m.backendName, 'container_framing');
    await m.close();
  });
}
