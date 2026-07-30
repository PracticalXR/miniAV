/// Abstract backend contract.
///
/// Each `miniav_tools_*` backend package implements [MiniAVToolsBackend] and
/// registers an instance with [MiniAVToolsPlatform.instance.register].
library;

import 'backend_context.dart';
import 'capability.dart';
import 'codec_types.dart';
import 'config.dart';
import 'frame_source.dart';
import 'platform_codec.dart';
import 'warmup.dart';

abstract class MiniAVToolsBackend {
  /// Human-readable backend name, e.g. `"ffmpeg"`, `"webcodecs"`, `"minigpu"`.
  String get name;

  /// Higher value = preferred when multiple backends support the same codec.
  /// Backends should default to 0 and let users override via
  /// [MiniAVToolsPlatform.setBackendPriority].
  int get priority;

  // --- Capability queries ----------------------------------------------------

  bool supportsEncode(VideoCodec codec, {bool hwAccel = false});
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false});
  bool supportsAudioEncode(AudioCodec codec);
  bool supportsAudioDecode(AudioCodec codec);
  bool supportsMux(Container container);
  bool supportsDemux(Container container);

  /// Which [FrameSource] variants this backend can consume directly (without
  /// the facade falling back to CPU readback).
  Set<FrameSourceKind> get acceptedFrameSources;

  // --- Factories -------------------------------------------------------------
  // Return `null` if this backend cannot satisfy the request — the facade
  // will try the next backend by priority.
  //
  // The optional [context] carries cross-backend resources (e.g. a shared
  // GPU device) that the caller has already initialised. Backends that do
  // not recognise anything in the context MUST behave exactly as if it were
  // null — contexts are purely additive opt-ins.

  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  });
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  });
  Future<PlatformMuxer?> createMuxer(MuxerConfig config);
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config);

  /// Construct an audio encoder. Default implementation returns `null` —
  /// backends without audio support don't need to override.
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) async => null;

  /// Construct an audio decoder. Default implementation returns `null` —
  /// backends without audio support don't need to override.
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) async => null;

  // --- Capability negotiation -----------------------------------------------

  /// Enumerate the concrete [CodecCapability]s this backend offers for [query].
  ///
  /// The facade calls this on every backend, flattens the results, filters by
  /// the caller's [HwPreference], ranks (hardware → zero-copy → score →
  /// init-cost), and opens in order — attaching the chosen capability to the
  /// returned encoder/decoder.
  ///
  /// The default implementation derives capabilities from the boolean
  /// `supports*` queries above, so existing backends participate immediately
  /// (a `software` capability, plus a generic `hardware` one when `hwAccel`
  /// works). Backends override this to report the *specific* path
  /// ([HwPath.d3d11va], [HwPath.nvdec], …), `producedOutputs`
  /// (`{d3d11Texture}` for GPU-resident decode), and `zeroCopy` — which is what
  /// lets the negotiator route and lets consumers pick their frame path
  /// without probing the returned frame.
  Future<List<CodecCapability>> probe(CodecQuery query) async {
    final caps = <CodecCapability>[];
    final dir = query.direction;

    // Container mux/demux: a single software capability when supported.
    // Containers are never hardware-accelerated; a backend with an out-of-band
    // container path still just reports software here.
    if (query.isContainer) {
      final ct = query.container!;
      final ok = dir == CodecDirection.mux
          ? supportsMux(ct)
          : supportsDemux(ct);
      if (ok) {
        caps.add(CodecCapability(
          backendName: name,
          direction: dir,
          container: ct,
          hwPath: HwPath.software,
          isHardware: false,
        ));
      }
      return caps;
    }

    final isEnc = dir == CodecDirection.encode;

    if (query.isVideo) {
      final vc = query.videoCodec!;
      // Custom codecs are matched by NAME, which the boolean supports* queries
      // can't express — only backends that override probe() (the app backend
      // that owns the name) may claim them. The default probe stays silent so
      // a backend whose supports* maps sloppily return true can't hijack a
      // custom codec it has never heard of.
      if (vc == VideoCodec.custom) return caps;
      final swOk = isEnc ? supportsEncode(vc) : supportsDecode(vc);
      if (swOk) {
        caps.add(CodecCapability(
          backendName: name,
          direction: dir,
          videoCodec: vc,
          hwPath: HwPath.software,
          isHardware: false,
          acceptedInputs: isEnc ? acceptedFrameSources : const {},
          producedOutputs: isEnc ? const {} : const {FrameSourceKind.cpu},
        ));
      }
      final hwOk =
          isEnc ? supportsEncode(vc, hwAccel: true) : supportsDecode(vc, hwAccel: true);
      if (hwOk) {
        caps.add(CodecCapability(
          backendName: name,
          direction: dir,
          videoCodec: vc,
          hwPath: HwPath.hardware,
          isHardware: true,
          score: 10,
          acceptedInputs: isEnc ? acceptedFrameSources : const {},
          // The default probe can't know GPU-residency; a backend that keeps
          // frames on the GPU overrides this with the specific output kind.
          producedOutputs: isEnc ? const {} : const {FrameSourceKind.cpu},
        ));
      }
    } else {
      final ac = query.audioCodec!;
      final ok = isEnc ? supportsAudioEncode(ac) : supportsAudioDecode(ac);
      if (ok) {
        caps.add(CodecCapability(
          backendName: name,
          direction: dir,
          audioCodec: ac,
          hwPath: HwPath.software,
          isHardware: false,
        ));
      }
    }
    return caps;
  }

  // --- Warmup ---------------------------------------------------------------

  /// Perform any slow early initialisation required by this backend.
  ///
  /// Common uses:
  /// - Downloading FFmpeg shared libraries on first run.
  /// - Fetching a remote ML model.
  /// - Warming up a JIT or shader cache.
  ///
  /// Emit [WarmupProgress] events as work proceeds. The stream **must**
  /// complete (fire `onDone`) when all work is done or has failed.
  /// Failures should be emitted as [WarmupProgress] events with a non-null
  /// [WarmupProgress.error] — the stream itself must not error.
  ///
  /// The default implementation returns an empty stream (no warmup needed).
  /// Backends that need no early initialisation do not need to override this.
  Stream<WarmupProgress> warmup() => const Stream.empty();
}
