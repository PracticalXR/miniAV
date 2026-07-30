/// Packed RGBA8 → planar YUV420 (u8) GPU converter (minigpu compute) — the
/// encode-side inverse of [GpuPlanarYuvToRgbaConverter].
///
/// ONE params-driven WGSL kernel serves every matrix/range: the ×256
/// [RgbaYuvCoeffs] set rides in the params buffer, so the compiled shader is
/// reused across formats. Byte-identical to the C `miniav_rgba_to_i420` and
/// the pure-Dart [dartRgbaToI420] (chroma = rounded 2x2 box average of the
/// RGB cell, edges replicate for odd dims) — the paired GPU test asserts it.
///
/// This replaces the per-consumer copies (the recorder's BT.601-only
/// `GpuYuv420Converter` WGSL was the prior art for the quad-packing scheme):
/// each invocation packs 4 output bytes into one u32 word it exclusively owns,
/// so plane writes never race.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show YuvColorMatrix, RgbaYuvCoeffs;
import 'package:minigpu/minigpu.dart';


const String kRgbaToYuv420Wgsl = r'''
struct Params {
  w    : u32,
  h    : u32,
  mode : u32,   // 0 = luma pass, 1 = chroma pass
  _pad : u32,
  yR : i32, yG : i32, yB : i32,
  uR : i32, uG : i32, uB : i32,
  vR : i32, vG : i32, vB : i32,
  yOff : i32,
};

@group(0) @binding(0) var<storage, read_write> rgba   : array<u32>;
@group(0) @binding(1) var<storage, read_write> yOut   : array<u32>;
@group(0) @binding(2) var<storage, read_write> uOut   : array<u32>;
@group(0) @binding(3) var<storage, read_write> vOut   : array<u32>;
@group(0) @binding(4) var<storage, read_write> params : Params;

fn clamp255(v : i32) -> u32 { return u32(clamp(v, 0, 255)); }

// RGB bytes (0..255) of pixel (x,y). R is the low byte (little-endian RGBA8).
fn rgb_at(x : u32, y : u32) -> vec3<i32> {
  let p = rgba[y * params.w + x];
  return vec3<i32>(i32(p & 0xFFu), i32((p >> 8u) & 0xFFu), i32((p >> 16u) & 0xFFu));
}

fn y_of(c : vec3<i32>) -> u32 {
  return clamp255(((params.yR * c.x + params.yG * c.y + params.yB * c.z + 128) >> 8u)
                  + params.yOff);
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let quad = gid.x; // each invocation owns one u32 = 4 output bytes

  if (params.mode == 0u) {
    // --- Luma: 4 consecutive (linear) pixels -> 4 packed Y bytes ---
    let ySize = params.w * params.h;
    let nQuads = (ySize + 3u) / 4u;
    if (quad >= nQuads) { return; }
    let base = quad * 4u;
    var packed : u32 = 0u;
    for (var k = 0u; k < 4u; k = k + 1u) {
      let p = base + k;
      if (p >= ySize) { continue; } // padded tail: leave byte = 0
      let x = p % params.w;
      let y = p / params.w;
      packed = packed | (y_of(rgb_at(x, y)) << (k * 8u));
    }
    yOut[quad] = packed;
  } else {
    // --- Chroma: 4 consecutive chroma samples -> packed U and V bytes ---
    let cw = (params.w + 1u) / 2u;
    let ch = (params.h + 1u) / 2u;
    let uvSize = cw * ch;
    let nQuads = (uvSize + 3u) / 4u;
    if (quad >= nQuads) { return; }
    let base = quad * 4u;
    var uPacked : u32 = 0u;
    var vPacked : u32 = 0u;
    for (var k = 0u; k < 4u; k = k + 1u) {
      let j = base + k;
      if (j >= uvSize) { continue; }
      let cx = j % cw;
      let cy = j / cw;
      let x0 = cx * 2u;
      let y0 = cy * 2u;
      let x1 = min(x0 + 1u, params.w - 1u); // replicate edge for odd dims
      let y1 = min(y0 + 1u, params.h - 1u);
      let c00 = rgb_at(x0, y0);
      let c10 = rgb_at(x1, y0);
      let c01 = rgb_at(x0, y1);
      let c11 = rgb_at(x1, y1);
      // Rounded 2x2 box average, matching the C/Dart reference exactly.
      let a = (c00 + c10 + c01 + c11 + vec3<i32>(2)) >> vec3<u32>(2u);
      let uv = clamp255(((params.uR * a.x + params.uG * a.y + params.uB * a.z + 128) >> 8u) + 128);
      let vv = clamp255(((params.vR * a.x + params.vG * a.y + params.vB * a.z + 128) >> 8u) + 128);
      uPacked = uPacked | (uv << (k * 8u));
      vPacked = vPacked | (vv << (k * 8u));
    }
    uOut[quad] = uPacked;
    vOut[quad] = vPacked;
  }
}
''';

int _ceil4(int n) => (n + 3) & ~3;

/// Reusable GPU RGBA→YUV420 converter. One per output resolution; the shader
/// and plane buffers are reused across frames. Not thread-safe — drive it from
/// a single serialized encode path.
class GpuRgbaToYuv420Converter {
  GpuRgbaToYuv420Converter(this._gpu);

  final Minigpu _gpu;

  ComputeShader? _shader;
  Buffer? _yBuf;
  Buffer? _uBuf;
  Buffer? _vBuf;
  Buffer? _paramsBuf;
  Buffer? _rgbaUpload; // only for the CPU-bytes entry point
  int _w = 0;
  int _h = 0;
  bool _fullRange = false;
  YuvColorMatrix _matrix = YuvColorMatrix.bt601;
  bool _paramsWritten = false;
  bool _disposed = false;

  /// Y-plane size in bytes for [width]x[height].
  static int ySize(int width, int height) => width * height;

  /// U or V plane size in bytes (chroma dims `ceil(w/2) x ceil(h/2)`).
  static int uvSize(int width, int height) =>
      ((width + 1) >> 1) * ((height + 1) >> 1);

  Future<void> _ensure(
      int w, int h, bool fullRange, YuvColorMatrix matrix) async {
    assert(!_disposed, 'GpuRgbaToYuv420Converter used after dispose()');
    if (w <= 0 || h <= 0) throw ArgumentError('non-positive dims ${w}x$h');
    _shader ??= _gpu.createComputeShader()..loadKernelString(kRgbaToYuv420Wgsl);
    if (w != _w || h != _h) {
      _yBuf?.destroy();
      _uBuf?.destroy();
      _vBuf?.destroy();
      _rgbaUpload?.destroy();
      _rgbaUpload = null;
      final uv = uvSize(w, h);
      _yBuf = _gpu.createBuffer(_ceil4(ySize(w, h)), BufferDataType.uint8);
      _uBuf = _gpu.createBuffer(_ceil4(uv), BufferDataType.uint8);
      _vBuf = _gpu.createBuffer(_ceil4(uv), BufferDataType.uint8);
    }
    if (!_paramsWritten ||
        w != _w ||
        h != _h ||
        fullRange != _fullRange ||
        matrix != _matrix) {
      _paramsBuf ??= _gpu.createBuffer(64, BufferDataType.uint8);
      final k = RgbaYuvCoeffs.of(matrix, fullRange: fullRange);
      _params
        ..setUint32(0, w, Endian.little)
        ..setUint32(4, h, Endian.little)
        ..setUint32(8, 0, Endian.little) // mode — rewritten per pass
        ..setUint32(12, 0, Endian.little)
        ..setInt32(16, k.yR, Endian.little)
        ..setInt32(20, k.yG, Endian.little)
        ..setInt32(24, k.yB, Endian.little)
        ..setInt32(28, k.uR, Endian.little)
        ..setInt32(32, k.uG, Endian.little)
        ..setInt32(36, k.uB, Endian.little)
        ..setInt32(40, k.vR, Endian.little)
        ..setInt32(44, k.vG, Endian.little)
        ..setInt32(48, k.vB, Endian.little)
        ..setInt32(52, k.yOff, Endian.little);
      _w = w;
      _h = h;
      _fullRange = fullRange;
      _matrix = matrix;
      _paramsWritten = true;
    }
  }

  final ByteData _params = ByteData(64);

  Future<void> _writeMode(int mode) {
    _params.setUint32(8, mode, Endian.little);
    return _paramsBuf!.write(_params.buffer.asUint8List(), 64,
        dataType: BufferDataType.uint8);
  }

  Future<void> _run(Buffer rgbaSource, int w, int h) async {
    final s = _shader!
      ..setBufferAtSlot(0, rgbaSource)
      ..setBufferAtSlot(1, _yBuf!)
      ..setBufferAtSlot(2, _uBuf!)
      ..setBufferAtSlot(3, _vBuf!)
      ..setBufferAtSlot(4, _paramsBuf!);
    const wg = 64;
    await _writeMode(0);
    final yQuads = (ySize(w, h) + 3) ~/ 4;
    await s.dispatch((yQuads + wg - 1) ~/ wg, 1, 1);
    await _writeMode(1);
    final uvQuads = (uvSize(w, h) + 3) ~/ 4;
    await s.dispatch((uvQuads + wg - 1) ~/ wg, 1, 1);
  }

  Future<void> _readback(
      int w, int h, Uint8List outY, Uint8List outU, Uint8List outV) async {
    await _yBuf!.read(outY, ySize(w, h), dataType: BufferDataType.uint8);
    await _uBuf!.read(outU, uvSize(w, h), dataType: BufferDataType.uint8);
    await _vBuf!.read(outV, uvSize(w, h), dataType: BufferDataType.uint8);
  }

  /// Convert a packed-RGBA8 GPU [Buffer] at [w]x[h] into the provided Y/U/V
  /// plane buffers — no RGBA read-back. [outY] must hold [ySize] bytes;
  /// [outU]/[outV] must hold [uvSize].
  Future<void> convertFromGpuBuffer(
    Buffer rgbaGpu,
    int w,
    int h, {
    required Uint8List outY,
    required Uint8List outU,
    required Uint8List outV,
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
  }) async {
    await _ensure(w, h, fullRange, matrix);
    await _run(rgbaGpu, w, h);
    await _readback(w, h, outY, outU, outV);
  }

  /// Convert packed-RGBA8 CPU [rgba] bytes by uploading them first. Mainly for
  /// tests and sources that aren't already a GPU buffer.
  Future<void> convertFromBytes(
    Uint8List rgba,
    int w,
    int h, {
    required Uint8List outY,
    required Uint8List outU,
    required Uint8List outV,
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
  }) async {
    await _ensure(w, h, fullRange, matrix);
    final upload = _rgbaUpload ??= _gpu.createBuffer(
      w * h * 4,
      BufferDataType.uint8,
    );
    await upload.write(rgba, w * h * 4, dataType: BufferDataType.uint8);
    await _run(upload, w, h);
    await _readback(w, h, outY, outU, outV);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _shader?.destroy();
    _yBuf?.destroy();
    _uBuf?.destroy();
    _vBuf?.destroy();
    _paramsBuf?.destroy();
    _rgbaUpload?.destroy();
    _shader = null;
    _yBuf = _uBuf = _vBuf = _paramsBuf = _rgbaUpload = null;
  }
}
