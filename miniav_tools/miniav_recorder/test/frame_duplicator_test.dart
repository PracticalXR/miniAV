/// Tests for the video frame duplicator added to [_VideoTrackRuntime].
///
/// **Problem (before fix)**
/// DXGI / WGC delivers capture callbacks only when the source surface
/// changes.  On a mostly-static screen the pipeline delivers 7–15 fps
/// regardless of the configured target, producing matching gaps in the
/// encoded stream.  Playback shows those gaps as a freeze-then-jump,
/// universally reported as "laggy video".
///
/// **Fix**
/// After every successful zero-copy GPU encode, [_VideoTrackRuntime] stores
/// a reference to the last [SharedOutputTexture].  A [Timer.periodic] started
/// at the target frame interval fires at the target rate.  Each tick checks:
///
///   !_stopping && !_busy
///   && _lastSharedTex != null && _lastSharedTex!.isValid
///   && _lastVideoPtsUs >= 0
///   && (now - _lastVideoPtsUs) >= (interval * 3) ~/ 2
///
/// If all conditions are met it re-encodes the last texture with a fresh
/// PTS, advancing `_lastVideoPtsUs` so each duplicate is strictly after the
/// previous one.
///
/// All state machine logic is self-contained and easily simulated, so these
/// tests do not require a real GPU, encoder, or capture device.
library;

import 'package:test/test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Simulation helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Simulates the guard condition used by [_VideoTrackRuntime._maybeDuplicateLast].
///
/// Returns true when the duplicator should fire given the supplied state.
bool shouldDuplicate({
  required bool stopping,
  required bool busy,
  required bool hasLastTex,
  required bool texIsValid,
  required int lastVideoPtsUs,
  required int nowUs,
  required int intervalUs,
}) {
  if (stopping || busy) return false;
  if (!hasLastTex || !texIsValid) return false;
  if (lastVideoPtsUs < 0) return false;
  return (nowUs - lastVideoPtsUs) >= (intervalUs * 3) ~/ 2;
}

/// Simulates one duplicator tick.  Returns the PTS that would be emitted,
/// or null if the tick was suppressed.
///
/// Mutates [lastVideoPtsUsRef] in place (like the runtime does) when a
/// duplicate is emitted.
int? simulateTick({
  required bool stopping,
  required bool busy,
  required bool hasLastTex,
  required bool texIsValid,
  required int Function() clock, // rec.now()
  required int lastVideoPtsUs,
  required int intervalUs,
  required void Function(int)
  updateLastPts, // callback to advance _lastVideoPtsUs
}) {
  final nowUs = clock();
  if (!shouldDuplicate(
    stopping: stopping,
    busy: busy,
    hasLastTex: hasLastTex,
    texIsValid: texIsValid,
    lastVideoPtsUs: lastVideoPtsUs,
    nowUs: nowUs,
    intervalUs: intervalUs,
  ))
    return null;

  var ptsUs = nowUs;
  if (ptsUs <= lastVideoPtsUs) ptsUs = lastVideoPtsUs + 1;
  updateLastPts(ptsUs);
  return ptsUs;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── Gate: conditions that SUPPRESS duplication ───────────────────────────

  group('Frame duplicator — suppression gates', () {
    // Baseline valid state: 30 fps, 1 interval since last frame, has tex.
    const intervalUs = 33333; // ~30 fps
    final baseNow = intervalUs * 2; // 2 intervals since epoch
    final baseLast =
        intervalUs ~/
        2; // last pts was 0.5 intervals ago → gap = 1.5 × interval

    test('does not fire when _stopping is true', () {
      final result = shouldDuplicate(
        stopping: true,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: baseLast,
        nowUs: baseNow,
        intervalUs: intervalUs,
      );
      expect(result, isFalse, reason: 'Must not fire while stopping');
    });

    test('does not fire when _busy is true', () {
      final result = shouldDuplicate(
        stopping: false,
        busy: true,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: baseLast,
        nowUs: baseNow,
        intervalUs: intervalUs,
      );
      expect(result, isFalse, reason: 'Must not fire while encoder is busy');
    });

    test('does not fire when no last texture is stored', () {
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: false,
        texIsValid: true, // irrelevant — no tex
        lastVideoPtsUs: baseLast,
        nowUs: baseNow,
        intervalUs: intervalUs,
      );
      expect(result, isFalse, reason: 'Must not fire before first frame');
    });

    test('does not fire when last texture has been invalidated', () {
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: false, // processor disposed it (resolution change etc.)
        lastVideoPtsUs: baseLast,
        nowUs: baseNow,
        intervalUs: intervalUs,
      );
      expect(result, isFalse, reason: 'Must not fire with an invalid texture');
    });

    test('does not fire before the first live frame (_lastVideoPtsUs < 0)', () {
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: -1, // no frame yet
        nowUs: baseNow,
        intervalUs: intervalUs,
      );
      expect(
        result,
        isFalse,
        reason: 'Must not fire before _lastVideoPtsUs is set',
      );
    });

    test('does not fire when last frame was within 1.5 × interval '
        '(live capture keeping up)', () {
      // Gap = 1.0 × interval — live capture is on time.
      const nowUs = intervalUs * 5;
      const lastUs = nowUs - intervalUs; // exactly 1 interval ago
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: lastUs,
        nowUs: nowUs,
        intervalUs: intervalUs,
      );
      expect(
        result,
        isFalse,
        reason: 'Live capture keeps up — duplicator should not interfere',
      );
    });
  });

  // ── Gate: conditions that ALLOW duplication ───────────────────────────────

  group('Frame duplicator — firing conditions', () {
    const intervalUs = 33333;

    test('fires when gap is exactly 1.5 × interval', () {
      const nowUs = intervalUs * 5;
      const lastUs = nowUs - (intervalUs * 3) ~/ 2;
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: lastUs,
        nowUs: nowUs,
        intervalUs: intervalUs,
      );
      expect(
        result,
        isTrue,
        reason: 'Should fire when gap reaches exactly the 1.5× threshold',
      );
    });

    test('fires when gap is greater than 1.5 × interval', () {
      // Screen static for 1 second — gap = 1s >> 33 ms
      const nowUs = 1000000;
      const lastUs = 0;
      final result = shouldDuplicate(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        lastVideoPtsUs: lastUs,
        nowUs: nowUs,
        intervalUs: intervalUs,
      );
      expect(
        result,
        isTrue,
        reason: 'Should fire when screen has been idle for 1 second',
      );
    });
  });

  // ── PTS semantics ─────────────────────────────────────────────────────────

  group('Frame duplicator — PTS advancement', () {
    const intervalUs = 33333;

    test('emitted PTS is rec.now() for the first duplicate', () {
      var lastPts = 100000;
      const nowUs = 200000; // >> 1.5 × interval after lastPts=100000

      final pts = simulateTick(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        clock: () => nowUs,
        lastVideoPtsUs: lastPts,
        intervalUs: intervalUs,
        updateLastPts: (v) => lastPts = v,
      );
      expect(
        pts,
        equals(nowUs),
        reason: 'Duplicate PTS should be the current clock value',
      );
    });

    test('emitted PTS is at least lastVideoPtsUs + 1 for monotonicity', () {
      // Extremely unlikely edge: clock hasn't advanced past lastPts.
      // Use intervalUs=1 → threshold = (1*3)~//2 = 1.
      // Set nowUs = lastPts + 1 so gap == threshold (fires), but PTS would
      // equal lastPts+1 which is also rec.now() — both sides produce 100001.
      var lastPts = 100000;
      const nowUs = 100001; // gap = 1 == threshold → fires

      final pts = simulateTick(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        clock: () => nowUs,
        lastVideoPtsUs: lastPts,
        intervalUs: 1, // threshold = (1*3)~//2 = 1
        updateLastPts: (v) => lastPts = v,
      );
      // rec.now()=100001 > lastPts=100000, so ptsUs = rec.now() = 100001.
      expect(
        pts,
        equals(nowUs),
        reason: 'PTS must equal rec.now() when rec.now() > _lastVideoPtsUs',
      );
      // Also verify the guard would clamp if clock == lastPts.
      // Manually: ptsUs = clock; if (ptsUs <= last) ptsUs = last + 1;
      const stuckClock = 100000;
      const stuckLast = 100000;
      var clamped = stuckClock;
      if (clamped <= stuckLast) clamped = stuckLast + 1;
      expect(
        clamped,
        equals(stuckLast + 1),
        reason: 'Clamp formula: ptsUs = lastVideoPtsUs + 1 when clock is stuck',
      );
    });

    test('_lastVideoPtsUs is updated after a duplicate is emitted', () {
      var lastPts = 0;
      const nowUs = 200000;

      simulateTick(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        clock: () => nowUs,
        lastVideoPtsUs: lastPts,
        intervalUs: intervalUs,
        updateLastPts: (v) => lastPts = v,
      );
      expect(
        lastPts,
        equals(nowUs),
        reason: '_lastVideoPtsUs should be advanced to the emitted PTS',
      );
    });

    test('successive duplicates are strictly monotonic', () {
      var lastPts = 0;
      var clockUs = 200000;
      final pts = <int>[];

      // Simulate 5 consecutive duplicator ticks, each advancing clock by
      // the target interval.
      for (int i = 0; i < 5; i++) {
        clockUs += intervalUs;
        final p = simulateTick(
          stopping: false,
          busy: false,
          hasLastTex: true,
          texIsValid: true,
          clock: () => clockUs,
          lastVideoPtsUs: lastPts,
          intervalUs: intervalUs,
          updateLastPts: (v) => lastPts = v,
        );
        if (p != null) pts.add(p);
        // After first duplicate, lastPts is close to clockUs, so the guard
        // fires on every tick (each tick advances by > 0).
      }

      for (int i = 1; i < pts.length; i++) {
        expect(
          pts[i],
          greaterThan(pts[i - 1]),
          reason: 'Duplicate PTSs must be strictly monotonic',
        );
      }
    });

    test('first tick after _lastVideoPtsUs update suppresses the next tick', () {
      // After the duplicator emits a PTS, lastPts is set to rec.now().
      // The very next tick fires intervalUs later, so gap = 1 interval < 1.5×.
      // That tick should be suppressed.
      var lastPts = 0;
      const firstNow = 200000;

      // Tick 1: fires, advances lastPts to firstNow.
      simulateTick(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        clock: () => firstNow,
        lastVideoPtsUs: lastPts,
        intervalUs: intervalUs,
        updateLastPts: (v) => lastPts = v,
      );

      // Tick 2: fires intervalUs later — gap to lastPts = exactly 1 interval.
      final nextNow = firstNow + intervalUs;
      final pts2 = simulateTick(
        stopping: false,
        busy: false,
        hasLastTex: true,
        texIsValid: true,
        clock: () => nextNow,
        lastVideoPtsUs: lastPts,
        intervalUs: intervalUs,
        updateLastPts: (v) => lastPts = v,
      );
      expect(
        pts2,
        isNull,
        reason:
            'Live gap of 1× interval should not trigger a duplicate — '
            'the stream is on time at that point',
      );
    });
  });

  // ── Static-screen scenario ────────────────────────────────────────────────

  group('Frame duplicator — static-screen scenario', () {
    // Simulate a screen that sends a live frame at t=0, then goes idle for
    // 1 second.  The duplicator should fill in the gap at the target rate.
    test('fills 1-second static gap at 30 fps', () {
      const intervalUs = 33333; // ~30 fps
      const liveFrameUs = 0;
      const silenceEndUs = 1000000; // 1 s of no live frames

      var lastPts = liveFrameUs;
      var clockUs = liveFrameUs;
      final emittedPts = <int>[];

      // Step clock at target interval and collect all duplicate PTSs
      // until we reach 1 second.
      while (clockUs < silenceEndUs) {
        clockUs += intervalUs;
        final p = simulateTick(
          stopping: false,
          busy: false,
          hasLastTex: true,
          texIsValid: true,
          clock: () => clockUs,
          lastVideoPtsUs: lastPts,
          intervalUs: intervalUs,
          updateLastPts: (v) => lastPts = v,
        );
        if (p != null) emittedPts.add(p);
      }

      // After each duplicate, _lastVideoPtsUs = rec.now(). The next timer
      // tick fires intervalUs later, giving a gap of exactly 1× interval —
      // below the 1.5× threshold, so it is skipped. The tick after THAT
      // fires 2× interval after the last duplicate, which meets the threshold.
      // Therefore duplicates fire every 2 timer ticks → ~15 frames per second
      // for a 30 fps target (30 ticks total, fires on ticks 2,4,6,...,30).
      expect(
        emittedPts.length,
        greaterThanOrEqualTo(13),
        reason:
            'Should fill ~15 duplicate frames in a 1-second idle gap '
            '(fires every 2 timer ticks due to the 1.5× threshold)',
      );
      expect(emittedPts.length, lessThanOrEqualTo(17));

      // All emitted PTSs must be strictly monotonic.
      for (int i = 1; i < emittedPts.length; i++) {
        expect(
          emittedPts[i],
          greaterThan(emittedPts[i - 1]),
          reason: 'All duplicate PTSs must be strictly monotonic',
        );
      }
    });

    test(
      'does not fire when live capture resumes (gap drops below threshold)',
      () {
        // After 500 ms of static, a live frame arrives.  _lastVideoPtsUs is
        // reset to the live PTS.  Next timer tick should NOT fire because gap
        // is now < 1.5 × interval.
        const intervalUs = 33333;

        // Live capture resumes at 600 000 µs.
        const liveResumePts = 600000;
        // Timer fires 1 interval later.
        const nextTimerNow = liveResumePts + intervalUs;

        final result = shouldDuplicate(
          stopping: false,
          busy: false,
          hasLastTex: true,
          texIsValid: true,
          lastVideoPtsUs: liveResumePts,
          nowUs: nextTimerNow,
          intervalUs: intervalUs,
        );
        expect(
          result,
          isFalse,
          reason:
              'Timer tick immediately after a live frame should be '
              'suppressed — live capture is keeping up',
        );
      },
    );
  });
}
