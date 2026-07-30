/// Phase 1a AV1 GPU pipeline.
///
/// Stages:
///   Stage 1 GPU : RGBA float [H,W,4]  → planar YUV420 BT.709-limited float
///                 (Y plane + Cb plane + Cr plane in one buffer)
///   Stage 2 CPU : pack Temporal Unit bytes
///                 (TD OBU + SH OBU + placeholder Frame OBU).
///                 The YUV buffer is read back from the GPU and currently
///                 thrown away — Phase 2 will feed it into intra prediction,
///                 DCT/quantize, and the boolean coder.
///
/// The container output is decode-able as AV1 up to the Frame OBU header at
/// which point dav1d still rejects it (the Frame OBU body is empty pending
/// the frame_header / tile_group implementation in Phase 2).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:gpu_pipeline/gpu_pipeline.dart';
// ignore: implementation_imports
import 'package:gpu_pipeline/src/pipeline_ports.dart' show FlexibleInputPort;
import 'package:gpu_tensor/gpu_tensor.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:minigpu/minigpu.dart' show Buffer;
import 'package:minigpu_platform_interface/minigpu_platform_interface.dart'
    show BufferDataType;

import '../gpu_codec_pipeline.dart';
import 'av1_constants.dart';
import 'av1_frame_header.dart';
import 'av1_obu.dart';
import 'av1_sequence_header.dart';
import 'av1_intra_dct_stage.dart';
import 'av1_residual_tile_group.dart' as residual;
import 'av1_source_dc_stage.dart';
import 'av1_tile_group.dart';
import 'av1_yuv420_stage.dart';
import 'mp4/av1_mp4_muxer.dart' show buildAv1ConfigRecord;

/// Whether to use real residual coding (Phase 3b+) or the fast all-skip path.
/// Default `false` until libaom CDF tables and context functions are fully
/// ported and validated end-to-end with dav1d. Can be overridden per-instance.
// Phase 4 Stage 1 (full partition tree to BLOCK_4X4 leaves, all-skip leaves)
// is implemented in [av1_residual_tile_group.dart] and validated end-to-end
// against libdav1d at 64×64 and 256×192. It produces a structurally complete
// 4×4-leaf bitstream that decodes cleanly but carries no actual residuals
// (so the decoded output is the same uniform mid-gray as the legacy path,
// at roughly 660× the symbol count per superblock). Stage 2 (CPU pred-DCT-
// quant + libaom-accurate coefficient context coding) is not yet wired —
// flip this to true only when iterating on the coefficient coder.
const bool kUseResidualCoding = true;

/// base_q_idx for the full-AC coefficient coder. The qcat0 CDF tables
/// require base_q_idx ∈ [1,20]; 16 gives dc_q=20, ac_q=23 (dq_shift=0).
const int kBaseQIdx = 16;

class MinigpuAv1Pipeline extends GpuCodecPipeline {
  MinigpuAv1Pipeline({
    required EncoderConfig config,
    this.useResidualCoding = kUseResidualCoding,
  }) : super(config: config) {
    if (config.width <= 0 || config.height <= 0) {
      throw ArgumentError(
        'AV1 requires positive width/height; got '
        '${config.width}x${config.height}',
      );
    }
    // Coded dims: round up to the partition walker's superblock alignment
    // (64). Real-world feeds (1920×1080, 1280×720, 640×480, …) won't
    // satisfy this naturally, so we pad the RGBA upload and encode at the
    // padded size while advertising true display dims via render_size.
    _codedWidth = ((config.width + 63) >> 6) << 6;
    _codedHeight = ((config.height + 63) >> 6) << 6;
    _shResult = buildSequenceHeader(
      width: _codedWidth,
      height: _codedHeight,
      frameRateNumerator: config.frameRateNumerator,
      frameRateDenominator: config.frameRateDenominator,
    );
    _sequenceHeaderObu = encodeObu(
      type: ObuType.sequenceHeader,
      payload: _shResult.payload,
    );
    _av1cRecord = buildAv1ConfigRecord(
      seqProfile: _shResult.seqProfile,
      seqLevelIdx0: _shResult.seqLevelIdx0,
      seqTier0: _shResult.seqTier0,
      highBitDepth: _shResult.highBitDepth,
      twelveBit: _shResult.twelveBit,
      monochrome: _shResult.monochrome,
      chromaSubsamplingX: _shResult.chromaSubsamplingX,
      chromaSubsamplingY: _shResult.chromaSubsamplingY,
      chromaSamplePosition: _shResult.chromaSamplePosition,
      sequenceHeaderObu: _sequenceHeaderObu,
    );
    _layout = Yuv420Layout(_codedWidth, _codedHeight);

    // Resolve the effective base_q_idx from the requested quality. The qcat0
    // CDF tables (the only ones ported so far) support base_q_idx ∈ [1,20],
    // where 1 is the finest quantiser (best quality / most bits) and 20 is
    // the coarsest. The recorder maps its normalized 0..1 quality knob to a
    // CRF-style number in [1,51] (1 = best). Project that onto [1,20] so the
    // quality setting actually changes the output; fall back to [kBaseQIdx]
    // when no quality/CRF was requested.
    final crf = config.crfQuality;
    if (crf == null) {
      _baseQIdx = kBaseQIdx;
    } else {
      final c = crf.clamp(1, 51);
      _baseQIdx = (1 + ((c - 1) / 50.0) * 19).round().clamp(1, 20);
    }

    // Keyframe cadence. gopLength == 0 means "encoder default": we emit a
    // single leading KEY frame and code every subsequent frame as an inter
    // (P) frame referencing the previous reconstruction (infinite GOP). A
    // positive gopLength forces a periodic intra refresh every N frames,
    // which is friendlier for seeking / error recovery.
    _gopLength = config.gopLength > 0 ? config.gopLength : 0;
  }

  /// Effective base_q_idx for the AC coefficient coder, derived from
  /// [EncoderConfig.crfQuality] (clamped to the qcat0-supported [1,20]).
  late final int _baseQIdx;

  final bool useResidualCoding;

  /// Resolved keyframe interval (0 = single leading key, then infinite GOP).
  late final int _gopLength;

  // --- inter-frame (P-frame) encode state -------------------------------
  /// Number of frames the pack stage has processed (== adapter frame index).
  int _frameCounter = 0;

  /// Frame index of the most recent KEY frame (drives periodic intra
  /// refresh; reset on forced keyframes so the cadence restarts).
  int _lastKeyFrameIdx = 0;

  /// Set by [onKeyframeRequested]; forces the next frame to be a KEY frame.
  bool _forceKeyNext = false;

  /// Whether the most recently packed frame was a KEY frame (read back by
  /// [isKeyframe] so the muxer tags the packet correctly).
  bool _lastFrameWasKey = true;

  /// Previous frame's closed-loop reconstruction (coded dims), used as the
  /// single LAST_FRAME reference for the next inter frame. Null before the
  /// first frame is encoded.
  Uint8List? _refY;
  Uint8List? _refU;
  Uint8List? _refV;

  late final int _codedWidth;
  late final int _codedHeight;

  @override
  int get codedWidth => _codedWidth;
  @override
  int get codedHeight => _codedHeight;

  late final SequenceHeaderResult _shResult;
  late final Uint8List _sequenceHeaderObu;
  late final Uint8List _av1cRecord;
  late final Yuv420Layout _layout;

  /// Most recent quantised coefficient buffer produced by the GPU DCT+quant
  /// stage (residual path only). Layout matches [buildIntraDctQuantStage].
  Float32List? get lastQuantCoeffs => _lastQuantCoeffs;
  Float32List? _lastQuantCoeffs;

  /// Most recent YUV420 buffer produced by the GPU stage. Exposed so tests
  /// and dev tools can introspect intermediate GPU output without rerunning
  /// the pipeline. Cleared between frames.
  Float32List? get lastYuv420 => _lastYuv;
  Float32List? _lastYuv;

  /// Most recent GPU source-DC tensor (one f32 per 4×4 block; layout
  /// matches [buildSourceDcStage]). Snapshotted by the source-DC snapshot
  /// stage so the CPU pack stage can pass it to the residual encoder.
  Float32List? get lastSourceDcs => _lastSourceDcs;
  Float32List? _lastSourceDcs;

  /// Per-stage timing (ms) of the most recent encode — for benchmarks.
  double get lastResidualMs => _lastResidualMs;
  double _lastResidualMs = 0;
  double get lastBytesToFloatMs => _lastBytesToFloatMs;
  double _lastBytesToFloatMs = 0;
  double get lastPackTotalMs => _lastPackTotalMs;
  double _lastPackTotalMs = 0;

  /// YUV420 planar layout for this pipeline's resolution.
  Yuv420Layout get yuv420Layout => _layout;

  /// MP4 muxer reads this via `track.extraData`.
  @override
  CodecExtraData? get extraData =>
      CodecExtraData.video(VideoCodec.av1, _av1cRecord);

  @override
  bool isKeyframe(int frameIndex) => _lastFrameWasKey;

  @override
  void onKeyframeRequested() {
    _forceKeyNext = true;
  }

  /// AV1 reads pixels through a `array<u32>` binding with `unpack4x8unorm`,
  /// so the adapter uploads packed RGBA8 (one u32 per pixel) instead of the
  /// default f32-per-byte layout. This cuts the GPU upload to a quarter of
  /// its size and skips the per-pixel `toDouble()` loop — the dominant cost
  /// at 1080p before this optimisation (~30 ms / frame).
  @override
  bool get acceptsPackedRgba8 => true;

  /// Fast path: the all-skip baseline is a pure CPU bit-stream synthesis —
  /// the YUV420 / DCT / quant GPU stages produce nothing the packed TU
  /// actually consumes. Skip the GPU upload + dispatch + read-back entirely
  /// (saves ~60ms / frame on Windows/Dawn for the placeholder encoder).
  ///
  /// Only engaged when [useResidualCoding] is false. When residual coding
  /// is on we must run the GPU stages, so we return `null` and the adapter
  /// falls back to the normal pipeline path.
  @override
  Future<Uint8List?> encodeFast(int frameIndex) async {
    if (useResidualCoding) return null;
    return _buildAllSkipTemporalUnit();
  }

  /// GPU-buffer hot path: accept a caller-owned packed-RGBA8 GPU buffer and
  /// run the full AV1 encode pipeline on it without any CPU round-trip.
  ///
  /// [buf] must contain at least [_codedWidth]\u00d7[_codedHeight] packed `u32`
  /// RGBA8 values and must remain alive for the duration of this call.
  /// [Tensor.external] is used so that the Tensor wrapper does not attach a
  /// finalizer — the caller (e.g. [GpuScreenProcessor]) owns the buffer.
  @override
  Future<Uint8List?> runOneFrameFromGpuBuffer(
    Buffer buf,
    int width,
    int height,
  ) async {
    // Wrap the caller-owned buffer in a non-owning Tensor view.
    // Tensor.external skips the Finalizer that Tensor.fromBuffer would attach,
    // so the caller's buffer is NOT destroyed when this Tensor is GCd.
    final input = Tensor<Uint32List>.external(buf, [
      height,
      width,
    ], dataType: BufferDataType.uint32);
    return runOneFrameInternal(input);
  }

  // Cached TD OBU + all-skip TU bytes — invariant for the lifetime of the
  // encoder when running the baseline path.
  Uint8List? _cachedAllSkipTu;

  Uint8List _buildAllSkipTemporalUnit() {
    final cached = _cachedAllSkipTu;
    if (cached != null) return cached;

    final tdObu = encodeObu(
      type: ObuType.temporalDelimiter,
      payload: Uint8List(0),
    );
    final fh = buildKeyFrameHeader(
      frameWidth: config.width,
      frameHeight: config.height,
      codedWidth: _codedWidth,
      codedHeight: _codedHeight,
    );
    final skipTg = buildAllSkipTileGroup(
      frameWidth: _codedWidth,
      frameHeight: _codedHeight,
    );
    final frameBody = BytesBuilder(copy: false)
      ..add(fh.payload)
      ..add(skipTg.payload);
    final out = BytesBuilder(copy: false)
      ..add(tdObu)
      ..add(_sequenceHeaderObu)
      ..add(encodeObu(type: ObuType.frame, payload: frameBody.toBytes()));
    final bytes = out.toBytes();
    _cachedAllSkipTu = bytes;
    return bytes;
  }

  @override
  Future<Pipeline> buildPipeline() async {
    final p = Pipeline(id: 'minigpu_av1_${_codedWidth}x$_codedHeight');
    p.addStage(
      buildRgba8ToYuv420Bt709LimitedStage(
        width: _codedWidth,
        height: _codedHeight,
        srcWidth: config.width,
        srcHeight: config.height,
        packedU32: true,
      ),
    );
    // Stage 2 GPU: per-4×4-block source means for Y / U / V. Replaces the
    // per-block CPU `_sourceDc4x4` summation in the residual encoder.
    //
    // Only beneficial above ~0.5 MP: below that the GPU dispatch +
    // readback synchronisation costs more than the CPU summation it
    // replaces. Measured on Windows/Dawn: 1920×1088 ≈ −18%, 512×512
    // ≈ +20%. Threshold picked from the bench crossover.
    final useGpuSourceDc =
        useResidualCoding && _codedWidth * _codedHeight >= 512 * 1024;
    if (useGpuSourceDc) {
      p.addStage(buildSourceDcStage(width: _codedWidth, height: _codedHeight));
      p.addStage(_buildSourceDcSnapshotStage());
    }
    p.addStage(
      _buildPackTemporalUnitStage(
        // Empirically (Windows/Dawn), wiring the pack stage off the smaller
        // source-DC passthrough instead of the YUV plane regresses end-to-end
        // frame time by ~30 % at 1080p even though it removes a 3 MB
        // readback. Likely a pipeline scheduling artefact: the YUV-input
        // dependency lets the runtime overlap the YUV readback with the
        // source-DC compute, while the alternative serialises them.
        useDcPassthroughInput: false,
      ),
    );
    await p.start();
    return p;
  }

  // ---------------------------------------------------------------------------
  // CPU emit stage.
  //
  // Reads the planar YUV420 tensor (so the GPU stage actually executes and
  // we keep a handle to the data for inspection), then writes the Temporal
  // Unit bytes:
  //   * TD OBU (always)
  //   * SH OBU (on keyframes — Phase 1a = every frame)
  //   * Frame OBU placeholder (empty payload — invalid body, replaced in
  //     Phase 2 when the boolean coder + tile_group land)
  //
  // The YUV data is buffered onto [lastYuv420]. Pipeline-internal use of the
  // YUV tensor (intra prediction, DCT, quantize) is the next GPU stage to
  // be added; for now the buffer is materialised here purely to validate
  // the read-back path.
  // ---------------------------------------------------------------------------
  PipelineStage _buildPackTemporalUnitStage({
    bool useDcPassthroughInput = false,
  }) {
    final tdObu = encodeObu(
      type: ObuType.temporalDelimiter,
      payload: Uint8List(0),
    );

    final stageInputKey = useDcPassthroughInput
        ? 'av1_source_dcs_passthrough'
        : kYuv420Key;

    Future<Map<String, TypedData>> processor(
      Map<String, TypedData> inputs,
      Map<String, List<int>> ranks,
      Map<String, dynamic> parameters,
    ) async {
      final tProc = Stopwatch()..start();
      Float32List? yuv;
      if (!useDcPassthroughInput) {
        final yuvRaw = inputs[kYuv420Key];
        if (yuvRaw is! Float32List) {
          throw CodecRuntimeException(
            'minigpu',
            'av1 pack TU: expected Float32List on $kYuv420Key, got '
                '${yuvRaw.runtimeType}',
          );
        }
        yuv = yuvRaw;
        _lastYuv = yuvRaw;
      }

      // ---- Decide frame type (KEY vs INTER) for this frame --------------
      final frameIdx = _frameCounter;
      final hasRef = _refY != null && _refU != null && _refV != null;
      // An inter frame needs: residual coding on, a valid previous
      // reconstruction to reference, and source pixels for this frame.
      final canInter = useResidualCoding && hasRef && yuv != null;
      final periodicRefresh =
          _gopLength > 0 && (frameIdx - _lastKeyFrameIdx) >= _gopLength;
      final isKey =
          frameIdx == 0 || _forceKeyNext || periodicRefresh || !canInter;
      _forceKeyNext = false;
      _lastFrameWasKey = isKey;

      residual.TileGroupResult tg;
      final BytesBuilder frameBody = BytesBuilder(copy: false);
      final tEnc = Stopwatch()..start();
      if (!useResidualCoding) {
        // All-skip fallback (KEY only — no reference reconstruction).
        final fh = buildKeyFrameHeader(
          frameWidth: config.width,
          frameHeight: config.height,
          codedWidth: _codedWidth,
          codedHeight: _codedHeight,
          baseQIdx: _baseQIdx,
        );
        final skipTg = buildAllSkipTileGroup(
          frameWidth: _codedWidth,
          frameHeight: _codedHeight,
        );
        tg = residual.TileGroupResult(
          payload: skipTg.payload,
          symbolsEmitted: skipTg.symbolsEmitted,
        );
        frameBody
          ..add(fh.payload)
          ..add(tg.payload);
      } else if (isKey) {
        final fh = buildKeyFrameHeader(
          frameWidth: config.width,
          frameHeight: config.height,
          codedWidth: _codedWidth,
          codedHeight: _codedHeight,
          baseQIdx: _baseQIdx,
        );
        tg = residual.buildResidualTileGroup(
          quantCoeffs: null,
          yuv420: yuv,
          frameWidth: _codedWidth,
          frameHeight: _codedHeight,
          useCoefficients: true,
          baseQIdx: _baseQIdx,
          sourceDcs: _lastSourceDcs,
          trueFrameWidth: config.width,
          trueFrameHeight: config.height,
        );
        frameBody
          ..add(fh.payload)
          ..add(tg.payload);
      } else {
        // Inter (P) frame: residual against the previous reconstruction.
        final fh = buildInterFrameHeader(
          frameWidth: config.width,
          frameHeight: config.height,
          codedWidth: _codedWidth,
          codedHeight: _codedHeight,
          baseQIdx: _baseQIdx,
          refreshFrameFlags: 0x01,
          refIdx: 0,
        );
        tg = residual.buildResidualTileGroup(
          quantCoeffs: null,
          yuv420: yuv,
          frameWidth: _codedWidth,
          frameHeight: _codedHeight,
          useCoefficients: true,
          baseQIdx: _baseQIdx,
          sourceDcs: _lastSourceDcs,
          trueFrameWidth: config.width,
          trueFrameHeight: config.height,
          interFrame: true,
          interResidual: true,
          referenceY: _refY,
          referenceU: _refU,
          referenceV: _refV,
        );
        frameBody
          ..add(fh.payload)
          ..add(tg.payload);
      }
      tEnc.stop();
      _lastResidualMs = tEnc.elapsedMicroseconds / 1000.0;

      // Update reference state from this frame's closed-loop reconstruction
      // so the next inter frame can reference it.
      if (tg.reconY != null && tg.reconU != null && tg.reconV != null) {
        _refY = tg.reconY;
        _refU = tg.reconU;
        _refV = tg.reconV;
      }
      if (isKey) {
        _lastKeyFrameIdx = frameIdx;
      }
      _frameCounter++;

      final out = BytesBuilder(copy: false);
      out.add(tdObu);
      // Sequence header is only carried on KEY temporal units; inter TUs
      // rely on the SH already delivered (in the av1C record + key frame).
      if (isKey) {
        out.add(_sequenceHeaderObu);
      }
      out.add(encodeObu(type: ObuType.frame, payload: frameBody.toBytes()));
      final bytes = out.toBytes();
      final tCopy = Stopwatch()..start();
      final asFloat = Float32List(bytes.length);
      for (var i = 0; i < bytes.length; i++) {
        asFloat[i] = bytes[i].toDouble();
      }
      tCopy.stop();
      tProc.stop();
      _lastBytesToFloatMs = tCopy.elapsedMicroseconds / 1000.0;
      _lastPackTotalMs = tProc.elapsedMicroseconds / 1000.0;
      return {kEncodedOutputKey: asFloat};
    }

    return StageBuilder('av1_pack_tu_phase3')
        .withFlexibleInput(stageInputKey)
        .withDynamicOutput(kEncodedOutputKey)
        .executeCPU(
          processor,
          inputKey: stageInputKey,
          outputKey: kEncodedOutputKey,
        )
        .build();
  }

  // Stage 2.5: snapshot the GPU source-DC tensor into [_lastSourceDcs] so
  // the CPU pack stage can hand it to the residual encoder. The stage is a
  // pass-through (output == input) — the residual encoder consumes the
  // snapshot from the field, not from the pipeline data flow.
  PipelineStage _buildSourceDcSnapshotStage() {
    const passthroughKey = 'av1_source_dcs_passthrough';
    Future<Map<String, TypedData>> processor(
      Map<String, TypedData> inputs,
      Map<String, List<int>> ranks,
      Map<String, dynamic> parameters,
    ) async {
      final raw = inputs[kSourceDcKey];
      if (raw is Float32List) {
        _lastSourceDcs = raw;
      }
      return {passthroughKey: raw ?? Float32List(0)};
    }

    return StageBuilder('av1_source_dc_snapshot')
        .withFlexibleInput(kSourceDcKey)
        .withDynamicOutput(passthroughKey)
        .executeCPU(
          processor,
          inputKey: kSourceDcKey,
          outputKey: passthroughKey,
        )
        .build();
  }
}

// Keep the unused-import suppressor happy until later phases bring the
// remaining shader-stage ports back into play.
// ignore: unused_element
const _portTypeSentinel = FlexibleInputPort;
