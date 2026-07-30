/// DSP effect descriptors for audio tracks.
///
/// Effects are pure configuration objects — no state is allocated until the
/// [Recorder] starts. They run as cheap O(n) float DSP on the audio capture
/// hot path (interleaved f32 PCM), so every stage is a handful of multiplies
/// per sample with no allocation.
///
/// Currently consumed by the **mixed mic + loopback** track
/// (`RecorderBuilder.addMixedAudio`), which exposes three chains:
///
/// ```
/// mic capture      → [micEffects]      ─┐
///                                       ├─ sum → [masterEffects] → encoder
/// loopback capture → [loopbackEffects] ─┘
/// ```
///
/// ### Built-in effects
/// | Factory | Description |
/// |---|---|
/// | [AudioEffect.gain] | Fixed gain in dB. |
/// | [AudioEffect.highPass] | Biquad high-pass (rumble / plosive removal). |
/// | [AudioEffect.noiseGate] | Mutes the signal below a threshold (keyboard / breath noise between speech). |
/// | [AudioEffect.autoLevel] | Slow AGC that rides gain toward a target loudness. |
/// | [AudioEffect.limiter] | Peak limiter — transparent alternative to hard clipping. |
///
/// ### Presets
/// [AudioEffect.voiceChain] returns a ready-made mic chain
/// (high-pass → noise gate → auto-level) tuned for spoken commentary.
library;

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Config descriptors
// ---------------------------------------------------------------------------

/// A descriptor for one DSP stage applied to an audio stream.
///
/// Construct via the factories ([AudioEffect.gain], [AudioEffect.highPass],
/// [AudioEffect.noiseGate], [AudioEffect.autoLevel], [AudioEffect.limiter])
/// and pass to `RecorderBuilder.addMixedAudio(micEffects: …)`.
sealed class AudioEffect {
  const AudioEffect();

  /// Fixed gain of [db] decibels (negative attenuates).
  factory AudioEffect.gain(double db) => GainAudioEffect(db: db);

  /// Butterworth biquad high-pass at [cutoffHz].
  ///
  /// Removes low-frequency rumble, desk thumps and plosive pops from a mic.
  /// 80–120 Hz is the usual range for voice; content below ~90 Hz carries
  /// almost no speech information.
  factory AudioEffect.highPass({double cutoffHz = 90}) =>
      HighPassAudioEffect(cutoffHz: cutoffHz);

  /// Downward noise gate.
  ///
  /// Fully attenuates the stream while its level stays below
  /// [thresholdDb] (dBFS peak), removing constant hiss, fan noise and
  /// keyboard spam *between* speech. Opens within [attackMs] when the level
  /// exceeds the threshold, stays open for [holdMs] after the level drops
  /// (so natural speech pauses don't chatter), then fades closed over
  /// [releaseMs]. [hysteresisDb] sets how far below the open threshold the
  /// close threshold sits, preventing rapid open/close flutter.
  factory AudioEffect.noiseGate({
    double thresholdDb = -42,
    double hysteresisDb = 8,
    double attackMs = 2,
    double holdMs = 200,
    double releaseMs = 150,
  }) => NoiseGateAudioEffect(
    thresholdDb: thresholdDb,
    hysteresisDb: hysteresisDb,
    attackMs: attackMs,
    holdMs: holdMs,
    releaseMs: releaseMs,
  );

  /// Automatic level control (slow AGC).
  ///
  /// Continuously measures smoothed RMS loudness and rides a makeup gain so
  /// the stream converges on [targetRmsDb] (dBFS). Use the same target on
  /// mic and loopback to fix "my mic is way louder than the game" without
  /// manual gain staging.
  ///
  /// Boost is capped at [maxBoostDb] and cut at [maxCutDb]. The gain rises
  /// slowly ([riseDbPerSec]) so noise floors aren't pumped up audibly, and
  /// falls quickly ([fallDbPerSec]) so sudden loud passages are tamed fast.
  /// Below [gateDb] the gain freezes — silence is never boosted.
  factory AudioEffect.autoLevel({
    double targetRmsDb = -20,
    double maxBoostDb = 18,
    double maxCutDb = 18,
    double gateDb = -50,
    double windowMs = 250,
    double riseDbPerSec = 6,
    double fallDbPerSec = 48,
  }) => AutoLevelAudioEffect(
    targetRmsDb: targetRmsDb,
    maxBoostDb: maxBoostDb,
    maxCutDb: maxCutDb,
    gateDb: gateDb,
    windowMs: windowMs,
    riseDbPerSec: riseDbPerSec,
    fallDbPerSec: fallDbPerSec,
  );

  /// Peak limiter with [ceilingDb] output ceiling.
  ///
  /// Tracks the peak envelope and scales gain down so peaks never exceed the
  /// ceiling, releasing over [releaseMs]. Far more transparent than the hard
  /// clip that otherwise guards the mix bus — use on `masterEffects` when
  /// both sources can be loud at once.
  factory AudioEffect.limiter({
    double ceilingDb = -1,
    double releaseMs = 150,
  }) => LimiterAudioEffect(ceilingDb: ceilingDb, releaseMs: releaseMs);

  /// Ready-made mic chain for spoken commentary:
  /// high-pass (rumble) → noise gate (background noise / key spam between
  /// speech) → auto-level (consistent loudness).
  static List<AudioEffect> voiceChain({double targetRmsDb = -20}) => [
    AudioEffect.highPass(),
    AudioEffect.noiseGate(),
    AudioEffect.autoLevel(targetRmsDb: targetRmsDb),
  ];
}

/// Fixed gain. Created via [AudioEffect.gain].
final class GainAudioEffect extends AudioEffect {
  const GainAudioEffect({required this.db});

  final double db;
}

/// Biquad high-pass filter. Created via [AudioEffect.highPass].
final class HighPassAudioEffect extends AudioEffect {
  const HighPassAudioEffect({required this.cutoffHz});

  final double cutoffHz;
}

/// Downward noise gate. Created via [AudioEffect.noiseGate].
final class NoiseGateAudioEffect extends AudioEffect {
  const NoiseGateAudioEffect({
    required this.thresholdDb,
    required this.hysteresisDb,
    required this.attackMs,
    required this.holdMs,
    required this.releaseMs,
  });

  final double thresholdDb;
  final double hysteresisDb;
  final double attackMs;
  final double holdMs;
  final double releaseMs;
}

/// Automatic level control. Created via [AudioEffect.autoLevel].
final class AutoLevelAudioEffect extends AudioEffect {
  const AutoLevelAudioEffect({
    required this.targetRmsDb,
    required this.maxBoostDb,
    required this.maxCutDb,
    required this.gateDb,
    required this.windowMs,
    required this.riseDbPerSec,
    required this.fallDbPerSec,
  });

  final double targetRmsDb;
  final double maxBoostDb;
  final double maxCutDb;
  final double gateDb;
  final double windowMs;
  final double riseDbPerSec;
  final double fallDbPerSec;
}

/// Peak limiter. Created via [AudioEffect.limiter].
final class LimiterAudioEffect extends AudioEffect {
  const LimiterAudioEffect({required this.ceilingDb, required this.releaseMs});

  final double ceilingDb;
  final double releaseMs;
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

/// A stateful, ready-to-run chain of effect processors for one stream.
///
/// Built once per track at recorder start (state such as filter history and
/// gain envelopes lives for the duration of the recording) and invoked from
/// the audio capture hot path. [process] mutates the samples in place.
class AudioEffectChain {
  AudioEffectChain(
    List<AudioEffect> configs, {
    required int sampleRate,
    required int channels,
  }) : _stages = [
         for (final cfg in configs)
           switch (cfg) {
             GainAudioEffect() => _GainStage(cfg),
             HighPassAudioEffect() => _HighPassStage(cfg, sampleRate, channels),
             NoiseGateAudioEffect() => _NoiseGateStage(
               cfg,
               sampleRate,
               channels,
             ),
             AutoLevelAudioEffect() => _AutoLevelStage(
               cfg,
               sampleRate,
               channels,
             ),
             LimiterAudioEffect() => _LimiterStage(cfg, sampleRate, channels),
           },
       ];

  final List<_Stage> _stages;

  bool get isEmpty => _stages.isEmpty;

  /// Run every stage in order over the first [sampleCount] interleaved
  /// samples of [samples], in place.
  void process(Float32List samples, int sampleCount) {
    for (final s in _stages) {
      s.process(samples, sampleCount);
    }
  }
}

/// One-pole smoothing coefficient for a time constant of [ms] at [sampleRate].
double _onePoleCoef(double ms, int sampleRate) {
  if (ms <= 0) return 1.0;
  return 1.0 - math.exp(-1000.0 / (ms * sampleRate));
}

double _dbToLin(double db) => math.pow(10.0, db / 20.0).toDouble();

abstract class _Stage {
  void process(Float32List x, int n);
}

class _GainStage implements _Stage {
  _GainStage(GainAudioEffect cfg) : _gain = _dbToLin(cfg.db);

  final double _gain;

  @override
  void process(Float32List x, int n) {
    if (_gain == 1.0) return;
    for (var i = 0; i < n; i++) {
      x[i] *= _gain;
    }
  }
}

/// RBJ-cookbook Butterworth high-pass biquad, independent state per channel.
class _HighPassStage implements _Stage {
  _HighPassStage(HighPassAudioEffect cfg, int sampleRate, this._channels)
    : _x1 = Float64List(_channels),
      _x2 = Float64List(_channels),
      _y1 = Float64List(_channels),
      _y2 = Float64List(_channels) {
    final w0 = 2 * math.pi * cfg.cutoffHz / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / math.sqrt2; // Q = 1/√2 (Butterworth)
    final a0 = 1 + alpha;
    _b0 = (1 + cosW0) / 2 / a0;
    _b1 = -(1 + cosW0) / a0;
    _b2 = (1 + cosW0) / 2 / a0;
    _a1 = -2 * cosW0 / a0;
    _a2 = (1 - alpha) / a0;
  }

  final int _channels;
  late final double _b0, _b1, _b2, _a1, _a2;
  final Float64List _x1, _x2, _y1, _y2;

  @override
  void process(Float32List x, int n) {
    final frames = n ~/ _channels;
    for (var ch = 0; ch < _channels; ch++) {
      var x1 = _x1[ch], x2 = _x2[ch], y1 = _y1[ch], y2 = _y2[ch];
      for (var f = 0; f < frames; f++) {
        final i = f * _channels + ch;
        final x0 = x[i].toDouble();
        final y0 = _b0 * x0 + _b1 * x1 + _b2 * x2 - _a1 * y1 - _a2 * y2;
        x[i] = y0;
        x2 = x1;
        x1 = x0;
        y2 = y1;
        y1 = y0;
      }
      _x1[ch] = x1;
      _x2[ch] = x2;
      _y1[ch] = y1;
      _y2[ch] = y2;
    }
  }
}

class _NoiseGateStage implements _Stage {
  _NoiseGateStage(NoiseGateAudioEffect cfg, int sampleRate, this._channels)
    : _openLin = _dbToLin(cfg.thresholdDb),
      _closeLin = _dbToLin(cfg.thresholdDb - cfg.hysteresisDb),
      _attackCoef = _onePoleCoef(cfg.attackMs, sampleRate),
      _releaseCoef = _onePoleCoef(cfg.releaseMs, sampleRate),
      _holdFramesMax = (cfg.holdMs * sampleRate / 1000).round(),
      // ~30 ms peak-envelope decay: fast enough to track speech offsets,
      // slow enough not to flutter within a single word.
      _envDecay = math.exp(-1000.0 / (30.0 * sampleRate));

  final int _channels;
  final double _openLin;
  final double _closeLin;
  final double _attackCoef;
  final double _releaseCoef;
  final int _holdFramesMax;
  final double _envDecay;

  double _env = 0;
  double _gain = 0;
  double _target = 0;
  int _holdFrames = 0;

  @override
  void process(Float32List x, int n) {
    final frames = n ~/ _channels;
    for (var f = 0; f < frames; f++) {
      final base = f * _channels;
      var peak = 0.0;
      for (var ch = 0; ch < _channels; ch++) {
        final a = x[base + ch].abs();
        if (a > peak) peak = a;
      }
      _env = peak > _env ? peak : _env * _envDecay;

      if (_env >= _openLin) {
        _target = 1;
        _holdFrames = _holdFramesMax;
      } else if (_env < _closeLin) {
        if (_holdFrames > 0) {
          _holdFrames--;
        } else {
          _target = 0;
        }
      }
      // Between thresholds: keep the previous target (hysteresis).

      _gain += (_target - _gain) * (_target > _gain ? _attackCoef : _releaseCoef);
      for (var ch = 0; ch < _channels; ch++) {
        x[base + ch] *= _gain;
      }
    }
  }
}

class _AutoLevelStage implements _Stage {
  _AutoLevelStage(AutoLevelAudioEffect cfg, int sampleRate, this._channels)
    : _targetLin = _dbToLin(cfg.targetRmsDb),
      _maxGain = _dbToLin(cfg.maxBoostDb),
      _minGain = _dbToLin(-cfg.maxCutDb),
      _gateMs = _dbToLin(cfg.gateDb) * _dbToLin(cfg.gateDb),
      _msCoef = _onePoleCoef(cfg.windowMs, sampleRate),
      // Per-frame multiplicative steps equivalent to ±dB/s slew rates —
      // keeps the per-sample loop free of pow()/log() calls.
      _riseStep = _dbToLin(cfg.riseDbPerSec / sampleRate),
      _fallStep = _dbToLin(-cfg.fallDbPerSec / sampleRate);

  final int _channels;
  final double _targetLin;
  final double _maxGain;
  final double _minGain;
  final double _gateMs; // gate threshold as mean-square
  final double _msCoef;
  final double _riseStep;
  final double _fallStep;

  double _meanSquare = 0;
  double _gain = 1;

  @override
  void process(Float32List x, int n) {
    final frames = n ~/ _channels;
    for (var f = 0; f < frames; f++) {
      final base = f * _channels;
      var sq = 0.0;
      for (var ch = 0; ch < _channels; ch++) {
        final s = x[base + ch];
        sq += s * s;
      }
      sq /= _channels;
      _meanSquare += (sq - _meanSquare) * _msCoef;

      // Only adapt while the (pre-gain) signal is above the gate floor;
      // silence keeps the last gain so the noise floor is never ridden up.
      if (_meanSquare > _gateMs) {
        final rms = math.sqrt(_meanSquare);
        var desired = _targetLin / rms;
        if (desired > _maxGain) desired = _maxGain;
        if (desired < _minGain) desired = _minGain;
        if (_gain < desired) {
          _gain *= _riseStep;
          if (_gain > desired) _gain = desired;
        } else if (_gain > desired) {
          _gain *= _fallStep;
          if (_gain < desired) _gain = desired;
        }
      }
      for (var ch = 0; ch < _channels; ch++) {
        x[base + ch] *= _gain;
      }
    }
  }
}

class _LimiterStage implements _Stage {
  _LimiterStage(LimiterAudioEffect cfg, int sampleRate, this._channels)
    : _ceiling = _dbToLin(cfg.ceilingDb),
      _envDecay = math.exp(-1000.0 / (cfg.releaseMs * sampleRate));

  final int _channels;
  final double _ceiling;
  final double _envDecay;

  double _env = 0;

  @override
  void process(Float32List x, int n) {
    final frames = n ~/ _channels;
    for (var f = 0; f < frames; f++) {
      final base = f * _channels;
      var peak = 0.0;
      for (var ch = 0; ch < _channels; ch++) {
        final a = x[base + ch].abs();
        if (a > peak) peak = a;
      }
      // Instant attack, exponential release.
      _env = peak > _env ? peak : _env * _envDecay;
      if (_env > _ceiling) {
        final g = _ceiling / _env;
        for (var ch = 0; ch < _channels; ch++) {
          x[base + ch] *= g;
        }
      }
    }
  }
}
