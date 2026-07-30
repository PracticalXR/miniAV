/// Builder that captures recording configuration: sources + sinks + global
/// options. Compose then call [build] to get a [Recorder].
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'clip_buffer.dart';
import 'recorder.dart';
import 'recorder_sink.dart';
import 'recorder_source.dart';

export 'audio_effect.dart';
export 'screen_effect.dart';
export 'screen_scale_policy.dart';
export 'recorder_source.dart' show VideoIdleFramePolicy;

class RecorderBuilder {
  final List<RecorderSource> _sources = [];
  final List<RecorderSink> _sinks = [];

  /// Default video encoder bitrate (bits/sec) when a source doesn't override.
  int defaultVideoBitrate = 6_000_000;

  /// Default audio encoder bitrate (bits/sec) when a source doesn't override.
  int defaultAudioBitrate = 128_000;

  /// Default frame-rate hint passed to video encoders. Capture sources may
  /// supply a different actual rate.
  int defaultFrameRate = 30;

  /// Backend preference (forwarded to [MiniAVTools.createEncoder] /
  /// [MiniAVTools.createAudioEncoder]).
  BackendPreference backendPreference = BackendPreference.auto;

  /// When true (and at least one source benefits, e.g. screen capture on
  /// Windows with HW encoding), the recorder spins up a shared GPU device
  /// and asks backends to use a zero-copy data path. Backends fall back
  /// to the regular CPU upload path on any failure, so this is safe to
  /// leave on. Defaults to `true`.
  bool preferZeroCopy = true;

  // --- sources -------------------------------------------------------------

  /// Add a screen / display source.
  ///
  /// If [displayId] is null, the platform's default display is used.
  /// [codec] defaults to H.264. Provide [width]/[height]/[fps] to override
  /// the platform default capture format.
  ///
  /// [scale] controls optional GPU downscaling before encoding.
  /// [ScreenScalePolicy.h264Friendly] is recommended for ultrawide / 4K+
  /// displays — it auto-downscales so H.264 HW stays in range (max dim ≤ 4096)
  /// without the automatic HEVC codec promotion.
  ///
  /// [effects] is an ordered list of GPU post-processing effects applied after
  /// downscaling. All effects run on the GPU (WGSL compute shaders) with no
  /// CPU copy. Requires the zero-copy GPU path; silently ignored otherwise.
  void addScreen({
    String? displayId,
    String? windowId,
    VideoCodec codec = VideoCodec.h264,
    int? bitrateBps,
    int? width,
    int? height,
    int? fps,
    HwAccelPreference hwAccel = HwAccelPreference.preferred,
    ScreenScalePolicy scale = ScreenScalePolicy.none,
    List<ScreenEffect> effects = const [],
    double? quality,
    Map<String, String> encoderOptions = const {},
    VideoIdleFramePolicy idleFramePolicy = VideoIdleFramePolicy.duplicate,
    bool adaptiveGpuThrottle = true,
    bool cfrOutput = false,
  }) {
    _sources.add(
      ScreenRecorderSource(
        displayId: displayId,
        windowId: windowId,
        codec: codec,
        bitrateBps: bitrateBps,
        width: width,
        height: height,
        fps: fps,
        hwAccel: hwAccel,
        scale: scale,
        effects: effects,
        quality: quality,
        encoderOptions: encoderOptions,
        idleFramePolicy: idleFramePolicy,
        adaptiveGpuThrottle: adaptiveGpuThrottle,
        cfrOutput: cfrOutput,
      ),
    );
  }

  /// Add a camera source.
  void addCamera({
    required String deviceId,
    VideoCodec codec = VideoCodec.h264,
    int? bitrateBps,
    int? width,
    int? height,
    int? fps,
    HwAccelPreference hwAccel = HwAccelPreference.preferred,
    double? quality,
    Map<String, String> encoderOptions = const {},
    VideoIdleFramePolicy idleFramePolicy = VideoIdleFramePolicy.none,
  }) {
    _sources.add(
      CameraRecorderSource(
        deviceId: deviceId,
        codec: codec,
        bitrateBps: bitrateBps,
        width: width,
        height: height,
        fps: fps,
        hwAccel: hwAccel,
        quality: quality,
        encoderOptions: encoderOptions,
        idleFramePolicy: idleFramePolicy,
      ),
    );
  }

  /// Add a microphone source.
  void addMic({
    required String deviceId,
    AudioCodec codec = AudioCodec.aac,
    int? bitrateBps,
    int? sampleRate,
    int? channels,
  }) {
    _sources.add(
      MicRecorderSource(
        deviceId: deviceId,
        codec: codec,
        bitrateBps: bitrateBps,
        sampleRate: sampleRate,
        channels: channels,
      ),
    );
  }

  /// Add a system-loopback source (records what's currently being played).
  void addLoopback({
    required String deviceId,
    AudioCodec codec = AudioCodec.aac,
    int? bitrateBps,
    int? sampleRate,
    int? channels,
  }) {
    _sources.add(
      LoopbackRecorderSource(
        deviceId: deviceId,
        codec: codec,
        bitrateBps: bitrateBps,
        sampleRate: sampleRate,
        channels: channels,
      ),
    );
  }

  /// Add a **mixed** mic + loopback source.
  ///
  /// Both inputs are captured simultaneously, normalised to 48 kHz / stereo /
  /// float32, summed, and emitted as **one** audio track. Most players (and
  /// browsers, and Windows shell preview) only auto-play the first audio
  /// track, so mixing is usually what you want for screen-recordings with
  /// commentary.
  ///
  /// Use [micGainDb] / [loopbackGainDb] (in dB) to attenuate either source
  /// before the sum — pass `-3` to each if you hear clipping when both are
  /// loud at the same time.
  ///
  /// [micEffects] / [loopbackEffects] are [AudioEffect] chains applied to
  /// each source (after its gain) before the sum; [masterEffects] runs on
  /// the summed mix just before encoding. Typical setup for "mic much
  /// louder than the game" plus keyboard noise:
  ///
  /// ```dart
  /// builder.addMixedAudio(
  ///   micDeviceId: mic, loopbackDeviceId: loop,
  ///   micEffects: AudioEffect.voiceChain(),          // HPF + gate + AGC
  ///   loopbackEffects: [AudioEffect.autoLevel()],    // match loudness
  ///   masterEffects: [AudioEffect.limiter()],        // transparent ceiling
  /// );
  /// ```
  void addMixedAudio({
    required String micDeviceId,
    required String loopbackDeviceId,
    AudioCodec codec = AudioCodec.aac,
    int? bitrateBps,
    double micGainDb = 0.0,
    double loopbackGainDb = 0.0,
    List<AudioEffect> micEffects = const [],
    List<AudioEffect> loopbackEffects = const [],
    List<AudioEffect> masterEffects = const [],
  }) {
    _sources.add(
      MixedAudioRecorderSource(
        micDeviceId: micDeviceId,
        loopbackDeviceId: loopbackDeviceId,
        codec: codec,
        bitrateBps: bitrateBps,
        micGainDb: micGainDb,
        loopbackGainDb: loopbackGainDb,
        micEffects: micEffects,
        loopbackEffects: loopbackEffects,
        masterEffects: masterEffects,
      ),
    );
  }

  // --- sinks ---------------------------------------------------------------

  /// Mux every source's encoded packets into a container file.
  ///
  /// If [container] is omitted the recorder infers it in order:
  /// 1. File extension (`.mp4` → MP4, `.mkv` → MKV, `.webm` → WebM, etc.)
  /// 2. Track-mix heuristic: video-only → MP4; video+audio → MKV (handles
  ///    any codec mix); audio-only → M4A/MP3/OGG/MKV based on codec.
  ///
  /// Prefer naming your output file with the correct extension (e.g.
  /// `recording.mp4`) so the right container is selected automatically.
  void addFileOutput(String path, {Container? container}) {
    _sinks.add(FileRecorderSink(path: path, container: container));
  }

  /// Receive a [TrackChunk] for every encoded packet from every source.
  /// Useful for live streaming / network forwarding without an on-disk
  /// container.
  void addStreamOutput(void Function(Object chunk) onChunk) {
    _sinks.add(StreamRecorderSink(onChunk: onChunk));
  }

  /// Attach a [ClipBuffer] that silently accumulates the last [maxWindow] of
  /// encoded data. Call [ClipBuffer.saveClip] at any time with any
  /// [Duration] ≤ [maxWindow] to write a clip without interrupting the
  /// running recorder.
  ///
  /// Size [maxWindow] to the longest clip you will ever want. You can then
  /// call `saveClip` multiple times with different durations from the same
  /// buffer:
  ///
  /// ```dart
  /// final clip = builder.addClipBuffer(maxWindow: Duration(minutes: 3));
  /// final rec = builder.build();
  /// await rec.start();
  ///
  /// // Save different lengths from the same 3-minute buffer:
  /// await clip.saveClip('clip_5s.mp4',  duration: Duration(seconds: 5));
  /// await clip.saveClip('clip_30s.mp4', duration: Duration(seconds: 30));
  /// await clip.saveClip('clip_full.mp4');  // full 3 min
  /// ```
  ///
  /// [maxPackets] is an optional hard cap on buffered packet count.
  ClipBuffer addClipBuffer({
    required Duration maxWindow,
    int? maxPackets,
    PlatformMuxer Function(MuxerConfig)? muxerFactory,
  }) {
    final buf = ClipBuffer(
      maxWindow: maxWindow,
      maxPackets: maxPackets,
      muxerFactory: muxerFactory,
    );
    _sinks.add(StreamRecorderSink(onChunk: buf.onChunk));
    return buf;
  }

  // --- build ---------------------------------------------------------------

  Recorder build() {
    if (_sources.isEmpty) {
      throw StateError(
        'RecorderBuilder.build: no sources — call addScreen/addCamera/'
        'addMic/addLoopback first.',
      );
    }
    if (_sinks.isEmpty) {
      throw StateError(
        'RecorderBuilder.build: no sinks — call addFileOutput / '
        'addStreamOutput first.',
      );
    }
    return Recorder.internal(
      sources: List.unmodifiable(_sources),
      sinks: List.unmodifiable(_sinks),
      defaultVideoBitrate: defaultVideoBitrate,
      defaultAudioBitrate: defaultAudioBitrate,
      defaultFrameRate: defaultFrameRate,
      backendPreference: backendPreference,
      preferZeroCopy: preferZeroCopy,
    );
  }
}
