/// Unit tests for the bilinear rescale path built into [FfmpegHwEncoder].
///
/// Two layers of coverage:
///
/// 1. **White-box unit tests** — call [bilinearRescaleRgbaForTest] directly,
///    no FFmpeg required, run everywhere.
///
/// 2. **Integration tests** — open a real [FfmpegHwEncoder] at a fixed size,
///    push frames whose dimensions *differ* from the encoder config, and assert
///    that packets are produced (no crash / throw).  Skips when no HW encoder
///    is present in the test environment.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:miniav_tools_ffmpeg/src/ffmpeg_hw_encoder.dart'
    show bilinearRescaleRgbaForTest;
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 1. White-box — pure algorithm, no FFmpeg needed.
  // ---------------------------------------------------------------------------
  group('bilinearRescaleRgbaForTest', () {
    test('downscale 4x4 → 2x2 solid-red preserves colour', () {
      const w = 4, h = 4;
      final src = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        src[i * 4] = 255; // R
        src[i * 4 + 1] = 0; // G
        src[i * 4 + 2] = 0; // B
        src[i * 4 + 3] = 255; // A
      }

      final dst = bilinearRescaleRgbaForTest(src, w, h, 2, 2);

      expect(dst.length, equals(2 * 2 * 4));
      for (var i = 0; i < 4; i++) {
        expect(dst[i * 4], equals(255), reason: 'R at pixel $i');
        expect(dst[i * 4 + 1], equals(0), reason: 'G at pixel $i');
        expect(dst[i * 4 + 2], equals(0), reason: 'B at pixel $i');
        expect(dst[i * 4 + 3], equals(255), reason: 'A at pixel $i');
      }
    });

    test('upscale 1x1 → 4x4 replicates the single pixel', () {
      final src = Uint8List(4)
        ..[0] = 10
        ..[1] = 20
        ..[2] = 30
        ..[3] = 255;

      final dst = bilinearRescaleRgbaForTest(src, 1, 1, 4, 4);

      expect(dst.length, equals(4 * 4 * 4));
      for (var i = 0; i < 16; i++) {
        expect(dst[i * 4], equals(10), reason: 'R at $i');
        expect(dst[i * 4 + 1], equals(20), reason: 'G at $i');
        expect(dst[i * 4 + 2], equals(30), reason: 'B at $i');
        expect(dst[i * 4 + 3], equals(255), reason: 'A at $i');
      }
    });

    test('output byte count is correct for 5120x1440 → 1920x1080', () {
      const srcW = 5120, srcH = 1440, dstW = 1920, dstH = 1080;
      final src = Uint8List(srcW * srcH * 4);
      for (var i = 0; i < srcW * srcH; i++) {
        src[i * 4] = (i & 0xff);
        src[i * 4 + 3] = 255;
      }

      final dst = bilinearRescaleRgbaForTest(src, srcW, srcH, dstW, dstH);

      expect(dst.length, equals(dstW * dstH * 4));
    });

    test('all output bytes are in range 0–255', () {
      const srcW = 64, srcH = 48, dstW = 32, dstH = 24;
      final src = Uint8List.fromList(
        List.generate(srcW * srcH * 4, (i) => (i * 37 + 11) & 0xff),
      );

      final dst = bilinearRescaleRgbaForTest(src, srcW, srcH, dstW, dstH);

      for (var i = 0; i < dst.length; i++) {
        expect(
          dst[i],
          inInclusiveRange(0, 255),
          reason: 'byte $i out of range',
        );
      }
    });

    test('alpha channel is preserved through downscale', () {
      const w = 4, h = 4;
      final src = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        src[i * 4 + 3] = 128; // semi-transparent, RGB = 0
      }

      final dst = bilinearRescaleRgbaForTest(src, w, h, 2, 2);

      for (var i = 0; i < 4; i++) {
        expect(dst[i * 4 + 3], equals(128), reason: 'alpha at pixel $i');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Integration — real HW encoder, mismatched frame size, expect packets.
  //    Skips cleanly when no HW vendor is available.
  // ---------------------------------------------------------------------------
  group('FfmpegHwEncoder size-mismatch rescale (integration)', () {
    setUpAll(() async {
      await ensureFFmpegLoaded();
    });

    test('oversized input (5120x1440 → 1920x1080) produces packets', () async {
      final vendors = ffmpegHwVendorsAvailable();
      if (vendors.isEmpty) {
        markTestSkipped('No HW encoder vendors available');
        return;
      }

      const encW = 1920, encH = 1080;
      const srcW = 5120, srcH = 1440;
      final rgba = _makeGradient(srcW, srcH);

      FfmpegHwEncoder? enc;
      for (final v in vendors) {
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: encW,
              height: encH,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.required,
              rateControl: RateControl.vbr,
            ),
            v,
          );
          break;
        } on CodecInitException {
          continue;
        }
      }
      if (enc == null) {
        markTestSkipped('All HW vendors failed to open for this test');
        return;
      }

      var packets = 0;
      try {
        for (var f = 0; f < 5; f++) {
          final pkt = await enc.encode(
            FrameSource.cpu(
              bytes: rgba,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: srcW,
              height: srcH,
              timestampUs: f * 33333,
            ),
          );
          if (pkt != null) packets++;
        }
        packets += (await enc.flush()).length;
      } finally {
        await enc.close();
      }

      print('Mismatch oversized: $packets packets');
      expect(
        packets,
        greaterThan(0),
        reason: 'Encoder should produce packets for oversized (rescaled) input',
      );
    });

    test('undersized input (640x360 → 1920x1080) produces packets', () async {
      final vendors = ffmpegHwVendorsAvailable();
      if (vendors.isEmpty) {
        markTestSkipped('No HW encoder vendors available');
        return;
      }

      const encW = 1920, encH = 1080;
      const srcW = 640, srcH = 360;
      final rgba = _makeGradient(srcW, srcH);

      FfmpegHwEncoder? enc;
      for (final v in vendors) {
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: encW,
              height: encH,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.required,
              rateControl: RateControl.vbr,
            ),
            v,
          );
          break;
        } on CodecInitException {
          continue;
        }
      }
      if (enc == null) {
        markTestSkipped('All HW vendors failed to open for this test');
        return;
      }

      var packets = 0;
      try {
        for (var f = 0; f < 5; f++) {
          final pkt = await enc.encode(
            FrameSource.cpu(
              bytes: rgba,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: srcW,
              height: srcH,
              timestampUs: f * 33333,
            ),
          );
          if (pkt != null) packets++;
        }
        packets += (await enc.flush()).length;
      } finally {
        await enc.close();
      }

      print('Mismatch undersized: $packets packets');
      expect(packets, greaterThan(0));
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
