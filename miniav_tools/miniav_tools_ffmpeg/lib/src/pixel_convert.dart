/// CPU pixel-format helpers for the FFmpeg encode/preview paths.
///
/// All COLOUR math (RGB<->YCbCr coefficients) is delegated to the canonical
/// shared converters in `miniav_tools_platform_interface` (`dartRgbaToI420` /
/// `dartI420ToRgba` / `dartI422ToRgba` — BT.601 limited by default, byte-exact
/// twins of the C/GPU converters in miniav_tools_codecs). This file only keeps
/// FORMAT plumbing: plane splitting/deinterleaving (NV12, YUY2) and channel
/// widening — data movement, not colour conversion.
library;

import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show dartI420ToRgba, dartI422ToRgba, dartRgbaToI420;

/// Result of preparing a frame for an FFmpeg encoder.
///
/// Buffers are tightly packed in YUV420P plane order: Y (w*h), U (w*h/4),
/// V (w*h/4). [yStride], [uStride], [vStride] are equal to width, width/2,
/// width/2 respectively.
class PreparedYuv420p {
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int width;
  final int height;

  const PreparedYuv420p({
    required this.y,
    required this.u,
    required this.v,
    required this.width,
    required this.height,
  });

  int get yStride => width;
  int get uStride => width ~/ 2;
  int get vStride => width ~/ 2;
}

/// Convert any supported source pixel format into tightly-packed YUV420P.
///
/// Supported sources (MVP):
///   - rgba32, bgra32 (8-bit, 4 bytes per pixel, no alpha in output)
///   - rgb24, bgr24
///   - i420 (passthrough; bytes assumed to be Y|U|V planes contiguous)
///   - nv12 (Y plane copied, UV deinterleaved)
PreparedYuv420p toYuv420p({
  required Uint8List src,
  required MiniAVPixelFormat format,
  required int width,
  required int height,
  List<int>? strides,
}) {
  if (width <= 0 || height <= 0 || width.isOdd || height.isOdd) {
    throw ArgumentError(
      'YUV420P requires even, positive dimensions; got ${width}x$height',
    );
  }

  switch (format) {
    case MiniAVPixelFormat.i420:
      return _splitI420(src, width, height);
    case MiniAVPixelFormat.nv12:
      return _nv12ToI420(src, width, height, strides);
    case MiniAVPixelFormat.yuy2:
      return _yuy2ToI420(src, width, height, strides);
    case MiniAVPixelFormat.rgba32:
      return _rgbaToYuv420p(src, width, height,
          srcBgrA: false, strides: strides);
    case MiniAVPixelFormat.bgra32:
      return _rgbaToYuv420p(src, width, height,
          srcBgrA: true, strides: strides);
    case MiniAVPixelFormat.rgb24:
      return _rgbToYuv420p(src, width, height, srcBgr: false);
    case MiniAVPixelFormat.bgr24:
      return _rgbToYuv420p(src, width, height, srcBgr: true);
    default:
      throw ArgumentError(
        'Unsupported source pixel format for FFmpeg encoder MVP: $format. '
        'Supported: rgba32, bgra32, rgb24, bgr24, i420, nv12. '
        'Convert via miniav_tools facade or libswscale.',
      );
  }
}

PreparedYuv420p _splitI420(Uint8List src, int w, int h) {
  final ySize = w * h;
  final cSize = (w * h) ~/ 4;
  if (src.length < ySize + 2 * cSize) {
    throw ArgumentError(
      'I420 source too small: have ${src.length}, need ${ySize + 2 * cSize}',
    );
  }
  return PreparedYuv420p(
    y: Uint8List.fromList(src.sublist(0, ySize)),
    u: Uint8List.fromList(src.sublist(ySize, ySize + cSize)),
    v: Uint8List.fromList(src.sublist(ySize + cSize, ySize + 2 * cSize)),
    width: w,
    height: h,
  );
}

PreparedYuv420p _nv12ToI420(Uint8List src, int w, int h, List<int>? strides) {
  final ySize = w * h;
  final yStride = (strides != null && strides.isNotEmpty) ? strides[0] : w;
  final uvStride = (strides != null && strides.length >= 2) ? strides[1] : w;
  // Validate enough bytes for tight or strided layout.
  final need = yStride * h + uvStride * (h ~/ 2);
  if (src.length < need) {
    throw ArgumentError(
      'NV12 source too small: have ${src.length}, '
      'need at least $need (yStride=$yStride, uvStride=$uvStride)',
    );
  }
  final y = Uint8List(ySize);
  for (var row = 0; row < h; row++) {
    y.setRange(row * w, (row + 1) * w, src, row * yStride);
  }
  final cw = w ~/ 2;
  final ch = h ~/ 2;
  final u = Uint8List(cw * ch);
  final v = Uint8List(cw * ch);
  final uvBase = yStride * h;
  for (var row = 0; row < ch; row++) {
    final srcRow = uvBase + row * uvStride;
    final dstRow = row * cw;
    for (var col = 0; col < cw; col++) {
      u[dstRow + col] = src[srcRow + col * 2];
      v[dstRow + col] = src[srcRow + col * 2 + 1];
    }
  }
  return PreparedYuv420p(y: y, u: u, v: v, width: w, height: h);
}

/// YUY2 (YUYV422) → I420. YUY2 packs 2 pixels in 4 bytes: Y0 U Y1 V.
/// Chroma is 4:2:2 horizontally; we vertically average pairs of rows to
/// produce 4:2:0.
PreparedYuv420p _yuy2ToI420(Uint8List src, int w, int h, List<int>? strides) {
  final yStride = (strides != null && strides.isNotEmpty) ? strides[0] : w * 2;
  final need = yStride * h;
  if (src.length < need) {
    throw ArgumentError(
      'YUY2 source too small: have ${src.length}, '
      'need at least $need (stride=$yStride)',
    );
  }
  final cw = w ~/ 2;
  final ch = h ~/ 2;
  final y = Uint8List(w * h);
  final u = Uint8List(cw * ch);
  final v = Uint8List(cw * ch);

  // Y plane: pick byte 0 and 2 of each YUYV quartet.
  for (var row = 0; row < h; row++) {
    final srcRow = row * yStride;
    final dstRow = row * w;
    for (var col = 0; col < cw; col++) {
      final p = srcRow + col * 4;
      y[dstRow + col * 2] = src[p];
      y[dstRow + col * 2 + 1] = src[p + 2];
    }
  }
  // U/V: average the two source rows that share a chroma row.
  for (var row = 0; row < ch; row++) {
    final srcRow0 = (row * 2) * yStride;
    final srcRow1 = (row * 2 + 1) * yStride;
    final dstRow = row * cw;
    for (var col = 0; col < cw; col++) {
      final p0 = srcRow0 + col * 4;
      final p1 = srcRow1 + col * 4;
      u[dstRow + col] = (src[p0 + 1] + src[p1 + 1] + 1) >> 1;
      v[dstRow + col] = (src[p0 + 3] + src[p1 + 3] + 1) >> 1;
    }
  }
  return PreparedYuv420p(y: y, u: u, v: v, width: w, height: h);
}

PreparedYuv420p _rgbaToYuv420p(
  Uint8List src,
  int w,
  int h, {
  required bool srcBgrA,
  List<int>? strides,
}) {
  // Source row stride in bytes. Capture APIs (DXGI, V4L2) often return
  // rows padded to an alignment > w*4. When `strides` is provided, honor
  // it; otherwise assume tightly packed.
  final srcStride = (strides != null && strides.isNotEmpty && strides[0] > 0)
      ? strides[0]
      : w * 4;
  if (src.length < srcStride * h) {
    throw ArgumentError(
      'BGRA/RGBA source too small: have ${src.length}, '
      'need ${srcStride * h} (stride=$srcStride, h=$h)',
    );
  }
  // Canonical shared converter (BT.601 limited) — byte-identical to the C /
  // GPU encode-side converters, so a CPU<->GPU path switch can't shift colour.
  final p = dartRgbaToI420(src, w, h,
      bgra: srcBgrA, srcStrideBytes: srcStride);
  return PreparedYuv420p(y: p.y, u: p.u, v: p.v, width: w, height: h);
}

PreparedYuv420p _rgbToYuv420p(
  Uint8List src,
  int w,
  int h, {
  required bool srcBgr,
}) {
  // Reuse the RGBA path by widening (cheap for an MVP).
  final wide = Uint8List(w * h * 4);
  for (var i = 0, j = 0; i < w * h; i++, j += 3) {
    final base = i * 4;
    wide[base] = src[j];
    wide[base + 1] = src[j + 1];
    wide[base + 2] = src[j + 2];
    wide[base + 3] = 255;
  }
  return _rgbaToYuv420p(wide, w, h, srcBgrA: srcBgr);
}

/// Convert a decoded YUV420P plane set back into RGBA (for tests + previews).
Uint8List yuv420pToRgba({
  required Uint8List y,
  required Uint8List u,
  required Uint8List v,
  required int width,
  required int height,
  int yStride = 0,
  int uStride = 0,
  int vStride = 0,
}) =>
    dartI420ToRgba(y, u, v, width, height,
        strideY: yStride, strideU: uStride, strideV: vStride);

/// Convert YUY2 / NV12 / I420 (or pass through RGBA/BGRA) to tightly-packed
/// BGRA32 (b, g, r, 0xff per pixel). Used by HW encoders that take a packed
/// 4-byte RGB layout (NVENC's `bgr0`, AMF, etc.) when the source is YUV.
///
/// Returns [src] unchanged when [format] is already BGRA32 — caller can
/// detect by reference-equality and skip work. RGBA32 is byte-swapped.
Uint8List toBgra32({
  required Uint8List src,
  required MiniAVPixelFormat format,
  required int width,
  required int height,
  List<int>? strides,
}) {
  switch (format) {
    case MiniAVPixelFormat.bgra32:
      return src;
    case MiniAVPixelFormat.rgba32:
      return _swapRb(src, width, height);
    case MiniAVPixelFormat.yuy2:
      return _yuy2ToBgra32(src, width, height, strides);
    case MiniAVPixelFormat.nv12:
      return _nv12ToBgra32(src, width, height, strides);
    case MiniAVPixelFormat.i420:
      return _i420ToBgra32(src, width, height);
    default:
      throw ArgumentError(
        'Unsupported source pixel format for toBgra32: $format. '
        'Supported: rgba32, bgra32, yuy2, nv12, i420.',
      );
  }
}

Uint8List _swapRb(Uint8List src, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = src[i + 2];
    out[i + 1] = src[i + 1];
    out[i + 2] = src[i];
    out[i + 3] = src[i + 3];
  }
  return out;
}

Uint8List _yuy2ToBgra32(Uint8List src, int w, int h, List<int>? strides) {
  final yStride = (strides != null && strides.isNotEmpty) ? strides[0] : w * 2;
  // Deinterleave to I422 planes (keeps FULL vertical chroma resolution — no
  // 4:2:0 downsample), then one shared-converter pass straight to BGRA.
  final cw = (w + 1) >> 1;
  final y = Uint8List(w * h);
  final u = Uint8List(cw * h);
  final v = Uint8List(cw * h);
  for (var row = 0; row < h; row++) {
    final srcRow = row * yStride;
    final yRow = row * w;
    final cRow = row * cw;
    for (var col = 0; col < cw; col++) {
      final p = srcRow + col * 4;
      y[yRow + col * 2] = src[p];
      if (col * 2 + 1 < w) y[yRow + col * 2 + 1] = src[p + 2];
      u[cRow + col] = src[p + 1];
      v[cRow + col] = src[p + 3];
    }
  }
  return dartI422ToRgba(y, u, v, w, h, bgra: true);
}

Uint8List _nv12ToBgra32(Uint8List src, int w, int h, List<int>? strides) {
  final p = _nv12ToI420(src, w, h, strides);
  return dartI420ToRgba(p.y, p.u, p.v, w, h, bgra: true);
}

Uint8List _i420ToBgra32(Uint8List src, int w, int h) {
  final ySize = w * h;
  final cw = w ~/ 2;
  final cSize = cw * (h ~/ 2);
  return dartI420ToRgba(
    Uint8List.sublistView(src, 0, ySize),
    Uint8List.sublistView(src, ySize, ySize + cSize),
    Uint8List.sublistView(src, ySize + cSize, ySize + 2 * cSize),
    w,
    h,
    bgra: true,
  );
}
