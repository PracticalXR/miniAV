/// Codec capability model — the spine of the negotiation layer.
///
/// A backend answers [MiniAVToolsBackend.probe] with the concrete
/// [CodecCapability]s it can offer for a query. The facade flattens every
/// backend's capabilities, filters by the caller's [HwPreference], ranks them
/// (hardware / zero-copy / score / init-cost), and opens them in order. The
/// chosen capability is attached to the returned encoder/decoder so consumers
/// (recorder/player) read `acceptedInputs` / `producedOutputs` / `zeroCopy` and
/// pick their frame path deterministically — no trial-and-error.
library;

import 'codec_types.dart';
import 'frame_source.dart';

/// The direction a capability runs in. Codec caps are [encode]/[decode];
/// container caps are [mux] (write) / [demux] (read).
enum CodecDirection { encode, decode, mux, demux }

/// The specific acceleration path a capability runs on. `software` is the CPU
/// path; `hardware` is a generic "some HW path" used only by the default
/// boolean-derived probe — backends that override [MiniAVToolsBackend.probe]
/// report the exact vendor path so the negotiator can order/exclude by it
/// (e.g. exclude `amf` on AMD, prefer `nvdec` over `d3d11va`).
enum HwPath {
  software,

  /// Generic hardware — emitted by the default probe when a backend only
  /// reports `hwAccel: true` without naming the vendor path.
  hardware,

  // Windows
  mediaFoundation, // IMFTransform (generic MFT, all vendors)
  d3d11va, // FFmpeg d3d11va decode
  // NVIDIA
  nvenc,
  nvdec,
  // Intel
  qsv,
  // AMD
  amf,
  // Apple
  videotoolbox,
  // Linux
  vaapi,
  // Android
  mediacodec,
  // Web
  webCodecs,
  mse,
  // GPU compute (minigpu / custom codecs)
  minigpu,
}

/// One concrete thing a backend can do: a codec, in one direction, via one
/// path, with a known I/O and cost profile. Immutable + cheap to enumerate.
class CodecCapability {
  const CodecCapability({
    required this.backendName,
    required this.direction,
    required this.hwPath,
    required this.isHardware,
    this.videoCodec,
    this.audioCodec,
    this.container,
    this.customName,
    this.zeroCopy = false,
    this.acceptedInputs = const {},
    this.producedOutputs = const {},
    this.maxWidth,
    this.maxHeight,
    this.score = 0,
    this.initCostHint = 0,
  })  : assert(videoCodec != null || audioCodec != null || container != null,
            'a capability is for a video codec, an audio codec, or a container'),
        assert(videoCodec != VideoCodec.custom || customName != null,
            'a VideoCodec.custom capability must carry its customName');

  final String backendName;
  final CodecDirection direction;

  /// Exactly one of these is non-null: a video codec, an audio codec, or —
  /// for [CodecDirection.mux]/[CodecDirection.demux] caps — a [container].
  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;
  final Container? container;

  /// Identity of a [VideoCodec.custom] capability (see the enum docs). The
  /// negotiator only matches a custom capability to a query with the SAME
  /// name. `null` for the built-in codecs.
  final String? customName;

  /// The acceleration path this capability runs on.
  final HwPath hwPath;

  /// True for any non-software path. Convenience over `hwPath != software`.
  final bool isHardware;

  /// True when the path keeps frames on the GPU end-to-end (no CPU readback):
  /// a decoder that produces a D3D11 texture the present device can import, or
  /// an encoder that consumes a GPU texture directly.
  final bool zeroCopy;

  /// ENCODE: the [FrameSource] kinds this path can consume directly.
  final Set<FrameSourceKind> acceptedInputs;

  /// DECODE: the output kinds this path produces (e.g. `{d3d11Texture}` for a
  /// GPU-resident decoder, `{cpu}` for a software one). Consumers read this to
  /// pick their present path without probing the returned frame.
  final Set<FrameSourceKind> producedOutputs;

  /// Optional resolution ceiling (encoder/decoder level limits).
  final int? maxWidth;
  final int? maxHeight;

  /// Tie-break quality/preference hint; higher = better. Backend-defined.
  final int score;

  /// Rough one-time open cost in ms (device/session creation). Cheaper wins
  /// ties so a trivial software fallback isn't chosen over an equal HW path
  /// but a heavy HW session isn't chosen over a cheaper equivalent.
  final int initCostHint;

  @override
  String toString() =>
      'CodecCapability($backendName ${direction.name} '
      '${videoCodec?.name ?? audioCodec?.name ?? container?.name} '
      'via ${hwPath.name}${zeroCopy ? ' zero-copy' : ''})';
}

/// What a consumer asks the negotiator for. Exactly one of [videoCodec] /
/// [audioCodec] / [container] is set.
class CodecQuery {
  const CodecQuery.video(this.videoCodec, this.direction, {this.customName})
      : audioCodec = null,
        container = null;
  const CodecQuery.audio(this.audioCodec, this.direction)
      : videoCodec = null,
        container = null,
        customName = null;

  /// A container mux/demux query. [direction] must be
  /// [CodecDirection.mux] or [CodecDirection.demux].
  const CodecQuery.container(this.container, this.direction)
      : videoCodec = null,
        audioCodec = null,
        customName = null;

  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;
  final Container? container;
  final CodecDirection direction;

  /// Set (only) when [videoCodec] is [VideoCodec.custom]: the custom codec's
  /// identity a capability's [CodecCapability.customName] must equal.
  final String? customName;

  bool get isVideo => videoCodec != null;
  bool get isContainer => container != null;
}
