/// GPU effect descriptors for screen captures.
///
/// Effects are pure configuration objects — no GPU resources are allocated
/// until the [Recorder] starts. They run entirely on the GPU (WGSL compute
/// shaders via Dawn/D3D12) as part of the zero-copy pipeline and require
/// [RecorderBuilder.preferZeroCopy] to be active (the default on Windows).
///
/// ### Pipeline order (per frame)
/// ```
/// D3D11 NT handle (miniav capture)
///   → importVideoFrame()    VideoTexture  BGRA, srcW×srcH
///   → toRGBA()              Buffer        RGBA u32[], srcW×srcH
///   → [bilinear downscale]  Buffer        RGBA u32[], dstW×dstH  ← if scale policy set
///   → effect[0].apply()     Buffer        RGBA u32[], dstW×dstH  ← in-place
///   → effect[1].apply()     …
///   → SharedOutputTexture.copyFromBuffer
///   → FfmpegD3d11HwEncoder  (zero-copy, no PCIe)
/// ```
library;

// ---------------------------------------------------------------------------
// ScreenRotation enum
// ---------------------------------------------------------------------------

/// Clockwise rotation amounts for [ScreenEffect.rotate].
enum ScreenRotation {
  /// 90 degrees clockwise.
  /// Output width = input height, output height = input width.
  r90,

  /// 180 degrees clockwise.
  /// Output dimensions are unchanged.
  r180,

  /// 270 degrees clockwise (equivalent to 90° counter-clockwise).
  /// Output width = input height, output height = input width.
  r270,
}

// ---------------------------------------------------------------------------

/// A descriptor for a GPU compute effect applied to screen captures.
///
/// Effects are applied in declaration order **after** any [ScreenScalePolicy]
/// downscaling, operating on the final encoder-sized RGBA8 buffer. This means
/// effects always work on the smallest possible buffer for maximum efficiency.
///
/// ### Built-in effects
/// | Factory | Description |
/// |---|---|
/// | [ScreenEffect.vignette] | Radial vignette + warm colour grade. |
///
/// ### Custom WGSL effect
///
/// Write a standard WGSL compute shader that follows the **binding convention**:
/// ```wgsl
/// struct Params {
///   width    : u32,   // always injected — current frame width in pixels
///   height   : u32,   // always injected — current frame height in pixels
///   myParam  : f32,   // extraParams[0]
///   // ... more extraParams fields ...
/// };
///
/// @group(0) @binding(0) var<storage, read_write> pixels : array<u32>; // RGBA8 in/out
/// @group(0) @binding(1) var<storage, read_write> params : Params;
///
/// @compute @workgroup_size(8, 8, 1)
/// fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
///   if (gid.x >= params.width || gid.y >= params.height) { return; }
///   let idx = gid.y * params.width + gid.x;
///   // … modify pixels[idx] …
/// }
/// ```
///
/// Then register it:
/// ```dart
/// builder.addScreen(
///   effects: [
///     ScreenEffect.wgsl(myWgsl, extraParams: [0.8]),
///   ],
/// );
/// ```
sealed class ScreenEffect {
  const ScreenEffect();

  /// Returns the output dimensions this effect produces for a given input size.
  ///
  /// In-place effects (e.g. [ScreenEffect.wgsl], [ScreenEffect.vignette])
  /// return `(inW, inH)` unchanged. Transform effects (e.g. [ScreenEffect.crop])
  /// return a different size, which the recorder uses to correctly size the
  /// encoder and the shared output texture.
  (int, int) outputSize(int inW, int inH) => (inW, inH);

  // ----- factories ---------------------------------------------------------

  /// Apply a custom WGSL compute shader effect.
  ///
  /// [wgslSource] must follow the binding convention described on [ScreenEffect]:
  /// - `@binding(0)` — `array<u32>` RGBA8 pixels, read-write in-place.
  /// - `@binding(1)` — `Params` struct: `width : u32` at byte 0, `height : u32`
  ///   at byte 4, then [extraParams] as `f32` fields from byte 8 onward.
  ///
  /// [extraParams] are appended to the params struct after `width` and `height`.
  /// The recorder injects the current frame dimensions automatically; you only
  /// need to provide your own shader-specific floats here.
  factory ScreenEffect.wgsl(
    String wgslSource, {
    List<double> extraParams = const [],
  }) => WgslScreenEffect(
    wgslSource: wgslSource,
    extraParams: List.unmodifiable(extraParams),
  );

  /// Built-in radial vignette + warm colour grade.
  ///
  /// Darkens corners with a soft radial falloff and applies a warm colour
  /// shift (R +6 %, G neutral, B −8 %).
  ///
  /// [strength] controls intensity: `0.0` = pass-through, `1.0` = full effect.
  factory ScreenEffect.vignette({double strength = 1.0}) => WgslScreenEffect(
    wgslSource: _kVignetteWarmWgsl,
    extraParams: List.unmodifiable([strength.clamp(0.0, 1.0), 0.0]),
  );

  /// Crop the frame to an [x],[y] offset with the given [width] and [height].
  ///
  /// The crop is expressed in pixels relative to the *encoder input* (i.e.
  /// after any [ScreenScalePolicy] downscaling and before this effect). The
  /// encoder will be opened at exactly [width]×[height].
  ///
  /// ```dart
  /// // Crop to the top-left quadrant of a 1920×1080 source:
  /// ScreenEffect.crop(0, 0, 960, 540)
  ///
  /// // Remove a 200-px taskbar at the bottom of a 2560×1440 display:
  /// ScreenEffect.crop(0, 0, 2560, 1240)
  /// ```
  ///
  /// An [AssertionError] is thrown at recorder start if the crop rectangle
  /// falls outside the source frame.
  factory ScreenEffect.crop(int x, int y, int width, int height) =>
      CropScreenEffect(
        cropX: x,
        cropY: y,
        cropWidth: width,
        cropHeight: height,
      );

  /// Mirror the frame horizontally and/or vertically.
  ///
  /// Uses a separate output buffer internally (the in-place WGSL path would
  /// have thread-racing hazards). Output dimensions are unchanged.
  ///
  /// ```dart
  /// // Correct a front-facing webcam mirror:
  /// ScreenEffect.flip(horizontal: true)
  ///
  /// // Flip both axes (= 180° rotation):
  /// ScreenEffect.flip(horizontal: true, vertical: true)
  /// ```
  factory ScreenEffect.flip({bool horizontal = false, bool vertical = false}) =>
      FlipScreenEffect(horizontal: horizontal, vertical: vertical);

  /// Rotate the frame clockwise by [rotation].
  ///
  /// 90° and 270° rotations swap width and height; 180° preserves them.
  /// Uses a separate output buffer (cannot be done in-place without races).
  ///
  /// ```dart
  /// // Correct a sideways phone recording:
  /// ScreenEffect.rotate(ScreenRotation.r90)
  /// ```
  factory ScreenEffect.rotate(ScreenRotation rotation) =>
      RotateScreenEffect(rotation: rotation);

  /// Bilinear resize to [width]×[height] as part of the effects chain.
  ///
  /// Unlike [ScreenScalePolicy], this runs *after* all earlier effects,
  /// making it composable — e.g. crop a region then upscale it to HD.
  ///
  /// ```dart
  /// // Upscale a 640×360 crop back to 1280×720:
  /// ScreenEffect.scale(1280, 720)
  /// ```
  factory ScreenEffect.scale(int width, int height) =>
      ScaleScreenEffect(width: width, height: height);

  /// Overlay a solid-colour rectangle to censor part of the frame in-place.
  ///
  /// Coordinates are in pixels relative to the *encoder input* (i.e. after
  /// any [ScreenScalePolicy] downscaling and after earlier effects in the
  /// chain). Output dimensions are unchanged.
  ///
  /// [color] is the fill colour packed as `R | G<<8 | B<<16 | A<<24`.
  /// Defaults to opaque black (`0xFF000000`).
  ///
  /// ```dart
  /// // Black out a 200×100 box at (50, 50):
  /// ScreenEffect.censor(50, 50, 200, 100)
  ///
  /// // Semi-transparent red box:
  /// ScreenEffect.censor(0, 0, 100, 100, color: 0x800000FF)
  /// ```
  factory ScreenEffect.censor(
    int x,
    int y,
    int width,
    int height, {
    int color = 0xFF000000,
  }) => CensorScreenEffect(
    boxX: x,
    boxY: y,
    boxW: width,
    boxH: height,
    color: color,
  );
}

// ---------------------------------------------------------------------------
// CropScreenEffect
// ---------------------------------------------------------------------------

/// Crops the frame to the rectangle ([cropX],[cropY])–([cropX]+[cropWidth],
/// [cropY]+[cropHeight]). Created via [ScreenEffect.crop].
final class CropScreenEffect extends ScreenEffect {
  const CropScreenEffect({
    required this.cropX,
    required this.cropY,
    required this.cropWidth,
    required this.cropHeight,
  });

  final int cropX;
  final int cropY;
  final int cropWidth;
  final int cropHeight;

  @override
  (int, int) outputSize(int inW, int inH) => (cropWidth, cropHeight);
}

// ---------------------------------------------------------------------------
// Concrete descriptor (public so gpu_screen_processor.dart can access fields across
// the library boundary without using `part`).
// Prefer the ScreenEffect factories rather than constructing this directly.
// ---------------------------------------------------------------------------

/// WGSL-based [ScreenEffect] descriptor.
///
/// Use the [ScreenEffect.wgsl] or [ScreenEffect.vignette] factories rather
/// than constructing this directly.
final class WgslScreenEffect extends ScreenEffect {
  const WgslScreenEffect({required this.wgslSource, required this.extraParams});

  /// WGSL source that follows the standard binding convention.
  final String wgslSource;

  /// Extra `f32` values written into the params buffer starting at byte 8
  /// (after `width : u32` and `height : u32`).
  final List<double> extraParams;
}

// ---------------------------------------------------------------------------
// FlipScreenEffect
// ---------------------------------------------------------------------------

/// Mirrors the frame horizontally and/or vertically.
/// Created via [ScreenEffect.flip].
final class FlipScreenEffect extends ScreenEffect {
  const FlipScreenEffect({this.horizontal = false, this.vertical = false});

  final bool horizontal;
  final bool vertical;
  // outputSize is identity (same dimensions) — no override needed.
}

// ---------------------------------------------------------------------------
// RotateScreenEffect
// ---------------------------------------------------------------------------

/// Rotates the frame clockwise by [rotation]. Created via [ScreenEffect.rotate].
final class RotateScreenEffect extends ScreenEffect {
  const RotateScreenEffect({required this.rotation});

  final ScreenRotation rotation;

  @override
  (int, int) outputSize(int inW, int inH) {
    if (rotation == ScreenRotation.r180) return (inW, inH);
    return (inH, inW); // 90° and 270° swap width ↔ height
  }
}

// ---------------------------------------------------------------------------
// ScaleScreenEffect
// ---------------------------------------------------------------------------

/// Bilinear resize to [width]×[height]. Created via [ScreenEffect.scale].
final class ScaleScreenEffect extends ScreenEffect {
  const ScaleScreenEffect({required this.width, required this.height});

  final int width;
  final int height;

  @override
  (int, int) outputSize(int inW, int inH) => (width, height);
}

// ---------------------------------------------------------------------------
// CensorScreenEffect
// ---------------------------------------------------------------------------

/// Overlays a solid-colour rectangle over the frame in-place (dimensions
/// unchanged). Created via [ScreenEffect.censor].
final class CensorScreenEffect extends ScreenEffect {
  const CensorScreenEffect({
    required this.boxX,
    required this.boxY,
    required this.boxW,
    required this.boxH,
    this.color = 0xFF000000,
  });

  /// Left edge of the censor box in pixels.
  final int boxX;

  /// Top edge of the censor box in pixels.
  final int boxY;

  /// Width of the censor box in pixels.
  final int boxW;

  /// Height of the censor box in pixels.
  final int boxH;

  /// Fill colour packed as `R | G<<8 | B<<16 | A<<24`.
  /// Defaults to opaque black (`0xFF000000`).
  final int color;

  // outputSize is identity (same dimensions) — no override needed.
}

// ---------------------------------------------------------------------------
// Built-in vignette + warm grade shader
// ---------------------------------------------------------------------------

const _kVignetteWarmWgsl = r'''
// Radial vignette + warm colour grade.
// Standard binding convention:
//   @binding(0) pixels : array<u32>   RGBA8 in/out (one u32 per pixel)
//   @binding(1) params : Params       { width, height, strength, _pad }
struct Params {
  width    : u32,
  height   : u32,
  strength : f32,
  _pad     : f32,
};

@group(0) @binding(0) var<storage, read_write> pixels : array<u32>;
@group(0) @binding(1) var<storage, read_write> params : Params;

fn unpack(p : u32) -> vec4<f32> {
  return vec4<f32>(
    f32( p        & 0xFFu),
    f32((p >>  8u) & 0xFFu),
    f32((p >> 16u) & 0xFFu),
    f32((p >> 24u) & 0xFFu),
  ) / 255.0;
}

fn pack(c : vec4<f32>) -> u32 {
  let q = clamp(c, vec4<f32>(0.0), vec4<f32>(1.0)) * 255.0 + vec4<f32>(0.5);
  return  u32(q.x)
       | (u32(q.y) <<  8u)
       | (u32(q.z) << 16u)
       | (u32(q.w) << 24u);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  if (gid.x >= params.width || gid.y >= params.height) { return; }
  let idx = gid.y * params.width + gid.x;
  var c = unpack(pixels[idx]);

  // Radial vignette — normalised squared distance from centre.
  let cx = f32(params.width)  * 0.5;
  let cy = f32(params.height) * 0.5;
  let dx = f32(gid.x) - cx;
  let dy = f32(gid.y) - cy;
  let r2 = (dx * dx + dy * dy) / (cx * cx + cy * cy);
  let vig = 1.0 - r2 * 0.65 * params.strength;

  // Warm grade: boost R slightly, dampen B.
  let warm = vec3<f32>(1.06, 1.00, 0.92);
  let rgb = mix(c.rgb, c.rgb * warm * vig, params.strength);
  pixels[idx] = pack(vec4<f32>(rgb, c.a));
}
''';
