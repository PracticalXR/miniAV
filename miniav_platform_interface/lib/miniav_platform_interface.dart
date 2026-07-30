import 'dart:async';

import 'package:miniav_platform_interface/miniav_platform_types.dart';

import 'modules/miniav_camera_interface.dart';
import 'modules/miniav_screen_interface.dart';
import 'modules/miniav_audio_input_interface.dart';
import 'modules/miniav_audio_output_interface.dart';
import 'modules/miniav_loopback_interface.dart';
import 'modules/miniav_input_interface.dart';
import 'modules/miniav_inject_interface.dart';

export 'miniav_platform_types.dart';
export 'modules/miniav_camera_interface.dart';
export 'modules/miniav_screen_interface.dart';
export 'modules/miniav_audio_input_interface.dart';
export 'modules/miniav_audio_output_interface.dart';
export 'modules/miniav_loopback_interface.dart';
export 'modules/miniav_input_interface.dart';
export 'modules/miniav_inject_interface.dart';

// Conditional import for platform-specific implementation
import 'platform_stub/miniav_platform_stub.dart'
    if (dart.library.ffi) 'package:miniav_ffi/miniav_ffi.dart'
    if (dart.library.js) 'package:miniav_web/miniav_web.dart';

// Abstract interface
abstract class MiniAVPlatformInterface {
  MiniAVPlatformInterface();

  static MiniAVPlatformInterface? _instance;
  static MiniAVPlatformInterface get instance {
    _instance ??= registeredInstance();
    return _instance!;
  }

  static set instance(MiniAVPlatformInterface instance) {
    _instance = instance;
  }

  static MiniAVPlatformInterface createMiniAVPlatform() =>
      throw UnsupportedError('No platform implementation available.');

  MiniCameraPlatformInterface get camera;
  MiniScreenPlatformInterface get screen;
  MiniAudioInputPlatformInterface get audioInput;
  MiniAudioOutputPlatformInterface get audioOutput;
  MiniLoopbackPlatformInterface get loopback;
  MiniInputPlatformInterface get input;
  MiniInjectPlatformInterface get inject;

  String getVersionString();
  void setLogLevel(int level);

  /// Install a callback that receives native log messages from the MiniAV C
  /// library. [callback] receives a raw level integer (matching the
  /// [MiniAVLogLevel] index mapping used by [setLogLevel]) and the message
  /// string. Pass `null` to remove the current callback.
  ///
  /// The default implementation is a no-op (platforms that do not support
  /// native log callbacks — e.g. web — simply ignore this call).
  void setLogCallback(void Function(int level, String message)? callback) {}

  void dispose();
  Future<void> releaseBuffer(MiniAVBuffer buffer);

  /// Synchronous, fire-and-forget buffer release for hot paths (e.g. the
  /// per-frame capture callback) that cannot afford a per-call [Future]
  /// allocation. The default implementation delegates to [releaseBuffer] and
  /// drops the returned future; backends with a genuinely synchronous release
  /// (e.g. the native FFI backend, whose underlying C call is synchronous)
  /// should override this to release directly with no allocation.
  void releaseBufferSync(MiniAVBuffer buffer) {
    unawaited(releaseBuffer(buffer));
  }
}
