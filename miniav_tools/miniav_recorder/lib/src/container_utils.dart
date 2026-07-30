/// Container-selection helpers shared by [Recorder] and unit tests.
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// Maps a file-path extension to a [Container], or returns `null` for
/// unrecognised / missing extensions.
///
/// Matching is case-insensitive. Used by [Recorder] to honour the caller's
/// implicit intent when they write `addFileOutput('recording.mp4')` without
/// an explicit `container:` override.
Container? containerForExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'mp4' || 'm4v' => Container.mp4,
    'mkv' => Container.mkv,
    'webm' => Container.webm,
    'ts' || 'mts' => Container.mpegts,
    'ogg' => Container.ogg,
    'wav' => Container.wav,
    'm4a' => Container.m4a,
    'mp3' => Container.mp3,
    _ => null,
  };
}

/// Heuristic container for a track mix when the file extension offers no
/// hint and the caller did not supply an explicit [Container] override.
///
/// Rules (in order):
/// - video + audio → MKV  (handles any codec mix without restriction)
/// - video only    → MP4
/// - audio only    → M4A / MP3 / OGG based on codec; MKV as catch-all
/// - mixed audio codecs → MKV
Container containerForTrackMix({
  required bool hasVideo,
  required bool hasAudio,

  /// Codec(s) present on audio-only tracks.  Ignored when [hasVideo] is true.
  Set<AudioCodec> audioCodecs = const {},
}) {
  if (hasVideo) {
    return hasAudio ? Container.mkv : Container.mp4;
  }
  if (audioCodecs.length == 1) {
    return switch (audioCodecs.single) {
      AudioCodec.aac => Container.m4a,
      AudioCodec.mp3 => Container.mp3,
      AudioCodec.opus => Container.ogg,
      _ => Container.mkv,
    };
  }
  return Container.mkv; // mixed or unknown codecs
}
