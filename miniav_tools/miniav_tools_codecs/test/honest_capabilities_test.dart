// P0.2: backends must not advertise capabilities they then throw/return-null
// on. Before this, FfmpegBackend.supportsDecode returned true for EVERY codec
// while its decoder map (_videoCodecToAvId) has no prores entry — so a
// capability-ranking negotiator would select FFmpeg for prores and crash with a
// CodecInitException at open. Now the advertised decode set is honest, so
// prores decode fails cleanly as "no backend" instead.
@TestOn('vm')
library;

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show FfmpegBackend, registerFfmpegBackend;
import 'package:test/test.dart';

void main() {
  test('FfmpegBackend advertises decode only for codecs it maps (no prores)',
      () {
    final b = FfmpegBackend();
    for (final c in const [
      VideoCodec.h264,
      VideoCodec.hevc,
      VideoCodec.mjpeg,
      VideoCodec.vp8,
      VideoCodec.vp9,
      VideoCodec.av1,
    ]) {
      expect(b.supportsDecode(c), isTrue, reason: '$c should be decodable');
    }
    expect(
      b.supportsDecode(VideoCodec.prores),
      isFalse,
      reason: 'no prores decoder path exists — must not advertise it',
    );
  });

  test('negotiating prores decode fails cleanly (NoBackend, not a crash)',
      () async {
    registerFfmpegBackend();
    await expectLater(
      MiniAVTools.createDecoder(const DecoderConfig(codec: VideoCodec.prores)),
      throwsA(isA<NoBackendForCodecException>()),
    );
  });
}
