/// Tests for [IsolateSoftwareEncoder] — the worker-isolate host for the
/// software encoder (the fix for the recorder's software fallback freezing
/// the UI isolate) AND the CPU-fed hardware encoder (the fix for QSV /
/// MediaFoundation init failing on Flutter's STA UI isolate). Exercises a
/// REAL encode on the worker: open, extraData, YUV420P-plane and RGBA-bytes
/// inputs, keyframe request, flush, close.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

const _w = 320, _h = 240;

Uint8List _rgba(int seed) {
  final b = Uint8List(_w * _h * 4);
  for (var i = 0; i < b.length; i += 4) {
    b[i] = (i + seed) & 0xff;
    b[i + 1] = (i >> 2) & 0xff;
    b[i + 2] = seed & 0xff;
    b[i + 3] = 255;
  }
  return b;
}

void main() {
  group('IsolateSoftwareEncoder', () {
    var ready = false;
    setUpAll(() async => ready = await ensureFFmpegLoaded());

    test('encodes AV1 frames on the worker isolate (yuv + rgba inputs)', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      final enc = await IsolateSoftwareEncoder.open(
        const EncoderConfig(
          codec: VideoCodec.av1, // SVT-AV1 is in the LGPL build
          width: _w,
          height: _h,
          bitrateBps: 1_000_000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          bFrameCount: 0,
          backendOptions: {'preset': '12'},
        ),
      );
      try {
        expect(enc.acceptsYuv420pPlanes, isTrue);

        var packets = 0, bytes = 0;
        // RGBA input (worker does the CPU conversion — off the main isolate).
        for (var i = 0; i < 3; i++) {
          final pkt = await enc.encode(
            FrameSource.cpu(
              bytes: _rgba(i),
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: _w,
              height: _h,
              timestampUs: i * 33333,
            ),
          );
          if (pkt != null) {
            packets++;
            bytes += pkt.data.length;
          }
        }
        // Pre-converted YUV planes (the recorder's GPU-YUV path).
        final cw = _w ~/ 2, ch = _h ~/ 2;
        final y = Uint8List(_w * _h)..fillRange(0, _w * _h, 90);
        final u = Uint8List(cw * ch)..fillRange(0, cw * ch, 120);
        final v = Uint8List(cw * ch)..fillRange(0, cw * ch, 140);
        await enc.requestKeyframe();
        for (var i = 3; i < 6; i++) {
          final pkt = await enc.encode(
            FrameSource.yuv420p(
              yPlane: y,
              uPlane: u,
              vPlane: v,
              width: _w,
              height: _h,
              timestampUs: i * 33333,
            ),
          );
          if (pkt != null) {
            packets++;
            bytes += pkt.data.length;
          }
        }
        for (final p in await enc.flush()) {
          packets++;
          bytes += p.data.length;
        }
        expect(
          packets,
          greaterThanOrEqualTo(6),
          reason: '6 frames in → at least 6 packets across encode+flush',
        );
        expect(bytes, greaterThan(0));
        print('isolate AV1: $packets packets, $bytes bytes');
      } finally {
        await enc.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('CPU-fed HW-first on the worker: opens a HW vendor (or falls back to '
        'SW) and encodes — HW init works on the worker MTA thread', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      if (!Platform.isWindows) {
        print('SKIP: CPU-fed HW vendors under test are Windows-only here');
        return;
      }
      // Windows order with MediaFoundation last as the universal fallback;
      // MF before AMF mirrors hwVendorOrderForDevice() on AMD (AMF can encode
      // black there). The worker LOOPS this order, so a registered-but-
      // nonfunctional vendor (e.g. NVENC with no NVIDIA GPU) falls through.
      final enc = await IsolateSoftwareEncoder.open(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: _w,
          height: _h,
          bitrateBps: 2_000_000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          bFrameCount: 0,
          hwAccel: HwAccelPreference.preferred,
        ),
        hwVendorOrder: const [
          HwEncoderVendor.mediafoundation,
          HwEncoderVendor.amf,
          HwEncoderVendor.qsv,
          HwEncoderVendor.nvenc,
        ],
      );
      try {
        // Whatever opened, it must report a description and a consistent input
        // contract: HW encoders want RGBA (acceptsYuv420pPlanes == false), the
        // software fallback wants YUV420P planes (== true).
        print('worker opened: ${enc.activeEncoderDescription} '
            '(yuv420p=${enc.acceptsYuv420pPlanes})');
        expect(enc.activeEncoderDescription, isNotEmpty);

        var packets = 0, bytes = 0;
        for (var i = 0; i < 6; i++) {
          // Feed RGBA regardless: the software encoder also accepts CPU RGBA,
          // and the CPU-fed HW encoder converts RGBA→NV12 on the worker.
          final pkt = await enc.encode(
            FrameSource.cpu(
              bytes: _rgba(i),
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: _w,
              height: _h,
              timestampUs: i * 33333,
            ),
          );
          if (pkt != null) {
            packets++;
            bytes += pkt.data.length;
          }
        }
        for (final p in await enc.flush()) {
          packets++;
          bytes += p.data.length;
        }
        expect(packets, greaterThan(0),
            reason: 'worker encoder (HW or SW) must emit packets');
        expect(bytes, greaterThan(0));
      } finally {
        await enc.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('open failure surfaces as CodecInitException (invalid size)', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      await expectLater(
        () => IsolateSoftwareEncoder.open(
          const EncoderConfig(
            codec: VideoCodec.h264,
            width: -320, // invalid — avcodec_open2 must reject it in the worker
            height: _h,
            bitrateBps: 1_000_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
          ),
        ),
        throwsA(isA<CodecInitException>()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('encode after close throws', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      final enc = await IsolateSoftwareEncoder.open(
        const EncoderConfig(
          codec: VideoCodec.av1,
          width: _w,
          height: _h,
          bitrateBps: 1_000_000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          backendOptions: {'preset': '12'},
        ),
      );
      await enc.close();
      expect(
        () => enc.encode(
          FrameSource.cpu(
            bytes: _rgba(0),
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: _w,
            height: _h,
          ),
        ),
        throwsA(isA<CodecRuntimeException>()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
