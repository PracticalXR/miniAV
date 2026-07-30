/// Web capability probes + MIME/codecs-string derivation for the MSE fallback.
/// Web implementation; the native twin (`mse_support_stub.dart`) reports nothing
/// available. Selected via conditional import.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:miniav_tools/miniav_tools.dart';

/// True when the browser exposes the WebCodecs `VideoDecoder`. When false, the
/// player should take the MSE `<video>` fallback for video.
bool webCodecsVideoAvailable() => globalContext.has('VideoDecoder');

/// True when the browser exposes Media Source Extensions.
bool mseAvailable() => globalContext.has('MediaSource');

/// True when the WebCodecs video path is unavailable but MSE is — i.e. the
/// player should take the browser-native `<video>` fallback for video.
bool mseFallbackRecommended() => !webCodecsVideoAvailable() && mseAvailable();

/// Plain container MIME for the Blob (whole-file) path — no codecs= needed.
/// Sniffs magic bytes; returns null if unrecognized (caller shouldn't use MSE).
String? blobMimeForBytes(List<int> b, {bool hasVideo = true}) {
  if (b.length >= 8 &&
      b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
    return hasVideo ? 'video/mp4' : 'audio/mp4'; // ISO-BMFF 'ftyp'
  }
  if (b.length >= 4 &&
      b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
    return hasVideo ? 'video/webm' : 'audio/webm'; // EBML (Matroska/WebM)
  }
  if (b.length >= 4 &&
      b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
    return 'audio/ogg'; // OggS
  }
  if (b.length >= 4 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
    return 'audio/wav'; // RIFF
  }
  return null;
}

/// Full `video/mp4; codecs="..."` string for the MSE stream path, derived from
/// the demuxer's track info. Returns null when the video codec can't be mapped
/// (caller should not attempt MSE streaming). H.264+AAC — the dominant fMP4
/// case — is derived precisely from avcC/ASC; others are best-effort.
String? mp4MimeForTracks(VideoTrackInfo? v, AudioTrackInfo? a) {
  final codecs = <String>[];
  final isVideo = v != null;
  if (v != null) {
    final s = _videoCodecString(v);
    if (s == null) return null;
    codecs.add(s);
  }
  if (a != null) {
    final s = _audioCodecString(a);
    if (s != null) codecs.add(s);
  }
  if (codecs.isEmpty) return null;
  final container = isVideo ? 'video/mp4' : 'audio/mp4';
  return '$container; codecs="${codecs.join(',')}"';
}

String? _videoCodecString(VideoTrackInfo v) {
  switch (v.codec) {
    case VideoCodec.h264:
      final e = v.extraData?.bytes;
      // avcC: [0]=version [1]=profile [2]=compat [3]=level -> avc1.PPCCLL
      if (e != null && e.length >= 4) {
        return 'avc1.${_hex2(e[1])}${_hex2(e[2])}${_hex2(e[3])}';
      }
      return 'avc1.42E01E'; // Baseline@3.0 fallback
    case VideoCodec.hevc:
      // Precise hvc1 strings require parsing hvcC; Main@L93 is a safe default.
      return 'hvc1.1.6.L93.B0';
    default:
      return null; // AV1/VP8/VP9 -> WebM path (not derived here)
  }
}

String? _audioCodecString(AudioTrackInfo a) {
  switch (a.codec) {
    case AudioCodec.aac:
      return 'mp4a.40.2'; // AAC-LC (browsers are lenient about the object type)
    case AudioCodec.opus:
      return 'opus';
    case AudioCodec.mp3:
      return 'mp4a.40.34';
    default:
      return null;
  }
}

String _hex2(int b) => (b & 0xff).toRadixString(16).padLeft(2, '0').toUpperCase();
