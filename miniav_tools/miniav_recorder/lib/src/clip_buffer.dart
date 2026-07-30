/// DVR-style rolling clip buffer.
///
/// Set [maxWindow] to the longest clip you will ever want (e.g. 3 minutes),
/// then call [saveClip] with any [duration] ≤ [maxWindow] to write that many
/// seconds to a file — without interrupting the running recorder.
///
/// ```dart
/// // Keep up to 3 minutes in RAM.
/// final clip = builder.addClipBuffer(maxWindow: Duration(minutes: 3));
/// final rec = builder.build();
/// await rec.start();
///
/// // Save different durations from the same buffer — all at any time:
/// await clip.saveClip('moment_5s.mp4',  duration: Duration(seconds: 5));
/// await clip.saveClip('moment_10s.mp4', duration: Duration(seconds: 10));
/// await clip.saveClip('moment_25s.mp4', duration: Duration(seconds: 25));
/// await clip.saveClip('moment_3min.mp4');  // uses full maxWindow
/// ```
library;

import 'dart:collection';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'container_utils.dart';
import 'recorder_log.dart';
import 'track_chunk.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Internal per-track metadata snapshot (captured from the first chunk).
// ──────────────────────────────────────────────────────────────────────────────
class _TrackMeta {
  final int trackIndex;
  final TrackKind kind;
  // video
  final VideoCodec? videoCodec;
  final int? videoWidth;
  final int? videoHeight;
  final int? videoFrameRateNum;
  final int? videoFrameRateDen;
  // audio
  final AudioCodec? audioCodec;
  final int? sampleRate;
  final int? channels;
  // shared
  final List<int>? extraData; // snapshot of first-chunk extraData bytes

  const _TrackMeta({
    required this.trackIndex,
    required this.kind,
    this.videoCodec,
    this.videoWidth,
    this.videoHeight,
    this.videoFrameRateNum,
    this.videoFrameRateDen,
    this.audioCodec,
    this.sampleRate,
    this.channels,
    this.extraData,
  });

  factory _TrackMeta.from(TrackChunk c) => _TrackMeta(
    trackIndex: c.trackIndex,
    kind: c.kind,
    videoCodec: c.videoCodec,
    videoWidth: c.videoWidth,
    videoHeight: c.videoHeight,
    videoFrameRateNum: c.videoFrameRateNum,
    videoFrameRateDen: c.videoFrameRateDen,
    audioCodec: c.audioCodec,
    sampleRate: c.sampleRate,
    channels: c.channels,
    extraData: c.extraData?.toList(),
  );

  /// Build the [TrackInfo] used to open the muxer (video only; audio needs a
  /// live encoder bridge to set up ch_layout — see [ClipBuffer.saveClip]).
  TrackInfo toVideoTrackInfo() {
    assert(kind == TrackKind.video);
    final ed = extraData;
    return VideoTrackInfo(
      codec: videoCodec!,
      width: videoWidth!,
      height: videoHeight!,
      frameRateNumerator: videoFrameRateNum!,
      frameRateDenominator: videoFrameRateDen!,
      extraData: (ed != null && ed.isNotEmpty)
          ? CodecExtraData.video(videoCodec, Uint8List.fromList(ed))
          : null,
    );
  }
}

/// Selected slice of the clip ring buffer: the PTS-sorted [chunks] snapshot to
/// mux, the set of video track indices seen in the window, and whether video
/// had to be dropped (no keyframe available).
typedef ClipSlice = ({
  List<TrackChunk> chunks,
  Set<int> videoTracks,
  bool droppedVideo,
});

/// Selects + snapshots the chunks for a clip covering `[cutoffPts, lastPts]` in
/// a single bounded operation (a couple of scans over [buf] plus one sort),
/// producing a stable copy decoupled from the live ring buffer.
///
/// When the window contains video, the clip is extended back to the most recent
/// keyframe at or before [cutoffPts] (the GOP boundary) so the decoder has an
/// IDR to anchor to — or, failing that, trimmed forward to the first keyframe
/// inside the window. If no keyframe exists anywhere and the window has
/// non-video content, video is dropped so a valid audio-only file still results.
///
/// Pure and top-level so the (subtle) windowing/keyframe logic is unit-testable
/// without a live recorder.
ClipSlice selectClipSlice(
  Iterable<TrackChunk> buf,
  int cutoffPts,
  int lastPts,
) {
  // Pass 1: which video tracks appear in the window, and is there any non-video?
  final videoTracks = <int>{};
  var hasNonVideoInWindow = false;
  for (final c in buf) {
    if (c.ptsUs < cutoffPts || c.ptsUs > lastPts) continue;
    if (c.kind == TrackKind.video) {
      videoTracks.add(c.trackIndex);
    } else {
      hasNonVideoInWindow = true;
    }
  }

  var startPts = cutoffPts;
  var droppedVideo = false;
  if (videoTracks.isNotEmpty) {
    // Pass 2: find the keyframe-aligned clip start. Prefer the newest keyframe
    // at or before the window (full duration, extended to the GOP boundary);
    // else the first keyframe inside the window.
    int? bestKeyPts; // newest video keyframe pts <= cutoffPts
    int? firstKeyInside; // first video keyframe pts in (cutoffPts, lastPts]
    for (final c in buf) {
      if (c.kind != TrackKind.video || !c.isKeyframe) continue;
      if (!videoTracks.contains(c.trackIndex)) continue;
      if (c.ptsUs <= cutoffPts) {
        if (bestKeyPts == null || c.ptsUs > bestKeyPts) bestKeyPts = c.ptsUs;
      } else if (c.ptsUs <= lastPts && firstKeyInside == null) {
        firstKeyInside = c.ptsUs;
      }
    }
    final clipStart = bestKeyPts ?? firstKeyInside;
    if (clipStart != null) {
      startPts = clipStart;
    } else {
      // No keyframe anywhere — GOP exceeds the buffer. Drop video (keep audio)
      // when there is non-video content; otherwise keep the video chunks so the
      // caller's metadata validation runs (matching the prior behavior).
      droppedVideo = hasNonVideoInWindow;
    }
  }

  // Pass 3: snapshot the selected chunks once, then sort by PTS so DTS is
  // monotonic per stream (the IDR precedes the P-frames that reference it).
  final chunks = <TrackChunk>[];
  for (final c in buf) {
    if (c.ptsUs < startPts || c.ptsUs > lastPts) continue;
    if (droppedVideo && c.kind == TrackKind.video) continue;
    chunks.add(c);
  }
  chunks.sort((a, b) => a.ptsUs.compareTo(b.ptsUs));
  return (
    chunks: chunks,
    videoTracks: videoTracks,
    droppedVideo: droppedVideo,
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// ClipBuffer
// ──────────────────────────────────────────────────────────────────────────────

/// A rolling in-memory buffer of encoded [TrackChunk]s covering the last
/// [maxWindow] of recording time. Call [saveClip] with any [Duration] ≤
/// [maxWindow] to write a clip to a file without interrupting the running
/// recorder.
///
/// The buffer always retains [maxWindow] worth of data, so you can call
/// [saveClip] multiple times with different durations (5 s, 30 s, 3 min…)
/// from the same buffer instance without reconfiguring anything.
///
/// Thread-safety: designed for single-isolate use. [onChunk] and [saveClip]
/// must not be called concurrently from different isolates.
class ClipBuffer {
  /// Creates a [ClipBuffer] that retains at most [maxWindow] of encoded data.
  ///
  /// Size [maxWindow] to the longest clip you will ever want. You can then
  /// call `saveClip(path, duration: Duration(seconds: 10))` to save any
  /// shorter sub-window on demand.
  ///
  /// [maxPackets] is an optional hard cap on the ring size to bound memory
  /// usage when the encoder produces many small packets.
  /// Optional muxer factory used by [saveClip] for **video-only** clips.
  ///
  /// When set and the clip contains a single video track (no audio), this
  /// factory is called instead of [FfmpegMuxer.open], letting the caller
  /// supply a backend-native muxer (e.g. [Av1Mp4Muxer] for the minigpu
  /// AV1 path). For clips that include audio tracks [FfmpegMuxer] is
  /// always used regardless of this setting, because audio muxing requires
  /// FFmpeg's `ch_layout` bridge.
  ClipBuffer({required this.maxWindow, this.maxPackets, this.muxerFactory});

  /// Maximum buffered duration. Packets older than `now − maxWindow` are
  /// evicted automatically. This is the upper bound for [saveClip]'s
  /// optional [duration] parameter.
  final Duration maxWindow;

  /// Optional maximum number of packets retained. When non-null the oldest
  /// packets are dropped even if they are still within [window].
  final int? maxPackets;

  /// Optional factory for creating a [PlatformMuxer] for video-only clips.
  /// See constructor doc for details.
  final PlatformMuxer Function(MuxerConfig)? muxerFactory;

  // Ring buffer — newest packets at the back, oldest at the front.
  final _buf = ListQueue<TrackChunk>();

  // Tracks the maximum ptsUs seen across all chunks ever added. Used as the
  // "current time" anchor for both eviction and clip-window computation,
  // because _buf.last.ptsUs can be stale when an audio packet (whose encoder
  // may buffer samples for one frame before emitting) lands in the queue
  // after a later-timestamped video packet.
  int _maxPtsUs = 0;

  // Per-track metadata snapshot (populated on first chunk with non-null
  // extraData for that track).
  final _meta = <int, _TrackMeta>{};

  // ── Public API ────────────────────────────────────────────────────────────

  /// Number of packets currently in the buffer.
  int get length => _buf.length;

  /// Whether the buffer contains at least one packet.
  bool get isNotEmpty => _buf.isNotEmpty;

  /// The pts timestamp of the oldest packet in the buffer, or null if empty.
  int? get oldestPtsUs => _buf.isEmpty ? null : _buf.first.ptsUs;

  /// The pts timestamp of the newest packet in the buffer, or null if empty.
  int? get newestPtsUs => _buf.isEmpty ? null : _maxPtsUs;

  /// Callback to pass to [RecorderBuilder.addStreamOutput].
  ///
  /// Accepts [Object] to match the builder's untyped sink API; the value is
  /// always a [TrackChunk].
  void onChunk(Object raw) {
    final chunk = raw as TrackChunk;
    // Capture track metadata from the first chunk that carries format info.
    // A chunk carries metadata when extraData is present (first chunk per
    // track) and at least one of the track-specific fields is populated.
    if (!_meta.containsKey(chunk.trackIndex) && chunk.extraData != null) {
      if (chunk.videoWidth != null || chunk.sampleRate != null) {
        _meta[chunk.trackIndex] = _TrackMeta.from(chunk);
      }
    }
    _buf.addLast(chunk);
    if (chunk.ptsUs > _maxPtsUs) _maxPtsUs = chunk.ptsUs;
    _evict();
  }

  /// Discard all buffered packets and track metadata.
  void clear() {
    _buf.clear();
    _meta.clear();
    _maxPtsUs = 0;
  }

  /// Write the most-recent [duration] of buffered recording to [path].
  ///
  /// Pass any [duration] ≤ [maxWindow] — you can call this multiple times
  /// with different values while the recorder is running:
  ///
  /// ```dart
  /// // All from the same 3-minute buffer:
  /// await clip.saveClip('highlight_5s.mp4',  duration: Duration(seconds: 5));
  /// await clip.saveClip('highlight_30s.mp4', duration: Duration(seconds: 30));
  /// await clip.saveClip('replay_3min.mp4');  // omit duration → full maxWindow
  /// ```
  ///
  /// The output file is a self-contained container (MP4, MKV, etc.) starting
  /// from a video keyframe — suitable for direct playback. Timestamps are
  /// remapped to start from 0.
  ///
  /// [container] overrides the container format; when omitted the format is
  /// inferred from [path]'s extension, then from the track mix.
  ///
  /// Throws [StateError] if the buffer is empty or track metadata is missing
  /// (i.e. [saveClip] was called before any chunk with [TrackChunk.extraData]
  /// arrived for a track present in the clip).
  ///
  /// Returns the number of packets written.
  Future<int> saveClip(
    String path, {
    Duration? duration,
    Container? container,
  }) async {
    if (_buf.isEmpty) throw StateError('ClipBuffer.saveClip: buffer is empty');

    // 1. Determine the time window for this clip.
    //    Use _maxPtsUs (the true maximum PTS seen) rather than _buf.last.ptsUs.
    //    _buf.last may be an audio packet whose encoder buffered samples for
    //    one frame, causing it to land in the queue after a later-timestamped
    //    video packet.  Using _maxPtsUs prevents the window from being anchored
    //    to a stale timestamp that would drag in older packets or push
    //    originPts toward zero.
    final effectiveWindowUs = (duration ?? maxWindow).inMicroseconds.clamp(
      0,
      maxWindow.inMicroseconds,
    );
    final lastPts = _buf.isEmpty ? 0 : _maxPtsUs;
    final cutoffPts = lastPts - effectiveWindowUs;

    // 2–3. Select + snapshot the clip slice (keyframe-aligned) in one bounded
    //      operation, decoupled from the live ring buffer. The returned chunks
    //      are already PTS-sorted. See [selectClipSlice].
    final slice = selectClipSlice(_buf, cutoffPts, lastPts);
    final chunks = slice.chunks;
    final videoTrackIndices = slice.videoTracks;
    if (slice.droppedVideo) {
      recorderLog(
        RecorderLogSource.recorder,
        RecorderLogLevel.warning,
        '[clip_buffer] no IDR/keyframe in buffer for video tracks '
        '$videoTrackIndices — encoder gopLength likely exceeds buffer '
        'window. Dropping video from this clip.',
      );
    }
    if (chunks.isEmpty) {
      throw StateError('ClipBuffer.saveClip: no packets in requested window');
    }

    // 4. Determine which track indices are actually present.
    final presentIndices = chunks.map((c) => c.trackIndex).toSet().toList()
      ..sort();

    // Validate metadata — we need it for every track in the clip.
    for (final idx in presentIndices) {
      if (!_meta.containsKey(idx)) {
        throw StateError(
          'ClipBuffer.saveClip: no track metadata for track $idx. '
          'The first encoded packet for this track has not yet arrived.',
        );
      }
    }

    // 5. Remap original track indices to 0-based muxer stream indices.
    final idxRemap = <int, int>{
      for (var i = 0; i < presentIndices.length; i++) presentIndices[i]: i,
    };

    // 6. Resolve container up front so we can choose the muxer strategy
    //    before deciding whether the temporary FFmpeg audio encoders are
    //    even needed.
    final effectiveContainer =
        container ??
        containerForExtension(path) ??
        containerForTrackMix(
          hasVideo: videoTrackIndices.isNotEmpty,
          hasAudio: presentIndices.any(
            (i) => _meta[i]!.kind == TrackKind.audio,
          ),
          audioCodecs: presentIndices
              .where((i) => _meta[i]!.kind == TrackKind.audio)
              .map((i) => _meta[i]!.audioCodec!)
              .toSet(),
        );

    // 7. Decide muxer strategy. The caller-supplied muxerFactory (the
    //    pure-Dart Av1Mp4Muxer for the minigpu path) can handle MP4 clips
    //    with exactly one AV1 video track plus any number of AAC audio
    //    tracks — no FFmpeg round-trip and no temporary audio encoders.
    final videoMetas = presentIndices
        .map((i) => _meta[i]!)
        .where((m) => m.kind == TrackKind.video)
        .toList();
    final audioMetas = presentIndices
        .map((i) => _meta[i]!)
        .where((m) => m.kind == TrackKind.audio)
        .toList();
    final useDartMuxer =
        muxerFactory != null &&
        effectiveContainer == Container.mp4 &&
        videoMetas.length == 1 &&
        videoMetas.first.videoCodec == VideoCodec.av1 &&
        audioMetas.every((m) => m.audioCodec == AudioCodec.aac);

    // 8. Build track-info list. For the FFmpeg path we open a temporary audio
    //    encoder per audio track purely so FfmpegMuxer can call
    //    avcodec_parameters_from_context (ch_layout needs a live context).
    //    The Dart muxer needs no encoder — it muxes the already-encoded AAC
    //    packets directly, passing through the captured AudioSpecificConfig
    //    when present (otherwise it synthesises one from sample-rate /
    //    channel-count).
    final trackInfos = <TrackInfo>[];
    final tempAudioEncoders = <int, AudioEncoder>{}; // remapped idx → encoder
    final encoderForTrack = <int, FfmpegEncoderBridge>{};

    try {
      for (final origIdx in presentIndices) {
        final meta = _meta[origIdx]!;
        final remapIdx = idxRemap[origIdx]!;

        if (meta.kind == TrackKind.video) {
          trackInfos.add(meta.toVideoTrackInfo());
        } else if (useDartMuxer) {
          final ed = meta.extraData;
          trackInfos.add(
            AudioTrackInfo(
              codec: meta.audioCodec!,
              sampleRate: meta.sampleRate!,
              channels: meta.channels!,
              extraData: (ed != null && ed.isNotEmpty)
                  ? CodecExtraData.audio(
                      meta.audioCodec,
                      Uint8List.fromList(ed),
                    )
                  : null,
            ),
          );
        } else {
          // Audio: create a temporary encoder purely for codecpar filling.
          final enc = await MiniAVTools.createAudioEncoder(
            AudioEncoderConfig(
              codec: meta.audioCodec!,
              sampleRate: meta.sampleRate!,
              channels: meta.channels!,
              bitrateBps: 128000,
              backendOptions: const {'global_header': '1'},
            ),
          );
          tempAudioEncoders[remapIdx] = enc;
          final bridge = enc.platform;
          if (bridge is FfmpegEncoderBridge) {
            encoderForTrack[remapIdx] = bridge as FfmpegEncoderBridge;
          }
          trackInfos.add(
            AudioTrackInfo(
              codec: meta.audioCodec!,
              sampleRate: meta.sampleRate!,
              channels: meta.channels!,
            ),
          );
        }
      }

      // Open muxer: Dart muxer for the AV1(+AAC) MP4 path, FFmpeg otherwise.
      final muxerConfig = MuxerConfig(
        container: effectiveContainer,
        output: FileMuxerOutput(path),
        tracks: trackInfos,
      );
      final PlatformMuxer muxer = useDartMuxer
          ? muxerFactory!(muxerConfig)
          : FfmpegMuxer.open(
              muxerConfig,
              encoderForTrack: encoderForTrack.isNotEmpty
                  ? encoderForTrack
                  : null,
            );

      // 9. Write header. After this the muxer no longer needs the encoder
      //    bridges, so we can close the temp encoders immediately.
      await muxer.writeHeader();

      // Close temp audio encoders — codecpar has been copied by writeHeader.
      for (final enc in tempAudioEncoders.values) {
        try {
          await enc.close();
        } catch (_) {}
      }
      tempAudioEncoders.clear();

      // 10. Determine timestamp origin for remapping.
      //
      //     We anchor at `cutoffPts` (the requested window start) rather
      //     than the earliest pts in `chunks`. Any video keyframe preroll
      //     that lies between `clipStartPts` and `cutoffPts` therefore
      //     gets a NEGATIVE pts/dts, which the mp4 muxer turns into an
      //     `edts/elst` edit list (because we set
      //     `avoid_negative_ts=make_zero`). Players honour the edit list
      //     and skip the preroll, so the visible clip is exactly the
      //     requested duration even when the encoder GOP is several
      //     seconds long.
      //
      //     If the buffer is younger than the requested window
      //     (cutoffPts < earliest chunk), we anchor at the earliest
      //     chunk instead so we don't introduce a synthetic delay.
      final earliestPts = chunks.map((c) => c.ptsUs).reduce(min);
      final originPts = cutoffPts > earliestPts ? cutoffPts : earliestPts;

      // 11. Write packets. [chunks] is already PTS-sorted by [selectClipSlice]
      //    (the buffer stores *arrival* order, which is NOT PTS order — an IDR
      //    can land after the P-frames it precedes; writing arrival order would
      //    give av_interleaved_write_frame a backwards DTS and it would silently
      //    drop the IDR, garbling the first GOP). Sorting by PTS (== DTS for
      //    no-B-frame streams) keeps DTS monotonic per stream.
      var written = 0;
      for (final chunk in chunks) {
        final remapIdx = idxRemap[chunk.trackIndex]!;
        final ptsUs = chunk.ptsUs - originPts;
        // dts can legitimately be negative for the GOP preroll (the
        // muxer turns this into an edit list — see comment on originPts
        // above). Don't clamp.
        final dtsUs = chunk.dtsUs - originPts;

        try {
          await muxer.writePacket(
            EncodedPacket(
              trackIndex: remapIdx,
              data: chunk.bytes,
              ptsUs: ptsUs,
              dtsUs: dtsUs,
              durationUs: chunk.durationUs,
              isKeyframe: chunk.isKeyframe,
            ),
          );
          written++;
        } catch (e) {
          recorderLog(
            RecorderLogSource.recorder,
            RecorderLogLevel.error,
            '[clip_buffer] writePacket track=$remapIdx: $e',
          );
        }
      }

      // 12. Finish (writes container trailer) then close (flushes AVIO to
      //    disk and releases the file handle). Both must run for the file
      //    to be valid — finish() writes moov/trailer, close() calls
      //    avio_closep which flushes the write buffer to the OS.
      try {
        await muxer.finish();
      } finally {
        await muxer.close();
      }

      return written;
    } finally {
      // Ensure temp encoders are always cleaned up on error paths.
      for (final enc in tempAudioEncoders.values) {
        try {
          await enc.close();
        } catch (_) {}
      }
    }
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _evict() {
    if (_buf.isEmpty) return;

    // Time-based eviction: drop packets older than maxWindow.
    // Use _maxPtsUs (the true latest timestamp seen) rather than
    // _buf.last.ptsUs to avoid keeping stale data when an out-of-order
    // audio packet is the most-recently-added element.
    final cutoff = _maxPtsUs - maxWindow.inMicroseconds;
    while (_buf.isNotEmpty && _buf.first.ptsUs < cutoff) {
      _buf.removeFirst();
    }

    // Packet-count cap.
    final cap = maxPackets;
    if (cap != null) {
      while (_buf.length > cap) {
        _buf.removeFirst();
      }
    }
  }
}
