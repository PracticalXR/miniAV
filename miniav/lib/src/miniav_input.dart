import 'package:miniav_platform_interface/miniav_platform_interface.dart';

/// Input capture functionality wrapper
class MiniInput {
  MiniInput();

  static MiniInputPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance.input;

  /// Enumerate available gamepad devices
  static Future<List<MiniAVDeviceInfo>> enumerateGamepads() =>
      _platform.enumerateGamepads();

  /// Create an input capture context
  static Future<MiniInputContext> createContext() async {
    final context = await _platform.createContext();
    return MiniInputContext._(context);
  }

  /// Subscribe to gamepad add/remove notifications.
  /// Returns a disposer that must be called to unsubscribe.
  static void Function() addGamepadChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _platform.addGamepadChangeListener(listener);

  /// Request OS motion-sensor permission (iOS 13+ / iOS-Safari web). On iOS
  /// Safari this MUST be awaited as the first statement of a user-gesture
  /// handler (e.g. the "enter room" tap) — before creating a context — so the
  /// user-activation is still live. No-op / already-granted elsewhere. Returns
  /// true if motion may be captured; a false / denied result should be treated
  /// as "motion off" (the reduced-motion path), not an error.
  static Future<bool> requestMotionPermission() =>
      _platform.requestMotionPermission();
}

/// Input capture context for configuration and capture operations
class MiniInputContext {
  final MiniInputContextPlatformInterface _context;

  MiniInputContext._(this._context);

  /// Configure the input capture with the given config.
  /// Must be called before [startCapture].
  Future<void> configure(MiniAVInputConfig config) =>
      _context.configure(config);

  /// Start input capture.
  /// Provide callbacks for each input type you want to receive.
  Future<void> startCapture({
    void Function(MiniAVKeyboardEvent event, Object? userData)? onKeyboard,
    void Function(MiniAVMouseEvent event, Object? userData)? onMouse,
    void Function(MiniAVGamepadEvent event, Object? userData)? onGamepad,
    void Function(MiniAVMotionEvent event, Object? userData)? onMotion,
    Object? userData,
  }) => _context.startCapture(
    onKeyboard: onKeyboard,
    onMouse: onMouse,
    onGamepad: onGamepad,
    onMotion: onMotion,
    userData: userData,
  );

  /// Latest IMU/motion sample (pull surface for a parallax/render loop), or
  /// null. See [MiniAVMotionEvent].
  MiniAVMotionEvent? latestMotion() => _context.latestMotion();

  /// Snapshot of gamepad [index] (pull surface for a game tick), or null.
  MiniAVGamepadEvent? snapshotGamepad(int index) =>
      _context.snapshotGamepad(index);

  /// Request OS motion-sensor permission (iOS 13+ / iOS-Safari web, from a user
  /// gesture); no-op / already-granted elsewhere. True if motion may capture.
  Future<bool> requestMotionPermission() => _context.requestMotionPermission();

  /// Stop input capture
  Future<void> stopCapture() => _context.stopCapture();

  /// Destroy the context and release resources
  Future<void> destroy() => _context.destroy();
}
