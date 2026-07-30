part of '../miniav_web.dart';

/// Web implementation of [MiniLoopbackPlatformInterface]
class MiniAVWebLoopbackPlatform implements MiniLoopbackPlatformInterface {
  @override
  void Function() addDeviceChangeListener(MiniAVDeviceChangeListener listener) {
    // Web doesn't support loopback capture; no devices to notify about.
    return () {};
  }

  @override
  Future<List<MiniAVDeviceInfo>> enumerateDevices() async {
    // Web doesn't support system audio loopback capture
    return [];
  }

  @override
  Future<MiniAVAudioInfo> getDefaultFormat(String targetId) async {
    // Web doesn't support system audio loopback capture
    throw UnsupportedError(
      'Loopback audio capture not supported on web platform',
    );
  }

  @override
  Future<MiniLoopbackContextPlatformInterface> createContext() async {
    throw UnsupportedError(
      'Loopback audio capture not supported on web platform',
    );
  }
}

/// Web stub for [MiniLoopbackContextPlatformInterface] (not actually used)
class MiniAVWebLoopbackContext implements MiniLoopbackContextPlatformInterface {
  @override
  void Function() addLostListener(MiniAVContextLostListener listener) {
    return () {};
  }

  @override
  Future<void> configure(String targetId, MiniAVAudioInfo format) async {
    throw UnsupportedError(
      'Loopback audio capture not supported on web platform',
    );
  }

  @override
  Future<MiniAVAudioInfo> getConfiguredFormat() async {
    throw UnsupportedError(
      'Loopback audio capture not supported on web platform',
    );
  }

  @override
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, dynamic userData) onData, {
    dynamic userData,
  }) async {
    throw UnsupportedError(
      'Loopback audio capture not supported on web platform',
    );
  }

  @override
  Future<void> stopCapture() async {
    // No-op since capture is not supported
  }

  @override
  Future<void> destroy() async {
    // No-op since no resources to clean up
  }
}
