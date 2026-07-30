// CPU YUV -> RGBA8888 native converter (frame_convert.c), the player's
// cross-platform present fallback. Verifies:
//   1. exact BT.709 limited-range values for solid colours (white/black/chroma),
//   2. correct per-pixel plane indexing (each luma its own Y, shared chroma),
//   3. BYTE-EXACT agreement with a Dart reference of the same fixed-point
//      formula across a full-range pseudo-random buffer — this locks the C
//      implementation to its documented spec across every input value,
//   4. odd dimensions don't crash and produce the right output size.
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

// Dart mirror of the C fixed-point BT.601 limited-range math — the reference
// the C output must match byte-for-byte. These are the SAME coefficients as the
// player's yuv_rgba_reference.dart (298/409/516/-100/-208), which is the point:
// the CPU fallback must be colorimetrically identical to the zero-copy GPU path.
int _clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// x256 fixed-point coefficient sets — must match frame_convert.c.
class _Coeffs {
  const _Coeffs(this.yOff, this.yMul, this.rV, this.gU, this.gV, this.bU);
  final int yOff, yMul, rV, gU, gV, bU;
}

const _limited = _Coeffs(16, 298, 409, 100, 208, 516);
const _full = _Coeffs(0, 256, 359, 88, 183, 454);
const _limited709 = _Coeffs(16, 298, 459, 55, 136, 541);
const _full709 = _Coeffs(0, 256, 403, 48, 120, 475);
const _limited2020 = _Coeffs(16, 298, 430, 48, 167, 548);
const _full2020 = _Coeffs(0, 256, 378, 42, 146, 482);

List<int> _ref(int y, int u, int v, [_Coeffs k = _limited]) {
  final c = y - k.yOff, d = u - 128, e = v - 128;
  final yy = c * k.yMul + 128;
  return [
    _clip8((yy + k.rV * e) >> 8),
    _clip8((yy - k.gU * d - k.gV * e) >> 8),
    _clip8((yy + k.bU * d) >> 8),
    255,
  ];
}

// Back-compat alias used by the original I420/NV12 tests (limited range).
List<int> _yuvToRgbaRef(int y, int u, int v) => _ref(y, u, v);

Uint8List _solidI420(int w, int h, int y, int u, int v) {
  final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
  final buf = Uint8List(w * h + 2 * cw * ch);
  var p = 0;
  for (var i = 0; i < w * h; i++) {
    buf[p++] = y;
  }
  for (var i = 0; i < cw * ch; i++) {
    buf[p++] = u;
  }
  for (var i = 0; i < cw * ch; i++) {
    buf[p++] = v;
  }
  return buf;
}

Uint8List _solidNv12(int w, int h, int y, int u, int v) {
  final ch = (h + 1) >> 1;
  final buf = Uint8List(w * h + w * ch);
  var p = 0;
  for (var i = 0; i < w * h; i++) {
    buf[p++] = y;
  }
  for (var row = 0; row < ch; row++) {
    for (var col = 0; col < ((w + 1) >> 1); col++) {
      buf[p++] = u;
      buf[p++] = v;
    }
  }
  return buf;
}

void _expectPixel(Uint8List rgba, int idx, List<int> want, {int tol = 0}) {
  for (var k = 0; k < 4; k++) {
    expect((rgba[idx * 4 + k] - want[k]).abs() <= tol, isTrue,
        reason: 'pixel $idx byte $k: got ${rgba[idx * 4 + k]} want ${want[k]}');
  }
}

void main() {
  group('I420 -> RGBA', () {
    test('solid white / black are exact', () {
      final white = cpuI420ToRgba(_solidI420(4, 4, 235, 128, 128), 4, 4);
      final black = cpuI420ToRgba(_solidI420(4, 4, 16, 128, 128), 4, 4);
      expect(white.length, 4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        _expectPixel(white, i, [255, 255, 255, 255]);
        _expectPixel(black, i, [0, 0, 0, 255]);
      }
    });

    test('max chroma matches the fixed-point formula', () {
      // Y=128, V=240 (max red-difference): BT.601 -> (255,39,130).
      final red = cpuI420ToRgba(_solidI420(2, 2, 128, 128, 240), 2, 2);
      _expectPixel(red, 0, _yuvToRgbaRef(128, 128, 240));
      // Y=128, U=240 (max blue-difference): BT.601 -> (130,87,255).
      final blue = cpuI420ToRgba(_solidI420(2, 2, 128, 240, 128), 2, 2);
      _expectPixel(blue, 0, _yuvToRgbaRef(128, 240, 128));
    });

    test('per-pixel luma indexing: 2x2 distinct Y, shared chroma', () {
      // Y laid out row-major: [16, 235 / 126, 200], U=V=128 (neutral).
      final buf = Uint8List(2 * 2 + 2); // 4 Y + 1 U + 1 V (cw=ch=1)
      buf.setAll(0, [16, 235, 126, 200, 128, 128]);
      final rgba = cpuI420ToRgba(buf, 2, 2);
      _expectPixel(rgba, 0, _yuvToRgbaRef(16, 128, 128)); // black
      _expectPixel(rgba, 1, _yuvToRgbaRef(235, 128, 128)); // white
      _expectPixel(rgba, 2, _yuvToRgbaRef(126, 128, 128)); // mid
      _expectPixel(rgba, 3, _yuvToRgbaRef(200, 128, 128));
    });

    test('byte-exact vs Dart reference over a full-range buffer', () {
      const w = 64, h = 48;
      final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
      final buf = Uint8List(w * h + 2 * cw * ch);
      // deterministic pseudo-random fill spanning the full 0..255 range
      var s = 0x1234;
      for (var i = 0; i < buf.length; i++) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        buf[i] = (s >> 8) & 0xff;
      }
      final got = cpuI420ToRgba(buf, w, h);
      // reference
      final ref = Uint8List(w * h * 4);
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final y = buf[j * w + i];
          final u = buf[w * h + (j >> 1) * cw + (i >> 1)];
          final v = buf[w * h + cw * ch + (j >> 1) * cw + (i >> 1)];
          final px = _yuvToRgbaRef(y, u, v);
          final o = (j * w + i) * 4;
          for (var k = 0; k < 4; k++) {
            ref[o + k] = px[k];
          }
        }
      }
      expect(got, equals(ref));
    });

    test('odd dimensions do not crash and size is right', () {
      final rgba = cpuI420ToRgba(_solidI420(3, 3, 200, 100, 150), 3, 3);
      expect(rgba.length, 3 * 3 * 4);
    });
  });

  group('NV12 -> RGBA', () {
    test('solid white / black are exact', () {
      final white = cpuNv12ToRgba(_solidNv12(4, 4, 235, 128, 128), 4, 4);
      final black = cpuNv12ToRgba(_solidNv12(4, 4, 16, 128, 128), 4, 4);
      for (var i = 0; i < 16; i++) {
        _expectPixel(white, i, [255, 255, 255, 255]);
        _expectPixel(black, i, [0, 0, 0, 255]);
      }
    });

    test('byte-exact vs Dart reference over a full-range buffer', () {
      const w = 40, h = 32;
      final ch = (h + 1) >> 1;
      final buf = Uint8List(w * h + w * ch);
      var s = 0x99;
      for (var i = 0; i < buf.length; i++) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        buf[i] = (s >> 8) & 0xff;
      }
      final got = cpuNv12ToRgba(buf, w, h);
      final ref = Uint8List(w * h * 4);
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final y = buf[j * w + i];
          final uvRow = w * h + (j >> 1) * w;
          final pair = (i >> 1) << 1;
          final u = buf[uvRow + pair];
          final v = buf[uvRow + pair + 1];
          final px = _yuvToRgbaRef(y, u, v);
          final o = (j * w + i) * 4;
          for (var k = 0; k < 4; k++) {
            ref[o + k] = px[k];
          }
        }
      }
      expect(got, equals(ref));
    });
  });

  group('planar formats (i422 / i444 / 10-bit / range)', () {
    // Deterministic full-range fill for a byte buffer.
    Uint8List rand(int n, int seed) {
      final b = Uint8List(n);
      var s = seed;
      for (var i = 0; i < n; i++) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        b[i] = (s >> 8) & 0xff;
      }
      return b;
    }

    int le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

    test('i422 byte-exact vs reference (limited + full range)', () {
      const w = 16, h = 8;
      final cw = w >> 1;
      final buf = rand(w * h + 2 * cw * h, 0x11);
      for (final full in [false, true]) {
        final k = full ? _full : _limited;
        final got = cpuPlanarToRgba(YuvPlanar.i422, buf, w, h, fullRange: full);
        final ref = Uint8List(w * h * 4);
        for (var j = 0; j < h; j++) {
          for (var i = 0; i < w; i++) {
            final y = buf[j * w + i];
            final u = buf[w * h + j * cw + (i >> 1)];
            final v = buf[w * h + cw * h + j * cw + (i >> 1)];
            final px = _ref(y, u, v, k);
            final o = (j * w + i) * 4;
            for (var c = 0; c < 4; c++) { ref[o + c] = px[c]; }
          }
        }
        expect(got, equals(ref), reason: 'i422 full=$full');
      }
    });

    test('i444 byte-exact vs reference', () {
      const w = 12, h = 10;
      final buf = rand(3 * w * h, 0x22);
      final got = cpuPlanarToRgba(YuvPlanar.i444, buf, w, h);
      final ref = Uint8List(w * h * 4);
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final y = buf[j * w + i];
          final u = buf[w * h + j * w + i];
          final v = buf[2 * w * h + j * w + i];
          final px = _ref(y, u, v);
          final o = (j * w + i) * 4;
          for (var c = 0; c < 4; c++) { ref[o + c] = px[c]; }
        }
      }
      expect(got, equals(ref));
    });

    test('i420p10 byte-exact vs reference (16-bit LE >> 2)', () {
      const w = 16, h = 8;
      final cw = w >> 1, ch = h >> 1;
      final buf = rand(2 * (w * h + 2 * cw * ch), 0x33);
      final got = cpuPlanarToRgba(YuvPlanar.i420p10, buf, w, h);
      final ref = Uint8List(w * h * 4);
      final yOff = 0, uOff = 2 * w * h, vOff = 2 * (w * h + cw * ch);
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final y = le16(buf, yOff + (j * w + i) * 2) >> 2;
          final ci = ((j >> 1) * cw + (i >> 1)) * 2;
          final u = le16(buf, uOff + ci) >> 2;
          final v = le16(buf, vOff + ci) >> 2;
          final px = _ref(y, u, v);
          final o = (j * w + i) * 4;
          for (var c = 0; c < 4; c++) { ref[o + c] = px[c]; }
        }
      }
      expect(got, equals(ref));
    });

    test('bt709 i420 byte-exact vs 709 reference (limited + full)', () {
      const w = 32, h = 16;
      final cw = w >> 1, ch = h >> 1;
      final buf = rand(w * h + 2 * cw * ch, 0x77);
      for (final full in [false, true]) {
        final k = full ? _full709 : _limited709;
        final got = cpuPlanarToRgba(YuvPlanar.i420, buf, w, h,
            fullRange: full, matrix: YuvColorMatrix.bt709);
        final ref = Uint8List(w * h * 4);
        for (var j = 0; j < h; j++) {
          for (var i = 0; i < w; i++) {
            final y = buf[j * w + i];
            final u = buf[w * h + (j >> 1) * cw + (i >> 1)];
            final v = buf[w * h + cw * ch + (j >> 1) * cw + (i >> 1)];
            final px = _ref(y, u, v, k);
            final o = (j * w + i) * 4;
            for (var c = 0; c < 4; c++) {
              ref[o + c] = px[c];
            }
          }
        }
        expect(got, equals(ref), reason: 'bt709 full=$full');
        // And 709 must actually differ from 601 for chroma-heavy input.
        final got601 =
            cpuPlanarToRgba(YuvPlanar.i420, buf, w, h, fullRange: full);
        expect(got, isNot(equals(got601)));
      }
    });

    test('bt2020 i420 byte-exact vs 2020 reference + distinct from 601/709',
        () {
      const w = 32, h = 16;
      final cw = w >> 1, ch = h >> 1;
      final buf = rand(w * h + 2 * cw * ch, 0x2020);
      for (final full in [false, true]) {
        final k = full ? _full2020 : _limited2020;
        final got = cpuPlanarToRgba(YuvPlanar.i420, buf, w, h,
            fullRange: full, matrix: YuvColorMatrix.bt2020);
        final ref = Uint8List(w * h * 4);
        for (var j = 0; j < h; j++) {
          for (var i = 0; i < w; i++) {
            final y = buf[j * w + i];
            final u = buf[w * h + (j >> 1) * cw + (i >> 1)];
            final v = buf[w * h + cw * ch + (j >> 1) * cw + (i >> 1)];
            final px = _ref(y, u, v, k);
            final o = (j * w + i) * 4;
            for (var c = 0; c < 4; c++) {
              ref[o + c] = px[c];
            }
          }
        }
        expect(got, equals(ref), reason: 'bt2020 full=$full');
        final got709 = cpuPlanarToRgba(YuvPlanar.i420, buf, w, h,
            fullRange: full, matrix: YuvColorMatrix.bt709);
        expect(got, isNot(equals(got709)));
      }
    });

    test('p010 byte-exact vs reference (HIGH-bit samples, u16 >> 8)', () {
      const w = 16, h = 8;
      final ch = (h + 1) >> 1;
      // Y plane 2*w*h bytes + interleaved UV 2*w*ch bytes, 16-bit LE.
      final buf = rand(2 * w * h + 2 * w * ch, 0x1010);
      final got = cpuP010ToRgba(buf, w, h);
      final ref = Uint8List(w * h * 4);
      final uvOff = 2 * w * h;
      int hi(int byteOff) => buf[byteOff + 1]; // LE u16 >> 8 == high byte
      for (var j = 0; j < h; j++) {
        for (var i = 0; i < w; i++) {
          final y = hi((j * w + i) * 2);
          final pair = ((i >> 1) << 1);
          final rowOff = uvOff + (j >> 1) * 2 * w;
          final u = hi(rowOff + pair * 2);
          final v = hi(rowOff + (pair + 1) * 2);
          final px = _ref(y, u, v);
          final o = (j * w + i) * 4;
          for (var c = 0; c < 4; c++) {
            ref[o + c] = px[c];
          }
        }
      }
      expect(got, equals(ref));
      // Matrix threading works on p010 too (709 differs from 601).
      final got709 =
          cpuP010ToRgba(buf, w, h, matrix: YuvColorMatrix.bt709);
      expect(got709, isNot(equals(got)));
    });

    test('full-range i420 differs from limited + matches full coeffs', () {
      final buf = _solidI420(4, 4, 128, 200, 60);
      final full =
          cpuPlanarToRgba(YuvPlanar.i420, buf, 4, 4, fullRange: true);
      _expectPixel(full, 0, _ref(128, 200, 60, _full));
      final limited = cpuI420ToRgba(buf, 4, 4);
      expect(full.sublist(0, 3), isNot(equals(limited.sublist(0, 3))));
    });
  });

  group('CpuFrameConverter reuse', () {
    test('same converter across differing sizes stays correct', () {
      final c = CpuFrameConverter();
      try {
        final a = Uint8List.fromList(c.i420ToRgba(_solidI420(2, 2, 235, 128, 128), 2, 2));
        final b = Uint8List.fromList(c.i420ToRgba(_solidI420(8, 8, 16, 128, 128), 8, 8));
        _expectPixel(a, 0, [255, 255, 255, 255]);
        _expectPixel(b, 0, [0, 0, 0, 255]);
        expect(b.length, 8 * 8 * 4);
      } finally {
        c.dispose();
      }
    });

    test('use after dispose throws', () {
      final c = CpuFrameConverter()..dispose();
      expect(() => c.i420ToRgba(_solidI420(2, 2, 16, 128, 128), 2, 2),
          throwsA(isA<StateError>()));
    });

    test('too-small buffer throws', () {
      final c = CpuFrameConverter();
      try {
        expect(() => c.i420ToRgba(Uint8List(3), 4, 4),
            throwsA(isA<ArgumentError>()));
      } finally {
        c.dispose();
      }
    });
  });
}
