/// Unified planar YUV → packed RGBA8 GPU converter (minigpu compute).
///
/// ONE params-driven WGSL kernel serves every planar layout the decoders emit —
/// i420 / i422 / i444 and their 10-bit variants — in limited or full (JPEG)
/// range. All variation lives in a 64-byte Params buffer (chroma dims, plane
/// byte offsets, subsampling shifts, bytes-per-sample, and the ×256 coefficient
/// set), so the SAME compiled shader is reused across formats and only the
/// params buffer is rewritten when `(w,h,layout,fullRange)` changes.
///
/// It is BYTE-IDENTICAL to the player's legacy `kYuv420ToRgbaBt601Wgsl` for the
/// i420-limited case, and byte-identical to the native C converter
/// (`frame_convert.c` / [cpuPlanarToRgba]) for every format+range — the paired
/// GPU test (`test/gpu_planar_yuv_test.dart`) asserts exactly that. This lets
/// the player present 4:2:2 / 4:4:4 / 10-bit / full-range frames fully on the
/// GPU with zero readback, instead of the CPU-convert-then-upload interim path.
///
/// Lives in `miniav_tools_codecs` (pure-Dart, already on `minigpu`, co-located
/// with its own C reference) so non-Flutter consumers can reuse it — the
/// `minigpu` `Buffer`/`Minigpu` handles it exchanges cross package boundaries by
/// reference, in-process, with no serialization cost.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show DecodedPixelLayout, YuvColorMatrix, YuvRgbCoeffs;
import 'package:minigpu/minigpu.dart';



/// The unified kernel. `>>` on i32 is arithmetic in WGSL (matching Dart), so the
/// rounding of negative intermediates is identical to the CPU reference.
const String kPlanarYuvToRgbaBt601Wgsl = r'''
struct Params {
  w         : u32,
  h         : u32,
  cw        : u32,
  ch        : u32,
  uByteOff  : u32,
  vByteOff  : u32,
  cShiftX   : u32,
  cShiftY   : u32,
  bps       : u32,
  yOff      : i32,
  yMul      : i32,
  rV        : i32,
  gU        : i32,
  gV        : i32,
  bU        : i32,
  _pad      : u32,
};

@group(0) @binding(0) var<storage, read_write> yuv    : array<u32>;
@group(0) @binding(1) var<storage, read_write> rgba   : array<u32>;
@group(0) @binding(2) var<storage, read_write> params : Params;

fn byte_at(i : u32) -> i32 {
  return i32((yuv[i >> 2u] >> ((i & 3u) * 8u)) & 0xFFu);
}

// Sample `si` within a plane starting at byte `planeOff`. 8-bit = one byte;
// 10-bit = little-endian u16 scaled to 8-bit via >>2 (matches C ld10).
fn sample_at(planeOff : u32, si : u32) -> i32 {
  let b = planeOff + si * params.bps;
  if (params.bps == 2u) {
    return (byte_at(b) | (byte_at(b + 1u) << 8u)) >> 2u;
  }
  return byte_at(b);
}

fn clamp255(v : i32) -> u32 {
  return u32(clamp(v, 0, 255));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let x = gid.x;
  let y = gid.y;
  if (x >= params.w || y >= params.h) { return; }

  let yi = y * params.w + x;
  let ci = (y >> params.cShiftY) * params.cw + (x >> params.cShiftX);

  let Y = sample_at(0u,              yi);
  let U = sample_at(params.uByteOff, ci);
  let V = sample_at(params.vByteOff, ci);

  let c  = Y - params.yOff;
  let d  = U - 128;
  let e  = V - 128;
  let yy = c * params.yMul + 128;

  let r = clamp255((yy + params.rV * e) >> 8u);
  let g = clamp255((yy - params.gU * d - params.gV * e) >> 8u);
  let b = clamp255((yy + params.bU * d) >> 8u);

  rgba[y * params.w + x] = r | (g << 8u) | (b << 16u) | (255u << 24u);
}
''';

/// Geometry of a planar layout: chroma dims (samples), subsampling shifts, and
/// bytes-per-sample. Mirrors `frame_convert.c` plane indexing exactly.
class _PlanarGeom {
  const _PlanarGeom(this.cw, this.ch, this.cShiftX, this.cShiftY, this.bps);
  final int cw, ch, cShiftX, cShiftY, bps;

  static _PlanarGeom of(DecodedPixelLayout layout, int w, int h) {
    final cwHalf = (w + 1) >> 1;
    final chHalf = (h + 1) >> 1;
    return switch (layout) {
      DecodedPixelLayout.i420 => _PlanarGeom(cwHalf, chHalf, 1, 1, 1),
      DecodedPixelLayout.i422 => _PlanarGeom(cwHalf, h, 1, 0, 1),
      DecodedPixelLayout.i444 => _PlanarGeom(w, h, 0, 0, 1),
      DecodedPixelLayout.i420p10 => _PlanarGeom(cwHalf, chHalf, 1, 1, 2),
      DecodedPixelLayout.i422p10 => _PlanarGeom(cwHalf, h, 1, 0, 2),
      DecodedPixelLayout.i444p10 => _PlanarGeom(w, h, 0, 0, 2),
      DecodedPixelLayout.nv12 ||
      DecodedPixelLayout.p010 =>
        throw ArgumentError(
            'GpuPlanarYuvToRgbaConverter is planar-only; nv12/p010 are '
            'semi-planar (interleaved UV)'),
      DecodedPixelLayout.rgba => throw ArgumentError(
          'rgba frames are already RGBA — no conversion applies'),
    };
  }
}

/// Reusable converter: shader + params + [slotCount] independent (yuv upload,
/// rgba output) buffer pairs so a presenter can ping-pong slots while the
/// display samples the previous frame. Buffers are sized per resolution+layout
/// and rebuilt on change. Not thread-safe — drive from one serialized path.
class GpuPlanarYuvToRgbaConverter {
  GpuPlanarYuvToRgbaConverter(this._gpu, {this.slotCount = 2});

  final Minigpu _gpu;
  final int slotCount;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  late final List<Buffer?> _yuvBufs = List.filled(slotCount, null);
  late final List<Buffer?> _rgbaBufs = List.filled(slotCount, null);
  int _w = 0;
  int _h = 0;
  DecodedPixelLayout? _layout;
  bool _fullRange = false;
  YuvColorMatrix _matrix = YuvColorMatrix.bt601;
  int _yuvBytes = 0;
  bool _disposed = false;

  int get width => _w;
  int get height => _h;

  /// Total tightly-packed YUV byte size for ([layout], [w]×[h]).
  static int yuvSize(DecodedPixelLayout layout, int w, int h) {
    final g = _PlanarGeom.of(layout, w, h);
    return g.bps * w * h + 2 * g.bps * g.cw * g.ch;
  }

  Future<void> _ensure(DecodedPixelLayout layout, bool fullRange,
      YuvColorMatrix matrix, int w, int h) async {
    assert(!_disposed, 'GpuPlanarYuvToRgbaConverter used after dispose()');
    if (w <= 0 || h <= 0) {
      throw ArgumentError('non-positive dims ${w}x$h');
    }
    _shader ??= _gpu.createComputeShader()
      ..loadKernelString(kPlanarYuvToRgbaBt601Wgsl);

    final g = _PlanarGeom.of(layout, w, h);
    final ySizeB = g.bps * w * h;
    final cSizeB = g.bps * g.cw * g.ch;
    final yuvBytes = ySizeB + 2 * cSizeB;

    // (Re)allocate the upload/output buffers when the byte size changes (a
    // format/resolution change can grow or shrink them).
    if (yuvBytes != _yuvBytes || w != _w || h != _h) {
      _releaseSlotBuffers();
      final yuvLen = (yuvBytes + 3) & ~3; // round up to u32 words
      for (var i = 0; i < slotCount; i++) {
        _yuvBufs[i] = _gpu.createBuffer(yuvLen, BufferDataType.uint8);
        _rgbaBufs[i] = _gpu.createBuffer(w * h * 4, BufferDataType.uint8);
      }
      _yuvBytes = yuvBytes;
    }

    // Rewrite the params buffer only when a param actually changes.
    if (_paramsBuf == null ||
        w != _w ||
        h != _h ||
        layout != _layout ||
        fullRange != _fullRange ||
        matrix != _matrix) {
      _paramsBuf ??= _gpu.createBuffer(64, BufferDataType.uint8);
      final k = YuvRgbCoeffs.of(matrix, fullRange: fullRange);
      final p = ByteData(64)
        ..setUint32(0, w, Endian.little)
        ..setUint32(4, h, Endian.little)
        ..setUint32(8, g.cw, Endian.little)
        ..setUint32(12, g.ch, Endian.little)
        ..setUint32(16, ySizeB, Endian.little)
        ..setUint32(20, ySizeB + cSizeB, Endian.little)
        ..setUint32(24, g.cShiftX, Endian.little)
        ..setUint32(28, g.cShiftY, Endian.little)
        ..setUint32(32, g.bps, Endian.little)
        ..setInt32(36, k.yOff, Endian.little)
        ..setInt32(40, k.yMul, Endian.little)
        ..setInt32(44, k.rV, Endian.little)
        ..setInt32(48, k.gU, Endian.little)
        ..setInt32(52, k.gV, Endian.little)
        ..setInt32(56, k.bU, Endian.little)
        ..setUint32(60, 0, Endian.little);
      await _paramsBuf!
          .write(p.buffer.asUint8List(), 64, dataType: BufferDataType.uint8);
      _w = w;
      _h = h;
      _layout = layout;
      _fullRange = fullRange;
      _matrix = matrix;
    }
  }

  /// Upload [yuv] (tightly packed planes for [layout]) into [slot], dispatch the
  /// convert, and return the slot's packed-RGBA8 GPU buffer (borrowed — valid
  /// until the slot is reused; do NOT destroy it).
  Future<Buffer> convert(
    Uint8List yuv,
    int w,
    int h, {
    DecodedPixelLayout layout = DecodedPixelLayout.i420,
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
    int slot = 0,
  }) async {
    await _ensure(layout, fullRange, matrix, w, h);
    final yuvBuf = _yuvBufs[slot]!;
    final rgbaBuf = _rgbaBufs[slot]!;
    await yuvBuf.write(yuv, yuvSize(layout, w, h),
        dataType: BufferDataType.uint8);
    _shader!
      ..setBufferAtSlot(0, yuvBuf)
      ..setBufferAtSlot(1, rgbaBuf)
      ..setBufferAtSlot(2, _paramsBuf!);
    await _shader!.dispatch((w + 7) ~/ 8, (h + 7) ~/ 8, 1);
    return rgbaBuf;
  }

  /// Validation path (NOT the hot path — the whole point is to never read back):
  /// convert + read the RGBA bytes back. Used by the byte-exact GPU==C test.
  Future<Uint8List> convertAndRead(
    Uint8List yuv,
    int w,
    int h, {
    DecodedPixelLayout layout = DecodedPixelLayout.i420,
    bool fullRange = false,
    YuvColorMatrix matrix = YuvColorMatrix.bt601,
  }) async {
    final rgbaBuf = await convert(yuv, w, h,
        layout: layout, fullRange: fullRange, matrix: matrix);
    final out = Uint8List(w * h * 4);
    await rgbaBuf.read(out, out.length, dataType: BufferDataType.uint8);
    return out;
  }

  void _releaseSlotBuffers() {
    for (var i = 0; i < slotCount; i++) {
      _yuvBufs[i]?.destroy();
      _rgbaBufs[i]?.destroy();
      _yuvBufs[i] = null;
      _rgbaBufs[i] = null;
    }
    _yuvBytes = 0;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _shader?.destroy();
    _shader = null;
    _paramsBuf?.destroy();
    _paramsBuf = null;
    _releaseSlotBuffers();
  }
}
