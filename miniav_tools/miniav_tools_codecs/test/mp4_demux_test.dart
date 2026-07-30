// P2.3 (demux half): pure-Dart MP4 / ISO-BMFF demuxer. Round-trips the existing
// AV1 MP4 muxer's output (av01/av1C video + mp4a/esds AAC audio), recovering
// tracks, per-sample data, keyframe flags, monotonic pts, and codec extra-data
// — with zero libavformat. Malformed boxes fail gracefully.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

/// A throwaway av1C config record (the demuxer round-trips it as opaque bytes).
final _av1c = Uint8List.fromList([0x81, 0x00, 0x00, 0x00, 0xAA, 0xBB]);

Future<Uint8List> _muxAv1Aac(
  List<Uint8List> video,
  List<Uint8List> audio,
) async {
  final mux = Av1Mp4Muxer(MuxerConfig(
    container: Container.mp4,
    output: MuxerOutput.bytes(),
    tracks: [
      VideoTrackInfo(
        codec: VideoCodec.av1,
        width: 320,
        height: 240,
        frameRateNumerator: 25,
        frameRateDenominator: 1,
        extraData: CodecExtraData.video(VideoCodec.av1, _av1c),
      ),
      const AudioTrackInfo(
        codec: AudioCodec.aac,
        sampleRate: 48000,
        channels: 2,
      ),
    ],
  ));
  await mux.writeHeader();
  for (var i = 0; i < video.length; i++) {
    await mux.writePacket(EncodedPacket(
      data: video[i],
      ptsUs: i * 40000, // 25 fps
      dtsUs: i * 40000,
      isKeyframe: i == 0,
      trackIndex: 0,
    ));
  }
  for (var i = 0; i < audio.length; i++) {
    await mux.writePacket(EncodedPacket(
      data: audio[i],
      ptsUs: i * 21333,
      dtsUs: i * 21333,
      isKeyframe: true,
      trackIndex: 1,
    ));
  }
  await mux.finish();
  return Uint8List.fromList(mux.getBytes()!);
}

void main() {
  test('MP4 (av1 + aac) round-trips through Mp4Demuxer', () async {
    final video = [
      for (var i = 0; i < 5; i++)
        Uint8List.fromList(List.generate(20 + i, (j) => (i * 31 + j) & 0xFF)),
    ];
    final audio = [
      for (var i = 0; i < 8; i++)
        Uint8List.fromList(List.generate(6 + i, (j) => (i * 17 + j) & 0xFF)),
    ];
    final mp4 = await _muxAv1Aac(video, audio);
    expect(mp4.sublist(4, 8), 'ftyp'.codeUnits);

    final dm = Mp4Demuxer.open(mp4);
    expect(dm.tracks.length, 2);

    final vt = dm.tracks[0] as VideoTrackInfo;
    expect(vt.codec, VideoCodec.av1);
    expect(vt.width, 320);
    expect(vt.height, 240);
    expect(vt.extraData!.bytes, _av1c); // av1C round-trips exactly

    final at = dm.tracks[1] as AudioTrackInfo;
    expect(at.codec, AudioCodec.aac);
    expect(at.sampleRate, 48000);
    expect(at.channels, 2);
    expect(at.extraData, isNotNull); // ASC from esds

    // Collect packets per track (file order = all video then all audio).
    final gotV = <EncodedPacket>[];
    final gotA = <EncodedPacket>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      (p.trackIndex == 0 ? gotV : gotA).add(p);
    }
    await dm.close();

    expect(gotV.length, video.length);
    expect(gotA.length, audio.length);
    // Sample data + keyframe flags round-trip exactly.
    for (var i = 0; i < video.length; i++) {
      expect(gotV[i].data, video[i], reason: 'video sample $i');
      expect(gotV[i].isKeyframe, i == 0);
      if (i > 0) expect(gotV[i].ptsUs, greaterThan(gotV[i - 1].ptsUs));
    }
    expect(gotV.first.ptsUs, 0);
    for (var i = 0; i < audio.length; i++) {
      expect(gotA[i].data, audio[i], reason: 'audio sample $i');
    }
  });

  test('the facade picks Mp4Demuxer for Container.mp4 over FFmpeg', () async {
    registerContainerFramingBackend();
    final mp4 = await _muxAv1Aac(
      [Uint8List.fromList([1, 2, 3, 4])],
      [Uint8List.fromList([9, 9])],
    );
    final dm = await MiniAVTools.createDemuxer(
      DemuxerConfig(container: Container.mp4, input: DemuxerInput.bytes(mp4)),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(dm.backendName, 'container_framing');
    expect(dm.capability?.container, Container.mp4);
    expect(dm.tracks, isNotEmpty);
    await dm.close();
  });

  test('malformed MP4 fails gracefully (no crash)', () {
    // No moov box.
    final noMoov = Uint8List(16)
      ..setRange(4, 8, 'ftyp'.codeUnits)
      ..[3] = 16;
    expect(() => Mp4Demuxer.open(noMoov),
        throwsA(isA<CodecInitException>()));
    // A 'moov' whose declared size overruns the buffer → walk stops, no track.
    final badMoov = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x08, ...'ftyp'.codeUnits,
      0x7F, 0xFF, 0xFF, 0xFF, ...'moov'.codeUnits, // size way past the buffer
    ]);
    expect(() => Mp4Demuxer.open(badMoov),
        throwsA(isA<CodecInitException>()));
  });
}
