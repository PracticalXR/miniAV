import '../miniav_platform_types.dart';

/// Abstract interface for loopback (system audio output) capture functionality.
abstract class MiniLoopbackPlatformInterface {
  /// Enumerate available loopback (output) devices.
  Future<List<MiniAVDeviceInfo>> enumerateDevices();

  /// Get supported audio formats for a given loopback device.
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId);

  /// Create a loopback capture context.
  Future<MiniLoopbackContextPlatformInterface> createContext();

  /// Subscribe to loopback target add/remove notifications.
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Device-change subscription not supported.');
}

/// Abstract loopback context for configuring and capturing system audio output.
abstract class MiniLoopbackContextPlatformInterface {
  /// Configure the loopback context with a device and format.
  Future<void> configure(String deviceId, MiniAVAudioInfo format);

  /// Get the configured format.
  Future<MiniAVAudioInfo> getConfiguredFormat();

  /// Start loopback capture.
  /// [onData] is called for each audio buffer received.
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onData, {
    Object? userData,
  });

  /// Stop loopback capture.
  Future<void> stopCapture();

  /// Destroy this loopback context and release resources.
  Future<void> destroy();

  /// Subscribe to a one-shot lost notification (rendering endpoint removed,
  /// process target ended, etc.).
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      throw UnsupportedError('Context-lost subscription not supported.');
}
