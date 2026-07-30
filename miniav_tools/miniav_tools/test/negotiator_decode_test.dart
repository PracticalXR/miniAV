// Tests for the negotiated video-decode path (MiniAVTools.createDecoder):
// probe → filter(HwPreference) → rank → open → attach chosen capability.
//
// Backends here OVERRIDE probe() to report explicit capabilities (specific
// HwPath, zero-copy, score, producedOutputs), so the tests exercise the real
// negotiation logic rather than the boolean-derived default probe.

import 'package:miniav_tools/miniav_tools.dart';
import 'package:test/test.dart';

class _FakeDecoder extends PlatformDecoder {
  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async => null;
  @override
  Future<List<DecodedFrame>> flush() async => const [];
  @override
  Future<void> close() async {}
}

class _NegBackend extends MiniAVToolsBackend {
  @override
  final String name;
  @override
  final int priority;

  /// Capabilities this backend reports from [probe].
  final List<CodecCapability> caps;

  /// When true, [createDecoder] throws to exercise fall-through ranking.
  final bool failInit;

  /// Records the hwAccel the negotiator opened us with (align verification).
  HwAccelPreference? lastOpenHwAccel;
  bool requestedGpuOutput = false;

  _NegBackend(this.name, this.priority, this.caps, {this.failInit = false});

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;
  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => caps.any(
    (c) =>
        c.videoCodec == codec && (hwAccel ? c.isHardware : !c.isHardware),
  );
  @override
  bool supportsAudioEncode(AudioCodec codec) => false;
  @override
  bool supportsAudioDecode(AudioCodec codec) => false;
  @override
  bool supportsMux(Container container) => false;
  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {FrameSourceKind.cpu};

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async {
    lastOpenHwAccel = config.hwAccel;
    requestedGpuOutput = config.requestGpuOutput;
    if (failInit) throw CodecInitException(name, 'simulated init failure');
    return _FakeDecoder();
  }

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;
  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;

  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async => caps
      .where(
        (c) =>
            c.direction == query.direction &&
            c.videoCodec == query.videoCodec,
      )
      .toList();
}

CodecCapability _cap(
  String backend,
  HwPath path, {
  int score = 0,
  bool zeroCopy = false,
  Set<FrameSourceKind> outputs = const {FrameSourceKind.cpu},
}) => CodecCapability(
  backendName: backend,
  direction: CodecDirection.decode,
  videoCodec: VideoCodec.h264,
  hwPath: path,
  isHardware: path != HwPath.software,
  zeroCopy: zeroCopy,
  score: score,
  producedOutputs: outputs,
);

const _h264 = DecoderConfig(codec: VideoCodec.h264);
const _h264Sw = DecoderConfig(
  codec: VideoCodec.h264,
  hwAccel: HwAccelPreference.forbidden,
);

void main() {
  final registered = <_NegBackend>[];

  _NegBackend reg(_NegBackend b) {
    MiniAVToolsPlatform.instance.register(b);
    registered.add(b);
    return b;
  }

  tearDown(() {
    for (final b in registered) {
      MiniAVToolsPlatform.instance.unregisterByName(b.name);
    }
    registered.clear();
  });

  group('ranking', () {
    test('preferred ranks hardware first and pins hwAccel=required', () async {
      final sw = reg(_NegBackend('sw', 50, [_cap('sw', HwPath.software)]));
      final hw = reg(
        _NegBackend('hw', 1, [
          _cap(
            'hw',
            HwPath.d3d11va,
            score: 10,
            zeroCopy: true,
            outputs: {FrameSourceKind.d3d11Texture},
          ),
        ]),
      );

      final dec = await MiniAVTools.createDecoder(_h264);
      expect(dec.backendName, 'hw');
      expect(dec.capability?.hwPath, HwPath.d3d11va);
      expect(dec.isZeroCopy, isTrue);
      expect(
        dec.capability?.producedOutputs,
        contains(FrameSourceKind.d3d11Texture),
      );
      // The winning HW path was opened as `required`; the SW backend untouched.
      expect(hw.lastOpenHwAccel, HwAccelPreference.required);
      expect(sw.lastOpenHwAccel, isNull);
      await dec.close();
    });

    test('forbidden keeps only software and pins hwAccel=forbidden', () async {
      reg(
        _NegBackend('hw', 100, [_cap('hw', HwPath.d3d11va, score: 10)]),
      );
      final sw = reg(_NegBackend('sw', 1, [_cap('sw', HwPath.software)]));

      final dec = await MiniAVTools.createDecoder(_h264Sw);
      expect(dec.backendName, 'sw');
      expect(dec.capability?.isHardware, isFalse);
      expect(sw.lastOpenHwAccel, HwAccelPreference.forbidden);
      await dec.close();
    });

    test('explicit order beats score', () async {
      reg(_NegBackend('dx', 1, [_cap('dx', HwPath.d3d11va, score: 100)]));
      reg(_NegBackend('nv', 1, [_cap('nv', HwPath.nvdec, score: 5)]));

      final dec = await MiniAVTools.createDecoder(
        _h264,
        hwPreference: const HwPreference(
          order: [HwPath.nvdec, HwPath.d3d11va],
        ),
      );
      expect(dec.backendName, 'nv');
      await dec.close();
    });

    test('zero-copy ranks above readback at equal score', () async {
      reg(_NegBackend('rb', 1, [_cap('rb', HwPath.mediaFoundation)]));
      reg(
        _NegBackend('zc', 1, [_cap('zc', HwPath.d3d11va, zeroCopy: true)]),
      );

      final dec = await MiniAVTools.createDecoder(_h264);
      expect(dec.backendName, 'zc');
      await dec.close();
    });

    test('backend priority breaks ties between equal software caps', () async {
      reg(_NegBackend('lo', 1, [_cap('lo', HwPath.software)]));
      reg(_NegBackend('hi', 100, [_cap('hi', HwPath.software)]));

      final dec = await MiniAVTools.createDecoder(_h264Sw);
      expect(dec.backendName, 'hi');
      await dec.close();
    });
  });

  group('filtering', () {
    test('exclude drops the named path', () async {
      reg(_NegBackend('nv', 1, [_cap('nv', HwPath.nvdec, score: 100)]));
      reg(_NegBackend('dx', 1, [_cap('dx', HwPath.d3d11va, score: 10)]));

      final dec = await MiniAVTools.createDecoder(
        _h264,
        hwPreference: const HwPreference(exclude: {HwPath.nvdec}),
      );
      expect(dec.backendName, 'dx');
      await dec.close();
    });

    test('requireZeroCopy drops readback paths', () async {
      reg(
        _NegBackend('rb', 100, [
          _cap('rb', HwPath.mediaFoundation, score: 100),
        ]),
      );
      reg(
        _NegBackend('zc', 1, [
          _cap(
            'zc',
            HwPath.d3d11va,
            zeroCopy: true,
            outputs: {FrameSourceKind.d3d11Texture},
          ),
        ]),
      );

      final dec = await MiniAVTools.createDecoder(
        _h264,
        hwPreference: const HwPreference(requireZeroCopy: true),
      );
      expect(dec.backendName, 'zc');
      expect(dec.isZeroCopy, isTrue);
      await dec.close();
    });

    test('softwareOnly ignores hardware even when available', () async {
      reg(
        _NegBackend('hw', 100, [_cap('hw', HwPath.d3d11va, score: 100)]),
      );
      reg(_NegBackend('sw', 1, [_cap('sw', HwPath.software)]));

      final dec = await MiniAVTools.createDecoder(
        _h264,
        hwPreference: const HwPreference.softwareOnly(),
      );
      expect(dec.backendName, 'sw');
      await dec.close();
    });
  });

  group('failure handling', () {
    test('a failed HW open falls through to the next-ranked path', () async {
      reg(
        _NegBackend(
          'hw',
          100,
          [_cap('hw', HwPath.d3d11va, score: 10)],
          failInit: true,
        ),
      );
      final sw = reg(_NegBackend('sw', 1, [_cap('sw', HwPath.software)]));

      final dec = await MiniAVTools.createDecoder(_h264);
      expect(dec.backendName, 'sw');
      expect(sw.lastOpenHwAccel, HwAccelPreference.forbidden);
      await dec.close();
    });

    test('requireHardware with no HW path throws', () async {
      reg(_NegBackend('sw', 1, [_cap('sw', HwPath.software)]));

      expect(
        () => MiniAVTools.createDecoder(
          _h264,
          hwPreference: const HwPreference.requireHardware(),
        ),
        throwsA(isA<NoBackendForCodecException>()),
      );
    });

    test('surfaces the init error when every candidate fails', () async {
      reg(
        _NegBackend(
          'hw',
          1,
          [_cap('hw', HwPath.d3d11va)],
          failInit: true,
        ),
      );

      expect(
        () => MiniAVTools.createDecoder(
          _h264,
          hwPreference: const HwPreference.requireHardware(),
        ),
        throwsA(isA<CodecInitException>()),
      );
    });
  });

  group('BackendPreference', () {
    test('pinned restricts negotiation to the named backend', () async {
      reg(_NegBackend('a', 1, [_cap('a', HwPath.software)]));
      reg(_NegBackend('b', 100, [_cap('b', HwPath.software)]));

      final dec = await MiniAVTools.createDecoder(
        _h264Sw,
        preference: BackendPreference.pinned('a'),
      );
      expect(dec.backendName, 'a');
      await dec.close();
    });
  });
}
