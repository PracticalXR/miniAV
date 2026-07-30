/// Configuration objects for encoders, decoders, muxers, and demuxers.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';

import 'codec_types.dart';
import 'packet.dart';

/// Configuration for a video encoder.
class EncoderConfig {
  final VideoCodec codec;

  /// Identity of the codec when [codec] is [VideoCodec.custom] (see the enum
  /// docs — the app-registered backend matches on this name). Ignored for
  /// built-in codecs.
  final String? customCodecName;

  final int width;
  final int height;
  final int bitrateBps;

  /// Keyframe interval in frames. 0 = encoder default.
  final int gopLength;

  final int frameRateNumerator;
  final int frameRateDenominator;

  /// Pixel format the encoder will receive (post-upload). Most hardware
  /// encoders want NV12; software encoders often want YUV420P.
  final MiniAVPixelFormat inputPixelFormat;

  final HwAccelPreference hwAccel;
  final RateControl rateControl;

  /// CRF / ICQ quality (codec-dependent range, typically 0–51).
  final int? crfQuality;

  final EncoderProfile profile;
  final EncoderLevel? level;

  /// Maximum number of B-frames between P-frames. 0 disables.
  final int bFrameCount;

  /// Backend-specific options as key-value strings (e.g. NVENC `preset=p4`).
  final Map<String, String> backendOptions;

  const EncoderConfig({
    required this.codec,
    this.customCodecName,
    required this.width,
    required this.height,
    required this.bitrateBps,
    this.gopLength = 0,
    this.frameRateNumerator = 30,
    this.frameRateDenominator = 1,
    this.inputPixelFormat = MiniAVPixelFormat.nv12,
    this.hwAccel = HwAccelPreference.preferred,
    this.rateControl = RateControl.vbr,
    this.crfQuality,
    this.profile = EncoderProfile.high,
    this.level,
    this.bFrameCount = 0,
    this.backendOptions = const {},
  });

  /// Returns a copy with the given fields replaced. Used by backends that
  /// must adjust the requested codec/resolution to something the loaded
  /// encoder build can actually produce (e.g. downscaling a >4096px capture
  /// and switching to H.264 when no HEVC encoder is available).
  EncoderConfig copyWith({
    VideoCodec? codec,
    String? customCodecName,
    int? width,
    int? height,
    int? bitrateBps,
    int? gopLength,
    int? frameRateNumerator,
    int? frameRateDenominator,
    MiniAVPixelFormat? inputPixelFormat,
    HwAccelPreference? hwAccel,
    RateControl? rateControl,
    int? crfQuality,
    EncoderProfile? profile,
    EncoderLevel? level,
    int? bFrameCount,
    Map<String, String>? backendOptions,
  }) {
    return EncoderConfig(
      codec: codec ?? this.codec,
      customCodecName: customCodecName ?? this.customCodecName,
      width: width ?? this.width,
      height: height ?? this.height,
      bitrateBps: bitrateBps ?? this.bitrateBps,
      gopLength: gopLength ?? this.gopLength,
      frameRateNumerator: frameRateNumerator ?? this.frameRateNumerator,
      frameRateDenominator: frameRateDenominator ?? this.frameRateDenominator,
      inputPixelFormat: inputPixelFormat ?? this.inputPixelFormat,
      hwAccel: hwAccel ?? this.hwAccel,
      rateControl: rateControl ?? this.rateControl,
      crfQuality: crfQuality ?? this.crfQuality,
      profile: profile ?? this.profile,
      level: level ?? this.level,
      bFrameCount: bFrameCount ?? this.bFrameCount,
      backendOptions: backendOptions ?? this.backendOptions,
    );
  }
}

/// Configuration for a video decoder.
class DecoderConfig {
  final VideoCodec codec;

  /// Identity of the codec when [codec] is [VideoCodec.custom] (see the enum
  /// docs). Ignored for built-in codecs.
  final String? customCodecName;

  /// Codec-private extra-data (SPS/PPS for H.264, codec-private for VP9, etc.).
  /// Required for some codecs/containers; pass `null` if the bitstream is
  /// self-contained (Annex-B).
  final Uint8List? extraData;

  /// Coded-dims HINT (`null` = unknown). Most decoders read dims from the
  /// bitstream, but some require them up front — the MF HEVC decoder MFT
  /// needs a frame size on its input media type before it will accept any
  /// input at all. Callers that know the track dims (demuxer, wire header)
  /// should pass them; decoders may ignore.
  final int? width;
  final int? height;

  final HwAccelPreference hwAccel;

  /// Preferred output pixel format. Decoder may ignore if not supported.
  final MiniAVPixelFormat outputPixelFormat;

  /// If true, request the decoder to output GPU-resident frames (D3D11
  /// texture, IOSurface, dmabuf) for zero-copy onward processing.
  final bool requestGpuOutput;

  final Map<String, String> backendOptions;

  const DecoderConfig({
    required this.codec,
    this.customCodecName,
    this.extraData,
    this.width,
    this.height,
    this.hwAccel = HwAccelPreference.preferred,
    this.outputPixelFormat = MiniAVPixelFormat.nv12,
    this.requestGpuOutput = false,
    this.backendOptions = const {},
  });

  /// Copy with selected fields overridden. Used by the facade negotiator to
  /// open a chosen capability on its exact path (e.g. force [hwAccel] to match
  /// the ranked capability's HW/SW-ness so the attached capability is honest).
  DecoderConfig copyWith({
    VideoCodec? codec,
    String? customCodecName,
    Uint8List? extraData,
    int? width,
    int? height,
    HwAccelPreference? hwAccel,
    MiniAVPixelFormat? outputPixelFormat,
    bool? requestGpuOutput,
    Map<String, String>? backendOptions,
  }) => DecoderConfig(
    codec: codec ?? this.codec,
    customCodecName: customCodecName ?? this.customCodecName,
    extraData: extraData ?? this.extraData,
    width: width ?? this.width,
    height: height ?? this.height,
    hwAccel: hwAccel ?? this.hwAccel,
    outputPixelFormat: outputPixelFormat ?? this.outputPixelFormat,
    requestGpuOutput: requestGpuOutput ?? this.requestGpuOutput,
    backendOptions: backendOptions ?? this.backendOptions,
  );
}

/// Description of a single track to be written by a muxer.
sealed class TrackInfo {
  const TrackInfo();
}

class VideoTrackInfo extends TrackInfo {
  final VideoCodec codec;
  final int width;
  final int height;
  final int frameRateNumerator;
  final int frameRateDenominator;
  final CodecExtraData? extraData;

  /// Display rotation from the container (MP4 `tkhd` matrix / display-matrix
  /// side data), degrees CLOCKWISE: 0, 90, 180, or 270. Phone-shot video is
  /// commonly stored sideways with 90/270 here. Decoded frames stay in coded
  /// orientation ([width]/[height] are CODED dims); the player/consumer
  /// applies the rotation at present time.
  final int rotationDegrees;

  const VideoTrackInfo({
    required this.codec,
    required this.width,
    required this.height,
    required this.frameRateNumerator,
    required this.frameRateDenominator,
    this.extraData,
    this.rotationDegrees = 0,
  });
}

class AudioTrackInfo extends TrackInfo {
  final AudioCodec codec;
  final int sampleRate;
  final int channels;
  final CodecExtraData? extraData;

  const AudioTrackInfo({
    required this.codec,
    required this.sampleRate,
    required this.channels,
    this.extraData,
  });
}

/// Where a muxer writes its output.
sealed class MuxerOutput {
  const MuxerOutput();

  factory MuxerOutput.file(String path) = FileMuxerOutput;
  factory MuxerOutput.bytes() = BytesMuxerOutput;
  factory MuxerOutput.callback(void Function(Uint8List chunk) onChunk) =
      CallbackMuxerOutput;
}

class FileMuxerOutput extends MuxerOutput {
  final String path;
  const FileMuxerOutput(this.path);
}

class BytesMuxerOutput extends MuxerOutput {
  const BytesMuxerOutput();
}

class CallbackMuxerOutput extends MuxerOutput {
  final void Function(Uint8List chunk) onChunk;
  const CallbackMuxerOutput(this.onChunk);
}

/// Configuration for a muxer (encoded packets → container file/stream).
class MuxerConfig {
  final Container container;
  final MuxerOutput output;
  final List<TrackInfo> tracks;

  /// For fragmented MP4 etc.: target fragment duration in microseconds.
  /// 0 = container default.
  final int fragmentDurationUs;

  final Map<String, String> backendOptions;

  const MuxerConfig({
    required this.container,
    required this.output,
    required this.tracks,
    this.fragmentDurationUs = 0,
    this.backendOptions = const {},
  });
}

/// Where a demuxer reads its input.
sealed class DemuxerInput {
  const DemuxerInput();

  factory DemuxerInput.file(String path) = FileDemuxerInput;
  factory DemuxerInput.bytes(Uint8List bytes) = BytesDemuxerInput;
  factory DemuxerInput.byteStream(
    Stream<List<int>> stream, {
    int bufferBytes,
  }) = StreamDemuxerInput;
}

class FileDemuxerInput extends DemuxerInput {
  final String path;
  const FileDemuxerInput(this.path);
}

class BytesDemuxerInput extends DemuxerInput {
  final Uint8List bytes;
  const BytesDemuxerInput(this.bytes);
}

/// A progressive/live container byte stream (fMP4 / MKV / MPEG-TS from the
/// network, a recorder chunk stream, …).
///
/// The backend buffers up to [bufferBytes] of undemuxed input and applies
/// backpressure to [stream] (pause/resume) when the demuxer falls behind.
/// Non-seekable. Note: plain (non-fragmented) MP4 needs its moov atom
/// up-front (`faststart` / fMP4) to be demuxable as a stream.
class StreamDemuxerInput extends DemuxerInput {
  final Stream<List<int>> stream;
  final int bufferBytes;

  const StreamDemuxerInput(this.stream, {this.bufferBytes = 16 * 1024 * 1024});
}

/// Configuration for a demuxer (container file/stream → encoded packets).
class DemuxerConfig {
  final Container? container; // null = auto-probe
  final DemuxerInput input;
  final Map<String, String> backendOptions;

  const DemuxerConfig({
    required this.input,
    this.container,
    this.backendOptions = const {},
  });
}

/// Configuration for an audio encoder (AAC, Opus, …).
///
/// Sample format of the input PCM is supplied per [encode] call rather than
/// at config time so a single encoder instance can accept whichever PCM
/// format miniav delivers (u8/s16/s32/f32 interleaved).
class AudioEncoderConfig {
  final AudioCodec codec;
  final int sampleRate;
  final int channels;
  final int bitrateBps;
  final Map<String, String> backendOptions;

  const AudioEncoderConfig({
    required this.codec,
    required this.sampleRate,
    required this.channels,
    required this.bitrateBps,
    this.backendOptions = const {},
  });
}

/// Configuration for an audio decoder (AAC, Opus, …).
///
/// Decoded output is always interleaved float32 (see [DecodedAudio]); the
/// true sample rate / channel count come from the bitstream and are reported
/// per decoded chunk.
class AudioDecoderConfig {
  final AudioCodec codec;

  /// Codec-private extra-data (AudioSpecificConfig for AAC-in-MP4, OpusHead,
  /// …). Pass `null` for self-contained bitstreams (ADTS AAC, MP3).
  final Uint8List? extraData;

  /// Optional hints for codecs whose bitstream does not self-describe
  /// (raw PCM) or when no [extraData] is available. Decoders may ignore.
  final int? sampleRate;
  final int? channels;

  final Map<String, String> backendOptions;

  const AudioDecoderConfig({
    required this.codec,
    this.extraData,
    this.sampleRate,
    this.channels,
    this.backendOptions = const {},
  });

  /// Build a decoder config directly from a demuxed [AudioTrackInfo], carrying
  /// its sample-rate / channels / codec-private extra-data across. This is the
  /// demuxer→decoder handoff: codecs whose bitstream isn't self-describing (AAC
  /// via ASC, Opus via OpusHead, raw PCM) need these, and a demuxer is the one
  /// that knows them.
  factory AudioDecoderConfig.fromTrack(
    AudioTrackInfo track, {
    Map<String, String> backendOptions = const {},
  }) => AudioDecoderConfig(
    codec: track.codec,
    extraData: track.extraData?.bytes,
    sampleRate: track.sampleRate,
    channels: track.channels,
    backendOptions: backendOptions,
  );
}
