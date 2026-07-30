/// Regression tests for the fps-throttle behaviour of the video track,
/// exercised against the REAL pacing policy ([FramePacer]) rather than a
/// mirrored copy of the algorithm (this file previously simulated the old
/// credit scheduler standalone, which let the test and production drift).
///
/// Semantics under test (see [FramePacer] for the full story):
///  - A source that meaningfully outruns the target (60→30) is thinned
///    EVENLY to the target rate by the credit scheduler.
///  - A source within ~15% of the target (the DXGI/WGC ~31.4 fps vs 30
///    overdelivery case) passes through UNTOUCHED: deleting one frame per
///    ~20 from a near-target cadence produces a double-length presentation
///    hole every ~0.7 s — the metronomic stutter this campaign removed.
///  - A source slower than the target is never dropped.
library;

import 'package:miniav_recorder/src/frame_pacer.dart';
import 'package:test/test.dart';

void main() {
  group('FPS throttle (FramePacer VFR) — 30 fps target', () {
    test('near-target overdelivery (31.5 fps) is NOT thinned', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      var drops = 0;
      for (var n = 0; n < 400; n++) {
        if (pacer.shouldDropOnArrival(1000 + n * 31746)) drops++;
      }
      expect(drops, 0,
          reason: 'each drop from a near-target cadence is a 63 ms '
              'presentation hole — the stutter this fix removes');
      expect(pacer.throttleActive, isFalse);
    });

    test('slow source (24 fps) is never dropped', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      var drops = 0;
      for (var n = 0; n < 200; n++) {
        if (pacer.shouldDropOnArrival(1000 + n * 41667)) drops++;
      }
      expect(drops, 0);
      expect(pacer.throttleActive, isFalse);
    });

    test('genuinely fast source (60 fps) is thinned evenly to target', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final accepted = <int>[];
      for (var n = 0; n < 400; n++) {
        final t = 1000 + n * 16667;
        if (!pacer.shouldDropOnArrival(t)) accepted.add(t);
      }
      expect(pacer.throttleActive, isTrue);
      expect(accepted.length / 400, closeTo(0.5, 0.05));
      for (var i = 1; i < accepted.length; i++) {
        expect(accepted[i] - accepted[i - 1], lessThanOrEqualTo(2 * 16667),
            reason: 'thinning must be even, never drop-several-in-a-row');
      }
    });

    test('burst (window-focus event) is smoothed, steady flow recovers', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      var t = 1000;
      // 100 steady frames at 30 fps.
      for (var n = 0; n < 100; n++) {
        pacer.shouldDropOnArrival(t);
        t += 33333;
      }
      // Burst: 20 frames at 5 ms spacing.
      var burstDrops = 0;
      for (var n = 0; n < 20; n++) {
        if (pacer.shouldDropOnArrival(t)) burstDrops++;
        t += 5000;
      }
      expect(burstDrops, greaterThan(5),
          reason: 'a 200 fps burst must be thinned, not passed through');
      // Steady flow resumes: after the EMA recovers, no more drops.
      var lateDrops = 0;
      for (var n = 0; n < 100; n++) {
        final drop = pacer.shouldDropOnArrival(t);
        if (n >= 40 && drop) lateDrops++;
        t += 33333;
      }
      expect(lateDrops, 0,
          reason: 'the throttle must release once cadence ≈ target again');
      expect(pacer.throttleActive, isFalse);
    });

    test('fractional target (23.976 fps) tolerates its exact cadence', () {
      final pacer = FramePacer(frameRateNum: 24000, frameRateDen: 1001);
      var drops = 0;
      for (var n = 0; n < 200; n++) {
        // Arrivals exactly on the rational grid.
        final t = 1000 + (n * 1000000 * 1001) ~/ 24000;
        if (pacer.shouldDropOnArrival(t)) drops++;
      }
      expect(drops, 0);
    });
  });
}
