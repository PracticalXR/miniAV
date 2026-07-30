/// AV1 Sequence Header OBU builder.
///
/// Generates a Main-profile 8-bit 4:2:0 sequence header tied to the given
/// resolution + framerate. Output is the raw OBU payload bytes (i.e.
/// `sequence_header_obu()` per spec §5.5, terminated with trailing bits).
/// Use [encodeObu] to wrap with an OBU header.
library;

import 'dart:typed_data';

import 'av1_constants.dart';
import 'av1_obu.dart';

/// Result of building a sequence header — the bare payload plus a small
/// summary used by the av1C config record and the MP4 muxer.
class SequenceHeaderResult {
  final Uint8List payload;
  final int seqProfile;
  final int seqLevelIdx0;
  final int seqTier0; // 0 = Main tier
  final int width;
  final int height;
  final bool highBitDepth; // false (8-bit)
  final bool twelveBit; // false
  final bool monochrome; // false
  final int chromaSubsamplingX; // 1
  final int chromaSubsamplingY; // 1
  final int chromaSamplePosition;

  const SequenceHeaderResult({
    required this.payload,
    required this.seqProfile,
    required this.seqLevelIdx0,
    required this.seqTier0,
    required this.width,
    required this.height,
    required this.highBitDepth,
    required this.twelveBit,
    required this.monochrome,
    required this.chromaSubsamplingX,
    required this.chromaSubsamplingY,
    required this.chromaSamplePosition,
  });
}

/// Build a minimal Main-profile sequence header.
///
/// We pin many switches to their simplest valid combinations:
///   * still_picture = 0, reduced_still_picture_header = 0
///   * Single operating point (op count − 1 = 0), no decoder model
///   * No frame ID numbers
///   * use_128x128_superblock = 0  → 64×64 superblocks (matches our pipeline)
///   * All optional intra/inter tools enabled at the SH layer; per-frame
///     flags in the frame header will disable inter for our intra-only stream
///   * film_grain_params_present = 0
SequenceHeaderResult buildSequenceHeader({
  required int width,
  required int height,
  required int frameRateNumerator,
  required int frameRateDenominator,
}) {
  assert(width > 0 && height > 0);
  final w = BitWriter();

  // seq_profile, still_picture, reduced_still_picture_header
  w.writeBits(SeqProfile.main, 3);
  w.writeFlag(false); // still_picture
  w.writeFlag(false); // reduced_still_picture_header

  // No decoder model / timing info
  w.writeFlag(false); // timing_info_present_flag
  w.writeFlag(false); // initial_display_delay_present_flag
  // operating_points_cnt_minus_1 = 0  (5 bits)
  w.writeBits(0, 5);
  // operating_point_idc[0] = 0  (12 bits)
  w.writeBits(0, 12);
  // seq_level_idx[0] = 8  (5 bits) → Level 4.0
  const seqLevelIdx0 = SeqLevel.level_4_0;
  w.writeBits(seqLevelIdx0, 5);
  // seq_level_idx[0] > 7 → seq_tier[0] flag must be present
  const seqTier0 = 0;
  w.writeFlag(seqTier0 != 0);

  // frame_width_bits_minus_1 + frame_height_bits_minus_1
  final fwBits = _minBitsFor(width);
  final fhBits = _minBitsFor(height);
  w.writeBits(fwBits - 1, 4);
  w.writeBits(fhBits - 1, 4);
  w.writeBits(width - 1, fwBits);
  w.writeBits(height - 1, fhBits);

  // frame_id_numbers_present_flag = 0
  w.writeFlag(false);

  // use_128x128_superblock = 0  → 64×64
  w.writeFlag(false);

  // Tools — disable everything that would add per-block syntax we don't
  // emit. filter_intra in particular is parsed per BLOCK_4X4 DC_PRED leaf
  // and we don't carry filter_intra_cdfs, so it must be off.
  w.writeFlag(false); // enable_filter_intra
  w.writeFlag(false); // enable_intra_edge_filter
  w.writeFlag(false); // enable_interintra_compound
  w.writeFlag(false); // enable_masked_compound
  w.writeFlag(false); // enable_warped_motion
  w.writeFlag(false); // enable_dual_filter

  w.writeFlag(false); // enable_order_hint
  // order_hint disabled → skip enable_jnt_comp / enable_ref_frame_mvs

  // seq_force_screen_content_tools (1 bit) — 2 = SELECT_SCREEN_CONTENT_TOOLS
  w.writeFlag(true); // seq_choose_screen_content_tools = 1
  // (seq_force_screen_content_tools is then SELECT, no further bits)
  // seq_force_integer_mv — only present if SELECT_SCREEN_CONTENT_TOOLS chosen
  w.writeFlag(true); // seq_choose_integer_mv = 1

  // order_hint disabled → no order_hint_bits_minus_1 bits

  w.writeFlag(false); // enable_superres
  w.writeFlag(false); // enable_cdef
  w.writeFlag(false); // enable_restoration

  // color_config
  w.writeFlag(false); // high_bitdepth = 0 (8-bit)
  // monochrome flag only present when seq_profile != 1
  w.writeFlag(false); // monochrome = 0
  w.writeFlag(true); // color_description_present_flag = 1
  w.writeBits(ColorPrimaries.bt709, 8);
  w.writeBits(TransferCharacteristics.bt709, 8);
  w.writeBits(MatrixCoefficients.bt709, 8);
  // not monochrome + color_description present → color_range
  w.writeFlag(false); // color_range = 0 (studio swing)
  // 4:2:0 (Main): subsampling_x = 1, subsampling_y = 1
  // For seq_profile=0, both are implied to 1 — but for color_range==0 we
  // still need to emit chroma_sample_position
  w.writeBits(ChromaSamplePosition.colocated, 2);
  w.writeFlag(false); // separate_uv_deltas / reserved zero

  // film_grain_params_present
  w.writeFlag(false);

  w.writeTrailingBits();

  // frame rate is unused in the SH proper; passed through for the av1C
  // record / MP4 mvhd via the encoder config separately.
  return SequenceHeaderResult(
    payload: w.toBytes(),
    seqProfile: SeqProfile.main,
    seqLevelIdx0: seqLevelIdx0,
    seqTier0: seqTier0,
    width: width,
    height: height,
    highBitDepth: false,
    twelveBit: false,
    monochrome: false,
    chromaSubsamplingX: 1,
    chromaSubsamplingY: 1,
    chromaSamplePosition: ChromaSamplePosition.colocated,
  );
}

int _minBitsFor(int value) {
  // value ≥ 1; returns ceil(log2(value)) but at least 1.
  var b = 1;
  while ((1 << b) < value) {
    b++;
  }
  return b;
}
