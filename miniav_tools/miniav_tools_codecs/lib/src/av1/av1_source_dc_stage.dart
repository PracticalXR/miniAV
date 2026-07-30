/// GPU stage: per-4×4-block source plane means (DCs) for Y, U, V.
///
/// Input  : [kYuv420Key] — planar YUV420 floats (Y plane W*H, then U, then V).
/// Output : [kSourceDcKey] — one f32 per 4×4 block in raster order:
///            [0                          .. numLuma)            → Y DCs
///            [numLuma                    .. numLuma + numUv)    → U DCs
///            [numLuma + numUv            .. numLuma + 2*numUv)  → V DCs
///          Each value is the rounded mean of the 16 source samples in
///          that block, in the same [0..255] integer domain the CPU
///          encoder uses (matching `_sourceDc4x4`'s `(sum + 8) >> 4`).
///
/// All plane dimensions must be multiples of 4 (the encoder already
/// requires multiples of 64 at the frame level, so this is implied).
library;

import 'package:gpu_pipeline/gpu_pipeline.dart';
import 'av1_yuv420_stage.dart' show Yuv420Layout, kYuv420Key;

const String kSourceDcKey = 'av1_source_dcs';

/// Total number of f32 DCs the [buildSourceDcStage] output holds for the
/// given frame dimensions.
int sourceDcCount(int width, int height) {
  final layout = Yuv420Layout(width, height);
  final numLuma = (width >> 2) * (height >> 2);
  final numUv = (layout.uvWidth >> 2) * (layout.uvHeight >> 2);
  return numLuma + 2 * numUv;
}

PipelineStage buildSourceDcStage({
  required int width,
  required int height,
  String inputKey = kYuv420Key,
  String outputKey = kSourceDcKey,
}) {
  assert(
    width % 4 == 0 && height % 4 == 0,
    'source-DC stage requires multiple-of-4 dims; got ${width}x$height',
  );

  final layout = Yuv420Layout(width, height);
  final bw = width >> 2;
  final bh = height >> 2;
  final numLuma = bw * bh;
  final uvW = layout.uvWidth;
  final uvH = layout.uvHeight;
  final uvBw = uvW >> 2;
  final uvBh = uvH >> 2;
  final numUv = uvBw * uvBh;
  final totalDcs = numLuma + 2 * numUv;

  // 1 thread per output block (all 3 planes treated uniformly via
  // dispatch index range).
  final wgsl =
      '''
@group(0) @binding(0) var<storage, read_write> yuv: array<f32>;
@group(0) @binding(1) var<storage, read_write> out: array<f32>;

const W:        u32 = ${width}u;
const H:        u32 = ${height}u;
const UV_W:     u32 = ${uvW}u;
const Y_SIZE:   u32 = ${layout.ySize}u;
const UV_SIZE:  u32 = ${layout.uvSize}u;
const NUM_LUMA: u32 = ${numLuma}u;
const NUM_UV:   u32 = ${numUv}u;
const BW:       u32 = ${bw}u;
const UV_BW:    u32 = ${uvBw}u;
const TOTAL:    u32 = ${totalDcs}u;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i: u32 = gid.x;
  if (i >= TOTAL) { return; }

  var base: u32;
  var stride: u32;
  var bx: u32;
  var by: u32;

  if (i < NUM_LUMA) {
    base   = 0u;
    stride = W;
    bx = i % BW;
    by = i / BW;
  } else if (i < NUM_LUMA + NUM_UV) {
    let j = i - NUM_LUMA;
    base   = Y_SIZE;
    stride = UV_W;
    bx = j % UV_BW;
    by = j / UV_BW;
  } else {
    let j = i - NUM_LUMA - NUM_UV;
    base   = Y_SIZE + UV_SIZE;
    stride = UV_W;
    bx = j % UV_BW;
    by = j / UV_BW;
  }

  let px: u32 = bx * 4u;
  let py: u32 = by * 4u;
  var sum: f32 = 0.0;
  for (var r: u32 = 0u; r < 4u; r = r + 1u) {
    let row = base + (py + r) * stride + px;
    sum = sum + yuv[row + 0u] + yuv[row + 1u] + yuv[row + 2u] + yuv[row + 3u];
  }
  // Match CPU `(sum + 8) >> 4` rounding: floor((sum + 8) / 16).
  // YUV samples are integer-valued f32 → sum is integer-valued, so
  // floor((sum + 8) * (1/16)) is exact.
  out[i] = floor((sum + 8.0) * 0.0625);
}
''';

  return StageBuilder('av1_source_dc')
      .withFlexibleInput(inputKey)
      .withFixedOutput(outputKey, shape: [totalDcs])
      .executeShader(
        wgsl,
        inputKeys: [inputKey],
        outputKeys: [outputKey],
        workgroupSize: const [64],
      )
      .build();
}
