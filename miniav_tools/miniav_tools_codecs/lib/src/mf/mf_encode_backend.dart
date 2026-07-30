/// First-party Media Foundation H.264/HEVC video-encode backend (Windows).
///
/// Priority 45 (BELOW FFmpeg's 50) for now: this first cut is the sync software
/// MF encoder with CPU-NV12 input only, so it's opt-in (via
/// `BackendPreference.excluded({'ffmpeg'})`) rather than the default — it won't
/// disturb the recorder's mature FFmpeg encode path. Bump the priority once the
/// D3D11 zero-copy + hardware/async + isolate-host follow-ups land.
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'mf_video_encoder.dart';

class MfEncodeBackend extends MiniAVToolsBackend {
  static const String backendName = 'mf_encode';
  static const int defaultPriority = 45;

  static const _codecs = {VideoCodec.h264, VideoCodec.hevc};

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) =>
      Platform.isWindows && !hwAccel && _codecs.contains(codec);

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;

  @override
  bool supportsAudioDecode(AudioCodec codec) => false;

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources =>
      const {FrameSourceKind.cpu, FrameSourceKind.miniavBufferCpu};

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) => MfVideoEncoder.open(config);

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
