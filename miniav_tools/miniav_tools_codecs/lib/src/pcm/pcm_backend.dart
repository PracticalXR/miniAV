/// First-party raw-PCM audio backend (pcmS16le / pcmF32le), pure Dart, all
/// platforms. Fixes the previous state where PCM had NO decode path and
/// FFmpeg's audio codec map threw on it.
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'pcm_audio_decoder.dart';
import 'pcm_audio_encoder.dart';

class PcmBackend extends MiniAVToolsBackend {
  static const String backendName = 'pcm';

  /// Above OpusBackend (60) and FfmpegBackend (50): for raw PCM this trivial
  /// pure-Dart path is always the right choice (and needs no FFmpeg).
  static const int defaultPriority = 70;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  static bool _isPcm(AudioCodec c) =>
      c == AudioCodec.pcmS16le || c == AudioCodec.pcmF32le;

  // --- Capabilities (raw PCM audio, both directions) ------------------------

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => _isPcm(codec);

  @override
  bool supportsAudioDecode(AudioCodec codec) => _isPcm(codec);

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
  }) => PcmAudioDecoder.open(config);

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) => PcmAudioEncoder.open(config);

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
