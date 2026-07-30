/// Web stub for [YuvRgbaConverter]. The CPU present fallback is native-only
/// (web presents a decoded `VideoFrame` directly and never constructs a
/// [VideoFramePresenter]); this exists solely so `video_presenter.dart` stays
/// free of `dart:ffi` when compiled for web.
library;

import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart'
    show DecodedPixelLayout, YuvColorMatrix;

class YuvRgbaConverter {
  Uint8List i420ToRgba(Uint8List yuv, int width, int height) =>
      throw UnsupportedError('CPU YUV->RGBA fallback is not available on web');

  Uint8List toRgba(DecodedPixelLayout layout, Uint8List yuv, int width,
          int height,
          {bool fullRange = false,
          YuvColorMatrix matrix = YuvColorMatrix.bt601}) =>
      throw UnsupportedError('CPU YUV->RGBA fallback is not available on web');

  void dispose() {}
}
