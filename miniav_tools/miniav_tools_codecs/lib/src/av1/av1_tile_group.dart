/// AV1 tile group OBU for an all-skip intra-only KEY_FRAME.
///
/// Phase 3a: multi-SB tile (frame dims multiple of 64). Every SB is
/// PARTITION_NONE 64×64, intra DC_PRED, skip=1. Skip context tracked
/// across SBs; partition/y_mode/uv_mode contexts are constant
/// (12 / [0][0] / 0) for an all-DC all-skip grid.
library;

import 'dart:typed_data';

import 'av1_bool_writer.dart';
import 'av1_default_cdfs.dart';

class TileGroupResult {
  final Uint8List payload;
  final int symbolsEmitted;
  const TileGroupResult({required this.payload, required this.symbolsEmitted});
}

TileGroupResult buildAllSkipTileGroup({
  required int frameWidth,
  required int frameHeight,
}) {
  if (frameWidth <= 0 || frameHeight <= 0) {
    throw ArgumentError('frame dims must be positive');
  }
  if ((frameWidth & 63) != 0 || (frameHeight & 63) != 0) {
    throw ArgumentError(
      'Phase 3a tile group requires multiple-of-64 frame dims; got '
      '${frameWidth}x$frameHeight',
    );
  }

  final sbCols = frameWidth >> 6;
  final sbRows = frameHeight >> 6;
  final w = Av1BoolWriter();

  // Skip-context tracking. above_skip[col] = last skip flag emitted for
  // the SB in the row above this column.
  final aboveSkip = Uint8List(sbCols); // all 0 at frame start

  var symbols = 0;
  for (var r = 0; r < sbRows; r++) {
    var leftSkip = 0;
    for (var c = 0; c < sbCols; c++) {
      // partition (BLOCK_64X64) — context always 12 for all-NONE grid.
      w.writeSymbol(0, defaultPartitionCdf[12]);

      // skip flag — context = above_skip + left_skip in [0,2].
      final skipCtx = aboveSkip[c] + leftSkip;
      w.writeSymbol(1, defaultSkipTxfmCdfs[skipCtx]);

      // intra_frame_y_mode (KEY_FRAME). Above/left mode class = 0 (DC).
      w.writeSymbol(0, defaultKfYModeCdf[0][0]);

      // uv_mode (CFL not allowed at 64×64 luma → 32×32 chroma).
      w.writeSymbol(0, defaultUvModeCdfCflNotAllowed[0]);

      symbols += 4;
      aboveSkip[c] = 1;
      leftSkip = 1;
    }
  }

  return TileGroupResult(payload: w.finish(), symbolsEmitted: symbols);
}
