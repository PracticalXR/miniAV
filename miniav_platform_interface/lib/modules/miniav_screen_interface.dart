import '../miniav_platform_types.dart';

/// Abstract interface for screen capture functionality on all platforms.
abstract class MiniScreenPlatformInterface {
  /// Enumerate available displays
  Future<List<MiniAVDeviceInfo>> enumerateDisplays();

  /// Enumerate available windows
  Future<List<MiniAVDeviceInfo>> enumerateWindows();

  /// Get default formats for display and loopback devices.
  Future<ScreenFormatDefaults> getDefaultFormats(String displayId);

  /// Create a screen capture context (for capture/configuration).
  Future<MiniScreenContextPlatformInterface> createContext();

  /// Subscribe to display add/remove notifications.
  void Function() addDisplayChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Display-change subscription not supported.');

  /// Subscribe to window add/remove notifications.
  void Function() addWindowChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Window-change subscription not supported.');

  /// iOS only: register the App Group ID shared between the app and its
  /// Broadcast Upload Extension. Must be called before configuring the
  /// `system_screen_broadcast` pseudo-display. On every other platform the
  /// native layer reports not-supported.
  Future<void> setIOSAppGroup(String appGroupId) =>
      throw UnsupportedError('setIOSAppGroup is only available on iOS.');
}

/// Abstract screen context for configuring and capturing from a screen or window.
abstract class MiniScreenContextPlatformInterface {
  /// Configure the screen context with a display and format.
  Future<void> configureDisplay(
    String screenId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  });

  /// Configure the screen context with a window and format.
  Future<void> configureWindow(
    String windowId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  });

  Future<ScreenFormatDefaults> getConfiguredFormats();

  /// Include the mouse cursor in captured frames (off by default). Must be
  /// called BEFORE configuring the display/window. Honored on Windows WGC,
  /// macOS ScreenCaptureKit, and Linux PipeWire; Windows DXGI cannot draw the
  /// cursor and stays cursor-less.
  Future<void> setCaptureCursor(bool enabled) =>
      throw UnsupportedError('setCaptureCursor is not supported.');

  /// Start screen capture.
  /// [onFrame] is called for each frame received.
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  });

  /// Stop screen capture.
  Future<void> stopCapture();

  /// Destroy this screen context and release resources.
  Future<void> destroy();

  /// Subscribe to a one-shot lost notification (e.g. the captured display
  /// was disconnected or the captured window was closed).
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      throw UnsupportedError('Context-lost subscription not supported.');
}
