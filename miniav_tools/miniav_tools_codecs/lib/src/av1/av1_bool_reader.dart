/// AV1 boolean (Daala) arithmetic range **decoder**.
///
/// Test-only counterpart to [Av1BoolWriter]. Direct port of libaom
/// `aom_dsp/entdec.c` (`od_ec_dec_*`) with a 32-bit window. The minigpu
/// encoder pipeline never uses this — production decoding is delegated to
/// `dav1d`/`ffmpeg`. Its sole purpose is round-trip validation of the writer.
library;

import 'dart:typed_data';

class Av1BoolReader {
  Av1BoolReader(Uint8List buf) : _buf = buf {
    _dif = (1 << 31) - 1;
    _cnt = -15;
    _refill();
  }

  static const int _windowSize = 32;
  static const int _ecProbShift = 6;
  static const int _ecMinProb = 4;
  static const int _lotsOfBits = 0x4000;

  final Uint8List _buf;
  int _bptr = 0;
  int _dif = 0;
  int _rng = 0x8000;
  int _cnt = 0;

  void _refill() {
    var dif = _dif;
    var cnt = _cnt;
    var bptr = _bptr;
    final end = _buf.length;
    var s = _windowSize - 9 - (cnt + 15);
    while (s >= 0 && bptr < end) {
      dif ^= _buf[bptr] << s;
      cnt += 8;
      s -= 8;
      bptr++;
    }
    if (bptr >= end) {
      cnt = _lotsOfBits;
    }
    _dif = dif;
    _cnt = cnt;
    _bptr = bptr;
  }

  int _normalize(int dif, int rng, int ret) {
    final d = 16 - _ilogNz(rng);
    _cnt -= d;
    _dif = ((dif + 1) << d) - 1;
    _rng = rng << d;
    if (_cnt < 0) _refill();
    return ret;
  }

  int readBool(int p15) {
    var dif = _dif;
    final r = _rng;
    var v =
        (((r >> 8) * (p15 >> _ecProbShift)) >> (7 - _ecProbShift)) + _ecMinProb;
    final vw = v << (_windowSize - 16);
    var ret = 1;
    var rNew = v;
    if (dif >= vw) {
      rNew = r - v;
      dif -= vw;
      ret = 0;
    }
    return _normalize(dif, rNew, ret);
  }

  int readSymbol(List<int> cdf) {
    final nsyms = cdf.length - 1;
    var dif = _dif;
    final r = _rng;
    final c = dif >> (_windowSize - 16);
    var v = r;
    var u = 0;
    var ret = -1;
    do {
      u = v;
      ret++;
      v =
          (((r >> 8) * (cdf[ret] >> _ecProbShift)) >> (7 - _ecProbShift)) +
          _ecMinProb * (nsyms - ret - 1);
    } while (c < v);
    final rNew = u - v;
    dif -= v << (_windowSize - 16);
    return _normalize(dif, rNew, ret);
  }

  static int _ilogNz(int v) {
    var n = 0;
    var x = v;
    while (x > 0) {
      x >>= 1;
      n++;
    }
    return n;
  }
}
