/// A unit of encoded data emitted by encoders / consumed by decoders & muxers.
library;

import 'dart:typed_data';

import 'codec_types.dart';

/// A single encoded video or audio access unit.
class EncodedPacket {
  /// Raw codec bitstream. For video this is typically one access unit
  /// (one frame's worth of NAL units for H.264, one OBU sequence for AV1, etc.);
  /// for audio it is typically one frame of compressed samples.
  final Uint8List data;

  /// Presentation timestamp in microseconds.
  final int ptsUs;

  /// Decode timestamp in microseconds. Equals [ptsUs] when there are no
  /// B-frames.
  final int dtsUs;

  /// Frame duration in microseconds. May be 0 if unknown (rate-driven).
  final int durationUs;

  /// `true` for IDR / keyframes / sync-points.
  final bool isKeyframe;

  /// Track index this packet belongs to (0-based, in declaration order).
  final int trackIndex;

  /// Optional codec-specific extras (e.g. SEI for H.264, side data).
  final Map<String, Object>? sideData;

  const EncodedPacket({
    required this.data,
    required this.ptsUs,
    required this.dtsUs,
    this.durationUs = 0,
    this.isKeyframe = false,
    this.trackIndex = 0,
    this.sideData,
  });

  /// Return a copy with selected fields overridden. Useful when routing a
  /// packet emitted by an encoder (which has trackIndex=0) to a specific
  /// muxer track.
  EncodedPacket copyWith({
    Uint8List? data,
    int? ptsUs,
    int? dtsUs,
    int? durationUs,
    bool? isKeyframe,
    int? trackIndex,
    Map<String, Object>? sideData,
  }) {
    return EncodedPacket(
      data: data ?? this.data,
      ptsUs: ptsUs ?? this.ptsUs,
      dtsUs: dtsUs ?? this.dtsUs,
      durationUs: durationUs ?? this.durationUs,
      isKeyframe: isKeyframe ?? this.isKeyframe,
      trackIndex: trackIndex ?? this.trackIndex,
      sideData: sideData ?? this.sideData,
    );
  }

  @override
  String toString() =>
      'EncodedPacket(${data.length}B, '
      'pts=${ptsUs}us, dts=${dtsUs}us, '
      '${isKeyframe ? "KEY" : "P/B"}, track=$trackIndex)';
}

/// Codec-private bitstream extras (SPS/PPS for H.264, codec-private for VP9,
/// etc.) emitted once at stream start. Muxers need this to write track headers.
class CodecExtraData {
  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;
  final Uint8List bytes;

  const CodecExtraData.video(this.videoCodec, this.bytes) : audioCodec = null;
  const CodecExtraData.audio(this.audioCodec, this.bytes) : videoCodec = null;
}
