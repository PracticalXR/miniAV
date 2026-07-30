/// Phase C: FFmpeg libavformat MP4 muxer smoke test.
///
/// Encodes a few synthetic frames with libx264 (global_header on),
/// writes them through `FfmpegMuxer` into an MP4 file, then verifies
/// the resulting file:
///   - exists and is non-empty
///   - has the ISO base-media `ftyp` box at offset 4
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  final enabled =
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();

  test(
    'libx264 → FfmpegMuxer writes a valid MP4 file',
    skip: enabled
        ? null
        : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
    () async {
      expect(await ensureFFmpegLoaded(), isTrue);

      const w = 320;
      const h = 240;
      const frames = 12;

      final tmp = await Directory.systemTemp.createTemp('miniav_mux_');
      final outPath = '${tmp.path}/out.mp4';

      try {
        final backend = FfmpegBackend();

        // Encode with global_header so SPS/PPS land in extradata
        // (required for MP4).
        final enc = await backend.createEncoder(
          const EncoderConfig(
            codec: VideoCodec.h264,
            width: w,
            height: h,
            // This test is libx264-specific (extradata + global_header path),
            // so force software even on systems with NVENC/AMF/QSV available.
            hwAccel: HwAccelPreference.forbidden,
            bitrateBps: 2_000_000,
            gopLength: 4,
            bFrameCount: 0,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            rateControl: RateControl.crf,
            crfQuality: 23,
            backendOptions: {
              'preset': 'ultrafast',
              'tune': 'zerolatency',
              'global_header': '1',
              // This test needs the in-isolate encoder: it casts to
              // FfmpegSoftwareEncoder and wires its bridge into the muxer.
              'sw_isolate': '0',
            },
          ),
        );
        expect(enc, isNotNull);
        final ffEnc = enc! as FfmpegSoftwareEncoder;

        // The muxer pulls codec parameters straight from the encoder's
        // native AVCodecContext — preserves extradata + correct codec_tag.
        final muxer = FfmpegMuxer.open(
          MuxerConfig(
            container: Container.mp4,
            output: MuxerOutput.file(outPath),
            tracks: const [
              VideoTrackInfo(
                codec: VideoCodec.h264,
                width: w,
                height: h,
                frameRateNumerator: 30,
                frameRateDenominator: 1,
              ),
            ],
          ),
          encoderForTrack: {0: ffEnc},
        );

        await muxer.writeHeader();

        for (var i = 0; i < frames; i++) {
          final src = FrameSource.cpu(
            bytes: _gradientRgba(w, h, i),
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: w,
            height: h,
            timestampUs: i * 33333,
          );
          final pkt = await ffEnc.encode(src);
          if (pkt != null) await muxer.writePacket(pkt);
        }
        for (final pkt in await ffEnc.flush()) {
          await muxer.writePacket(pkt);
        }

        await muxer.finish();
        await muxer.close();
        await ffEnc.close();

        final f = File(outPath);
        expect(f.existsSync(), isTrue, reason: 'output file missing');
        final bytes = await f.readAsBytes();
        expect(
          bytes.length,
          greaterThan(1024),
          reason: 'mp4 unexpectedly small (${bytes.length}B)',
        );

        // Verify ISO base media `ftyp` box at offset 4.
        expect(bytes.length, greaterThanOrEqualTo(8));
        final magic = String.fromCharCodes(bytes.sublist(4, 8));
        expect(
          magic,
          equals('ftyp'),
          reason: 'expected ftyp magic, saw "$magic"',
        );
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Simple animated RGBA gradient.
Uint8List _gradientRgba(int w, int h, int frame) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      out[i + 0] = ((x + frame * 4) & 0xff);
      out[i + 1] = ((y + frame * 2) & 0xff);
      out[i + 2] = ((x + y + frame * 6) & 0xff);
      out[i + 3] = 0xff;
    }
  }
  return out;
}
