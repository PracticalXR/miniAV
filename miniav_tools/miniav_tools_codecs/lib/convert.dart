/// Platform-neutral colour conversion — importable from ANY Dart target (web,
/// native, pure-Dart CLIs) with no FFI, no dart:io, no minigpu.
///
/// This is the boundary for consumers that only want the conversion math
/// (coefficient tables + pure-Dart YUV420<->RGBA loops) without pulling in the
/// codec backends: `import 'package:miniav_tools_codecs/convert.dart';`
///
/// The native-accelerated twin ([CpuFrameConverter], C loops, ~10-20x faster)
/// and the GPU converters live in the main `miniav_tools_codecs.dart` barrel;
/// all three implementations are byte-identical per matrix/range.
library;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show YuvColorMatrix, DecodedPixelLayout;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show YuvRgbCoeffs, RgbaYuvCoeffs;
export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show
        I420Planes,
        dartI420ToRgba,
        dartI420ToRgbaAsync,
        dartI422ToRgba,
        dartRgbaToI420,
        dartRgbaToI420Async;
