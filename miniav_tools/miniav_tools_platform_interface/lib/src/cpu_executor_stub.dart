/// Fallback [createCpuExecutorImpl] for platforms that expose neither
/// `dart:io` nor `dart:js_interop`. Never selected in practice.
library;

import 'cpu_executor.dart';

CpuExecutor<I, O> createCpuExecutorImpl<I, O>(
  CpuTask<I, O> task, {
  String? debugName,
}) => throw UnsupportedError(
  'CpuExecutor has no implementation for this platform',
);
