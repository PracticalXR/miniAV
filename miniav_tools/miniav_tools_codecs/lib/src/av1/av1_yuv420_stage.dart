/// BGRA / RGBA → planar YUV420 GPU stage.
///
/// Output layout (single flat buffer):
///
///   [ Y plane:  width * height floats ]
///   [ U plane:  (width/2) * (height/2) floats ]
///   [ V plane:  (width/2) * (height/2) floats ]
///
/// Width and height must be even (the chroma decimation assumes 2x2 blocks).
/// Values are BT.709 *limited* range (Y in [16,235], C in [16,240]) to match
/// what we advertise in the sequence header (`color_range = 0` = studio).
///
/// The conversion runs as a single compute shader: one thread per *chroma*
/// pixel. Each thread reads a 2x2 luma block, writes all four Y samples,
/// averages the RGB, and writes one U + one V sample. Dispatch count is
/// `(width/2) * (height/2) / 64` workgroups (rounded up).
library;

import 'package:gpu_pipeline/gpu_pipeline.dart';

import '../gpu_codec_pipeline.dart' show kFrameInputKey;

/// Output tensor key.
const String kYuv420Key = 'yuv420_planar';

/// Pre-computed sizes for a given resolution.
class Yuv420Layout {
  Yuv420Layout(int width, int height)
    : assert(width > 0 && height > 0),
      width = width,
      height = height,
      uvWidth = width ~/ 2,
      uvHeight = height ~/ 2,
      ySize = width * height,
      uvSize = (width ~/ 2) * (height ~/ 2),
      totalFloats = width * height + 2 * ((width ~/ 2) * (height ~/ 2));

  final int width;
  final int height;
  final int uvWidth;
  final int uvHeight;
  final int ySize;
  final int uvSize;
  final int totalFloats;

  /// Byte offset of U plane in the planar buffer.
  int get uOffset => ySize;

  /// Byte offset of V plane in the planar buffer.
  int get vOffset => ySize + uvSize;
}

/// Build the RGBA→YUV420 GPU stage that reads [kFrameInputKey] and writes a
/// planar YUV420 buffer keyed [kYuv420Key].
///
/// If [packedU32] is `false` (default), the input is `array<f32>` with shape
/// `[H, W, 4]` in `[0,255]` — one float per byte.
///
/// If [packedU32] is `true`, the input is `array<u32>` with shape `[H, W]`
/// where each `u32` packs one RGBA pixel in little-endian byte order
/// (R = bits 0..7, A = bits 24..31). The shader uses `unpack4x8unorm` to
/// recover the components in `[0,1]`. This quarters the upload size and
/// removes the per-pixel `u8 → f32` Dart conversion. The encoder adapter
/// will upload this format when `GpuCodecPipeline.acceptsPackedRgba8` is
/// `true`.
PipelineStage buildRgba8ToYuv420Bt709LimitedStage({
  required int width,
  required int height,
  int? srcWidth,
  int? srcHeight,
  String inputKey = kFrameInputKey,
  String outputKey = kYuv420Key,
  bool packedU32 = false,
}) {
  if (width.isOdd || height.isOdd) {
    throw ArgumentError(
      'YUV420 requires even width/height; got ${width}x$height',
    );
  }
  // The *coded* dims (width/height) drive the output grid and must be even
  // (caller passes 64-aligned superblock dims). The *source* dims describe
  // the actual packed-RGBA input buffer stride; when smaller than the coded
  // dims the shader edge-extends (replicates the last row/column), matching
  // the CPU `_padRgbaToCodedDims` semantics so the encoder can consume a
  // display-sized buffer directly without a CPU pad + re-upload.
  final int sw = (srcWidth == null || srcWidth <= 0) ? width : srcWidth;
  final int sh = (srcHeight == null || srcHeight <= 0) ? height : srcHeight;
  final layout = Yuv420Layout(width, height);

  // BT.709 limited (a.k.a. studio swing) RGB→YCbCr.
  //
  // For R,G,B in [0,255]:
  //   Y' = 16  + (219/255) * (0.2126*R + 0.7152*G + 0.0722*B)
  //   Cb = 128 + (224/255) * (-0.1146*R - 0.3854*G + 0.5000*B)
  //   Cr = 128 + (224/255) * ( 0.5000*R - 0.4542*G - 0.0458*B)
  //
  // Folded coefficient table (multiplied by 219/255 or 224/255):
  //   Y':  0.18259 R + 0.61423 G + 0.06201 B + 16
  //   Cb: -0.10068 R - 0.33857 G + 0.43922 B + 128
  //   Cr:  0.43922 R - 0.39895 G - 0.04027 B + 128
  final String inputDecl;
  final String readRgb;
  if (packedU32) {
    inputDecl =
        '@group(0) @binding(0) var<storage, read_write> input_0: array<u32>;';
    // unpack4x8unorm returns components / 255 in [0,1]; multiply by 255 to
    // match the existing coefficient table (which expects [0,255]).
    readRgb = '''
      let sx: u32 = min(x, SRC_W - 1u);
      let sy: u32 = min(y, SRC_H - 1u);
      let px: vec4<f32> = unpack4x8unorm(input_0[sy * SRC_W + sx]) * 255.0;
      let r: f32 = px.x;
      let g: f32 = px.y;
      let b: f32 = px.z;''';
  } else {
    inputDecl =
        '@group(0) @binding(0) var<storage, read_write> input_0: array<f32>;';
    readRgb = '''
      let sx: u32 = min(x, SRC_W - 1u);
      let sy: u32 = min(y, SRC_H - 1u);
      let i: u32 = (sy * SRC_W + sx) * 4u;
      let r: f32 = input_0[i + 0u];
      let g: f32 = input_0[i + 1u];
      let b: f32 = input_0[i + 2u];''';
  }

  final wgsl =
      '''
$inputDecl
@group(0) @binding(1) var<storage, read_write> output_0: array<f32>;

const W: u32 = ${width}u;
const H: u32 = ${height}u;
const SRC_W: u32 = ${sw}u;
const SRC_H: u32 = ${sh}u;
const UV_W: u32 = ${layout.uvWidth}u;
const UV_H: u32 = ${layout.uvHeight}u;
const Y_SIZE: u32 = ${layout.ySize}u;
const UV_SIZE: u32 = ${layout.uvSize}u;

fn rgb_to_y(r: f32, g: f32, b: f32) -> f32 {
  return clamp(16.0 + 0.18259 * r + 0.61423 * g + 0.06201 * b, 0.0, 255.0);
}

fn rgb_to_cb(r: f32, g: f32, b: f32) -> f32 {
  return clamp(128.0 + (-0.10068) * r + (-0.33857) * g + 0.43922 * b, 0.0, 255.0);
}

fn rgb_to_cr(r: f32, g: f32, b: f32) -> f32 {
  return clamp(128.0 + 0.43922 * r + (-0.39895) * g + (-0.04027) * b, 0.0, 255.0);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let uv_idx: u32 = gid.x;
  if (uv_idx >= UV_SIZE) { return; }

  let cx: u32 = uv_idx % UV_W;
  let cy: u32 = uv_idx / UV_W;
  let x0: u32 = cx * 2u;
  let y0: u32 = cy * 2u;

  var r_sum: f32 = 0.0;
  var g_sum: f32 = 0.0;
  var b_sum: f32 = 0.0;

  for (var dy: u32 = 0u; dy < 2u; dy = dy + 1u) {
    for (var dx: u32 = 0u; dx < 2u; dx = dx + 1u) {
      let x: u32 = x0 + dx;
      let y: u32 = y0 + dy;
$readRgb
      r_sum = r_sum + r;
      g_sum = g_sum + g;
      b_sum = b_sum + b;
      output_0[y * W + x] = rgb_to_y(r, g, b);
    }
  }

  let r_avg: f32 = r_sum * 0.25;
  let g_avg: f32 = g_sum * 0.25;
  let b_avg: f32 = b_sum * 0.25;
  output_0[Y_SIZE + uv_idx]            = rgb_to_cb(r_avg, g_avg, b_avg);
  output_0[Y_SIZE + UV_SIZE + uv_idx]  = rgb_to_cr(r_avg, g_avg, b_avg);
}
''';

  return StageBuilder('rgba_to_yuv420_bt709l')
      .withFlexibleInput(inputKey)
      .withFixedOutput(outputKey, shape: [layout.totalFloats])
      .executeShader(
        wgsl,
        inputKeys: [inputKey],
        outputKeys: [outputKey],
        workgroupSize: const [64],
      )
      .build();
}
