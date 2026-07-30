/// Tests for the >4096px / HEVC-unavailable "downscale + H.264" fallback.
///
/// Covers three layers:
///   1. FfmpegBackend._resolveEncodableConfig (codec/resolution resolution).
///   2. End-to-end: createEncoder for a >4096px H.264 request downscales and
///      still emits packets when fed full-resolution frames (HW rescale).
///   3. The software encoder rescales mismatched input instead of throwing
///      (so the libopenh264 fallback also works after a downscale).
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('_resolveEncodableConfig', () {
    setUpAll(() async => ensureFFmpegLoaded());

    EncoderConfig cfg(VideoCodec codec, int w, int h) => EncoderConfig(
      codec: codec,
      width: w,
      height: h,
      bitrateBps: 8_000_000,
      frameRateNumerator: 30,
      frameRateDenominator: 1,
      bFrameCount: 0,
    );

    test('H.264 at 1920x1080 is unchanged', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.h264, 1920, 1080),
      );
      expect(r.codec, VideoCodec.h264);
      expect(r.width, 1920);
      expect(r.height, 1080);
    });

    test('H.264 at 5120x1440 downscales to 4096x1152 (aspect preserved)', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.h264, 5120, 1440),
      );
      expect(r.codec, VideoCodec.h264);
      expect(r.width, 4096);
      expect(r.height, 1152); // 1440 * (4096/5120) = 1152, exact
      expect(r.width, lessThanOrEqualTo(FfmpegBackend.kH264MaxDimension));
      expect(r.height, lessThanOrEqualTo(FfmpegBackend.kH264MaxDimension));
    });

    test('H.264 downscale yields even dimensions', () {
      // 5121x1443 -> longer=5121, scale≈0.7998 -> ~4096x1154 (force even).
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.h264, 5121, 1443),
      );
      expect(r.codec, VideoCodec.h264);
      expect(r.width.isEven, isTrue);
      expect(r.height.isEven, isTrue);
      expect(r.width, lessThanOrEqualTo(4096));
      expect(r.height, lessThanOrEqualTo(4096));
    });

    test('tall H.264 7680x8640 caps the longer (height) side at 4096', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.h264, 7680, 8640),
      );
      expect(r.codec, VideoCodec.h264);
      expect(r.height, 4096);
      expect(r.width, lessThanOrEqualTo(4096));
    });

    test('AV1 above 4096px is left at full resolution (SVT-AV1 handles it)', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.av1, 5120, 1440),
      );
      expect(r.codec, VideoCodec.av1);
      expect(r.width, 5120);
      expect(r.height, 1440);
    });

    test('HEVC ≤4096: keeps HEVC if HW present, else H.264 at same size', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.hevc, 1920, 1080),
      );
      // No downscale at this size regardless of the codec choice.
      expect(r.width, 1920);
      expect(r.height, 1080);
      expect(r.codec, anyOf(VideoCodec.hevc, VideoCodec.h264));
    });

    test('HEVC at 5120x1440: HEVC full-res if HW, else downscaled H.264', () {
      final r = FfmpegBackend.resolveEncodableConfigForTest(
        cfg(VideoCodec.hevc, 5120, 1440),
      );
      if (r.codec == VideoCodec.hevc) {
        // HW HEVC available — HEVC handles >4096, no downscale.
        expect(r.width, 5120);
        expect(r.height, 1440);
      } else {
        expect(r.codec, VideoCodec.h264);
        expect(r.width, lessThanOrEqualTo(4096));
        expect(r.height, lessThanOrEqualTo(4096));
      }
    });
  });

  group('end-to-end downscale fallback', () {
    setUpAll(() async => ensureFFmpegLoaded());

    test(
      'createEncoder for H.264 5120x1440 downscales and emits packets',
      () async {
        if (!await ensureFFmpegLoaded()) {
          print('SKIP: FFmpeg not available');
          return;
        }
        const srcW = 5120, srcH = 1440;
        final backend = FfmpegBackend();
        final enc = await backend.createEncoder(
          const EncoderConfig(
            codec: VideoCodec.h264,
            width: srcW,
            height: srcH,
            bitrateBps: 8_000_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            bFrameCount: 0,
            hwAccel: HwAccelPreference.preferred,
            rateControl: RateControl.vbr,
          ),
        );
        expect(enc, isNotNull, reason: 'createEncoder returned null');

        final rgba = _gradient(srcW, srcH);
        var packets = 0;
        try {
          // Feed FULL-resolution frames; the encoder (configured at the
          // downscaled size) rescales them internally.
          for (var i = 0; i < 10; i++) {
            final pkt = await enc!.encode(
              FrameSource.cpu(
                bytes: rgba,
                pixelFormat: MiniAVPixelFormat.rgba32,
                width: srcW,
                height: srcH,
                timestampUs: i * 33333,
              ),
            );
            if (pkt != null) packets++;
          }
          packets += (await enc!.flush()).length;
        } finally {
          await enc?.close();
        }
        print('createEncoder H.264 5120x1440 fallback: $packets packets');
        expect(packets, greaterThan(0));
      },
    );

    test(
      'software H.264 encoder rescales oversized frames (no throw)',
      () async {
        if (!await ensureFFmpegLoaded()) {
          print('SKIP: FFmpeg not available');
          return;
        }
        // Encoder fixed at the downscaled size; feed larger frames.
        const encW = 4096, encH = 1152;
        const srcW = 5120, srcH = 1440;
        FfmpegSoftwareEncoder enc;
        try {
          enc = FfmpegSoftwareEncoder.open(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: encW,
              height: encH,
              bitrateBps: 6_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
            ),
          );
        } on CodecInitException catch (e) {
          print('SKIP: no software H.264 encoder: ${e.message}');
          return;
        }
        final rgba = _gradient(srcW, srcH);
        var packets = 0;
        try {
          for (var i = 0; i < 5; i++) {
            final pkt = await enc.encode(
              FrameSource.cpu(
                bytes: rgba,
                pixelFormat: MiniAVPixelFormat.rgba32,
                width: srcW,
                height: srcH,
                timestampUs: i * 33333,
              ),
            );
            if (pkt != null) packets++;
          }
          packets += (await enc.flush()).length;
        } finally {
          await enc.close();
        }
        print('software H.264 rescale ${srcW}x$srcH→${encW}x$encH: $packets packets');
        expect(packets, greaterThan(0));
      },
    );
  });
}

Uint8List _gradient(int w, int h) {
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
