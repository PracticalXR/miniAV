/// Shared Dart-side log routing for the recorder package.
///
/// [recorderLog] is the single funnel for every Dart-layer diagnostic in
/// this package (recorder runtime, clip buffer, GPU screen processor).
/// `Recorder.setLogCallback` installs the process-wide callback consumed
/// here; without one, messages go to the default sink.
///
/// The default sink is `print`, NOT `dart:io` `stderr`/`stdout`. In a
/// Windows GUI-subsystem process (a packaged Flutter desktop app launched
/// outside a terminal) the OS stdio handles are invalid and `dart:io`
/// stdio writes fail with an asynchronous `FileSystemException` ("The
/// handle is invalid, errno = 6") that surfaces as an uncaught zone error
/// no try/catch can intercept. `print` is routed through the zone (and in
/// Flutter, the engine logger) instead of the raw OS handle, so it is safe
/// with or without a console.
library;

/// Log verbosity level for all native subsystems managed by `Recorder`.
///
/// Maps to:
/// - MiniAV C library   → `MiniAVLogLevel`
/// - FFmpeg (av_log)    → AV_LOG_* constants
/// - minigpu / Dawn     → no native API; Dawn writes directly to native stderr
enum RecorderLogLevel {
  /// All internal debug output (very verbose — for deep diagnostics only).
  verbose,

  /// Informational messages (startup, encoder selection, device names).
  info,

  /// Warnings only (recoverable issues, dropped frames, fallbacks).
  warning,

  /// Errors only.
  error,

  /// Suppress all native log output.
  quiet,
}

/// Identifies which subsystem produced a log message delivered to the
/// callback installed via `Recorder.setLogCallback`.
enum RecorderLogSource {
  /// Log from the Dart-layer recorder runtime (encoder selection, stats,
  /// errors surfaced from native callbacks).
  recorder,

  /// Log from the MiniAV C library (capture pipeline, device enumeration).
  miniav,

  /// Log from FFmpeg — native av_log messages bridged via the shim, plus
  /// the miniav_tools_ffmpeg Dart layer (downloader, encoder selection).
  ffmpeg,

  /// Log from the minigpu / Dawn native GPU layer (compute, texture import,
  /// D3D11 interop).
  minigpu,
}

/// Process-wide callback installed via `Recorder.setLogCallback`.
/// Package-internal — the barrel does not export this library's globals.
void Function(RecorderLogSource source, RecorderLogLevel level, String message)?
recorderLogCallback;

/// Route a Dart-layer log line to the installed callback, or to the safe
/// default sink (`print`) when none is installed.
void recorderLog(
  RecorderLogSource source,
  RecorderLogLevel level,
  String message,
) {
  final cb = recorderLogCallback;
  if (cb != null) {
    cb(source, level, message);
  } else {
    // deliberate: see library doc-comment for why print, not stderr
    print('[${source.name}] $message');
  }
}
