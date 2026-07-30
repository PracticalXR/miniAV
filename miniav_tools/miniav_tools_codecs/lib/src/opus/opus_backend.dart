/// First-party Opus audio-decode backend (FFmpeg-free, all platforms).
///
/// Reports `supportsAudioDecode(opus)` at a priority above [FfmpegBackend]
/// (50), so the facade's `createAudioDecoder` priority scan picks it over
/// FFmpeg's libopus — giving an Opus decode path with zero FFmpeg in the
/// process. Returns `null` on open failure, so the scan still falls through to
/// FFmpeg (Opus is never worse than the status quo).
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'opus_audio_decoder.dart';
import 'opus_audio_encoder.dart';

class OpusBackend extends MiniAVToolsBackend {
  static const String backendName = 'opus';

  /// Above [FfmpegBackend]'s default (50) so the audio priority scan prefers
  /// this first-party libopus decoder over FFmpeg's.
  static const int defaultPriority = 60;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  // --- Capabilities (Opus audio decode only) --------------------------------

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => codec == AudioCodec.opus;

  @override
  bool supportsAudioDecode(AudioCodec codec) => codec == AudioCodec.opus;

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  // --- Factories ------------------------------------------------------------

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) => OpusAudioDecoder.open(config);

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) => OpusAudioEncoder.open(config);

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}
