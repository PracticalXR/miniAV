import '../miniav_platform_types.dart';

/// Abstract interface for camera functionality on all platforms.
abstract class MiniCameraPlatformInterface {
  /// Enumerate available camera devices.
  Future<List<MiniAVDeviceInfo>> enumerateDevices();

  /// Get supported video formats for a given device.
  Future<List<MiniAVVideoInfo>> getSupportedFormats(String deviceId);

  /// Get supported audio formats for a given device.
  Future<MiniAVVideoInfo> getDefaultFormat(String deviceId);

  /// Create a camera context (for capture/configuration).
  Future<MiniCameraContextPlatformInterface> createContext();

  /// Subscribe to camera-device add/remove notifications. The returned
  /// disposer must be called to unsubscribe.
  /// Default implementation throws [UnsupportedError]; platform
  /// implementations should override.
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Device-change subscription not supported.');
}

/// Abstract camera context for configuring and capturing from a camera.
abstract class MiniCameraContextPlatformInterface {
  /// Configure the camera context with a device and format.
  Future<void> configure(String deviceId, MiniAVVideoInfo format);

  Future<MiniAVVideoInfo> getConfiguredFormat();

  /// Start camera capture.
  /// [onFrame] is called for each frame received.
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  });

  /// Stop camera capture.
  Future<void> stopCapture();

  /// Destroy this camera context and release resources.
  Future<void> destroy();

  /// Subscribe to a one-shot lost notification for this context (the device
  /// being captured was unplugged or otherwise became unavailable). The
  /// returned disposer must be called to unsubscribe (or the listener cleans
  /// itself up on context destroy).
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      throw UnsupportedError('Context-lost subscription not supported.');
}
