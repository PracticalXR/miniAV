/// First-party OS AAC backend (Windows) — Media Foundation AAC decode + encode,
/// FFmpeg-free. Preferred over FFmpeg for AAC on Windows; `open` returns `null`
/// when no MFT is available or the thread is STA, so the negotiator falls
/// through to FFmpeg (never worse than the status quo). libfdk-aac is banned
/// (GPL); the OS MFT is license-clean.
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'mf_aac_decoder.dart';
import 'mf_aac_encoder.dart';

class AacBackend extends MiniAVToolsBackend {
  static const String backendName = 'mf_aac';

  /// Above FFmpeg (50) so OS AAC is preferred on Windows.
  static const int defaultPriority = 55;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) =>
      Platform.isWindows && codec == AudioCodec.aac;

  @override
  bool supportsAudioDecode(AudioCodec codec) =>
      Platform.isWindows && codec == AudioCodec.aac;

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
  }) => MfAacDecoder.open(config);

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) => MfAacEncoder.open(config);

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
