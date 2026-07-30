# miniav_tools_minigpu

GPU compute codec backend for [`miniav_tools`](../miniav_tools), powered by
[minigpu](../../../minigpu) (WGSL via Google Dawn).  
Self-registers with the `miniav_tools_platform_interface` registry on import.

> Importing `package:miniav_tools_minigpu/miniav_tools_minigpu.dart` is enough.
> Once registered, `MiniAVTools.createEncoder(...)` will use this backend for
> codecs it supports at priority 30 (below WebCodecs, above software fallback).

## What it provides

- **MJPEG encoder** — DCT and VLC computed entirely in WGSL compute shaders.
  No libavcodec dependency; runs on any Dawn-capable GPU (Vulkan, D3D12, Metal).
- **`GpuCodecPipeline`** — composable pipeline abstraction for chaining compute
  passes (`kFrameInputKey` → … → `kEncodedOutputKey`).
- **`MinigpuMjpegPipeline`** — concrete MJPEG pipeline built on top of
  `GpuCodecPipeline`.

Planned (Phase B/C):
- VP8/VP9-style intra-only "raw GPU" codec for screen capture.
- Custom ML-inference-optimised video codec.

## Usage

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_minigpu/miniav_tools_minigpu.dart'; // self-registers

final encoder = await MiniAVTools.createEncoder(EncoderConfig(
  codec: VideoCodec.mjpeg,
  width: 1920, height: 1080,
));
```

### Direct pipeline access

```dart
import 'package:miniav_tools_minigpu/miniav_tools_minigpu.dart';

final pipeline = MinigpuMjpegPipeline();
await pipeline.init(width: 1920, height: 1080);

final encoded = await pipeline.encode(frame);
await pipeline.dispose();
```

## Supported codecs

| Codec | Encode | Decode |
|-------|--------|--------|
| MJPEG | ✅ | — |

## Dependencies

- [`minigpu`](../../../minigpu/minigpu) — GPU compute facade
- [`gpu_tensor`](../../../minigpu/gpu_tensor) — tensor buffers over Dawn
- [`gpu_pipeline`](../../../minigpu/gpu_pipeline) — shader pipeline helpers
- [`miniav_tools_platform_interface`](../miniav_tools_platform_interface)

## See also

- [miniav_tools](../miniav_tools) — user-facing facade
- [miniav_tools_ffmpeg](../miniav_tools_ffmpeg) — FFmpeg backend (software + hardware)
- [miniav_tools_web](../miniav_tools_web) — WebCodecs backend (browser)
- [Design doc](../miniav_tools_design.MD)
