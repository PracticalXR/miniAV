/// minigpu compute-shader codec backend.
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'av1/minigpu_av1_pipeline.dart';
import 'av1/mp4/av1_mp4_muxer.dart';
import 'gpu_codec_pipeline.dart';
import 'minigpu_mjpeg_pipeline.dart';

class MinigpuBackend extends MiniAVToolsBackend {
  static const String backendName = 'minigpu';
  static const int defaultPriority = 30;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  // MJPEG: fully working GPU pipeline.
  // AV1: Phase 0 skeleton — bitstream framing + MP4 muxer only.
  static const _encodeCodecs = <VideoCodec>{VideoCodec.mjpeg, VideoCodec.av1};
  static const _muxContainers = <Container>{Container.mp4};

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) =>
      _encodeCodecs.contains(codec);

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;
  @override
  bool supportsAudioDecode(AudioCodec codec) => false;

  @override
  bool supportsMux(Container container) => _muxContainers.contains(container);
  @override
  bool supportsDemux(Container container) => false;

  /// minigpu can natively consume miniav GPU buffers in zero-copy fashion
  /// once the WGSL textures are wired up.
  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {
    FrameSourceKind.cpu,
    FrameSourceKind.miniavBufferCpu,
    FrameSourceKind.gpuTexture,
  };

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async {
    if (!_encodeCodecs.contains(config.codec)) return null;
    switch (config.codec) {
      case VideoCodec.mjpeg:
        return GpuCodecEncoder(MinigpuMjpegPipeline(config: config));
      case VideoCodec.av1:
        return GpuCodecEncoder(MinigpuAv1Pipeline(config: config));
      default:
        return null;
    }
  }

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async {
    if (!_muxContainers.contains(config.container)) return null;
    switch (config.container) {
      case Container.mp4:
        return Av1Mp4Muxer(config);
      default:
        return null;
    }
  }

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}
