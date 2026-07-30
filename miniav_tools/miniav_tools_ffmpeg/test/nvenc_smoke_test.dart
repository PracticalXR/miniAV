/// Smoke test: validate that h264_nvenc is reachable through the FFmpeg
/// backend and emits a non-empty packet for a synthetic 1920x1080 frame.
///
/// Skipped automatically if NVENC is not present (no NVIDIA GPU, missing
/// nvEncodeAPI64.dll, missing h264_nvenc in the loaded FFmpeg build, etc.).
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  test('h264_nvenc opens, accepts RGBA frames, emits packets', () async {
    final loaded = await ensureFFmpegLoaded();
    if (!loaded) {
      print('SKIP: FFmpeg not available');
      return;
    }
    if (!ffmpegNvencAvailable()) {
      print(
        'SKIP: h264_nvenc not present in this FFmpeg build '
        '(no NVIDIA GPU / driver / nvEncodeAPI64.dll)',
      );
      return;
    }

    const w = 1920;
    const h = 1080;

    final backend = FfmpegBackend();
    final encoder = await backend.createEncoder(
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
        backendOptions: {'preset': 'p4', 'tune': 'll'},
      ),
    );

    expect(encoder, isNotNull, reason: 'createEncoder returned null');
    expect(
      encoder,
      isA<FfmpegHwEncoder>(),
      reason:
          'hwAccel=required should select an HW encoder, got ${encoder.runtimeType}',
    );
    expect(
      (encoder as FfmpegHwEncoder).vendor,
      HwEncoderVendor.nvenc,
      reason: 'expected NVENC to win the probe order',
    );

    try {
      final rgba = Uint8List(w * h * 4);
      // Fill with a vertical gradient so the encoder has something
      // non-trivial to compress.
      for (var y = 0; y < h; y++) {
        final v = (y * 255 ~/ (h - 1)) & 0xff;
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          rgba[i] = v; // R
          rgba[i + 1] = 128; // G
          rgba[i + 2] = 255 - v; // B
          rgba[i + 3] = 255; // A (ignored as RGB0)
        }
      }

      var packetsReceived = 0;
      var totalBytes = 0;
      for (var i = 0; i < 30; i++) {
        final src = FrameSource.cpu(
          bytes: rgba,
          pixelFormat: MiniAVPixelFormat.rgba32,
          width: w,
          height: h,
          timestampUs: i * 33333,
        );
        final pkt = await encoder!.encode(src);
        if (pkt != null) {
          packetsReceived++;
          totalBytes += pkt.data.length;
        }
      }

      final tail = await encoder!.flush();
      packetsReceived += tail.length;
      for (final p in tail) {
        totalBytes += p.data.length;
      }

      print('NVENC produced $packetsReceived packets, $totalBytes bytes total');
      expect(
        packetsReceived,
        greaterThan(0),
        reason: 'NVENC emitted no packets after 30 frames + flush',
      );
      expect(totalBytes, greaterThan(0));
    } finally {
      await encoder?.close();
    }
  });
}
