/// GPU (minigpu) video utilities for miniav_tools_codecs — WEB-SAFE.
///
/// A separate entry point (not the main `miniav_tools_codecs.dart` barrel, which
/// pulls the native `dart:ffi` codec bindings) so a consumer — including one
/// compiled for web, or a non-Flutter tool — can use the GPU converters without
/// dragging in the native asset. Depends only on `minigpu` (web-capable) and the
/// pure-Dart platform interface.
library;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show YuvRgbCoeffs, RgbaYuvCoeffs;
export 'src/gpu/gpu_planar_yuv_converter.dart'
    show GpuPlanarYuvToRgbaConverter, kPlanarYuvToRgbaBt601Wgsl;
export 'src/gpu/gpu_rgba_yuv420_converter.dart'
    show GpuRgbaToYuv420Converter, kRgbaToYuv420Wgsl;
