/// Real residual tile group encoder (Phase 4).
///
/// Emits an AV1 OBU_FRAME tile-group payload that fully partitions every
/// 64×64 superblock down to BLOCK_4X4 luma leaves so that residuals can be
/// carried in TX_4X4 coefficient blocks (the only TX size we have CDFs for).
///
/// The implementation is a two-stage rollout:
///
///   * **Stage 1** (current default of [buildResidualTileGroup]): the
///     partition tree is fully emitted and every leaf carries `skip_txfm=1`
///     plus DC_PRED for luma + chroma. No coefficient blocks are coded.
///     This is structurally identical to the legacy all-skip baseline (a
///     uniform mid-gray decoded output) but exercises the full leaf-walking
///     framework. dav1d must accept it before we layer coefficient coding
///     on top.
///
///   * **Stage 2** (gated by [useCoefficients]): per-leaf forward
///     prediction + DCT + quantise + entropy-coded coefficients with
///     libaom-accurate context functions, and a CPU raster-scan
///     reconstruction loop so the encoder and decoder stay in sync on
///     intra prediction neighbours.
///
/// `quantCoeffs` from the GPU stage is no longer consumed — the GPU output
/// is informational only, and Stage 2 recomputes everything on CPU to
/// maintain proper raster-order reconstruction.
library;

import 'dart:typed_data';

import 'av1_bool_writer.dart';
import 'av1_default_cdfs.dart';
import 'av1_partition_walker.dart';
import 'av1_yuv420_stage.dart' show Yuv420Layout;

/// Public output type — kept ABI-compatible with the previous sketch so the
/// pipeline glue does not need to change.
class TileGroupResult {
  final Uint8List payload;
  final int symbolsEmitted;

  /// Closed-loop reconstructed planes (decoder-domain Uint8). Populated when
  /// [buildResidualTileGroup] runs with `useCoefficients: true`; these become
  /// the reference for the next inter frame and drive bit-exact validation.
  final Uint8List? reconY;
  final Uint8List? reconU;
  final Uint8List? reconV;

  const TileGroupResult({
    required this.payload,
    required this.symbolsEmitted,
    this.reconY,
    this.reconU,
    this.reconV,
  });
}

/// Encode a tile group for a single intra-only KEY_FRAME using the
/// partition-walker framework.
///
/// [yuv420] is the planar BT.709-limited YUV420 buffer that the GPU stage
/// produces; it is only consulted when [useCoefficients] is true.
///
/// [sourceDcs] is the optional GPU-produced per-4×4-block source-DC tensor
/// (one f32 per block, layout [numLumaY][numU][numV] — see
/// av1_source_dc_stage.dart). When supplied, the per-block source mean is
/// taken from this buffer instead of being recomputed on the CPU.
///
/// [quantCoeffs] is currently unused (kept for the call-site signature; the
/// CPU recon loop recomputes its own quantised coefficients).
TileGroupResult buildResidualTileGroup({
  required Float32List? quantCoeffs,
  required Float32List? yuv420,
  required int frameWidth,
  required int frameHeight,
  bool useCoefficients = false,
  int baseQIdx = 32,
  Float32List? sourceDcs,
  int? trueFrameWidth,
  int? trueFrameHeight,
  bool interFrame = false,
  bool interResidual = false,
  Uint8List? referenceY,
  Uint8List? referenceU,
  Uint8List? referenceV,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) {
    throw ArgumentError('frame dims must be positive');
  }
  if ((frameWidth & 63) != 0 || (frameHeight & 63) != 0) {
    throw ArgumentError(
      'tile group requires multiple-of-64 frame dims; got '
      '${frameWidth}x$frameHeight',
    );
  }
  if (useCoefficients && yuv420 == null) {
    // Iter 2 just emits hardcoded DC=+1 coefs and ignores yuv420; the
    // real Stage 2 will need it for prediction.  For now, allow null.
    // (Will be re-tightened once we hook up real source-driven coefs.)
  }
  if (interResidual) {
    if (!interFrame) {
      throw ArgumentError('interResidual requires interFrame=true');
    }
    if (!useCoefficients) {
      throw ArgumentError('interResidual requires useCoefficients=true');
    }
    if (referenceY == null || referenceU == null || referenceV == null) {
      throw ArgumentError('interResidual requires reference planes');
    }
  }
  final layout = Yuv420Layout(frameWidth, frameHeight);
  // quantCoeffs is reserved for a future transform-domain input path.
  // ignore: unused_local_variable
  final _qc = quantCoeffs;

  final miCols = frameWidth >> 2; // 4 luma samples per mi
  final miRows = frameHeight >> 2;
  final sbCols = frameWidth >> 6;
  final sbRows = frameHeight >> 6;

  // True display dimensions in mi units, rounded up to a multiple of 8 luma
  // samples (= dav1d's f->bw / f->bh = ((dim + 7) >> 3) << 1, always even).
  // These drive the partition-tree boundary handling so that superblocks
  // straddling the bottom/right frame edge emit partial partition syntax,
  // matching dav1d's decode_sb. When the true dims equal the coded dims
  // (mult-of-64 input) these collapse to the full miCols/miRows.
  final trueW = trueFrameWidth ?? frameWidth;
  final trueH = trueFrameHeight ?? frameHeight;
  final trueMiCols = ((trueW + 7) >> 3) << 1;
  final trueMiRows = ((trueH + 7) >> 3) << 1;

  // Chroma 4×4 transform grid (4:2:0): each chroma tx covers 2×2 mi.
  final chCols = miCols >> 1;
  final chRows = miRows >> 1;

  // ---------------------------------------------------------------------
  // Stage 3 (source-driven, closed-loop CPU recon).
  //
  // For every 4×4 luma block (and every 4×4 chroma block when chroma-ref):
  //   1. Compute DC_PRED from already-reconstructed neighbours (Uint8List
  //      recon plane).  Missing neighbours default to 128 per AV1 spec.
  //   2. Compute target DC = mean of source pixels in the block.
  //   3. residual_dc = target_dc - pred_dc.
  //   4. level = clamp(round(residual_dc / DC_STEP), -MAX, +MAX).
  //   5. If level == 0 → emit txb_skip=1, no coefs; reconstructed block =
  //      uniform pred.  Otherwise emit txb_skip=0 + tx_type=DCT_DCT (luma
  //      only) + eob_pt=0 + coeff_base_eob(|level|−1) + dc_sign(level<0),
  //      and update recon to uniform (pred + level * DC_STEP) clipped.
  //
  // MAX is 2 in this iteration so we only need coeff_base_eob sym 0
  // (level 1) and sym 1 (level 2); no br_tok extensions yet.  This will
  // look like a heavily quantised low-pass version of the source — visible
  // structure but coarse contrast.  A follow-up iteration widens MAX.
  // ---------------------------------------------------------------------

  // Per-pixel value that a single coef level produces in the decoder's
  // inverse-DCT_DCT-4×4 + dequant pipeline at baseQIdx=32.  Empirically
  // (from iter4): level=+1 gave delta=+1 vs pred.  We treat this as
  // exactly 1 for both luma and chroma.  Closed-loop recon uses the same
  // constant.
  // Per-level pixel delta produced by dav1d's TX_4X4 DCT_DCT inverse on a
  // DC-only block at qcat=1 (baseQIdx=32, dq_dc=34, dq_shift=0).
  // dav1d's inv_dct4_1d_internal_c (src/itx_1d.c) does, for DC-only input:
  //   t = ((in0 + in2) * 181 + 128) >> 8   // in2 = 0
  //   t = ((t  + 0  ) * 181 + 128) >> 8    // column pass
  // and the final per-pixel add uses `(t + 8) >> 4`.
  // The integer rounding makes the per-level delta non-linear (level 1 → 1,
  // level 2 → 2, etc.).  We precompute the exact table and use it both for
  // selecting the best level and for keeping the encoder's CPU recon in
  // perfect sync with the decoder.  Same table applies to luma and chroma
  // because we do not signal any DeltaQ for U/V (DC qindex = baseQIdx).
  // Quantiser step sizes (8-bit AV1 dc/ac qlookup, low range idx 0..20).
  // The qcat0 CDF tables require baseQIdx ∈ [1,20]; dq_shift = 0 for TX_4X4.
  const dcQLookup = [
    4, 8, 8, 9, 10, 11, 12, 12, 13, 14, 15, //
    16, 17, 18, 19, 19, 20, 21, 22, 23, 24,
  ];
  const acQLookup = [
    4, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, //
    18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
  ];
  if (useCoefficients && (baseQIdx < 1 || baseQIdx > 20)) {
    throw ArgumentError(
      'qcat0 coefficient coding requires baseQIdx in [1,20]; got $baseQIdx',
    );
  }
  final dcQ = dcQLookup[baseQIdx.clamp(0, 20)];
  final acQ = acQLookup[baseQIdx.clamp(0, 20)];

  // dav1d default_scan_4x4 (src/scan.c) and the 2D low-frequency context
  // offset table (dav1d_lo_ctx_offsets[0], w == h).
  const scan4x4 = [0, 4, 1, 2, 5, 8, 12, 9, 6, 3, 7, 10, 13, 14, 11, 15];
  const loCtxOffsets = [
    [0, 1, 6, 6, 21],
    [1, 6, 6, 21, 21],
    [6, 6, 21, 21, 21],
    [6, 21, 21, 21, 21],
    [21, 21, 21, 21, 21],
  ];

  // Exact dav1d inv_dct4 1D butterfly (src/itx_1d.c), clipped to INT16.
  void invDct4(List<int> c) {
    final in0 = c[0], in1 = c[1], in2 = c[2], in3 = c[3];
    final t0 = ((in0 + in2) * 181 + 128) >> 8;
    final t1 = ((in0 - in2) * 181 + 128) >> 8;
    final t2 = (in1 * 1567 - in3 * 3784 + 2048) >> 12;
    final t3 = (in1 * 3784 + in3 * 1567 + 2048) >> 12;
    int clip(int v) => v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
    c[0] = clip(t0 + t3);
    c[1] = clip(t1 + t2);
    c[2] = clip(t1 - t2);
    c[3] = clip(t0 - t3);
  }

  // Float synthesis basis derived from the same butterfly. Used to project
  // residuals onto (near-)orthogonal DCT coefficients for level selection.
  List<double> floatInvDct4(List<double> c) {
    final t0 = (c[0] + c[2]) * 181 / 256;
    final t1 = (c[0] - c[2]) * 181 / 256;
    final t2 = (c[1] * 1567 - c[3] * 3784) / 4096;
    final t3 = (c[1] * 3784 + c[3] * 1567) / 4096;
    return [t0 + t3, t1 + t2, t1 - t2, t0 - t3];
  }

  final basis = List.generate(16, (n) {
    final cf = List<double>.filled(16, 0.0);
    cf[n] = 1.0;
    final tmp = List<double>.filled(16, 0.0);
    for (var y = 0; y < 4; y++) {
      final r = floatInvDct4([cf[y], cf[y + 4], cf[y + 8], cf[y + 12]]);
      for (var x = 0; x < 4; x++) {
        tmp[y * 4 + x] = r[x];
      }
    }
    final out = List<double>.filled(16, 0.0);
    for (var x = 0; x < 4; x++) {
      final r = floatInvDct4([tmp[x], tmp[x + 4], tmp[x + 8], tmp[x + 12]]);
      for (var k = 0; k < 4; k++) {
        out[x + k * 4] = r[k];
      }
    }
    for (var i = 0; i < 16; i++) {
      out[i] /= 16.0;
    }
    return out;
  });
  final basisNorm = List.generate(16, (n) {
    var s = 0.0;
    for (var i = 0; i < 16; i++) {
      s += basis[n][i] * basis[n][i];
    }
    return s;
  });

  // Forward level selection: project the 4×4 residual (source − DC_PRED)
  // onto each DCT basis vector and scalar-quantise. Writes signed levels in
  // rc layout (rc = x*4 + y) into [out] (all 16 entries overwritten).
  //
  // [_selR] is a reused scratch buffer: this runs once per 4×4 block (~130k
  // blocks per 1080p luma plane), so allocating fresh lists here would create
  // enormous GC churn and starve the encode isolate, causing dropped frames.
  final _selR = List<double>.filled(16, 0.0);
  void selectLevels(
    Uint8List src,
    int stride,
    int py,
    int px,
    int pred,
    List<int> out,
  ) {
    final r = _selR;
    for (var ry = 0; ry < 4; ry++) {
      final base = (py + ry) * stride + px;
      for (var rx = 0; rx < 4; rx++) {
        r[ry * 4 + rx] = (src[base + rx] - pred).toDouble();
      }
    }
    // Fast path: a uniform residual block projects to DC only — every AC
    // basis vector is zero-mean, so dot_n = r0 * sum(basis[n]) = 0 exactly.
    // Screen capture is dominated by flat/solid regions, so this skips the
    // 240 AC multiplies for the common case while producing identical levels.
    final r0 = r[0];
    var uniform = true;
    for (var i = 1; i < 16; i++) {
      if (r[i] != r0) {
        uniform = false;
        break;
      }
    }
    if (uniform) {
      final b = basis[0];
      var dot = 0.0;
      for (var i = 0; i < 16; i++) {
        dot += r0 * b[i];
      }
      var lv = (dot / basisNorm[0] / dcQ).round();
      if (lv > 1638) lv = 1638;
      if (lv < -1638) lv = -1638;
      out[0] = lv;
      for (var n = 1; n < 16; n++) {
        out[n] = 0;
      }
      return;
    }
    for (var n = 0; n < 16; n++) {
      final b = basis[n];
      var dot = 0.0;
      for (var i = 0; i < 16; i++) {
        dot += r[i] * b[i];
      }
      final coeff = dot / basisNorm[n];
      final q = n == 0 ? dcQ : acQ;
      var lv = (coeff / q).round();
      if (lv > 1638) lv = 1638;
      if (lv < -1638) lv = -1638;
      out[n] = lv;
    }
  }

  // Highest scan index with a nonzero level (-1 → all-zero block).
  int lastScanIndex(List<int> levels) {
    for (var i = 15; i >= 0; i--) {
      if (levels[scan4x4[i]] != 0) return i;
    }
    return -1;
  }

  // Exact dav1d inverse reconstruction of a TX_4X4 DCT_DCT block. `eob` is
  // the highest scan index (>=0); eob==0 takes the DC-only fast path.
  //
  // [_reconCf]/[_reconTmp]/[_reconBuf] are reused per-block scratch buffers
  // (see selectLevels rationale). `cf` must be zero-cleared each call because
  // the AC loop only writes nonzero positions.
  final _reconCf = List<int>.filled(16, 0);
  final _reconTmp = List<int>.filled(16, 0);
  final _reconBuf = List<int>.filled(4, 0);
  void reconBlock(
    Uint8List plane,
    int stride,
    int py,
    int px,
    int pred,
    List<int> levels,
    int eob,
  ) {
    int clampPix(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    if (eob == 0) {
      final lv = levels[0];
      final neg = lv < 0;
      var dq = lv.abs() * dcQ;
      final cap = neg ? 32768 : 32767;
      if (dq > cap) dq = cap;
      final cf0 = neg ? -dq : dq;
      var dc = (cf0 * 181 + 128) >> 8;
      dc = (dc * 181 + 128 + 2048) >> 12;
      final pix = clampPix(pred + dc);
      for (var ry = 0; ry < 4; ry++) {
        final base = (py + ry) * stride + px;
        plane[base] = pix;
        plane[base + 1] = pix;
        plane[base + 2] = pix;
        plane[base + 3] = pix;
      }
      return;
    }
    final cf = _reconCf;
    cf.fillRange(0, 16, 0);
    for (var rc = 0; rc < 16; rc++) {
      final lv = levels[rc];
      if (lv == 0) continue;
      final neg = lv < 0;
      var dq = lv.abs() * (rc == 0 ? dcQ : acQ);
      final cap = neg ? 32768 : 32767;
      if (dq > cap) dq = cap;
      cf[rc] = neg ? -dq : dq;
    }
    final tmp = _reconTmp;
    final buf = _reconBuf;
    for (var y = 0; y < 4; y++) {
      buf[0] = cf[y];
      buf[1] = cf[y + 4];
      buf[2] = cf[y + 8];
      buf[3] = cf[y + 12];
      invDct4(buf);
      tmp[y * 4] = buf[0];
      tmp[y * 4 + 1] = buf[1];
      tmp[y * 4 + 2] = buf[2];
      tmp[y * 4 + 3] = buf[3];
    }
    for (var x = 0; x < 4; x++) {
      buf[0] = tmp[x];
      buf[1] = tmp[x + 4];
      buf[2] = tmp[x + 8];
      buf[3] = tmp[x + 12];
      invDct4(buf);
      tmp[x] = buf[0];
      tmp[x + 4] = buf[1];
      tmp[x + 8] = buf[2];
      tmp[x + 12] = buf[3];
    }
    for (var ry = 0; ry < 4; ry++) {
      final base = (py + ry) * stride + px;
      for (var rx = 0; rx < 4; rx++) {
        plane[base + rx] = clampPix(pred + ((tmp[ry * 4 + rx] + 8) >> 4));
      }
    }
  }

  // ------------------------------------------------------------------
  // Inter-residual (Approach C′) variants: prediction is the co-located
  // reference 4×4 block (MV = 0), so the residual is per-pixel
  // (source − reference) rather than against a scalar DC predictor. The
  // transform math is identical to the intra path; only the predictor
  // sampling differs.
  // ------------------------------------------------------------------

  // Forward level selection against a per-pixel reference block.
  void selectLevelsRef(
    Uint8List src,
    Uint8List ref,
    int stride,
    int py,
    int px,
    List<int> out,
  ) {
    final r = _selR;
    for (var ry = 0; ry < 4; ry++) {
      final base = (py + ry) * stride + px;
      for (var rx = 0; rx < 4; rx++) {
        r[ry * 4 + rx] = (src[base + rx] - ref[base + rx]).toDouble();
      }
    }
    for (var n = 0; n < 16; n++) {
      final b = basis[n];
      var dot = 0.0;
      for (var i = 0; i < 16; i++) {
        dot += r[i] * b[i];
      }
      final coeff = dot / basisNorm[n];
      final q = n == 0 ? dcQ : acQ;
      var lv = (coeff / q).round();
      if (lv > 1638) lv = 1638;
      if (lv < -1638) lv = -1638;
      out[n] = lv;
    }
  }

  // Inverse reconstruction = reference block + inverse-transformed residual.
  void reconBlockRef(
    Uint8List plane,
    Uint8List ref,
    int stride,
    int py,
    int px,
    List<int> levels,
    int eob,
  ) {
    int clampPix(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    final cf = _reconCf;
    cf.fillRange(0, 16, 0);
    for (var rc = 0; rc < 16; rc++) {
      final lv = levels[rc];
      if (lv == 0) continue;
      final neg = lv < 0;
      var dq = lv.abs() * (rc == 0 ? dcQ : acQ);
      final cap = neg ? 32768 : 32767;
      if (dq > cap) dq = cap;
      cf[rc] = neg ? -dq : dq;
    }
    final tmp = _reconTmp;
    final buf = _reconBuf;
    for (var y = 0; y < 4; y++) {
      buf[0] = cf[y];
      buf[1] = cf[y + 4];
      buf[2] = cf[y + 8];
      buf[3] = cf[y + 12];
      invDct4(buf);
      tmp[y * 4] = buf[0];
      tmp[y * 4 + 1] = buf[1];
      tmp[y * 4 + 2] = buf[2];
      tmp[y * 4 + 3] = buf[3];
    }
    for (var x = 0; x < 4; x++) {
      buf[0] = tmp[x];
      buf[1] = tmp[x + 4];
      buf[2] = tmp[x + 8];
      buf[3] = tmp[x + 12];
      invDct4(buf);
      tmp[x] = buf[0];
      tmp[x + 4] = buf[1];
      tmp[x + 8] = buf[2];
      tmp[x + 12] = buf[3];
    }
    for (var ry = 0; ry < 4; ry++) {
      final base = (py + ry) * stride + px;
      for (var rx = 0; rx < 4; rx++) {
        plane[base + rx] = clampPix(
          ref[base + rx] + ((tmp[ry * 4 + rx] + 8) >> 4),
        );
      }
    }
  }

  // Copy a co-located 4×4 reference block into the recon plane (inter skip).
  void _copyBlock4x4(Uint8List dst, Uint8List ref, int stride, int py, int px) {
    for (var r = 0; r < 4; r++) {
      final base = (py + r) * stride + px;
      dst[base] = ref[base];
      dst[base + 1] = ref[base + 1];
      dst[base + 2] = ref[base + 2];
      dst[base + 3] = ref[base + 3];
    }
  }

  // Reconstructed planes — Uint8 to match decoder output domain.
  final reconY = Uint8List(frameWidth * frameHeight);
  final reconU = Uint8List((frameWidth >> 1) * (frameHeight >> 1));
  final reconV = Uint8List((frameWidth >> 1) * (frameHeight >> 1));
  // Source planes, snapshot as Uint8 (rounded float→int). Full-AC coding
  // needs every source pixel (not just per-block means), so we always
  // materialise them when coefficient coding is enabled.
  final needSrc = useCoefficients && yuv420 != null;
  final srcY = needSrc ? Uint8List(reconY.length) : Uint8List(0);
  final srcU = needSrc ? Uint8List(reconU.length) : Uint8List(0);
  final srcV = needSrc ? Uint8List(reconV.length) : Uint8List(0);
  if (needSrc) {
    int clampU8(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
    final uOff = layout.uOffset;
    final vOff = layout.vOffset;
    for (var i = 0; i < srcY.length; i++) {
      srcY[i] = clampU8(yuv420![i]);
    }
    for (var i = 0; i < srcU.length; i++) {
      srcU[i] = clampU8(yuv420![uOff + i]);
      srcV[i] = clampU8(yuv420[vOff + i]);
    }
  }

  // DC_PRED from already-reconstructed neighbour samples.
  // `recon` is the destination/source plane (we read above row + left col).
  // `py`, `px` are top-left pixel coordinates of the 4×4 block.
  int _dcPredict4x4(Uint8List recon, int stride, int py, int px) {
    final hasT = py > 0;
    final hasL = px > 0;
    if (!hasT && !hasL) return 128;
    int sum = 0;
    if (hasT) {
      final row = (py - 1) * stride + px;
      sum += recon[row] + recon[row + 1] + recon[row + 2] + recon[row + 3];
    }
    if (hasL) {
      final col = py * stride + (px - 1);
      sum +=
          recon[col] +
          recon[col + stride] +
          recon[col + 2 * stride] +
          recon[col + 3 * stride];
    }
    if (hasT && hasL) return (sum + 4) >> 3; // avg of 8 samples
    return (sum + 2) >> 2; // avg of 4 samples
  }

  // Mean of 4×4 source samples (rounded).

  // Fill a 4×4 region of `dst` with uniform `value` (clipped to 0..255).
  void _fillBlock4x4(Uint8List dst, int stride, int py, int px, int value) {
    final v = value < 0 ? 0 : (value > 255 ? 255 : value);
    for (var r = 0; r < 4; r++) {
      final base = (py + r) * stride + px;
      dst[base] = v;
      dst[base + 1] = v;
      dst[base + 2] = v;
      dst[base + 3] = v;
    }
  }

  final w = Av1BoolWriter();
  final partCtx = PartitionContext(miCols, miRows);
  final skipCtx = SkipContext(miCols, miRows);

  // Per-plane cf_ctx neighbour bytes (above[col] / left[row]) for
  // `get_dc_sign_ctx`.  Encoding (dav1d):
  //   0x40              = skip block
  //   cul_level | 0x80  = positive dc (bit 7 set)
  //   cul_level         = negative dc (bit 7 clear, cul_level in 0..63)
  // The dc_sign_ctx for TX_4X4 = (s!=0)+(s>0) where
  //   s = (a[0]>>6) + (l[0]>>6) - 2.
  // dav1d reset_context() memsets these to 0x40 (skip marker) at tile start.
  // For the very first block at (0,0), both neighbours are 0x40 →
  // dc_sign_ctx = ((0x40>>6)+(0x40>>6)-2 = 0) → ctx=0.
  final yCfCtxAbove = Uint8List(miCols)..fillRange(0, miCols, 0x40);
  final yCfCtxLeft = Uint8List(miRows)..fillRange(0, miRows, 0x40);
  final uCfCtxAbove = Uint8List(chCols)..fillRange(0, chCols, 0x40);
  final uCfCtxLeft = Uint8List(chRows)..fillRange(0, chRows, 0x40);
  final vCfCtxAbove = Uint8List(chCols)..fillRange(0, chCols, 0x40);
  final vCfCtxLeft = Uint8List(chRows)..fillRange(0, chRows, 0x40);

  int _dcSignCtx(int aboveCfCtx, int leftCfCtx) {
    final s = (aboveCfCtx >> 6) + (leftCfCtx >> 6) - 2;
    return (s != 0 ? 1 : 0) + (s > 0 ? 1 : 0);
  }

  var symbolsEmitted = 0;

  // Reused per-block signed coefficient buffers (luma/U/V). All three coexist
  // within one leafEmitter call, so they are distinct, but they are reused
  // across the ~130k block iterations to avoid per-block allocation.
  final _yLevels = List<int>.filled(16, 0);
  final _uLevels = List<int>.filled(16, 0);
  final _vLevels = List<int>.filled(16, 0);

  // Exp-golomb encoder matching dav1d `read_golomb`:
  //   decoder:  val = 1; while(!equi() && len<32) len++; while(len--) val=(val<<1)+equi(); return val-1;
  // To encode `v ≥ 0`:
  //   val = v + 1; len = floor(log2(val))   (i.e. val.bitLength - 1)
  //   emit `len` zero bits, then a `1` bit (which doubles as val's leading 1),
  //   then emit val's lower `len` bits MSB-first.
  // Bits are 50/50 equiprobable, matching `dav1d_msac_decode_bool_equi`.
  void _writeGolomb(int v) {
    assert(v >= 0);
    final val = v + 1;
    final len = val.bitLength - 1;
    for (var i = 0; i < len; i++) {
      w.writeLiteralBit(0);
    }
    w.writeLiteralBit(1);
    for (var i = len - 1; i >= 0; i--) {
      w.writeLiteralBit((val >> i) & 1);
    }
    // Each equi bit is one symbol for accounting purposes.
    symbolsEmitted += 2 * len + 1;
  }

  // hi_tok (BR) emission for a level >= 3 (inverse of
  // dav1d_msac_decode_hi_tok). Up to 4 symbols ∈ {0..3}; a `3` means
  // "continue". tok saturates at 15 (an exp-golomb suffix carries the rest).
  void _writeHiTok(int level, List<int> brCdf) {
    final t = level >= 15 ? 15 : level;
    var rem = t - 3; // 0..12
    for (var k = 0; k < 4; k++) {
      final s = rem < 3 ? rem : 3;
      w.writeSymbol(s, brCdf);
      symbolsEmitted++;
      if (s < 3) break;
      rem -= 3;
    }
  }

  // Emit a full TX_4X4 DCT_DCT coefficient block (DC + AC) mirroring dav1d
  // decode_coefs exactly. `levels` are signed in rc layout; `eob` is the
  // highest scan index (>=0). `plane` is 0=luma, 1=chroma. Returns the
  // cf_ctx neighbour byte to store for both above/left.
  final _emitLev = Uint8List(24);
  int _emitCoefTokens(int plane, List<int> levels, int eob, int dcSignCtx) {
    final lev = _emitLev; // dav1d levels[] scratch, stride = 4
    lev.fillRange(0, 24, 0);
    final eobBaseTok = coefEobBaseTokTx4Qcat0[plane];
    final baseTok = coefBaseTokTx4Qcat0[plane];
    final brTok = coefBrTokTx4Qcat0[plane];

    // eob_bin (+ hi bit + low bits).
    final eobBin = eob.bitLength;
    w.writeSymbol(eobBin, coefEobBin16Tx4Qcat0[plane]);
    symbolsEmitted++;
    if (eobBin > 1) {
      final hi = (eob >> (eobBin - 2)) & 1;
      w.writeSymbol(hi, coefEobHiBitTx4Qcat0[plane][eobBin]);
      symbolsEmitted++;
      for (var b = eobBin - 3; b >= 0; b--) {
        w.writeLiteralBit((eob >> b) & 1);
        symbolsEmitted++;
      }
    }

    var cul = 0;
    if (eob > 0) {
      // EOB coefficient (scan[eob], always an AC coef).
      final rcE = scan4x4[eob];
      final absE = levels[rcE].abs();
      final ctxEob = 1 + (eob > 2 ? 1 : 0) + (eob > 4 ? 1 : 0);
      final eobTok = absE < 3 ? absE - 1 : 2;
      w.writeSymbol(eobTok, eobBaseTok[ctxEob]);
      symbolsEmitted++;
      if (eobTok == 2) {
        final xb = rcE >> 2, yb = rcE & 3;
        final brctx = ((xb | yb) > 1) ? 14 : 7;
        _writeHiTok(absE, brTok[brctx]);
        lev[rcE] = (absE >= 15 ? 15 : absE) + 192;
      } else {
        lev[rcE] = absE * 65;
      }
      cul += absE;

      // AC loop, descending scan index.
      for (var i = eob - 1; i >= 1; i--) {
        final rcI = scan4x4[i];
        final x = rcI >> 2, y = rcI & 3;
        var mag = lev[rcI + 1] + lev[rcI + 4];
        mag += lev[rcI + 5];
        final hiMag = mag;
        mag += lev[rcI + 2] + lev[rcI + 8];
        final ctx =
            loCtxOffsets[y < 4 ? y : 4][x < 4 ? x : 4] +
            (mag > 512 ? 4 : (mag + 64) >> 7);
        final absI = levels[rcI].abs();
        final tok = absI < 3 ? absI : 3;
        w.writeSymbol(tok, baseTok[ctx]);
        symbolsEmitted++;
        final yy = y | x;
        if (tok == 3) {
          final m2 = hiMag & 63;
          final brctx = (yy > 1 ? 14 : 7) + (m2 > 12 ? 6 : (m2 + 1) >> 1);
          _writeHiTok(absI, brTok[brctx]);
          lev[rcI] = (absI >= 15 ? 15 : absI) + 192;
        } else {
          lev[rcI] = tok * 65;
        }
        cul += absI;
      }

      // DC (rc = 0, 2D context 0).
      final absDc = levels[0].abs();
      final dcTok = absDc < 3 ? absDc : 3;
      w.writeSymbol(dcTok, baseTok[0]);
      symbolsEmitted++;
      if (dcTok == 3) {
        var mag = lev[1] + lev[4] + lev[5];
        mag &= 63;
        final brctx = mag > 12 ? 6 : (mag + 1) >> 1;
        _writeHiTok(absDc, brTok[brctx]);
      }
      cul += absDc;
    } else {
      // DC-only (eob == 0): only the DC coefficient is nonzero.
      final absDc = levels[0].abs();
      final tokBr = absDc < 3 ? absDc - 1 : 2;
      w.writeSymbol(tokBr, eobBaseTok[0]);
      symbolsEmitted++;
      if (tokBr == 2) {
        _writeHiTok(absDc, brTok[0]);
      }
      cul += absDc;
    }

    // Residual signs + golomb suffixes (DC first, then AC ascending scan).
    int dcSignLevel;
    final absDc = levels[0].abs();
    if (absDc == 0) {
      dcSignLevel = 0x40;
    } else {
      final neg = levels[0] < 0;
      w.writeSymbol(neg ? 1 : 0, defaultDcSignCdf[plane][dcSignCtx]);
      symbolsEmitted++;
      if (absDc >= 15) _writeGolomb(absDc - 15);
      dcSignLevel = neg ? 0x00 : 0x80;
    }
    for (var i = 1; i <= eob; i++) {
      final rcI = scan4x4[i];
      final absI = levels[rcI].abs();
      if (absI == 0) continue;
      w.writeLiteralBit(levels[rcI] < 0 ? 1 : 0);
      symbolsEmitted++;
      if (absI >= 15) _writeGolomb(absI - 15);
    }

    return (cul < 63 ? cul : 63) | dcSignLevel;
  }

  void leafEmitter(Av1BoolWriter w, int miRow, int miCol, bool hasChromaRef) {
    final pyL = miRow << 2;
    final pxL = miCol << 2;
    final chR = miRow >> 1;
    final chC = miCol >> 1;
    final uvStride = frameWidth >> 1;
    final pyC = chR << 2;
    final pxC = chC << 2;

    // -------- prediction + forward level selection (luma + chroma) --------
    var yPred = 128, uPred = 128, vPred = 128;
    List<int> yL = const [], uL = const [], vL = const [];
    var yEob = -1, uEob = -1, vEob = -1;
    if (useCoefficients) {
      if (interResidual) {
        // Prediction = co-located reference block (MV 0); residual is
        // per-pixel (source − reference). No scalar predictor.
        selectLevelsRef(srcY, referenceY!, frameWidth, pyL, pxL, _yLevels);
        yL = _yLevels;
        yEob = lastScanIndex(yL);
        if (hasChromaRef) {
          selectLevelsRef(srcU, referenceU!, uvStride, pyC, pxC, _uLevels);
          selectLevelsRef(srcV, referenceV!, uvStride, pyC, pxC, _vLevels);
          uL = _uLevels;
          vL = _vLevels;
          uEob = lastScanIndex(uL);
          vEob = lastScanIndex(vL);
        }
      } else {
        yPred = _dcPredict4x4(reconY, frameWidth, pyL, pxL);
        selectLevels(srcY, frameWidth, pyL, pxL, yPred, _yLevels);
        yL = _yLevels;
        yEob = lastScanIndex(yL);
        if (hasChromaRef) {
          uPred = _dcPredict4x4(reconU, uvStride, pyC, pxC);
          vPred = _dcPredict4x4(reconV, uvStride, pyC, pxC);
          selectLevels(srcU, uvStride, pyC, pxC, uPred, _uLevels);
          selectLevels(srcV, uvStride, pyC, pxC, vPred, _vLevels);
          uL = _uLevels;
          vL = _vLevels;
          uEob = lastScanIndex(uL);
          vEob = lastScanIndex(vL);
        }
      }
    }

    // -------- skip_txfm: 1 only if every per-plane block is all-zero ----
    final mbSkipCtx = skipCtx.ctxAt(miRow, miCol);
    final hasAnyCoef =
        useCoefficients &&
        (yEob >= 0 || (hasChromaRef && (uEob >= 0 || vEob >= 0)));
    final skipFlag = hasAnyCoef ? 0 : 1;
    w.writeSymbol(skipFlag, defaultSkipTxfmCdfs[mbSkipCtx]);
    symbolsEmitted++;

    // In an INTER frame an intra-coded block must first signal is_inter=0.
    // dav1d derives `b->intra = !msac_bool(m.intra[ctx])`, so an intra block
    // emits symbol value 0. The context (get_intra_ctx) for an all-intra
    // field is purely position-based: corner=0, single edge=2, interior=3.
    if (interResidual) {
      // Approach C′: every block is inter (single-ref LAST, GLOBALMV). The
      // field is uniformly inter so all neighbour contexts collapse to the
      // position-based forms validated in Phase 1.
      final haveTop = miRow > 0;
      final haveLeft = miCol > 0;
      // is_inter = 1 (intra ctx always 0 for an all-inter field).
      w.writeSymbol(1, defaultIntraInterCdf[0]);
      // single-reference tree → LAST_FRAME (three 0-bits).
      final refCtx = (haveTop || haveLeft) ? 2 : 1;
      w.writeSymbol(0, defaultSingleRefCdf[0][refCtx]); // p1
      w.writeSymbol(0, defaultSingleRefCdf[2][refCtx]); // p3
      w.writeSymbol(0, defaultSingleRefCdf[3][refCtx]); // p4
      // inter mode → GLOBALMV: new_mv=1 (not NEWMV) then global_mv=0.
      final nearest = (haveTop ? 1 : 0) + (haveLeft ? 1 : 0);
      final newMvCtx = nearest == 0 ? 0 : (nearest == 1 ? 3 : 5);
      w.writeSymbol(1, defaultNewMvCdf[newMvCtx]);
      w.writeSymbol(0, defaultGlobalMvCdf[0]);
      symbolsEmitted += 6;
    } else {
      if (interFrame) {
        final haveTop = miRow > 0;
        final haveLeft = miCol > 0;
        final intraCtx = haveLeft ? (haveTop ? 3 : 2) : (haveTop ? 2 : 0);
        w.writeSymbol(0, defaultIntraInterCdf[intraCtx]);
        symbolsEmitted++;
      }

      // Luma intra mode = DC_PRED (symbol 0). KEY frames use kf_y_mode (which
      // is conditioned on neighbour modes, always [0][0] for an all-DC field);
      // INTER-frame intra blocks use if_y_mode indexed by the block-size
      // group (0 for BLOCK_4X4).
      if (interFrame) {
        w.writeSymbol(0, defaultIfYModeCdf[0]);
      } else {
        w.writeSymbol(0, defaultKfYModeCdf[0][0]);
      }
      symbolsEmitted++;

      if (hasChromaRef) {
        w.writeSymbol(0, defaultUvModeCdfCflAllowed[0]);
        symbolsEmitted++;
      }
    }

    if (skipFlag == 0) {
      // ------ LUMA block (txb_skip ctx 0: BS_4X4 matches TX_4X4) ------
      if (yEob < 0) {
        w.writeSymbol(1, coefSkipTx4Qcat0[0]);
        symbolsEmitted++;
        if (useCoefficients) {
          if (interResidual) {
            _copyBlock4x4(reconY, referenceY!, frameWidth, pyL, pxL);
          } else {
            _fillBlock4x4(reconY, frameWidth, pyL, pxL, yPred);
          }
        }
        yCfCtxAbove[miCol] = 0x40;
        yCfCtxLeft[miRow] = 0x40;
      } else {
        w.writeSymbol(0, coefSkipTx4Qcat0[0]);
        // Luma tx_type = DCT_DCT. For intra blocks dav1d's reduced intra set
        // (Intra2) encodes DCT_DCT as sym=1 on txtp_intra2; for inter blocks
        // the reduced inter set (txtp_inter3) decodes idx then *txtp =
        // (idx-1)&IDTX, so DCT_DCT also needs the bool VALUE 1.
        w.writeSymbol(
          1,
          interResidual ? defaultTxtpInter3Tx4Cdf : defaultTxtpIntra2DcPredCdf,
        );
        symbolsEmitted += 2;
        final dcCtx = _dcSignCtx(yCfCtxAbove[miCol], yCfCtxLeft[miRow]);
        final cfByte = _emitCoefTokens(0, yL, yEob, dcCtx);
        if (interResidual) {
          reconBlockRef(reconY, referenceY!, frameWidth, pyL, pxL, yL, yEob);
        } else {
          reconBlock(reconY, frameWidth, pyL, pxL, yPred, yL, yEob);
        }
        yCfCtxAbove[miCol] = cfByte;
        yCfCtxLeft[miRow] = cfByte;
      }

      if (hasChromaRef) {
        // ------ U plane (txb_skip ctx = 7 + above + left) ------
        final uCtx =
            7 +
            (uCfCtxAbove[chC] != 0x40 ? 1 : 0) +
            (uCfCtxLeft[chR] != 0x40 ? 1 : 0);
        if (uEob < 0) {
          w.writeSymbol(1, coefSkipTx4Qcat0[uCtx]);
          symbolsEmitted++;
          if (useCoefficients) {
            if (interResidual) {
              _copyBlock4x4(reconU, referenceU!, uvStride, pyC, pxC);
            } else {
              _fillBlock4x4(reconU, uvStride, pyC, pxC, uPred);
            }
          }
          uCfCtxAbove[chC] = 0x40;
          uCfCtxLeft[chR] = 0x40;
        } else {
          w.writeSymbol(0, coefSkipTx4Qcat0[uCtx]);
          symbolsEmitted++;
          final dcCtx = _dcSignCtx(uCfCtxAbove[chC], uCfCtxLeft[chR]);
          final cfByte = _emitCoefTokens(1, uL, uEob, dcCtx);
          if (interResidual) {
            reconBlockRef(reconU, referenceU!, uvStride, pyC, pxC, uL, uEob);
          } else {
            reconBlock(reconU, uvStride, pyC, pxC, uPred, uL, uEob);
          }
          uCfCtxAbove[chC] = cfByte;
          uCfCtxLeft[chR] = cfByte;
        }

        // ------ V plane ------
        final vCtx =
            7 +
            (vCfCtxAbove[chC] != 0x40 ? 1 : 0) +
            (vCfCtxLeft[chR] != 0x40 ? 1 : 0);
        if (vEob < 0) {
          w.writeSymbol(1, coefSkipTx4Qcat0[vCtx]);
          symbolsEmitted++;
          if (useCoefficients) {
            if (interResidual) {
              _copyBlock4x4(reconV, referenceV!, uvStride, pyC, pxC);
            } else {
              _fillBlock4x4(reconV, uvStride, pyC, pxC, vPred);
            }
          }
          vCfCtxAbove[chC] = 0x40;
          vCfCtxLeft[chR] = 0x40;
        } else {
          w.writeSymbol(0, coefSkipTx4Qcat0[vCtx]);
          symbolsEmitted++;
          final dcCtx = _dcSignCtx(vCfCtxAbove[chC], vCfCtxLeft[chR]);
          final cfByte = _emitCoefTokens(1, vL, vEob, dcCtx);
          if (interResidual) {
            reconBlockRef(reconV, referenceV!, uvStride, pyC, pxC, vL, vEob);
          } else {
            reconBlock(reconV, uvStride, pyC, pxC, vPred, vL, vEob);
          }
          vCfCtxAbove[chC] = cfByte;
          vCfCtxLeft[chR] = cfByte;
        }
      }
    } else {
      // skip path — recon stays at prediction (uniform pred fill).
      // skip_txfm=1 means *all* per-plane txbs are all-zero, so set
      // every cf_ctx neighbour byte to the skip marker (0x40).
      yCfCtxAbove[miCol] = 0x40;
      yCfCtxLeft[miRow] = 0x40;
      if (hasChromaRef) {
        uCfCtxAbove[chC] = 0x40;
        uCfCtxLeft[chR] = 0x40;
        vCfCtxAbove[chC] = 0x40;
        vCfCtxLeft[chR] = 0x40;
      }
      if (useCoefficients) {
        if (interResidual) {
          // Inter skip: decoder copies the co-located reference (MV 0).
          _copyBlock4x4(reconY, referenceY!, frameWidth, pyL, pxL);
          if (hasChromaRef) {
            _copyBlock4x4(reconU, referenceU!, uvStride, pyC, pxC);
            _copyBlock4x4(reconV, referenceV!, uvStride, pyC, pxC);
          }
        } else {
          _fillBlock4x4(reconY, frameWidth, pyL, pxL, yPred);
          if (hasChromaRef) {
            _fillBlock4x4(reconU, uvStride, pyC, pxC, uPred);
            _fillBlock4x4(reconV, uvStride, pyC, pxC, vPred);
          }
        }
      }
    }

    skipCtx.set(miRow, miCol, 1, 1, skipFlag);
  }

  for (var sbR = 0; sbR < sbRows; sbR++) {
    for (var sbC = 0; sbC < sbCols; sbC++) {
      final sbMiRow = sbR * 16; // 64 px / 4 = 16 mi
      final sbMiCol = sbC * 16;

      // Partition symbols actually emitted depend on how much of this
      // superblock is in-frame (partial SBs at the bottom/right edge emit
      // fewer). walkSuperblock returns the exact count.
      symbolsEmitted += walkSuperblock(
        w: w,
        partCtx: partCtx,
        sbMiRow: sbMiRow,
        sbMiCol: sbMiCol,
        miRows: trueMiRows,
        miCols: trueMiCols,
        leafEmitter: leafEmitter,
      );
    }
  }

  return TileGroupResult(
    payload: w.finish(),
    symbolsEmitted: symbolsEmitted,
    reconY: useCoefficients ? reconY : null,
    reconU: useCoefficients ? reconU : null,
    reconV: useCoefficients ? reconV : null,
  );
}
