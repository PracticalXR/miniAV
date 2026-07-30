/// Mimics the ClipBuffer.saveClip path: video track is configured via
/// VideoTrackInfo + extraData (NO bound encoder for video), audio is
/// bound via FfmpegEncoderBridge for ch_layout. Validates that the
/// resulting MP4 plays the correct number of video frames.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegMuxer unbound video (clip_buffer path)', () {
    setUpAll(() async {
      await ensureFFmpegLoaded();
    });

    test('mux H.264 (extradata only) + AAC into MP4', () async {
      const w = 320;
      const h = 240;
      const fps = 30;
      const sampleRate = 48000;
      const channels = 2;
      const seconds = 2;

      final backend = FfmpegBackend();

      final venc = (await backend.createEncoder(
        EncoderConfig(
          codec: VideoCodec.h264,
          width: w,
          height: h,
          bitrateBps: 800_000,
          frameRateNumerator: fps,
          frameRateDenominator: 1,
          backendOptions: const {'global_header': '1'},
        ),
      ))!;
      final aenc = (await backend.createAudioEncoder(
        AudioEncoderConfig(
          codec: AudioCodec.aac,
          sampleRate: sampleRate,
          channels: channels,
          bitrateBps: 128_000,
          backendOptions: const {'global_header': '1'},
        ),
      ))!;

      // Encode all video first so we can capture extradata from venc.
      final rgba = _makeFrame(w, h);
      final vpkts = <EncodedPacket>[];
      for (var i = 0; i < fps * seconds; i++) {
        final ptsUs = (i * 1000000) ~/ fps;
        final src = FrameSource.cpu(
          bytes: rgba,
          pixelFormat: MiniAVPixelFormat.rgba32,
          width: w,
          height: h,
          timestampUs: ptsUs,
        );
        final p = await venc.encode(src);
        if (p != null) vpkts.add(p);
      }
      vpkts.addAll(await venc.flush());

      final extra = venc.extraData;
      expect(extra, isNotNull, reason: 'encoder must expose SPS/PPS extradata');
      print('[test] video extraData size = ${extra!.bytes.length}');

      // Now build a fresh muxer with VideoTrackInfo (extraData only) and
      // bound audio encoder — exactly like ClipBuffer.saveClip does.
      final tmpFile = File(
        '${Directory.systemTemp.path}/miniav_tools_av_mux_unbound.mp4',
      );
      if (tmpFile.existsSync()) tmpFile.deleteSync();

      final muxer = FfmpegMuxer.open(
        MuxerConfig(
          container: Container.mp4,
          output: FileMuxerOutput(tmpFile.path),
          tracks: [
            VideoTrackInfo(
              codec: VideoCodec.h264,
              width: w,
              height: h,
              frameRateNumerator: fps,
              frameRateDenominator: 1,
              extraData: extra,
            ),
            AudioTrackInfo(
              codec: AudioCodec.aac,
              sampleRate: sampleRate,
              channels: channels,
            ),
          ],
        ),
        encoderForTrack: {1: aenc as FfmpegEncoderBridge},
      );
      await muxer.writeHeader();

      for (final p in vpkts) {
        await muxer.writePacket(p.copyWith(trackIndex: 0));
      }

      const totalAudioFrames = sampleRate * seconds;
      final pcm = Float32List(totalAudioFrames * channels);
      for (var i = 0; i < totalAudioFrames; i++) {
        final v = math.sin(2 * math.pi * 440 * i / sampleRate) * 0.25;
        pcm[i * channels] = v;
        pcm[i * channels + 1] = v;
      }
      final pcmBytes = Uint8List.view(pcm.buffer);
      final apkts = await aenc.encode(
        pcm: pcmBytes,
        format: MiniAVAudioFormat.f32,
        frameCount: totalAudioFrames,
        ptsUs: 0,
      );
      for (final p in apkts) {
        await muxer.writePacket(p.copyWith(trackIndex: 1));
      }
      for (final p in await aenc.flush()) {
        await muxer.writePacket(p.copyWith(trackIndex: 1));
      }

      await muxer.finish();
      await muxer.close();
      await venc.close();
      await aenc.close();

      expect(tmpFile.existsSync(), isTrue);
      print('[test] wrote ${tmpFile.path} (${tmpFile.lengthSync()} bytes)');

      // ffprobe to verify.
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'stream=index,codec_name,codec_type,nb_frames,duration',
        '-of',
        'default=nw=1',
        tmpFile.path,
      ]);
      print('[test] ffprobe stdout:\n${probe.stdout}');
      print('[test] ffprobe stderr:\n${probe.stderr}');
      expect(probe.stdout.toString(), contains('codec_name=h264'));
      expect(probe.stdout.toString(), contains('codec_name=aac'));
      // Should have ~60 video frames for 2s @ 30fps.
      expect(
        probe.stdout.toString(),
        contains(RegExp(r'nb_frames=(5\d|60)')),
        reason:
            'expected ~60 video frames; if 0 or missing, video packets were dropped',
      );
    });
  });
}

Uint8List _makeFrame(int w, int h) {
  final buf = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final off = (y * w + x) * 4;
      buf[off] = (x * 255 ~/ w);
      buf[off + 1] = (y * 255 ~/ h);
      buf[off + 2] = 128;
      buf[off + 3] = 255;
    }
  }
  return buf;
}
