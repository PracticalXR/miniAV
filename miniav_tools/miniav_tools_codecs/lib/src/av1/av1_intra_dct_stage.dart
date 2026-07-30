/// Phase 3b GPU stage: DC intra-prediction + forward 4×4 DCT-II + quantize.
///
/// Input : kYuv420Key — planar YUV420 float buffer produced by the BGRA→YUV420
///         stage (Y plane: W*H floats, U/V planes: (W/2)*(H/2) floats each).
///         Values are BT.709 limited-range integers [16..235 / 16..240] stored
///         as f32.
///
/// Output: kQuantCoeffsKey — one int16 per coefficient, layout:
///   [numBlocks4x4 * 3 * 16] int16 values (each signed, already quantized).
///   First numBlocks4x4 blocks are Y, next numBlocks4x4/4 are U, then V.
///   Within each block: 16 values in AV1 default 4×4 scan order (DC first).
///
/// Frame dims must be multiples of 4. Each 4×4 block:
///   1. Predict every pixel = DC (mean of top-row + left-column; edge blocks
///      use 0 as the neighbour value, i.e. the mean of available samples).
///   2. Subtract prediction from source → residual in [-128..128].
///   3. Apply forward 4×4 DCT-II (integer-approximate, no scaling).
///   4. Divide by quantiser step (round-toward-zero). Output clamped to
///      [-2047..2047].
///
/// This stage does NOT produce coefficients in AV1's scan order — that
/// reordering is done on readback (CPU) for simplicity because it's just a
/// table lookup.
library;

import 'package:gpu_pipeline/gpu_pipeline.dart';
import 'av1_yuv420_stage.dart' show Yuv420Layout, kYuv420Key;

const String kQuantCoeffsKey = 'av1_quant_coeffs';

/// Number of 4×4 luma blocks for a given width/height (both must be ≥4 and
/// multiples of 4).
int numLumaBlocks4x4(int width, int height) => (width >> 2) * (height >> 2);

/// Build the DC-intra + fDCT + quantize GPU stage.
///
/// [baseQIdx] is the AV1 base_q_idx (0..255) from the frame header.
/// The DC-quantizer step is looked up from the standard AV1 table;
/// AC steps use the AC table.
PipelineStage buildIntraDctQuantStage({
  required int width,
  required int height,
  int baseQIdx = 32,
  String inputKey = kYuv420Key,
  String outputKey = kQuantCoeffsKey,
}) {
  assert(width > 0 && height > 0);
  assert(
    width % 4 == 0 && height % 4 == 0,
    'dims must be multiples of 4; got ${width}x$height',
  );

  final layout = Yuv420Layout(width, height);
  final bw = width >> 2; // luma blocks per row
  final bh = height >> 2; // luma blocks per column
  final numLuma = bw * bh;
  final uvW = layout.uvWidth;
  final uvH = layout.uvHeight;
  final uvBw = uvW >> 2; // UV blocks per row: uvWidth / 4
  final uvBh = uvH >> 2;
  final numUv = uvBw * uvBh;
  // Total int16 output: (numLuma * 16) + 2*(numUv * 16)
  final totalCoeffs = (numLuma + 2 * numUv) * 16;

  // AV1 dc_qlookup_Q3 / ac_qlookup_Q3 (8-bit) — step sizes in units of 1/8.
  // We store integer steps (divide by 8 from Q3, but in practice just use the
  // tabulated value directly as the divisor in f32 divide).
  // Index = baseQIdx. From av1_constants.dart kDcQlookup / kAcQlookup.
  // We embed only the single step at baseQIdx in the shader as a constant.
  // Full tables are in av1_constants.dart.
  final dcStep = _dcQlookup[baseQIdx.clamp(0, 255)];
  final acStep = _acQlookup[baseQIdx.clamp(0, 255)];

  // Forward 4×4 DCT-II coefficients, same separable structure as MJPEG 8×8.
  // C[k,n] = sqrt(Ck/4) * cos((2n+1)*k*pi/8), with C0=1/sqrt(2), Ck=1 for k>0.
  const dct4Coeff = '''
// 4x4 DCT-II coefficients: COEFF4[k*4+n] = Ck/2 * cos((2n+1)*k*pi/8).
const COEFF4: array<f32, 16> = array<f32, 16>(
  0.5,        0.5,        0.5,        0.5,
  0.6532814,  0.2705981, -0.2705981, -0.6532814,
  0.5,       -0.5,       -0.5,        0.5,
  0.2705981, -0.6532814,  0.6532814, -0.2705981,
);
''';

  // One workgroup per 4×4 block (luma or chroma), 16 threads each.
  // bindings: input YUV420 (binding 0), output int16-as-f32 (binding 1).
  final wgsl =
      '''
@group(0) @binding(0) var<storage, read_write> yuv: array<f32>;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

$dct4Coeff

// --- layout constants ---
const W:         u32 = ${width}u;
const H:         u32 = ${height}u;
const UV_W:      u32 = ${uvW}u;
const UV_H:      u32 = ${uvH}u;
const Y_SIZE:    u32 = ${layout.ySize}u;
const UV_SIZE:   u32 = ${layout.uvSize}u;
const NUM_LUMA:  u32 = ${numLuma}u;
const NUM_UV:    u32 = ${numUv}u;
const BW:        u32 = ${bw}u;   // luma block cols
const UV_BW:     u32 = ${uvBw}u; // uv block cols
const DC_STEP:   f32 = ${dcStep}.0;
const AC_STEP:   f32 = ${acStep}.0;

var<workgroup> pixels: array<f32, 16>;
var<workgroup> tmp:    array<f32, 16>;

// AV1 4x4 scan order: scan[i] = natural index for i-th scan position.
const SCAN4: array<u32, 16> = array<u32, 16>(
  0u, 4u, 1u, 8u, 5u, 2u, 12u, 9u, 6u, 3u, 13u, 10u, 7u, 14u, 11u, 15u
);

@compute @workgroup_size(16)
fn main(
  @builtin(global_invocation_id) gid: vec3<u32>,
  @builtin(local_invocation_id) lid: vec3<u32>,
) {
  let group_idx: u32 = gid.x / 16u;
  let li:        u32 = lid.x; // 0..15

  // ---- determine pixel source ----
  // group_idx in [0, NUM_LUMA):        luma block
  // group_idx in [NUM_LUMA, NUM_LUMA+NUM_UV): U block
  // group_idx in [NUM_LUMA+NUM_UV, NUM_LUMA+2*NUM_UV): V block
  var px: i32;
  var py: i32;
  var plane: u32;
  var plane_w: u32;
  var plane_h: u32;
  var yuv_base: u32;
  var coeff_base: u32;

  if (group_idx < NUM_LUMA) {
    // luma 4x4
    plane   = 0u;
    plane_w = W;
    plane_h = H;
    yuv_base   = 0u;
    coeff_base = group_idx * 16u;
    let bx: u32 = group_idx % BW;
    let by: u32 = group_idx / BW;
    px = i32(bx * 4u);
    py = i32(by * 4u);
  } else if (group_idx < NUM_LUMA + NUM_UV) {
    // U plane 4x4
    let uv_idx: u32 = group_idx - NUM_LUMA;
    plane   = 1u;
    plane_w = UV_W;
    plane_h = UV_H;
    yuv_base   = Y_SIZE;
    coeff_base = (NUM_LUMA + uv_idx) * 16u;
    let bx: u32 = uv_idx % UV_BW;
    let by: u32 = uv_idx / UV_BW;
    px = i32(bx * 4u);
    py = i32(by * 4u);
  } else {
    // V plane 4x4
    let uv_idx: u32 = group_idx - NUM_LUMA - NUM_UV;
    plane   = 2u;
    plane_w = UV_W;
    plane_h = UV_H;
    yuv_base   = Y_SIZE + UV_SIZE;
    coeff_base = (NUM_LUMA + NUM_UV + uv_idx) * 16u;
    let bx: u32 = uv_idx % UV_BW;
    let by: u32 = uv_idx / UV_BW;
    px = i32(bx * 4u);
    py = i32(by * 4u);
  }

  // ---- step 1: compute DC prediction = mean of available top/left samples ----
  // For simplicity: mean of top row (4 samples) if py>0, plus left col (4 samples)
  // if px>0. Edge pixels contribute 128.0 (mid-gray) as fallback.
  var dc_sum: f32 = 0.0;
  var dc_count: u32 = 0u;
  if (li == 0u) {
    // Top row
    for (var dx: i32 = 0; dx < 4; dx = dx + 1) {
      let sx: i32 = px + dx;
      let sy: i32 = py - 1;
      var val: f32 = 128.0;
      if (sy >= 0) {
        val = yuv[yuv_base + u32(sy) * plane_w + u32(sx)];
      }
      dc_sum += val;
      dc_count += 1u;
    }
    // Left col
    for (var dy: i32 = 0; dy < 4; dy = dy + 1) {
      let sx: i32 = px - 1;
      let sy: i32 = py + dy;
      var val: f32 = 128.0;
      if (sx >= 0) {
        val = yuv[yuv_base + u32(sy) * plane_w + u32(sx)];
      }
      dc_sum += val;
      dc_count += 1u;
    }
  }
  // NOTE: only thread 0 computed dc; broadcast via workgroup memory trick:
  // Store in pixels[0] temporarily for other threads to read.
  if (li == 0u) {
    pixels[0] = dc_sum / f32(dc_count);
  }
  workgroupBarrier();
  let dc_pred: f32 = pixels[0];

  // ---- step 2: load source pixel, subtract DC pred → residual ----
  let ry: u32 = li / 4u;
  let rx: u32 = li % 4u;
  let src_x: u32 = u32(px) + rx;
  let src_y: u32 = u32(py) + ry;
  let src_idx: u32 = yuv_base + src_y * plane_w + src_x;
  pixels[ry * 4u + rx] = yuv[src_idx] - dc_pred;

  workgroupBarrier();

  // ---- step 3: 4×4 forward DCT-II (separable: horizontal then vertical) ----
  // Horizontal: tmp[row, k] = Σ_n pixels[row, n] * COEFF4[k, n]
  let hk: u32 = rx;  // output frequency k
  let hr: u32 = ry;  // row index
  var hsum: f32 = 0.0;
  for (var n: u32 = 0u; n < 4u; n = n + 1u) {
    hsum += pixels[hr * 4u + n] * COEFF4[hk * 4u + n];
  }
  tmp[hr * 4u + hk] = hsum;

  workgroupBarrier();

  // Vertical: coeff[v, k] = Σ_r tmp[r, k] * COEFF4[v, r]
  let vv: u32 = ry;  // output vertical frequency v
  let vk: u32 = rx;  // horizontal frequency k
  var vsum: f32 = 0.0;
  for (var r: u32 = 0u; r < 4u; r = r + 1u) {
    vsum += tmp[r * 4u + vk] * COEFF4[vv * 4u + r];
  }
  // natural-order coeff index: vv*4+vk
  let nat_idx: u32 = vv * 4u + vk;

  // ---- step 4: quantize (DC uses dc_step, AC uses ac_step) ----
  let step: f32 = select(AC_STEP, DC_STEP, nat_idx == 0u);
  // Scale: DCT-II output is in roughly [-128*sqrt(2), +128*sqrt(2)].
  // AV1 dequantiser convention: coeff * step / 4 = residual sample.
  // So quantised_level = round(coeff * 4 / step).  We round-toward-zero.
  let level_f: f32 = vsum * 4.0 / step;
  let level: i32 = i32(level_f); // truncate toward zero

  // ---- step 5: reorder into AV1 4×4 scan order ----
  // Write to scan position SCAN4[nat_idx].
  let scan_pos: u32 = SCAN4[nat_idx];
  out[coeff_base + scan_pos] = f32(clamp(level, -2047, 2047));
}
''';

  final numGroups = numLuma + 2 * numUv; // used for doc; dispatch is auto.

  return StageBuilder('av1_intra_dct_quant_${width}x$height')
      .withFlexibleInput(inputKey)
      .withFixedOutput(outputKey, shape: [totalCoeffs])
      .executeShader(
        wgsl,
        inputKeys: [inputKey],
        outputKeys: [outputKey],
        workgroupSize: const [16],
        // Dispatch = ceil(totalCoeffs / 16) = numGroups; auto-derived from
        // the output tensor size by the StageBuilder.
      )
      .build();
}

// Embedded quantiser tables (identical to av1_constants.dart kDcQlookup /
// kAcQlookup; duplicated here so the shader builder is self-contained).
const List<int> _dcQlookup = [
  4,
  8,
  8,
  9,
  10,
  11,
  12,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  38,
  39,
  40,
  41,
  42,
  43,
  43,
  44,
  45,
  46,
  47,
  48,
  48,
  49,
  50,
  51,
  52,
  53,
  53,
  54,
  55,
  56,
  57,
  57,
  58,
  59,
  60,
  61,
  62,
  62,
  63,
  64,
  65,
  66,
  66,
  67,
  68,
  69,
  70,
  70,
  71,
  72,
  73,
  74,
  74,
  75,
  76,
  77,
  78,
  78,
  79,
  80,
  81,
  81,
  82,
  83,
  84,
  85,
  85,
  87,
  88,
  90,
  92,
  93,
  95,
  96,
  98,
  99,
  101,
  102,
  104,
  105,
  107,
  108,
  110,
  111,
  113,
  114,
  116,
  117,
  118,
  120,
  121,
  123,
  125,
  127,
  129,
  131,
  134,
  136,
  138,
  140,
  142,
  144,
  146,
  148,
  150,
  152,
  154,
  156,
  158,
  161,
  164,
  166,
  169,
  172,
  174,
  177,
  180,
  182,
  185,
  188,
  191,
  193,
  196,
  199,
  202,
  205,
  208,
  211,
  214,
  217,
  220,
  223,
  226,
  229,
  232,
  235,
  238,
  241,
  244,
  247,
  250,
  253,
  257,
  261,
  265,
  269,
  272,
  276,
  280,
  284,
  288,
  292,
  296,
  300,
  304,
  308,
  312,
  316,
  320,
  324,
  328,
  332,
  336,
  340,
  344,
  348,
  352,
  356,
  360,
  364,
  369,
  373,
  378,
  382,
  387,
  391,
  396,
  400,
  405,
  409,
  414,
  418,
  423,
  427,
  432,
  436,
  441,
  445,
  450,
  454,
  459,
  463,
  468,
  472,
  477,
  481,
  486,
  490,
  495,
  499,
  504,
  509,
  513,
  518,
  522,
  527,
  531,
  536,
  540,
  545,
  550,
  554,
  559,
  563,
  568,
  572,
  577,
  581,
  586,
  591,
  595,
  600,
  604,
  609,
  614,
  618,
  623,
];
const List<int> _acQlookup = [
  4,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  61,
  62,
  63,
  64,
  65,
  66,
  67,
  68,
  69,
  70,
  71,
  72,
  73,
  74,
  75,
  76,
  77,
  78,
  79,
  80,
  81,
  82,
  83,
  84,
  85,
  86,
  87,
  88,
  89,
  90,
  91,
  92,
  93,
  94,
  95,
  96,
  97,
  98,
  99,
  100,
  101,
  102,
  104,
  106,
  108,
  110,
  112,
  114,
  116,
  118,
  120,
  122,
  124,
  126,
  128,
  130,
  132,
  134,
  136,
  138,
  140,
  142,
  144,
  146,
  148,
  150,
  152,
  155,
  158,
  161,
  164,
  167,
  170,
  173,
  176,
  179,
  182,
  185,
  188,
  191,
  194,
  197,
  200,
  203,
  207,
  211,
  215,
  219,
  223,
  227,
  231,
  235,
  239,
  243,
  247,
  251,
  255,
  260,
  265,
  270,
  275,
  280,
  285,
  290,
  295,
  300,
  305,
  311,
  317,
  323,
  329,
  335,
  341,
  347,
  353,
  359,
  366,
  373,
  380,
  387,
  394,
  401,
  408,
  416,
  424,
  432,
  440,
  448,
  456,
  465,
  474,
  483,
  492,
  501,
  510,
  520,
  530,
  540,
  550,
  560,
  571,
  582,
  593,
  604,
  615,
  627,
  639,
  651,
  663,
  676,
  689,
  702,
  715,
  729,
  743,
  757,
  771,
  786,
  801,
  816,
  831,
  847,
  863,
  879,
  896,
  913,
  930,
  947,
  965,
  983,
  1001,
  1019,
  1037,
  1056,
  1075,
  1094,
  1113,
  1133,
  1153,
  1173,
  1193,
  1214,
  1235,
  1256,
  1278,
  1300,
  1322,
  1345,
  1368,
  1391,
  1415,
  1439,
  1463,
  1488,
  1513,
  1538,
  1563,
  1589,
  1615,
  1641,
  1668,
  1695,
];
