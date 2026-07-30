/// GPU RGBA→YUV420P conversion for the software/CPU-encode fallback path.
///
/// The implementation moved to `miniav_tools_codecs` as the canonical,
/// params-driven [GpuRgbaToYuv420Converter] (this file's BT.601-only WGSL was
/// its prior art — same quad-packing scheme, now matrix/range-parameterised
/// and byte-identical to the shared C and pure-Dart converters instead of a
/// private ×8192 variant). This shim keeps the recorder's original name and
/// call sites working; the API (`convertFromGpuBuffer` / `convertFromBytes`
/// with out-planes, `ySize`/`uvSize`) is unchanged, defaults are still BT.601
/// limited.
library;

export 'package:miniav_tools_codecs/gpu.dart' show GpuRgbaToYuv420Converter;

import 'package:miniav_tools_codecs/gpu.dart';

/// Legacy recorder name for the canonical converter.
typedef GpuYuv420Converter = GpuRgbaToYuv420Converter;
