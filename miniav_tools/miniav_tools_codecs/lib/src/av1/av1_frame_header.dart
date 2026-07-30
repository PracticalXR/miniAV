/// AV1 uncompressed frame header for an all-skip intra-only KEY_FRAME.
///
/// The sequence header we emit pins:
///   reduced_still_picture_header = 0
///   timing/decoder model absent
///   frame_id_numbers_present_flag = 0
///   use_128x128_superblock = 0   (64×64 SBs)
///   enable_order_hint = 0
///   enable_superres = 0
///   enable_cdef = 0
///   enable_restoration = 0
///   seq_force_screen_content_tools = SELECT_SCREEN_CONTENT_TOOLS
///   seq_force_integer_mv = SELECT_INTEGER_MV
///   separate_uv_delta_q = 0
///   film_grain_params_present = 0
///
/// And in this frame header we pin:
///   show_existing_frame = 0
///   frame_type = KEY_FRAME (=> error_resilient_mode = 1 implicit,
///                              refresh_frame_flags = 0xFF implicit)
///   show_frame = 1
///   disable_cdf_update = 1
///   allow_screen_content_tools = 0          (so force_integer_mv skipped)
///   frame_size_override_flag = 0
///   render_and_frame_size_different = 0
///   disable_frame_end_update_cdf = 1
///   uniform_tile_spacing_flag = 1 with TileColsLog2 = TileRowsLog2 = 0
///   base_q_idx = q, all deltaQ = 0, using_qmatrix = 0
///   segmentation_enabled = 0
///   delta_q_present = 0
///   loop_filter all zeros, sharpness=0, delta_enabled=0
///   tx_mode_select = 0          (TxMode = TX_MODE_LARGEST)
///   reduced_tx_set = 1
library;

import 'dart:typed_data';

import 'av1_obu.dart';

class FrameHeaderResult {
  final Uint8List payload;
  final int tileColsLog2;
  final int tileRowsLog2;
  final int baseQIdx;
  const FrameHeaderResult({
    required this.payload,
    required this.tileColsLog2,
    required this.tileRowsLog2,
    required this.baseQIdx,
  });
}

/// Number of superblocks in one axis (64×64 SBs).
int _sbCount(int dim) => (dim + 63) >> 6;

/// Spec §5.9.15 `tile_log2(blkSize, target)`.
int _tileLog2(int blkSize, int target) {
  var k = 0;
  while ((blkSize << k) < target) {
    k++;
  }
  return k;
}

/// Build the bare uncompressed-header payload (not including trailing bits
/// of the tile group — those go in [buildTileGroupObu]). The frame OBU
/// payload is `frame_header + tile_group`; we emit them separately and
/// concatenate at the OBU layer so that the byte alignment between them
/// (required by spec §5.10) is respected.
///
/// The returned [payload] is byte-aligned (header trailing bits + byte
/// padding).
///
/// [frameWidth] / [frameHeight] are the **display** (true) dimensions in
/// luma samples. When these equal the sequence-header coded dims they must
/// match what was encoded in the SH. When the coded dims are larger (e.g.
/// padding to a 64-pixel superblock boundary), pass the coded dims in
/// [codedWidth] / [codedHeight] and the true dims here; the function then
/// emits `frame_size_override_flag = 1` so decoders output the exact
/// [frameWidth]×[frameHeight] frame without any external crop.
FrameHeaderResult buildKeyFrameHeader({
  required int frameWidth,
  required int frameHeight,
  int? renderWidth,
  int? renderHeight,

  /// Coded (padded) dims from the sequence header. When non-null and
  /// different from [frameWidth]/[frameHeight], `frame_size_override_flag=1`
  /// is emitted so the decoder uses the true display dims.
  int? codedWidth,
  int? codedHeight,
  int baseQIdx = 32,
}) {
  assert(frameWidth > 0 && frameHeight > 0);
  assert(baseQIdx >= 0 && baseQIdx <= 255);
  final cW = codedWidth ?? frameWidth;
  final cH = codedHeight ?? frameHeight;
  // frame_size_override: emit when the coded (SH) dims differ from the
  // true display frame dims so the decoder uses the exact display size.
  final frameSizeOverride = (cW != frameWidth) || (cH != frameHeight);
  final rW = renderWidth ?? frameWidth;
  final rH = renderHeight ?? frameHeight;
  assert(rW > 0 && rW <= 0xFFFF + 1, 'renderWidth out of range');
  assert(rH > 0 && rH <= 0xFFFF + 1, 'renderHeight out of range');
  final renderDiff = (rW != frameWidth) || (rH != frameHeight);

  final w = BitWriter();

  // ----- frame flags -----
  w.writeBits(0, 1); // show_existing_frame
  w.writeBits(0, 2); // frame_type = KEY_FRAME
  w.writeBits(1, 1); // show_frame
  // error_resilient_mode implicit = 1 (KEY_FRAME && show_frame)
  w.writeBits(1, 1); // disable_cdf_update
  // allow_screen_content_tools — SH said SELECT, so we emit:
  w.writeBits(0, 1); // allow_screen_content_tools = 0
  // force_integer_mv skipped because allow_scc = 0
  // frame_id_numbers_present_flag = 0 in SH → no current_frame_id
  w.writeBits(frameSizeOverride ? 1 : 0, 1); // frame_size_override_flag
  // order_hint: enable_order_hint=0 → 0 bits
  // primary_ref_frame: implicit PRIMARY_REF_NONE (FrameIsIntra && error_resilient)
  // refresh_frame_flags: implicit 0xFF (KEY && show)

  // ----- frame_size + render_size for KEY_FRAME -----
  // frame_size:
  if (frameSizeOverride) {
    // Emit true frame dims using the SH's frame_width_bits field widths,
    // which are derived from the (larger) coded dims. Spec: each field
    // is `frame_width_bits_minus_1 + 1` bits wide.
    final fwBits = _minBitsFor(cW); // same as SH frame_width_bits_minus_1 + 1
    final fhBits = _minBitsFor(cH);
    w.writeBits(frameWidth - 1, fwBits);
    w.writeBits(frameHeight - 1, fhBits);
  }
  // superres: enable_superres=0 → 0 bits
  // render_size:
  if (renderDiff) {
    w.writeBits(1, 1); // render_and_frame_size_different
    w.writeBits(rW - 1, 16); // render_width_minus_1
    w.writeBits(rH - 1, 16); // render_height_minus_1
  } else {
    w.writeBits(0, 1); // render_and_frame_size_different
  }
  // allow_intrabc: allow_screen_content_tools=0 → skipped

  // ----- disable_frame_end_update_cdf -----
  // Per AV1 spec / FFmpeg CBS: when disable_cdf_update==1 (or reduced_still_picture_header),
  // disable_frame_end_update_cdf is INFERRED to 1 — NO bit is emitted.
  // (Previously emitted a bit here, which caused dav1d/CBS "zero_bit out of range"
  // because the extra bit pushed reduced_tx_set into the byte_alignment zone.)

  // ----- tile_info() — single tile -----
  final sbCols = _sbCount(frameWidth);
  final sbRows = _sbCount(frameHeight);
  // sbSize = 64 → sbSizeLog2 = 6
  // MAX_TILE_WIDTH_SB = 4096 >> 6 = 64
  // MAX_TILE_AREA_SB  = (4096 * 2304) >> (6+6) = 2304
  const maxTileWidthSb = 64;
  const maxTileAreaSb = 2304;
  final minLog2TileCols = _tileLog2(maxTileWidthSb, sbCols);
  final maxLog2TileCols = _tileLog2(1, sbCols.clamp(1, maxTileWidthSb));
  final minLog2Tiles = _tileLog2(maxTileAreaSb, sbRows * sbCols);
  const tileColsLog2 = 0;
  // Spec: we must have TileColsLog2 in [minLog2TileCols, maxLog2TileCols].
  if (minLog2TileCols > tileColsLog2) {
    throw StateError(
      'Frame too large for single-tile layout: '
      'minLog2TileCols=$minLog2TileCols (need ≤ 0). '
      'Frame ${frameWidth}x$frameHeight, sbCols=$sbCols',
    );
  }
  final minLog2TileRows = (minLog2Tiles - tileColsLog2).clamp(0, 64);
  final maxLog2TileRows = _tileLog2(1, sbRows.clamp(1, 64));
  const tileRowsLog2 = 0;
  if (minLog2TileRows > tileRowsLog2) {
    throw StateError(
      'Frame too large for single-tile layout: minLog2TileRows='
      '$minLog2TileRows. Frame ${frameWidth}x$frameHeight, sbRows=$sbRows',
    );
  }

  w.writeBits(1, 1); // uniform_tile_spacing_flag
  // Column loop: write 0 to stop at minLog2TileCols (which equals our
  // tileColsLog2). Bits = maxLog2TileCols - tileColsLog2 ones followed by a
  // 0 ... actually spec: while (TileColsLog2 < maxLog2TileCols) {
  //   increment_tile_cols_log2 f(1); if 1: TileColsLog2++; else break }
  // Starting at minLog2TileCols=0 with tileColsLog2=0, we just write 0.
  var t = minLog2TileCols;
  while (t < maxLog2TileCols) {
    if (t < tileColsLog2) {
      w.writeBits(1, 1);
      t++;
    } else {
      w.writeBits(0, 1);
      break;
    }
  }
  t = minLog2TileRows;
  while (t < maxLog2TileRows) {
    if (t < tileRowsLog2) {
      w.writeBits(1, 1);
      t++;
    } else {
      w.writeBits(0, 1);
      break;
    }
  }
  // tileColsLog2 + tileRowsLog2 == 0 → skip context_update_tile_id and
  // tile_size_bytes_minus_1 emit.

  // ----- quantization_params() -----
  w.writeBits(baseQIdx, 8); // base_q_idx
  w.writeBits(0, 1); // DeltaQYDc.delta_coded = 0
  // NumPlanes > 1, separate_uv_delta_q=0 → no diff_uv_delta bit
  w.writeBits(0, 1); // DeltaQUDc.delta_coded = 0
  w.writeBits(0, 1); // DeltaQUAc.delta_coded = 0
  w.writeBits(0, 1); // using_qmatrix = 0

  // ----- segmentation_params() -----
  w.writeBits(0, 1); // segmentation_enabled = 0

  // ----- delta_q_params() — only emitted when base_q_idx > 0 -----
  if (baseQIdx > 0) {
    w.writeBits(0, 1); // delta_q_present = 0
  }
  // delta_lf_params() skipped because delta_q_present = 0

  // ----- loop_filter_params() — not CodedLossless, not allow_intrabc -----
  w.writeBits(0, 6); // loop_filter_level[0] = 0
  w.writeBits(0, 6); // loop_filter_level[1] = 0
  // both luma levels = 0 → no chroma loop_filter levels emitted
  w.writeBits(0, 3); // loop_filter_sharpness
  w.writeBits(0, 1); // loop_filter_delta_enabled = 0
  // delta_enabled = 0 → no further mode/ref delta bits

  // cdef_params: enable_cdef = 0 → skipped
  // lr_params:   enable_restoration = 0 → skipped

  // ----- read_tx_mode() — CodedLossless=0 -----
  w.writeBits(0, 1); // tx_mode_select = 0 → TxMode = TX_MODE_LARGEST

  // frame_reference_mode: intra → skipped
  // skip_mode_params:     intra → skipped
  // global_motion_params: intra → skipped
  // film_grain_params:    not present → skipped

  // ----- reduced_tx_set -----
  w.writeBits(1, 1); // reduced_tx_set = 1

  // Byte-align to the next boundary using `byte_alignment()` semantics
  // (pad with zero bits — NO leading `1` bit). The leading-`1` trailing-bits
  // pattern is only used when this header is its own OBU (OBU_FRAME_HEADER).
  // Inside an OBU_FRAME, the spec's `frame_obu(sz)` invokes
  // `byte_alignment()` after `frame_header_obu()`, which writes only zeros.
  w.byteAlign();
  return FrameHeaderResult(
    payload: w.toBytes(),
    tileColsLog2: tileColsLog2,
    tileRowsLog2: tileRowsLog2,
    baseQIdx: baseQIdx,
  );
}

/// Build the uncompressed frame header for an INTER_FRAME.
///
/// Pinned choices (must match the sequence header we emit and the inter tile
/// group emitter):
///   show_existing_frame      = 0
///   frame_type               = INTER_FRAME (=1)
///   show_frame               = 1
///   error_resilient_mode     = 1   (=> primary_ref_frame = PRIMARY_REF_NONE,
///                                       => default CDFs, => no allow_warped,
///                                       => use_ref_frame_mvs = 0)
///   disable_cdf_update       = 1   (=> disable_frame_end_update_cdf inferred)
///   allow_screen_content_tools = 0 (=> force_integer_mv = 0, not coded)
///   ref_frame_idx[0..6]      = [refIdx] (default all 0 → slot 0)
///   refresh_frame_flags      = [refreshFrameFlags]
///   allow_high_precision_mv  = 0
///   interpolation_filter     = EIGHTTAP (is_filter_switchable = 0)
///   is_motion_mode_switchable= 0   (=> motion_mode SIMPLE, no per-block syntax)
///   tx_mode_select           = 0   (TX_MODE_LARGEST)
///   reference_select         = 0   (SINGLE_REFERENCE, no comp_mode per block)
///   reduced_tx_set           = 1
///   GmType[all refs]         = IDENTITY (is_global = 0 → GLOBALMV ⇒ MV(0,0))
///
/// With every ref slot pointing at the previous KEY frame and every block
/// coded as GLOBALMV+skip, the decoder reproduces the reference frame exactly.
FrameHeaderResult buildInterFrameHeader({
  required int frameWidth,
  required int frameHeight,
  int? renderWidth,
  int? renderHeight,
  int? codedWidth,
  int? codedHeight,
  int baseQIdx = 32,

  /// 8-bit mask of which of the 8 reference slots this frame writes into.
  int refreshFrameFlags = 0x01,

  /// Slot index (0..7) all 7 ref_frame_idx entries point at. Default 0 → the
  /// previous KEY frame (which refreshed all slots).
  int refIdx = 0,
}) {
  assert(frameWidth > 0 && frameHeight > 0);
  assert(baseQIdx >= 0 && baseQIdx <= 255);
  assert(refreshFrameFlags >= 0 && refreshFrameFlags <= 0xFF);
  assert(refIdx >= 0 && refIdx <= 7);
  final cW = codedWidth ?? frameWidth;
  final cH = codedHeight ?? frameHeight;
  final frameSizeOverride = (cW != frameWidth) || (cH != frameHeight);
  final rW = renderWidth ?? frameWidth;
  final rH = renderHeight ?? frameHeight;
  assert(rW > 0 && rW <= 0xFFFF + 1, 'renderWidth out of range');
  assert(rH > 0 && rH <= 0xFFFF + 1, 'renderHeight out of range');
  final renderDiff = (rW != frameWidth) || (rH != frameHeight);

  final w = BitWriter();

  // ----- frame flags -----
  w.writeBits(0, 1); // show_existing_frame
  w.writeBits(1, 2); // frame_type = INTER_FRAME (1)
  w.writeBits(1, 1); // show_frame
  // showable_frame: show_frame=1 → showable_frame = (frame_type != KEY) = 1,
  // inferred (not coded).
  w.writeBits(1, 1); // error_resilient_mode = 1
  w.writeBits(1, 1); // disable_cdf_update = 1
  // allow_screen_content_tools — SH said SELECT → emit:
  w.writeBits(0, 1); // allow_screen_content_tools = 0
  // force_integer_mv skipped (allow_scc = 0, not intra → 0)
  // frame_id_numbers_present = 0 → no current_frame_id
  w.writeBits(frameSizeOverride ? 1 : 0, 1); // frame_size_override_flag
  // order_hint: enable_order_hint = 0 → OrderHint = 0, not coded
  // primary_ref_frame: error_resilient_mode → PRIMARY_REF_NONE, not coded
  // decoder_model_info_present = 0 → no buffer_removal_time
  w.writeBits(refreshFrameFlags, 8); // refresh_frame_flags
  // (!FrameIsIntra) && error_resilient_mode && enable_order_hint → ref order
  // hints; enable_order_hint = 0 → skipped.

  // ----- INTER reference / size block -----
  // enable_order_hint = 0 → frame_refs_short_signaling = 0 (not coded).
  for (var i = 0; i < 7; i++) {
    w.writeBits(refIdx, 3); // ref_frame_idx[i]
    // frame_id_numbers_present = 0 → no delta_frame_id
  }
  // error_resilient_mode = 1 → use frame_size() + render_size() (no
  // frame_size_with_refs found_ref loop), regardless of frame_size_override.
  if (frameSizeOverride) {
    final fwBits = _minBitsFor(cW);
    final fhBits = _minBitsFor(cH);
    w.writeBits(frameWidth - 1, fwBits); // frame_width_minus_1
    w.writeBits(frameHeight - 1, fhBits); // frame_height_minus_1
  }
  // superres: enable_superres = 0 → 0 bits
  if (renderDiff) {
    w.writeBits(1, 1); // render_and_frame_size_different
    w.writeBits(rW - 1, 16);
    w.writeBits(rH - 1, 16);
  } else {
    w.writeBits(0, 1); // render_and_frame_size_different
  }
  // force_integer_mv = 0 → emit allow_high_precision_mv
  w.writeBits(0, 1); // allow_high_precision_mv = 0
  // read_interpolation_filter()
  w.writeBits(0, 1); // is_filter_switchable = 0
  w.writeBits(0, 2); // interpolation_filter = EIGHTTAP (0)
  w.writeBits(0, 1); // is_motion_mode_switchable = 0
  // use_ref_frame_mvs: error_resilient_mode = 1 → 0, not coded
  // disable_frame_end_update_cdf: disable_cdf_update = 1 → inferred 1, not coded

  // ----- tile_info() — single tile (identical to KEY path) -----
  final sbCols = _sbCount(frameWidth);
  final sbRows = _sbCount(frameHeight);
  const maxTileWidthSb = 64;
  const maxTileAreaSb = 2304;
  final minLog2TileCols = _tileLog2(maxTileWidthSb, sbCols);
  final maxLog2TileCols = _tileLog2(1, sbCols.clamp(1, maxTileWidthSb));
  final minLog2Tiles = _tileLog2(maxTileAreaSb, sbRows * sbCols);
  const tileColsLog2 = 0;
  if (minLog2TileCols > tileColsLog2) {
    throw StateError(
      'Frame too large for single-tile layout: '
      'minLog2TileCols=$minLog2TileCols (need ≤ 0). '
      'Frame ${frameWidth}x$frameHeight, sbCols=$sbCols',
    );
  }
  final minLog2TileRows = (minLog2Tiles - tileColsLog2).clamp(0, 64);
  final maxLog2TileRows = _tileLog2(1, sbRows.clamp(1, 64));
  const tileRowsLog2 = 0;
  if (minLog2TileRows > tileRowsLog2) {
    throw StateError(
      'Frame too large for single-tile layout: minLog2TileRows='
      '$minLog2TileRows. Frame ${frameWidth}x$frameHeight, sbRows=$sbRows',
    );
  }
  w.writeBits(1, 1); // uniform_tile_spacing_flag
  var t = minLog2TileCols;
  while (t < maxLog2TileCols) {
    if (t < tileColsLog2) {
      w.writeBits(1, 1);
      t++;
    } else {
      w.writeBits(0, 1);
      break;
    }
  }
  t = minLog2TileRows;
  while (t < maxLog2TileRows) {
    if (t < tileRowsLog2) {
      w.writeBits(1, 1);
      t++;
    } else {
      w.writeBits(0, 1);
      break;
    }
  }

  // ----- quantization_params() (identical to KEY) -----
  w.writeBits(baseQIdx, 8); // base_q_idx
  w.writeBits(0, 1); // DeltaQYDc.delta_coded = 0
  w.writeBits(0, 1); // DeltaQUDc.delta_coded = 0
  w.writeBits(0, 1); // DeltaQUAc.delta_coded = 0
  w.writeBits(0, 1); // using_qmatrix = 0

  // ----- segmentation_params() -----
  w.writeBits(0, 1); // segmentation_enabled = 0

  // ----- delta_q_params() (only when base_q_idx > 0) -----
  if (baseQIdx > 0) {
    w.writeBits(0, 1); // delta_q_present = 0
  }
  // delta_lf_params() skipped (delta_q_present = 0)

  // ----- loop_filter_params() -----
  w.writeBits(0, 6); // loop_filter_level[0] = 0
  w.writeBits(0, 6); // loop_filter_level[1] = 0
  w.writeBits(0, 3); // loop_filter_sharpness
  w.writeBits(0, 1); // loop_filter_delta_enabled = 0

  // cdef_params: enable_cdef = 0 → skipped
  // lr_params:   enable_restoration = 0 → skipped

  // ----- read_tx_mode() -----
  w.writeBits(0, 1); // tx_mode_select = 0 → TX_MODE_LARGEST

  // ----- frame_reference_mode() -----
  w.writeBits(0, 1); // reference_select = 0 → SINGLE_REFERENCE

  // skip_mode_params(): reference_select = 0 → skipModeAllowed = 0, no bit.
  // allow_warped_motion: error_resilient_mode = 1 → 0, not coded.

  // ----- reduced_tx_set -----
  w.writeBits(1, 1); // reduced_tx_set = 1

  // ----- global_motion_params() — 7 refs (LAST..ALTREF), all IDENTITY -----
  for (var ref = 0; ref < 7; ref++) {
    w.writeBits(0, 1); // is_global = 0 → GmType = IDENTITY
  }

  // film_grain_params(): film_grain_params_present = 0 → skipped

  w.byteAlign();
  return FrameHeaderResult(
    payload: w.toBytes(),
    tileColsLog2: tileColsLog2,
    tileRowsLog2: tileRowsLog2,
    baseQIdx: baseQIdx,
  );
}

// Minimum number of bits needed to represent [value] distinct values
// (i.e. ceil(log2(value)), minimum 1).
int _minBitsFor(int value) {
  var b = 1;
  while ((1 << b) < value) {
    b++;
  }
  return b;
}
