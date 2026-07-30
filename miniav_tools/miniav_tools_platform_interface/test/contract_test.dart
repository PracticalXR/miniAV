// Pure-Dart contract tests for miniav_tools_platform_interface.
// Verify that the public types exist with the expected shape and defaults.
// No backends required.

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('VideoCodec enum', () {
    test('contains H.264, HEVC, AV1, VP9, VP8, MJPEG, ProRes', () {
      expect(VideoCodec.values, contains(VideoCodec.h264));
      expect(VideoCodec.values, contains(VideoCodec.hevc));
      expect(VideoCodec.values, contains(VideoCodec.av1));
      expect(VideoCodec.values, contains(VideoCodec.vp9));
      expect(VideoCodec.values, contains(VideoCodec.vp8));
      expect(VideoCodec.values, contains(VideoCodec.mjpeg));
      expect(VideoCodec.values, contains(VideoCodec.prores));
    });
  });

  group('AudioCodec enum', () {
    test('contains AAC, Opus, Vorbis, MP3, FLAC, PCM variants', () {
      expect(AudioCodec.values, contains(AudioCodec.aac));
      expect(AudioCodec.values, contains(AudioCodec.opus));
      expect(AudioCodec.values, contains(AudioCodec.vorbis));
      expect(AudioCodec.values, contains(AudioCodec.mp3));
      expect(AudioCodec.values, contains(AudioCodec.flac));
      expect(AudioCodec.values, contains(AudioCodec.pcmS16le));
      expect(AudioCodec.values, contains(AudioCodec.pcmF32le));
    });
  });

  group('Container enum', () {
    test('contains MP4, fMP4, MKV, WebM, MPEG-TS, raw, Ogg, WAV', () {
      expect(Container.values, contains(Container.mp4));
      expect(Container.values, contains(Container.fmp4));
      expect(Container.values, contains(Container.mkv));
      expect(Container.values, contains(Container.webm));
      expect(Container.values, contains(Container.mpegts));
      expect(Container.values, contains(Container.raw));
      expect(Container.values, contains(Container.ogg));
      expect(Container.values, contains(Container.wav));
    });
  });

  group('HwAccelPreference enum', () {
    test('has forbidden / allowed / preferred / required', () {
      expect(HwAccelPreference.values, hasLength(4));
    });
  });

  group('EncoderConfig', () {
    test('required fields are wired through', () {
      const cfg = EncoderConfig(
        codec: VideoCodec.h264,
        width: 1920,
        height: 1080,
        bitrateBps: 8_000_000,
      );
      expect(cfg.codec, equals(VideoCodec.h264));
      expect(cfg.width, equals(1920));
      expect(cfg.height, equals(1080));
      expect(cfg.bitrateBps, equals(8_000_000));
    });

    test('defaults are sensible', () {
      const cfg = EncoderConfig(
        codec: VideoCodec.h264,
        width: 1280,
        height: 720,
        bitrateBps: 4_000_000,
      );
      expect(cfg.frameRateNumerator, equals(30));
      expect(cfg.frameRateDenominator, equals(1));
      expect(cfg.inputPixelFormat, equals(MiniAVPixelFormat.nv12));
      expect(cfg.hwAccel, equals(HwAccelPreference.preferred));
      expect(cfg.rateControl, equals(RateControl.vbr));
      expect(cfg.profile, equals(EncoderProfile.high));
      expect(cfg.bFrameCount, equals(0));
      expect(cfg.gopLength, equals(0));
      expect(cfg.backendOptions, isEmpty);
    });
  });

  group('DecoderConfig', () {
    test('required fields and defaults', () {
      const cfg = DecoderConfig(codec: VideoCodec.h264);
      expect(cfg.codec, equals(VideoCodec.h264));
      expect(cfg.hwAccel, equals(HwAccelPreference.preferred));
      expect(cfg.outputPixelFormat, equals(MiniAVPixelFormat.nv12));
      expect(cfg.requestGpuOutput, isFalse);
      expect(cfg.extraData, isNull);
    });
  });

  group('MuxerConfig + MuxerOutput', () {
    test('FileMuxerOutput carries path', () {
      final out = MuxerOutput.file('out.mp4');
      expect(out, isA<FileMuxerOutput>());
      expect((out as FileMuxerOutput).path, equals('out.mp4'));
    });

    test('BytesMuxerOutput is constructible', () {
      final out = MuxerOutput.bytes();
      expect(out, isA<BytesMuxerOutput>());
    });

    test('CallbackMuxerOutput carries callback', () {
      var called = false;
      final out = MuxerOutput.callback((_) => called = true);
      expect(out, isA<CallbackMuxerOutput>());
      (out as CallbackMuxerOutput).onChunk(Uint8List(1));
      expect(called, isTrue);
    });

    test('MuxerConfig accepts video and audio tracks', () {
      final cfg = MuxerConfig(
        container: Container.mp4,
        output: MuxerOutput.file('o.mp4'),
        tracks: const [
          VideoTrackInfo(
            codec: VideoCodec.h264,
            width: 1920,
            height: 1080,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
          ),
          AudioTrackInfo(codec: AudioCodec.aac, sampleRate: 48000, channels: 2),
        ],
      );
      expect(cfg.tracks, hasLength(2));
      expect(cfg.tracks[0], isA<VideoTrackInfo>());
      expect(cfg.tracks[1], isA<AudioTrackInfo>());
    });
  });

  group('FrameSource sealed hierarchy', () {
    test('CPU variant', () {
      final fs = FrameSource.cpu(
        bytes: Uint8List(64 * 64 * 4),
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: 64,
        height: 64,
      );
      expect(fs, isA<CpuFrameSource>());
      expect(fs.kind, equals(FrameSourceKind.cpu));
      expect(fs.width, equals(64));
      expect(fs.height, equals(64));
      expect(fs.pixelFormat, equals(MiniAVPixelFormat.rgba32));
    });

    test('miniavBuffer (CPU video) maps to miniavBufferCpu kind', () {
      final video = MiniAVVideoBuffer(
        width: 16,
        height: 16,
        pixelFormat: MiniAVPixelFormat.nv12,
        strideBytes: const [16, 16],
        planes: [Uint8List(256), Uint8List(128)],
      );
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.cpu,
        timestampUs: 1000,
        data: video,
        dataSizeBytes: 384,
      );
      final fs = FrameSource.miniavBuffer(buf);
      expect(fs.kind, equals(FrameSourceKind.miniavBufferCpu));
      expect(fs.width, equals(16));
      expect(fs.height, equals(16));
      expect(fs.pixelFormat, equals(MiniAVPixelFormat.nv12));
      expect(fs.timestampUs, equals(1000));
    });

    test('miniavBuffer (D3D11) maps to miniavBufferD3D11 kind', () {
      final video = MiniAVVideoBuffer(
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.nv12,
        strideBytes: const [0, 0],
        planes: const [null, null],
      );
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.gpuD3D11Handle,
        timestampUs: 2000,
        data: video,
        dataSizeBytes: 0,
        nativeHandle: 0xDEADBEEF,
        nativeFence: const MiniAVNativeFence(d3d11FencePtr: 0xCAFE),
      );
      final fs = FrameSource.miniavBuffer(buf);
      expect(fs.kind, equals(FrameSourceKind.miniavBufferD3D11));
    });

    test('d3d11Texture, cvPixelBuffer, dmabuf escape hatches', () {
      final a = FrameSource.d3d11Texture(
        texturePtr: 0x1000,
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.nv12,
      );
      final b = FrameSource.cvPixelBuffer(
        cvPixelBufferPtr: 0x2000,
        width: 1280,
        height: 720,
        pixelFormat: MiniAVPixelFormat.nv12,
      );
      final c = FrameSource.dmabuf(
        fds: const [3],
        strides: const [1920],
        offsets: const [0],
        modifier: 0,
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.nv12,
      );
      expect(a.kind, equals(FrameSourceKind.d3d11Texture));
      expect(b.kind, equals(FrameSourceKind.cvPixelBuffer));
      expect(c.kind, equals(FrameSourceKind.dmabuf));
    });
  });

  group('EncodedPacket', () {
    test('toString summarises pts/dts/keyframe', () {
      final pkt = EncodedPacket(
        data: Uint8List(123),
        ptsUs: 1000,
        dtsUs: 1000,
        isKeyframe: true,
      );
      final s = pkt.toString();
      expect(s, contains('123B'));
      expect(s, contains('pts=1000us'));
      expect(s, contains('KEY'));
    });

    test('non-keyframe shows P/B', () {
      final pkt = EncodedPacket(data: Uint8List(50), ptsUs: 2000, dtsUs: 1500);
      expect(pkt.toString(), contains('P/B'));
    });
  });

  group('Exception types', () {
    test('NoBackendForCodecException.video carries codec', () {
      final e = NoBackendForCodecException.video(VideoCodec.av1, hwAccel: true);
      expect(e.videoCodec, equals(VideoCodec.av1));
      expect(e.message, contains('av1'));
      expect(e.message, contains('HW accel'));
    });

    test('NoBackendForCodecException.container carries container', () {
      final e = NoBackendForCodecException.container(Container.fmp4);
      expect(e.container, equals(Container.fmp4));
    });

    test('CodecInitException includes backend name and message', () {
      const e = CodecInitException('ffmpeg', 'NVENC driver not found');
      expect(e.backendName, equals('ffmpeg'));
      expect(e.toString(), contains('ffmpeg'));
      expect(e.toString(), contains('NVENC'));
    });

    test('CodecInitException with cause includes cause', () {
      const e = CodecInitException(
        'ffmpeg',
        'init failed',
        cause: 'AVERROR_INVALIDDATA',
      );
      expect(e.toString(), contains('AVERROR_INVALIDDATA'));
    });
  });

  group('BackendPreference', () {
    test('auto is a singleton const', () {
      expect(BackendPreference.auto, isA<BackendPreference>());
      expect(BackendPreference.auto, same(BackendPreference.auto));
    });

    test('pinned carries name', () {
      final p = BackendPreference.pinned('ffmpeg');
      expect(p, isA<PinnedBackendPreference>());
      expect((p as PinnedBackendPreference).backendName, equals('ffmpeg'));
    });

    test('excluded carries set', () {
      final p = BackendPreference.excluded({'web', 'minigpu'});
      expect(p, isA<ExcludedBackendPreference>());
      expect((p as ExcludedBackendPreference).backendNames, hasLength(2));
    });
  });
}
