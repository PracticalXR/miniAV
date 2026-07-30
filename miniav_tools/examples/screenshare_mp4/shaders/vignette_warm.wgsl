// Vignette + colour-grade effect for the screenshare example.
//
// Reads RGBA8 pixels from `inBuf`, applies a soft radial vignette plus a
// warm colour grade, writes back to the same byte indices in `inBuf`
// (in-place). Dispatch one workgroup per 8x8 pixel tile.

struct Params {
  width  : u32,
  height : u32,
  // Effect strength. 0.0 = pass-through, 1.0 = full effect.
  strength : f32,
  // Padding for std140-ish alignment; not used by the kernel.
  _pad : f32,
};

@group(0) @binding(0) var<storage, read_write> pixels : array<u32>;
// NOTE: minigpu's setBufferAtSlot binds ALL buffers as storage read_write;
// declaring this as `storage, read` causes a WebGPU bind-group-layout mismatch.
@group(0) @binding(1) var<storage, read_write> params : Params;

fn unpack_rgba(p : u32) -> vec4<f32> {
  return vec4<f32>(
    f32((p >> 0u)  & 0xFFu),
    f32((p >> 8u)  & 0xFFu),
    f32((p >> 16u) & 0xFFu),
    f32((p >> 24u) & 0xFFu),
  ) / 255.0;
}

fn pack_rgba(c : vec4<f32>) -> u32 {
  let q = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0 + vec4<f32>(0.5);
  let r = u32(q.x);
  let g = u32(q.y);
  let b = u32(q.z);
  let a = u32(q.w);
  return (a << 24u) | (b << 16u) | (g << 8u) | r;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.width || gid.y >= params.height) {
    return;
  }
  let idx = gid.y * params.width + gid.x;
  var c = unpack_rgba(pixels[idx]);

  // Radial vignette — distance from centre, normalised to the shorter axis.
  let cx = f32(params.width)  * 0.5;
  let cy = f32(params.height) * 0.5;
  let dx = (f32(gid.x) - cx);
  let dy = (f32(gid.y) - cy);
  let r2_max = cx * cx + cy * cy;
  let r2 = (dx * dx + dy * dy) / r2_max;
  // Smooth falloff: 1.0 at centre, ~0.35 in the corners.
  let vignette = 1.0 - (r2 * 0.65);

  // Warm grade — boost R, slight G, dampen B.
  let warm = vec3<f32>(1.06, 1.00, 0.92);

  let graded = c.rgb * warm * vignette;
  let mixed = mix(c.rgb, graded, params.strength);

  pixels[idx] = pack_rgba(vec4<f32>(mixed, c.a));
}
