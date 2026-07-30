/// Tests for the native (isolate-backed) [CpuExecutor]. The conditional import
/// selects the `dart:io` implementation on the VM, so these exercise the real
/// long-lived background isolate.
@TestOn('vm')
library;

import 'dart:isolate' show TransferableTypedData;
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/src/cpu_executor.dart';
import 'package:test/test.dart';

// Tasks MUST be top-level/static so they are sendable to the worker isolate.
int _square(int x) => x * x;

int _sum(List<int> xs) => xs.fold(0, (a, b) => a + b);

Never _boom(int x) => throw StateError('boom $x');

/// Doubles every byte (mod 256). Takes/returns [TransferableTypedData] to
/// exercise zero-copy byte hand-off across the isolate boundary.
TransferableTypedData _doubleBytes(TransferableTypedData input) {
  final bytes = input.materialize().asUint8List();
  final out = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    out[i] = (bytes[i] * 2) & 0xff;
  }
  return TransferableTypedData.fromList([out]);
}

void main() {
  group('CpuExecutor (native isolate)', () {
    test('runs a task and returns its result', () async {
      final ex = createCpuExecutor<int, int>(_square);
      expect(await ex.run(7), 49);
      await ex.dispose();
    });

    test('handles many concurrent submissions, matched correctly by id', () async {
      final ex = createCpuExecutor<int, int>(_square);
      final results = await Future.wait([for (var i = 0; i < 50; i++) ex.run(i)]);
      expect(results, [for (var i = 0; i < 50; i++) i * i]);
      await ex.dispose();
    });

    test('propagates task errors as CpuExecutorException', () async {
      final ex = createCpuExecutor<int, Never>(_boom);
      await expectLater(
        () => ex.run(3),
        throwsA(
          isA<CpuExecutorException>().having(
            (e) => e.message,
            'message',
            contains('boom 3'),
          ),
        ),
      );
      // Executor survives a task error and keeps working.
      final ex2 = createCpuExecutor<int, int>(_square);
      expect(await ex2.run(5), 25);
      await ex.dispose();
      await ex2.dispose();
    });

    test('round-trips byte payloads via TransferableTypedData', () async {
      final ex =
          createCpuExecutor<TransferableTypedData, TransferableTypedData>(
            _doubleBytes,
          );
      final input = TransferableTypedData.fromList([
        Uint8List.fromList([1, 2, 3, 200]),
      ]);
      final out = (await ex.run(input)).materialize().asUint8List();
      expect(out, [2, 4, 6, 144]); // 200*2 = 400 & 0xff = 144
      await ex.dispose();
    });

    test('run after dispose throws StateError', () async {
      final ex = createCpuExecutor<int, int>(_square);
      await ex.run(2);
      await ex.dispose();
      expect(() => ex.run(2), throwsStateError);
    });

    test('dispose awaits an in-flight submission rather than aborting it', () async {
      final ex = createCpuExecutor<List<int>, int>(_sum);
      final f = ex.run(List<int>.generate(1000, (i) => i));
      await ex.dispose(); // must not abort the already-submitted run
      expect(await f, 499500);
    });
  });
}
