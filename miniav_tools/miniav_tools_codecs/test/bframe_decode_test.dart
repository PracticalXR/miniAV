/// P3.2 B-frame reorder E2E: a real B-frame MP4 (libx264 -bf 2) goes
/// Mp4Demuxer (packets in dts order, pts reordered) → FFmpeg SW decode →
/// decoded frames come out in MONOTONIC presentation order. This is the
/// whole B-frame contract for the player: the demuxer feeds decode order,
/// libavcodec does the reordering, and the scheduler can trust frame pts.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show FfmpegBackend, ensureFFmpegLoaded;
import 'package:test/test.dart';

void main() {
  test('B-frame MP4 decodes to monotonically increasing pts', () async {
    final f = File('test/assets/bframes.mp4');
    if (!f.existsSync()) {
      markTestSkipped('bframes.mp4 fixture absent (generate with ffmpeg CLI)');
      return;
    }
    if (!await ensureFFmpegLoaded()) {
      markTestSkipped('FFmpeg unavailable');
      return;
    }

    final dm = Mp4Demuxer.open(Uint8List.fromList(f.readAsBytesSync()));
    final v = dm.tracks.whereType<VideoTrackInfo>().single;
    final dec = await FfmpegBackend().createDecoder(
      DecoderConfig(
        codec: v.codec,
        extraData: v.extraData?.bytes,
        backendOptions: const {'sw_isolate': '0'},
      ),
    );
    expect(dec, isNotNull, reason: 'ffmpeg SW decoder should open');

    var packets = 0;
    final outPts = <int>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      packets++;
      final frame = await dec!.decode(p);
      if (frame != null) {
        outPts.add(frame.ptsUs);
        frame.close();
      }
    }
    for (final frame in await dec!.flush()) {
      outPts.add(frame.ptsUs);
      frame.close();
    }
    await dec.close();
    await dm.close();

    expect(packets, greaterThan(5));
    expect(outPts.length, packets,
        reason: 'every packet should decode to a frame after flush');
    for (var i = 1; i < outPts.length; i++) {
      expect(outPts[i], greaterThan(outPts[i - 1]),
          reason: 'decoded pts must be presentation-ordered at frame $i '
              '(libavcodec reorders B-frames internally)');
    }
  });
}
