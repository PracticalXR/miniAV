/// Web [CpuExecutor]: runs the task inline on the main isolate.
///
/// `dart:isolate` is unavailable on web, and the browser already threads the
/// heavy codec/GPU paths the recorder relies on, so the pure-Dart fallback work
/// runs inline here. This can later be swapped for a Web Worker
/// (`dart:js_interop` + `package:web`) without changing callers.
library;

import 'cpu_executor.dart';

CpuExecutor<I, O> createCpuExecutorImpl<I, O>(
  CpuTask<I, O> task, {
  String? debugName,
}) => _InlineCpuExecutor<I, O>(task);

class _InlineCpuExecutor<I, O> implements CpuExecutor<I, O> {
  _InlineCpuExecutor(this._task);
  final CpuTask<I, O> _task;
  bool _disposed = false;

  @override
  Future<O> run(I input) async {
    if (_disposed) throw StateError('CpuExecutor has been disposed');
    // Run inline; surface task errors as CpuExecutorException so the contract
    // matches the native implementation.
    try {
      return _task(input);
    } catch (e, st) {
      throw CpuExecutorException(e.toString(), st.toString());
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}
