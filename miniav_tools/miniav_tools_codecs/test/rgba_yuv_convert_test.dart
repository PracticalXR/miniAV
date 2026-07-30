/// The pure-Dart converters (`convert.dart`) must be BYTE-IDENTICAL to the
/// native C converter in both directions for every matrix x range — that
/// equivalence is what lets web (no FFI) and native consumers share one
/// canonical colour contract. Also pins the RgbaYuvCoeffs invariants the
/// tables were adjusted for (neutral grey -> exactly 128, full-range white ->
/// exactly 255).
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

Uint8List _rand(int n, int seed) {
  final b = Uint8List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (s >> 8) & 0xff;
  }
  return b;
}

void main() {
  const combos = [
    (YuvColorMatrix.bt601, false),
    (YuvColorMatrix.bt601, true),
    (YuvColorMatrix.bt709, false),
    (YuvColorMatrix.bt709, true),
    (YuvColorMatrix.bt2020, false),
    (YuvColorMatrix.bt2020, true),
  ];

  group('dartRgbaToI420 == C cpuRgbaToI420 (byte-exact)', () {
    for (final (m, full) in combos) {
      test('$m fullRange=$full', () {
        for (final (w, h) in [(64, 48), (33, 17), (2, 2)]) {
          final rgba = _rand(w * h * 4, 0xC0FFEE + w);
          final d = dartRgbaToI420(rgba, w, h, matrix: m, fullRange: full);
          final c = cpuRgbaToI420(rgba, w, h, matrix: m, fullRange: full);
          expect(d.y, equals(c.y), reason: 'Y ${w}x$h');
          expect(d.u, equals(c.u), reason: 'U ${w}x$h');
          expect(d.v, equals(c.v), reason: 'V ${w}x$h');
        }
      });
    }
  });

  group('dartI420ToRgba == C cpuPlanarToRgba (byte-exact)', () {
    for (final (m, full) in combos) {
      test('$m fullRange=$full', () {
        for (final (w, h) in [(64, 48), (33, 17)]) {
          final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
          final y = _rand(w * h, 1);
          final u = _rand(cw * ch, 2);
          final v = _rand(cw * ch, 3);
          final dart =
              dartI420ToRgba(y, u, v, w, h, matrix: m, fullRange: full);
          final yuv = Uint8List(w * h + 2 * cw * ch)
            ..setRange(0, w * h, y)
            ..setRange(w * h, w * h + cw * ch, u)
            ..setRange(w * h + cw * ch, w * h + 2 * cw * ch, v);
          final c = cpuPlanarToRgba(YuvPlanar.i420, yuv, w, h,
              matrix: m, fullRange: full);
          expect(dart, equals(c), reason: '${w}x$h');
        }
      });
    }
  });

  group('RgbaYuvCoeffs invariants', () {
    test('neutral grey -> U=V=128 for every matrix/range', () {
      for (final (m, full) in combos) {
        for (final grey in [0, 1, 127, 128, 254, 255]) {
          final rgba = Uint8List(4 * 4 * 4);
          for (var i = 0; i < rgba.length; i += 4) {
            rgba[i] = grey;
            rgba[i + 1] = grey;
            rgba[i + 2] = grey;
            rgba[i + 3] = 255;
          }
          final p = dartRgbaToI420(rgba, 4, 4, matrix: m, fullRange: full);
          expect(p.u, everyElement(128), reason: '$m full=$full grey=$grey U');
          expect(p.v, everyElement(128), reason: '$m full=$full grey=$grey V');
        }
      }
    });

    test('white -> Y=255 full range, Y=235 limited (every matrix)', () {
      for (final (m, full) in combos) {
        final rgba = Uint8List(2 * 2 * 4)..fillRange(0, 16, 255);
        final p = dartRgbaToI420(rgba, 2, 2, matrix: m, fullRange: full);
        expect(p.y, everyElement(full ? 255 : 235), reason: '$m full=$full');
      }
    });

    test('black -> Y=0 full range, Y=16 limited (every matrix)', () {
      for (final (m, full) in combos) {
        final rgba = Uint8List(2 * 2 * 4);
        for (var i = 3; i < 16; i += 4) {
          rgba[i] = 255;
        }
        final p = dartRgbaToI420(rgba, 2, 2, matrix: m, fullRange: full);
        expect(p.y, everyElement(full ? 0 : 16), reason: '$m full=$full');
      }
    });

    test('round-trip grey ramp is near-lossless (601 limited)', () {
      // Sanity that the pair of tables actually inverts: a flat grey frame
      // must round-trip within 1 LSB (fixed-point rounding).
      for (final grey in [16, 64, 128, 200, 235]) {
        final rgba = Uint8List(4 * 4 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = grey;
          rgba[i + 1] = grey;
          rgba[i + 2] = grey;
          rgba[i + 3] = 255;
        }
        final p = dartRgbaToI420(rgba, 4, 4);
        final back = dartI420ToRgba(p.y, p.u, p.v, 4, 4);
        for (var i = 0; i < back.length; i += 4) {
          expect((back[i] - grey).abs(), lessThanOrEqualTo(1));
          expect((back[i + 1] - grey).abs(), lessThanOrEqualTo(1));
          expect((back[i + 2] - grey).abs(), lessThanOrEqualTo(1));
        }
      }
    });
  });

  test('bgra flag == swizzled rgba, Dart == C (byte-exact)', () {
    const w = 34, h = 22;
    final bgra = _rand(w * h * 4, 99);
    final rgba = Uint8List(bgra.length);
    for (var i = 0; i < bgra.length; i += 4) {
      rgba[i] = bgra[i + 2];
      rgba[i + 1] = bgra[i + 1];
      rgba[i + 2] = bgra[i];
      rgba[i + 3] = bgra[i + 3];
    }
    final viaFlag = dartRgbaToI420(bgra, w, h, bgra: true);
    final viaSwizzle = dartRgbaToI420(rgba, w, h);
    expect(viaFlag.y, equals(viaSwizzle.y));
    expect(viaFlag.u, equals(viaSwizzle.u));
    expect(viaFlag.v, equals(viaSwizzle.v));
    final c = cpuRgbaToI420(bgra, w, h, bgra: true);
    expect(c.y, equals(viaFlag.y));
    expect(c.u, equals(viaFlag.u));
    expect(c.v, equals(viaFlag.v));
  });

  test('async variants match sync byte-exactly', () async {
    const w = 40, h = 70; // several chunks + odd height
    final rgba = _rand(w * h * 4, 42);
    final sync = dartRgbaToI420(rgba, w, h);
    final async = await dartRgbaToI420Async(rgba, w, h, chunkRows: 16);
    expect(async.y, equals(sync.y));
    expect(async.u, equals(sync.u));
    expect(async.v, equals(sync.v));

    final rgbaBack = dartI420ToRgba(sync.y, sync.u, sync.v, w, h);
    final rgbaBackAsync =
        await dartI420ToRgbaAsync(sync.y, sync.u, sync.v, w, h, chunkRows: 16);
    expect(rgbaBackAsync, equals(rgbaBack));
  });
}
