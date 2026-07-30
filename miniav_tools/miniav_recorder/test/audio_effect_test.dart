/// Unit tests for the [AudioEffectChain] DSP stages.
///
/// All tests run on synthetic interleaved stereo f32 PCM at 48 kHz — the
/// fixed format of the mixed mic+loopback track — and feed the chain in
/// ~10 ms chunks to mirror the real capture cadence.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_recorder/src/audio_effect.dart';
import 'package:test/test.dart';

const sampleRate = 48000;
const channels = 2;
const chunkFrames = 480; // 10 ms, like the WASAPI callback

/// Interleaved stereo sine of [amplitude] at [freqHz] lasting [seconds].
Float32List sine(double amplitude, double freqHz, double seconds) {
  final frames = (seconds * sampleRate).round();
  final out = Float32List(frames * channels);
  for (var f = 0; f < frames; f++) {
    final s = amplitude * math.sin(2 * math.pi * freqHz * f / sampleRate);
    out[f * channels] = s;
    out[f * channels + 1] = s;
  }
  return out;
}

/// Run [chain] over [pcm] in 10 ms chunks, in place.
void run(AudioEffectChain chain, Float32List pcm) {
  const chunkSamples = chunkFrames * channels;
  for (var off = 0; off + chunkSamples <= pcm.length; off += chunkSamples) {
    final view = Float32List.sublistView(pcm, off, off + chunkSamples);
    chain.process(view, chunkSamples);
  }
}

double rmsOf(Float32List pcm, int start, int end) {
  var sum = 0.0;
  for (var i = start; i < end; i++) {
    sum += pcm[i] * pcm[i];
  }
  return math.sqrt(sum / (end - start));
}

double peakOf(Float32List pcm, int start, int end) {
  var peak = 0.0;
  for (var i = start; i < end; i++) {
    final a = pcm[i].abs();
    if (a > peak) peak = a;
  }
  return peak;
}

void main() {
  AudioEffectChain chain(List<AudioEffect> fx) =>
      AudioEffectChain(fx, sampleRate: sampleRate, channels: channels);

  group('gain', () {
    test('-6.02 dB halves amplitude', () {
      final pcm = sine(0.8, 1000, 0.1);
      run(chain([AudioEffect.gain(-6.0206)]), pcm);
      expect(peakOf(pcm, 0, pcm.length), closeTo(0.4, 0.005));
    });
  });

  group('highPass', () {
    test('removes DC offset', () {
      final pcm = Float32List(sampleRate * channels); // 1 s
      pcm.fillRange(0, pcm.length, 0.5);
      run(chain([AudioEffect.highPass(cutoffHz: 90)]), pcm);
      // After the initial transient the DC must be gone.
      final tail = peakOf(pcm, pcm.length ~/ 2, pcm.length);
      expect(tail, lessThan(0.01));
    });

    test('passes 1 kHz voice band nearly untouched', () {
      final pcm = sine(0.5, 1000, 0.5);
      run(chain([AudioEffect.highPass(cutoffHz: 90)]), pcm);
      final rms = rmsOf(pcm, pcm.length ~/ 2, pcm.length);
      expect(rms, closeTo(0.5 / math.sqrt2, 0.01));
    });
  });

  group('noiseGate', () {
    test('passes loud speech-level signal', () {
      final pcm = sine(0.5, 440, 0.5); // -6 dBFS, far above -42 threshold
      run(chain([AudioEffect.noiseGate()]), pcm);
      final rms = rmsOf(pcm, pcm.length ~/ 2, pcm.length);
      expect(rms, closeTo(0.5 / math.sqrt2, 0.02));
    });

    test('mutes low-level noise after hold + release', () {
      // 0.5 s loud (opens the gate) then 1.5 s of quiet hiss at -60 dBFS.
      final loud = sine(0.5, 440, 0.5);
      final quiet = sine(0.001, 440, 1.5);
      final pcm = Float32List(loud.length + quiet.length)
        ..setAll(0, loud)
        ..setAll(loud.length, quiet);
      run(chain([AudioEffect.noiseGate()]), pcm);
      // Hold (200 ms) + release (150 ms) are long over by the last 0.5 s.
      final tailStart = pcm.length - sampleRate * channels ~/ 2;
      expect(peakOf(pcm, tailStart, pcm.length), lessThan(1e-4));
    });
  });

  group('autoLevel', () {
    test('boosts a quiet source toward the RMS target', () {
      // -37 dBFS RMS sine: needs ~+17 dB to reach the -20 dBFS target.
      // High rise rate so the test converges in a fraction of a second.
      final pcm = sine(0.02, 440, 2.0);
      run(
        chain([
          AudioEffect.autoLevel(targetRmsDb: -20, riseDbPerSec: 60),
        ]),
        pcm,
      );
      final lastHalfSec = sampleRate * channels ~/ 2;
      final rms = rmsOf(pcm, pcm.length - lastHalfSec, pcm.length);
      final rmsDb = 20 * math.log(rms) / math.ln10;
      expect(rmsDb, closeTo(-20, 2.0));
    });

    test('cuts a loud source toward the RMS target', () {
      // -3 dBFS RMS sine: needs ~-17 dB. Fall is fast by default (48 dB/s).
      final pcm = sine(1.0, 440, 2.0);
      run(chain([AudioEffect.autoLevel(targetRmsDb: -20)]), pcm);
      final lastHalfSec = sampleRate * channels ~/ 2;
      final rms = rmsOf(pcm, pcm.length - lastHalfSec, pcm.length);
      final rmsDb = 20 * math.log(rms) / math.ln10;
      expect(rmsDb, closeTo(-20, 2.0));
    });

    test('does not boost silence', () {
      final pcm = Float32List(sampleRate * channels); // 1 s of digital silence
      run(
        chain([
          AudioEffect.autoLevel(targetRmsDb: -20, riseDbPerSec: 600),
        ]),
        pcm,
      );
      expect(peakOf(pcm, 0, pcm.length), 0);
    });
  });

  group('limiter', () {
    test('caps peaks at the ceiling', () {
      final pcm = sine(1.5, 440, 0.5); // would hard-clip badly
      run(chain([AudioEffect.limiter(ceilingDb: -1)]), pcm);
      expect(peakOf(pcm, 0, pcm.length), lessThanOrEqualTo(0.8913));
    });

    test('leaves signal under the ceiling untouched', () {
      final pcm = sine(0.5, 440, 0.5);
      run(chain([AudioEffect.limiter(ceilingDb: -1)]), pcm);
      expect(peakOf(pcm, 0, pcm.length), closeTo(0.5, 0.005));
    });
  });

  group('voiceChain preset', () {
    test('levels quiet speech and mutes the noise floor', () {
      // Quiet "speech" burst followed by hiss far below the gate threshold.
      final speech = sine(0.05, 300, 1.5); // ~-29 dBFS RMS
      final hiss = sine(0.0005, 6000, 1.5); // -66 dBFS
      final pcm = Float32List(speech.length + hiss.length)
        ..setAll(0, speech)
        ..setAll(speech.length, hiss);
      run(chain(AudioEffect.voiceChain()), pcm);

      // Speech got louder (auto-level boost, even if not fully converged).
      final speechRms = rmsOf(
        pcm,
        speech.length - sampleRate * channels ~/ 2,
        speech.length,
      );
      expect(speechRms, greaterThan(0.05 / math.sqrt2));

      // Hiss tail is gated to silence.
      final tailStart = pcm.length - sampleRate * channels ~/ 2;
      expect(peakOf(pcm, tailStart, pcm.length), lessThan(1e-4));
    });
  });
}
