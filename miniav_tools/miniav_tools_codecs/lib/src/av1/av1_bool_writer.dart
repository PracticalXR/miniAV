/// AV1 boolean (Daala) arithmetic range encoder.
///
/// Direct port of libaom `aom_dsp/entenc.c` (`od_ec_enc_*`). Only the bits
/// the encoder needs are ported — no precarry storage growth math (we use a
/// dynamic list), no bitstream-debug hooks.
///
/// Output convention matches AV1 §5.11 tile data: write all symbols, then
/// call [finish] which returns the byte stream that goes into the tile
/// payload.
///
/// CDF format (libaom `aom_cdf_prob`, length `nsyms + 1`):
///   * cdf[i] for i in [0, nsyms-1] is the Q15 inverse-CDF: probability that
///     the symbol value is **greater than** i, scaled so total mass = 32768
///     (cdf[nsyms-1] == 0 always).
///   * cdf[nsyms] is the adaptation rate counter (unused here — Phase 2 uses
///     `disable_cdf_update = 1` so CDFs are never updated).
///
/// For symbol s ∈ [0, nsyms):
///   * fl = (s > 0) ? cdf[s - 1] : 32768
///   * fh = cdf[s]
library;

import 'dart:typed_data';

class Av1BoolWriter {
  /// Probability shift applied inside the range update (matches libaom
  /// `EC_PROB_SHIFT`).
  static const int _ecProbShift = 6;

  /// Minimum probability spacing in 15-bit units (libaom `EC_MIN_PROB`).
  static const int _ecMinProb = 4;

  /// Construct a writer. [initialCapacity] sizes the internal
  /// `Uint16List` precarry buffer to avoid early growth reallocations
  /// (callers that know the rough output size can pass a tight hint).
  Av1BoolWriter({int initialCapacity = 16384})
    : _precarry = Uint16List(initialCapacity);

  int _low = 0;
  int _rng = 0x8000;
  int _cnt = -9;

  // Hot path: a `Uint16List` ring grown by doubling. Values fit in 16 bits
  // (the encoder masks each entry with `0xFFFF`), so we avoid the boxing /
  // dynamic-growth cost of `List<int>.add` — at 1080p the residual encoder
  // makes ~180k add() calls per frame, and the original `<int>[]` ate ~6 ms.
  Uint16List _precarry;
  int _precarryLen = 0;
  bool _done = false;

  /// Bytes produced so far (estimate before [finish]).
  int get pendingByteCount => _precarryLen;

  @pragma('vm:prefer-inline')
  void _pushPrecarry(int word) {
    if (_precarryLen >= _precarry.length) {
      final grown = Uint16List(_precarry.length * 2);
      grown.setRange(0, _precarryLen, _precarry);
      _precarry = grown;
    }
    _precarry[_precarryLen++] = word;
  }

  /// Encode a binary symbol [value] (0 or 1) where [p15] is the 15-bit
  /// probability that the symbol is **one** (range 1..32767).
  ///
  /// Convention matches libaom `od_ec_encode_bool_q15` and AV1 spec §9.4.2
  /// `boolean_decode` (where `bit = 1` occupies the bottom v of the range).
  void writeBool(int value, int p15) {
    assert(!_done, 'Av1BoolWriter: writeBool after finish()');
    assert(p15 > 0 && p15 < 32768, 'p15 out of range: $p15');
    var l = _low;
    final r = _rng;
    final v =
        (((r >> 8) * (p15 >> _ecProbShift)) >> (7 - _ecProbShift)) + _ecMinProb;
    final newR = value != 0 ? v : r - v;
    if (value != 0) l += r - v;
    _normalize(l, newR);
  }

  /// Encode a 50/50 binary symbol.
  void writeLiteralBit(int value) => writeBool(value, 16384);

  /// Encode multi-symbol [s] (0..nsyms-1) using the AV1 inverse-CDF.
  void writeSymbol(int s, List<int> cdf) {
    assert(!_done, 'Av1BoolWriter: writeSymbol after finish()');
    final nsyms = cdf.length - 1;
    assert(s >= 0 && s < nsyms, 'symbol $s out of range [0,$nsyms)');
    final fl = s > 0 ? cdf[s - 1] : 32768;
    final fh = cdf[s];
    _encodeQ15(fl, fh, s, nsyms);
  }

  // -- internals --------------------------------------------------------------

  void _encodeQ15(int fl, int fh, int s, int nsyms) {
    var l = _low;
    var r = _rng;
    assert(r >= 32768);
    assert(fh <= fl && fl <= 32768);
    final n = nsyms - 1;
    int u;
    int v;
    if (fl < 32768) {
      u =
          (((r >> 8) * (fl >> _ecProbShift)) >> (7 - _ecProbShift)) +
          _ecMinProb * (n - (s - 1));
      v =
          (((r >> 8) * (fh >> _ecProbShift)) >> (7 - _ecProbShift)) +
          _ecMinProb * (n - (s + 0));
      l += r - u;
      r = u - v;
    } else {
      r -=
          (((r >> 8) * (fh >> _ecProbShift)) >> (7 - _ecProbShift)) +
          _ecMinProb * (n - (s + 0));
    }
    _normalize(l, r);
  }

  void _normalize(int low, int rng) {
    assert(rng <= 65535);
    final d = 16 - _ilogNz(rng);
    var c = _cnt;
    var s = c + d;
    if (s >= 0) {
      // Match libaom: c is bumped by 16 here so subsequent `low >> c`
      // extracts bytes from the correct slot. (entenc.c — see comment in
      // od_ec_enc_normalize: `c += 16; m = (1 << c) - 1;`.)
      c += 16;
      var m = (1 << c) - 1;
      if (s >= 8) {
        _pushPrecarry((low >> c) & 0xFFFF);
        low &= m;
        c -= 8;
        m >>= 8;
      }
      _pushPrecarry((low >> c) & 0xFFFF);
      s = c + d - 24;
      low &= m;
    }
    _low = low << d;
    _rng = rng << d;
    _cnt = s;
  }

  // Bit-length lookup for an 8-bit value (1..255). `_log2P1[v]` returns
  // `floor(log2(v)) + 1`, i.e. the number of bits needed to represent `v`.
  // Index 0 is unused (rng is never zero on the hot path).
  static final Uint8List _log2P1 = _buildLog2P1();
  static Uint8List _buildLog2P1() {
    final t = Uint8List(256);
    for (var i = 1; i < 256; i++) {
      var n = 0;
      var x = i;
      while (x > 0) {
        x >>= 1;
        n++;
      }
      t[i] = n;
    }
    return t;
  }

  /// Bit length of a non-zero value in `[1, 65535]`. Branchless-ish: one
  /// table lookup on whichever byte holds the highest bit.
  @pragma('vm:prefer-inline')
  static int _ilogNz(int v) {
    final hi = v >> 8;
    if (hi != 0) return 8 + _log2P1[hi];
    return _log2P1[v];
  }

  /// Finalise and return the byte stream that goes into the tile data.
  Uint8List finish() {
    assert(!_done, 'Av1BoolWriter: finish() called twice');
    _done = true;
    final l = _low;
    var c = _cnt;
    var s = 10;
    const m = 0x3FFF;
    var e = ((l + m) & ~m) | (m + 1);
    s += c;
    if (s > 0) {
      var n = (1 << (c + 16)) - 1;
      do {
        _pushPrecarry((e >> (c + 16)) & 0xFFFF);
        e &= n;
        s -= 8;
        c -= 8;
        n >>= 8;
      } while (s > 0);
    }
    final len = _precarryLen;
    final pre = _precarry;
    final out = Uint8List(len);
    var carry = 0;
    for (var i = len - 1; i >= 0; i--) {
      final w = pre[i] + carry;
      out[i] = w & 0xFF;
      carry = w >> 8;
    }
    return out;
  }
}
