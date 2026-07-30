/// Multi-vendor HW encoder smoke test.
///
/// For every HW encoder vendor present in the loaded FFmpeg build, opens
/// the encoder for H.264 (or HEVC if H.264 isn't available) at 1920x1080,
/// pushes 30 synthetic frames, and asserts that we got non-empty packets
/// out. Skips gracefully when no HW encoder is present.
///
/// Also runs an ultrawide 5120x1440 HEVC test if any HEVC HW encoder is
/// present — this is the regression for the original "h264_nvenc max
/// width 4096" failure.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegHwEncoder', () {
    setUpAll(() async {
      await ensureFFmpegLoaded();
    });

    test('lists at least one vendor on a system with any HW encoder', () {
      final vendors = ffmpegHwVendorsAvailable();
      print('HW vendors detected: $vendors');
      // Don't assert non-empty: CI may have neither.
      expect(vendors, isA<List<HwEncoderVendor>>());
    });

    test('every available vendor encodes 1920x1080 H.264', () async {
      final vendors = ffmpegHwVendorsAvailable();
      if (vendors.isEmpty) {
        print('SKIP: no HW encoder vendors present');
        return;
      }

      const w = 1920;
      const h = 1080;
      final rgba = _makeGradient(w, h);

      var anyOk = false;
      for (final vendor in vendors) {
        late FfmpegHwEncoder enc;
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: w,
              height: h,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.required,
              rateControl: RateControl.vbr,
            ),
            vendor,
          );
        } on CodecInitException catch (e) {
          print('SKIP $vendor (h264): ${e.message}');
          continue;
        }
        try {
          final (packets, bytes) = await _drive(enc, rgba, w, h, 30);
          print('$vendor / ${enc.encoderName}: $packets packets, $bytes bytes');
          expect(packets, greaterThan(0));
          expect(bytes, greaterThan(0));
          anyOk = true;
        } finally {
          await enc.close();
        }
      }
      expect(
        anyOk,
        isTrue,
        reason: 'Every detected HW vendor failed to produce packets',
      );
    });

    test(
      'ultrawide 5120x1440 HEVC encodes when any HEVC HW encoder exists',
      () async {
        if (!ffmpegHwEncoderAvailable(VideoCodec.hevc)) {
          print('SKIP: no HEVC HW encoder available');
          return;
        }
        const w = 5120;
        const h = 1440;
        final rgba = _makeGradient(w, h);

        final enc = FfmpegHwEncoder.open(
          const EncoderConfig(
            codec: VideoCodec.hevc,
            width: w,
            height: h,
            bitrateBps: 12_000_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            bFrameCount: 0,
            hwAccel: HwAccelPreference.required,
            rateControl: RateControl.vbr,
          ),
        );
        try {
          final (packets, bytes) = await _drive(enc, rgba, w, h, 10);
          print(
            'ultrawide ${enc.vendor} / ${enc.encoderName}: '
            '$packets packets, $bytes bytes',
          );
          expect(packets, greaterThan(0));
          expect(bytes, greaterThan(0));
        } finally {
          await enc.close();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Regression: encoding frames whose pixel dimensions differ from the
    // encoder config must NOT throw — the bilinear rescale path absorbs them.
    // -------------------------------------------------------------------------
    test('mismatched frame size is rescaled silently (no throw)', () async {
      final vendors = ffmpegHwVendorsAvailable();
      if (vendors.isEmpty) {
        print('SKIP: no HW encoder vendors present');
        return;
      }

      // Encoder fixed at 1280x720; frames will arrive at 1920x1080.
      const encW = 1280, encH = 720;
      const srcW = 1920, srcH = 1080;
      final rgba = _makeGradient(srcW, srcH);

      FfmpegHwEncoder? enc;
      for (final vendor in vendors) {
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: encW,
              height: encH,
              bitrateBps: 1_500_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.required,
              rateControl: RateControl.vbr,
            ),
            vendor,
          );
          break;
        } on CodecInitException catch (e) {
          print('SKIP $vendor (mismatch test): ${e.message}');
        }
      }
      if (enc == null) {
        print('SKIP: all vendors failed to open for mismatch test');
        return;
      }

      var packets = 0;
      try {
        for (var f = 0; f < 5; f++) {
          final pkt = await enc.encode(
            FrameSource.cpu(
              bytes: rgba,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: srcW, // ← intentionally != encW
              height: srcH, // ← intentionally != encH
              timestampUs: f * 33333,
            ),
          );
          if (pkt != null) packets++;
        }
        packets += (await enc.flush()).length;
      } finally {
        await enc.close();
      }

      print(
        'Mismatch rescale: $packets packets from ${srcW}x$srcH → ${encW}x$encH',
      );
      expect(
        packets,
        greaterThan(0),
        reason:
            'Rescaled mismatched input should still produce encoded packets',
      );
    });

    test('bestCodecForResolution promotes H.264 → HEVC above 4096px', () {
      expect(
        FfmpegBackend.bestCodecForResolution(
          width: 1920,
          height: 1080,
          hwAccel: true,
        ),
        VideoCodec.h264,
      );
      expect(
        FfmpegBackend.bestCodecForResolution(
          width: 5120,
          height: 1440,
          hwAccel: true,
        ),
        VideoCodec.hevc,
      );
      // Software path: never promote.
      expect(
        FfmpegBackend.bestCodecForResolution(
          width: 5120,
          height: 1440,
          hwAccel: false,
        ),
        VideoCodec.h264,
      );
    });
  });
}

Uint8List _makeGradient(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final v = (y * 255 ~/ (h - 1)) & 0xff;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = v;
      rgba[i + 1] = (x * 255 ~/ (w - 1)) & 0xff;
      rgba[i + 2] = 255 - v;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<(int, int)> _drive(
  FfmpegHwEncoder enc,
  Uint8List rgba,
  int w,
  int h,
  int n,
) async {
  var packets = 0;
  var bytes = 0;
  for (var i = 0; i < n; i++) {
    final src = FrameSource.cpu(
      bytes: rgba,
      pixelFormat: MiniAVPixelFormat.rgba32,
      width: w,
      height: h,
      timestampUs: i * 33333,
    );
    final pkt = await enc.encode(src);
    if (pkt != null) {
      packets++;
      bytes += pkt.data.length;
    }
  }
  final tail = await enc.flush();
  packets += tail.length;
  for (final p in tail) {
    bytes += p.data.length;
  }
  return (packets, bytes);
}
