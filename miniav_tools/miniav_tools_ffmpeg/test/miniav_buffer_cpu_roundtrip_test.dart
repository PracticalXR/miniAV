/// Roundtrip test for the MiniAVBufferSource CPU path.
///
/// Verifies that when a frame arrives as a [MiniAVBuffer] (CPU content type)
/// — which is how real miniav screen/camera/loopback frames are delivered —
/// the encoder correctly reads [MiniAVVideoBuffer.planes][0] and produces
/// output whose decoded luma is non-zero.
///
/// This test catches the silent-black-frame regression: if planes[0] is
/// ignored or its bytes are not forwarded to the pixel-conversion path, the
/// encoder may still produce valid packets (passing a simple "bytes > 0"
/// check) while every decoded frame is all-black.
///
/// Also asserts that a GPU-backed buffer (planes[0] == null) throws
/// [CodecRuntimeException] rather than silently encoding black frames.
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

  group('MiniAVBufferSource CPU path', () {
    setUpAll(() async {
      if (enabled) await ensureFFmpegLoaded();
    });

    test(
      'decoded luma is non-zero when planes[0] contains real pixel data',
      skip: enabled
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        const w = 320;
        const h = 240;
        const frames = 4;

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
            hwAccel: HwAccelPreference.forbidden,
            backendOptions: {'preset': 'ultrafast', 'tune': 'zerolatency'},
          ),
        );
        expect(enc, isNotNull);

        final dec = await backend.createDecoder(
          const DecoderConfig(codec: VideoCodec.h264),
        );
        expect(dec, isNotNull);

        final packets = <EncodedPacket>[];
        for (var i = 0; i < frames; i++) {
          // Wrap the gradient bytes inside a MiniAVBuffer to exercise the
          // MiniAVBufferSource code path (not FrameSource.cpu).
          final rgba = _gradientRgba(w, h, i);
          final src = FrameSource.miniavBuffer(
            MiniAVBuffer(
              type: MiniAVBufferType.video,
              contentType: MiniAVBufferContentType.cpu,
              timestampUs: i * 33333,
              dataSizeBytes: rgba.length,
              data: MiniAVVideoBuffer(
                width: w,
                height: h,
                pixelFormat: MiniAVPixelFormat.rgba32,
                strideBytes: [w * 4],
                planes: [rgba],
              ),
            ),
          );
          final pkt = await enc!.encode(src);
          if (pkt != null) packets.add(pkt);
        }
        packets.addAll(await enc!.flush());
        expect(packets, isNotEmpty, reason: 'encoder produced no packets');

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
              'frame count mismatch: expected $frames, got ${decoded.length}',
        );

        // Read luma plane of the first decoded frame and assert it is NOT
        // all-zero. A black frame has Y = 16 (limited range), so checking
        // for any value > 0 is sufficient. An all-zero Y plane (YUV 0,0,0)
        // means the pixel bytes from planes[0] were never forwarded.
        final firstFrameBytes = await decoded.first.readBytes();
        final yPlane = Uint8List.fromList(firstFrameBytes.sublist(0, w * h));
        final maxY = yPlane.reduce(math.max);
        expect(
          maxY,
          greaterThan(0),
          reason:
              'Decoded luma is all-zero — MiniAVBufferSource CPU plane bytes '
              'were not forwarded to the encoder. This indicates a silent '
              'black-frame regression in the CPU path.',
        );

        // Also check PSNR vs the RGBA→Y reference so we catch partial
        // corruption as well (not just the all-black case).
        final refY = _rgbaToY(_gradientRgba(w, h, 0), w, h);
        final psnr = _psnr8(refY, yPlane);
        expect(
          psnr,
          greaterThan(30.0),
          reason:
              'PSNR(Y) too low (${psnr.toStringAsFixed(2)} dB) — '
              'decoded luma does not match the source gradient',
        );
        print(
          'MiniAVBufferSource CPU roundtrip PSNR(Y): '
          '${psnr.toStringAsFixed(2)} dB '
          '(${packets.length} packets, ${decoded.length} frames)',
        );

        await enc.close();
        await dec.close();
      },
    );

    test(
      'GPU-backed buffer (planes[0] == null) throws CodecRuntimeException',
      skip: enabled
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        const w = 320;
        const h = 240;

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
            hwAccel: HwAccelPreference.forbidden,
            backendOptions: {'preset': 'ultrafast'},
          ),
        );
        expect(enc, isNotNull);

        // Simulate a GPU-backed frame where planes[0] is null (as delivered
        // when outputPreference is NOT set to cpu — the default D3D11 path).
        final gpuSrc = FrameSource.miniavBuffer(
          MiniAVBuffer(
            type: MiniAVBufferType.video,
            contentType: MiniAVBufferContentType.gpuD3D11Handle,
            timestampUs: 0,
            dataSizeBytes: 0,
            data: MiniAVVideoBuffer(
              width: w,
              height: h,
              pixelFormat: MiniAVPixelFormat.bgra32,
              strideBytes: [],
              planes: [null], // GPU-backed: no CPU bytes
            ),
          ),
        );

        // Must throw — NOT silently encode a black frame.
        await expectLater(
          () => enc!.encode(gpuSrc),
          throwsA(isA<CodecRuntimeException>()),
          reason:
              'Encoder accepted a GPU-backed buffer with null planes[0] '
              'without throwing. This risks silently encoding black frames.',
        );

        await enc!.close();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Helpers (duplicated from roundtrip_test to keep this file self-contained)
// ---------------------------------------------------------------------------

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
