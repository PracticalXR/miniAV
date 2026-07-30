// The MSE byte-stream probe: incremental ISO-BMFF parsing on arbitrary chunk
// boundaries, fragmentation detection (mvex), and codec-string derivation.
// This is the logic that decides live-fMP4-streaming vs collect-and-blob vs
// error, so it must be right on partial and odd-split inputs.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/src/mse/mp4_init_scan.dart';

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff,
    ...type.codeUnits,
    ...payload,
  ]);
}

Uint8List _cat(List<Uint8List> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

// avcC box content: version=1, profile=0x64, compat=0x00, level=0x28.
Uint8List get _avcC => _box('avcC', [1, 0x64, 0x00, 0x28, 0xff, 0xe1]);
Uint8List get _mp4a => _box('mp4a', List.filled(28, 0));
Uint8List get _mvex => _box('mvex', _box('trex', List.filled(24, 0)));

Uint8List _fmp4Init({bool fragmented = true, bool withAudio = true}) {
  final moovKids = <Uint8List>[
    _box('mvhd', List.filled(100, 0)),
    _box('trak', _cat([_avcC])),
    if (withAudio) _box('trak', _cat([_mp4a])),
    if (fragmented) _mvex,
  ];
  return _cat([
    _box('ftyp', 'isom'.codeUnits + [0, 0, 0, 1] + 'isomiso5'.codeUnits),
    _box('moov', _cat(moovKids)),
  ]);
}

void main() {
  test('whole init segment in one chunk: fragmented + codec string', () {
    final probe = Mp4InitProbe();
    final done = probe.add(_fmp4Init());
    expect(done, isTrue);
    expect(probe.isIsoBmff, isTrue);
    expect(probe.moovComplete, isTrue);
    expect(probe.fragmented, isTrue);
    expect(probe.mimeCodecs, 'video/mp4; codecs="avc1.640028,mp4a.40.2"');
  });

  test('byte-at-a-time chunking reaches the same result', () {
    final init = _fmp4Init();
    final probe = Mp4InitProbe();
    var done = false;
    for (final b in init) {
      done = probe.add([b]);
    }
    expect(done, isTrue);
    expect(probe.fragmented, isTrue);
    expect(probe.mimeCodecs, 'video/mp4; codecs="avc1.640028,mp4a.40.2"');
    expect(probe.initSegmentEnd, init.length);
  });

  test('incomplete moov stays pending', () {
    final init = _fmp4Init();
    final probe = Mp4InitProbe();
    expect(probe.add(init.sublist(0, init.length - 4)), isFalse);
    expect(probe.moovComplete, isFalse);
    expect(probe.add(init.sublist(init.length - 4)), isTrue);
  });

  test('plain (unfragmented) MP4: moov complete, fragmented=false', () {
    final probe = Mp4InitProbe();
    probe.add(_fmp4Init(fragmented: false));
    expect(probe.moovComplete, isTrue);
    expect(probe.fragmented, isFalse);
  });

  test('video-only derives video/mp4 with just avc1', () {
    final probe = Mp4InitProbe();
    probe.add(_fmp4Init(withAudio: false));
    expect(probe.mimeCodecs, 'video/mp4; codecs="avc1.640028"');
  });

  test('media after moov does not confuse the scan', () {
    final probe = Mp4InitProbe();
    final init = _fmp4Init();
    final withMedia = _cat([
      init,
      _box('moof', List.filled(32, 0)),
      _box('mdat', List.filled(64, 0xAB)),
    ]);
    probe.add(withMedia);
    expect(probe.moovComplete, isTrue);
    expect(probe.initSegmentEnd, init.length);
    expect(probe.bufferedLength, withMedia.length);
  });

  test('non-ISO-BMFF input is identified for fallback', () {
    final probe = Mp4InitProbe();
    probe.add(Uint8List.fromList(List.filled(64, 0x42)));
    expect(probe.isIsoBmff, isFalse);
    expect(probe.moovComplete, isFalse);
  });

  test('isIsoBmff is null until 8 bytes arrive', () {
    final probe = Mp4InitProbe();
    probe.add([0, 0]);
    expect(probe.isIsoBmff, isNull);
  });
}
