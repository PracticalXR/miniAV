/// Player configuration + stats types.
library;

import 'package:miniav_tools/miniav_tools.dart';

export 'video_scheduler.dart' show PlayerLatencyMode;

/// Video track description for [MiniavPlayer.open].
class VideoStreamSpec {
  const VideoStreamSpec({required this.config});

  /// Decoder configuration. `extraData` carries avcC/hvcC/codec-private for
  /// non-self-contained streams; Annex-B needs none. Decode runs on a worker
  /// isolate by default (backendOptions `{'sw_isolate': '0'}` opts out).
  final DecoderConfig config;
}

/// Audio track description for [MiniavPlayer.open].
class AudioStreamSpec {
  const AudioStreamSpec({required this.config, this.bufferMs = 120});

  /// Decoder configuration (AAC ASC / OpusHead via `extraData` when the
  /// transport provides it out-of-band).
  final AudioDecoderConfig config;

  /// Playback ring target depth, ms. Bigger = more jitter tolerance,
  /// more latency.
  final int bufferMs;
}

/// Aggregated live counters. Cheap value snapshot — poll from a stats HUD.
class PlayerStats {
  const PlayerStats({
    required this.videoPacketsSubmitted,
    required this.videoPacketsDropped,
    required this.videoFramesDecoded,
    required this.videoFramesPresented,
    required this.videoFramesDroppedSuperseded,
    required this.videoFramesDroppedLate,
    required this.videoQueueDepth,
    required this.audioPacketsSubmitted,
    required this.audioFramesWritten,
    required this.audioFramesDropped,
    required this.decodeMs,
    required this.convertMs,
    required this.copyMs,
    required this.presentMs,
  });

  final int videoPacketsSubmitted;

  /// Packets dropped by the bounded decode-input queue (catch-up).
  final int videoPacketsDropped;
  final int videoFramesDecoded;
  final int videoFramesPresented;
  final int videoFramesDroppedSuperseded;
  final int videoFramesDroppedLate;
  final int videoQueueDepth;

  final int audioPacketsSubmitted;
  final int audioFramesWritten;
  final int audioFramesDropped;

  /// Last-frame timings, milliseconds. `convertMs` includes the YUV upload
  /// (the player's single CPU→GPU pixel copy).
  final double decodeMs;
  final double convertMs;
  final double copyMs;
  final double presentMs;

  @override
  String toString() =>
      'PlayerStats(video: $videoFramesPresented presented / '
      '$videoFramesDecoded decoded / $videoPacketsSubmitted pkts '
      '(-$videoPacketsDropped q, -$videoFramesDroppedSuperseded sup, '
      '-$videoFramesDroppedLate late), '
      'audio: $audioFramesWritten frames (-$audioFramesDropped), '
      'ms: dec=${decodeMs.toStringAsFixed(1)} '
      'cvt=${convertMs.toStringAsFixed(1)} '
      'copy=${copyMs.toStringAsFixed(1)} '
      'present=${presentMs.toStringAsFixed(1)})';
}
