/// A bounded, strictly-FIFO, serialized async write queue.
///
/// This is the seam that decouples slow downstream writes (e.g. muxing an
/// encoded packet to disk via libav) from the producer that generates them
/// (e.g. the per-frame encode path). [add] chains each item onto a single
/// serial future, so:
///
///  * writes never overlap and always run in enqueue order (FIFO);
///  * [add] returns immediately in the common case, so the producer is not
///    blocked by the downstream write — it only blocks when [pending] has
///    reached [maxDepth] (back-pressure), at which point it awaits until a
///    completed write frees a slot.
///
/// Items are NEVER dropped: dropping already-produced data (e.g. an encoded
/// packet) would tear a hole in the output. The bound exists purely to cap
/// memory if the consumer stalls (e.g. a slow disk).
library;

import 'dart:async';

/// Writes a single [item] to the downstream sink. Must complete (or throw) when
/// the item has been fully consumed.
typedef AsyncWriter<T> = Future<void> Function(T item);

/// Called when [AsyncWriter] throws for an item. The queue swallows the error
/// (so one failed write does not poison the chain) after invoking this.
typedef WriteErrorHandler<T> =
    void Function(Object error, StackTrace stackTrace, T item);

class BoundedWriteQueue<T> {
  BoundedWriteQueue(this._write, {this.maxDepth = 64, this.onError})
    : assert(maxDepth > 0, 'maxDepth must be positive');

  final AsyncWriter<T> _write;

  /// Maximum number of in-flight (queued-but-unwritten) items before [add]
  /// applies back-pressure.
  final int maxDepth;

  final WriteErrorHandler<T>? onError;

  Future<void> _chain = Future<void>.value();
  int _pending = 0;
  Completer<void>? _spaceAvailable;

  /// Number of items queued but not yet written. Never exceeds [maxDepth].
  int get pending => _pending;

  /// Enqueues [item] for writing. Returns immediately unless the queue is full,
  /// in which case the returned future completes once a slot frees up.
  Future<void> add(T item) async {
    while (_pending >= maxDepth) {
      await (_spaceAvailable ??= Completer<void>()).future;
    }
    _pending++;
    _chain = _chain.then((_) async {
      try {
        await _write(item);
      } catch (e, st) {
        onError?.call(e, st, item);
      } finally {
        _pending--;
        final waiter = _spaceAvailable;
        if (waiter != null && _pending < maxDepth) {
          _spaceAvailable = null;
          waiter.complete();
        }
      }
    });
  }

  /// Completes once every currently-queued write has finished.
  Future<void> drain() => _chain;
}
