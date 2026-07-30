/// Scale policy applied to screen/display sources before encoding.
///
/// Pass to [RecorderBuilder.addScreen] or directly to
/// [ScreenRecorderSource.scale]. When a non-[none] policy is active
/// **and** the recorder has a live zero-copy GPU context, the downscale is
/// performed entirely on the GPU (WGSL compute + Dawn D3D11) so no
/// pixel data crosses the PCIe bus.
///
/// When zero-copy is unavailable the CPU-upload path is used instead, and
/// the policy is still applied (at lower priority — the source can also be
/// manually sized via [RecorderBuilder.addScreen]'s `width`/`height`
/// arguments, which take priority over the policy).
library;

/// Describes how to downscale a screen source before it reaches the encoder.
///
/// ### Variants
/// | Factory / const | Behaviour |
/// |---|---|
/// | [ScreenScalePolicy.none] | No scaling — encoder receives the raw capture dimensions. |
/// | [ScreenScalePolicy.h264Friendly] | Auto-downscale so the longest dimension is ≤ 4096, keeping the aspect ratio. On ultrawide / 4K+ displays this avoids the automatic H.264 → HEVC codec promotion. No-op when both dimensions are already ≤ 4096. |
/// | [ScreenScalePolicy.fixedSize] | Encode at an exact pixel size. Both dimensions are rounded to the nearest even value. |
/// | [ScreenScalePolicy.scaleFactor] | Uniform fractional scale (e.g. `0.5` = half each axis). Output is rounded to even values. |
sealed class ScreenScalePolicy {
  const ScreenScalePolicy();

  // ----- named const -------------------------------------------------------

  /// No downscaling.  The encoder receives the raw capture dimensions.
  static const none = _ScalePolicyNone();

  /// Auto-downscale so that `max(width, height) ≤ 4096`, preserving the
  /// source aspect ratio. This keeps H.264 hardware encoders in range on
  /// ultrawide / 4K+ displays, avoiding the automatic HEVC promotion.
  ///
  /// Returns `null` from [targetSize] when both dimensions are already ≤ 4096.
  static const h264Friendly = _ScalePolicyH264Friendly();

  // ----- factories ---------------------------------------------------------

  /// Encode at an explicit [width] × [height].
  /// Both values are rounded up to the nearest even integer.
  factory ScreenScalePolicy.fixedSize(int width, int height) =>
      _ScalePolicyFixed(width: _even(width), height: _even(height));

  /// Uniform fractional scale applied to both axes.
  ///
  /// [factor] must be in `(0, 1]`.  A value of `1.0` is equivalent to [none].
  /// Output dimensions are rounded up to the nearest even integer.
  factory ScreenScalePolicy.scaleFactor(double factor) {
    assert(factor > 0 && factor <= 1.0, 'scaleFactor must be in (0, 1]');
    return _ScalePolicyFactor(factor.clamp(0.001, 1.0));
  }

  // ----- API ---------------------------------------------------------------

  /// Returns the target `(width, height)` for a source of [srcW] × [srcH],
  /// or `null` when no downscaling is required.
  (int, int)? targetSize(int srcW, int srcH);

  // ----- helpers -----------------------------------------------------------

  /// Round [v] up to the nearest even integer (H.264/HEVC macroblock boundary).
  static int _even(int v) => v + (v & 1);
}

// ---------------------------------------------------------------------------
// Concrete implementations (private)
// ---------------------------------------------------------------------------

final class _ScalePolicyNone extends ScreenScalePolicy {
  const _ScalePolicyNone();

  @override
  (int, int)? targetSize(int srcW, int srcH) => null;

  @override
  String toString() => 'ScreenScalePolicy.none';
}

final class _ScalePolicyH264Friendly extends ScreenScalePolicy {
  const _ScalePolicyH264Friendly();

  static const int _maxDim = 4096;

  @override
  (int, int)? targetSize(int srcW, int srcH) {
    final maxSrc = srcW > srcH ? srcW : srcH;
    if (maxSrc <= _maxDim) return null; // already fits — no-op
    final scale = _maxDim / maxSrc;
    final dstW = ScreenScalePolicy._even((srcW * scale).ceil());
    final dstH = ScreenScalePolicy._even((srcH * scale).ceil());
    return (dstW, dstH);
  }

  @override
  String toString() => 'ScreenScalePolicy.h264Friendly';
}

final class _ScalePolicyFixed extends ScreenScalePolicy {
  const _ScalePolicyFixed({required this.width, required this.height});
  final int width;
  final int height;

  @override
  (int, int)? targetSize(int srcW, int srcH) {
    if (width == srcW && height == srcH) return null;
    return (width, height);
  }

  @override
  String toString() => 'ScreenScalePolicy.fixedSize($width, $height)';
}

final class _ScalePolicyFactor extends ScreenScalePolicy {
  const _ScalePolicyFactor(this.factor);
  final double factor;

  @override
  (int, int)? targetSize(int srcW, int srcH) {
    if (factor >= 1.0) return null;
    final dstW = ScreenScalePolicy._even((srcW * factor).ceil());
    final dstH = ScreenScalePolicy._even((srcH * factor).ceil());
    if (dstW == srcW && dstH == srcH) return null;
    return (dstW, dstH);
  }

  @override
  String toString() => 'ScreenScalePolicy.scaleFactor($factor)';
}
