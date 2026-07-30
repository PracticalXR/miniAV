/// End-to-end AV mux smoke test: encode 1 second of synthetic video +
/// audio, mux into MP4 and MKV, validate the output files exist and are
/// non-trivial in size.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegMuxer audio+video', () {
    setUpAll(() async {
      await ensureFFmpegLoaded();
    });

    test('mux H.264 + AAC into MP4', () async {
      await _runAvMux(
        container: Container.mp4,
        videoCodec: VideoCodec.h264,
        audioCodec: AudioCodec.aac,
        ext: 'mp4',
      );
    });

    test('mux H.264 + Opus into MKV', () async {
      try {
        await _runAvMux(
          container: Container.mkv,
          videoCodec: VideoCodec.h264,
          audioCodec: AudioCodec.opus,
          ext: 'mkv',
        );
      } on CodecInitException catch (e) {
        if (e.message.contains('libopus') || e.message.contains('Opus')) {
          print('SKIP MKV: libopus missing — ${e.message}');
          return;
        }
        rethrow;
      }
    });
  });
}

Future<void> _runAvMux({
  required Container container,
  required VideoCodec videoCodec,
  required AudioCodec audioCodec,
  required String ext,
}) async {
  const w = 320;
  const h = 240;
  const fps = 30;
  const sampleRate = 48000;
  const channels = 2;
  const seconds = 1;

  final backend = FfmpegBackend();

  final venc = await backend.createEncoder(
    EncoderConfig(
      codec: videoCodec,
      width: w,
      height: h,
      bitrateBps: 800_000,
      frameRateNumerator: fps,
      frameRateDenominator: 1,
      // This test wires the encoder's FfmpegEncoderBridge into the muxer, so
      // keep the in-isolate software encoder (the isolate host has no bridge).
      backendOptions: const {'global_header': '1', 'sw_isolate': '0'},
    ),
  );
  expect(venc, isNotNull);
  final v = venc!;
  final aenc = await backend.createAudioEncoder(
    AudioEncoderConfig(
      codec: audioCodec,
      sampleRate: sampleRate,
      channels: channels,
      bitrateBps: audioCodec == AudioCodec.aac ? 128_000 : 96_000,
      backendOptions: const {'global_header': '1'},
    ),
  );
  expect(aenc, isNotNull);
  final a = aenc!;

  // Build muxer with bound encoders so codecpar (incl. extradata + audio
  // ch_layout) is pulled from each encoder's AVCodecContext.
  final tmpFile = File(
    '${Directory.systemTemp.path}/miniav_tools_av_mux_$ext.$ext',
  );
  if (tmpFile.existsSync()) tmpFile.deleteSync();

  final muxer = FfmpegMuxer.open(
    MuxerConfig(
      container: container,
      output: FileMuxerOutput(tmpFile.path),
      tracks: [
        VideoTrackInfo(
          codec: videoCodec,
          width: w,
          height: h,
          frameRateNumerator: fps,
          frameRateDenominator: 1,
        ),
        AudioTrackInfo(
          codec: audioCodec,
          sampleRate: sampleRate,
          channels: channels,
        ),
      ],
    ),
    encoderForTrack: {0: v as FfmpegEncoderBridge, 1: a as FfmpegEncoderBridge},
  );
  await muxer.writeHeader();

  // Encode + mux video.
  final rgba = _makeFrame(w, h);
  for (var i = 0; i < fps * seconds; i++) {
    final ptsUs = (i * 1000000) ~/ fps;
    final src = FrameSource.cpu(
      bytes: rgba,
      pixelFormat: MiniAVPixelFormat.rgba32,
      width: w,
      height: h,
      timestampUs: ptsUs,
    );
    final p = await v.encode(src);
    if (p != null) {
      await muxer.writePacket(p.copyWith(trackIndex: 0));
    }
  }
  for (final p in await v.flush()) {
    await muxer.writePacket(p.copyWith(trackIndex: 0));
  }

  // Encode + mux audio (1s of 440 Hz stereo sine).
  const totalAudioFrames = sampleRate * seconds;
  final pcm = Float32List(totalAudioFrames * channels);
  for (var i = 0; i < totalAudioFrames; i++) {
    final v = math.sin(2 * math.pi * 440 * i / sampleRate) * 0.25;
    pcm[i * channels] = v;
    pcm[i * channels + 1] = v;
  }
  final pcmBytes = Uint8List.view(pcm.buffer);
  final apkts = await a.encode(
    pcm: pcmBytes,
    format: MiniAVAudioFormat.f32,
    frameCount: totalAudioFrames,
    ptsUs: 0,
  );
  for (final p in apkts) {
    await muxer.writePacket(p.copyWith(trackIndex: 1));
  }
  for (final p in await a.flush()) {
    await muxer.writePacket(p.copyWith(trackIndex: 1));
  }

  await muxer.finish();
  await muxer.close();
  await v.close();
  await a.close();

  expect(tmpFile.existsSync(), isTrue);
  final size = tmpFile.lengthSync();
  print('$container / $videoCodec+$audioCodec → ${tmpFile.path} ($size bytes)');
  expect(size, greaterThan(2048));
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
