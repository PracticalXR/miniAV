@TestOn('vm')
library;

/// End-to-end regression test: encode N frames, decode them with the
/// system `ffmpeg` (libdav1d), and assert each frame round-trips cleanly
/// and the decoded Y/U/V means are in a plausible range for the synthetic
/// gradient source we encode.
///
/// Skipped automatically when `ffmpeg` is not on PATH so it stays
/// portable on machines without the dependency.

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart' show Minigpu;
import 'package:test/test.dart';

bool _hasFfmpeg() {
  try {
    final r = Process.runSync('ffmpeg', ['-version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final hasFfmpeg = _hasFfmpeg();

  group('AV1 encoder dav1d round-trip', () {
    setUpAll(() {
      Minigpu.setLogCallback(null, level: 3);
    });

    test(
      '5 frames of 64x64 gradient decode cleanly',
      () async {
        if (!hasFfmpeg) {
          markTestSkipped('ffmpeg not on PATH');
          return;
        }

        const w = 64, h = 64, frames = 5;
        final tmp = await Directory.systemTemp.createTemp('av1_rt_');
        final mp4 = File('${tmp.path}/out.mp4');
        final dec = File('${tmp.path}/dec.yuv');

        try {
          final backend = MinigpuBackend();
          final enc = await backend.createEncoder(
            EncoderConfig(
              codec: VideoCodec.av1,
              width: w,
              height: h,
              bitrateBps: 0,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              inputPixelFormat: MiniAVPixelFormat.rgba32,
            ),
          );
          expect(enc, isNotNull);

          final pkts = <EncodedPacket>[];
          for (var i = 0; i < frames; i++) {
            final buf = Uint8List(w * h * 4);
            for (var y = 0; y < h; y++) {
              for (var x = 0; x < w; x++) {
                final o = (y * w + x) * 4;
                buf[o + 0] = (x * 200) ~/ (w - 1);
                buf[o + 1] = (y * 200) ~/ (h - 1);
                buf[o + 2] = (x + y + i * 8) & 0x7f;
                buf[o + 3] = 255;
              }
            }
            final p = await enc!.encode(
              CpuFrameSource(
                bytes: buf,
                pixelFormat: MiniAVPixelFormat.rgba32,
                width: w,
                height: h,
                timestampUs: i * 33333,
              ),
            );
            if (p != null) pkts.add(p);
          }
          expect(
            pkts.length,
            frames,
            reason: 'every frame should produce a pkt',
          );

          final mux = await backend.createMuxer(
            MuxerConfig(
              container: Container.mp4,
              output: MuxerOutput.file(mp4.path),
              tracks: [
                VideoTrackInfo(
                  codec: VideoCodec.av1,
                  width: w,
                  height: h,
                  frameRateNumerator: 30,
                  frameRateDenominator: 1,
                  extraData: enc!.extraData,
                ),
              ],
            ),
          );
          await mux!.writeHeader();
          for (final p in pkts) {
            await mux.writePacket(p);
          }
          await mux.finish();
          await mux.close();
          await enc.close();

          // Decode with ffmpeg/libdav1d. We use stderr to catch decode errors.
          final r = Process.runSync('ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            '-i',
            mp4.path,
            '-pix_fmt',
            'yuv420p',
            '-y',
            dec.path,
          ]);
          expect(
            r.stderr.toString(),
            isEmpty,
            reason: 'ffmpeg should decode all frames without error',
          );
          expect(r.exitCode, 0);

          final bytes = dec.readAsBytesSync();
          final perFrame = w * h * 3 ~/ 2;
          expect(
            bytes.length,
            frames * perFrame,
            reason: 'must produce $frames decoded frames',
          );

          // Source is BT.709-limited:  for the gradient above, the expected
          // luma mean is ~99-100 (rgb means r=g=100, b~64).  The encoder is
          // coarsely DC-quantised so we tolerate ±5.
          for (var f = 0; f < frames; f++) {
            final base = f * perFrame;
            var sumY = 0;
            for (var k = 0; k < w * h; k++) {
              sumY += bytes[base + k];
            }
            final yMean = sumY / (w * h);
            expect(
              yMean,
              inInclusiveRange(94.0, 106.0),
              reason: 'frame $f Y mean out of range: $yMean',
            );
          }
        } finally {
          try {
            tmp.deleteSync(recursive: true);
          } catch (_) {}
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
