/// Tests for [selectClipSlice] — the keyframe-aligned window selection +
/// single-pass snapshot used by `ClipBuffer.saveClip`. Pure logic, no recorder.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_recorder/src/clip_buffer.dart' show selectClipSlice;
import 'package:miniav_recorder/src/track_chunk.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show VideoCodec, AudioCodec;
import 'package:test/test.dart';

TrackChunk _v(int pts, {bool key = false, int track = 0}) => TrackChunk(
  trackIndex: track,
  kind: TrackKind.video,
  ptsUs: pts,
  dtsUs: pts,
  durationUs: 0,
  bytes: Uint8List(1),
  isKeyframe: key,
  videoCodec: VideoCodec.h264,
);

TrackChunk _a(int pts, {int track = 1}) => TrackChunk(
  trackIndex: track,
  kind: TrackKind.audio,
  ptsUs: pts,
  dtsUs: pts,
  durationUs: 0,
  bytes: Uint8List(1),
  isKeyframe: true,
  audioCodec: AudioCodec.aac,
);

List<int> _pts(Iterable<TrackChunk> cs) => cs.map((c) => c.ptsUs).toList();

void main() {
  group('selectClipSlice', () {
    test('extends the clip back to the keyframe before the window (GOP preroll)', () {
      final buf = [
        _v(0, key: true),
        _v(100),
        _v(200),
        _v(300, key: true),
        _v(400),
        _v(500),
      ];
      // Window [350, 500] — the most recent keyframe at/before 350 is @300.
      final s = selectClipSlice(buf, 350, 500);
      expect(_pts(s.chunks), [300, 400, 500]);
      expect(s.chunks.first.isKeyframe, isTrue);
      expect(s.videoTracks, {0});
      expect(s.droppedVideo, isFalse);
    });

    test('trims forward to the first in-window keyframe when none precedes it', () {
      final buf = [
        _v(0),
        _v(100),
        _v(250), // non-key, inside window but before the first keyframe
        _v(300, key: true),
        _v(400),
      ];
      final s = selectClipSlice(buf, 200, 400);
      // No keyframe <= 200, so start at the first in-window keyframe (@300);
      // the non-key @250 is excluded (no anchor before it).
      expect(_pts(s.chunks), [300, 400]);
      expect(s.droppedVideo, isFalse);
    });

    test('drops video (keeps audio) when the buffer has no keyframe at all', () {
      final buf = [_v(100), _v(200), _a(150), _a(250)];
      final s = selectClipSlice(buf, 0, 250);
      expect(s.droppedVideo, isTrue);
      expect(_pts(s.chunks), [150, 250]); // audio only, sorted
      expect(s.chunks.every((c) => c.kind == TrackKind.audio), isTrue);
      expect(s.videoTracks, {0});
    });

    test('keeps video when there is no keyframe but also no other track', () {
      final buf = [_v(100), _v(200)];
      final s = selectClipSlice(buf, 0, 200);
      expect(s.droppedVideo, isFalse);
      expect(_pts(s.chunks), [100, 200]);
    });

    test('returns PTS-sorted snapshot even when arrival order differs', () {
      // IDR encodes slower, so it can arrive after the P-frames it precedes.
      final buf = [_v(0, key: true), _v(200), _v(100), _v(300)];
      final s = selectClipSlice(buf, 0, 300);
      expect(_pts(s.chunks), [0, 100, 200, 300]);
    });

    test('interleaves audio with the keyframe-aligned video window', () {
      final buf = [
        _v(0, key: true),
        _a(50),
        _v(100),
        _a(150),
        _v(200, key: true),
        _a(250),
        _v(300),
      ];
      final s = selectClipSlice(buf, 220, 300);
      // Keyframe <= 220 is @200, so the clip starts there; audio @250 is in
      // range, audio @150 is not.
      expect(_pts(s.chunks), [200, 250, 300]);
      expect(s.videoTracks, {0});
    });

    test('audio-only buffer yields no video tracks and the full window', () {
      final buf = [_a(0), _a(100), _a(200), _a(300)];
      final s = selectClipSlice(buf, 100, 300);
      expect(s.videoTracks, isEmpty);
      expect(s.droppedVideo, isFalse);
      expect(_pts(s.chunks), [100, 200, 300]);
    });
  });
}
