/// Dart-side logging hook for miniav_tools_ffmpeg.
///
/// Every diagnostic this package emits from Dart code (downloader progress,
/// encoder selection, vendor probing, fallbacks) flows through [ffmpegToolsLog]
/// so a host application can capture it via [setFfmpegToolsLogCallback] —
/// the recorder does this automatically and re-tags messages as
/// `RecorderLogSource.ffmpeg`.
///
/// The default sink is `print`, NOT `dart:io` `stderr`/`stdout`. In a
/// Windows GUI-subsystem process (a packaged Flutter desktop app launched
/// outside a terminal) the OS stdio handles are invalid and `dart:io` stdio
/// writes fail with an asynchronous `FileSystemException` ("The handle is
/// invalid, errno = 6") that no try/catch at the call site can intercept —
/// it surfaces as an uncaught zone error. `print` is routed through the
/// zone (and in Flutter, the engine logger) instead of the raw OS handle,
/// so it is safe with or without a console.
library;

import 'package:miniav_platform_interface/miniav_platform_interface.dart'
    show MiniAVLogLevel;

export 'package:miniav_platform_interface/miniav_platform_interface.dart'
    show MiniAVLogLevel;

/// Receives Dart-side diagnostics from this package.
typedef FfmpegToolsLogCallback =
    void Function(MiniAVLogLevel level, String message);

FfmpegToolsLogCallback? _callback;
MiniAVLogLevel _minLevel = MiniAVLogLevel.info;

/// Install [callback] to receive every Dart-side log message this package
/// emits (at or above the level set via [setFfmpegToolsLogLevel]).
///
/// Pass `null` to restore the default sink (`print`).
///
/// This covers the package's own Dart diagnostics only. Native `av_log`
/// messages from the FFmpeg libraries are routed separately via
/// `FfmpegShim.setFfmpegLogCallback`.
void setFfmpegToolsLogCallback(FfmpegToolsLogCallback? callback) =>
    _callback = callback;

/// Minimum severity that is forwarded. Defaults to [MiniAVLogLevel.info]
/// (per-attempt probe chatter is classified `debug` and hidden by default).
/// [MiniAVLogLevel.none] silences the package entirely.
void setFfmpegToolsLogLevel(MiniAVLogLevel level) => _minLevel = level;

/// Route [message] to the installed callback or the safe default sink.
/// Internal — call sites in this package use this instead of `stderr`.
void ffmpegToolsLog(MiniAVLogLevel level, String message) {
  if (_minLevel == MiniAVLogLevel.none || level == MiniAVLogLevel.none) return;
  if (level.index < _minLevel.index) return;
  final cb = _callback;
  if (cb != null) {
    cb(level, message);
  } else {
    print(message); // deliberate: see library doc-comment for why not stderr
  }
}
