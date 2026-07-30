@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

void main() {
  group('MJPEG via GpuCodecPipeline', () {
    final backend = MinigpuBackend();

    test(
      'encodes a 64x48 RGBA gradient frame to a valid JFIF stream',
      () async {
        const w = 64;
        const h = 48;
        final cfg = EncoderConfig(
          codec: VideoCodec.mjpeg,
          width: w,
          height: h,
          bitrateBps: 0,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          inputPixelFormat: MiniAVPixelFormat.rgba32,
          crfQuality: 23,
        );

        final encoder = await backend.createEncoder(cfg);
        expect(
          encoder,
          isNotNull,
          reason: 'minigpu backend should create an MJPEG encoder',
        );

        try {
          // Three synthetic gradient frames.
          for (var f = 0; f < 3; f++) {
            final bytes = Uint8List(w * h * 4);
            for (var y = 0; y < h; y++) {
              for (var x = 0; x < w; x++) {
                final i = (y * w + x) * 4;
                bytes[i + 0] = (x * 4 + f * 10) & 0xff; // R
                bytes[i + 1] = (y * 5 + f * 20) & 0xff; // G
                bytes[i + 2] = ((x + y) * 3 + f * 30) & 0xff; // B
                bytes[i + 3] = 0xff; // A
              }
            }
            final pkt = await encoder!.encode(
              CpuFrameSource(
                bytes: bytes,
                pixelFormat: MiniAVPixelFormat.rgba32,
                width: w,
                height: h,
                timestampUs: f * 33333,
              ),
            );
            expect(pkt, isNotNull, reason: 'frame $f produced no packet');
            final data = pkt!.data;
            // SOI marker.
            expect(data.length, greaterThan(8));
            expect(data[0], 0xFF);
            expect(data[1], 0xD8);
            // APP0 marker (JFIF).
            expect(data[2], 0xFF);
            expect(data[3], 0xE0);
            // EOI marker.
            expect(data[data.length - 2], 0xFF);
            expect(data[data.length - 1], 0xD9);
            // Every MJPEG frame is a keyframe.
            expect(pkt.isKeyframe, isTrue);
          }

          final tail = await encoder!.flush();
          expect(tail, isEmpty, reason: 'MJPEG should not buffer any frames');
        } finally {
          await encoder?.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'GPU-encoded JFIF round-trip decodes to a near-identical image',
      () async {
        // 256×128 covers >= 8×16 = 128 MCUs, exercising the per-MCU GPU
        // Huffman shader on a non-trivial workload, with a deterministic
        // pattern that's easy to validate against a CPU decode.
        const w = 256;
        const h = 128;
        final cfg = EncoderConfig(
          codec: VideoCodec.mjpeg,
          width: w,
          height: h,
          bitrateBps: 0,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          inputPixelFormat: MiniAVPixelFormat.rgba32,
          // High quality so the decode error stays small for the assertion.
          crfQuality: 5,
        );

        final encoder = await MinigpuBackend().createEncoder(cfg);
        expect(encoder, isNotNull);

        // Build a smooth gradient + diagonal sin pattern (forgiving for DCT).
        final src = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            src[i + 0] = (x) & 0xff;
            src[i + 1] = (y * 2) & 0xff;
            src[i + 2] = ((x + y) ~/ 2) & 0xff;
            src[i + 3] = 0xff;
          }
        }

        try {
          final pkt = await encoder!.encode(
            CpuFrameSource(
              bytes: src,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: w,
              height: h,
              timestampUs: 0,
            ),
          );
          expect(pkt, isNotNull);
          final jfif = pkt!.data;

          // Validate JFIF marker presence (DQT, DHT, DRI, SOS).
          int find(int b1, int b2) {
            for (var i = 0; i < jfif.length - 1; i++) {
              if (jfif[i] == b1 && jfif[i + 1] == b2) return i;
            }
            return -1;
          }

          expect(find(0xFF, 0xDB), greaterThan(0), reason: 'DQT marker');
          expect(find(0xFF, 0xC4), greaterThan(0), reason: 'DHT marker');
          expect(find(0xFF, 0xDD), greaterThan(0), reason: 'DRI marker');
          expect(find(0xFF, 0xDA), greaterThan(0), reason: 'SOS marker');
          // Must be substantially larger than just the header.
          expect(jfif.length, greaterThan(2000));

          // Decode with a CPU reference (image package).
          final decoded = img.decodeJpg(jfif);
          expect(
            decoded,
            isNotNull,
            reason: 'image package failed to decode our GPU JFIF',
          );
          expect(decoded!.width, w);
          expect(decoded.height, h);

          // Compute mean-absolute error against the source. For a smooth
          // gradient at high quality, error should be tiny (< 6/255 per ch).
          var totalErr = 0;
          var count = 0;
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final i = (y * w + x) * 4;
              final px = decoded.getPixel(x, y);
              totalErr += (px.r.toInt() - src[i + 0]).abs();
              totalErr += (px.g.toInt() - src[i + 1]).abs();
              totalErr += (px.b.toInt() - src[i + 2]).abs();
              count += 3;
            }
          }
          final mae = totalErr / count;
          expect(
            mae,
            lessThan(6.0),
            reason:
                'mean-abs decode error $mae too high — '
                'GPU pipeline diverges from JPEG spec',
          );
        } finally {
          await encoder?.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'high-res 5120x1440 frame encodes without exceeding the 65535 '
      'workgroup-per-dimension dispatch cap',
      () async {
        // Regression: at 5120x1440 the GPU pipeline's per-pixel / per-(block,
        // channel) / per-MCU dispatches overflow WebGPU's 65535/dim cap
        //   color+DCT+quant groups = W*H*3/64 = 345600
        //   Huffman groups         = numMcus = (W/8)*(H/8) = 115200
        // which invalidated the CommandBuffer and produced no output. The
        // pipeline now folds each dispatch into a 2D grid. This asserts the
        // encode completes and yields a JFIF that decodes to the right dims.
        const w = 5120;
        const h = 1440;
        final cfg = EncoderConfig(
          codec: VideoCodec.mjpeg,
          width: w,
          height: h,
          bitrateBps: 0,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          inputPixelFormat: MiniAVPixelFormat.rgba32,
          crfQuality: 5,
        );

        final encoder = await MinigpuBackend().createEncoder(cfg);
        expect(encoder, isNotNull);

        // A smooth gradient (forgiving for DCT); we only need a valid decode.
        final src = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          final row = y * w * 4;
          for (var x = 0; x < w; x++) {
            final i = row + x * 4;
            src[i + 0] = x & 0xff;
            src[i + 1] = y & 0xff;
            src[i + 2] = (x + y) & 0xff;
            src[i + 3] = 0xff;
          }
        }

        try {
          final pkt = await encoder!.encode(
            CpuFrameSource(
              bytes: src,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: w,
              height: h,
              timestampUs: 0,
            ),
          );
          expect(pkt, isNotNull, reason: 'high-res frame produced no packet');
          final jfif = pkt!.data;
          expect(jfif.length, greaterThan(2000));

          final decoded = img.decodeJpg(jfif);
          expect(
            decoded,
            isNotNull,
            reason: 'GPU JFIF for 5120x1440 failed to decode — dispatch '
                'overflow likely corrupted the stream',
          );
          expect(decoded!.width, w);
          expect(decoded.height, h);

          // Sparse MAE (a prime stride keeps the check fast on 7.4M pixels):
          // proves the folded 2D dispatch still covers the whole frame, not
          // just the first 65535*64 elements.
          var totalErr = 0, count = 0;
          for (var p = 0; p < w * h; p += 9973) {
            final x = p % w, y = p ~/ w;
            final i = p * 4;
            final px = decoded.getPixel(x, y);
            totalErr += (px.r.toInt() - src[i + 0]).abs();
            totalErr += (px.g.toInt() - src[i + 1]).abs();
            totalErr += (px.b.toInt() - src[i + 2]).abs();
            count += 3;
          }
          final mae = totalErr / count;
          expect(
            mae,
            lessThan(6.0),
            reason: 'high-res decode MAE $mae too high — folded dispatch may '
                'be dropping rows/blocks beyond the 65535 boundary',
          );
        } finally {
          await encoder?.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
