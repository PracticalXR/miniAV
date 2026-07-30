// Integration tests for the MiniAVTools facade using fake backends.
// Verifies backend selection, priority resolution, capability filtering,
// and BackendPreference semantics — without depending on any real codec.

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:test/test.dart';

class _FakeEncoder extends PlatformEncoder {
  final String tag;
  bool closed = false;
  int frameCount = 0;

  _FakeEncoder(this.tag);

  @override
  CodecExtraData? get extraData =>
      CodecExtraData.video(VideoCodec.h264, Uint8List.fromList([1, 2, 3]));

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    frameCount++;
    return EncodedPacket(
      data: Uint8List.fromList([0, 0, 0, 1, frameCount & 0xff]),
      ptsUs: frame.timestampUs,
      dtsUs: frame.timestampUs,
      isKeyframe: frameCount == 1,
    );
  }

  @override
  Future<List<EncodedPacket>> flush() async => const [];

  @override
  Future<void> requestKeyframe() async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeBackend extends MiniAVToolsBackend {
  @override
  final String name;
  @override
  final int priority;

  final Set<VideoCodec> encodeCodecs;
  final Set<VideoCodec> hwEncodeCodecs;
  final Set<Container> muxContainers;

  bool failInit;

  _FakeBackend({
    required this.name,
    required this.priority,
    this.encodeCodecs = const {},
    this.hwEncodeCodecs = const {},
    this.muxContainers = const {},
    this.failInit = false,
  });

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) =>
      hwAccel ? hwEncodeCodecs.contains(codec) : encodeCodecs.contains(codec);

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;
  @override
  bool supportsAudioDecode(AudioCodec codec) => false;

  @override
  bool supportsMux(Container container) => muxContainers.contains(container);
  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => {
    FrameSourceKind.cpu,
    FrameSourceKind.miniavBufferCpu,
  };

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async {
    if (failInit) {
      throw CodecInitException(name, 'simulated init failure');
    }
    return _FakeEncoder(name);
  }

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;
  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;
  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}

void main() {
  setUp(() {
    // Reset registry between tests.
    MiniAVToolsPlatform.instance.unregisterByName('low');
    MiniAVToolsPlatform.instance.unregisterByName('high');
    MiniAVToolsPlatform.instance.unregisterByName('only-sw');
    MiniAVToolsPlatform.instance.unregisterByName('only-hw');
    MiniAVToolsPlatform.instance.unregisterByName('failing');
    MiniAVToolsPlatform.instance.unregisterByName('mp4');
  });

  group('Backend registration', () {
    test('register adds backends; backends getter returns them', () {
      final b = _FakeBackend(name: 'low', priority: 1);
      MiniAVToolsPlatform.instance.register(b);
      expect(
        MiniAVToolsPlatform.instance.backends.any((x) => x.name == 'low'),
        isTrue,
      );
    });

    test('unregisterByName removes', () {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1),
      );
      MiniAVToolsPlatform.instance.unregisterByName('low');
      expect(
        MiniAVToolsPlatform.instance.backends.any((x) => x.name == 'low'),
        isFalse,
      );
    });
  });

  group('createEncoder routing', () {
    test(
      'picks the highest-priority backend that supports the codec',
      () async {
        MiniAVToolsPlatform.instance.register(
          _FakeBackend(
            name: 'low',
            priority: 1,
            encodeCodecs: {VideoCodec.h264},
          ),
        );
        MiniAVToolsPlatform.instance.register(
          _FakeBackend(
            name: 'high',
            priority: 100,
            encodeCodecs: {VideoCodec.h264},
          ),
        );

        final enc = await MiniAVTools.createEncoder(
          const EncoderConfig(
            codec: VideoCodec.h264,
            width: 64,
            height: 64,
            bitrateBps: 100_000,
            hwAccel: HwAccelPreference.forbidden,
          ),
        );
        expect(enc.backendName, equals('high'));
        await enc.close();
      },
    );

    test('skips backends that do not support the codec', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'high',
          priority: 100,
          encodeCodecs: {VideoCodec.av1}, // not h264
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1, encodeCodecs: {VideoCodec.h264}),
      );

      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.forbidden,
        ),
      );
      expect(enc.backendName, equals('low'));
      await enc.close();
    });

    test(
      'throws NoBackendForCodecException when no backend supports',
      () async {
        MiniAVToolsPlatform.instance.register(
          _FakeBackend(
            name: 'only-sw',
            priority: 1,
            encodeCodecs: {VideoCodec.h264},
          ),
        );

        expect(
          () => MiniAVTools.createEncoder(
            const EncoderConfig(
              codec: VideoCodec.av1,
              width: 64,
              height: 64,
              bitrateBps: 100_000,
            ),
          ),
          throwsA(isA<NoBackendForCodecException>()),
        );
      },
    );

    test('hwAccel=required only picks HW-capable backends', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'only-sw',
          priority: 100,
          encodeCodecs: {VideoCodec.h264},
          // no hwEncodeCodecs
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'only-hw',
          priority: 1,
          encodeCodecs: {VideoCodec.h264},
          hwEncodeCodecs: {VideoCodec.h264},
        ),
      );

      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.required,
        ),
      );
      expect(enc.backendName, equals('only-hw'));
      await enc.close();
    });

    test('hwAccel=preferred falls back to SW when HW unavailable', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'only-sw',
          priority: 100,
          encodeCodecs: {VideoCodec.h264},
        ),
      );

      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.preferred,
        ),
      );
      expect(enc.backendName, equals('only-sw'));
      await enc.close();
    });

    test(
      'hwAccel=required rethrows CodecInitException without falling back',
      () async {
        MiniAVToolsPlatform.instance.register(
          _FakeBackend(
            name: 'failing',
            priority: 100,
            encodeCodecs: {VideoCodec.h264},
            hwEncodeCodecs: {VideoCodec.h264},
            failInit: true,
          ),
        );

        expect(
          () => MiniAVTools.createEncoder(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: 64,
              height: 64,
              bitrateBps: 100_000,
              hwAccel: HwAccelPreference.required,
            ),
          ),
          throwsA(isA<CodecInitException>()),
        );
      },
    );
  });

  group('BackendPreference', () {
    test('pinned forces the named backend', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'high',
          priority: 100,
          encodeCodecs: {VideoCodec.h264},
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1, encodeCodecs: {VideoCodec.h264}),
      );

      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.forbidden,
        ),
        preference: BackendPreference.pinned('low'),
      );
      expect(enc.backendName, equals('low'));
      await enc.close();
    });

    test('excluded skips the named backends', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'high',
          priority: 100,
          encodeCodecs: {VideoCodec.h264},
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1, encodeCodecs: {VideoCodec.h264}),
      );

      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.forbidden,
        ),
        preference: BackendPreference.excluded({'high'}),
      );
      expect(enc.backendName, equals('low'));
      await enc.close();
    });
  });

  group('Encoder lifecycle', () {
    test('encode → close → cannot encode again', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1, encodeCodecs: {VideoCodec.h264}),
      );
      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.forbidden,
        ),
      );
      final pkt = await enc.encode(
        FrameSource.cpu(
          bytes: Uint8List(64 * 64 * 4),
          pixelFormat: MiniAVPixelFormat.rgba32,
          width: 64,
          height: 64,
        ),
      );
      expect(pkt, isNotNull);
      expect(pkt!.isKeyframe, isTrue);
      await enc.close();
      expect(enc.isClosed, isTrue);
      expect(
        () => enc.encode(
          FrameSource.cpu(
            bytes: Uint8List(64 * 64 * 4),
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: 64,
            height: 64,
          ),
        ),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(name: 'low', priority: 1, encodeCodecs: {VideoCodec.h264}),
      );
      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 100_000,
          hwAccel: HwAccelPreference.forbidden,
        ),
      );
      await enc.close();
      await enc.close(); // must not throw
      expect(enc.isClosed, isTrue);
    });
  });

  group('Capability discovery', () {
    test('supportedEncodeCodecs aggregates across backends', () {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'low',
          priority: 1,
          encodeCodecs: {VideoCodec.h264, VideoCodec.vp9},
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'high',
          priority: 100,
          encodeCodecs: {VideoCodec.av1},
        ),
      );
      final supported = MiniAVToolsPlatform.instance.supportedEncodeCodecs();
      expect(supported, contains(VideoCodec.h264));
      expect(supported, contains(VideoCodec.vp9));
      expect(supported, contains(VideoCodec.av1));
      expect(supported, isNot(contains(VideoCodec.hevc)));
    });

    test('supportedMuxContainers aggregates', () {
      MiniAVToolsPlatform.instance.register(
        _FakeBackend(
          name: 'mp4',
          priority: 1,
          muxContainers: {Container.mp4, Container.fmp4},
        ),
      );
      final supported = MiniAVToolsPlatform.instance.supportedMuxContainers();
      expect(supported, contains(Container.mp4));
      expect(supported, contains(Container.fmp4));
    });
  });
}
