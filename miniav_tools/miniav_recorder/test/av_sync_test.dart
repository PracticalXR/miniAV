/// Tests for AV synchronisation in the mixed-audio path and in ClipBuffer's
/// PTS rebasing logic.
///
/// Because the private classes (_MixedAudioTrackRuntime, _VideoTrackRuntime,
/// ClipBuffer internals) cannot be imported directly, the tests replicate the
/// exact formulas used by those classes and verify that:
///
///  A. The OLD (broken) frame-counter PTS formula (always starting from 0)
///     produces a constant negative audio offset relative to video PTSs,
///     which after saveClip's `avoid_negative_ts` shift causes a visible
///     AV desync equal to the clock-start-to-first-audio-callback delay.
///
///  B. The NEW (fixed) formula anchors `_audioStartUs` to the master clock
///     at the first loopback callback, so audio and video PTSs share the same
///     reference and the offset after rebasing is ≤ one audio frame (≈10 ms).
///
///  C. saveClip's originPts logic subtracts the same base from both tracks,
///     producing zero skew regardless of which track arrives first.
///
///  D. Edge cases: buffer younger than requested window, single-track clips,
///     and the exact monotonicity guarantee for _framesOut increments.
library;

import 'dart:math' show min;

import 'package:test/test.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Minimal data model — mirrors the fields read by saveClip's rebasing logic.
// ──────────────────────────────────────────────────────────────────────────────

/// Mirrors the fields of TrackChunk that saveClip's PTS rebasing touches.
class _Chunk {
  final int trackIndex;
  final bool isAudio; // true=audio, false=video
  final int ptsUs;
  final bool isKeyframe;

  const _Chunk({
    required this.trackIndex,
    required this.isAudio,
    required this.ptsUs,
    this.isKeyframe = false,
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// Mirrors the PTS-generation formulas from recorder.dart.
// ──────────────────────────────────────────────────────────────────────────────

/// Broken (pre-fix) audio PTS: frame counter always starts from 0.
/// This is what _MixedAudioTrackRuntime used to produce.
int _brokenAudioPts(int framesOut, int sampleRate) {
  return framesOut * 1000000 ~/ sampleRate;
}

/// Fixed audio PTS: anchored to the master clock at first callback.
/// This is what _MixedAudioTrackRuntime now produces.
int _fixedAudioPts(int framesOut, int sampleRate, int audioStartUs) {
  return audioStartUs + (framesOut * 1000000 ~/ sampleRate);
}

/// Simulates the video PTS assigned by _VideoTrackRuntime: rec.now() at the
/// moment the capture callback fires, which is master-clock elapsed time.
int _videoPts(int masterClockUs) => masterClockUs;

// ──────────────────────────────────────────────────────────────────────────────
// Mirrors the saveClip originPts / cutoff computation.
// ──────────────────────────────────────────────────────────────────────────────

/// Compute the origin PTS that saveClip uses when rebasing to [0…], given the
/// set of all packets and the requested clip duration.
///
/// Mirrors the logic in clip_buffer.dart lines 219-228:
///   cutoffPts = maxPts - windowUs
///   originPts = cutoffPts > earliestPts ? cutoffPts : earliestPts
int _computeOriginPts(List<_Chunk> chunks, int maxPtsUs, int windowUs) {
  final cutoffPts = maxPtsUs - windowUs;
  final inWindow = chunks.where((c) => c.ptsUs >= cutoffPts).toList();
  if (inWindow.isEmpty) return cutoffPts;
  final earliestPts = inWindow.map((c) => c.ptsUs).reduce(min);
  return cutoffPts > earliestPts ? cutoffPts : earliestPts;
}

/// Returns the rebased (output) PTS for [chunk] given [originPts].
int _rebasedPts(_Chunk chunk, int originPts) => chunk.ptsUs - originPts;

// ──────────────────────────────────────────────────────────────────────────────
// Helper: build a synthetic stream of mixed audio+video PTSs.
// ──────────────────────────────────────────────────────────────────────────────

/// Returns [count] video PTSs starting at [startUs], spaced by [frameIntervalUs].
List<int> _videoPtsList(int startUs, int frameIntervalUs, int count) {
  return List.generate(count, (i) => startUs + i * frameIntervalUs);
}

/// Returns [count] audio PTSs using the FIXED formula with [audioStartUs].
List<int> _audioFixedPtsList(
  int audioStartUs,
  int samplesPerChunk,
  int sampleRate,
  int count,
) {
  return List.generate(
    count,
    (i) => _fixedAudioPts(i * samplesPerChunk, sampleRate, audioStartUs),
  );
}

/// Returns [count] audio PTSs using the BROKEN formula (no start offset).
List<int> _audioBrokenPtsList(int samplesPerChunk, int sampleRate, int count) {
  return List.generate(
    count,
    (i) => _brokenAudioPts(i * samplesPerChunk, sampleRate),
  );
}

// ──────────────────────────────────────────────────────────────────────────────
void main() {
  // ── A. Broken formula produces constant AV desync ─────────────────────────

  group('Broken audio PTS (no master-clock anchor)', () {
    // Scenario: recorder starts, master clock advances 50 ms before the first
    // WASAPI loopback callback arrives.  Video uses rec.now() so its first PTS
    // is ~50 000 µs.  Audio uses the broken frame counter starting at 0, so
    // its first PTS is 0.
    //
    // After saveClip subtracts originPts (≈ cutoffPts, which is on the
    // master-clock scale), audio comes out negative by exactly that offset.
    // avoid_negative_ts=make_zero then shifts ALL streams by the magnitude of
    // the most-negative PTS — pushing video forward relative to audio.

    const int sampleRate = 48000;
    const int samplesPerChunk = 480; // 10 ms at 48 kHz
    const int audioChunkDurationUs = samplesPerChunk * 1000000 ~/ sampleRate;

    test('first audio PTS is 0 when broken formula used', () {
      expect(_brokenAudioPts(0, sampleRate), equals(0));
    });

    test('first video PTS reflects master clock delay', () {
      const int masterClockAtFirstVideoFrameUs = 50000; // 50 ms
      expect(_videoPts(masterClockAtFirstVideoFrameUs), equals(50000));
    });

    test('audio PTS is always behind video PTS by the startup delay', () {
      // After 1 second of recording:
      //   video pts ≈ startDelay + 1_000_000
      //   audio pts ≈ 1_000_000  (no start offset)
      // Difference = startDelay = 50 ms → visible desync.
      const int startDelayUs = 50000;
      const int recordedUs = 1000000;
      const int chunksAfter1s = recordedUs ~/ audioChunkDurationUs;

      final lastAudioPts = _brokenAudioPts(
        chunksAfter1s * samplesPerChunk,
        sampleRate,
      );
      final correspondingVideoPts = _videoPts(startDelayUs + recordedUs);

      // Broken: audio lags video by exactly the startup delay.
      expect(
        correspondingVideoPts - lastAudioPts,
        closeTo(startDelayUs, audioChunkDurationUs),
        reason:
            'Broken formula: audio PTS should lag video by the startup delay '
            '(~$startDelayUs µs)',
      );
    });

    test('saveClip rebasing exposes broken audio/video offset', () {
      // Scenario: recorder runs for 1 second. The master clock started 50 ms
      // before the first WASAPI loopback callback, so:
      //   video PTSs: 50_000, 83_333 … (rec.now() — on the master clock)
      //   audio PTSs:      0, 10_000 … (broken: frame counter from 0)
      //
      // At any given wall-clock time T, the audio PTS is T − startDelayUs
      // while the video PTS is T. The two timelines diverge by startDelayUs.
      //
      // We verify this directly: for each video PTS, compute the audio PTS
      // that corresponds to the same recording instant and check that it is
      // startDelayUs smaller than the video PTS.
      const int startDelayUs = 50000;
      const int sampleRate = 48000;
      const int samplesPerChunk = 480;
      const int chunkDurUs = samplesPerChunk * 1000000 ~/ sampleRate;

      // Wall-clock times at which we sample (multiples of the audio chunk
      // duration so both streams produce packets there).
      final wallTimes = [100000, 200000, 500000, 900000]; // µs into recording

      for (final wallUs in wallTimes) {
        // Video PTS = rec.now() = startDelayUs + wallUs.
        final videoPtsAtWall = _videoPts(startDelayUs + wallUs);

        // Audio PTS (broken) at the same wall time: the chunk that started at
        // frame index floor((wallUs) / chunkDurUs).
        final chunkIndex = wallUs ~/ chunkDurUs;
        final audioPtsAtWall = _brokenAudioPts(
          chunkIndex * samplesPerChunk,
          sampleRate,
        );

        // The two timelines differ by startDelayUs at every wall-clock sample.
        expect(
          videoPtsAtWall - audioPtsAtWall,
          closeTo(startDelayUs, chunkDurUs),
          reason:
              'At wall time $wallUs µs: video PTS=$videoPtsAtWall, '
              'audio PTS (broken)=$audioPtsAtWall — '
              'should differ by startDelayUs=$startDelayUs',
        );
      }
    });
  });

  // ── B. Fixed formula eliminates desync ────────────────────────────────────

  group('Fixed audio PTS (anchored to master clock)', () {
    const int sampleRate = 48000;
    const int samplesPerChunk = 480; // 10 ms at 48 kHz

    test('first audio PTS equals the master-clock snapshot', () {
      const int audioStartUs = 50000; // 50 ms — when first callback fires
      expect(_fixedAudioPts(0, sampleRate, audioStartUs), equals(audioStartUs));
    });

    test('subsequent audio PTSs advance by exactly audioChunkDurationUs', () {
      const int audioStartUs = 50000;
      const int chunkDurUs = samplesPerChunk * 1000000 ~/ sampleRate;

      final pts0 = _fixedAudioPts(0, sampleRate, audioStartUs);
      final pts1 = _fixedAudioPts(samplesPerChunk, sampleRate, audioStartUs);
      final pts2 = _fixedAudioPts(
        2 * samplesPerChunk,
        sampleRate,
        audioStartUs,
      );

      expect(pts1 - pts0, equals(chunkDurUs));
      expect(pts2 - pts1, equals(chunkDurUs));
    });

    test('after 1 s, audio and video PTSs differ by at most one audio frame', () {
      const int startDelayUs = 50000;
      const int audioStartUs = startDelayUs; // captured at first loopback
      const int recordedUs = 1000000;
      const int samplesAfter1s =
          (recordedUs ~/ (samplesPerChunk * 1000000 ~/ sampleRate)) *
          samplesPerChunk;
      const int chunkDurUs = samplesPerChunk * 1000000 ~/ sampleRate;

      final lastAudioPts = _fixedAudioPts(
        samplesAfter1s,
        sampleRate,
        audioStartUs,
      );
      final correspondingVideoPts = _videoPts(startDelayUs + recordedUs);

      // Fixed: difference should be at most one audio chunk duration (~10 ms).
      expect(
        (correspondingVideoPts - lastAudioPts).abs(),
        lessThanOrEqualTo(chunkDurUs),
        reason:
            'Fixed formula: audio and video PTSs should differ by at most one '
            'audio frame (${chunkDurUs} µs = 10 ms)',
      );
    });

    test('saveClip rebasing yields non-negative audio PTS after fix', () {
      const int startDelayUs = 50000;
      const int windowUs = 300000;

      // Video: 3 packets at 33 ms intervals starting at 50 ms.
      final videoPts = _videoPtsList(startDelayUs, 33333, 3);
      // Audio (fixed): 3 packets at 10 ms intervals starting at startDelayUs.
      final audioPts = _audioFixedPtsList(
        startDelayUs,
        samplesPerChunk,
        sampleRate,
        3,
      );

      final allPts = [...videoPts, ...audioPts];
      final maxPts = allPts.reduce((a, b) => a > b ? a : b);

      final chunks = [
        for (final p in videoPts)
          _Chunk(
            trackIndex: 0,
            isAudio: false,
            ptsUs: p,
            isKeyframe: p == videoPts.first,
          ),
        for (final p in audioPts)
          _Chunk(trackIndex: 1, isAudio: true, ptsUs: p),
      ];

      final originPts = _computeOriginPts(chunks, maxPts, windowUs);

      for (final chunk in chunks) {
        final rebased = _rebasedPts(chunk, originPts);
        expect(
          rebased,
          greaterThanOrEqualTo(0),
          reason:
              'Fixed formula: rebased PTS for track '
              '${chunk.trackIndex} at original ${chunk.ptsUs} µs should be '
              '>= 0 (got $rebased)',
        );
      }
    });

    test(
      'audio/video relative offset after rebasing is at most one audio frame',
      () {
        // Verify that after saveClip rebasing, the difference between the first
        // audio PTS and the first video PTS is within one audio chunk duration.
        const int startDelayUs = 47000; // realistic: ~47 ms startup jitter
        const int windowUs = 5000000; // 5 s clip

        final videoPts = _videoPtsList(
          startDelayUs,
          33333,
          150,
        ); // 5 s of 30fps
        final audioPts = _audioFixedPtsList(
          startDelayUs,
          samplesPerChunk,
          sampleRate,
          500, // 5 s of audio
        );

        final allPts = [...videoPts, ...audioPts];
        final maxPts = allPts.reduce((a, b) => a > b ? a : b);

        final chunks = [
          for (var i = 0; i < videoPts.length; i++)
            _Chunk(
              trackIndex: 0,
              isAudio: false,
              ptsUs: videoPts[i],
              isKeyframe: i == 0,
            ),
          for (final p in audioPts)
            _Chunk(trackIndex: 1, isAudio: true, ptsUs: p),
        ];

        final originPts = _computeOriginPts(chunks, maxPts, windowUs);
        final inWindow = chunks.where((c) => _rebasedPts(c, originPts) >= 0);
        final firstVideo = inWindow
            .where((c) => !c.isAudio)
            .map((c) => _rebasedPts(c, originPts))
            .reduce(min);
        final firstAudio = inWindow
            .where((c) => c.isAudio)
            .map((c) => _rebasedPts(c, originPts))
            .reduce(min);

        const int chunkDurUs = samplesPerChunk * 1000000 ~/ sampleRate;
        expect(
          (firstAudio - firstVideo).abs(),
          lessThanOrEqualTo(chunkDurUs),
          reason:
              'After rebasing, audio and video should start within one audio '
              'frame of each other (≤ ${chunkDurUs} µs). '
              'firstAudio=$firstAudio firstVideo=$firstVideo',
        );
      },
    );
  });

  // ── C. saveClip originPts logic ───────────────────────────────────────────

  group('saveClip originPts / cutoff math', () {
    test('originPts equals cutoffPts when buffer covers the full window', () {
      // 10 packets spaced 100 ms apart — buffer covers 900 ms.
      // Request a 500 ms clip.
      final chunks = List.generate(
        10,
        (i) => _Chunk(trackIndex: 0, isAudio: false, ptsUs: i * 100000),
      );
      final maxPts = 900000;
      const windowUs = 500000;
      final originPts = _computeOriginPts(chunks, maxPts, windowUs);
      // cutoffPts = 900_000 - 500_000 = 400_000
      // earliestPts in window = 400_000
      // cutoffPts == earliestPts → originPts = cutoffPts = 400_000
      expect(originPts, equals(400000));
    });

    test('originPts equals earliestPts when buffer younger than window', () {
      // Buffer only covers 200 ms, but we request a 500 ms window.
      final chunks = List.generate(
        3,
        (i) => _Chunk(trackIndex: 0, isAudio: false, ptsUs: i * 100000),
      );
      final maxPts = 200000;
      const windowUs = 500000;
      final originPts = _computeOriginPts(chunks, maxPts, windowUs);
      // cutoffPts = 200_000 - 500_000 = -300_000
      // earliestPts in window = 0 (all chunks are >= cutoffPts)
      // cutoffPts < earliestPts → originPts = earliestPts = 0
      expect(originPts, equals(0));
    });

    test(
      'rebased first packet is always 0 when buffer younger than window',
      () {
        final chunks = List.generate(
          3,
          (i) => _Chunk(trackIndex: 0, isAudio: false, ptsUs: i * 100000),
        );
        final maxPts = 200000;
        const windowUs = 500000;
        final originPts = _computeOriginPts(chunks, maxPts, windowUs);
        expect(_rebasedPts(chunks.first, originPts), equals(0));
      },
    );

    test('rebased PTS monotonically increases for sorted packets', () {
      final chunks = List.generate(
        20,
        (i) => _Chunk(trackIndex: 0, isAudio: false, ptsUs: i * 33333),
      );
      final maxPts = chunks.last.ptsUs;
      const windowUs = 500000;
      final originPts = _computeOriginPts(chunks, maxPts, windowUs);

      final inWindow =
          chunks.where((c) => c.ptsUs >= maxPts - windowUs).toList()
            ..sort((a, b) => a.ptsUs.compareTo(b.ptsUs));

      int prev = -1;
      for (final c in inWindow) {
        final rebased = _rebasedPts(c, originPts);
        expect(rebased, greaterThan(prev));
        prev = rebased;
      }
    });

    test('both tracks have same rebased start when anchored to same clock', () {
      // Simulate ideal: video and audio start at exactly the same time.
      const int baseUs = 100000; // 100 ms into master clock
      const int sampleRate = 48000;
      const int samplesPerChunk = 480;

      final videoPts = _videoPtsList(baseUs, 33333, 30); // ~1 s
      final audioPts = _audioFixedPtsList(
        baseUs,
        samplesPerChunk,
        sampleRate,
        100,
      );

      final allPts = [...videoPts, ...audioPts];
      final maxPts = allPts.reduce((a, b) => a > b ? a : b);
      const windowUs = 1000000;

      final chunks = [
        for (var i = 0; i < videoPts.length; i++)
          _Chunk(
            trackIndex: 0,
            isAudio: false,
            ptsUs: videoPts[i],
            isKeyframe: i == 0,
          ),
        for (final p in audioPts)
          _Chunk(trackIndex: 1, isAudio: true, ptsUs: p),
      ];

      final originPts = _computeOriginPts(chunks, maxPts, windowUs);
      final inWindow = chunks
          .where((c) => _rebasedPts(c, originPts) >= 0)
          .toList();

      final firstRebasedVideo = inWindow
          .where((c) => !c.isAudio)
          .map((c) => _rebasedPts(c, originPts))
          .reduce(min);
      final firstRebasedAudio = inWindow
          .where((c) => c.isAudio)
          .map((c) => _rebasedPts(c, originPts))
          .reduce(min);

      const int chunkDurUs = samplesPerChunk * 1000000 ~/ sampleRate;
      expect(
        (firstRebasedVideo - firstRebasedAudio).abs(),
        lessThanOrEqualTo(chunkDurUs),
        reason:
            'Tracks anchored to the same clock should have the same rebased '
            'start (within one audio frame). '
            'video=$firstRebasedVideo audio=$firstRebasedAudio',
      );
    });
  });

  // ── D. Edge cases ─────────────────────────────────────────────────────────

  group('Edge cases', () {
    test('_framesOut increments are strictly additive (no PTS holes)', () {
      // Simulate 5 consecutive loopback callbacks of varying size and verify
      // that the resulting PTSs form a contiguous sequence with no gaps.
      const int sampleRate = 48000;
      const int audioStartUs = 35000;
      final chunkSizes = [480, 480, 512, 480, 448]; // slightly variable

      var framesOut = 0;
      final ptsList = <int>[];
      final durList = <int>[];
      for (final sz in chunkSizes) {
        ptsList.add(_fixedAudioPts(framesOut, sampleRate, audioStartUs));
        durList.add(sz * 1000000 ~/ sampleRate);
        framesOut += sz;
      }

      // Each PTS should equal the previous PTS + previous duration.
      for (var i = 1; i < ptsList.length; i++) {
        expect(
          ptsList[i],
          equals(ptsList[i - 1] + durList[i - 1]),
          reason:
              'PTS gap between chunk $i and ${i - 1}: '
              '${ptsList[i]} != ${ptsList[i - 1]} + ${durList[i - 1]}',
        );
      }
    });

    test('audio-only clip: originPts anchors correctly', () {
      // No video track — originPts must still equal cutoffPts (or earliestPts
      // if buffer is younger), and the first rebased PTS should be 0.
      const int audioStartUs = 80000;
      const int sampleRate = 48000;
      const int samplesPerChunk = 480;

      final audioPts = _audioFixedPtsList(
        audioStartUs,
        samplesPerChunk,
        sampleRate,
        100,
      );
      final chunks = [
        for (final p in audioPts)
          _Chunk(trackIndex: 0, isAudio: true, ptsUs: p),
      ];
      final maxPts = audioPts.last;
      const windowUs = 500000;

      final originPts = _computeOriginPts(chunks, maxPts, windowUs);
      final inWindow = chunks.where((c) => _rebasedPts(c, originPts) >= 0);
      final firstRebased = inWindow
          .map((c) => _rebasedPts(c, originPts))
          .reduce(min);

      expect(firstRebased, equals(0));
    });

    test(
      '_audioStartUs captured only once (idempotent after first callback)',
      () {
        // Simulate the ??= assignment: the start offset must not change even if
        // the clock advances.
        int? audioStartUs;
        final masterClockValues = [45000, 55000, 65000, 75000];

        for (final clockNow in masterClockValues) {
          audioStartUs ??= clockNow;
        }

        // Only the first value (45_000) should stick.
        expect(audioStartUs, equals(45000));
      },
    );

    test('large startup delay (200 ms) is fully compensated by the fix', () {
      const int startDelayUs = 200000; // 200 ms — extreme startup lag
      const int sampleRate = 48000;
      const int samplesPerChunk = 480;
      const int audioStartUs = startDelayUs;
      const int windowUs = 1000000;

      final videoPts = _videoPtsList(startDelayUs, 33333, 30);
      final audioPts = _audioFixedPtsList(
        audioStartUs,
        samplesPerChunk,
        sampleRate,
        100,
      );

      final allPts = [...videoPts, ...audioPts];
      final maxPts = allPts.reduce((a, b) => a > b ? a : b);

      final chunks = [
        for (var i = 0; i < videoPts.length; i++)
          _Chunk(
            trackIndex: 0,
            isAudio: false,
            ptsUs: videoPts[i],
            isKeyframe: i == 0,
          ),
        for (final p in audioPts)
          _Chunk(trackIndex: 1, isAudio: true, ptsUs: p),
      ];

      final originPts = _computeOriginPts(chunks, maxPts, windowUs);

      // Every rebased PTS must be >= 0.
      for (final c in chunks) {
        final rebased = _rebasedPts(c, originPts);
        if (c.ptsUs >= maxPts - windowUs) {
          expect(
            rebased,
            greaterThanOrEqualTo(0),
            reason:
                'track=${c.isAudio ? "audio" : "video"} original=${c.ptsUs}: '
                'rebased=$rebased must be >= 0 even with 200 ms startup delay',
          );
        }
      }
    });
  });

  // ── E. Capture-gap silence fill (capture-timestamp based) ────────────────
  //
  // The AAC encoder derives every output packet's PTS from the cumulative
  // sample COUNT fed to it (the wall-clock ptsUs we pass only slowly slews its
  // epoch). WASAPI loopback delivers NOTHING while the render endpoint is
  // idle, so without intervention the fed sample count falls behind and every
  // packet after the gap plays early — a growing A/V desync.
  //
  // Gaps are detected on the buffers' native CAPTURE timestamps, never on
  // arrival-time drift: when the isolate stalls, the native capture thread
  // keeps queueing packets which then arrive late in a burst. Arrival drift
  // looks identical to an idle gap, but the burst is capture-contiguous and
  // no samples are missing — filling (or snapping) there inserts phantom
  // silence and desyncs everything after the stall.

  group('Capture-gap silence fill (capture-timestamp based)', () {
    const int sampleRate = 48000;
    const int chunkFrames = 480; // 10 ms callbacks
    const int chunkDurUs = chunkFrames * 1000000 ~/ sampleRate; // 10 000
    const int captureGapThresholdUs = 30000; // 30 ms
    const int maxGapFillUs = 60000000; // 60 s
    const int snapThresholdUs = 5000000; // 5 s — catastrophic only

    // Mirrors the runtime state machine: capture-gap fill + catastrophic
    // snap + emitted-PTS-from-sample-count. `state` holds epoch, emitted,
    // expectedCapture, tsValid (as 0/1). Returns the emitted PTS.
    int simulateCallback(
      Map<String, int> state, {
      required int wallUs,
      required int captureUs,
      int frameCount = chunkFrames,
    }) {
      var epoch = state['epoch']!;
      var emitted = state['emitted']!;

      // Capture-gap fill.
      if (state['tsValid']! != 0) {
        final gapUs = captureUs - state['expectedCapture']!;
        if (gapUs > captureGapThresholdUs) {
          final fillUs = gapUs > maxGapFillUs ? maxGapFillUs : gapUs;
          emitted += fillUs * sampleRate ~/ 1000000; // silence injected
        }
      }
      state['expectedCapture'] =
          captureUs + frameCount * 1000000 ~/ sampleRate;
      state['tsValid'] = 1;

      // Catastrophic snap only.
      final drift = (epoch + emitted * 1000000 ~/ sampleRate) - wallUs;
      if (drift < -snapThresholdUs) {
        epoch = wallUs - emitted * 1000000 ~/ sampleRate;
      }
      final pts = epoch + emitted * 1000000 ~/ sampleRate;
      emitted += frameCount;
      state['epoch'] = epoch;
      state['emitted'] = emitted;
      return pts;
    }

    Map<String, int> freshState() =>
        {'epoch': 0, 'emitted': 0, 'expectedCapture': 0, 'tsValid': 0};

    test('true idle gap (capture jump) is filled — resumed PTS on clock', () {
      final state = freshState();
      // 2 s of normal callbacks; capture time == wall time (no stall).
      var t = 0;
      for (var i = 0; i < 200; i++) {
        simulateCallback(state, wallUs: t, captureUs: t);
        t += chunkDurUs;
      }
      // 5 s idle gap: nothing captured, nothing delivered.
      t += 5000000;
      final resumePts = simulateCallback(state, wallUs: t, captureUs: t);
      expect(
        (resumePts - t).abs(),
        lessThanOrEqualTo(2 * chunkDurUs),
        reason:
            'After the capture-gap fill, the resumed packet PTS must land on '
            'the clock (got $resumePts vs $t)',
      );
      // Fed sample count (incl. fill) must equal elapsed capture time.
      final fedUs = state['emitted']! * 1000000 ~/ sampleRate;
      expect(fedUs - t, inInclusiveRange(0, 2 * chunkDurUs));
    });

    test(
      'delivery burst after a 300 ms isolate stall: NO fill, NO snap, '
      'PTS stays content-contiguous',
      () {
        final state = freshState();
        var t = 0;
        final pts = <int>[];
        for (var i = 0; i < 100; i++) {
          pts.add(simulateCallback(state, wallUs: t, captureUs: t));
          t += chunkDurUs;
        }
        // Isolate stalls for 300 ms: the native thread kept capturing, so 30
        // packets with CONTIGUOUS capture times all arrive at the same late
        // wall time (t + 300 ms).
        final stallEndWall = t + 300000;
        for (var i = 0; i < 30; i++) {
          pts.add(
            simulateCallback(
              state,
              wallUs: stallEndWall,
              captureUs: t + i * chunkDurUs,
            ),
          );
        }
        // No fill: emitted grew by exactly 130 chunks.
        expect(
          state['emitted'],
          equals(130 * chunkFrames),
          reason: 'A capture-contiguous burst must never be silence-filled',
        );
        // PTS spacing stayed exactly one chunk throughout the burst — the
        // burst packets keep their content timeline (no snap mislabel).
        for (var i = 1; i < pts.length; i++) {
          expect(
            pts[i] - pts[i - 1],
            equals(chunkDurUs),
            reason: 'PTS must stay content-contiguous through the burst',
          );
        }
      },
    );

    test('capture-time jitter below threshold never fills', () {
      final state = freshState();
      var injectedAny = false;
      for (var i = 0; i < 300; i++) {
        final t = i * chunkDurUs;
        final jitter = (i % 5 - 2) * 5000; // ±10 ms capture-stamp noise
        final before = state['emitted']!;
        simulateCallback(state, wallUs: t, captureUs: t + jitter);
        if (state['emitted']! - before > chunkFrames) injectedAny = true;
      }
      expect(
        injectedAny,
        isFalse,
        reason: 'Sub-threshold capture jitter must never inject silence',
      );
    });

    test('gap beyond the 60 s fill cap: fill caps, snap absorbs the rest', () {
      final state = freshState();
      var t = 0;
      for (var i = 0; i < 100; i++) {
        simulateCallback(state, wallUs: t, captureUs: t);
        t += chunkDurUs;
      }
      t += 120000000; // 2 min idle gap
      final resumePts = simulateCallback(state, wallUs: t, captureUs: t);
      expect(
        (resumePts - t).abs(),
        lessThanOrEqualTo(2 * chunkDurUs),
        reason:
            'Fill covers 60 s, the catastrophic snap must absorb the '
            'remainder so the resumed PTS still lands on the clock',
      );
    });
  });
}
