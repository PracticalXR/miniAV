/// Verifies the software encoder accepts pre-converted planar YUV420P frames
/// (`FrameSource.yuv420p`) directly — the path used when the GPU converts
/// RGBA→YUV420P and hands the encoder the planes with no CPU conversion.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('software encoder YUV420P plane input', () {
    var ready = false;
    setUpAll(() async => ready = await ensureFFmpegLoaded());

    test('advertises acceptsYuv420pPlanes and encodes FrameSource.yuv420p', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      const w = 320, h = 240;
      final enc = FfmpegSoftwareEncoder.open(
        EncoderConfig(
          codec: VideoCodec.av1, // SVT-AV1 is present in the LGPL build
          width: w,
          height: h,
          bitrateBps: 1_000_000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          bFrameCount: 0,
          backendOptions: const {'preset': '12'}, // fastest, keep the probe quick
        ),
      );

      expect(
        enc.acceptsYuv420pPlanes,
        isTrue,
        reason: 'software encoder must advertise native YUV420P plane input',
      );

      try {
        final cw = w ~/ 2, ch = h ~/ 2;
        final yP = Uint8List(w * h);
        for (var i = 0; i < yP.length; i++) {
          yP[i] = i & 0xff; // some luma variation
        }
        final uP = Uint8List(cw * ch)..fillRange(0, cw * ch, 100);
        final vP = Uint8List(cw * ch)..fillRange(0, cw * ch, 160);

        var packets = 0, bytes = 0;
        for (var i = 0; i < 3; i++) {
          final pkt = await enc.encode(
            FrameSource.yuv420p(
              yPlane: yP,
              uPlane: uP,
              vPlane: vP,
              width: w,
              height: h,
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
          greaterThan(0),
          reason: 'pre-converted YUV420P planes must encode to packets',
        );
        print('YUV420P-input AV1 ${w}x$h: $packets packets, $bytes bytes');
      } finally {
        await enc.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
