import 'dart:typed_data';

import '../miniav_platform_types.dart';

/// Abstract interface for audio output (playback / speaker) functionality.
///
/// This is a first-party PCM *sink*: it accepts interleaved float32 PCM and
/// plays it through the system output device, on native (miniaudio via FFI)
/// and web (miniaudio compiled to WASM) alike. Compressed-audio decode lives
/// in `miniav_tools` (WebCodecs / FFmpeg) which already emits the canonical
/// interleaved-f32 layout consumed here.
abstract class MiniAudioOutputPlatformInterface {
  /// Enumerate available audio output (speaker/headphone) devices.
  Future<List<MiniAVDeviceInfo>> enumerateDevices();

  /// Native default output format for a device (`deviceId` empty = default).
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId);

  /// Create an audio output (playback) context.
  Future<MiniAudioOutputContextPlatformInterface> createContext();

  /// Subscribe to audio output device add/remove notifications.
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => throw UnsupportedError('Device-change subscription not supported.');
}

/// Abstract audio output context: configure a sink, push PCM, control it.
///
/// Lifecycle: create → configure → start → writeFrames* → (stop/clear) →
/// destroy. Controls (volume/pan/pitch) may be set before or after configure;
/// they persist across re-configure.
abstract class MiniAudioOutputContextPlatformInterface {
  /// Configure the output stream. `format` describes the PCM you will push
  /// (float32 is the canonical layout). `bufferFrames` is the ring depth
  /// (0 = ~100 ms at the format's sample rate).
  Future<void> configure(
    String deviceId,
    MiniAVAudioInfo format, {
    int bufferFrames = 0,
  });

  /// The configured stream format.
  Future<MiniAVAudioInfo> getConfiguredFormat();

  /// Begin playback. On web this resumes the AudioContext, so call it from a
  /// user gesture (e.g. a Play button) to satisfy autoplay policy.
  Future<void> start();

  /// Pause playback. Queued samples remain buffered; [start] resumes.
  Future<void> stop();

  /// Drop all queued samples (flush / seek).
  Future<void> clear();

  /// Push interleaved float32 PCM. Returns the number of frames accepted,
  /// which may be less than [frameCount] when the ring is full (the caller
  /// drops the remainder in live mode, or retries after a short delay in
  /// paced mode). Synchronous — this is the per-chunk hot path.
  int writeFrames(Float32List interleaved, int frameCount);

  /// Frames currently queued (readable) in the ring.
  int get bufferedFrames;

  /// Free space (writable frames) in the ring.
  int get writableFrames;

  /// Master gain: 0.0 = silence, 1.0 = unity (may exceed 1).
  double get volume;
  set volume(double value);

  /// Stereo pan: -1.0 = left, 0.0 = center, +1.0 = right.
  double get pan;
  set pan(double value);

  /// Playback rate / pitch: 1.0 = normal (alters speed and pitch).
  double get pitch;
  set pitch(double value);

  /// Whether playback is currently running.
  bool get isStarted;

  /// Destroy this context and release resources.
  Future<void> destroy();

  /// Subscribe to a one-shot lost notification (output device removed).
  void Function() addLostListener(MiniAVContextLostListener listener) =>
      throw UnsupportedError('Context-lost subscription not supported.');
}
