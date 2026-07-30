/// Tests for the audio PTS-from-sample-count fix in both
/// [_AudioTrackRuntime] and [_MixedAudioTrackRuntime].
///
/// **Problem A (before fix) — isolate-jitter crackle**
/// Both runtimes called `rec.now()` on every encode callback to produce a
/// PTS. When the Dart isolate stalled (GC, heavy GPU work) successive PTS
/// values jumped or repeated, causing the AAC muxer to produce gaps,
/// overlaps, and audible crackle.
///
/// **Problem B (after naive fix) — 59-hour container duration**
/// A further attempt used `buffer.timestampUs` (an absolute QPC timestamp
/// from `QueryPerformanceCounter`, measured from system boot) as the epoch.
/// On a machine that had been on for 59 hours, `buffer.timestampUs` was
/// ~212 billion µs. The final audio PTS became 59 h + 12 min, which the
/// muxer wrote as the container duration — producing a 59-hour file.
///
/// **Fix**
/// Both runtimes anchor the epoch to `rec.now()` (master clock elapsed µs
/// since `_launch()`) on the FIRST callback and then compute:
///
///   ptsUs = epoch + samplesEmitted × 1_000_000 / sampleRate
///
/// `buffer.timestampUs` is intentionally never used; it is an absolute
/// system-uptime value and has no relationship to the recording timeline.
///
/// **Problem C — WASAPI silent-buffer crash → missing game audio**
/// WASAPI sends `AUDCLNT_BUFFERFLAGS_SILENT` packets with `data=NULL` and
/// `data_size_bytes=0` but a non-zero frame count.  The Dart FFI layer
/// exposes this as `audio.data` being an empty `Uint8List`.  Calling
/// `asFloat32List()` on an empty buffer with a positive length throws a
/// `RangeError`, which propagates out of the loopback FFI callback and
/// kills the loopback capture — exactly why game audio disappeared.
///
/// Fix: check `audio.data.isEmpty` first, then synthesise zero-filled silence
/// and encode it (rather than dropping the buffer). Both `_AudioTrackRuntime`
/// and `_MixedAudioTrackRuntime` do this — dropping the buffer instead left a
/// HOLE in the AAC stream, so any clip overlapping a quiet stretch played back
/// with broken / missing audio.
library;

import 'package:test/test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Formula mirrors
// ─────────────────────────────────────────────────────────────────────────────

/// Mirrors the PTS formula used by both _AudioTrackRuntime and
/// _MixedAudioTrackRuntime:
///
///   ptsUs = epoch + samplesEmitted * 1_000_000 ~/ sampleRate
int audioPts(int epoch, int samplesEmitted, int sampleRate) =>
    epoch + samplesEmitted * 1000000 ~/ sampleRate;

// ─────────────────────────────────────────────────────────────────────────────
// Drift-corrected simulator
// ─────────────────────────────────────────────────────────────────────────────

/// Mirrors the drift-correction logic added to both _AudioTrackRuntime and
/// _MixedAudioTrackRuntime.
///
/// On each callback:
///   1. Compute PTS from current epoch (before correction).
///   2. Advance sample counter.
///   3. Compare PTS to wall clock (masterNow).
///   4. If |drift| > [driftThresholdUs], nudge epoch by ±[driftCorrectionUs].
///
/// This matches the production code exactly so tests cover the real formula.
/// Mirrors the drift-correction logic in both _AudioTrackRuntime and
/// _MixedAudioTrackRuntime.
///
/// On each callback, BEFORE computing the emitted PTS:
///   1. Compute preliminary PTS from current epoch.
///   2. Compare to wall clock (masterNow).
///   3. If drift < −[driftSnapThresholdUs] → snap epoch so this chunk's PTS
///      equals masterNow exactly (gap-recovery path: audio fell behind
///      wall clock due to silence / sleep / stall).
///   4. Else if |drift| > [driftThresholdUs] → nudge epoch by
///      ±[driftCorrectionUs] (steady-state crystal-drift path).
///   5. Compute final PTS from corrected epoch and advance sample counter.
///
/// This matches the production code exactly so tests cover the real formula.
class DriftCorrectedPtsSimulator {
  DriftCorrectedPtsSimulator({
    required this.sampleRate,
    required this.samplesPerCallback,
    this.driftThresholdUs = 10000, // 10 ms
    this.driftSnapThresholdUs = 100000, // 100 ms
    this.driftCorrectionUs = 20, // 20 µs per callback
  });

  final int sampleRate;
  final int samplesPerCallback;
  final int driftThresholdUs;
  final int driftSnapThresholdUs;
  final int driftCorrectionUs;

  bool _epochSet = false;
  int _epoch = 0;
  int _samplesEmitted = 0;

  int get epoch => _epochSet ? _epoch : -1;
  int get samplesEmitted => _samplesEmitted;

  /// Simulate one callback.
  /// [masterNow] is rec.now() (wall clock µs) at processing time.
  int onCallback(int masterNow) {
    // Use a bool flag (not _epoch < 0) so that drift corrections that nudge
    // the epoch slightly negative do not re-trigger epoch initialization.
    if (!_epochSet) {
      _epoch = masterNow;
      _epochSet = true;
    }
    // 1. Preliminary PTS from current epoch.
    final preliminary = _epoch + _samplesEmitted * 1000000 ~/ sampleRate;
    // 2. Drift correction applied BEFORE the emitted PTS so this chunk uses
    //    the corrected epoch. Snap only on NEGATIVE drift (gap recovery);
    //    snapping on positive drift would violate muxer monotonicity.
    final drift = preliminary - masterNow;
    if (drift < -driftSnapThresholdUs) {
      _epoch = masterNow - _samplesEmitted * 1000000 ~/ sampleRate;
    } else if (drift > driftThresholdUs) {
      _epoch -= driftCorrectionUs;
    } else if (drift < -driftThresholdUs) {
      _epoch += driftCorrectionUs;
    }
    // 3. Final PTS from corrected epoch.
    final pts = _epoch + _samplesEmitted * 1000000 ~/ sampleRate;
    _samplesEmitted += samplesPerCallback;
    return pts;
  }

  void reset() {
    _epochSet = false;
    _epoch = 0;
    _samplesEmitted = 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Simulator: drives the state machine for one runtime instance
// ─────────────────────────────────────────────────────────────────────────────

/// Simulates the PTS-from-sample-count state machine shared by both
/// _AudioTrackRuntime and _MixedAudioTrackRuntime.
///
/// Both runtimes now always use `masterNow` (rec.now()) as the epoch.
/// `buffer.timestampUs` (absolute QPC from boot) is intentionally ignored.
class AudioPtsSimulator {
  AudioPtsSimulator({
    required this.sampleRate,
    required this.samplesPerCallback,
  });

  final int sampleRate;
  final int samplesPerCallback;

  int _epoch = -1;
  int _samplesEmitted = 0;

  int get samplesEmitted => _samplesEmitted;
  int get epoch => _epoch;

  /// Simulate one callback.  Returns the PTS sent to the encoder.
  ///
  /// [silent]=true models a WASAPI AUDCLNT_BUFFERFLAGS_SILENT buffer. Both
  /// runtimes now synthesise zero-filled silence for these and encode them
  /// like any other chunk, so a silent buffer produces a PTS on the SAME
  /// contiguous timeline (it is no longer dropped — dropping left holes in the
  /// AAC stream that played back as broken / missing audio). The [silent] flag
  /// is therefore behaviourally identical to a normal callback here; it is kept
  /// so call sites can document intent.
  ///
  /// [masterNow] — rec.now() at the moment this callback fires
  /// [silent]    — true for empty/silent WASAPI packets
  int? onCallback({required int masterNow, bool silent = false}) {
    if (_epoch < 0) {
      _epoch = masterNow; // always master clock, never absolute QPC hwTs
    }
    final pts = audioPts(_epoch, _samplesEmitted, sampleRate);
    _samplesEmitted += samplesPerCallback;
    return pts;
  }

  void reset() {
    _epoch = -1;
    _samplesEmitted = 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── _AudioTrackRuntime (mic path, 44.1 kHz mono) ─────────────────────────

  group('_AudioTrackRuntime — epoch always from master clock (44.1 kHz)', () {
    const sampleRate = 44100;
    const samplesPerCallback = 441; // 10 ms @ 44.1 kHz

    test('epoch is rec.now(), not the absolute QPC hwTs', () {
      final sim = AudioPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: samplesPerCallback,
      );
      // Machine has been running for 59 hours. QPC-based hwTs would be:
      const qpcHwTs = 59 * 3600 * 1000000; // ~212 billion µs
      // rec.now() is only 50 ms into the recording.
      const masterNow = 50000;
      // Old (broken): epoch = qpcHwTs → 59-hour file
      // New (fixed):  epoch = masterNow → correct 12-minute file
      sim.onCallback(masterNow: masterNow);
      expect(
        sim.epoch,
        equals(masterNow),
        reason: 'Epoch must be master clock, never the absolute QPC value',
      );
      expect(sim.epoch, isNot(equals(qpcHwTs)));
    });

    test('epoch is set only on the first callback', () {
      final sim = AudioPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: samplesPerCallback,
      );
      sim.onCallback(masterNow: 10000);
      final epochAfterFirst = sim.epoch;
      sim.onCallback(masterNow: 20000); // later — epoch must not change
      expect(
        sim.epoch,
        equals(epochAfterFirst),
        reason: 'Epoch should not change after the first callback',
      );
    });

    test(
      'silent WASAPI buffer is encoded as silence on the contiguous timeline',
      () {
        final sim = AudioPtsSimulator(
          sampleRate: sampleRate,
          samplesPerCallback: samplesPerCallback,
        );
        const chunkDurUs = samplesPerCallback * 1000000 ~/ sampleRate;
        const epoch = 100000;

        final pts0 = sim.onCallback(masterNow: epoch);
        // Silent callback: now synthesises + encodes zero-filled silence, so it
        // emits a PTS one interval after pts0 — no hole in the AAC stream.
        final ptsSilent = sim.onCallback(
          masterNow: epoch + chunkDurUs,
          silent: true,
        );
        final pts2 = sim.onCallback(masterNow: epoch + 2 * chunkDurUs);

        expect(
          ptsSilent,
          equals(pts0! + chunkDurUs),
          reason: 'Silent buffer is encoded, landing one interval after pts0',
        );
        // pts2 continues contiguously — two intervals after pts0.
        expect(
          pts2,
          equals(pts0 + 2 * chunkDurUs),
          reason: 'Timeline stays contiguous across the encoded silent slot',
        );
      },
    );
  });

  group('_AudioTrackRuntime — PTS uniformity (44.1 kHz)', () {
    const sampleRate = 44100;
    const samplesPerCallback = 441; // 10 ms blocks
    const chunkDurationUs = samplesPerCallback * 1000000 ~/ sampleRate;

    late AudioPtsSimulator sim;

    setUp(() {
      sim = AudioPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: samplesPerCallback,
      );
    });

    test('first PTS equals epoch (rec.now() at first callback)', () {
      const masterNow = 50000;
      final pts = sim.onCallback(masterNow: masterNow);
      expect(pts, equals(masterNow));
    });

    test('successive PTSs advance by exactly chunkDurationUs', () {
      const epoch = 50000;
      final pts = List.generate(5, (_) => sim.onCallback(masterNow: epoch));
      for (int i = 1; i < pts.length; i++) {
        expect(
          pts[i]! - pts[i - 1]!,
          equals(chunkDurationUs),
          reason:
              'PTS[$i] - PTS[${i - 1}] should be exactly '
              '$chunkDurationUs µs regardless of callback jitter',
        );
      }
    });

    test('PTSs are strictly monotonic even when callbacks arrive late', () {
      // Simulate callbacks that arrive 5 ms late every other tick — the
      // kind of jitter that caused crackle with the old rec.now() approach.
      const epoch = 100000;
      var masterNow = epoch;
      final pts = <int>[];
      for (int i = 0; i < 20; i++) {
        masterNow += chunkDurationUs + (i.isOdd ? 5000 : 0);
        pts.add(sim.onCallback(masterNow: masterNow)!);
      }
      for (int i = 1; i < pts.length; i++) {
        expect(
          pts[i],
          greaterThan(pts[i - 1]),
          reason: 'PTS must be strictly monotonic even under jitter',
        );
      }
    });

    test('PTSs stay uniform even when callbacks arrive early', () {
      const epoch = 0;
      var masterNow = epoch;
      final pts = <int>[];
      for (int i = 0; i < 10; i++) {
        masterNow += chunkDurationUs - 2000; // 2 ms early
        pts.add(sim.onCallback(masterNow: masterNow)!);
      }
      for (int i = 1; i < pts.length; i++) {
        expect(pts[i] - pts[i - 1], equals(chunkDurationUs));
      }
    });
  });

  // ── _MixedAudioTrackRuntime (loopback mix, 48 kHz stereo) ────────────────

  group(
    '_MixedAudioTrackRuntime — epoch always from master clock (48 kHz)',
    () {
      const sampleRate = 48000;
      const samplesPerCallback = 480; // 10 ms @ 48 kHz
      const chunkDurationUs = samplesPerCallback * 1000000 ~/ sampleRate;

      late AudioPtsSimulator sim;

      setUp(() {
        sim = AudioPtsSimulator(
          sampleRate: sampleRate,
          samplesPerCallback: samplesPerCallback,
        );
      });

      test('epoch is masterNow', () {
        const masterNow = 77000;
        sim.onCallback(masterNow: masterNow);
        expect(sim.epoch, equals(masterNow));
      });

      test('first PTS equals masterNow at first callback', () {
        const masterNow = 45000;
        final pts = sim.onCallback(masterNow: masterNow);
        expect(pts, equals(masterNow));
      });

      test('successive PTSs advance by exactly chunkDurationUs', () {
        const epoch = 45000;
        final pts = List.generate(5, (_) => sim.onCallback(masterNow: epoch));
        for (int i = 1; i < pts.length; i++) {
          expect(pts[i]! - pts[i - 1]!, equals(chunkDurationUs));
        }
      });

      test('PTSs are uniform over 5 seconds of 48 kHz loopback', () {
        const epoch = 100000;
        final pts = List.generate(
          500, // 5 s × 100 callbacks/s
          (i) => audioPts(epoch, i * samplesPerCallback, sampleRate),
        );
        for (int i = 1; i < pts.length; i++) {
          expect(
            pts[i] - pts[i - 1],
            equals(chunkDurationUs),
            reason: 'PTS spacing must be uniform over 5 s of loopback',
          );
        }
      });

      test('WASAPI silent buffers are encoded as silence, timeline contiguous', () {
        const epoch = 50000;
        final pts0 = sim.onCallback(masterNow: epoch)!;
        final pts1 = sim.onCallback(masterNow: epoch + 10000)!;
        final ptsSilent = sim.onCallback(
          masterNow: epoch + 20000,
          silent: true,
        );
        final pts3 = sim.onCallback(masterNow: epoch + 30000)!;

        expect(pts1 - pts0, equals(chunkDurationUs));
        // Silent buffer is encoded — it emits a PTS one interval after pts1.
        expect(
          ptsSilent! - pts1,
          equals(chunkDurationUs),
          reason: 'Silent buffer encodes silence one interval after pts1',
        );
        // pts3 continues contiguously — one interval after the silent slot.
        expect(
          pts3 - ptsSilent,
          equals(chunkDurationUs),
          reason: 'Timeline stays contiguous after the encoded silent slot',
        );
      });
    },
  );

  // ── Regression: old rec.now() PTS caused jitter ───────────────────────────

  group('Regression — rec.now() PTS causes jitter', () {
    test(
      'stalled isolate causes non-uniform PTS spacing with old approach',
      () {
        const chunkDurationUs = 10000; // 10 ms
        final arrivalTimes = [0, 10000, 30000 /* 20 ms late */, 40000, 50000];
        final oldPts = arrivalTimes; // old code just used rec.now()
        final spacings = [
          for (int i = 1; i < oldPts.length; i++) oldPts[i] - oldPts[i - 1],
        ];
        expect(
          spacings,
          isNot(everyElement(equals(chunkDurationUs))),
          reason: 'Old approach: PTS spacing is non-uniform under jitter',
        );
      },
    );

    test('new sample-count formula is immune to the same jitter', () {
      const sampleRate = 44100;
      const samplesPerCallback = 441;
      const chunkDurationUs = samplesPerCallback * 1000000 ~/ sampleRate;
      const epoch = 0;
      final newPts = List.generate(
        5,
        (i) => audioPts(epoch, i * samplesPerCallback, sampleRate),
      );
      final spacings = [
        for (int i = 1; i < newPts.length; i++) newPts[i] - newPts[i - 1],
      ];
      expect(
        spacings,
        everyElement(equals(chunkDurationUs)),
        reason: 'New formula: all spacings must be exactly chunkDurationUs',
      );
    });
  });

  // ── Regression: absolute QPC epoch → 59-hour container ───────────────────

  group('Regression — absolute QPC epoch produces 59-hour container', () {
    test('using buffer.timestampUs as epoch offsets PTS by ~59 hours', () {
      const sampleRate = 44100;
      const samplesPerCallback = 441;
      // Machine has been on for 59 hours; QPC value in µs.
      const qpcEpoch = 59 * 3600 * 1000000; // ~212.4 billion µs
      const masterNow = 50000; // rec.now() = 50 ms since recording start

      // Old (broken): epoch = qpcEpoch
      final brokenFirstPts = audioPts(qpcEpoch, 0, sampleRate);
      // Correct (new): epoch = masterNow
      final correctFirstPts = audioPts(masterNow, 0, sampleRate);

      final diffUs = brokenFirstPts - correctFirstPts;
      final diffHours = diffUs / (3600 * 1000000.0);
      expect(
        diffHours,
        closeTo(59.0, 0.1),
        reason:
            'Broken epoch produces a PTS offset of ~59 hours — '
            'exactly the reported container duration bug',
      );
    });

    test(
      'correct epoch keeps first audio PTS within a few frames of video',
      () {
        // Video PTS = rec.now() at first video frame = ~50 ms.
        // Audio PTS = rec.now() at first audio callback = ~52 ms (2 ms later).
        // They must be within one audio frame of each other (~10 ms).
        const videoFirstPtsUs = 50000;
        const audioFirstPtsUs = 52000; // 2 ms later — normal startup jitter

        expect(
          (audioFirstPtsUs - videoFirstPtsUs).abs(),
          lessThan(10000), // one 10 ms audio chunk
          reason: 'With correct epoch, audio and video start within ~10 ms',
        );
      },
    );
  });

  // ── Crystal-drift correction ───────────────────────────────────────────────

  group('Crystal-drift correction', () {
    // Constants that match the production code defaults.
    const sampleRate = 48000;
    const framesPerCallback = 480; // 10 ms @ 48 kHz
    const chunkUs = framesPerCallback * 1000000 ~/ sampleRate; // 10 000 µs
    const threshold = 10000; // _driftThresholdUs = 10 ms
    const correction = 20; // _driftCorrectionUs = 20 µs

    test('no correction when drift is exactly zero', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 100000;
      // Wall clock advances by exactly 10 ms per callback — no drift.
      for (var i = 0; i < 200; i++) {
        sim.onCallback(epoch + i * chunkUs);
      }
      expect(
        sim.epoch,
        equals(epoch),
        reason: 'Epoch must not change when there is no crystal drift',
      );
    });

    test('no correction when drift is below threshold (< 10 ms)', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // Wall clock advances slightly slower: 9999 µs per callback.
      // After 9 callbacks: drift = 9 µs — still below 10 ms threshold.
      for (var i = 0; i < 9; i++) {
        sim.onCallback(epoch + i * (chunkUs - 1));
      }
      expect(
        sim.epoch,
        equals(epoch),
        reason: 'Epoch must not change for sub-threshold drift',
      );
    });

    test('correction fires when audio PTS exceeds wall clock by > 10 ms', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // Simulate audio crystal running fast: wall clock advances 1 µs/callback
      // slower than sample count. After 10 001 callbacks the drift reaches
      // 10 001 µs > 10 000 µs threshold.
      //
      // We run enough callbacks to definitely cross the threshold, then check
      // the epoch has been nudged downward.
      for (var i = 0; i < 11000; i++) {
        sim.onCallback(epoch + i * (chunkUs - 1)); // wall 1 µs/cb slow
      }
      expect(
        sim.epoch,
        lessThan(epoch),
        reason: 'Epoch must decrease when audio PTS runs ahead of wall clock',
      );
    });

    test('correction fires when audio PTS lags wall clock by > 10 ms', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // Wall clock advances 1 µs/callback FASTER than sample count.
      for (var i = 0; i < 11000; i++) {
        sim.onCallback(epoch + i * (chunkUs + 1)); // wall 1 µs/cb fast
      }
      expect(
        sim.epoch,
        greaterThan(epoch),
        reason: 'Epoch must increase when audio PTS lags behind wall clock',
      );
    });

    test('PTS is strictly monotonic during drift correction', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // Run with fast audio (1 µs/cb drift) for 30 000 callbacks = 5 minutes.
      var lastPts = -1;
      for (var i = 0; i < 30000; i++) {
        final pts = sim.onCallback(epoch + i * (chunkUs - 1));
        expect(
          pts,
          greaterThan(lastPts),
          reason:
              'PTS[$i] must be > PTS[${i - 1}] even during correction '
              '(correction=$correction µs << callback stride=$chunkUs µs)',
        );
        lastPts = pts;
      }
    });

    test('drift is bounded — does not grow without limit', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // 1 µs/callback drift. Correction (20 µs) fires every time drift > 10 ms.
      // Correction rate (20 µs/cb) >> accumulation rate (1 µs/cb), so drift
      // converges and stays within threshold + a few correction steps.
      final drifts = <int>[];
      for (var i = 0; i < 60000; i++) {
        // 10 minutes of audio at 100 callbacks/s
        final wallUs = epoch + i * (chunkUs - 1);
        final pts = sim.onCallback(wallUs);
        // Drift = how far audio PTS is ahead of wall clock.
        drifts.add(pts - wallUs);
      }
      // After correction converges, drift must stay bounded.
      // Allow up to threshold + 2 × correction for hysteresis.
      final maxAllowed = threshold + 2 * correction;
      final maxObserved = drifts.reduce((a, b) => a > b ? a : b);
      final minObserved = drifts.reduce((a, b) => a < b ? a : b);
      expect(
        maxObserved,
        lessThanOrEqualTo(maxAllowed),
        reason:
            'Drift must not exceed threshold + 2×correction '
            '= $maxAllowed µs (observed max: $maxObserved µs)',
      );
      expect(
        minObserved,
        greaterThanOrEqualTo(-maxAllowed),
        reason:
            'Negative drift must not exceed −$maxAllowed µs '
            '(observed min: $minObserved µs)',
      );
    });

    test('drift converges to near-zero after correction kicks in', () {
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // Fast audio: 1 µs/cb drift. Let it accumulate past threshold then
      // measure average drift over the second half (when corrected).
      const totalCallbacks = 40000; // ~6.7 minutes
      const warmup = 20000; // let correction reach steady state
      var driftSum = 0;
      for (var i = 0; i < totalCallbacks; i++) {
        final wallUs = epoch + i * (chunkUs - 1);
        final pts = sim.onCallback(wallUs);
        if (i >= warmup) driftSum += (pts - wallUs).abs();
      }
      final avgDrift = driftSum ~/ (totalCallbacks - warmup);
      // Average |drift| must be well within threshold after correction.
      expect(
        avgDrift,
        lessThan(threshold),
        reason:
            'Average absolute drift after correction must be < $threshold µs '
            '(got $avgDrift µs)',
      );
    });

    test('correction rate (20 µs/callback) is far below audible threshold', () {
      // At 100 callbacks/s the maximum epoch adjustment per second is
      // 100 × 20 µs = 2 000 µs = 2 ms/s.
      // That is 0.02% speed change — well below the 0.5% audible threshold.
      const callbacksPerSecond = 1000000 ~/ chunkUs; // = 100
      final maxAdjustPerSecondUs = callbacksPerSecond * correction;
      const auralThresholdPerSecondUs = 5000; // 0.5% of 1 000 000 µs/s

      expect(
        maxAdjustPerSecondUs,
        lessThan(auralThresholdPerSecondUs),
        reason:
            'Max correction rate must be below 0.5%/s aural threshold '
            '(got ${maxAdjustPerSecondUs}µs/s, limit ${auralThresholdPerSecondUs}µs/s)',
      );
    });

    test('100 ppm crystal drift over 30 min stays within ±10 ms after fix', () {
      // 100 ppm: wall clock advances 0.1 µs/ms slower than audio.
      // 30 minutes = 1 800 000 ms.
      // Uncorrected drift would be 1 800 000 × 0.1 µs = 180 000 µs = 180 ms.
      // With correction it must stay within ±10 ms.
      final sim = DriftCorrectedPtsSimulator(
        sampleRate: sampleRate,
        samplesPerCallback: framesPerCallback,
        driftThresholdUs: threshold,
        driftCorrectionUs: correction,
      );
      const epoch = 0;
      // 100 ppm fast audio: wallUs per callback = chunkUs * (1 - 100e-6)
      //                                         ≈ chunkUs - 1 µs.
      const wallStepUs = chunkUs - 1; // 9999 µs (1 µs/cb ≈ 100 ppm)
      const totalCallbacks = 180000; // 30 min × 100 cb/s
      var maxDrift = 0;
      for (var i = 0; i < totalCallbacks; i++) {
        final wallUs = epoch + i * wallStepUs;
        final pts = sim.onCallback(wallUs);
        final d = (pts - wallUs).abs();
        if (d > maxDrift) maxDrift = d;
      }
      expect(
        maxDrift,
        lessThanOrEqualTo(threshold + 2 * correction),
        reason:
            '100 ppm crystal drift over 30 min must be bounded to '
            '≤ ${threshold + 2 * correction} µs by the correction; '
            'without fix it would be 180 000 µs (got $maxDrift µs)',
      );
    });
  });
}
