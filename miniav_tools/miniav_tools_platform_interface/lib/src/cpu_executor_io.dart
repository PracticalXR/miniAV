/// Native [CpuExecutor]: a long-lived background [Isolate] reused across calls.
///
/// One isolate is spawned per executor and processes submissions serially from
/// a command port, matching responses back by id. The task function is sent to
/// the worker at spawn time (hence the top-level/static requirement). This is
/// the ONLY file that imports `dart:isolate`; the conditional import in
/// `cpu_executor.dart` keeps it out of web builds.
library;

import 'dart:async';
import 'dart:isolate';

import 'cpu_executor.dart';

CpuExecutor<I, O> createCpuExecutorImpl<I, O>(
  CpuTask<I, O> task, {
  String? debugName,
}) => _IsolateCpuExecutor<I, O>(task, debugName ?? 'CpuExecutor');

class _IsolateCpuExecutor<I, O> implements CpuExecutor<I, O> {
  _IsolateCpuExecutor(this._task, String debugName) {
    _ready = _start(debugName);
  }

  final CpuTask<I, O> _task;
  late final Future<void> _ready;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _onExit;
  final Map<int, Completer<O>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;

  Future<void> _start(String debugName) async {
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    final handshake = Completer<SendPort>();

    fromWorker.listen((dynamic msg) {
      if (msg is SendPort) {
        handshake.complete(msg);
        return;
      }
      // Response: [id, ok(bool), payload, (stack?)]
      final list = msg as List;
      final id = list[0] as int;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (list[1] as bool) {
        completer.complete(list[2] as O);
      } else {
        completer.completeError(
          CpuExecutorException(list[2] as String, list[3] as String?),
        );
      }
    });

    final onExit = ReceivePort();
    _onExit = onExit;
    onExit.listen((_) {
      // The worker exited. If this wasn't a clean dispose, fail anything still
      // pending so callers never hang on a dead worker.
      if (_disposed) return;
      final stranded = Map<int, Completer<O>>.of(_pending);
      _pending.clear();
      for (final c in stranded.values) {
        c.completeError(
          CpuExecutorException('CpuExecutor worker isolate exited'),
        );
      }
    });

    _isolate = await Isolate.spawn(
      _workerMain,
      [fromWorker.sendPort, _task],
      debugName: debugName,
      onExit: onExit.sendPort,
    );
    _toWorker = await handshake.future;
  }

  @override
  Future<O> run(I input) {
    if (_disposed) throw StateError('CpuExecutor has been disposed');
    // Register the request SYNCHRONOUSLY (before awaiting startup) so a dispose
    // that races a just-submitted run still sees it in _pending and waits.
    final id = _nextId++;
    final completer = Completer<O>();
    _pending[id] = completer;
    _ready.then(
      (_) => _toWorker!.send([id, input]),
      onError: (Object e, StackTrace st) {
        _pending.remove(id);
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _ready;
    } catch (_) {
      // Spawn failed; nothing to tear down beyond closing ports below.
    }
    // Let in-flight requests finish (responses still arrive via _fromWorker).
    if (_pending.isNotEmpty) {
      await Future.wait(
        _pending.values.map((c) => c.future.catchError((_) => null as O)),
      );
    }
    _toWorker?.send(null); // ask the worker to close its command port and exit
    _fromWorker?.close();
    _onExit?.close();
    // Guaranteed teardown in case the worker is wedged and never exits cleanly.
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
  }
}

/// Entry point on the worker isolate. [args] is `[SendPort toMain, CpuTask]`.
void _workerMain(List<dynamic> args) {
  final SendPort toMain = args[0] as SendPort;
  final Function task = args[1] as Function;
  final commands = ReceivePort();
  toMain.send(commands.sendPort); // handshake

  commands.listen((dynamic msg) {
    if (msg == null) {
      commands.close(); // shutdown → isolate exits once idle
      return;
    }
    final list = msg as List; // [id, input]
    final id = list[0] as int;
    final input = list[1];
    try {
      final result = (task as dynamic)(input);
      toMain.send([id, true, result]);
    } catch (e, st) {
      toMain.send([id, false, e.toString(), st.toString()]);
    }
  });
}
