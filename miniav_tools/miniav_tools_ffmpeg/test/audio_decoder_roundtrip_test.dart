/// End-to-end audio roundtrip: synthetic sine PCM → AAC encode →
/// FfmpegAudioDecoder / IsolateAudioDecoder → correlation check vs original.
///
/// Also pins the decode-side pts contract (µs passthrough) and the isolate
/// host's TransferableTypedData relay.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

/// One chunk of a PHASE-CONTINUOUS sine: [startFrame] carries the phase
/// across chunk boundaries (independent chunks restarting at phase 0 would
/// make the stream a discontinuous sawtooth-of-sines that cannot correlate
/// with a continuous reference).
Uint8List _sinePcmS16(
  int sampleRate,
  int channels,
  int frameCount,
  double hz,
  int startFrame,
) {
  final out = Int16List(frameCount * channels);
  for (var i = 0; i < frameCount; i++) {
    final t = startFrame + i;
    final v = (math.sin(2 * math.pi * hz * t / sampleRate) * 12000).round();
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out.buffer.asUint8List();
}

/// Normalized cross-correlation peak between the original sine and the
/// decoded stream, searched over ±[maxLagFrames]. AAC is lossy and adds
/// encoder+decoder delay, so exact sample equality is meaningless — a high
/// correlation at some lag proves the audio path carries the signal.
double _peakCorrelation(
  Float32List decoded,
  int channels,
  int sampleRate,
  double hz,
  int maxLagFrames,
) {
  final frames = decoded.length ~/ channels;
  var best = 0.0;
  for (var lag = 0; lag <= maxLagFrames; lag++) {
    var dot = 0.0, e1 = 0.0, e2 = 0.0;
    final n = math.min(frames - lag, sampleRate); // 1 s window
    if (n < sampleRate ~/ 2) break;
    for (var i = 0; i < n; i++) {
      final ref = math.sin(2 * math.pi * hz * i / sampleRate) * (12000 / 32768);
      final got = decoded[(i + lag) * channels];
      dot += ref * got;
      e1 += ref * ref;
      e2 += got * got;
    }
    if (e1 > 0 && e2 > 0) {
      final corr = dot / math.sqrt(e1 * e2);
      if (corr > best) best = corr;
    }
  }
  return best;
}

void main() {
  final enabled =
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();
  final skip = enabled
      ? null
      : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)';

  const sampleRate = 48000;
  const channels = 2;
  const chunkFrames = 1024;
  const chunks = 40; // ~0.85 s
  const toneHz = 440.0;

  /// Encode the tone; returns the packets + the ASC extradata the decoder
  /// needs (raw AAC access units carry no in-band config — threading the
  /// ASC through DecoderConfig.extraData is exactly the shim v14
  /// `codec_set_extradata` path under test).
  Future<(List<EncodedPacket>, Uint8List?)> encodeAac() async {
    final enc = FfmpegAudioEncoder.open(
      const AudioEncoderConfig(
        codec: AudioCodec.aac,
        sampleRate: sampleRate,
        channels: channels,
        bitrateBps: 128000,
        backendOptions: {'global_header': '1'},
      ),
    );
    final packets = <EncodedPacket>[];
    for (var i = 0; i < chunks; i++) {
      packets.addAll(
        await enc.encode(
          pcm: _sinePcmS16(
            sampleRate,
            channels,
            chunkFrames,
            toneHz,
            i * chunkFrames,
          ),
          format: MiniAVAudioFormat.s16,
          frameCount: chunkFrames,
          ptsUs: (i * chunkFrames * 1000000) ~/ sampleRate,
        ),
      );
    }
    packets.addAll(await enc.flush());
    final extra = enc.extraData?.bytes;
    await enc.close();
    expect(packets, isNotEmpty, reason: 'AAC encoder produced no packets');
    expect(extra, isNotNull, reason: 'AAC encoder should expose ASC');
    return (packets, extra);
  }

  Future<void> verifyDecoded(List<DecodedAudio> decoded) async {
    expect(decoded, isNotEmpty, reason: 'decoder produced no chunks');
    final first = decoded.first;
    expect(first.sampleRate, sampleRate, reason: 'frame-reported rate');
    expect(first.channels, channels, reason: 'frame-reported channels');

    // pts must be µs and strictly monotonic (passthrough contract). The
    // FIRST chunk is legitimately negative by the AAC priming delay
    // (1024 samples ≈ 21333 µs at 48 kHz) — the encoder pre-dates it so
    // audible samples align at 0.
    expect(
      decoded.first.ptsUs,
      inInclusiveRange(-2 * 21334, 0),
      reason: 'first pts should be ≤0 by at most ~2 priming frames',
    );
    var lastPts = decoded.first.ptsUs - 1;
    var totalFrames = 0;
    for (final c in decoded) {
      expect(c.ptsUs, greaterThan(lastPts));
      lastPts = c.ptsUs;
      totalFrames += c.frameCount;
      expect(c.samples.length, c.frameCount * c.channels);
    }
    // AAC pads with priming samples; expect at least the source length.
    expect(totalFrames, greaterThanOrEqualTo(chunks * chunkFrames));

    final all = Float32List(totalFrames * channels);
    var off = 0;
    for (final c in decoded) {
      all.setAll(off, c.samples);
      off += c.samples.length;
    }
    final corr = _peakCorrelation(
      all,
      channels,
      sampleRate,
      toneHz,
      4096, // encoder+decoder delay upper bound
    );
    expect(
      corr,
      greaterThan(0.95),
      reason: 'decoded stream should correlate with the source sine',
    );
  }

  test('AAC roundtrip via FfmpegAudioDecoder (in-isolate)', skip: skip,
      () async {
    expect(await ensureFFmpegLoaded(), isTrue);
    final (packets, extra) = await encodeAac();

    final dec = FfmpegAudioDecoder.open(
      AudioDecoderConfig(codec: AudioCodec.aac, extraData: extra),
    );
    final decoded = <DecodedAudio>[];
    for (final p in packets) {
      decoded.addAll(await dec.decode(p));
    }
    decoded.addAll(await dec.flush());
    await dec.close();
    await verifyDecoded(decoded);
  });

  test('AAC roundtrip via IsolateAudioDecoder (worker host)', skip: skip,
      () async {
    expect(await ensureFFmpegLoaded(), isTrue);
    final (packets, extra) = await encodeAac();

    final dec = await IsolateAudioDecoder.open(
      AudioDecoderConfig(codec: AudioCodec.aac, extraData: extra),
    );
    final decoded = <DecodedAudio>[];
    for (final p in packets) {
      decoded.addAll(await dec.decode(p));
    }
    decoded.addAll(await dec.flush());
    await dec.close();
    await verifyDecoded(decoded);
  });
}
