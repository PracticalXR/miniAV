/// Codec, container, and configuration enums.
library;

/// Video codec identifiers. Backends declare which they support via
/// [MiniAVToolsBackend.supportsEncode] / [supportsDecode].
enum VideoCodec {
  /// H.264 / AVC. Universally supported.
  h264,

  /// H.265 / HEVC.
  hevc,

  /// AV1 — modern royalty-free codec.
  av1,

  /// VP9 — used by WebM/YouTube.
  vp9,

  /// VP8 — older WebM/WebRTC codec.
  vp8,

  /// Motion JPEG — every frame is an independent JPEG. Trivial to encode in
  /// pure GPU compute.
  mjpeg,

  /// ProRes — Apple intermediate codec (decode only on most platforms).
  prores,

  /// Extension point for codecs miniav doesn't know about (an app's
  /// proprietary or experimental codec). The codec's identity is the
  /// `customCodecName` string carried alongside on [EncoderConfig] /
  /// [DecoderConfig] / `CodecQuery` / `CodecCapability` — negotiation matches
  /// capabilities by that name, never by this enum value alone.
  ///
  /// The miniav backends never claim [custom]; an app registers its own
  /// [MiniAVToolsBackend] (overriding `probe`) that answers for its names.
  /// This keeps third-party codecs on the same negotiation spine (priority,
  /// pinning, capability ranking) without their implementation living here.
  custom,
}

/// Audio codec identifiers.
enum AudioCodec { aac, opus, vorbis, mp3, flac, pcmS16le, pcmF32le }

/// Container / file-format identifiers for muxing & demuxing.
enum Container {
  /// ISO/IEC 14496-14 — `.mp4`. Most universal.
  mp4,

  /// Fragmented MP4 — for streaming / DASH / HLS-fMP4.
  fmp4,

  /// Matroska — `.mkv`.
  mkv,

  /// WebM — Matroska subset for VP8/9/AV1 + Opus/Vorbis.
  webm,

  /// MPEG-TS — `.ts`. Used by HLS.
  mpegts,

  /// Raw codec bitstream — no container, just packets concatenated.
  /// Useful for intermediate piping or Annex-B H.264 streams.
  raw,

  /// Ogg — `.ogg` / `.opus`.
  ogg,

  /// WAV — uncompressed audio container.
  wav,

  /// MPEG-4 Audio — `.m4a`. AAC (or ALAC) in an MPEG-4 container without
  /// a video track. Ideal for audio-only AAC recordings.
  m4a,

  /// MPEG Audio Layer III — `.mp3`. Audio-only MP3 container.
  mp3,

  /// ADTS (Audio Data Transport Stream) — `.aac`, per ISO/IEC 13818-7. A raw
  /// AAC bitstream where every frame carries a self-describing 7/9-byte header
  /// (profile, sample-rate index, channel config, frame length). Used for live
  /// AAC and HLS audio segments.
  adts,
}

/// Hardware acceleration preference.
///
/// - [forbidden]: never use HW. Always pick a software encoder/decoder.
/// - [allowed]:   use HW only if the backend reports it for free.
/// - [preferred]: try HW first; fall back to SW if unavailable.
/// - [required]:  fail with [CodecInitException] if no HW path exists.
enum HwAccelPreference { forbidden, allowed, preferred, required }

/// Rate-control mode for video encoders.
///
/// - [cbr]: constant bitrate — for streaming, fixed bandwidth.
/// - [vbr]: variable bitrate — better quality at same average bitrate.
/// - [crf]: constant quality (rate factor) — set [EncoderConfig.crfQuality].
/// - [icq]: intelligent constant quality (NVENC).
enum RateControl { cbr, vbr, crf, icq }

/// H.264 / HEVC profile identifiers (a sensible cross-codec subset).
enum EncoderProfile { baseline, main, high, high10, high422, high444 }

/// H.264 / HEVC level. Backends interpret this codec-appropriately.
enum EncoderLevel {
  level3_0,
  level3_1,
  level4_0,
  level4_1,
  level5_0,
  level5_1,
  level5_2,
  level6_0,
  level6_1,
  level6_2,
}
