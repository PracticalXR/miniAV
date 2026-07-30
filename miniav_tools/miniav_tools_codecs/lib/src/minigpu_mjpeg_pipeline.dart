/// MJPEG instance of the universal [GpuCodecPipeline].
///
/// Fully GPU-accelerated pipeline:
///
///   Stage 1 GPU  : RGBA float [H,W,4]     → YCbCr float [H,W,3]
///   Stage 2 GPU  : YCbCr [H,W,3]          → DCT coeffs [numBlocks*3*64]
///   Stage 3 GPU  : DCT [numBlocks*3*64]   → quantized+zigzagged [numBlocks*3*64]
///   Stage 4 GPU* : quantized [numBlocks*3*64] → Huffman bytes [numMcus*(stride+1)]
///                  (*custom PipelineStage, @workgroup_size(1) per MCU)
///   Stage 5 CPU  : JFIF header + scan-data assembly (lightweight)
///
/// With restart markers (DRI=1 MCU), every MCU resets DC prediction to 0,
/// making Stage 4 fully parallel across all MCUs with no inter-thread deps.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:gpu_pipeline/gpu_pipeline.dart';
// ignore: implementation_imports
import 'package:gpu_pipeline/src/pipeline_ports.dart'
    show FlexibleInputPort, FixedOutputPort;
import 'package:gpu_tensor/gpu_tensor.dart' show Tensor, DefaultMinigpu;
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:minigpu/minigpu.dart' show ComputeShader;
import 'package:minigpu_platform_interface/minigpu_platform_interface.dart'
    show BufferDataType;

import 'gpu_codec_pipeline.dart';
import 'jpeg_encoder.dart';

/// MJPEG via the GPU codec pipeline abstraction.
class MinigpuMjpegPipeline extends GpuCodecPipeline {
  MinigpuMjpegPipeline({required EncoderConfig config}) : super(config: config);

  /// JPEG quality 1..100. Mapped from `crfQuality` if provided (CRF 18 → q90,
  /// CRF 23 → q85, CRF 28 → q75, …); otherwise defaults to 75.
  int get _quality {
    final crf = config.crfQuality;
    if (crf == null) return 75;
    final q = (100 - (crf * 100 / 51)).round().clamp(1, 100);
    return q;
  }

  // Padded dimensions (round up to 8) so every block is fully covered.
  int get _paddedW => (config.width + 7) & ~7;
  int get _paddedH => (config.height + 7) & ~7;
  int get _blocksX => _paddedW >> 3;
  int get _blocksY => _paddedH >> 3;
  int get _numBlocks => _blocksX * _blocksY;
  int get _numMcus => _numBlocks; // 4:4:4: 1 MCU = 1 block per channel
  static const int _huffStride = 1024; // generous max bytes per 4:4:4 MCU

  @override
  bool isKeyframe(int frameIndex) => true; // MJPEG = all intra.

  @override
  Future<Pipeline> buildPipeline() async {
    final p = Pipeline(id: 'minigpu_mjpeg_${config.width}x${config.height}');

    p.addStage(_buildRgbaToYcbcrStage());
    p.addStage(_buildFdctStage());
    p.addStage(_buildQuantizeZigzagStage(_quality));
    p.addStage(
      _HuffmanVlcStage(
        stageId: 'huffman_vlc',
        numMcus: _numMcus,
        stride: _huffStride,
      ),
    );
    p.addStage(_buildJfifAssemblyStage());

    await p.start();
    return p;
  }

  // ---------------------------------------------------------------------------
  // Stage 1: RGBA → YCbCr (GPU shader).
  // ---------------------------------------------------------------------------

  PipelineStage _buildRgbaToYcbcrStage() {
    // BT.601 full-range RGB→YCbCr. Inputs in [0,255] → outputs in [0,255].
    // Per-pixel work; one workgroup-thread per pixel.
    //
    // Layout:
    //   input  shape [H, W, 4]  (RGBA, float)   → length = H*W*4
    //   output shape [H, W, 3]  (Y,Cb,Cr float) → length = H*W*3
    //
    // We dispatch one thread per pixel. executeShader folds the workgroup count
    // into a 2D (x,y) grid when it exceeds WebGPU's 65535/dim cap (large frames
    // like 5120x1440), so the flat pixel index must include the Y row:
    //   pixel = gid.x + gid.y * (num_workgroups.x * 64).
    // For frames that fit a 1D dispatch, gid.y==0 and this equals gid.x.
    // The auto-generated bindings provide:
    //   @group(0) @binding(0) input_0:  array<f32>
    //   @group(0) @binding(1) output_0: array<f32>
    final wgsl =
        '''
@group(0) @binding(0) var<storage, read_write> input_0: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_0: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>,
        @builtin(num_workgroups) nwg: vec3<u32>) {
  let pixel = gid.x + gid.y * (nwg.x * 64u);
  let total: u32 = ${config.width * config.height}u;
  if (pixel >= total) { return; }

  let i_in: u32  = pixel * 4u;
  let i_out: u32 = pixel * 3u;

  let r = input_0[i_in + 0u];
  let g = input_0[i_in + 1u];
  let b = input_0[i_in + 2u];

  let y_:  f32 =          0.299    * r + 0.587    * g + 0.114    * b;
  let cb:  f32 = 128.0 + (-0.168736 * r - 0.331264 * g + 0.5      * b);
  let cr:  f32 = 128.0 + ( 0.5      * r - 0.418688 * g - 0.081312 * b);

  output_0[i_out + 0u] = y_;
  output_0[i_out + 1u] = cb;
  output_0[i_out + 2u] = cr;
}
''';

    return StageBuilder('rgba_to_ycbcr')
        .withFlexibleInput(kFrameInputKey)
        .withFixedOutput('ycbcr', shape: [config.height, config.width, 3])
        .executeShader(
          wgsl,
          inputKeys: const [kFrameInputKey],
          outputKeys: const ['ycbcr'],
          workgroupSize: const [64],
        )
        .build();
  }

  // ---------------------------------------------------------------------------
  // Stage 2: forward 8×8 DCT (GPU shader, separable AAN-style direct DCT).
  //
  // Layout:
  //   input  ycbcr  shape [H, W, 3]                (YCbCr float [0,255])
  //   output dct    shape [numBlocks, 3, 64]       (raw DCT coeffs, natural)
  //
  // Dispatch: one workgroup per (block, channel) tuple = numBlocks*3 groups
  // of 64 threads. Each thread computes one DCT coefficient via the
  // precomputed COEFF table. Two-pass via `var<workgroup> wg[64]`.
  // ---------------------------------------------------------------------------
  PipelineStage _buildFdctStage() {
    final w = config.width;
    final h = config.height;
    final bx = _blocksX;
    final numBlocks = _numBlocks;

    // DCT-II coefficients (k,n) = 0.5 * Ck * cos((2n+1)*k*pi/16)
    // Stored as COEFF[k*8+n].
    const coeff = '''
const COEFF: array<f32, 64> = array<f32, 64>(
  0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339,
  0.49039264, 0.41573481, 0.27778512, 0.09754516, -0.09754516, -0.27778512, -0.41573481, -0.49039264,
  0.46193977, 0.19134172, -0.19134172, -0.46193977, -0.46193977, -0.19134172, 0.19134172, 0.46193977,
  0.41573481, -0.09754516, -0.49039264, -0.27778512, 0.27778512, 0.49039264, 0.09754516, -0.41573481,
  0.35355339, -0.35355339, -0.35355339, 0.35355339, 0.35355339, -0.35355339, -0.35355339, 0.35355339,
  0.27778512, -0.49039264, 0.09754516, 0.41573481, -0.41573481, -0.09754516, 0.49039264, -0.27778512,
  0.19134172, -0.46193977, 0.46193977, -0.19134172, -0.19134172, 0.46193977, -0.46193977, 0.19134172,
  0.09754516, -0.27778512, 0.41573481, -0.49039264, 0.49039264, -0.41573481, 0.27778512, -0.09754516,
);
''';

    final wgsl =
        '''
@group(0) @binding(0) var<storage, read_write> input_0: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_0: array<f32>;

$coeff

var<workgroup> tile: array<f32, 64>;
var<workgroup> tmp:  array<f32, 64>;

@compute @workgroup_size(64)
fn main(
  @builtin(workgroup_id) wid: vec3<u32>,
  @builtin(num_workgroups) nwg: vec3<u32>,
  @builtin(local_invocation_id) lid: vec3<u32>,
) {
  // One workgroup per (block,channel). executeShader folds the group count into
  // a 2D grid above 65535 groups (large frames), so reconstruct the flat group
  // index from the 2D workgroup id. The guard drops the padding groups the 2D
  // round-up adds; wid is uniform across the workgroup so this early return is
  // barrier-safe (all 64 threads take it or none do).
  let group_idx: u32 = wid.x + wid.y * nwg.x;
  if (group_idx >= ${numBlocks * 3}u) { return; }
  // channel = group_idx % 3, block = group_idx / 3.
  let chan: u32   = group_idx % 3u;
  let block: u32  = group_idx / 3u;
  let bx:    u32  = block % ${bx}u;
  let by:    u32  = block / ${bx}u;
  let x0:    u32  = bx * 8u;
  let y0:    u32  = by * 8u;

  let li: u32 = lid.x;        // [0, 64)
  let py: u32 = li / 8u;      // pixel row inside block
  let px: u32 = li % 8u;      // pixel col inside block

  // 1. Load with edge-clamp + level shift (subtract 128).
  var sx: u32 = x0 + px;
  var sy: u32 = y0 + py;
  if (sx >= ${w}u) { sx = ${w}u - 1u; }
  if (sy >= ${h}u) { sy = ${h}u - 1u; }
  let pixel_idx: u32 = (sy * ${w}u + sx) * 3u + chan;
  tile[li] = input_0[pixel_idx] - 128.0;

  workgroupBarrier();

  // 2. Horizontal pass: tmp[ty,u] = sum_x tile[ty,x] * COEFF[u*8+x]
  let ty: u32 = py;
  let u_h: u32 = px;
  var hsum: f32 = 0.0;
  for (var x: u32 = 0u; x < 8u; x = x + 1u) {
    hsum = hsum + tile[ty * 8u + x] * COEFF[u_h * 8u + x];
  }
  tmp[ty * 8u + u_h] = hsum;

  workgroupBarrier();

  // 3. Vertical pass: out[v,u] = sum_y tmp[y,u] * COEFF[v*8+y]
  let v_v: u32 = py;
  let u_v: u32 = px;
  var vsum: f32 = 0.0;
  for (var y: u32 = 0u; y < 8u; y = y + 1u) {
    vsum = vsum + tmp[y * 8u + u_v] * COEFF[v_v * 8u + y];
  }

  // Write coefficient at natural-order index v*8+u.
  let out_block_off: u32 = (block * 3u + chan) * 64u;
  output_0[out_block_off + v_v * 8u + u_v] = vsum;
}
''';
    return StageBuilder('fdct_8x8')
        .withFlexibleInput('ycbcr')
        .withFixedOutput('dct', shape: [numBlocks, 3, 64])
        .executeShader(
          wgsl,
          inputKeys: const ['ycbcr'],
          outputKeys: const ['dct'],
          workgroupSize: const [64],
        )
        .build();
  }

  // ---------------------------------------------------------------------------
  // Stage 3: quantization + zigzag reorder (GPU shader).
  //
  //   input  dct shape [numBlocks, 3, 64]   (natural-order DCT coeffs)
  //   output qz  shape [numBlocks, 3, 64]   (quantized + zigzagged ints)
  //
  // Dispatch: one workgroup per (block, channel), 64 threads, each emits one
  // zigzag-position coefficient.
  // ---------------------------------------------------------------------------
  PipelineStage _buildQuantizeZigzagStage(int quality) {
    final qY = JpegStandardTables.lumaQt(quality);
    final qC = JpegStandardTables.chromaQt(quality);
    final numBlocks = _numBlocks;

    String _arr(List<int> a) => a.join(', ');

    // Zigzag[i] = natural-order index that goes to zigzag position i.
    const zigzag = [
      0, 1, 8, 16, 9, 2, 3, 10, //
      17, 24, 32, 25, 18, 11, 4, 5,
      12, 19, 26, 33, 40, 48, 41, 34,
      27, 20, 13, 6, 7, 14, 21, 28,
      35, 42, 49, 56, 57, 50, 43, 36,
      29, 22, 15, 23, 30, 37, 44, 51,
      58, 59, 52, 45, 38, 31, 39, 46,
      53, 60, 61, 54, 47, 55, 62, 63,
    ];

    final wgsl =
        '''
@group(0) @binding(0) var<storage, read_write> input_0: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_0: array<f32>;

const QY: array<f32, 64> = array<f32, 64>(${qY.map((v) => v.toDouble().toStringAsFixed(1)).join(', ')});
const QC: array<f32, 64> = array<f32, 64>(${qC.map((v) => v.toDouble().toStringAsFixed(1)).join(', ')});
const ZIG: array<u32, 64> = array<u32, 64>(${_arr(zigzag)}u);

@compute @workgroup_size(64)
fn main(
  @builtin(workgroup_id) wid: vec3<u32>,
  @builtin(num_workgroups) nwg: vec3<u32>,
  @builtin(local_invocation_id) lid: vec3<u32>,
) {
  // One workgroup per (block,channel); flat index from the 2D grid executeShader
  // uses above 65535 groups (large frames), bounded against the 2D round-up pad.
  let group_idx: u32 = wid.x + wid.y * nwg.x;
  if (group_idx >= ${numBlocks * 3}u) { return; }
  let chan: u32  = group_idx % 3u;
  let block: u32 = group_idx / 3u;
  let li: u32    = lid.x;

  let base: u32 = (block * 3u + chan) * 64u;

  // Read natural-order index that ZIG maps zigzag-position `li` to.
  let nat: u32 = ZIG[li];
  let coef: f32 = input_0[base + nat];
  var q: f32;
  if (chan == 0u) { q = QY[nat]; } else { q = QC[nat]; }
  let v: f32 = coef / q;
  // Round to nearest int (banker's-style not needed; JPEG decoders cope).
  var iv: f32;
  if (v >= 0.0) { iv = floor(v + 0.5); } else { iv = -floor(-v + 0.5); }
  output_0[base + li] = iv;
}
''';

    return StageBuilder('quantize_zigzag')
        .withFlexibleInput('dct')
        .withFixedOutput('qz', shape: [numBlocks, 3, 64])
        .executeShader(
          wgsl,
          inputKeys: const ['dct'],
          outputKeys: const ['qz'],
          workgroupSize: const [64],
        )
        .build();
  }

  // ---------------------------------------------------------------------------
  // Stage 5: lightweight CPU JFIF assembly.
  //
  //   input  huff_raw shape [numMcus, stride+1]  (size byte + payload bytes)
  //   output encoded  Uint8List bytes (full JFIF stream)
  //
  // Each row = [ size_lo, size_hi, b0, b1, ..., b(stride-1) ].
  // (Sizes encoded as two f32s for portability.)
  // ---------------------------------------------------------------------------
  PipelineStage _buildJfifAssemblyStage() {
    final width = config.width;
    final height = config.height;
    final quality = _quality;
    final numMcus = _numMcus;
    final stride = _huffStride;

    Future<Map<String, TypedData>> processor(
      Map<String, TypedData> inputs,
      Map<String, List<int>> ranks,
      Map<String, dynamic> parameters,
    ) async {
      final huff = inputs['huff_raw'];
      if (huff is! Float32List) {
        throw CodecRuntimeException(
          'minigpu',
          'jfif assembly: expected Float32List huff_raw, got '
              '${huff.runtimeType}',
        );
      }
      final rowLen = stride + 2;
      if (huff.length != numMcus * rowLen) {
        throw CodecRuntimeException(
          'minigpu',
          'jfif assembly: huff_raw length ${huff.length} != '
              '${numMcus * rowLen}',
        );
      }

      final header = encodeJpegHeader(
        width: width,
        height: height,
        quality: quality,
        rstInterval: 1,
      );
      final out = BytesBuilder();
      out.add(header);

      var rstCounter = 0;
      for (var m = 0; m < numMcus; m++) {
        final base = m * rowLen;
        final lo = huff[base + 0].round() & 0xff;
        final hi = huff[base + 1].round() & 0xff;
        final size = (hi << 8) | lo;
        if (size < 0 || size > stride) {
          throw CodecRuntimeException(
            'minigpu',
            'jfif assembly: MCU $m bad size $size (stride=$stride)',
          );
        }
        final mcuBytes = Uint8List(size);
        for (var i = 0; i < size; i++) {
          mcuBytes[i] = huff[base + 2 + i].round() & 0xff;
        }
        out.add(mcuBytes);
        // RST marker between MCUs (not after the last one).
        if (m + 1 < numMcus) {
          out.addByte(0xFF);
          out.addByte(0xD0 + rstCounter);
          rstCounter = (rstCounter + 1) & 0x7;
        }
      }

      // EOI
      out.addByte(0xFF);
      out.addByte(0xD9);

      return {kEncodedOutputKey: out.toBytes()};
    }

    return StageBuilder('jfif_assembly')
        .withFlexibleInput('huff_raw')
        .withDynamicOutput(kEncodedOutputKey)
        .executeCPU(
          processor,
          inputKey: 'huff_raw',
          outputKey: kEncodedOutputKey,
        )
        .build();
  }
}

// =============================================================================
// Custom Huffman VLC stage.
//
// The standard `executeShader` path dispatches based on the output tensor
// length / workgroupSize. For Huffman we need exactly `numMcus` workgroups
// (one per MCU), but the output is `numMcus * (stride + 2)` floats — so we
// implement a true PipelineStage subclass that drives the GPU directly.
//
// With JPEG restart markers (DRI=1), every MCU resets DC prediction to 0,
// so encoding is trivially parallel across MCUs — no atomics, no barriers,
// no inter-thread dependencies.
// =============================================================================

class _HuffmanVlcStage extends PipelineStage {
  _HuffmanVlcStage({
    required String stageId,
    required this.numMcus,
    required this.stride,
  }) : super(stageId: stageId) {
    addInputPort(FlexibleInputPort(name: 'qz', description: 'quantized DCT'));
    addOutputPort(
      FixedOutputPort(
        name: 'huff_raw',
        shape: [numMcus, stride + 2],
        description: 'per-MCU [size_lo, size_hi, byte0..byte(stride-1)]',
      ),
    );
  }

  final int numMcus;
  final int stride;

  ComputeShader? _shader;

  String _wgsl() {
    final dcLumCode = JpegStandardTables.dcLumaCode;
    final dcLumLen = JpegStandardTables.dcLumaLen;
    final dcChrCode = JpegStandardTables.dcChromaCode;
    final dcChrLen = JpegStandardTables.dcChromaLen;
    final acLumCode = JpegStandardTables.acLumaCode;
    final acLumLen = JpegStandardTables.acLumaLen;
    final acChrCode = JpegStandardTables.acChromaCode;
    final acChrLen = JpegStandardTables.acChromaLen;

    String _u32arr(String name, List<int> vals, int len) {
      final s = List.generate(len, (i) => '${vals[i]}u').join(', ');
      return 'const $name: array<u32, $len> = array<u32, $len>($s);';
    }

    return '''
@group(0) @binding(0) var<storage, read_write> input_0:  array<f32>;
@group(0) @binding(1) var<storage, read_write> output_0: array<f32>;

${_u32arr('DC_L_CODE', dcLumCode, 16)}
${_u32arr('DC_L_LEN', dcLumLen, 16)}
${_u32arr('DC_C_CODE', dcChrCode, 16)}
${_u32arr('DC_C_LEN', dcChrLen, 16)}
${_u32arr('AC_L_CODE', acLumCode, 256)}
${_u32arr('AC_L_LEN', acLumLen, 256)}
${_u32arr('AC_C_CODE', acChrCode, 256)}
${_u32arr('AC_C_LEN', acChrLen, 256)}

const STRIDE: u32 = ${stride}u;
const ROWLEN: u32 = ${stride + 2}u;
const NUM_MCUS: u32 = ${numMcus}u;

// Per-thread bit/byte writer state.
var<private> g_buf: u32;
var<private> g_cnt: u32;     // bits in g_buf
var<private> g_pos: u32;     // bytes written to MCU payload
var<private> g_base: u32;    // byte-offset in output_0 of MCU's first payload byte

fn put_byte(b: u32) {
  if (g_pos < STRIDE) {
    output_0[g_base + g_pos] = f32(b & 0xffu);
    g_pos = g_pos + 1u;
    if ((b & 0xffu) == 0xffu) {
      if (g_pos < STRIDE) {
        output_0[g_base + g_pos] = 0.0;
        g_pos = g_pos + 1u;
      }
    }
  }
}

fn put_bits(code: u32, len: u32) {
  if (len == 0u) { return; }
  // Append `len` low-bits of `code` (MSB-first) to g_buf.
  g_buf = (g_buf << len) | (code & ((1u << len) - 1u));
  g_cnt = g_cnt + len;
  loop {
    if (g_cnt < 8u) { break; }
    g_cnt = g_cnt - 8u;
    let b: u32 = (g_buf >> g_cnt) & 0xffu;
    put_byte(b);
  }
}

fn flush_pad() {
  if (g_cnt > 0u) {
    let pad: u32 = 8u - g_cnt;
    g_buf = (g_buf << pad) | ((1u << pad) - 1u);
    g_cnt = 0u;
    put_byte(g_buf & 0xffu);
  }
}

// Number of bits needed to represent absolute value of v (0..2047 for JPEG
// baseline DC/AC magnitudes).
fn bit_size(v: i32) -> u32 {
  var x: u32 = u32(abs(v));
  var n: u32 = 0u;
  loop {
    if (x == 0u) { break; }
    x = x >> 1u;
    n = n + 1u;
  }
  return n;
}

// JPEG signed amplitude encoding: negatives → ones-complement of |v|.
fn signed_bits(v: i32, sz: u32) -> u32 {
  let mask: u32 = (1u << sz) - 1u;
  if (v >= 0) {
    return u32(v) & mask;
  } else {
    // v < 0: encoded value = v + (2^sz) - 1
    let enc: i32 = v + i32(mask);
    return u32(enc) & mask;
  }
}

fn encode_block(qz_base: u32, is_chroma: bool) {
  // DC: full value (DC_prev = 0 due to RST every MCU).
  let dc: i32 = i32(input_0[qz_base + 0u]);
  let ds: u32 = bit_size(dc);
  if (is_chroma) {
    put_bits(DC_C_CODE[ds], DC_C_LEN[ds]);
  } else {
    put_bits(DC_L_CODE[ds], DC_L_LEN[ds]);
  }
  if (ds > 0u) {
    put_bits(signed_bits(dc, ds), ds);
  }

  // AC: zigzag positions 1..63, run-length of zeros + (size, amplitude).
  var run: u32 = 0u;
  for (var k: u32 = 1u; k < 64u; k = k + 1u) {
    let c: i32 = i32(input_0[qz_base + k]);
    if (c == 0) {
      run = run + 1u;
      continue;
    }
    loop {
      if (run < 16u) { break; }
      // ZRL = 0xF0
      if (is_chroma) {
        put_bits(AC_C_CODE[0xF0u], AC_C_LEN[0xF0u]);
      } else {
        put_bits(AC_L_CODE[0xF0u], AC_L_LEN[0xF0u]);
      }
      run = run - 16u;
    }
    let cs: u32 = bit_size(c);
    let sym: u32 = (run << 4u) | cs;
    if (is_chroma) {
      put_bits(AC_C_CODE[sym], AC_C_LEN[sym]);
    } else {
      put_bits(AC_L_CODE[sym], AC_L_LEN[sym]);
    }
    put_bits(signed_bits(c, cs), cs);
    run = 0u;
  }
  if (run > 0u) {
    // EOB = 0x00
    if (is_chroma) {
      put_bits(AC_C_CODE[0u], AC_C_LEN[0u]);
    } else {
      put_bits(AC_L_CODE[0u], AC_L_LEN[0u]);
    }
  }
}

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>,
        @builtin(num_workgroups) nwg: vec3<u32>) {
  // MCU count can exceed WebGPU's 65535/dim dispatch cap on large frames
  // (5120x1440 -> 115200 MCUs), so process() folds the dispatch into a 2D grid;
  // reconstruct the flat MCU index. For small frames gid.y==0 -> mcu==gid.x.
  let mcu: u32 = gid.x + gid.y * nwg.x;
  if (mcu >= NUM_MCUS) { return; }

  // Each MCU = 1 Y block, 1 Cb block, 1 Cr block.
  let qz_off: u32 = mcu * 3u * 64u;

  // Reset per-MCU writer state.
  g_buf = 0u;
  g_cnt = 0u;
  g_pos = 0u;
  // Output row layout: [size_lo, size_hi, byte0..byte(stride-1)].
  let row_off: u32 = mcu * ROWLEN;
  g_base = row_off + 2u;

  encode_block(qz_off + 0u * 64u, false); // Y
  encode_block(qz_off + 1u * 64u, true);  // Cb
  encode_block(qz_off + 2u * 64u, true);  // Cr

  flush_pad();

  // Write the byte count into the row header.
  output_0[row_off + 0u] = f32(g_pos & 0xffu);
  output_0[row_off + 1u] = f32((g_pos >> 8u) & 0xffu);
}
''';
  }

  @override
  Future<void> initializeStage() async {
    final mg = DefaultMinigpu.instance;
    if (!mg.isInitialized) {
      await mg.init();
    }
    _shader = mg.createComputeShader();
    _shader!.loadKernelString(_wgsl());
  }

  @override
  Future<void> dispose() async {
    _shader?.destroy();
    _shader = null;
  }

  @override
  Future<Map<String, Tensor>> process(Map<String, Tensor> inputs) async {
    final qz = inputs['qz'];
    if (qz == null) {
      throw StateError('huffman_vlc: missing input "qz"');
    }
    final out = await Tensor.create<Float32List>([
      numMcus,
      stride + 2,
    ], dataType: BufferDataType.float32);
    final shader = _shader!;
    shader.setBuffer('input_0', qz.buffer);
    shader.setBuffer('output_0', out.buffer);
    // Fold the per-MCU dispatch into a 2D grid so it never exceeds WebGPU's
    // 65535-per-dimension cap (5120x1440 -> 115200 MCUs). The shader
    // reconstructs the flat MCU index from (gid.x, gid.y). <=65535 -> gy==1.
    final gx = numMcus <= 65535 ? numMcus : 65535;
    final gy = (numMcus + gx - 1) ~/ gx;
    await shader.dispatch(gx == 0 ? 1 : gx, gy == 0 ? 1 : gy, 1);
    return {'huff_raw': out};
  }
}
