/// First-party software audio-decode backend: MP3 / FLAC / Vorbis (FFmpeg-free,
/// via dr_mp3 / dr_flac / stb_vorbis in the codecs native asset).
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'sw_audio_decoder.dart';

class SwAudioBackend extends MiniAVToolsBackend {
  static const String backendName = 'sw_audio';

  /// Above FFmpeg (50) so these first-party decoders are preferred for MP3 /
  /// FLAC / Vorbis; open never fails (data arrives later), and these libs are
  /// battle-tested, so no fall-through is needed for the common case.
  static const int defaultPriority = 55;

  static const _codecs = {AudioCodec.mp3, AudioCodec.flac, AudioCodec.vorbis};

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;

  @override
  bool supportsAudioDecode(AudioCodec codec) => _codecs.contains(codec);

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) => SwAudioDecoder.open(config);

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
