// Proves P0.1: createEncoder / createAudioEncoder / createAudioDecoder /
// createMuxer / createDemuxer route through the SAME capability negotiator as
// createDecoder — so `BackendPreference.excluded`, `requireZeroCopy`, and
// capability-over-priority ranking work identically across every factory, and
// the chosen CodecCapability is attached to the returned wrapper.
//
// Uses fake backends that override probe() with explicit capabilities — no real
// codec. A LOW-priority "first-party" backend reports a hardware/zero-copy
// capability; a HIGH-priority "ffmpeg-like" backend reports only software.

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:test/test.dart';

// --- Minimal fake platform objects (only what the wrappers call) -------------

class _FE extends PlatformEncoder {
  @override
  CodecExtraData? get extraData => null;
  @override
  Future<EncodedPacket?> encode(FrameSource frame) async => null;
  @override
  Future<List<EncodedPacket>> flush() async => const [];
  @override
  Future<void> requestKeyframe() async {}
  @override
  Future<void> close() async {}
}

class _FAE extends PlatformAudioEncoder {
  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async => const [];
  @override
  Future<List<EncodedPacket>> flush() async => const [];
  @override
  CodecExtraData? get extraData => null;
  @override
  Future<void> close() async {}
}

class _FAD extends PlatformAudioDecoder {
  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async => const [];
  @override
  Future<List<DecodedAudio>> flush() async => const [];
  @override
  Future<void> close() async {}
}

class _FM extends PlatformMuxer {
  @override
  Future<void> writeHeader() async {}
  @override
  Future<void> writePacket(EncodedPacket packet) async {}
  @override
  Future<void> finish() async {}
  @override
  Future<void> close() async {}
}

class _FD extends PlatformDemuxer {
  @override
  List<TrackInfo> get tracks => const [];
  @override
  Future<EncodedPacket?> readPacket() async => null;
  @override
  Future<void> seek(int timestampUs) async {}
  @override
  Future<void> close() async {}
}

// --- A backend whose capabilities are driven by an injected builder ----------

typedef _CapsFn = List<CodecCapability> Function(String name, CodecQuery q);

class _CapBackend extends MiniAVToolsBackend {
  @override
  final String name;
  @override
  final int priority;
  final _CapsFn caps;

  _CapBackend(this.name, this.priority, this.caps);

  // probe() is the source of truth for the facade; supports* stay generous.
  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async =>
      caps(name, query);

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => true;
  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => true;
  @override
  bool supportsAudioEncode(AudioCodec codec) => true;
  @override
  bool supportsAudioDecode(AudioCodec codec) => true;
  @override
  bool supportsMux(Container container) => true;
  @override
  bool supportsDemux(Container container) => true;
  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {FrameSourceKind.cpu};

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => _FE();
  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;
  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => _FM();
  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => _FD();
  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) async => _FAE();
  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) async => _FAD();
}

// A backend that uses the DEFAULT base probe() (so it emits the generic
// `HwPath.hardware` cap, not an honest specific path) and records the hwAccel
// its createEncoder was called with — to prove the facade preserves the
// caller's original hwAccel for generic caps (the recorder-safety guarantee).
class _RecordingBaseBackend extends MiniAVToolsBackend {
  @override
  String get name => 'rec';
  @override
  int get priority => 50;

  HwAccelPreference? lastHwAccel;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => true; // sw + hw
  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;
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
  }) async {
    lastHwAccel = config.hwAccel;
    return _FE();
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

CodecCapability _cap(
  String name,
  CodecQuery q, {
  required HwPath hwPath,
  required bool isHardware,
  bool zeroCopy = false,
}) => CodecCapability(
  backendName: name,
  direction: q.direction,
  videoCodec: q.videoCodec,
  audioCodec: q.audioCodec,
  container: q.container,
  hwPath: hwPath,
  isHardware: isHardware,
  zeroCopy: zeroCopy,
  acceptedInputs: q.direction == CodecDirection.encode && q.isVideo
      ? const {FrameSourceKind.cpu}
      : const {},
);

// "ffmpeg-like": software-only for everything.
List<CodecCapability> _swCaps(String name, CodecQuery q) =>
    [_cap(name, q, hwPath: HwPath.software, isHardware: false)];

// "first-party": a hardware, zero-copy path for video encode; software else.
List<CodecCapability> _fpCaps(String name, CodecQuery q) {
  if (q.isVideo && q.direction == CodecDirection.encode) {
    return [_cap(name, q, hwPath: HwPath.nvenc, isHardware: true, zeroCopy: true)];
  }
  return [_cap(name, q, hwPath: HwPath.software, isHardware: false)];
}

void main() {
  // 'ff' = high priority, software-only. 'fp' = low priority, HW/zero-copy.
  void registerPair() {
    MiniAVToolsPlatform.instance.register(_CapBackend('ff', 100, _swCaps));
    MiniAVToolsPlatform.instance.register(_CapBackend('fp', 1, _fpCaps));
  }

  setUp(() {
    MiniAVToolsPlatform.instance.unregisterByName('ff');
    MiniAVToolsPlatform.instance.unregisterByName('fp');
  });

  const encCfg = EncoderConfig(
    codec: VideoCodec.h264,
    width: 64,
    height: 64,
    bitrateBps: 100000,
  );
  const audDecCfg = AudioDecoderConfig(codec: AudioCodec.opus);
  const audEncCfg = AudioEncoderConfig(
    codec: AudioCodec.opus,
    sampleRate: 48000,
    channels: 2,
    bitrateBps: 96000,
  );
  final muxCfg = MuxerConfig(
    container: Container.mp4,
    output: MuxerOutput.bytes(),
    tracks: const [],
  );
  final demuxCfg = DemuxerConfig(
    container: Container.mp4,
    input: DemuxerInput.bytes(Uint8List(0)),
  );

  group('createEncoder is negotiated', () {
    test('a HW/zero-copy cap out-ranks a higher-priority software cap', () async {
      registerPair();
      final enc = await MiniAVTools.createEncoder(encCfg); // hwAccel=preferred
      expect(enc.backendName, 'fp',
          reason: 'fp (pri 1) HW+zero-copy beats ff (pri 100) software');
      expect(enc.capability?.isHardware, isTrue);
      expect(enc.isZeroCopy, isTrue);
      await enc.close();
    });

    test('requireZeroCopy drops the non-zero-copy backend', () async {
      registerPair();
      final enc = await MiniAVTools.createEncoder(
        encCfg,
        hwPreference: const HwPreference(requireZeroCopy: true),
      );
      expect(enc.backendName, 'fp');
      await enc.close();

      // With only the software backend left, requireZeroCopy has no candidate.
      MiniAVToolsPlatform.instance.unregisterByName('fp');
      expect(
        () => MiniAVTools.createEncoder(
          encCfg,
          hwPreference: const HwPreference(requireZeroCopy: true),
        ),
        throwsA(isA<NoBackendForCodecException>()),
      );
    });

    test('excluded skips the named backend', () async {
      registerPair();
      final enc = await MiniAVTools.createEncoder(
        encCfg,
        preference: BackendPreference.excluded({'fp'}),
      );
      expect(enc.backendName, 'ff'); // fp excluded → software ff
      await enc.close();
    });

    test(
      'generic base-probe HW cap preserves the caller hwAccel (recorder-safety)',
      () async {
        // A backend using the DEFAULT base probe emits a generic HwPath.hardware
        // cap. The facade must open it with the ORIGINAL hwAccel — NOT force
        // `required` — so the backend's own HW→SW fallback and hwAccel-matched
        // options are preserved (the recorder relies on this).
        final rec = _RecordingBaseBackend();
        MiniAVToolsPlatform.instance.register(rec);
        addTearDown(
          () => MiniAVToolsPlatform.instance.unregisterByName('rec'),
        );

        final enc = await MiniAVTools.createEncoder(
          encCfg, // hwAccel defaults to preferred
        );
        expect(enc.backendName, 'rec');
        expect(
          rec.lastHwAccel,
          HwAccelPreference.preferred,
          reason: 'generic HW cap must NOT be forced to required',
        );
        await enc.close();
      },
    );
  });

  group('audio factories are negotiated', () {
    test('createAudioDecoder: default prefers higher priority; excluded flips',
        () async {
      registerPair();
      final d1 = await MiniAVTools.createAudioDecoder(audDecCfg);
      expect(d1.backendName, 'ff'); // both software → priority tie-break
      expect(d1.capability, isNotNull);
      await d1.close();

      final d2 = await MiniAVTools.createAudioDecoder(
        audDecCfg,
        preference: BackendPreference.excluded({'ff'}),
      );
      expect(d2.backendName, 'fp');
      expect(d2.capability?.backendName, 'fp');
      await d2.close();
    });

    test('createAudioEncoder honors excluded + attaches capability', () async {
      registerPair();
      final e = await MiniAVTools.createAudioEncoder(
        audEncCfg,
        preference: BackendPreference.excluded({'ff'}),
      );
      expect(e.backendName, 'fp');
      expect(e.capability?.audioCodec, AudioCodec.opus);
      await e.close();
    });
  });

  group('container factories are negotiated', () {
    test('createMuxer honors excluded + attaches a container capability',
        () async {
      registerPair();
      final m = await MiniAVTools.createMuxer(
        muxCfg,
        preference: BackendPreference.excluded({'ff'}),
      );
      expect(m.backendName, 'fp');
      expect(m.capability?.container, Container.mp4);
      expect(m.capability?.direction, CodecDirection.mux);
      await m.close();
    });

    test('createDemuxer (known container) honors excluded', () async {
      registerPair();
      final d = await MiniAVTools.createDemuxer(
        demuxCfg,
        preference: BackendPreference.excluded({'ff'}),
      );
      expect(d.backendName, 'fp');
      expect(d.capability?.direction, CodecDirection.demux);
      await d.close();
    });
  });
}
