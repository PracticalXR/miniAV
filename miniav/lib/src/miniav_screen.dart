import 'package:miniav_platform_interface/miniav_platform_interface.dart';

/// Screen capture functionality wrapper
class MiniScreen {
  MiniScreen();

  static MiniScreenPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance.screen;

  /// Enumerate available display devices
  static Future<List<MiniAVDeviceInfo>> enumerateDisplays() =>
      _platform.enumerateDisplays();

  /// Enumerate available windows
  static Future<List<MiniAVDeviceInfo>> enumerateWindows() =>
      _platform.enumerateWindows();

  /// Get default formats for screen capture
  static Future<ScreenFormatDefaults> getDefaultFormats(String displayId) =>
      _platform.getDefaultFormats(displayId);

  /// Create a screen capture context
  static Future<MiniScreenContext> createContext() async {
    final context = await _platform.createContext();
    return MiniScreenContext._(context);
  }

  /// Subscribe to display add/remove notifications.
  /// Returns a disposer that must be called to unsubscribe.
  static void Function() addDisplayChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _platform.addDisplayChangeListener(listener);

  /// Subscribe to window add/remove notifications.
  /// Returns a disposer that must be called to unsubscribe.
  static void Function() addWindowChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _platform.addWindowChangeListener(listener);

  /// iOS only: register the App Group ID shared between the app and its
  /// Broadcast Upload Extension (e.g. `group.com.example.yourapp`).
  ///
  /// Must be called before configuring the `system_screen_broadcast`
  /// pseudo-display. See the README's iOS Permissions section and
  /// `miniav_c/src/screen/ios/broadcast_extension/SETUP.md` for the full
  /// extension setup. Throws on every other platform.
  static Future<void> setIOSAppGroup(String appGroupId) =>
      _platform.setIOSAppGroup(appGroupId);
}

/// Screen capture context for configuration and capture operations
class MiniScreenContext {
  final MiniScreenContextPlatformInterface _context;

  MiniScreenContext._(this._context);

  /// Configure screen capture for a display
  Future<void> configureDisplay(
    String screenId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  }) => _context.configureDisplay(screenId, format, captureAudio: captureAudio);

  /// Configure screen capture for a window
  Future<void> configureWindow(
    String windowId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  }) => _context.configureWindow(windowId, format, captureAudio: captureAudio);

  /// Include the mouse cursor in captured frames (off by default). Call BEFORE
  /// [configureDisplay] / [configureWindow]. Honored on Windows WGC, macOS
  /// ScreenCaptureKit, and Linux PipeWire; Windows DXGI cannot draw the cursor
  /// and captures cursor-less (use the WGC backend for a visible cursor).
  Future<void> setCaptureCursor(bool enabled) =>
      _context.setCaptureCursor(enabled);

  /// Get the currently configured formats
  Future<ScreenFormatDefaults> getConfiguredFormats() =>
      _context.getConfiguredFormats();

  /// Start screen capture
  /// [onFrame] callback is called for each captured frame
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  }) => _context.startCapture(onFrame, userData: userData);

  /// Stop screen capture
  Future<void> stopCapture() => _context.stopCapture();

  /// Destroy the context and release resources
  Future<void> destroy() => _context.destroy();

  /// Subscribe to a context-lost notification (e.g. captured display
  /// disconnected, captured window closed). Fired from a capture thread; do
  /// NOT call [destroy] synchronously from inside the listener. Returns a
  /// disposer that must be called to unsubscribe.
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      _context.addLostListener(listener);
}
