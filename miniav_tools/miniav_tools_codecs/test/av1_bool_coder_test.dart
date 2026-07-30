@TestOn('vm')
library;

import 'dart:math' as math;

import 'package:miniav_tools_codecs/src/av1/av1_bool_reader.dart';
import 'package:miniav_tools_codecs/src/av1/av1_bool_writer.dart';
import 'package:test/test.dart';

void main() {
  group('AV1 range coder round-trip', () {
    test('writeBool / readBool — single 50/50 bit', () {
      final w = Av1BoolWriter();
      w.writeBool(1, 16384);
      final out = w.finish();
      expect(out.length, greaterThan(0));
      final r = Av1BoolReader(out);
      expect(r.readBool(16384), 1);
    });

    test('writeBool / readBool — 200 random fair bits', () {
      final rng = math.Random(0xC0DE);
      final bits = List<int>.generate(200, (_) => rng.nextInt(2));
      final w = Av1BoolWriter();
      for (final b in bits) {
        w.writeBool(b, 16384);
      }
      final out = w.finish();
      final r = Av1BoolReader(out);
      for (var i = 0; i < bits.length; i++) {
        expect(r.readBool(16384), bits[i], reason: 'bit $i');
      }
    });

    test('writeBool / readBool — biased probabilities, 5000 symbols', () {
      final rng = math.Random(0xBEEF);
      final probs = [256, 1024, 4096, 16384, 24000, 30000, 32000];
      final symbols = <int>[];
      final ps = <int>[];
      for (var i = 0; i < 5000; i++) {
        final p = probs[i % probs.length];
        final v = rng.nextInt(32768) < p ? 1 : 0;
        symbols.add(v);
        ps.add(p);
      }
      final w = Av1BoolWriter();
      for (var i = 0; i < symbols.length; i++) {
        w.writeBool(symbols[i], ps[i]);
      }
      final out = w.finish();
      final r = Av1BoolReader(out);
      for (var i = 0; i < symbols.length; i++) {
        expect(r.readBool(ps[i]), symbols[i], reason: 'symbol $i, p=${ps[i]}');
      }
    });

    test('writeSymbol / readSymbol — multi-symbol CDF, 1000 random', () {
      // 4-symbol uniform CDF (icdf: each prob = 8192 = 32768/4).
      // icdf[0]=24576 ( > 0), icdf[1]=16384, icdf[2]=8192, icdf[3]=0,
      // icdf[4]=adaptation count.
      final cdf = [24576, 16384, 8192, 0, 0];
      final rng = math.Random(0xF00D);
      final syms = List<int>.generate(1000, (_) => rng.nextInt(4));
      final w = Av1BoolWriter();
      for (final s in syms) {
        w.writeSymbol(s, cdf);
      }
      final out = w.finish();
      final r = Av1BoolReader(out);
      for (var i = 0; i < syms.length; i++) {
        expect(r.readSymbol(cdf), syms[i], reason: 'i=$i');
      }
    });

    test('Mixed bool + symbol stream round-trips', () {
      final cdf3 = [22000, 10000, 0, 0]; // 3 symbols, non-uniform
      final w = Av1BoolWriter();
      final rng = math.Random(42);
      final ops = <Object>[];
      for (var i = 0; i < 2000; i++) {
        if (rng.nextBool()) {
          final v = rng.nextInt(2);
          final p = 1 + rng.nextInt(32766);
          w.writeBool(v, p);
          ops.add([0, v, p]);
        } else {
          final s = rng.nextInt(3);
          w.writeSymbol(s, cdf3);
          ops.add([1, s]);
        }
      }
      final out = w.finish();
      final r = Av1BoolReader(out);
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i] as List;
        if (op[0] == 0) {
          expect(r.readBool(op[2] as int), op[1] as int, reason: 'op $i bool');
        } else {
          expect(r.readSymbol(cdf3), op[1] as int, reason: 'op $i sym');
        }
      }
    });

    test(
      'Compression: skewed bits use far fewer than 1 byte per 8 symbols',
      () {
        // p15=768 → prob(bit=1)=768/32768 → bit=0 is very likely (~97.6%).
        // 1000 zeros should compress to << 125 bytes.
        final w = Av1BoolWriter();
        for (var i = 0; i < 1000; i++) {
          w.writeBool(0, 768);
        }
        final out = w.finish();
        expect(
          out.length,
          lessThan(25),
          reason: 'expected strong compression on highly biased input',
        );
      },
    );
  });
}
