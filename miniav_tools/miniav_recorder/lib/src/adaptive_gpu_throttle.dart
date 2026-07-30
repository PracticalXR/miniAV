/// GPU-pressure-adaptive capture throttle policy.
///
/// When the GPU is saturated by another workload (e.g. a game), the recorder's
/// per-frame GPU stage (downscale / effects / YUV convert / shared-texture
/// copy) queues behind that workload and its wall-clock duration balloons past
/// the frame interval. Frames then pile into the bounded encode queue and are
/// dropped as `busy_drop` at an *uneven* cadence — which plays back as stutter.
///
/// This policy converts that failure mode into graceful degradation: it watches
/// an EMA of the GPU-stage duration and, under sustained overrun, steps the
/// *live* capture rate down by a power-of-two divisor (2×, 4× the frame
/// interval). Dropping frames via the fps throttle is *even* (and benign —
/// `thr_drop`), and the frame duplicator keeps the encoded output at the target
/// fps by re-encoding the last frame, so playback stays smooth at a lower live
/// refresh instead of jittering. When pressure clears, the divisor steps back
/// down with hysteresis.
///
/// Pure and synchronous so the step-up/step-down behavior is unit-testable.
library;

class AdaptiveGpuThrottle {
  AdaptiveGpuThrottle({
    this.maxDivisor = 4,
    this.hotFrames = 10,
    this.coolFrames = 60,
  }) : assert(maxDivisor >= 1),
       assert(hotFrames > 0),
       assert(coolFrames > 0);

  /// Upper bound for the divisor (4 → live rate never drops below 1/4 target).
  final int maxDivisor;

  /// Consecutive over-budget samples required before stepping the divisor UP.
  /// Small: engaging quickly limits the stutter window.
  final int hotFrames;

  /// Consecutive fits-with-headroom samples required before stepping DOWN.
  /// Larger than [hotFrames] so a briefly-quiet GPU doesn't cause flapping.
  final int coolFrames;

  int _divisor = 1;
  int _emaUs = 0;
  int _hot = 0;
  int _cool = 0;

  /// Current live-rate divisor (1 = full target rate).
  int get divisor => _divisor;

  /// Smoothed GPU-stage duration in microseconds (EMA, alpha = 1/8).
  int get emaUs => _emaUs;

  /// Feeds one GPU-stage duration sample ([gpuUs], wall-clock µs) against the
  /// configured frame interval [baseIntervalUs]. Returns the (possibly updated)
  /// divisor. A non-positive [baseIntervalUs] (device-controlled rate — no
  /// throttle target) disables adaptation.
  int addSample(int gpuUs, int baseIntervalUs) {
    if (baseIntervalUs <= 0) return _divisor;
    _emaUs = _emaUs == 0 ? gpuUs : (gpuUs + 7 * _emaUs) ~/ 8;

    // The per-frame GPU budget at the CURRENT divisor. Exceeding it means even
    // the reduced live rate can't keep up → escalate.
    final budgetUs = baseIntervalUs * _divisor;
    if (_emaUs > budgetUs) {
      _cool = 0;
      if (++_hot >= hotFrames && _divisor < maxDivisor) {
        _divisor *= 2;
        _hot = 0;
      }
    } else if (_divisor > 1 &&
        // Step down only when the stage would fit the NEXT divisor down with
        // ≥25% headroom: ema < 3/4 * (base * divisor/2).
        _emaUs * 4 < baseIntervalUs * (_divisor >> 1) * 3) {
      _hot = 0;
      if (++_cool >= coolFrames) {
        _divisor >>= 1;
        _cool = 0;
      }
    } else {
      // In the dead band (fits current budget, but not comfortably below the
      // next one) — hold steady and reset both streaks.
      _hot = 0;
      _cool = 0;
    }
    return _divisor;
  }

  void reset() {
    _divisor = 1;
    _emaUs = 0;
    _hot = 0;
    _cool = 0;
  }
}
