/// Canonical BT.601 ×256 fixed-point YCbCr→RGB coefficients — the single source
/// of truth shared by the native C converter (`frame_convert.c`), the unified
/// GPU WGSL converter, and the CPU reference. Keeping one table here is what
/// makes "the GPU output is byte-identical to the CPU output" a maintainable
/// invariant instead of three drifting copies.
///
///   c = Y - yOff;  d = U - 128;  e = V - 128
///   R = (c*yMul + rV*e         + 128) >> 8
///   G = (c*yMul - gU*d - gV*e  + 128) >> 8
///   B = (c*yMul + bU*d         + 128) >> 8
library;

import '../platform_codec.dart' show YuvColorMatrix;

class YuvRgbCoeffs {
  const YuvRgbCoeffs({
    required this.yOff,
    required this.yMul,
    required this.rV,
    required this.gU,
    required this.gV,
    required this.bU,
  });

  final int yOff, yMul, rV, gU, gV, bU;

  /// BT.601 limited/studio range (Y∈[16,235], C∈[16,240]) — the default for
  /// `yuv420p`/`yuv422p`/`yuv444p` and the 10-bit variants.
  static const YuvRgbCoeffs bt601Limited =
      YuvRgbCoeffs(yOff: 16, yMul: 298, rV: 409, gU: 100, gV: 208, bU: 516);

  /// BT.601 full/JPEG range (Y,C∈[0,255]) — for `yuvj420p`/`yuvj422p`/`yuvj444p`.
  static const YuvRgbCoeffs bt601Full =
      YuvRgbCoeffs(yOff: 0, yMul: 256, rV: 359, gU: 88, gV: 183, bU: 454);

  /// BT.709 limited range — HD content whose bitstream declares BT.709
  /// (R=1.164·C+1.793·E, G=1.164·C−0.213·D−0.533·E, B=1.164·C+2.112·D).
  static const YuvRgbCoeffs bt709Limited =
      YuvRgbCoeffs(yOff: 16, yMul: 298, rV: 459, gU: 55, gV: 136, bU: 541);

  /// BT.709 full range (R=Y+1.5748·E, G=Y−0.1873·D−0.4681·E, B=Y+1.8556·D).
  static const YuvRgbCoeffs bt709Full =
      YuvRgbCoeffs(yOff: 0, yMul: 256, rV: 403, gU: 48, gV: 120, bU: 475);

  /// BT.2020 NCL limited range (Kr=0.2627, Kb=0.0593; matrix only — PQ/HLG
  /// transfer is NOT applied by the converters, see [YuvColorMatrix.bt2020]).
  static const YuvRgbCoeffs bt2020Limited =
      YuvRgbCoeffs(yOff: 16, yMul: 298, rV: 430, gU: 48, gV: 167, bU: 548);

  /// BT.2020 NCL full range.
  static const YuvRgbCoeffs bt2020Full =
      YuvRgbCoeffs(yOff: 0, yMul: 256, rV: 378, gU: 42, gV: 146, bU: 482);

  static YuvRgbCoeffs forRange({required bool fullRange}) =>
      fullRange ? bt601Full : bt601Limited;

  /// Select by matrix + range. [bt709] picks the 709 tables; anything else
  /// (the miniAV default) picks 601. Prefer [of] for the full matrix set.
  static YuvRgbCoeffs select({required bool bt709, required bool fullRange}) =>
      bt709
          ? (fullRange ? bt709Full : bt709Limited)
          : (fullRange ? bt601Full : bt601Limited);

  /// Select by [YuvColorMatrix] + range — the canonical selector; mirrors the
  /// C `pick()` in frame_convert.c exactly.
  static YuvRgbCoeffs of(YuvColorMatrix matrix, {required bool fullRange}) =>
      switch (matrix) {
        YuvColorMatrix.bt601 => fullRange ? bt601Full : bt601Limited,
        YuvColorMatrix.bt709 => fullRange ? bt709Full : bt709Limited,
        YuvColorMatrix.bt2020 => fullRange ? bt2020Full : bt2020Limited,
      };
}

/// Canonical ×256 fixed-point RGB→YCbCr coefficients — the inverse direction,
/// same single-source-of-truth contract as [YuvRgbCoeffs]. Shared by the native
/// C converter (`frame_convert.c` `miniav_rgba_to_i420`), the pure-Dart
/// converter (`rgba_yuv_dart.dart`, the web / no-FFI path), and the GPU WGSL
/// converter — all byte-identical.
///
///   Y = ((yR·R + yG·G + yB·B + 128) >> 8) + yOff
///   U = ((uR·R + uG·G + uB·B + 128) >> 8) + 128
///   V = ((vR·R + vG·G + vB·B + 128) >> 8) + 128       (each clamped to 0..255)
///
/// Tables are round(coef·256) of the matrix rows, Y scaled by 219/255 and
/// chroma by 224/255 for limited range, with two integer adjustments so the
/// obvious invariants hold exactly: each chroma row sums to 0 (neutral grey →
/// exactly 128) and each full-range luma row sums to 256 (white → 255).
class RgbaYuvCoeffs {
  const RgbaYuvCoeffs({
    required this.yR,
    required this.yG,
    required this.yB,
    required this.uR,
    required this.uG,
    required this.uB,
    required this.vR,
    required this.vG,
    required this.vB,
    required this.yOff,
  });

  final int yR, yG, yB, uR, uG, uB, vR, vG, vB, yOff;

  /// BT.601 limited range — the classic integer table (66/129/25 …), identical
  /// to the MSDN/JFIF-studio formulation most software encoders feed on.
  static const RgbaYuvCoeffs bt601Limited = RgbaYuvCoeffs(
      yR: 66, yG: 129, yB: 25,
      uR: -38, uG: -74, uB: 112,
      vR: 112, vG: -94, vB: -18,
      yOff: 16);

  /// BT.601 full/JPEG range.
  static const RgbaYuvCoeffs bt601Full = RgbaYuvCoeffs(
      yR: 77, yG: 150, yB: 29,
      uR: -43, uG: -85, uB: 128,
      vR: 128, vG: -107, vB: -21,
      yOff: 0);

  /// BT.709 limited range (Kr=0.2126, Kb=0.0722).
  static const RgbaYuvCoeffs bt709Limited = RgbaYuvCoeffs(
      yR: 47, yG: 157, yB: 16,
      uR: -26, uG: -86, uB: 112,
      vR: 112, vG: -102, vB: -10,
      yOff: 16);

  /// BT.709 full range.
  static const RgbaYuvCoeffs bt709Full = RgbaYuvCoeffs(
      yR: 54, yG: 183, yB: 19,
      uR: -29, uG: -99, uB: 128,
      vR: 128, vG: -116, vB: -12,
      yOff: 0);

  /// BT.2020 NCL limited range (Kr=0.2627, Kb=0.0593; matrix only, no PQ/HLG).
  static const RgbaYuvCoeffs bt2020Limited = RgbaYuvCoeffs(
      yR: 58, yG: 149, yB: 13,
      uR: -31, uG: -81, uB: 112,
      vR: 112, vG: -103, vB: -9,
      yOff: 16);

  /// BT.2020 NCL full range.
  static const RgbaYuvCoeffs bt2020Full = RgbaYuvCoeffs(
      yR: 67, yG: 174, yB: 15,
      uR: -36, uG: -92, uB: 128,
      vR: 128, vG: -118, vB: -10,
      yOff: 0);

  /// Select by [YuvColorMatrix] + range — mirrors the C `inv_pick()` in
  /// frame_convert.c exactly.
  static RgbaYuvCoeffs of(YuvColorMatrix matrix, {required bool fullRange}) =>
      switch (matrix) {
        YuvColorMatrix.bt601 => fullRange ? bt601Full : bt601Limited,
        YuvColorMatrix.bt709 => fullRange ? bt709Full : bt709Limited,
        YuvColorMatrix.bt2020 => fullRange ? bt2020Full : bt2020Limited,
      };
}
