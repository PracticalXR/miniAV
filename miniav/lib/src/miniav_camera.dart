import 'package:miniav_platform_interface/miniav_platform_interface.dart';

/// Camera capture functionality wrapper
class MiniCamera {
  MiniCamera();

  static MiniCameraPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance.camera;

  /// Enumerate available camera devices
  static Future<List<MiniAVDeviceInfo>> enumerateDevices() =>
      _platform.enumerateDevices();

  /// Get supported video formats for a camera device
  static Future<List<MiniAVVideoInfo>> getSupportedFormats(String deviceId) =>
      _platform.getSupportedFormats(deviceId);

  /// Get default video format for a camera device
  static Future<MiniAVVideoInfo> getDefaultFormat(String deviceId) =>
      _platform.getDefaultFormat(deviceId);

  /// Create a camera capture context
  static Future<MiniCameraContext> createContext() async {
    final context = await _platform.createContext();
    return MiniCameraContext._(context);
  }

  /// Subscribe to camera-device add/remove notifications.
  /// Returns a disposer that must be called to unsubscribe.
  static void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _platform.addDeviceChangeListener(listener);
}

/// Camera capture context for configuration and capture operations
class MiniCameraContext {
  final MiniCameraContextPlatformInterface _context;

  MiniCameraContext._(this._context);

  /// Configure the camera with a device and video format
  Future<void> configure(String deviceId, MiniAVVideoInfo format) =>
      _context.configure(deviceId, format);

  /// Get the currently configured video format
  Future<MiniAVVideoInfo> getConfiguredFormat() =>
      _context.getConfiguredFormat();

  /// Start camera capture
  /// [onFrame] callback is called for each captured frame
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  }) => _context.startCapture(onFrame, userData: userData);

  /// Stop camera capture
  Future<void> stopCapture() => _context.stopCapture();

  /// Destroy the context and release resources
  Future<void> destroy() => _context.destroy();

  /// Subscribe to a context-lost notification (e.g. the camera being captured
  /// was unplugged or otherwise became unavailable). Fired from a capture
  /// thread; do NOT call [destroy] synchronously from inside the listener.
  /// Returns a disposer that must be called to unsubscribe.
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      _context.addLostListener(listener);
}
