// P0.3: the negotiator memoizes probe() results per (backend, query) and
// invalidates the cache on any registry change (register / unregister /
// setBackendPriority). A counting fake backend proves probe() runs once across
// repeated createDecoder calls, and re-runs after the registry mutates.

import 'package:miniav_tools/miniav_tools.dart';
import 'package:test/test.dart';

class _CountingBackend extends MiniAVToolsBackend {
  @override
  final String name;
  @override
  final int priority;
  int probeCalls = 0;

  _CountingBackend(this.name, this.priority);

  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async {
    probeCalls++;
    return [
      CodecCapability(
        backendName: name,
        direction: query.direction,
        videoCodec: query.videoCodec,
        audioCodec: query.audioCodec,
        container: query.container,
        hwPath: HwPath.software,
        isHardware: false,
      ),
    ];
  }

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => true;
  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => true;
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
  Future<PlatformEncoder?> createEncoder(EncoderConfig c,
          {BackendContext? context}) async =>
      null;
  @override
  Future<PlatformDecoder?> createDecoder(DecoderConfig c,
          {BackendContext? context}) async =>
      null; // returns null so createDecoder throws NoBackend — probe still ran
  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig c) async => null;
  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig c) async => null;
}

void main() {
  late _CountingBackend backend;

  setUp(() {
    MiniAVToolsPlatform.instance.unregisterByName('counter');
    MiniAVToolsPlatform.instance.unregisterByName('other');
    backend = _CountingBackend('counter', 10);
    MiniAVToolsPlatform.instance.register(backend);
  });

  Future<void> negotiateH264() async {
    try {
      await MiniAVTools.createDecoder(const DecoderConfig(codec: VideoCodec.h264));
    } on NoBackendForCodecException {
      // expected: the fake createDecoder returns null. We only care that the
      // negotiator probed.
    }
  }

  test('probe() is memoized across repeated negotiations', () async {
    await negotiateH264();
    await negotiateH264();
    await negotiateH264();
    expect(backend.probeCalls, 1, reason: 'cached after the first probe');
  });

  test('different query keys probe separately', () async {
    await negotiateH264(); // h264 decode
    try {
      await MiniAVTools.createDecoder(const DecoderConfig(codec: VideoCodec.hevc));
    } on NoBackendForCodecException {/* ignore */}
    expect(backend.probeCalls, 2, reason: 'h264 and hevc are distinct keys');
    await negotiateH264(); // h264 again → still cached
    expect(backend.probeCalls, 2);
  });

  test('registry changes invalidate the cache', () async {
    await negotiateH264();
    expect(backend.probeCalls, 1);

    // register a new backend → cache cleared → next negotiation re-probes.
    MiniAVToolsPlatform.instance.register(_CountingBackend('other', 1));
    await negotiateH264();
    expect(backend.probeCalls, 2);

    // setBackendPriority → cache cleared → re-probe.
    MiniAVToolsPlatform.instance.setBackendPriority('counter', 5);
    await negotiateH264();
    expect(backend.probeCalls, 3);

    // unregister → cache cleared (and 'counter' still present re-probes).
    MiniAVToolsPlatform.instance.unregisterByName('other');
    await negotiateH264();
    expect(backend.probeCalls, 4);
  });
}
