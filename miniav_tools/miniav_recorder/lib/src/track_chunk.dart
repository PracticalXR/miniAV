/// A single encoded chunk emitted to a [StreamRecorderOutput] sink.
///
/// Equivalent to one [EncodedPacket] tagged with the output-track index
/// and codec metadata so a downstream consumer (network sender, browser
/// MediaSource, etc.) can reconstruct the stream without parsing the
/// container.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// Identifies the kind of media a [TrackChunk] carries.
enum TrackKind { video, audio }

class TrackChunk {
  /// 0-based index of the track in the recorder's output (declaration order).
  final int trackIndex;

  /// Whether this chunk is video or audio.
  final TrackKind kind;

  /// Concrete codec for [kind]. Exactly one of [videoCodec]/[audioCodec] is
  /// non-null.
  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;

  /// Master-clock presentation timestamp in microseconds, relative to the
  /// recorder's start.
  final int ptsUs;

  /// Decode timestamp in microseconds (== [ptsUs] when no B-frames).
  final int dtsUs;

  /// Duration in microseconds (0 if unknown).
  final int durationUs;

  /// Encoded payload.
  final Uint8List bytes;

  /// `true` for IDR / sync points.
  final bool isKeyframe;

  /// Codec-private extras (SPS/PPS for H.264, AudioSpecificConfig for AAC,
  /// OpusHead for Opus). Present on the FIRST chunk per track and `null`
  /// on subsequent chunks.
  final Uint8List? extraData;

  // ── Track metadata (set on the FIRST chunk per track, null thereafter) ──

  /// Video frame width in pixels. Non-null on the first video chunk.
  final int? videoWidth;

  /// Video frame height in pixels. Non-null on the first video chunk.
  final int? videoHeight;

  /// Video frame-rate numerator. Non-null on the first video chunk.
  final int? videoFrameRateNum;

  /// Video frame-rate denominator. Non-null on the first video chunk.
  final int? videoFrameRateDen;

  /// Audio sample rate in Hz. Non-null on the first audio chunk.
  final int? sampleRate;

  /// Number of audio channels. Non-null on the first audio chunk.
  final int? channels;

  const TrackChunk({
    required this.trackIndex,
    required this.kind,
    required this.ptsUs,
    required this.dtsUs,
    required this.durationUs,
    required this.bytes,
    required this.isKeyframe,
    this.videoCodec,
    this.audioCodec,
    this.extraData,
    this.videoWidth,
    this.videoHeight,
    this.videoFrameRateNum,
    this.videoFrameRateDen,
    this.sampleRate,
    this.channels,
  });

  @override
  String toString() =>
      'TrackChunk(track=$trackIndex, $kind, '
      '${videoCodec ?? audioCodec}, ${bytes.length}B, '
      'pts=${ptsUs}us, ${isKeyframe ? "KEY" : "delta"})';
}
