/// CPU reference for the player's YUV420P → RGBA8 conversion.
///
/// This is the lockstep target for the WGSL kernel in `video_presenter.dart`.
/// The math is the canonical shared converter (`dartI420ToRgba` in
/// miniav_tools_platform_interface — BT.601 limited, ×256 fixed point,
/// byte-exact twin of the C and GPU converters); this wrapper only keeps the
/// player's packed-buffer signature and even-dims contract so
/// `tool/gpu_player_validate.dart` and the tests stay unchanged.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show dartI420ToRgba;

/// Convert tightly-packed YUV420P planes (Y `w*h` | U `w*h/4` | V `w*h/4`)
/// into interleaved RGBA8 (alpha = 0xFF). [w] and [h] must be even.
///
/// [out] must hold `w * h * 4` bytes; pass `null` to allocate.
Uint8List yuv420pToRgba8(Uint8List yuv, int w, int h, {Uint8List? out}) {
  if (w <= 0 || h <= 0 || w.isOdd || h.isOdd) {
    throw ArgumentError('YUV420P requires even, positive dims; got ${w}x$h');
  }
  final ySize = w * h;
  final cw = w >> 1;
  final uvSize = cw * (h >> 1);
  if (yuv.length < ySize + 2 * uvSize) {
    throw ArgumentError(
      'yuv buffer too small: ${yuv.length} < ${ySize + 2 * uvSize}',
    );
  }
  return dartI420ToRgba(
    Uint8List.sublistView(yuv, 0, ySize),
    Uint8List.sublistView(yuv, ySize, ySize + uvSize),
    Uint8List.sublistView(yuv, ySize + uvSize, ySize + 2 * uvSize),
    w,
    h,
    out: out,
  );
}
