/// AV1 partition-tree walker for intra-only KEY_FRAME tile groups.
///
/// Recursively emits the AV1 partition syntax down to BLOCK_4X4 leaves so
/// that every leaf can carry an independently-coded TX_4X4 residual. This
/// is the only way to use the existing TX_4X4 CDFs (the only ones we have
/// transcribed from libaom) on a real residual: TX size for intra blocks is
/// fully determined by block size, so getting TX_4X4 requires BLOCK_4X4
/// luma blocks.
///
/// Per 64×64 superblock we emit:
///   * 1   × PARTITION_SPLIT at  64×64
///   * 4   × PARTITION_SPLIT at  32×32
///   * 16  × PARTITION_SPLIT at  16×16
///   * 64  × PARTITION_SPLIT at   8×8
///   * 256 × BLOCK_4X4 luma leaves (implicit, no partition symbol)
///   * 64  × BLOCK_4X4 chroma blocks (one per 8×8 luma region, 4:2:0)
///
/// `aboveCtx` / `leftCtx` bitmasks track which block sizes have been split
/// at each mi position, exactly mirroring libaom's
/// `above_partition_context` / `left_partition_context`.
///
/// The leaf callback ([LeafEmitter]) is invoked once per BLOCK_4X4 luma
/// position. It receives the 4×4 (mi_row, mi_col) along with a flag that
/// is `true` when the leaf is the chroma reference for its 8×8 super
/// (bottom-right sub-block of every PARTITION_SPLIT-from-8×8 pair).
library;

import 'dart:typed_data';

import 'av1_bool_writer.dart';
import 'av1_default_cdfs.dart';

/// 4×4 mi-units. Each "mi" is 4 luma samples.
const int kMiSize = 4;

/// PARTITION enum symbol indices (libaom `PARTITION_TYPE`).
const int kPartitionNone = 0;
const int kPartitionSplit = 3;

/// Block-size-log2 in mi units (mi_size_wide_log2 in libaom).
/// We only use square block sizes 4, 8, 16, 32, 64 → bsl 0..4.
int _bsl(int sizePx) {
  switch (sizePx) {
    case 4:
      return 0;
    case 8:
      return 1;
    case 16:
      return 2;
    case 32:
      return 3;
    case 64:
      return 4;
    default:
      throw ArgumentError('unsupported block size $sizePx');
  }
}

/// Partition CDF context index in `defaultPartitionCdf` (20 entries total).
/// Matches libaom `partition_plane_context`:
///   (bsl - 1) * 4 + left*2 + above   for bsl in [1..5]
int _partitionCtx(int bsizePx, int above, int left) {
  final bsl = _bsl(bsizePx);
  assert(bsl >= 1, 'partition syntax only emitted for bsize ≥ 8');
  return (bsl - 1) * 4 + left * 2 + above;
}

/// Probability mass (Q15) of the partition symbol `e` given an *inverse*
/// partition CDF (`cdf[i] = 32768 - cumulative`, matching libaom AOM_ICDF
/// storage and our `_cdf` helper).  Mirrors libaom `cdf_element_prob`.
int _massGt(List<int> cdf, int e) => (e > 0 ? cdf[e - 1] : 32768) - cdf[e];

/// Clamp a gathered Q15 probability into the open range writeBool accepts.
int _clampProb(int p) => p < 1 ? 1 : (p > 32767 ? 32767 : p);

/// `split_or_horz` probability that the partition is SPLIT (vs PARTITION_H),
/// used in the `have_h_split` branch (right half in-frame, bottom off-frame).
/// Exact port of dav1d `gather_top_partition_prob` (src/env.h): the gathered
/// mass is the set of partitions whose top row is split vertically, i.e.
/// V + SPLIT + HORZ_A(T_TOP) + VERT_A(T_LEFT) + VERT_B(T_RIGHT) + V4.
/// Only valid for 16/32/64 partition CDFs (10 symbols); never reached at
/// BLOCK_8X8 because mi dimensions are always even.
int _gatherTopPartitionProb(List<int> cdf) => _clampProb(
  _massGt(cdf, 2) + // PARTITION_VERT
      _massGt(cdf, 3) + // PARTITION_SPLIT
      _massGt(cdf, 4) + // PARTITION_T_TOP_SPLIT (HORZ_A)
      _massGt(cdf, 6) + // PARTITION_T_LEFT_SPLIT (VERT_A)
      _massGt(cdf, 7) + // PARTITION_T_RIGHT_SPLIT (VERT_B)
      _massGt(cdf, 9), // PARTITION_VERT_4 (bsize < 128 always here)
);

/// `split_or_vert` probability that the partition is SPLIT (vs PARTITION_V),
/// used in the `have_v_split` branch (bottom half in-frame, right off-frame).
/// Exact port of dav1d `gather_left_partition_prob` (src/env.h): the gathered
/// mass is the set of partitions whose left column is split horizontally, i.e.
/// H + SPLIT + HORZ_A(T_TOP) + HORZ_B(T_BOTTOM) + VERT_A(T_LEFT) + H4.
int _gatherLeftPartitionProb(List<int> cdf) => _clampProb(
  _massGt(cdf, 1) + // PARTITION_HORZ
      _massGt(cdf, 3) + // PARTITION_SPLIT
      _massGt(cdf, 4) + // PARTITION_T_TOP_SPLIT (HORZ_A)
      _massGt(cdf, 5) + // PARTITION_T_BOTTOM_SPLIT (HORZ_B)
      _massGt(cdf, 6) + // PARTITION_T_LEFT_SPLIT (VERT_A)
      _massGt(cdf, 8), // PARTITION_HORZ_4
);

/// Mutable per-tile state for partition walking.
class PartitionContext {
  PartitionContext(int miCols, int miRowsInTile)
    : aboveCtx = Uint8List(miCols),
      leftCtx = Uint8List(miRowsInTile);

  /// One byte per mi column. Bit `bsl` is set when an `8<<bsl`-wide block
  /// covering this column has been split.
  final Uint8List aboveCtx;

  /// One byte per mi row (within the current tile).
  final Uint8List leftCtx;

  /// Mark `[miCol .. miCol+miW)` × `[miRow .. miRow+miH)` with bit `bsl`
  /// to record that this region was SPLIT at block-size `8<<bsl`.
  /// The bit is cleared again when we descend below that size, which we
  /// emulate here by always setting (we only ever emit SPLIT in this
  /// walker).
  void markSplit(int miRow, int miCol, int miW, int miH, int bsl) {
    final bit = 1 << bsl;
    for (var c = miCol; c < miCol + miW; c++) {
      aboveCtx[c] = (aboveCtx[c] | bit) & 0xff;
    }
    for (var r = miRow; r < miRow + miH; r++) {
      leftCtx[r] = (leftCtx[r] | bit) & 0xff;
    }
  }
}

/// Skip-context tracker (above/left) for `skip_txfm` syntax. Per-mi
/// granularity because we emit skip at the 4×4 leaf.
class SkipContext {
  SkipContext(int miCols, int miRowsInTile)
    : aboveSkip = Uint8List(miCols),
      leftSkip = Uint8List(miRowsInTile);

  final Uint8List aboveSkip;
  final Uint8List leftSkip;

  int ctxAt(int miRow, int miCol) => aboveSkip[miCol] + leftSkip[miRow];

  void set(int miRow, int miCol, int miW, int miH, int v) {
    for (var c = miCol; c < miCol + miW; c++) {
      aboveSkip[c] = v;
    }
    for (var r = miRow; r < miRow + miH; r++) {
      leftSkip[r] = v;
    }
  }
}

/// Y-mode neighbour tracker. We only ever emit DC_PRED (mode index 0),
/// so the tracker just keeps the previous mode at the boundary so other
/// leaves get ctx (0,0). The CDF uses 5×5 grouped contexts (intra-mode
/// group lookup) but for DC_PRED everywhere the group index is also 0.
class YModeContext {
  YModeContext(int miCols, int miRowsInTile)
    : aboveMode = Uint8List(miCols),
      leftMode = Uint8List(miRowsInTile);

  final Uint8List aboveMode;
  final Uint8List leftMode;

  /// Intra-mode group: 0 for DC_PRED (which is what we always emit), so
  /// the returned ctx is always (0, 0).
  static const int dcGroup = 0;
}

/// Leaf callback: invoked once per BLOCK_4X4 luma leaf in raster order.
typedef LeafEmitter =
    void Function(Av1BoolWriter w, int miRow, int miCol, bool hasChromaRef);

/// Walk the partition quad-tree under a single 64×64 superblock at
/// (`sbMiRow`, `sbMiCol`) and emit the AV1 partition syntax down to
/// BLOCK_4X4 leaves. The provided [leafEmitter] is invoked for every leaf
/// in z-order.
///
/// `miRows` / `miCols` are the *true* frame dimensions in mi units, rounded
/// up to a multiple of 8 luma samples (i.e. `((dim + 7) >> 3) << 1`, always
/// even) — matching dav1d's `f->bw` / `f->bh`. Superblocks that straddle
/// the bottom/right frame edge emit partial partition syntax
/// (`split_or_horz` / `split_or_vert` bools) and skip out-of-frame children,
/// exactly as dav1d's `decode_sb` expects.
///
/// Returns the number of partition syntax elements (symbols + bools) emitted
/// for this superblock.
///
/// `hasChromaRef` per leaf is true exactly for the bottom-right 4×4
/// luma sub-block within each PARTITION_SPLIT-from-8×8 quad (4:2:0).
int walkSuperblock({
  required Av1BoolWriter w,
  required PartitionContext partCtx,
  required int sbMiRow,
  required int sbMiCol,
  required int miRows,
  required int miCols,
  required LeafEmitter leafEmitter,
}) {
  return _splitBlock(
    w: w,
    partCtx: partCtx,
    miRow: sbMiRow,
    miCol: sbMiCol,
    bsizePx: 64,
    miRows: miRows,
    miCols: miCols,
    leafEmitter: leafEmitter,
  );
}

/// Returns the number of partition syntax elements emitted at/under this
/// block.
int _splitBlock({
  required Av1BoolWriter w,
  required PartitionContext partCtx,
  required int miRow,
  required int miCol,
  required int bsizePx,
  required int miRows,
  required int miCols,
  required LeafEmitter leafEmitter,
}) {
  if (bsizePx == 4) {
    // BLOCK_4X4 leaf — no partition symbol, no further recursion.
    leafEmitter(w, miRow, miCol, /*hasChromaRef=*/ false);
    return 0;
  }

  final bsl = _bsl(bsizePx);
  final miSize = bsizePx ~/ kMiSize;
  final halfMi = miSize ~/ 2; // == bsizePx / 8 (hsz in dav1d)
  final halfPx = bsizePx ~/ 2;

  // dav1d decode_sb: have_h_split = bw > bx + hsz (right half in-frame);
  //                  have_v_split = bh > by + hsz (bottom half in-frame).
  final haveH = miCols > miCol + halfMi;
  final haveV = miRows > miRow + halfMi;

  final above = (partCtx.aboveCtx[miCol] >> bsl) & 1;
  final left = (partCtx.leftCtx[miRow] >> bsl) & 1;
  final ctx = _partitionCtx(bsizePx, above, left);
  final cdf = defaultPartitionCdf[ctx];

  var symbols = 0;
  if (!haveH && !haveV) {
    // Both right and bottom off-frame → forced split, no syntax element.
  } else if (haveH && haveV) {
    // Fully in-frame → full partition symbol (always PARTITION_SPLIT).
    w.writeSymbol(kPartitionSplit, cdf);
    symbols = 1;
  } else if (haveH) {
    // Bottom off-frame → split_or_horz bool; 1 == PARTITION_SPLIT.
    w.writeBool(1, _gatherTopPartitionProb(cdf));
    symbols = 1;
  } else {
    // Right off-frame → split_or_vert bool; 1 == PARTITION_SPLIT.
    w.writeBool(1, _gatherLeftPartitionProb(cdf));
    symbols = 1;
  }

  // Update context: mark this 8<<bsl region as split. Off-frame columns /
  // rows past the true grid are never read, so the (coded-sized) arrays
  // stay consistent with what the decoder computes for in-frame blocks.
  partCtx.markSplit(miRow, miCol, miSize, miSize, bsl);

  if (bsizePx == 8) {
    // BLOCK_8X8 PARTITION_SPLIT → 4 BLOCK_4X4 luma leaves. mi dimensions
    // are always even, so an 8×8 reached here is always fully in-frame
    // (have_h_split && have_v_split). The bottom-right sub-block carries
    // the chroma_ref for the whole 8×8 region (single 4×4 chroma in 4:2:0).
    leafEmitter(w, miRow + 0, miCol + 0, false);
    leafEmitter(w, miRow + 0, miCol + 1, false);
    leafEmitter(w, miRow + 1, miCol + 0, false);
    leafEmitter(w, miRow + 1, miCol + 1, true);
    return symbols;
  }

  // Recurse only into children whose top-left mi is inside the true grid
  // (z-order: TL, TR, BL, BR), mirroring dav1d's child recursion.
  symbols += _splitBlock(
    w: w,
    partCtx: partCtx,
    miRow: miRow,
    miCol: miCol,
    bsizePx: halfPx,
    miRows: miRows,
    miCols: miCols,
    leafEmitter: leafEmitter,
  );
  if (miCol + halfMi < miCols) {
    symbols += _splitBlock(
      w: w,
      partCtx: partCtx,
      miRow: miRow,
      miCol: miCol + halfMi,
      bsizePx: halfPx,
      miRows: miRows,
      miCols: miCols,
      leafEmitter: leafEmitter,
    );
  }
  if (miRow + halfMi < miRows) {
    symbols += _splitBlock(
      w: w,
      partCtx: partCtx,
      miRow: miRow + halfMi,
      miCol: miCol,
      bsizePx: halfPx,
      miRows: miRows,
      miCols: miCols,
      leafEmitter: leafEmitter,
    );
  }
  if (miRow + halfMi < miRows && miCol + halfMi < miCols) {
    symbols += _splitBlock(
      w: w,
      partCtx: partCtx,
      miRow: miRow + halfMi,
      miCol: miCol + halfMi,
      bsizePx: halfPx,
      miRows: miRows,
      miCols: miCols,
      leafEmitter: leafEmitter,
    );
  }
  return symbols;
}
