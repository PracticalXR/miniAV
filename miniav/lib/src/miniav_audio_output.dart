import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';

/// Audio output (playback / speaker) functionality wrapper.
///
/// A first-party PCM sink: push interleaved float32 PCM and it plays through
/// the system output device — miniaudio via FFI on native, miniaudio compiled
/// to WASM on web. Decode compressed audio with `miniav_tools` (which emits
/// the interleaved-f32 layout this consumes) and feed the samples straight in.
class MiniAudioOutput {
  MiniAudioOutput();

  static MiniAudioOutputPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance.audioOutput;

  /// Enumerate available audio output devices.
  static Future<List<MiniAVDeviceInfo>> enumerateDevices() =>
      _platform.enumerateDevices();

  /// Get the default output format for a device (empty id = system default).
  static Future<MiniAVAudioInfo> getDefaultFormat(String deviceId) =>
      _platform.getDefaultFormat(deviceId);

  /// Create an audio output (playback) context.
  static Future<MiniAudioOutputContext> createContext() async {
    final context = await _platform.createContext();
    return MiniAudioOutputContext._(context);
  }

  /// Subscribe to audio output device add/remove notifications.
  static void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _platform.addDeviceChangeListener(listener);
}

/// Audio output context: configure a sink, push PCM, and control playback.
class MiniAudioOutputContext {
  final MiniAudioOutputContextPlatformInterface _context;

  MiniAudioOutputContext._(this._context);

  /// Configure the output stream. [format] describes the PCM you will push
  /// (float32 interleaved). [bufferFrames] is the ring depth (0 = ~100 ms).
  Future<void> configure(
    String deviceId,
    MiniAVAudioInfo format, {
    int bufferFrames = 0,
  }) => _context.configure(deviceId, format, bufferFrames: bufferFrames);

  /// The currently configured stream format.
  Future<MiniAVAudioInfo> getConfiguredFormat() =>
      _context.getConfiguredFormat();

  /// Begin playback. On web, call from a user gesture (autoplay policy).
  Future<void> start() => _context.start();

  /// Pause playback (queued samples remain buffered).
  Future<void> stop() => _context.stop();

  /// Drop all queued samples (flush / seek).
  Future<void> clear() => _context.clear();

  /// Push interleaved float32 PCM. Returns frames accepted (may be less than
  /// [frameCount] when the ring is full). Synchronous hot path.
  int writeFrames(Float32List interleaved, int frameCount) =>
      _context.writeFrames(interleaved, frameCount);

  /// Frames currently queued in the ring.
  int get bufferedFrames => _context.bufferedFrames;

  /// Free (writable) frames in the ring.
  int get writableFrames => _context.writableFrames;

  /// Master gain: 0.0 = silence, 1.0 = unity.
  double get volume => _context.volume;
  set volume(double value) => _context.volume = value;

  /// Stereo pan: -1.0 left … +1.0 right.
  double get pan => _context.pan;
  set pan(double value) => _context.pan = value;

  /// Playback rate / pitch: 1.0 = normal.
  double get pitch => _context.pitch;
  set pitch(double value) => _context.pitch = value;

  /// Whether playback is currently running.
  bool get isStarted => _context.isStarted;

  /// Destroy the context and release resources.
  Future<void> destroy() => _context.destroy();

  /// Subscribe to a context-lost notification (output device removed).
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      _context.addLostListener(listener);
}
