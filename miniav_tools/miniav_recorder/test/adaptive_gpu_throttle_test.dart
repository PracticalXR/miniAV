/// Tests for [AdaptiveGpuThrottle] — the GPU-pressure policy that steps the
/// live capture rate down (÷2, ÷4) under sustained GPU-stage overrun and
/// restores it with hysteresis when pressure clears.
@TestOn('vm')
library;

import 'package:miniav_recorder/src/adaptive_gpu_throttle.dart';
import 'package:test/test.dart';

/// 30 fps target → 33.333 ms budget per frame.
const int kInterval = 33333;

void main() {
  group('AdaptiveGpuThrottle', () {
    test('stays at ÷1 under light GPU load', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 100; i++) {
        t.addSample(5000, kInterval); // 5 ms — well inside budget
      }
      expect(t.divisor, 1);
    });

    test('engages ÷2 after hotFrames of sustained overrun', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 9; i++) {
        t.addSample(50000, kInterval); // 50 ms > 33 ms budget
      }
      expect(t.divisor, 1, reason: 'one sample short of the hot threshold');
      t.addSample(50000, kInterval); // 10th consecutive hot sample
      expect(t.divisor, 2);
    });

    test('escalates to ÷4 (and caps at maxDivisor) under extreme load', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 40; i++) {
        t.addSample(200000, kInterval); // 200 ms — worse than any budget
      }
      expect(t.divisor, 4, reason: 'capped at maxDivisor');
    });

    test('a brief spike does not engage (hysteresis)', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 5; i++) {
        t.addSample(50000, kInterval); // 5-frame spike < hotFrames
      }
      for (var i = 0; i < 50; i++) {
        t.addSample(5000, kInterval); // pressure gone; EMA decays
      }
      expect(t.divisor, 1);
    });

    test('releases back to ÷1 only after sustained cool-down', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 10; i++) {
        t.addSample(50000, kInterval);
      }
      expect(t.divisor, 2);

      // Pressure clears. The EMA takes ~7 samples to fall below the release
      // threshold, then coolFrames (60) consecutive fits are required.
      for (var i = 0; i < 50; i++) {
        t.addSample(5000, kInterval);
      }
      expect(t.divisor, 2, reason: 'cool streak not yet long enough');
      for (var i = 0; i < 50; i++) {
        t.addSample(5000, kInterval);
      }
      expect(t.divisor, 1, reason: 'sustained cool-down releases the divisor');
    });

    test('no target rate (interval 0) disables adaptation', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 100; i++) {
        t.addSample(500000, 0);
      }
      expect(t.divisor, 1);
    });

    test('reset() restores full rate immediately', () {
      final t = AdaptiveGpuThrottle();
      for (var i = 0; i < 40; i++) {
        t.addSample(200000, kInterval);
      }
      expect(t.divisor, greaterThan(1));
      t.reset();
      expect(t.divisor, 1);
      expect(t.emaUs, 0);
    });
  });
}
