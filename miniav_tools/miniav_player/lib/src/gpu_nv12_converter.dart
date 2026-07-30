/// GPU NV12 (imported D3D11 texture, 2 plane views) → packed RGBA8 conversion.
///
/// The hardware-decode counterpart of the planar GPU converter: instead of
/// uploading YUV420P bytes, it binds the two plane views of an imported
/// [VideoTexture] (Y = R8, UV = Rg8) and runs one WGSL dispatch. Crucially it
/// **caches the compiled compute shader and the output buffers**, so the only
/// per-frame GPU work is the bind-group rebuild + dispatch — not a fresh WGSL
/// compile (which `VideoTexture.toRGBA()` does on every call, ~several ms).
///
/// BT.709 full-range, identical arithmetic to minigpu's built-in
/// `nv12_to_rgba` kernel, so output matches `VideoTexture.toRGBA()`.
library;

import 'dart:typed_data';

import 'package:minigpu/minigpu.dart';

/// One invocation per pixel (8×8 workgroups). Y at full res, UV at half res
/// (chroma subsampling). Params is a storage buffer (not uniform) so it binds
/// through the same `setBufferAtSlot` path as the output buffer.
const String kNv12TextureToRgbaWgsl = r'''
@group(0) @binding(0) var y_tex  : texture_2d<f32>;
@group(0) @binding(1) var uv_tex : texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> out_buf : array<u32>;

struct Params { width: u32, height: u32 }
@group(0) @binding(3) var<storage, read_write> uni : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x >= uni.width || gid.y >= uni.height) { return; }
  let y  = textureLoad(y_tex,  vec2<u32>(gid.x, gid.y), 0).r;
  let cb = textureLoad(uv_tex, vec2<u32>(gid.x / 2u, gid.y / 2u), 0).r - 0.5;
  let cr = textureLoad(uv_tex, vec2<u32>(gid.x / 2u, gid.y / 2u), 0).g - 0.5;
  let r  = clamp(y + 1.5748 * cr,               0.0, 1.0);
  let g  = clamp(y - 0.1873 * cb - 0.4681 * cr, 0.0, 1.0);
  let b  = clamp(y + 1.8556 * cb,               0.0, 1.0);
  let ri = u32(r * 255.0);
  let gi = u32(g * 255.0);
  let bi = u32(b * 255.0);
  out_buf[gid.y * uni.width + gid.x] = ri | (gi << 8u) | (bi << 16u) | (255u << 24u);
}
''';

/// Reusable converter: cached shader + [slotCount] independent RGBA output
/// buffers so a presenter can ping-pong slots while the display samples the
/// previous frame. Buffers/shader are rebuilt on resolution change. Not
/// thread-safe — drive from a single serialized present path.
class GpuNv12TextureToRgbaConverter {
  GpuNv12TextureToRgbaConverter(this._gpu, {this.slotCount = 2});

  final Minigpu _gpu;
  final int slotCount;

  ComputeShader? _shader;
  Buffer? _paramsBuf;
  late final List<Buffer?> _rgbaBufs = List.filled(slotCount, null);
  int _w = 0;
  int _h = 0;
  bool _disposed = false;

  Future<void> _ensure(int w, int h) async {
    assert(!_disposed, 'GpuNv12TextureToRgbaConverter used after dispose()');
    if (_shader != null && w == _w && h == _h) return;
    _release();
    _w = w;
    _h = h;
    _shader = _gpu.createComputeShader()
      ..loadKernelString(kNv12TextureToRgbaWgsl);
    for (var i = 0; i < slotCount; i++) {
      _rgbaBufs[i] = _gpu.createBuffer(w * h * 4, BufferDataType.uint8);
    }
    _paramsBuf = _gpu.createBuffer(8, BufferDataType.uint8);
    final params = ByteData(8)
      ..setUint32(0, w, Endian.little)
      ..setUint32(4, h, Endian.little);
    await _paramsBuf!.write(
      params.buffer.asUint8List(),
      8,
      dataType: BufferDataType.uint8,
    );
  }

  /// Bind [vtex]'s Y + UV plane views, dispatch the convert, and return the
  /// slot's packed-RGBA8 GPU buffer (borrowed — valid until the slot is reused;
  /// do NOT destroy). [vtex] must be an NV12 [VideoTexture] (2 plane views).
  Future<Buffer> convert(VideoTexture vtex, int w, int h, {int slot = 0}) async {
    await _ensure(w, h);
    final rgbaBuf = _rgbaBufs[slot]!;
    vtex
      ..setOnShader(_shader!, 0, planeIndex: 0) // Y  (R8)
      ..setOnShader(_shader!, 1, planeIndex: 1); // UV (Rg8)
    final s = _shader!
      ..setBufferAtSlot(2, rgbaBuf)
      ..setBufferAtSlot(3, _paramsBuf!);
    await s.dispatch((w + 7) ~/ 8, (h + 7) ~/ 8, 1);
    return rgbaBuf;
  }

  void _release() {
    _shader?.destroy();
    _shader = null;
    _paramsBuf?.destroy();
    _paramsBuf = null;
    for (var i = 0; i < slotCount; i++) {
      _rgbaBufs[i]?.destroy();
      _rgbaBufs[i] = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
  }
}
