// Opus pre-skip (RFC 7845 encoder-delay priming) + the demuxer→decoder
// AudioDecoderConfig.fromTrack handoff.
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

Uint8List _opusHead(int channels, int sampleRate, int preSkip) {
  final b = Uint8List(19);
  b.setRange(0, 8, 'OpusHead'.codeUnits);
  b[8] = 1;
  b[9] = channels;
  final bd = ByteData.sublistView(b);
  bd.setUint16(10, preSkip, Endian.little);
  bd.setUint32(12, sampleRate, Endian.little);
  return b;
}

Future<List<EncodedPacket>> _encodeTone() async {
  const sr = 48000, ch = 2, frames = 48000;
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
  );
  final pkts = <EncodedPacket>[
    ...await enc.encode(
      pcm: Uint8List.view(src.buffer),
      format: MiniAVAudioFormat.f32,
      frameCount: frames,
      ptsUs: 0,
    ),
    ...await enc.flush(),
  ];
  await enc.close();
  return pkts;
}

Future<int> _decodeCount(List<EncodedPacket> pkts, Uint8List? head) async {
  final dec = await OpusAudioDecoder.open(AudioDecoderConfig(
    codec: AudioCodec.opus,
    sampleRate: 48000,
    channels: 2,
    extraData: head,
  ));
  var total = 0;
  for (final p in pkts) {
    for (final d in await dec!.decode(p)) {
      total += d.frameCount;
    }
  }
  await dec!.close();
  return total;
}

void main() {
  setUpAll(registerOpusBackend);

  test('OpusHead pre-skip trims exactly that many frames from the front',
      () async {
    final pkts = await _encodeTone();
    const preSkip = 312;
    final baseline = await _decodeCount(pkts, null); // no pre-skip
    final trimmed = await _decodeCount(pkts, _opusHead(2, 48000, preSkip));
    expect(baseline - trimmed, preSkip,
        reason: 'exactly $preSkip priming frames should be discarded');
  });

  test('AudioDecoderConfig.fromTrack drives demux→decode with no manual config',
      () async {
    // Record Opus → Ogg, then read the file back and decode straight from the
    // demuxed track (no hand-built AudioDecoderConfig).
    final pkts = await _encodeTone();
    final mux = OggMuxer.open(MuxerConfig(
      container: Container.ogg,
      output: MuxerOutput.bytes(),
      tracks: [
        AudioTrackInfo(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
          extraData: CodecExtraData.audio(
            AudioCodec.opus,
            _opusHead(2, 48000, 0),
          ),
        ),
      ],
    ));
    await mux.writeHeader();
    for (final p in pkts) {
      await mux.writePacket(p);
    }
    await mux.finish();
    final ogg = Uint8List.fromList(mux.getBytes()!);

    final dm = OggDemuxer.open(ogg);
    final track = dm.tracks.single as AudioTrackInfo;

    // The one-liner handoff: track → config → decoder.
    final dec = await MiniAVTools.createAudioDecoder(
      AudioDecoderConfig.fromTrack(track),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(dec.backendName, 'opus');

    var total = 0;
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      for (final d in await dec.decode(p)) {
        total += d.frameCount;
      }
    }
    await dec.close();
    expect(total, greaterThan((48000 * 0.9).round()));
  });
}
