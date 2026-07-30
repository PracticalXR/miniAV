/// End-to-end roundtrip: synthetic RGBA → libx264 encode → H.264 decode →
/// PSNR check vs. original (after RGBA→YUV→RGBA reference path).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  final enabled =
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();

  test(
    'libx264 roundtrip preserves a synthetic gradient (PSNR > 30 dB)',
    skip: enabled
        ? null
        : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
    () async {
      expect(await ensureFFmpegLoaded(), isTrue);

      const w = 320;
      const h = 240;
      const frames = 8;

      final backend = FfmpegBackend();
      final enc = await backend.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: w,
          height: h,
          bitrateBps: 2_000_000,
          gopLength: 4,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          rateControl: RateControl.crf,
          crfQuality: 18,
          // libx264-specific roundtrip (CRF 18 PSNR check); force software
          // so HW encoders don't intercept on systems with NVENC.
          hwAccel: HwAccelPreference.forbidden,
          backendOptions: {'preset': 'ultrafast', 'tune': 'zerolatency'},
        ),
      );
      expect(enc, isNotNull);

      final dec = await backend.createDecoder(
        const DecoderConfig(codec: VideoCodec.h264),
      );
      expect(dec, isNotNull);

      final firstFrame = _gradientRgba(w, h, 0);
      final packets = <EncodedPacket>[];
      for (var i = 0; i < frames; i++) {
        final src = FrameSource.cpu(
          bytes: _gradientRgba(w, h, i),
          pixelFormat: MiniAVPixelFormat.rgba32,
          width: w,
          height: h,
          timestampUs: i * 33333,
        );
        final pkt = await enc!.encode(src);
        if (pkt != null) packets.add(pkt);
      }
      packets.addAll(await enc!.flush());
      expect(packets, isNotEmpty, reason: 'encoder produced no packets');
      // First emitted packet must be a keyframe.
      expect(packets.first.isKeyframe, isTrue);

      final decoded = <DecodedFrame>[];
      for (final p in packets) {
        final f = await dec!.decode(p);
        if (f != null) decoded.add(f);
      }
      decoded.addAll(await dec!.flush());
      expect(
        decoded.length,
        equals(frames),
        reason:
            'frame count mismatch: encoded=$frames, '
            'decoded=${decoded.length}',
      );

      // Compare frame 0.
      final yuvBytes = await decoded.first.readBytes();
      final yLen = w * h;
      final y = Uint8List.fromList(yuvBytes.sublist(0, yLen));
      // Compare just the Y plane (luma) PSNR vs. the reference Y derived
      // from the original RGBA. Chroma loss is expected (subsampled +
      // quantised) and would dominate the metric.
      final refY = _rgbaToY(firstFrame, w, h);
      final psnr = _psnr8(refY, y);
      expect(psnr, greaterThan(30.0), reason: 'PSNR(Y) too low: $psnr dB');
      print(
        'Roundtrip PSNR(Y): ${psnr.toStringAsFixed(2)} dB '
        '(${packets.length} packets, ${decoded.length} frames)',
      );

      await enc.close();
      await dec.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Uint8List _gradientRgba(int w, int h, int frameIdx) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = (y * w + x) * 4;
      out[p] = ((x + frameIdx * 3) & 0xff);
      out[p + 1] = ((y + frameIdx * 5) & 0xff);
      out[p + 2] = (((x ^ y) + frameIdx) & 0xff);
      out[p + 3] = 255;
    }
  }
  return out;
}

Uint8List _rgbaToY(Uint8List rgba, int w, int h) {
  final out = Uint8List(w * h);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j++) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    out[j] = ((2105 * r + 4128 * g + 803 * b + (16 << 13) + 4096) >> 13).clamp(
      0,
      255,
    );
  }
  return out;
}

double _psnr8(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    throw ArgumentError('length mismatch: ${a.length} vs ${b.length}');
  }
  var sse = 0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    sse += d * d;
  }
  if (sse == 0) return 99.0;
  final mse = sse / a.length;
  return 10 * (math.log(255 * 255 / mse) / math.ln10);
}
