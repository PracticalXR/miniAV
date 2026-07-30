// Round-trip MSAC test: emit a sequence of symbols via Av1BoolWriter,
// then decode via a hand-ported dav1d MSAC decoder. Print any divergence.
import 'dart:typed_data';
import 'package:miniav_tools_codecs/src/av1/av1_bool_writer.dart';
import 'package:miniav_tools_codecs/src/av1/av1_default_cdfs.dart';

const int kEcProbShift = 6;
const int kEcMinProb = 4;
const int kEcWinSize = 64; // ec_win is 64-bit in dav1d 1.4.x

class MsacDecoder {
  final Uint8List buf;
  int pos = 0;
  int dif = 0;
  int rng = 0x8000;
  int cnt = -15;

  MsacDecoder(this.buf) {
    // init: dif starts at (1 << (EC_WIN_SIZE - 1)) - 1 then refill.
    dif = (1 << (kEcWinSize - 1)) - 1;
    refill();
  }

  void refill() {
    var c = cnt;
    var d = dif;
    while (c < 0 && pos < buf.length) {
      final b = buf[pos++];
      // dav1d: dif ^= (ec_win)byte << (EC_WIN_SIZE - 24 - cnt)
      final shift = kEcWinSize - 24 - c;
      // Use a 64-bit mask after shift to keep the value in window.
      d ^= (b << shift);
      c += 8;
    }
    cnt = c;
    dif = d;
  }

  // Treat dif as logical-unsigned 64-bit. Use >>> for logical right shift.
  int decodeBool(int p15) {
    final v =
        (((rng >> 8) * (p15 >> kEcProbShift)) >> (7 - kEcProbShift)) +
        kEcMinProb;
    final vw = v << (kEcWinSize - 16);
    // Unsigned compare: dif >= vw via toUnsigned trick or compare via
    // (dif - vw) sign with mask. Simplest: use BigInt-free approach by
    // splitting top 16 bits.
    final cHi = dif >>> (kEcWinSize - 16); // logical shift
    final ret = cHi >= v ? 1 : 0;
    if (ret != 0) dif -= vw;
    rng = ret != 0 ? rng - v : v;
    normalize();
    return 1 - ret; // dav1d returns !ret
  }

  int decodeSymbol(List<int> cdf) {
    final n = cdf.length - 1;
    final c = dif >>> (kEcWinSize - 16); // logical shift (unsigned)
    final r = rng >> 8;
    var u = rng;
    var v = rng;
    var val = -1;
    do {
      u = v;
      val++;
      v =
          ((r * (cdf[val] >> kEcProbShift)) >> (7 - kEcProbShift)) +
          kEcMinProb * (n - val - 1);
    } while (c < v);
    rng = u - v;
    dif -= v << (kEcWinSize - 16);
    normalize();
    return val;
  }

  void normalize() {
    if (rng >= 0x8000) return;
    while (rng < 0x8000) {
      rng <<= 1;
      dif <<= 1;
      // truncate dif to ec_win width
      dif &= (1 << kEcWinSize) - 1;
      cnt -= 1;
    }
    if (cnt < 0) refill();
  }
}

void main() {
  // Emit: writeSymbol(0, [25114,0,0]) i.e. sym=0 of 2-sym CDF [p=25114, 0]
  // then writeSymbol(1, same)
  // then writeBool(0, 25114)
  // then writeBool(1, 25114)
  final w = Av1BoolWriter();
  final cdf2 = _cdfMake([7654]); // == [25114, 0, 0]
  print('cdf2 = $cdf2');

  // Sequence: a series of test patterns
  final ops = <List<dynamic>>[];
  // chroma U skip then V skip pattern after luma coefs
  // Simulate iter12 minimal: 1 leaf worth
  ops.add(['sym', 0, defaultSkipTxfmCdfs[0]]); // skip=0
  ops.add(['sym', 0, defaultKfYModeCdf[0][0]]); // y_mode=DC_PRED
  ops.add(['sym', 0, defaultUvModeCdfCflAllowed[0]]); // uv_mode=DC_PRED
  // luma path
  ops.add(['sym', 0, coefTxbSkipTx4Qcat1[0]]); // txb_skip=0 ctx 0
  ops.add(['sym', 0, defaultTxtpIntra2DcPredCdf]); // tx_type=DCT_DCT
  ops.add(['sym', 0, coefEobBin16Qcat1[0]]); // eob_pt=0 luma
  ops.add(['sym', 0, coefEobBaseTokTx4Qcat1[0]]); // base_eob_tok=0
  ops.add(['sym', 0, defaultDcSignCdf[0][0]]); // dc_sign=0 (positive)
  // U: txb_skip=1 ctx 7
  ops.add(['sym7', 1]); // ctx 7
  // V: txb_skip=1 ctx 7
  ops.add(['sym7', 1]);

  for (final op in ops) {
    if (op[0] == 'sym') {
      final s = op[1] as int;
      final cdf = op[2] as List<int>;
      w.writeSymbol(s, cdf);
    } else if (op[0] == 'sym7') {
      final s = op[1] as int;
      w.writeSymbol(s, [32768 - coefTxbSkipTx4Qcat1Raw[7], 0, 0]);
    }
  }

  final bytes = w.finish();
  print(
    'encoded bytes (${bytes.length}): ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
  );

  // Decode
  final d = MsacDecoder(bytes);
  print(
    'init: rng=${d.rng.toRadixString(16)} dif=${d.dif.toRadixString(16)} cnt=${d.cnt}',
  );
  for (var i = 0; i < ops.length; i++) {
    final op = ops[i];
    int got;
    int expected;
    if (op[0] == 'sym') {
      expected = op[1] as int;
      got = d.decodeSymbol(op[2] as List<int>);
    } else {
      expected = op[1] as int;
      got = d.decodeSymbol([32768 - coefTxbSkipTx4Qcat1Raw[7], 0, 0]);
    }
    final mark = got == expected ? 'OK ' : '!! ';
    print(
      '$mark op$i: expected=$expected got=$got rng=${d.rng.toRadixString(16)} dif=${d.dif.toRadixString(16)} cnt=${d.cnt}',
    );
    if (got != expected) {
      print('  -> divergence at op $i; aborting');
      break;
    }
  }
}

const List<int> coefTxbSkipTx4Qcat1Raw = [
  30371,
  7570,
  13155,
  20751,
  20969,
  27067,
  32487,
  7654,
  19473,
  29984,
  9961,
  30242,
  32117,
];

List<int> _cdfMake(List<int> cum) {
  final out = List<int>.filled(cum.length + 2, 0);
  for (var i = 0; i < cum.length; i++) {
    out[i] = 32768 - cum[i];
  }
  return out;
}
