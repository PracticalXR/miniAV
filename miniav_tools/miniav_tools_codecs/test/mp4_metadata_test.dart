/// P3.2 container-metadata correctness on real encoder output:
///   - rotation: the tkhd display matrix of a phone-style rotated MP4 surfaces
///     as VideoTrackInfo.rotationDegrees (90° clockwise here).
///   - B-frames: ctts is realized into pts != dts, and packets come out in
///     DECODE (dts) order — the contract libavcodec needs to reorder correctly.
///
/// Fixtures are ffmpeg-CLI-generated (see test/assets/README in the playbook):
///   ffmpeg -f lavfi -i testsrc=duration=1:size=64x48:rate=10 \
///     -c:v libx264 -pix_fmt yuv420p -bf 0 plain.mp4
///   ffmpeg -display_rotation -90 -i plain.mp4 -c copy rot90.mp4
///   ffmpeg -f lavfi -i testsrc=... -c:v libx264 -bf 2 -g 10 bframes.mp4
/// Tests skip cleanly when a fixture is absent (fresh checkout without the
/// ffmpeg CLI); CI generates them with apt/choco ffmpeg.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

Uint8List? _fixture(String name) {
  final f = File('test/assets/$name');
  return f.existsSync() ? f.readAsBytesSync() : null;
}

void main() {
  test('tkhd display matrix → rotationDegrees == 90 (clockwise)', () async {
    final bytes = _fixture('rot90.mp4');
    if (bytes == null) {
      markTestSkipped('rot90.mp4 fixture absent (generate with ffmpeg CLI)');
      return;
    }
    final dm = Mp4Demuxer.open(bytes);
    final v = dm.tracks.whereType<VideoTrackInfo>().single;
    expect(v.rotationDegrees, 90);
    await dm.close();
  });

  test('un-rotated MP4 reports rotationDegrees == 0', () async {
    final bytes = _fixture('bframes.mp4');
    if (bytes == null) {
      markTestSkipped('bframes.mp4 fixture absent');
      return;
    }
    final dm = Mp4Demuxer.open(bytes);
    final v = dm.tracks.whereType<VideoTrackInfo>().single;
    expect(v.rotationDegrees, 0);
    await dm.close();
  });

  test('B-frame MP4: ctts realized (pts != dts) + packets in dts order',
      () async {
    final bytes = _fixture('bframes.mp4');
    if (bytes == null) {
      markTestSkipped('bframes.mp4 fixture absent');
      return;
    }
    final dm = Mp4Demuxer.open(bytes);
    final pts = <int>[];
    final dts = <int>[];
    for (var p = await dm.readPacket(); p != null; p = await dm.readPacket()) {
      pts.add(p.ptsUs);
      dts.add(p.dtsUs);
    }
    await dm.close();
    expect(pts.length, greaterThan(5));
    // B-frames exist -> at least one packet where presentation is delayed
    // relative to decode order.
    expect(
      Iterable<int>.generate(pts.length).any((i) => pts[i] != dts[i]),
      isTrue,
      reason: 'expected pts != dts somewhere (encoder used -bf 2)',
    );
    // Decode order: dts strictly increases packet-to-packet...
    for (var i = 1; i < dts.length; i++) {
      expect(dts[i], greaterThan(dts[i - 1]),
          reason: 'dts must be monotonic (decode order) at packet $i');
    }
    // ...while pts does NOT (that's what makes it a real B-frame stream).
    expect(
      Iterable<int>.generate(pts.length - 1).any((i) => pts[i + 1] < pts[i]),
      isTrue,
      reason: 'pts should reorder across B-frames',
    );
  });
}
