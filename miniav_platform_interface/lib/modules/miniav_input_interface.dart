import '../miniav_platform_types.dart';

/// Abstract interface for input capture functionality on all platforms.
abstract class MiniInputPlatformInterface {
  /// Enumerate available gamepad devices.
  Future<List<MiniAVDeviceInfo>> enumerateGamepads();

  /// Create an input capture context.
  Future<MiniInputContextPlatformInterface> createContext();

  /// Subscribe to gamepad add/remove notifications.
  void Function() addGamepadChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Gamepad-change subscription not supported.');

  /// Request OS motion-sensor permission where one is required (iOS 13+, and
  /// iOS-Safari web where it MUST be called synchronously from a user gesture —
  /// call this as the first thing in the gesture handler, before any context is
  /// created, so the user-activation is still live). No-op / already-granted
  /// elsewhere. Returns true if motion may be captured. Default: true.
  Future<bool> requestMotionPermission() async => true;
}

/// Abstract input context for configuring and capturing input events.
abstract class MiniInputContextPlatformInterface {
  /// Configure the input context with the given config.
  Future<void> configure(MiniAVInputConfig config);

  /// Start input capture.
  /// Provide callbacks for each input type you want to receive.
  Future<void> startCapture({
    void Function(MiniAVKeyboardEvent event, Object? userData)? onKeyboard,
    void Function(MiniAVMouseEvent event, Object? userData)? onMouse,
    void Function(MiniAVGamepadEvent event, Object? userData)? onGamepad,
    void Function(MiniAVMotionEvent event, Object? userData)? onMotion,
    Object? userData,
  });

  /// Latest motion (IMU) sample, or null if none yet / motion not captured.
  /// The pull surface for the parallax render loop / game tick (avoids the
  /// callback firehose). Default: null.
  MiniAVMotionEvent? latestMotion() => null;

  /// Snapshot of gamepad [index]'s current state, or null. The pull surface
  /// for a game tick. Default: null.
  MiniAVGamepadEvent? snapshotGamepad(int index) => null;

  /// Request OS motion-sensor permission where one is required (iOS 13+, and
  /// iOS-Safari web from a user gesture). No-op / already-granted elsewhere.
  /// Returns true if motion may be captured. Default: true.
  Future<bool> requestMotionPermission() async => true;

  /// Stop input capture.
  Future<void> stopCapture();

  /// Destroy this input context and release resources.
  Future<void> destroy();
}
