/// Inter (P-frame) tile group encoder — Phase 1.
///
/// Emits an AV1 OBU_FRAME tile-group payload for an INTER_FRAME in which
/// every block is a single-reference (LAST_FRAME), GLOBALMV (zero motion),
/// `skip=1` inter block. The decoded output is therefore a verbatim copy of
/// the reference frame — the minimal "do-nothing" P-frame used to validate
/// that our inter syntax + entropy contexts are bit-exact against dav1d
/// before any real motion / residual is layered on.
///
/// The partition tree is produced by the existing (intra-verified)
/// [walkSuperblock] which splits every 64×64 superblock down to BLOCK_4X4
/// luma leaves. Using 4×4 leaves is deliberate: at `min(bw4,bh4)==1` dav1d
/// gates off compound prediction, skip_mode, motion_mode and interp-filter
/// syntax entirely, so each leaf reduces to the smallest possible inter
/// block syntax.
///
/// Per-leaf emission (mirrors dav1d `decode_b` inter path, in order):
///   1. `skip` = 1                      → m.skip[skipCtx]
///   2. `is_inter` (decoded bool 1)     → m.intra[0]   (intra ctx is always
///                                          0 for an all-inter neighbourhood)
///   3. single-ref tree to LAST_FRAME:
///        p1 = 0 → m.ref[0][refCtx]
///        p3 = 0 → m.ref[2][refCtx]
///        p4 = 0 → m.ref[3][refCtx]
///   4. `new_mv`    (decoded bool 1)    → m.newmv_mode[newMvCtx]
///   5. `global_mv` (decoded bool 0)    → m.globalmv_mode[0]
///
/// All contexts collapse to pure position functions for this uniform field
/// (derived from src/refmvs.c `dav1d_refmvs_find` + src/env.h):
///   haveTop   = miRow > tileRowStart   (single tile ⇒ miRow > 0)
///   haveLeft  = miCol > tileColStart   (single tile ⇒ miCol > 0)
///   skipCtx   = haveTop + haveLeft                         (0/1/2)
///   refCtx    = (haveTop || haveLeft) ? 2 : 1
///   nearest   = haveTop + haveLeft
///   newMvCtx  = nearest == 0 ? 0 : nearest == 1 ? 3 : 5
///   globalMvCtx = 0  (use_ref_frame_mvs = 0 ⇒ globalmv_ctx always 0)
library;

import 'dart:typed_data';

import 'av1_bool_writer.dart';
import 'av1_default_cdfs.dart';
import 'av1_partition_walker.dart';

/// Public output type — mirrors [TileGroupResult] from the residual encoder
/// so the pipeline glue can treat both uniformly.
class InterTileGroupResult {
  final Uint8List payload;
  final int symbolsEmitted;
  const InterTileGroupResult({
    required this.payload,
    required this.symbolsEmitted,
  });
}

/// Build the tile group for a single all-skip / zero-motion INTER_FRAME.
///
/// [frameWidth] / [frameHeight] are the coded (64-aligned) dimensions.
/// [trueFrameWidth] / [trueFrameHeight] are the display dimensions used to
/// drive partial-superblock partition syntax at the bottom/right edges.
InterTileGroupResult buildInterTileGroup({
  required int frameWidth,
  required int frameHeight,
  int? trueFrameWidth,
  int? trueFrameHeight,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) {
    throw ArgumentError('frame dims must be positive');
  }
  if ((frameWidth & 63) != 0 || (frameHeight & 63) != 0) {
    throw ArgumentError(
      'inter tile group requires multiple-of-64 coded frame dims; got '
      '${frameWidth}x$frameHeight',
    );
  }

  final miCols = frameWidth >> 2;
  final miRows = frameHeight >> 2;
  final sbCols = frameWidth >> 6;
  final sbRows = frameHeight >> 6;

  final trueW = trueFrameWidth ?? frameWidth;
  final trueH = trueFrameHeight ?? frameHeight;
  final trueMiCols = ((trueW + 7) >> 3) << 1;
  final trueMiRows = ((trueH + 7) >> 3) << 1;

  final w = Av1BoolWriter();
  final partCtx = PartitionContext(miCols, miRows);
  final skipCtx = SkipContext(miCols, miRows);

  var symbolsEmitted = 0;

  void interLeafEmitter(
    Av1BoolWriter w,
    int miRow,
    int miCol,
    bool hasChromaRef,
  ) {
    final haveTop = miRow > 0;
    final haveLeft = miCol > 0;

    // 1. skip = 1.
    final sctx = skipCtx.ctxAt(miRow, miCol);
    w.writeSymbol(1, defaultSkipTxfmCdfs[sctx]);

    // 2. is_inter: dav1d decodes `b->intra = !bool`, so an inter block
    //    requires the decoded symbol to be 1. Intra ctx is always 0 here.
    w.writeSymbol(1, defaultIntraInterCdf[0]);

    // 3. single-reference tree → LAST_FRAME (three 0-bits).
    final refCtx = (haveTop || haveLeft) ? 2 : 1;
    w.writeSymbol(0, defaultSingleRefCdf[0][refCtx]); // p1
    w.writeSymbol(0, defaultSingleRefCdf[2][refCtx]); // p3
    w.writeSymbol(0, defaultSingleRefCdf[3][refCtx]); // p4

    // 4/5. inter mode → GLOBALMV: new_mv decoded as 1 (not NEWMV), then
    //      global_mv decoded as 0 (dav1d enters GLOBALMV on !bool).
    final nearest = (haveTop ? 1 : 0) + (haveLeft ? 1 : 0);
    final newMvCtx = nearest == 0 ? 0 : (nearest == 1 ? 3 : 5);
    w.writeSymbol(1, defaultNewMvCdf[newMvCtx]);
    w.writeSymbol(0, defaultGlobalMvCdf[0]);

    symbolsEmitted += 7;

    // Update the skip neighbour context (all blocks skip=1).
    skipCtx.set(miRow, miCol, 1, 1, 1);
  }

  for (var sbR = 0; sbR < sbRows; sbR++) {
    for (var sbC = 0; sbC < sbCols; sbC++) {
      symbolsEmitted += walkSuperblock(
        w: w,
        partCtx: partCtx,
        sbMiRow: sbR * 16,
        sbMiCol: sbC * 16,
        miRows: trueMiRows,
        miCols: trueMiCols,
        leafEmitter: interLeafEmitter,
      );
    }
  }

  return InterTileGroupResult(
    payload: w.finish(),
    symbolsEmitted: symbolsEmitted,
  );
}
