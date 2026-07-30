import 'dart:io';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import './src/miniav_audio_input.dart';
import './src/miniav_audio_output.dart';
import './src/miniav_camera.dart';
import './src/miniav_input.dart';
import './src/miniav_inject.dart';
import './src/miniav_loopback.dart';
import './src/miniav_screen.dart';

export 'package:miniav_platform_interface/miniav_platform_interface.dart';
export './src/miniav_audio_input.dart';
export './src/miniav_audio_output.dart';
export './src/miniav_camera.dart';
export './src/miniav_input.dart';
export './src/miniav_inject.dart';
export './src/miniav_loopback.dart';
export './src/miniav_screen.dart';

/// Main MiniAV library providing cross-platform audio/video capture functionality.
class MiniAV {
  static MiniAVPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance;

  /// Camera capture functionality
  static MiniCamera get camera => MiniCamera();

  /// Screen capture functionality
  static MiniScreen get screen => MiniScreen();

  /// Audio input (microphone) capture functionality
  static MiniAudioInput get audioInput => MiniAudioInput();

  /// Audio output (playback / speaker) functionality
  static MiniAudioOutput get audioOutput => MiniAudioOutput();

  /// Loopback (system audio) capture functionality
  static MiniLoopback get loopback => MiniLoopback();

  /// Input capture (keyboard, mouse, gamepad) functionality
  static MiniInput get input => MiniInput();

  /// Input injection (replay keyboard/mouse events onto this machine)
  static MiniInject get inject => MiniInject();

  /// Get the version string of the MiniAV library
  static String getVersion() => _platform.getVersionString();

  /// Set the log level for the MiniAV library
  static void setLogLevel(MiniAVLogLevel level) =>
      _platform.setLogLevel(level.index);

  /// Install a callback that receives log messages from the MiniAV C library.
  ///
  /// [callback] is invoked on the Dart event loop (not the native thread) with
  /// a [MiniAVLogLevel] and the trimmed message string. Pass `null` to remove
  /// the current callback and stop forwarding.
  ///
  /// Calling [setLogLevel] does NOT automatically install this callback — you
  /// must call [setLogCallback] or [installStderrLogger] separately.
  static void setLogCallback(
    void Function(MiniAVLogLevel level, String message)? callback,
  ) {
    _platform.setLogCallback(
      callback == null
          ? null
          : (int levelInt, String msg) {
              final idx = levelInt.clamp(0, MiniAVLogLevel.values.length - 1);
              callback(MiniAVLogLevel.values[idx], msg);
            },
    );
  }

  /// Install a stderr forwarder so that all MiniAV C-library log messages
  /// (at the currently configured log level) are written to Dart's `stderr`.
  ///
  /// Output format: `[miniav] <level>: <message>`
  ///
  /// Replaces any callback previously installed via [setLogCallback].
  static void installStderrLogger() {
    setLogCallback(
      (level, msg) =>
          stderr.writeln('[miniav] ${level.name}: ${msg.trimRight()}'),
    );
  }

  /// Dispose of all MiniAV resources
  static void dispose() => _platform.dispose();

  /// Release a buffer previously obtained from MiniAV.
  ///
  /// Must be called exactly once for every buffer delivered to a capture
  /// callback, including buffers you skip or drop.
  ///
  /// **GPU path:** this also closes the platform GPU handle exposed in
  /// `MiniAVVideoBuffer.nativeHandles[0]` (on Windows, the shared NT HANDLE).
  /// miniav owns that handle — do not close it yourself — and it becomes
  /// invalid as soon as this call runs. Complete any import
  /// (`OpenSharedResource1`, minigpu `importVideoFrame`, …) *before* releasing.
  static Future<void> releaseBuffer(MiniAVBuffer buffer) async {
    return _platform.releaseBuffer(buffer);
  }

  /// Synchronous, fire-and-forget variant of [releaseBuffer] for hot paths
  /// (e.g. a per-frame capture callback) that must avoid a per-call [Future]
  /// allocation. On the native FFI backend this performs the buffer release
  /// inline with no allocation; on platforms without a synchronous release it
  /// delegates to [releaseBuffer] and drops the future.
  static void releaseBufferSync(MiniAVBuffer buffer) =>
      _platform.releaseBufferSync(buffer);
}
