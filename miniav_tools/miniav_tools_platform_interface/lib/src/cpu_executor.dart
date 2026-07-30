/// A platform-agnostic seam for running CPU-bound work off the main isolate.
///
/// On native (`dart:io`), [createCpuExecutor] returns an implementation backed
/// by a long-lived background [Isolate] reused across calls (so we don't pay
/// spawn cost per frame). On web (`dart:js_interop`), it runs the task inline on
/// the main isolate — `dart:isolate` is unavailable there, and the browser
/// already provides real concurrency for the codec/GPU paths the recorder hides
/// behind (WebCodecs, WebGPU). A future web implementation can swap to a Web
/// Worker without touching callers.
///
/// Callers stay platform-agnostic and MUST NOT import `dart:isolate` directly —
/// that import lives only in the native implementation, kept out of web builds
/// by the conditional import below.
///
/// Because the work runs on another isolate on native:
///  * [CpuTask] MUST be a top-level or static function — closures that capture
///    state are not sendable across isolates;
///  * the input and output values must be sendable; wrap large byte payloads in
///    [TransferableTypedData] for zero-copy hand-off.
library;

import 'cpu_executor_stub.dart'
    if (dart.library.io) 'cpu_executor_io.dart'
    if (dart.library.js_interop) 'cpu_executor_web.dart';

/// A pure function executed by a [CpuExecutor]. MUST be top-level or static.
typedef CpuTask<I, O> = O Function(I input);

/// Runs CPU-bound [CpuTask]s off the main isolate where the platform allows it.
/// Create one via [createCpuExecutor] and [dispose] it when finished.
abstract class CpuExecutor<I, O> {
  /// Submits [input] for processing; completes with the task's result, or with
  /// a [CpuExecutorException] if the task threw. Submissions are processed in
  /// order on the worker.
  Future<O> run(I input);

  /// Releases the underlying worker. In-flight [run]s are awaited first on
  /// native; subsequent [run] calls throw [StateError].
  Future<void> dispose();
}

/// Error surfaced by [CpuExecutor.run] when the task throws (native) — the
/// original error/stack are carried as strings because arbitrary error objects
/// are not always sendable across isolates.
class CpuExecutorException implements Exception {
  CpuExecutorException(this.message, [this.workerStackTrace]);
  final String message;
  final String? workerStackTrace;

  @override
  String toString() => 'CpuExecutorException: $message'
      '${workerStackTrace != null ? '\n$workerStackTrace' : ''}';
}

/// Creates a [CpuExecutor] for [task], appropriate to the current platform.
CpuExecutor<I, O> createCpuExecutor<I, O>(
  CpuTask<I, O> task, {
  String? debugName,
}) => createCpuExecutorImpl<I, O>(task, debugName: debugName);
