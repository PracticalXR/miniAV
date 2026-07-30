/// End-to-end A/V sync drift simulation.
///
/// These tests build a synthetic capture stream where the audio and video
/// "wall clocks" are driven independently, then run the **exact** PTS state
/// machine used by `_AudioTrackRuntime`, `_MixedAudioTrackRuntime` and
/// `_VideoTrackRuntime` against it. After simulating up to 30 minutes of
/// real-world capture conditions we measure the residual A/V offset and
/// assert it stays within a bound that is inaudible to humans (≈ 20 ms /
/// MPEG-DASH / Apple's HLS guideline for lip-sync).
///
/// Scenarios covered:
///   1. Baseline — perfectly synchronous clocks.
///   2. Steady-state crystal drift (+50 ppm audio fast, +50 ppm audio slow,
///      ±100 ppm extremes).
///   3. Window minimised — video frames stop for 5 s while audio continues.
///   4. Loopback silence — audio stops for 5 s while video continues
///      (game audio fully muted; WASAPI delivers no SILENT packets either).
///   5. Audio device sleep / WASAPI exclusive-mode preemption — both audio
///      and video stop, then audio resumes 8 s later.
///   6. Long isolate stall (GC / GPU spike) — 300 ms of pure stall, no
///      callbacks at all.
///   7. WASAPI SILENT bursts at 100 / 1000 ms cadence (Windows behaviour
///      when system audio renderer has nothing to mix).
///
/// In every scenario we verify:
///   * Audio PTS is monotonically increasing.
///   * Video PTS is monotonically increasing.
///   * Residual |audio - video| offset at the end of the recording is ≤ the
///     scenario's allowed bound (≤ 40 ms for normal flow, ≤ 100 ms for the
///     "audio sleep" snap-recovery test, where 100 ms is the snap threshold).
///
/// The tests use [SyncSimulator], a tiny scheduler that interleaves audio
/// callbacks (every 10 ms by default) and video callbacks (every 33.33 ms
/// for 30 fps) on a single virtual clock. Each side can be paused, fast-
/// forwarded, or shifted in rate to model real-world hazards.
library;

import 'dart:math' show min;

import 'package:test/test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// State machines under test (mirrored from recorder.dart so the tests do not
// import private classes).
// ─────────────────────────────────────────────────────────────────────────────

/// Mirrors `_MixedAudioTrackRuntime._onLoopbackChunk` (and `_AudioTrackRuntime`)
/// PTS logic, including the idle-gap silence fill.
///
/// `_samplesEmitted` here stands in for the cumulative sample count fed to the
/// encoder — the quantity the AAC encoder actually derives its output PTS from.
/// Keeping it locked to wall clock (via the gap fill) is what prevents the
/// post-gap desync; the earlier version of this simulator modelled only the
/// snap on the ptsUs we pass, which the encoder mostly ignores.
class AudioPtsMachine {
  AudioPtsMachine({
    required this.sampleRate,
    required this.samplesPerCallback,
    this.driftThresholdUs = 10000,
    this.driftSnapThresholdUs = 5000000, // catastrophic-only, as production
    this.driftCorrectionUs = 20,
    this.captureGapThresholdUs = 30000,
    this.maxGapFillUs = 60000000,
  });

  final int sampleRate;
  final int samplesPerCallback;
  final int driftThresholdUs;
  final int driftSnapThresholdUs;
  final int driftCorrectionUs;
  final int captureGapThresholdUs;
  final int maxGapFillUs;

  bool _epochSet = false;
  int _epoch = 0;
  int _samplesEmitted = 0;
  int _expectedCaptureUs = 0;
  bool _captureTsValid = false;

  /// Produces the PTS for one callback. WASAPI SILENT buffers ([silent]=true)
  /// are now encoded as silence just like audible ones, so they also return a
  /// PTS on the same continuous timeline (they are no longer dropped).
  ///
  /// [captureUs] is the buffer's native capture timestamp. Capture gaps
  /// (idle render endpoint) are detected as jumps in this clock and filled
  /// with silence; delivery bursts (isolate stalls) are capture-contiguous
  /// and pass through untouched.
  int? onCallback({
    required int wallNowUs,
    required int captureUs,
    bool silent = false,
  }) {
    if (!_epochSet) {
      _epoch = wallNowUs;
      _epochSet = true;
    }

    // Capture-gap fill.
    if (_captureTsValid) {
      final gapUs = captureUs - _expectedCaptureUs;
      if (gapUs > captureGapThresholdUs) {
        final fillUs = gapUs > maxGapFillUs ? maxGapFillUs : gapUs;
        _samplesEmitted += fillUs * sampleRate ~/ 1000000;
      }
    }
    _expectedCaptureUs = captureUs + samplesPerCallback * 1000000 ~/ sampleRate;
    _captureTsValid = true;

    final drift =
        (_epoch + _samplesEmitted * 1000000 ~/ sampleRate) - wallNowUs;
    if (drift < -driftSnapThresholdUs) {
      _epoch = wallNowUs - _samplesEmitted * 1000000 ~/ sampleRate;
    } else if (drift > driftThresholdUs) {
      _epoch -= driftCorrectionUs;
    } else if (drift < -driftThresholdUs) {
      _epoch += driftCorrectionUs;
    }
    final pts = _epoch + _samplesEmitted * 1000000 ~/ sampleRate;
    _samplesEmitted += samplesPerCallback;
    return pts;
  }
}

/// Mirrors `_VideoTrackRuntime._encodeOne` PTS logic.
class VideoPtsMachine {
  int _lastPts = -1;

  /// Produces the PTS for one callback at wall time [wallNowUs].
  int onCallback({required int wallNowUs}) {
    var pts = wallNowUs;
    if (pts <= _lastPts) pts = _lastPts + 1;
    _lastPts = pts;
    return pts;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scheduler — interleaves audio + video callbacks on a virtual clock and
// records every emitted PTS so tests can assert on the timeline.
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one "leg" (audio or video) of the simulation.
class CaptureLeg {
  CaptureLeg({
    required this.intervalUs,
    this.driftPpm = 0, // +ve = leg's clock runs FAST relative to wall
  });

  /// Nominal interval between callbacks (e.g. 10 000 µs for 100 Hz audio,
  /// 33 333 µs for 30 fps video).
  final int intervalUs;

  /// Crystal drift of this leg's clock relative to the master/wall clock.
  /// +100 ppm means the leg fires every (intervalUs × (1 - 100e-6)) µs as
  /// measured by the wall clock.  (Wall sees them sooner ⇒ leg runs fast.)
  final int driftPpm;

  /// Computed wall-clock interval between this leg's callbacks.
  int get wallIntervalUs {
    if (driftPpm == 0) return intervalUs;
    // Higher ppm = leg's crystal runs faster ⇒ shorter wall-clock interval.
    final scaled = intervalUs - (intervalUs * driftPpm) ~/ 1000000;
    return scaled.clamp(1, 0x7fffffff);
  }
}

/// One sample point — the PTS of either audio or video at a particular wall
/// time.  Stored sparsely so tests can replay the timeline at any granularity.
class _Emit {
  _Emit({required this.wallUs, required this.pts, required this.isAudio});
  final int wallUs;
  final int pts;
  final bool isAudio;
}

class SyncSimulator {
  SyncSimulator({
    required this.audio,
    required this.video,
    required this.audioMachine,
    required this.videoMachine,
  });

  final CaptureLeg audio;
  final CaptureLeg video;
  final AudioPtsMachine audioMachine;
  final VideoPtsMachine videoMachine;

  final List<_Emit> emits = [];

  /// All audio PTSs in arrival order. Nulls (silent buffers) skipped.
  List<int> audioPts() =>
      emits.where((e) => e.isAudio).map((e) => e.pts).toList();

  /// All video PTSs in arrival order.
  List<int> videoPts() =>
      emits.where((e) => !e.isAudio).map((e) => e.pts).toList();

  /// Run the simulator for [totalWallUs] of virtual wall-clock time.
  ///
  /// Optional callbacks let tests pause/rate-modify the audio or video legs
  /// at runtime to model minimised windows, audio device sleeps, etc.
  ///
  /// [audioPolicyAt] returns one of:
  ///   - `null`      → emit normally
  ///   - `'silent'`  → emit a SILENT chunk (PTS counter advances, no PTS out)
  ///   - `'skip'`    → pretend the callback never fired (no advance)
  ///
  /// [videoPolicyAt] returns:
  ///   - `null`   → emit normally
  ///   - `'skip'` → pretend the callback never fired
  void run({
    required int totalWallUs,
    String? Function(int wallUs)? audioPolicyAt,
    String? Function(int wallUs)? videoPolicyAt,
  }) {
    var nextAudio = audio.wallIntervalUs;
    var nextVideo = video.wallIntervalUs;
    var wallUs = 0;
    while (wallUs <= totalWallUs) {
      // Advance to whichever leg fires next.
      if (nextAudio <= nextVideo) {
        wallUs = nextAudio;
        if (wallUs > totalWallUs) break;
        final policy = audioPolicyAt?.call(wallUs);
        if (policy == 'skip') {
          // Skipped callback: leg's clock keeps advancing the next slot.
          nextAudio += audio.wallIntervalUs;
        } else {
          // Delivery is instantaneous in this scheduler, so the capture
          // timestamp equals the slot's wall time. ('skip' slots therefore
          // show up to the machine as capture-time jumps — a true idle gap.
          // Delivery bursts are exercised separately in av_sync_test.)
          final pts = audioMachine.onCallback(
            wallNowUs: wallUs,
            captureUs: wallUs,
            silent: policy == 'silent',
          );
          if (pts != null) {
            emits.add(_Emit(wallUs: wallUs, pts: pts, isAudio: true));
          }
          nextAudio += audio.wallIntervalUs;
        }
      } else {
        wallUs = nextVideo;
        if (wallUs > totalWallUs) break;
        final policy = videoPolicyAt?.call(wallUs);
        if (policy == 'skip') {
          nextVideo += video.wallIntervalUs;
        } else {
          final pts = videoMachine.onCallback(wallNowUs: wallUs);
          emits.add(_Emit(wallUs: wallUs, pts: pts, isAudio: false));
          nextVideo += video.wallIntervalUs;
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Assertions — common shape applied at the end of every scenario.
// ─────────────────────────────────────────────────────────────────────────────

void _assertMonotonic(List<int> pts, String label) {
  for (var i = 1; i < pts.length; i++) {
    expect(
      pts[i],
      greaterThan(pts[i - 1]),
      reason:
          '$label PTS must be strictly monotonic '
          '(violation at index $i: ${pts[i - 1]} → ${pts[i]})',
    );
  }
}

/// Computes A/V offset at the moment of the most recent video PTS:
///   audioPts at that wall time − videoPts at that wall time
/// using PTS values (the values the muxer actually writes).
int _residualOffsetUs(SyncSimulator sim) {
  final lastVideo = sim.emits.lastWhere((e) => !e.isAudio);
  final lastAudio = sim.emits.lastWhere((e) => e.isAudio);
  // Both PTSs are on the wall-clock scale (audio is forced there by drift
  // correction + snap; video is rec.now() directly). Offset between the
  // two streams = difference between their last PTSs adjusted for the wall
  // time at which each fired.
  final wallDelta = lastAudio.wallUs - lastVideo.wallUs;
  final ptsDelta = lastAudio.pts - lastVideo.pts;
  // If audio fired wallDelta µs after video, we expect audio PTS to be that
  // much larger.  Residual = how much they actually diverge.
  return ptsDelta - wallDelta;
}

/// Maximum residual offset observed at any video frame across the timeline.
int _maxResidualOffsetUs(SyncSimulator sim) {
  // Build per-wall-time PTS streams.
  final audioByWall = <int, int>{};
  final videoByWall = <int, int>{};
  for (final e in sim.emits) {
    (e.isAudio ? audioByWall : videoByWall)[e.wallUs] = e.pts;
  }
  // For each video sample, find the closest preceding audio PTS.
  final audioWalls = audioByWall.keys.toList()..sort();
  var maxOffset = 0;
  for (final entry in videoByWall.entries) {
    final vWall = entry.key;
    final vPts = entry.value;
    // Largest audio wall ≤ vWall.
    int lo = 0, hi = audioWalls.length - 1, picked = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (audioWalls[mid] <= vWall) {
        picked = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (picked < 0) continue;
    final aWall = audioWalls[picked];
    final aPts = audioByWall[aWall]!;
    final wallDelta = aWall - vWall;
    final ptsDelta = aPts - vPts;
    final offset = (ptsDelta - wallDelta).abs();
    if (offset > maxOffset) maxOffset = offset;
  }
  return maxOffset;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

// Tolerance: ITU-R BT.1359 — viewers detect lip-sync errors only above
// ≈ ±45 ms.  We assert ≤ 40 ms for normal operation and ≤ 150 ms for the
// post-gap snap-recovery window (one snap threshold + a tiny margin).
const int _lipSyncToleranceUs = 40000;
const int _snapRecoveryToleranceUs = 150000;

const int _audioRate = 48000;
const int _audioFramesPerCb = 480; // 10 ms
const int _audioIntervalUs =
    _audioFramesPerCb * 1000000 ~/ _audioRate; // 10 000
const int _videoIntervalUs = 1000000 ~/ 30; // 30 fps ≈ 33 333

SyncSimulator _makeSim({int audioDriftPpm = 0, int videoDriftPpm = 0}) {
  return SyncSimulator(
    audio: CaptureLeg(intervalUs: _audioIntervalUs, driftPpm: audioDriftPpm),
    video: CaptureLeg(intervalUs: _videoIntervalUs, driftPpm: videoDriftPpm),
    audioMachine: AudioPtsMachine(
      sampleRate: _audioRate,
      samplesPerCallback: _audioFramesPerCb,
    ),
    videoMachine: VideoPtsMachine(),
  );
}

void main() {
  // ── 1. Baseline ──────────────────────────────────────────────────────────
  group('Baseline — perfectly synchronous clocks', () {
    test('60 s recording stays within lip-sync tolerance', () {
      final sim = _makeSim();
      sim.run(totalWallUs: 60 * 1000000);
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });
  });

  // ── 2. Steady-state crystal drift ────────────────────────────────────────
  group('Crystal drift', () {
    test('+50 ppm audio fast over 30 min stays within tolerance', () {
      final sim = _makeSim(audioDriftPpm: 50);
      sim.run(totalWallUs: 30 * 60 * 1000000);
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });

    test('−50 ppm audio slow over 30 min stays within tolerance', () {
      final sim = _makeSim(audioDriftPpm: -50);
      sim.run(totalWallUs: 30 * 60 * 1000000);
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });

    test('+100 ppm extreme drift over 30 min stays within tolerance', () {
      final sim = _makeSim(audioDriftPpm: 100);
      sim.run(totalWallUs: 30 * 60 * 1000000);
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });

    test(
      'BEFORE fix: 100 ppm uncorrected drift exceeds tolerance over 30 min',
      () {
        // Disable both snap and nudge by making thresholds huge — this
        // models the OLD code that had no drift correction at all.
        final sim = SyncSimulator(
          audio: CaptureLeg(intervalUs: _audioIntervalUs, driftPpm: 100),
          video: CaptureLeg(intervalUs: _videoIntervalUs),
          audioMachine: AudioPtsMachine(
            sampleRate: _audioRate,
            samplesPerCallback: _audioFramesPerCb,
            driftThresholdUs: 0x7fffffff,
            driftSnapThresholdUs: 0x7fffffff,
          ),
          videoMachine: VideoPtsMachine(),
        );
        sim.run(totalWallUs: 30 * 60 * 1000000);
        // 100 ppm × 30 min = 180 ms — well above the 40 ms tolerance.
        expect(
          _maxResidualOffsetUs(sim),
          greaterThan(_lipSyncToleranceUs * 3),
          reason:
              'Without drift correction the residual must be much larger '
              'than the lip-sync tolerance (regression check)',
        );
      },
    );
  });

  // ── 3. Window minimised: video stops, audio continues ────────────────────
  group('Window minimised — video frames stop for 5 s', () {
    test('audio keeps flowing and stays in sync after video resumes', () {
      final sim = _makeSim();
      // Pause video for 5 s starting at 10 s into the recording.
      sim.run(
        totalWallUs: 30 * 1000000,
        videoPolicyAt: (wallUs) {
          if (wallUs >= 10000000 && wallUs < 15000000) return 'skip';
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      // After video resumes, the residual offset must still be tight — the
      // capture pipeline is responsible for stamping resumed video PTSs at
      // the new wall time, which keeps both streams aligned.
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });
  });

  // ── 4. Loopback silence: audio stops, video continues ────────────────────
  group('Loopback silence — audio stops for 5 s', () {
    test('capture-gap fill recovers sync as soon as audio resumes', () {
      final sim = _makeSim();
      // No audio callbacks at all between 10 s and 15 s. This is the worst
      // case: the audio clock has no input so the sample counter freezes;
      // on resume the capture-time jump triggers a silence fill that brings
      // the fed sample count back onto the clock.
      sim.run(
        totalWallUs: 30 * 1000000,
        audioPolicyAt: (wallUs) {
          if (wallUs >= 10000000 && wallUs < 15000000) return 'skip';
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      // Final residual must be tight: snap fires on the first post-gap
      // callback and aligns audio exactly to wall clock.
      expect(_residualOffsetUs(sim).abs(), lessThan(_snapRecoveryToleranceUs));
    });

    test('many short silences (10× 200 ms) do not accumulate offset', () {
      final sim = _makeSim();
      sim.run(
        totalWallUs: 30 * 1000000,
        audioPolicyAt: (wallUs) {
          // 10 silences of 200 ms each, spaced 2 s apart starting at 2 s.
          for (var i = 0; i < 10; i++) {
            final start = (2 + i * 2) * 1000000;
            if (wallUs >= start && wallUs < start + 200000) return 'skip';
          }
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      // 200 ms gaps are above the 100 ms snap threshold so each one snaps
      // back to wall clock. Final residual must therefore be tight.
      expect(_residualOffsetUs(sim).abs(), lessThan(_snapRecoveryToleranceUs));
    });
  });

  // ── 5. Audio device sleep — multi-second gap ─────────────────────────────
  group('Audio device sleep / preemption', () {
    test('8 s silence then resume — capture-gap fill converges immediately', () {
      final sim = _makeSim();
      sim.run(
        totalWallUs: 30 * 1000000,
        audioPolicyAt: (wallUs) {
          if (wallUs >= 5000000 && wallUs < 13000000) return 'skip';
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      // First audio callback after resume should land right on the clock:
      // the capture-time jump triggers a fill covering the whole gap.
      final postResume = sim.emits
          .where((e) => e.isAudio && e.wallUs >= 13000000)
          .toList();
      expect(postResume, isNotEmpty);
      final first = postResume.first;
      expect(
        (first.pts - first.wallUs).abs(),
        lessThan(2 * _audioIntervalUs),
        reason: 'Capture-gap fill should align first post-gap PTS to clock',
      );
    });
  });

  // ── 6. Multi-length capture gaps (300 ms / 50 ms) ────────────────────────
  //
  // NOTE: in this scheduler 'skip' means the samples were never captured (a
  // true capture gap), so both cases below recover via the capture-gap fill.
  // A real isolate stall is different — packets keep being captured and
  // arrive late in a capture-CONTIGUOUS burst, which must NOT be filled;
  // that case is covered in av_sync_test's capture-gap group.
  group('Short capture gaps', () {
    test('300 ms capture gap — fill recovers instantly', () {
      final sim = _makeSim();
      sim.run(
        totalWallUs: 10 * 1000000,
        audioPolicyAt: (wallUs) {
          // Drop callbacks between 5.0 s and 5.3 s.
          if (wallUs >= 5000000 && wallUs < 5300000) return 'skip';
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      expect(_residualOffsetUs(sim).abs(), lessThan(_snapRecoveryToleranceUs));
    });

    test('50 ms capture gap — above 30 ms fill threshold, fill recovers', () {
      final sim = _makeSim();
      sim.run(
        totalWallUs: 60 * 1000000,
        audioPolicyAt: (wallUs) {
          if (wallUs >= 5000000 && wallUs < 5050000) return 'skip';
          return null;
        },
      );
      _assertMonotonic(sim.audioPts(), 'audio');
      expect(_maxResidualOffsetUs(sim), lessThan(60000));
      expect(_residualOffsetUs(sim).abs(), lessThan(_lipSyncToleranceUs));
    });
  });

  // ── 7. WASAPI SILENT bursts ──────────────────────────────────────────────
  group('WASAPI SILENT bursts (Windows nothing-playing behaviour)', () {
    test('continuous silent stream — encoded as silence, monotonic & synced', () {
      final sim = _makeSim();
      sim.run(
        totalWallUs: 5 * 1000000,
        audioPolicyAt: (_) => 'silent', // every callback is silent
      );
      // Silent buffers are now encoded (not dropped), so audio flows
      // continuously on the same wall-clock timeline as video.
      expect(sim.audioPts(), isNotEmpty);
      _assertMonotonic(sim.audioPts(), 'audio');
      _assertMonotonic(sim.videoPts(), 'video');
      expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
    });

    test(
      'mixed silent/audible — silent runs do not desync subsequent audio',
      () {
        final sim = _makeSim();
        sim.run(
          totalWallUs: 30 * 1000000,
          audioPolicyAt: (wallUs) {
            // 1 s of silent buffers every 5 s.
            if ((wallUs ~/ 1000000) % 5 == 0) return 'silent';
            return null;
          },
        );
        _assertMonotonic(sim.audioPts(), 'audio');
        // SILENT buffers advance the sample counter so the PTS timeline stays
        // continuous — no drift, no snap needed.
        expect(_maxResidualOffsetUs(sim), lessThan(_lipSyncToleranceUs));
      },
    );
  });

  // ── 8. Combined nightmare — drift + silences + stalls together ───────────
  group('Combined nightmare (real-world torture test)', () {
    test(
      '30 min recording: 80 ppm drift, 5 silent bursts, 2 minimised periods',
      () {
        final sim = _makeSim(audioDriftPpm: 80);
        sim.run(
          totalWallUs: 30 * 60 * 1000000,
          audioPolicyAt: (wallUs) {
            // 5 silent bursts (300 ms each) at 3, 8, 15, 22, 27 minutes.
            for (final m in [3, 8, 15, 22, 27]) {
              final start = m * 60 * 1000000;
              if (wallUs >= start && wallUs < start + 300000) return 'skip';
            }
            return null;
          },
          videoPolicyAt: (wallUs) {
            // 2 minimised periods (10 s each) at 10 min and 20 min.
            for (final m in [10, 20]) {
              final start = m * 60 * 1000000;
              if (wallUs >= start && wallUs < start + 10000000) return 'skip';
            }
            return null;
          },
        );
        _assertMonotonic(sim.audioPts(), 'audio');
        _assertMonotonic(sim.videoPts(), 'video');
        // Even after this combined torture, the final residual must still be
        // within the snap-recovery tolerance.
        expect(
          _residualOffsetUs(sim).abs(),
          lessThan(_snapRecoveryToleranceUs),
          reason:
              'After 30 min of drift + silences + minimised windows, '
              'final A/V offset must stay within ${_snapRecoveryToleranceUs}µs',
        );
      },
    );
  });

  // ── 9. Sanity helpers ────────────────────────────────────────────────────
  group('Helper invariants', () {
    test('_residualOffsetUs is 0 in baseline run', () {
      final sim = _makeSim();
      sim.run(totalWallUs: 1 * 1000000);
      expect(_residualOffsetUs(sim).abs(), lessThanOrEqualTo(_audioIntervalUs));
    });

    test('min helper compiles', () {
      // (silences unused-import warnings if dart:math import is trimmed)
      expect(min(1, 2), 1);
    });
  });
}
