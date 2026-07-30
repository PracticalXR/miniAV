/// GPU screen frame processor: optional bilinear downscale + chained effects.
///
/// Handles all per-frame GPU work for a screen source in the zero-copy
/// pipeline:
///
/// ```
/// MiniAVBuffer (D3D11 NT handle)
///   -> importVideoFrame()         VideoTexture  BGRA, srcW x srcH
///   -> VideoTexture.toRGBA()      Buffer        RGBA u32[], srcW x srcH
///   -> [bilinear downscale]       Buffer        RGBA u32[], dstW x dstH  (optional)
///   -> effect[0].apply()          Buffer        RGBA u32[], w0 x h0      (may change dims)
///   -> effect[n].apply()          ...
///   -> SharedOutputTexture.copyFromBuffer
///                                 SharedOutputTexture (RGBA, outputW x outputH)
///   -> D3D11TextureFrameSource -> FfmpegD3d11HwEncoder (zero-copy)
/// ```
library;

import 'dart:ffi' show Pointer;
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:minigpu/minigpu.dart';

import 'gpu_yuv420_converter.dart';
import 'recorder_log.dart';
import 'screen_effect.dart';

// ---------------------------------------------------------------------------
// WGSL bilinear downscale kernel
// ---------------------------------------------------------------------------

const _kDownscaleWgsl = r'''
struct Params {
  srcW     : u32,
  srcH     : u32,
  dstW     : u32,
  dstH     : u32,
};

@group(0) @binding(0) var<storage, read_write> src    : array<u32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

fn unpack_rgba(p : u32) -> vec4<f32> {
  return vec4<f32>(
    f32( p        & 0xFFu),
    f32((p >>  8u) & 0xFFu),
    f32((p >> 16u) & 0xFFu),
    f32((p >> 24u) & 0xFFu),
  ) / 255.0;
}

fn pack_rgba(c : vec4<f32>) -> u32 {
  let q = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0 + vec4<f32>(0.5);
  return  u32(q.x)
       | (u32(q.y) <<  8u)
       | (u32(q.z) << 16u)
       | (u32(q.w) << 24u);
}

fn read_src(x : u32, y : u32) -> vec4<f32> {
  let xx = clamp(x, 0u, params.srcW - 1u);
  let yy = clamp(y, 0u, params.srcH - 1u);
  return unpack_rgba(src[yy * params.srcW + xx]);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.dstW || gid.y >= params.dstH) { return; }

  let scaleX = f32(params.srcW) / f32(params.dstW);
  let scaleY = f32(params.srcH) / f32(params.dstH);
  let sx = (f32(gid.x) + 0.5) * scaleX - 0.5;
  let sy = (f32(gid.y) + 0.5) * scaleY - 0.5;

  let x0 = u32(max(i32(sx), 0));
  let y0 = u32(max(i32(sy), 0));
  let x1 = min(x0 + 1u, params.srcW - 1u);
  let y1 = min(y0 + 1u, params.srcH - 1u);

  let tx = fract(sx);
  let ty = fract(sy);

  let c = mix(mix(read_src(x0, y0), read_src(x1, y0), tx),
              mix(read_src(x0, y1), read_src(x1, y1), tx), ty);
  dst[gid.y * params.dstW + gid.x] = pack_rgba(c);
}
''';

// ---------------------------------------------------------------------------
// WGSL fused BGRA-texture → RGBA bilinear downscale/passthrough kernel
// ---------------------------------------------------------------------------
// Reads the VideoTexture directly via textureLoad (no intermediate toRGBA()
// allocation) and bilinear-samples to the target size in one pass.
// Use for both the downscale case (srcW×srcH → dstW×dstH) and the
// no-downscale case (srcW == dstW: equivalent to a 1:1 texture → buffer copy).
// Bound via tex.setOnShader(shader, 0) + setBufferAtSlot(1/2).
const _kFusedTexDownscaleWgsl = r'''
struct Params {
  srcW : u32,
  srcH : u32,
  dstW : u32,
  dstH : u32,
};

@group(0) @binding(0) var src_tex : texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

fn pack_rgba(c : vec4<f32>) -> u32 {
  let q = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0 + vec4<f32>(0.5);
  return  u32(q.x)
       | (u32(q.y) <<  8u)
       | (u32(q.z) << 16u)
       | (u32(q.w) << 24u);
}

fn read_src(x : u32, y : u32) -> vec4<f32> {
  return textureLoad(src_tex, vec2<i32>(i32(x), i32(y)), 0);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.dstW || gid.y >= params.dstH) { return; }

  let scaleX = f32(params.srcW) / f32(params.dstW);
  let scaleY = f32(params.srcH) / f32(params.dstH);
  let sx = (f32(gid.x) + 0.5) * scaleX - 0.5;
  let sy = (f32(gid.y) + 0.5) * scaleY - 0.5;

  let x0 = u32(max(i32(sx), 0));
  let y0 = u32(max(i32(sy), 0));
  let x1 = min(x0 + 1u, params.srcW - 1u);
  let y1 = min(y0 + 1u, params.srcH - 1u);

  let tx = fract(sx);
  let ty = fract(sy);

  let c = mix(mix(read_src(x0, y0), read_src(x1, y0), tx),
              mix(read_src(x0, y1), read_src(x1, y1), tx), ty);
  dst[gid.y * params.dstW + gid.x] = pack_rgba(c);
}
''';

// ---------------------------------------------------------------------------
// WGSL crop kernel
// ---------------------------------------------------------------------------
// Reads a sub-rectangle from src (srcW×srcH) and writes it to dst (dstW×dstH).
// dstW = cropWidth, dstH = cropHeight.
const _kCropWgsl = r'''
struct Params {
  srcW  : u32,
  srcH  : u32,
  dstW  : u32,
  dstH  : u32,
  cropX : u32,
  cropY : u32,
  _p0   : u32,
  _p1   : u32,
};

@group(0) @binding(0) var<storage, read_write> src    : array<u32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.dstW || gid.y >= params.dstH) { return; }
  let srcX = clamp(gid.x + params.cropX, 0u, params.srcW - 1u);
  let srcY = clamp(gid.y + params.cropY, 0u, params.srcH - 1u);
  dst[gid.y * params.dstW + gid.x] = src[srcY * params.srcW + srcX];
}
''';

// ---------------------------------------------------------------------------
// WGSL flip kernel
// ---------------------------------------------------------------------------
// Mirrors src into dst (same dimensions).  Separate buffers avoid the
// in-place race condition that would occur if threads operated on shared pixels.
const _kFlipWgsl = r'''
struct Params {
  srcW  : u32,
  srcH  : u32,
  flipH : u32,   // 1 = mirror horizontally
  flipV : u32,   // 1 = mirror vertically
};

@group(0) @binding(0) var<storage, read_write> src    : array<u32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.srcW || gid.y >= params.srcH) { return; }
  let srcX = select(gid.x, params.srcW - 1u - gid.x, params.flipH != 0u);
  let srcY = select(gid.y, params.srcH - 1u - gid.y, params.flipV != 0u);
  dst[gid.y * params.srcW + gid.x] = src[srcY * params.srcW + srcX];
}
''';

// ---------------------------------------------------------------------------
// WGSL rotate kernel
// ---------------------------------------------------------------------------
// rotation codes: 1 = 90° CW, 2 = 180°, 3 = 270° CW.
// For 90° / 270°: dstW = srcH, dstH = srcW.
// For 180°:       dstW = srcW, dstH = srcH.
const _kRotateWgsl = r'''
struct Params {
  srcW     : u32,
  srcH     : u32,
  dstW     : u32,
  dstH     : u32,
  rotation : u32,   // 1=90°CW, 2=180°, 3=270°CW
  _p0      : u32,
  _p1      : u32,
  _p2      : u32,
};

@group(0) @binding(0) var<storage, read_write> src    : array<u32>;
@group(0) @binding(1) var<storage, read_write> dst    : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.dstW || gid.y >= params.dstH) { return; }
  var srcX : u32;
  var srcY : u32;
  if (params.rotation == 1u) {
    // 90° CW: dest(x,y) ← src(y, srcH-1-x)
    srcX = gid.y;
    srcY = params.srcH - 1u - gid.x;
  } else if (params.rotation == 2u) {
    // 180°: dest(x,y) ← src(srcW-1-x, srcH-1-y)
    srcX = params.srcW - 1u - gid.x;
    srcY = params.srcH - 1u - gid.y;
  } else {
    // 270° CW: dest(x,y) ← src(srcW-1-y, x)
    srcX = params.srcW - 1u - gid.y;
    srcY = gid.x;
  }
  dst[gid.y * params.dstW + gid.x] = src[srcY * params.srcW + srcX];
}
''';

// ---------------------------------------------------------------------------
// WGSL censor kernel
// ---------------------------------------------------------------------------
// Paints a solid-colour rectangle in-place over [boxX,boxY,boxW,boxH].
// In-place: single read-write pixels buffer; no separate output needed.
const _kCensorWgsl = r'''
struct CensorParams {
  frameW : u32,   // frame width
  frameH : u32,   // frame height
  boxX   : u32,   // box left edge
  boxY   : u32,   // box top edge
  boxW   : u32,   // box width
  boxH   : u32,   // box height
  color  : u32,   // fill color: R | G<<8 | B<<16 | A<<24
  _pad   : u32,
};

@group(0) @binding(0) var<storage, read_write> pixels : array<u32>;
@group(0) @binding(1) var<storage, read_write> params : CensorParams;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.frameW || gid.y >= params.frameH) { return; }
  if (gid.x >= params.boxX && gid.x < params.boxX + params.boxW &&
      gid.y >= params.boxY && gid.y < params.boxY + params.boxH) {
    pixels[gid.y * params.frameW + gid.x] = params.color;
  }
}
''';

// ---------------------------------------------------------------------------
// Abstract effect runtime base
// ---------------------------------------------------------------------------

abstract class _EffectRuntime {
  /// Apply the effect.
  ///
  /// [inBuf] is the current RGBA8 pixel buffer at [inW]×[inH].
  /// In-place effects modify [inBuf] directly. Transform effects write to
  /// their own output buffer; call [outBuf] to get it.
  Future<void> apply(Buffer inBuf, int inW, int inH);

  /// For transform effects: the persistent output buffer (at [outW]×[outH]).
  /// Returns `null` for in-place effects.
  Buffer? get outBuf;
  int? get outW;
  int? get outH;

  void dispose();
}

// ---------------------------------------------------------------------------
// Internal per-effect GPU runtime (in-place WGSL)
// ---------------------------------------------------------------------------

/// Owns the [ComputeShader] + params [Buffer] for one [WgslScreenEffect].
/// Created lazily; reuses params buffer across frames unless dimensions change.
class _GpuEffectRuntime extends _EffectRuntime {
  _GpuEffectRuntime(this._gpu, this._descriptor);

  final Minigpu _gpu;
  final WgslScreenEffect _descriptor;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  int _lastW = -1;
  int _lastH = -1;

  @override
  Buffer? get outBuf => null; // in-place
  @override
  int? get outW => null;
  @override
  int? get outH => null;

  @override
  Future<void> apply(Buffer pixels, int width, int height) async {
    _shader ??= _gpu.createComputeShader()
      ..loadKernelString(_descriptor.wgslSource);

    if (_paramsBuf == null || _lastW != width || _lastH != height) {
      _paramsBuf?.destroy();
      final extras = _descriptor.extraParams;
      // Layout: width(u32) + height(u32) + extraParams(f32 each).
      // Pad to a multiple of 16 bytes for std140 alignment.
      final fieldCount = 2 + extras.length;
      final paddedFields = ((fieldCount + 3) ~/ 4) * 4;
      final byteCount = paddedFields * 4;
      final view = ByteData(byteCount);
      view.setUint32(0, width, Endian.little);
      view.setUint32(4, height, Endian.little);
      for (var i = 0; i < extras.length; i++) {
        view.setFloat32(8 + i * 4, extras[i], Endian.little);
      }
      final buf = _gpu.createBuffer(byteCount, BufferDataType.uint8);
      await buf.write(
        view.buffer.asUint8List(),
        byteCount,
        dataType: BufferDataType.uint8,
      );
      _paramsBuf = buf;
      _lastW = width;
      _lastH = height;
    }

    _shader!.setBufferAtSlot(0, pixels);
    _shader!.setBufferAtSlot(1, _paramsBuf!);

    const kGroup = 8;
    await _shader!.dispatch(
      (width + kGroup - 1) ~/ kGroup,
      (height + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
  }
}

// ---------------------------------------------------------------------------
// Crop effect runtime (transform: separate src → dst buffers)
// ---------------------------------------------------------------------------

/// GPU runtime for [CropScreenEffect]. Reads a sub-rectangle from the input
/// buffer and writes it to a persistent output buffer at the crop dimensions.
class _CropEffectRuntime extends _EffectRuntime {
  _CropEffectRuntime(this._gpu, this._desc, this._inW, this._inH);

  final Minigpu _gpu;
  final CropScreenEffect _desc;
  final int _inW;
  final int _inH;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  Buffer? _outBuf;

  @override
  Buffer? get outBuf => _outBuf;
  @override
  int? get outW => _desc.cropWidth;
  @override
  int? get outH => _desc.cropHeight;

  Future<void> init() async {
    assert(
      _desc.cropX + _desc.cropWidth <= _inW &&
          _desc.cropY + _desc.cropHeight <= _inH,
      'ScreenEffect.crop(${_desc.cropX}, ${_desc.cropY}, '
      '${_desc.cropWidth}, ${_desc.cropHeight}) '
      'falls outside the ${_inW}x${_inH} source frame.',
    );

    _shader = _gpu.createComputeShader()..loadKernelString(_kCropWgsl);

    // Params: srcW, srcH, dstW, dstH, cropX, cropY, _pad0, _pad1 (8×u32 = 32 bytes).
    final view = ByteData(32)
      ..setUint32(0, _inW, Endian.little)
      ..setUint32(4, _inH, Endian.little)
      ..setUint32(8, _desc.cropWidth, Endian.little)
      ..setUint32(12, _desc.cropHeight, Endian.little)
      ..setUint32(16, _desc.cropX, Endian.little)
      ..setUint32(20, _desc.cropY, Endian.little);
    _paramsBuf = _gpu.createBuffer(32, BufferDataType.uint8);
    await _paramsBuf!.write(
      view.buffer.asUint8List(),
      32,
      dataType: BufferDataType.uint8,
    );

    _outBuf = _gpu.createBuffer(
      _desc.cropWidth * _desc.cropHeight * 4,
      BufferDataType.uint8,
    );
  }

  @override
  Future<void> apply(Buffer inBuf, int inW, int inH) async {
    _shader!
      ..setBufferAtSlot(0, inBuf)
      ..setBufferAtSlot(1, _outBuf!)
      ..setBufferAtSlot(2, _paramsBuf!);
    const kGroup = 8;
    await _shader!.dispatch(
      (_desc.cropWidth + kGroup - 1) ~/ kGroup,
      (_desc.cropHeight + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    try {
      _outBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
    _outBuf = null;
  }
}

// ---------------------------------------------------------------------------
// Flip effect runtime (transform: separate src → dst, same dimensions)
// ---------------------------------------------------------------------------

/// GPU runtime for [FlipScreenEffect]. Mirrors into a persistent output buffer
/// to avoid the race condition that would occur with an in-place shader.
class _FlipEffectRuntime extends _EffectRuntime {
  _FlipEffectRuntime(this._gpu, this._desc, this._inW, this._inH);

  final Minigpu _gpu;
  final FlipScreenEffect _desc;
  final int _inW;
  final int _inH;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  Buffer? _outBuf;

  @override
  Buffer? get outBuf => _outBuf;
  @override
  int? get outW => _inW; // same dims
  @override
  int? get outH => _inH;

  Future<void> init() async {
    _shader = _gpu.createComputeShader()..loadKernelString(_kFlipWgsl);

    // Params: srcW, srcH, flipH (0/1), flipV (0/1) — 4×u32 = 16 bytes.
    final view = ByteData(16)
      ..setUint32(0, _inW, Endian.little)
      ..setUint32(4, _inH, Endian.little)
      ..setUint32(8, _desc.horizontal ? 1 : 0, Endian.little)
      ..setUint32(12, _desc.vertical ? 1 : 0, Endian.little);
    _paramsBuf = _gpu.createBuffer(16, BufferDataType.uint8);
    await _paramsBuf!.write(
      view.buffer.asUint8List(),
      16,
      dataType: BufferDataType.uint8,
    );

    _outBuf = _gpu.createBuffer(_inW * _inH * 4, BufferDataType.uint8);
  }

  @override
  Future<void> apply(Buffer inBuf, int inW, int inH) async {
    _shader!
      ..setBufferAtSlot(0, inBuf)
      ..setBufferAtSlot(1, _outBuf!)
      ..setBufferAtSlot(2, _paramsBuf!);
    const kGroup = 8;
    await _shader!.dispatch(
      (_inW + kGroup - 1) ~/ kGroup,
      (_inH + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    try {
      _outBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
    _outBuf = null;
  }
}

// ---------------------------------------------------------------------------
// Rotate effect runtime (transform: separate src → dst, may change dimensions)
// ---------------------------------------------------------------------------

/// GPU runtime for [RotateScreenEffect]. Rotates into a persistent output
/// buffer. 90°/270° rotations produce a buffer with swapped dimensions.
class _RotateEffectRuntime extends _EffectRuntime {
  _RotateEffectRuntime(this._gpu, this._desc, int inW, int inH)
    : _inW = inW,
      _inH = inH {
    final (w, h) = _desc.outputSize(inW, inH);
    _outWidth = w;
    _outHeight = h;
  }

  final Minigpu _gpu;
  final RotateScreenEffect _desc;
  final int _inW;
  final int _inH;

  late final int _outWidth;
  late final int _outHeight;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  Buffer? _outBuf;

  @override
  Buffer? get outBuf => _outBuf;
  @override
  int? get outW => _outWidth;
  @override
  int? get outH => _outHeight;

  Future<void> init() async {
    _shader = _gpu.createComputeShader()..loadKernelString(_kRotateWgsl);

    // rotation encoding: r90=1, r180=2, r270=3
    final rotCode = switch (_desc.rotation) {
      ScreenRotation.r90 => 1,
      ScreenRotation.r180 => 2,
      ScreenRotation.r270 => 3,
    };

    // Params: srcW, srcH, dstW, dstH, rotation, _p0, _p1, _p2 — 8×u32 = 32 bytes.
    final view = ByteData(32)
      ..setUint32(0, _inW, Endian.little)
      ..setUint32(4, _inH, Endian.little)
      ..setUint32(8, _outWidth, Endian.little)
      ..setUint32(12, _outHeight, Endian.little)
      ..setUint32(16, rotCode, Endian.little);
    _paramsBuf = _gpu.createBuffer(32, BufferDataType.uint8);
    await _paramsBuf!.write(
      view.buffer.asUint8List(),
      32,
      dataType: BufferDataType.uint8,
    );

    _outBuf = _gpu.createBuffer(
      _outWidth * _outHeight * 4,
      BufferDataType.uint8,
    );
  }

  @override
  Future<void> apply(Buffer inBuf, int inW, int inH) async {
    _shader!
      ..setBufferAtSlot(0, inBuf)
      ..setBufferAtSlot(1, _outBuf!)
      ..setBufferAtSlot(2, _paramsBuf!);
    const kGroup = 8;
    await _shader!.dispatch(
      (_outWidth + kGroup - 1) ~/ kGroup,
      (_outHeight + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    try {
      _outBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
    _outBuf = null;
  }
}

// ---------------------------------------------------------------------------
// Scale effect runtime (transform: separate src → dst, arbitrary target dims)
// ---------------------------------------------------------------------------

/// GPU runtime for [ScaleScreenEffect]. Uses the same bilinear kernel as the
/// initial downscale step but operates as a mid-chain effect, allowing upscale
/// or downscale to any target size after earlier effects (e.g. crop → scale).
class _ScaleEffectRuntime extends _EffectRuntime {
  _ScaleEffectRuntime(this._gpu, this._desc, this._inW, this._inH);

  final Minigpu _gpu;
  final ScaleScreenEffect _desc;
  final int _inW;
  final int _inH;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  Buffer? _outBuf;

  @override
  Buffer? get outBuf => _outBuf;
  @override
  int? get outW => _desc.width;
  @override
  int? get outH => _desc.height;

  Future<void> init() async {
    // Reuse the bilinear downscale WGSL — it works for up and downscale.
    _shader = _gpu.createComputeShader()..loadKernelString(_kDownscaleWgsl);

    // Params: srcW, srcH, dstW, dstH — 4×u32 = 16 bytes (same as downscale).
    final view = ByteData(16)
      ..setUint32(0, _inW, Endian.little)
      ..setUint32(4, _inH, Endian.little)
      ..setUint32(8, _desc.width, Endian.little)
      ..setUint32(12, _desc.height, Endian.little);
    _paramsBuf = _gpu.createBuffer(16, BufferDataType.uint8);
    await _paramsBuf!.write(
      view.buffer.asUint8List(),
      16,
      dataType: BufferDataType.uint8,
    );

    _outBuf = _gpu.createBuffer(
      _desc.width * _desc.height * 4,
      BufferDataType.uint8,
    );
  }

  @override
  Future<void> apply(Buffer inBuf, int inW, int inH) async {
    _shader!
      ..setBufferAtSlot(0, inBuf)
      ..setBufferAtSlot(1, _outBuf!)
      ..setBufferAtSlot(2, _paramsBuf!);
    const kGroup = 8;
    await _shader!.dispatch(
      (_desc.width + kGroup - 1) ~/ kGroup,
      (_desc.height + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    try {
      _outBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
    _outBuf = null;
  }
}

// ---------------------------------------------------------------------------
// Censor effect runtime (in-place: paints a solid rectangle over the frame)
// ---------------------------------------------------------------------------

/// GPU runtime for [CensorScreenEffect]. Overwrites the censor rectangle with
/// a solid colour in the existing pixel buffer — no extra output allocation.
class _CensorEffectRuntime extends _EffectRuntime {
  _CensorEffectRuntime(this._gpu, this._desc, this._inW, this._inH);

  final Minigpu _gpu;
  final CensorScreenEffect _desc;
  final int _inW;
  final int _inH;

  ComputeShader? _shader;
  Buffer? _paramsBuf;

  @override
  Buffer? get outBuf => null; // in-place

  @override
  int? get outW => null;

  @override
  int? get outH => null;

  Future<void> init() async {
    _shader = _gpu.createComputeShader()..loadKernelString(_kCensorWgsl);

    // Layout: frameW, frameH, boxX, boxY, boxW, boxH, color, _pad — 8×u32 = 32 bytes.
    final view = ByteData(32)
      ..setUint32(0, _inW, Endian.little)
      ..setUint32(4, _inH, Endian.little)
      ..setUint32(8, _desc.boxX, Endian.little)
      ..setUint32(12, _desc.boxY, Endian.little)
      ..setUint32(16, _desc.boxW, Endian.little)
      ..setUint32(20, _desc.boxH, Endian.little)
      ..setUint32(24, _desc.color, Endian.little);
    _paramsBuf = _gpu.createBuffer(32, BufferDataType.uint8);
    await _paramsBuf!.write(
      view.buffer.asUint8List(),
      32,
      dataType: BufferDataType.uint8,
    );
  }

  @override
  Future<void> apply(Buffer inBuf, int inW, int inH) async {
    _shader!
      ..setBufferAtSlot(0, inBuf)
      ..setBufferAtSlot(1, _paramsBuf!);
    const kGroup = 8;
    await _shader!.dispatch(
      (_inW + kGroup - 1) ~/ kGroup,
      (_inH + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  @override
  void dispose() {
    try {
      _shader?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    _shader = null;
    _paramsBuf = null;
  }
}

// ---------------------------------------------------------------------------

/// Owns all GPU resources for processing one screen-capture track per frame.
///
/// Combines optional bilinear downscaling and an ordered chain of
/// [ScreenEffect]s into a single [process] call that returns a
/// [SharedOutputTexture] ready for [FfmpegD3d11HwEncoder].
///
/// Lifecycle: create once per track, call [process] each frame, [dispose] on
/// track teardown.
class GpuScreenProcessor {
  GpuScreenProcessor({
    required Minigpu gpu,
    required this.srcWidth,
    required this.srcHeight,
    required this.dstWidth,
    required this.dstHeight,
    List<ScreenEffect> effects = const [],
    this.sharedRingDepth = 1,
  }) : assert(sharedRingDepth >= 1),
       _gpu = gpu,
       _effectDescriptors = List.unmodifiable(effects) {
    // Initialise the tracked src dims to the initial capture size.
    _currentSrcW = srcWidth;
    _currentSrcH = srcHeight;
    // Pre-compute the final output size by chaining each effect's outputSize().
    var (w, h) = (dstWidth, dstHeight);
    for (final fx in effects) {
      (w, h) = fx.outputSize(w, h);
    }
    outputWidth = w;
    outputHeight = h;
  }

  final Minigpu _gpu;

  /// Full-resolution capture dimensions.
  final int srcWidth;
  final int srcHeight;

  /// Dimensions after the [ScreenScalePolicy] downscale (pre-effects).
  /// Equal to [srcWidth]×[srcHeight] when no scale policy is active.
  final int dstWidth;
  final int dstHeight;

  /// Final output dimensions — after all effects have been applied.
  /// This is the size the encoder and [SharedOutputTexture] are opened at.
  /// Equals [dstWidth]×[dstHeight] when no dimension-changing effects are used.
  late final int outputWidth;
  late final int outputHeight;

  final List<ScreenEffect> _effectDescriptors;

  // _gpuPipelineReady: downscale shader + effect runtimes are set up.
  /// Number of [SharedOutputTexture]s in the output ring. Depth ≥ 2 lets the
  /// recorder pipeline the GPU stage of frame N+1 against the encode of frame
  /// N: [process] rotates through the ring, so the texture being written is
  /// never the one the encoder is still reading. Depth 1 = the classic single
  /// texture (no pipelining).
  final int sharedRingDepth;

  // Separate from _sharedTexReady so processToBytes() can skip the
  // SharedOutputTexture (which requires Dawn D3D12 shared-memory support).
  bool _gpuPipelineReady = false;
  bool _sharedTexReady = false;

  // Fused texture-downscale/passthrough shader + persistent output buffers.
  // Always allocated regardless of whether downscaling is needed; handles
  // both 1:1 passthrough (no scale) and bilinear downscale in one pass.
  ComputeShader? _texDownscaleShader;
  Buffer? _dstBuf; // persistent per-frame output buffer at dstWidth×dstHeight
  Buffer? _paramsBuf; // 16-byte params for the fused kernel

  /// Persistent CPU read-back buffer reused by [processToBytes] so we don't
  /// allocate a fresh `outputWidth*outputHeight*4` byte list (≈8 MB at 1080p)
  /// on every frame. Safe to reuse because the recorder's encode stage is
  /// strictly serialized — the previous frame's bytes are fully consumed by the
  /// encoder before the next [processToBytes] call overwrites them.
  Uint8List? _cpuReadbackBuf;

  /// GPU RGBA→YUV420P converter + reused plane buffers for [processToYuv420].
  /// Same serialized-encode reuse guarantee as [_cpuReadbackBuf].
  GpuYuv420Converter? _yuvConverter;
  Uint8List? _yPlaneBuf;
  Uint8List? _uPlaneBuf;
  Uint8List? _vPlaneBuf;

  // Shared-output ring (see [sharedRingDepth]); [_ringCursor] points at the
  // slot the NEXT process() call will write.
  final List<SharedOutputTexture> _sharedRing = [];
  int _ringCursor = 0;
  final List<_EffectRuntime> _effectRuntimes = [];

  bool _disposed = false;

  // -------------------------------------------------------------------------

  /// Current incoming frame dimensions. Initialised from [srcWidth]/[srcHeight]
  /// and updated whenever a window resize is detected in [process].
  int _currentSrcW = 0;
  int _currentSrcH = 0;

  /// True when the current input frame must be scaled to [dstWidth]×[dstHeight].
  bool get _needsDownscale =>
      _currentSrcW != dstWidth || _currentSrcH != dstHeight;

  /// True when this processor has actual GPU work to do on each frame.
  bool get hasWork =>
      srcWidth != dstWidth ||
      srcHeight != dstHeight ||
      _effectDescriptors.isNotEmpty;

  // -------------------------------------------------------------------------

  /// Process one captured [buffer] (must have `contentType == gpuD3D11Handle`).
  ///
  /// Returns the [SharedOutputTexture] at [outputWidth] x [outputHeight] with
  /// all scaling + effects applied, or `null` on any failure.
  ///
  /// The returned texture is owned by this processor. Do NOT destroy it.
  Future<SharedOutputTexture?> process(MiniAVBuffer buffer) async {
    assert(!_disposed, 'GpuScreenProcessor.process called after dispose()');

    final video = buffer.data;
    if (video is! MiniAVVideoBuffer) return null;
    if (video.nativeHandles.isEmpty || video.nativeHandles[0] == null) {
      return null;
    }
    final _h0a = video.nativeHandles[0];
    final int handleAddr = _h0a is int ? _h0a : (_h0a as Pointer).address;
    if (handleAddr == 0) return null;

    final int stride = video.strideBytes.isNotEmpty
        ? video.strideBytes[0]
        : video.width * 4;

    final extBuf = ExternalVideoBuffer(
      contentType: ExternalContentType.d3d11SharedHandle,
      pixelFormat: ExternalPixelFormat.bgra32,
      width: video.width,
      height: video.height,
      planes: [
        ExternalPlane(
          dataPtr: handleAddr,
          width: video.width,
          height: video.height,
          strideBytes: stride,
        ),
      ],
      fence: ExternalFence(d3d11FencePtr: buffer.nativeFence.d3d11FencePtr),
      timestampUs: buffer.timestampUs,
    );

    VideoTexture? tex;
    try {
      tex = _gpu.importVideoFrame(extBuf);
      if (tex == null) return null;

      await _ensureResources(); // ensures SharedOutputTexture for zero-copy path

      // Detect window resize: if the incoming frame has different dimensions
      // than the last seen frame, update the downscale shader params so we
      // always produce output at the fixed encoder size (outputWidth × outputHeight).
      final int actualW = video.width;
      final int actualH = video.height;
      if (actualW != _currentSrcW || actualH != _currentSrcH) {
        recorderLog(
          RecorderLogSource.recorder,
          RecorderLogLevel.info,
          '[gpu_processor] window resize: ${_currentSrcW}x$_currentSrcH → '
          '${actualW}x$actualH — adapting to encoder '
          '${outputWidth}x$outputHeight',
        );
        _currentSrcW = actualW;
        _currentSrcH = actualH;
        await _updateDownscaleParams();
      }

      // Rotate to the next shared-output slot (see [sharedRingDepth]). With
      // depth ≥ 2 the slot written this frame is never the one the encoder is
      // still reading from the previous frame.
      final slot = _sharedRing[_ringCursor];
      _ringCursor = (_ringCursor + 1) % _sharedRing.length;

      // Fast path: no scale + no effects → native single-pass BGRA→RGBA blit
      // directly into the shared output texture (no intermediate buffer).
      if (!_needsDownscale && _effectRuntimes.isEmpty) {
        // Async blit: the GPU work runs on minigpu's worker thread and we await
        // its completion instead of busy-polling the present-wait on this
        // isolate (the dominant per-frame blocking cost on this path).
        return (await tex.bgraToRgbaSharedOutputAsync(slot)) ? slot : null;
      }

      // 1. Fused BGRA→RGBA + bilinear downscale/passthrough from VideoTexture
      //    directly into the persistent _dstBuf — no per-frame allocation.
      await _runTexDownscale(tex);

      Buffer effectsBuf = _dstBuf!;
      int effectsW = dstWidth;
      int effectsH = dstHeight;

      // 3. Chained effects — each runtime may be in-place or transform.
      // Transform effects (e.g. crop) write to their own persistent output
      // buffer and change the working (effectsBuf, effectsW, effectsH).
      for (final fx in _effectRuntimes) {
        await fx.apply(effectsBuf, effectsW, effectsH);
        final ob = fx.outBuf;
        if (ob != null) {
          effectsBuf = ob; // switch to the transform output buffer
          effectsW = fx.outW!;
          effectsH = fx.outH!;
        }
      }

      // 4. Copy processed buffer -> SharedOutputTexture (GPU blit, no PCIe).
      //    Async: await the GPU copy + present sync on minigpu's worker thread
      //    rather than busy-polling it on this isolate.
      if (!await slot.copyFromBufferAsync(effectsBuf)) return null;
      return slot;
    } catch (e, st) {
      recorderLog(
        RecorderLogSource.recorder,
        RecorderLogLevel.error,
        '[gpu_processor] process error: $e\n$st',
      );
      return null;
    } finally {
      tex?.destroy();
    }
  }

  /// GPU downscale + effects, with result read back to CPU as RGBA8 bytes.
  ///
  /// Use this when a GPU context is available for the downscale step but the
  /// hardware D3D11 encoder is unavailable (e.g. Intel iGPU + NVENC). The GPU
  /// handles the expensive bilinear resize (e.g. 4K→1080p), and the smaller
  /// result is copied to CPU for software or CPU-backed hardware encoding.
  ///
  /// Unlike [process], this path does NOT require a [SharedOutputTexture]
  /// (no Dawn D3D12 shared-memory allocation needed).
  ///
  /// Returns RGBA8 pixels at [outputWidth]×[outputHeight], or `null` on any
  /// failure.
  ///
  /// **Ownership / reuse**: the returned list is owned by this processor and is
  /// REUSED on the next call — callers must fully consume (e.g. copy or encode)
  /// the bytes before invoking any `process*` method again. The recorder's
  /// serialized encode stage guarantees this. Do not free or retain it.
  Future<Uint8List?> processToBytes(MiniAVBuffer buffer) async {
    assert(
      !_disposed,
      'GpuScreenProcessor.processToBytes called after dispose()',
    );

    final video = buffer.data;
    if (video is! MiniAVVideoBuffer) return null;
    if (video.nativeHandles.isEmpty || video.nativeHandles[0] == null) {
      return null;
    }
    final _h0b = video.nativeHandles[0];
    final int handleAddr = _h0b is int ? _h0b : (_h0b as Pointer).address;
    if (handleAddr == 0) return null;

    final int stride = video.strideBytes.isNotEmpty
        ? video.strideBytes[0]
        : video.width * 4;

    final extBuf = ExternalVideoBuffer(
      contentType: ExternalContentType.d3d11SharedHandle,
      pixelFormat: ExternalPixelFormat.bgra32,
      width: video.width,
      height: video.height,
      planes: [
        ExternalPlane(
          dataPtr: handleAddr,
          width: video.width,
          height: video.height,
          strideBytes: stride,
        ),
      ],
      fence: ExternalFence(d3d11FencePtr: buffer.nativeFence.d3d11FencePtr),
      timestampUs: buffer.timestampUs,
    );

    VideoTexture? tex;
    try {
      tex = _gpu.importVideoFrame(extBuf);
      if (tex == null) return null;

      await _ensureGpuPipeline();

      // Detect window resize.
      final int actualW = video.width;
      final int actualH = video.height;
      if (actualW != _currentSrcW || actualH != _currentSrcH) {
        recorderLog(
          RecorderLogSource.recorder,
          RecorderLogLevel.info,
          '[gpu_processor] window resize (cpu-readback): '
          '${_currentSrcW}x$_currentSrcH → ${actualW}x$actualH — '
          'adapting to encoder ${outputWidth}x$outputHeight',
        );
        _currentSrcW = actualW;
        _currentSrcH = actualH;
        await _updateDownscaleParams();
      }

      // 1. Fused BGRA→RGBA + bilinear downscale/passthrough from VideoTexture
      //    directly into the persistent _dstBuf — no per-frame allocation.
      await _runTexDownscale(tex);

      Buffer effectsBuf = _dstBuf!;
      int effectsW = dstWidth;
      int effectsH = dstHeight;

      // 3. Chained effects.
      for (final fx in _effectRuntimes) {
        await fx.apply(effectsBuf, effectsW, effectsH);
        final ob = fx.outBuf;
        if (ob != null) {
          effectsBuf = ob;
          effectsW = fx.outW!;
          effectsH = fx.outH!;
        }
      }

      // 4. Read back to CPU into the persistent buffer — no per-frame alloc.
      final readbackBytes = outputWidth * outputHeight * 4;
      var pixels = _cpuReadbackBuf;
      if (pixels == null || pixels.length != readbackBytes) {
        pixels = Uint8List(readbackBytes);
        _cpuReadbackBuf = pixels;
      }
      await effectsBuf.read(
        pixels,
        readbackBytes,
        dataType: BufferDataType.uint8,
      );
      return pixels;
    } catch (e, st) {
      recorderLog(
        RecorderLogSource.recorder,
        RecorderLogLevel.error,
        '[gpu_processor] processToBytes error: $e\n$st',
      );
      return null;
    } finally {
      tex?.destroy();
    }
  }

  /// GPU downscale + effects, leaving the result in the GPU [Buffer].
  ///
  /// Identical to [processToBytes] but skips the final CPU read-back step.
  /// Returns the internal effects output buffer (packed RGBA8 `u32` values at
  /// [outputWidth]\u00d7[outputHeight]).
  ///
  /// **Ownership**: the returned buffer is owned by this processor. Callers
  /// must NOT destroy it. The buffer remains valid only until the next call to
  /// any `process*` method on this processor (which may overwrite its content).
  Future<Buffer?> processToGpuBuffer(MiniAVBuffer buffer) async {
    assert(
      !_disposed,
      'GpuScreenProcessor.processToGpuBuffer called after dispose()',
    );

    final video = buffer.data;
    if (video is! MiniAVVideoBuffer) return null;
    if (video.nativeHandles.isEmpty || video.nativeHandles[0] == null) {
      return null;
    }
    final h0 = video.nativeHandles[0];
    final int handleAddr = h0 is int ? h0 : (h0 as Pointer).address;
    if (handleAddr == 0) return null;

    final int stride = video.strideBytes.isNotEmpty
        ? video.strideBytes[0]
        : video.width * 4;

    final extBuf = ExternalVideoBuffer(
      contentType: ExternalContentType.d3d11SharedHandle,
      pixelFormat: ExternalPixelFormat.bgra32,
      width: video.width,
      height: video.height,
      planes: [
        ExternalPlane(
          dataPtr: handleAddr,
          width: video.width,
          height: video.height,
          strideBytes: stride,
        ),
      ],
      fence: ExternalFence(d3d11FencePtr: buffer.nativeFence.d3d11FencePtr),
      timestampUs: buffer.timestampUs,
    );

    VideoTexture? tex;
    try {
      tex = _gpu.importVideoFrame(extBuf);
      if (tex == null) return null;

      await _ensureGpuPipeline();

      // Detect window resize.
      final int actualW = video.width;
      final int actualH = video.height;
      if (actualW != _currentSrcW || actualH != _currentSrcH) {
        recorderLog(
          RecorderLogSource.recorder,
          RecorderLogLevel.info,
          '[gpu_processor] window resize (gpu-buffer): '
          '${_currentSrcW}x$_currentSrcH → ${actualW}x$actualH — '
          'adapting to encoder ${outputWidth}x$outputHeight',
        );
        _currentSrcW = actualW;
        _currentSrcH = actualH;
        await _updateDownscaleParams();
      }

      // 1. Fused BGRA→RGBA + bilinear downscale/passthrough from VideoTexture
      //    directly into the persistent _dstBuf.
      await _runTexDownscale(tex);

      Buffer effectsBuf = _dstBuf!;
      int effectsW = dstWidth;
      int effectsH = dstHeight;

      // 2. Chained effects.
      for (final fx in _effectRuntimes) {
        await fx.apply(effectsBuf, effectsW, effectsH);
        final ob = fx.outBuf;
        if (ob != null) {
          effectsBuf = ob;
          effectsW = fx.outW!;
          effectsH = fx.outH!;
        }
      }

      // Return the GPU buffer directly — no CPU read-back.
      return effectsBuf;
    } catch (e, st) {
      recorderLog(
        RecorderLogSource.recorder,
        RecorderLogLevel.error,
        '[gpu_processor] processToGpuBuffer error: $e\n$st',
      );
      return null;
    } finally {
      tex?.destroy();
    }
  }

  /// GPU downscale + effects + RGBA→YUV420P conversion, reading back the three
  /// u8 planes — NO RGBA read-back. For the software/CPU-encode fallback where
  /// the encoder consumes YUV420P natively (see
  /// `PlatformEncoder.acceptsYuv420pPlanes`). The chroma read-back is ~2.7×
  /// smaller than the RGBA buffer and the per-pixel CPU conversion is gone.
  ///
  /// **Ownership / reuse**: the returned planes are owned by this processor and
  /// REUSED on the next call — the caller must consume them before invoking any
  /// `process*` method again (the recorder's serialized encode stage guarantees
  /// this). Returns `null` on GPU failure or odd output dims (caller should fall
  /// back to the RGBA path).
  Future<({Uint8List y, Uint8List u, Uint8List v, int width, int height})?>
  processToYuv420(MiniAVBuffer buffer) async {
    final w = outputWidth;
    final h = outputHeight;
    if (w.isOdd || h.isOdd) return null; // YUV420 requires even dimensions
    final rgbaGpu = await processToGpuBuffer(buffer);
    if (rgbaGpu == null) return null;

    final yLen = w * h;
    final uvLen = (w ~/ 2) * (h ~/ 2);
    var y = _yPlaneBuf;
    if (y == null || y.length != yLen) y = _yPlaneBuf = Uint8List(yLen);
    var u = _uPlaneBuf;
    if (u == null || u.length != uvLen) u = _uPlaneBuf = Uint8List(uvLen);
    var v = _vPlaneBuf;
    if (v == null || v.length != uvLen) v = _vPlaneBuf = Uint8List(uvLen);

    final conv = _yuvConverter ??= GpuYuv420Converter(_gpu);
    try {
      await conv.convertFromGpuBuffer(rgbaGpu, w, h, outY: y, outU: u, outV: v);
    } catch (e, st) {
      recorderLog(
        RecorderLogSource.recorder,
        RecorderLogLevel.error,
        '[gpu_processor] processToYuv420 error: $e\n$st',
      );
      return null;
    }
    return (y: y, u: u, v: v, width: w, height: h);
  }

  // -------------------------------------------------------------------------

  /// Fused BGRA→RGBA + bilinear downscale/passthrough from [tex] into [_dstBuf].
  ///
  /// Reads the VideoTexture directly via textureLoad — no intermediate
  /// toRGBA() buffer allocation. Handles both the downscale case and the
  /// no-downscale passthrough case (srcW == dstW).
  Future<void> _runTexDownscale(VideoTexture tex) async {
    tex.setOnShader(_texDownscaleShader!, 0);
    _texDownscaleShader!
      ..setBufferAtSlot(1, _dstBuf!)
      ..setBufferAtSlot(2, _paramsBuf!);
    const kGroup = 8;
    await _texDownscaleShader!.dispatch(
      (dstWidth + kGroup - 1) ~/ kGroup,
      (dstHeight + kGroup - 1) ~/ kGroup,
      1,
    );
  }

  /// Updates the params buffer with the current [_currentSrcW]/[_currentSrcH].
  /// The shader and buffers are guaranteed to exist (created by
  /// [_ensureGpuPipeline]); only the srcW/srcH values need updating here.
  Future<void> _updateDownscaleParams() async {
    final pData = ByteData(16)
      ..setUint32(0, _currentSrcW, Endian.little)
      ..setUint32(4, _currentSrcH, Endian.little)
      ..setUint32(8, dstWidth, Endian.little)
      ..setUint32(12, dstHeight, Endian.little);
    await _paramsBuf!.write(
      pData.buffer.asUint8List(),
      16,
      dataType: BufferDataType.uint8,
    );
  }

  /// Ensures the GPU pipeline (fused tex-downscale shader + effect runtimes)
  /// is ready. Does NOT create the [SharedOutputTexture] — call
  /// [_ensureResources] for the zero-copy hardware-encode path.
  Future<void> _ensureGpuPipeline() async {
    if (_gpuPipelineReady) return;

    // Always create the fused texture→RGBA shader and output buffer.
    // Handles both downscale (srcW×srcH → dstW×dstH) and passthrough
    // (srcW == dstW) — eliminates the per-frame toRGBA() allocation.
    final s = _gpu.createComputeShader();
    s.loadKernelString(_kFusedTexDownscaleWgsl);
    _texDownscaleShader = s;

    _dstBuf = _gpu.createBuffer(dstWidth * dstHeight * 4, BufferDataType.uint8);

    final pData = ByteData(16)
      ..setUint32(0, _currentSrcW, Endian.little)
      ..setUint32(4, _currentSrcH, Endian.little)
      ..setUint32(8, dstWidth, Endian.little)
      ..setUint32(12, dstHeight, Endian.little);
    _paramsBuf = _gpu.createBuffer(16, BufferDataType.uint8);
    await _paramsBuf!.write(
      pData.buffer.asUint8List(),
      16,
      dataType: BufferDataType.uint8,
    );

    // Build effect runtimes, tracking the running (w, h) through the chain.
    var (runW, runH) = (dstWidth, dstHeight);
    for (final desc in _effectDescriptors) {
      switch (desc) {
        case WgslScreenEffect():
          _effectRuntimes.add(_GpuEffectRuntime(_gpu, desc));
        // in-place: runW/runH unchanged
        case CropScreenEffect():
          final rt = _CropEffectRuntime(_gpu, desc, runW, runH);
          await rt.init();
          _effectRuntimes.add(rt);
          runW = desc.cropWidth;
          runH = desc.cropHeight;
        case FlipScreenEffect():
          final rt = _FlipEffectRuntime(_gpu, desc, runW, runH);
          await rt.init();
          _effectRuntimes.add(rt);
        // same dims — runW/runH unchanged
        case RotateScreenEffect():
          final rt = _RotateEffectRuntime(_gpu, desc, runW, runH);
          await rt.init();
          _effectRuntimes.add(rt);
          (runW, runH) = desc.outputSize(runW, runH);
        case ScaleScreenEffect():
          final rt = _ScaleEffectRuntime(_gpu, desc, runW, runH);
          await rt.init();
          _effectRuntimes.add(rt);
          runW = desc.width;
          runH = desc.height;
        case CensorScreenEffect():
          final rt = _CensorEffectRuntime(_gpu, desc, runW, runH);
          await rt.init();
          _effectRuntimes.add(rt);
        // in-place: runW/runH unchanged
      }
    }

    _gpuPipelineReady = true;
  }

  /// Ensures all resources including the [SharedOutputTexture] are ready.
  /// Required for the D3D11 zero-copy hardware-encode path ([process]).
  Future<void> _ensureResources() async {
    await _ensureGpuPipeline();
    if (_sharedTexReady) return;

    for (var i = 0; i < sharedRingDepth; i++) {
      final tex = _gpu.createSharedOutputTexture(outputWidth, outputHeight);
      if (tex == null) {
        // Clean up any slots already created so a retry starts fresh.
        for (final t in _sharedRing) {
          try {
            t.destroy();
          } catch (_) {}
        }
        _sharedRing.clear();
        throw StateError(
          '[gpu_processor] createSharedOutputTexture(${outputWidth}x$outputHeight) '
          'returned null (slot ${i + 1}/$sharedRingDepth) — Dawn D3D12 '
          'backend required.',
        );
      }
      _sharedRing.add(tex);
    }
    _ringCursor = 0;

    _sharedTexReady = true;
  }

  // -------------------------------------------------------------------------

  /// Release all GPU resources. Safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _texDownscaleShader?.destroy();
    } catch (_) {}
    try {
      _dstBuf?.destroy();
    } catch (_) {}
    try {
      _paramsBuf?.destroy();
    } catch (_) {}
    for (final t in _sharedRing) {
      try {
        t.destroy();
      } catch (_) {}
    }
    _sharedRing.clear();
    for (final fx in _effectRuntimes) {
      try {
        fx.dispose();
      } catch (_) {}
    }
    _effectRuntimes.clear();
    _texDownscaleShader = null;
    _dstBuf = null;
    _paramsBuf = null;
    _cpuReadbackBuf = null;
    _yuvConverter?.dispose();
    _yuvConverter = null;
    _yPlaneBuf = null;
    _uPlaneBuf = null;
    _vPlaneBuf = null;
  }
}
