/// Tests for [BoundedWriteQueue] — the seam that decouples downstream writes
/// (muxing) from the encode path while preserving order and bounding memory.
@TestOn('vm')
library;

import 'dart:async';

import 'package:miniav_recorder/src/bounded_write_queue.dart';
import 'package:test/test.dart';

/// Runs all currently-scheduled microtasks (and one timer turn), so chained
/// writes that are gated on a [Completer] get a chance to progress.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('BoundedWriteQueue', () {
    test('writes items in strict FIFO order', () async {
      final written = <int>[];
      final q = BoundedWriteQueue<int>((i) async {
        // Yield so out-of-order completion would be possible if the queue were
        // not serial — it must still come out in order.
        await pump();
        written.add(i);
      });

      for (var i = 0; i < 10; i++) {
        await q.add(i);
      }
      await q.drain();

      expect(written, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(q.pending, 0);
    });

    test('add() returns without blocking while under maxDepth', () async {
      final gate = Completer<void>();
      var writes = 0;
      final q = BoundedWriteQueue<int>((i) async {
        await gate.future; // stays queued until we release
        writes++;
      }, maxDepth: 4);

      for (var i = 0; i < 4; i++) {
        await q.add(i); // must not block: pending stays <= maxDepth
      }
      await pump();
      expect(q.pending, 4, reason: 'all queued, none written yet');
      expect(writes, 0, reason: 'writes are gated');

      gate.complete();
      await q.drain();
      expect(writes, 4);
      expect(q.pending, 0);
    });

    test('applies back-pressure at maxDepth and resumes as writes drain', () async {
      final release = Completer<void>();
      final written = <int>[];
      final q = BoundedWriteQueue<int>((i) async {
        await release.future;
        written.add(i);
      }, maxDepth: 2);

      await q.add(0);
      await q.add(1);
      expect(q.pending, 2, reason: 'queue is now full');

      // The third add must block until a slot frees.
      var thirdReturned = false;
      final third = q.add(2).then((_) => thirdReturned = true);
      await pump();
      await pump();
      expect(thirdReturned, isFalse, reason: 'add(2) blocked at capacity');
      expect(q.pending, 2);

      // Releasing the writes frees slots; add(2) (and the rest) get through.
      release.complete();
      await third;
      expect(thirdReturned, isTrue);

      await q.drain();
      expect(q.pending, 0);
      expect(written, [0, 1, 2], reason: 'order preserved through back-pressure');
    });

    test('onError is invoked and the chain continues after a failing write', () async {
      final written = <int>[];
      final errors = <Object>[];
      final q = BoundedWriteQueue<int>(
        (i) async {
          if (i == 1) throw StateError('boom $i');
          written.add(i);
        },
        onError: (e, st, item) => errors.add(e),
      );

      for (var i = 0; i < 4; i++) {
        await q.add(i);
      }
      await q.drain();

      expect(written, [0, 2, 3], reason: 'item 1 threw; others still written');
      expect(errors, hasLength(1));
      expect(errors.first, isA<StateError>());
      expect(q.pending, 0);
    });

    test('drain() on an idle queue completes immediately', () async {
      final q = BoundedWriteQueue<int>((_) async {});
      await q.drain(); // must not hang
      expect(q.pending, 0);
    });
  });
}
