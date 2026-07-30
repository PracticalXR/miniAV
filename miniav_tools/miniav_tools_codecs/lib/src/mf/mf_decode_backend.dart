/// A dedicated decode-only backend for the Media Foundation hardware H.264/
/// HEVC → D3D11 NV12 path (see [MfD3d11Decoder]).
///
/// It exists separately from [FfmpegBackend] because it reports a *specific*
/// zero-copy capability (`hwPath: mediaFoundation`, `zeroCopy: true`,
/// `producedOutputs: {d3d11Texture}`) that the FFmpeg backend can't — the
/// facade negotiator ranks this above the FFmpeg software cap under
/// `preferred`/`required`, and falls back to FFmpeg SW for free if
/// [createDecoder] returns `null` (no hardware MFT / STA thread / device lost).
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';
import 'isolate_mf_decoder.dart';
import 'mf_d3d11_decoder.dart';

class MfDecodeBackend extends MiniAVToolsBackend {
  static const String backendName = 'mf_decode';

  /// Above [FfmpegBackend]'s default (50) so a rank tie prefers the specific
  /// hardware path — though the capability model (hardware → zero-copy) already
  /// makes it win under `preferred`.
  static const int defaultPriority = 60;

  static const _decodeCodecs = <VideoCodec>{VideoCodec.h264, VideoCodec.hevc};

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  // --- Capabilities (decode-only, hardware-only) ---------------------------

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) =>
      Platform.isWindows && hwAccel && _decodeCodecs.contains(codec);

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;

  @override
  bool supportsAudioDecode(AudioCodec codec) => false;

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  // --- Negotiation ----------------------------------------------------------

  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async {
    if (!Platform.isWindows) return const [];
    if (query.direction != CodecDirection.decode || !query.isVideo) {
      return const [];
    }
    final vc = query.videoCodec!;
    if (!_decodeCodecs.contains(vc)) return const [];

    // The codecs_native asset is always present (no FFmpeg gating), so this is
    // an honest check: does a hardware decoder MFT actually exist (→ D3D11
    // texture)? If the asset somehow can't load, report optimistically and let
    // createDecoder return null (→ facade falls back).
    try {
      final codec = vc == VideoCodec.hevc ? 1 : 0;
      if (!mfdecHasHardware(codec)) return const [];
    } catch (_) {
      // Asset not loadable here — stay optimistic; createDecoder gates.
    }

    return [
      CodecCapability(
        backendName: name,
        direction: CodecDirection.decode,
        videoCodec: vc,
        hwPath: HwPath.mediaFoundation,
        isHardware: true,
        zeroCopy: true,
        producedOutputs: const {FrameSourceKind.d3d11Texture},
        score: 20,
        initCostHint: 8,
      ),
    ];
  }

  // --- Factories ------------------------------------------------------------

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async {
    // Isolate-hosted by default: MF decode needs the COM MTA apartment, which
    // the Flutter UI isolate (STA) can't provide — the worker isolate's fresh
    // thread can. The worker relays the decoded NV12 shared handle (an NT
    // handle, valid cross-isolate) for a zero-copy import + present on the main
    // isolate. If the worker can't init HW MF decode it throws → the negotiator
    // falls back to the FFmpeg software decoder.
    //
    // Escape hatch (tests): backendOptions {'sw_isolate': '0'} runs the decoder
    // in-isolate (needs an MTA calling thread, e.g. `dart test`, not Flutter).
    if (config.backendOptions['sw_isolate'] == '0') {
      return MfD3d11Decoder.open(config);
    }
    try {
      return await IsolateMfDecoder.open(config);
    } on CodecInitException {
      return null; // no HW MF decode in the worker — fall back to SW.
    }
  }

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}
