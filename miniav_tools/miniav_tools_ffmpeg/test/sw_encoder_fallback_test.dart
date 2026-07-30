/// Inventory of SOFTWARE video encoders in the LGPL build, plus a
/// high-resolution (>4096px) probe.
///
/// Purpose: the LGPL build has no libx264/libx265, and HW H.264 caps at
/// 4096px wide. For captures above 4096px on a machine with no hardware HEVC
/// encoder, we need a royalty-free software codec that (a) ships in the LGPL
/// build and (b) accepts arbitrary resolution. This test discovers which
/// software encoders are actually present and which survive a >4096px encode.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('software encoder fallback inventory', () {
    var ready = false;
    setUpAll(() async => ready = await ensureFFmpegLoaded());

    test('which software encoders open at 1280x720 (LGPL build inventory)', () {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      const codecs = [
        VideoCodec.h264,
        VideoCodec.hevc,
        VideoCodec.av1,
        VideoCodec.vp9,
        VideoCodec.vp8,
        VideoCodec.mjpeg,
        VideoCodec.prores,
      ];
      final present = <VideoCodec, String>{};
      for (final c in codecs) {
        try {
          final enc = FfmpegSoftwareEncoder.open(
            EncoderConfig(
              codec: c,
              width: 1280,
              height: 720,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
            ),
          );
          present[c] = 'OK';
          enc.close();
        } on CodecInitException catch (e) {
          present[c] = 'FAIL: ${e.message}';
        }
      }
      // ignore: avoid_print
      print('--- Software encoder inventory (LGPL build) ---');
      present.forEach((k, v) => print('  $k: $v'));
    });

    test(
      'AV1 (SVT-AV1) software encodes a 5120x1440 frame (>4096px fallback)',
      () async {
        if (!ready) {
          print('SKIP: FFmpeg not available');
          return;
        }
        const w = 5120, h = 1440; // ultrawide, beyond H.264 HW 4096 cap
        final (ok, info) = await _tryHighRes(
          VideoCodec.av1,
          w,
          h,
          // SVT-AV1 fastest preset so the probe stays quick.
          backendOptions: const {'preset': '12'},
        );
        print('SVT-AV1 5120x1440: $info');
        expect(
          ok,
          isTrue,
          reason:
              'SVT-AV1 must encode >4096px to serve as the high-res fallback '
              'when no hardware HEVC encoder exists. $info',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('VP9 (libvpx-vp9) software encodes a 5120x1440 frame', () async {
      if (!ready) {
        print('SKIP: FFmpeg not available');
        return;
      }
      const w = 5120, h = 1440;
      final (ok, info) = await _tryHighRes(
        VideoCodec.vp9,
        w,
        h,
        backendOptions: const {'deadline': 'realtime', 'cpu-used': '8'},
      );
      print('VP9 5120x1440: $info');
      // Informational — VP9 may be slower / configured differently; AV1 is the
      // primary candidate. Don't hard-fail the suite on VP9 alone.
      if (!ok) print('INFO: VP9 high-res probe did not produce packets');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

Future<(bool, String)> _tryHighRes(
  VideoCodec codec,
  int w,
  int h, {
  Map<String, String> backendOptions = const {},
}) async {
  FfmpegSoftwareEncoder enc;
  try {
    enc = FfmpegSoftwareEncoder.open(
      EncoderConfig(
        codec: codec,
        width: w,
        height: h,
        bitrateBps: 8_000_000,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        bFrameCount: 0,
        backendOptions: backendOptions,
      ),
    );
  } on CodecInitException catch (e) {
    return (false, 'open failed: ${e.message}');
  }
  try {
    final rgba = _gradient(w, h);
    var packets = 0, bytes = 0;
    for (var i = 0; i < 3; i++) {
      final pkt = await enc.encode(
        FrameSource.cpu(
          bytes: rgba,
          pixelFormat: MiniAVPixelFormat.rgba32,
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
    return (packets > 0, '$packets packets, $bytes bytes');
  } catch (e) {
    return (false, 'encode failed: $e');
  } finally {
    await enc.close();
  }
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
