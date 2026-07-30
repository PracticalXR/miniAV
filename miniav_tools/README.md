# miniav_tools

Cross-platform audio/video **codec & container** tooling for the [miniav](../miniAV) capture stack and [minigpu](../minigpu) compute stack.

`miniav_tools` is the third pillar of the trio:

| Package | Concern | Direction |
|---------|---------|-----------|
| `miniav` | **Sources** — capture frames from cameras, screens, microphones, system audio | Hardware → buffer |
| `minigpu` | **Compute** — run WGSL compute shaders, manipulate GPU tensors | Buffer ↔ GPU |
| `miniav_tools` | **Codecs & containers** — encode/decode/mux/demux audio & video | Buffer ↔ bitstream/file |

## Repository structure

This repo follows the federated-plugin pattern used by `miniav` and `minigpu`:

```text
miniav_tools/
├── miniav_tools/                          ← User-facing facade. Depend on this.
├── miniav_tools_platform_interface/       ← Pure-Dart contracts. Backends implement.
├── miniav_tools_ffmpeg/                   ← FFmpeg backend (FFI; libavcodec/libavformat)
├── miniav_tools_minigpu/                  ← Pure-GPU/WGSL codec backend
├── miniav_tools_web/                      ← Browser backend (WebCodecs API)
└── examples/
    └── screenshare_mp4/                   ← Working end-to-end screenshare demo
```

## Quick start

Add the facade and one backend to your `pubspec.yaml`:

```yaml
dependencies:
  miniav_tools: ^0.1.0
  miniav_tools_ffmpeg: ^0.1.0   # FFmpeg backend (Windows/Linux/macOS)
  # miniav_tools_minigpu: ^0.1.0  # pure-GPU backend (MJPEG, any platform)
```

Import the backend package — importing it auto-registers it with the facade:

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'; // self-registers
```

FFmpeg shared libraries are **auto-downloaded on first run** (BtbN GPL-shared build,
~92 MB on Windows). Set `MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1` to disable.

---

## Usage

### Encode frames to H.264

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

// Create an encoder. hwAccel=preferred → tries NVENC/AMF/QSV/VideoToolbox
// in platform order, falls back to libx264 if none are available.
final encoder = await MiniAVTools.createEncoder(EncoderConfig(
  codec: VideoCodec.h264,
  width: 1920,
  height: 1080,
  bitrateBps: 8_000_000,
  frameRateNumerator: 60,
  frameRateDenominator: 1,
  hwAccel: HwAccelPreference.preferred,
));

// Feed CPU RGBA frames.
final EncodedPacket? pkt = await encoder.encode(
  CpuFrameSource(
    bytes: rgbaBytes,          // Uint8List, width*height*4
    pixelFormat: MiniAVPixelFormat.rgba32,
    width: 1920,
    height: 1080,
    timestampUs: frameIndex * 16667,
  ),
);
```

### Mux to MP4

```dart
// Open a muxer. The encoder's trackInfo carries SPS/PPS extradata.
final muxer = await MiniAVTools.createMuxer(MuxerConfig(
  container: Container.mp4,
  output: MuxerOutput.file('output.mp4'),
  tracks: [encoder.trackInfo],
));
await muxer.open();

// Write packets.
if (pkt != null) await muxer.writePacket(pkt);

// Flush encoder, drain remaining packets, then close.
for (final p in await encoder.flush()) {
  await muxer.writePacket(p);
}
await muxer.close();
await encoder.close();
```

### Mux to a byte buffer or streaming callback

```dart
// Collect all bytes in memory.
final muxer = await MiniAVTools.createMuxer(MuxerConfig(
  container: Container.mp4,
  output: MuxerOutput.bytes(),
  tracks: [encoder.trackInfo],
));
// ...
final Uint8List mp4Bytes = await muxer.close(); // returns accumulated bytes

// Or stream chunks as they are produced.
MuxerOutput.callback((Uint8List chunk) => socket.add(chunk))
```

### Force a specific hardware vendor

```dart
// Require NVENC — throw CodecInitException if unavailable.
final encoder = await MiniAVTools.createEncoder(EncoderConfig(
  codec: VideoCodec.h264,
  width: 3840, height: 2160,
  bitrateBps: 20_000_000,
  hwAccel: HwAccelPreference.required,
  backendOptions: {'vendor': 'nvenc', 'preset': 'p4', 'tune': 'hq'},
));
```

### Stage B — true zero-copy D3D11 encode (Windows)

When the frame source is a D3D11 shared texture (e.g. from miniav screen
capture), pass the handle directly without any CPU readback:

```dart
final encoder = await MiniAVTools.createEncoder(EncoderConfig(
  codec: VideoCodec.h264,
  width: captureWidth,
  height: captureHeight,
  bitrateBps: 8_000_000,
  hwAccel: HwAccelPreference.required,
  backendOptions: const {'zerocopy': '1'}, // ← enables Stage B
));

// Pass a D3D11 NT handle — no PCIe transfer, no colour conversion.
final pkt = await encoder.encode(
  D3d11TextureFrameSource(handle: buf.nativeHandle, timestampUs: ts),
);
```

Stage B requires AMF, QSV, or MediaFoundation in the FFmpeg build. NVENC uses
its own CUDA path and works automatically when `zerocopy=1` is set.

### Pure-GPU MJPEG (any platform, no FFmpeg)

```dart
import 'package:miniav_tools_minigpu/miniav_tools_minigpu.dart';

final encoder = await MinigpuBackend().createEncoder(EncoderConfig(
  codec: VideoCodec.mjpeg,
  width: 1280,
  height: 720,
  bitrateBps: 0,          // MJPEG uses crfQuality instead
  crfQuality: 5,          // 1 (best) – 31 (worst), maps to JPEG q90–q10
  frameRateNumerator: 30,
  frameRateDenominator: 1,
  inputPixelFormat: MiniAVPixelFormat.rgba32,
));

final pkt = await encoder!.encode(CpuFrameSource(
  bytes: rgbaBytes,
  pixelFormat: MiniAVPixelFormat.rgba32,
  width: 1280, height: 720,
  timestampUs: 0,
));
// pkt.bytes is a self-contained JFIF stream (valid JPEG, plays in QuickTime,
// VLC, browsers, ffmpeg, etc.)
```

The MJPEG backend runs entirely on WebGPU compute shaders
(RGBA→YCbCr→DCT→Quantize→Huffman→JFIF) with no native dependencies.

---

## Hardware encoder matrix

| Vendor | Codecs | Platform | Stage A (CPU frame) | Stage B (zero-copy) |
|---|---|---|---|---|
| NVIDIA NVENC | H.264 / HEVC / AV1 | Windows, Linux | ✅ | ✅ D3D11 texture |
| AMD AMF | H.264 / HEVC / AV1 | Windows | ✅ | ✅ D3D11 texture |
| Intel QSV | H.264 / HEVC / AV1 / VP9 | Windows, Linux | ✅ | ✅ D3D11 texture |
| Apple VideoToolbox | H.264 / HEVC | macOS, iOS | ✅ | ⬜ CVPixelBuffer (todo) |
| Windows MediaFoundation | H.264 / HEVC | Windows | ✅ | ✅ D3D11 texture |
| Linux V4L2 M2M | H.264 / HEVC | Linux, RPi | ✅ | ⬜ DMA-BUF (todo) |
| VAAPI | H.264 / HEVC | Linux | ⬜ todo | ⬜ todo |
| Software libx264/x265 | H.264 / HEVC | All | ✅ | — |
| minigpu WGSL | MJPEG | All (WebGPU) | ✅ | — |

Auto-selection order (Stage A):

- **Windows**: NVENC → AMF → QSV → MediaFoundation → libx264
- **macOS**: VideoToolbox → libx264
- **Linux**: NVENC → QSV → V4L2 → libx264

For widths > 4096 (e.g. ultrawide 5120×1440) the encoder automatically
promotes H.264 to HEVC, since H.264 hardware encoders cap at 4096 px.

---

## Environment variables

| Variable | Effect |
|---|---|
| `MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1` | Disable auto-download of FFmpeg libs |
| `MINIAV_TOOLS_FFMPEG_CACHE=<path>` | Override FFmpeg library cache directory |
| `MINIAV_TOOLS_FFMPEG_NETTEST=1` | Enable network-dependent tests |
| `FFMPEG_LIB_DIR=<path>` | Use FFmpeg libs from a specific directory |

---

## Status

| Component | Status |
|-----------|--------|
| Platform interface + types | ✅ |
| Facade + backend registry | ✅ |
| FFmpeg auto-download (Windows/Linux) | ✅ |
| FFmpeg software encode — H.264/HEVC/VP9/VP8/AV1/MJPEG/ProRes | ✅ |
| FFmpeg hardware encode Stage A — NVENC/AMF/QSV/VT/MF/V4L2 | ✅ |
| FFmpeg hardware encode Stage B — D3D11 zero-copy (Win) | ✅ |
| FFmpeg MP4/MKV/TS muxer | ✅ |
| FFmpeg decoder | ✅ |
| minigpu MJPEG encoder (pure WGSL, all platforms) | ✅ |
| WebCodecs backend (VideoEncoder + MediaRecorder fallback) | ✅ |
| Browser smoke tests (`dart test -p chrome`) | ✅ |
| VideoToolbox CVPixelBuffer zero-copy (Stage B macOS) | 📋 Planned |
| fMP4/WebM JS muxer for WebCodecs | 📋 Planned |
| WebCodecs AudioEncoder | 📋 Planned |
| VAAPI encoder (Linux AMD/Intel) | 📋 Planned |

See [miniav_tools_design.MD](miniav_tools_design.MD) for the full architecture.

## Example: screenshare to MP4

A working end-to-end demo is in [`examples/screenshare_mp4/`](examples/screenshare_mp4/):

```
dart run bin/screenshare_mp4.dart [seconds] [output.mp4] [options]

Options:
  --hw              Use hardware encoder (NVENC→AMF→QSV→VT→MF probe order)
  --zerocopy        Stage B: D3D11 texture direct to encoder (no PCIe transfer)
  --effect          Apply a minigpu vignette+warmth shader before encoding
  --effect-shader=  Path to a custom WGSL effect shader file
  --effect-strength=  Shader strength 0.0–1.0 (default 1.0)
  --gpu / --no-gpu  Force GPU or CPU readback path
  --duration        Recording duration in seconds (default 10)
```

---

## Web / Browser

On the browser the `miniav_tools_web` backend wraps the
[WebCodecs API](https://www.w3.org/TR/webcodecs/).

```yaml
dependencies:
  miniav_tools: ^0.1.0
  miniav_tools_web: ^0.1.0
```

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_web/miniav_tools_web.dart'; // auto-registers

// Check capabilities at runtime:
if (WebCapability.hasVideoEncoder) {
  final encoder = await MiniAVTools.createEncoder(EncoderConfig(
    codec: VideoCodec.h264,
    width: 1280, height: 720,
    bitrateBps: 4_000_000,
  ));
} else {
  // Fallback: MediaRecorder stream-level recording
  final capture = MediaRecorderCapture(
    stream: displayMediaStream,
    mimeType: MediaRecorderCapture.preferredMimeType,
    onChunk: (bytes) => sink.add(bytes),
  );
  await capture.start();
}
```

Degradation tiers:

| Tier | Condition | Path |
|------|-----------|------|
| **Full** | WebGPU + WebCodecs | GPU effects (WGSL via `minigpu_web`) + `VideoEncoder` |
| **Encode-only** | WebCodecs, no WebGPU | GPU effects skipped; `VideoEncoder` works |
| **Fallback** | No WebCodecs | `MediaRecorderCapture` wraps `MediaRecorder` |

Run browser tests:

```
cd miniav_tools_web
dart test -p chrome
```

---

## Benchmarks

### FFmpeg encoder throughput

```
cd miniav_tools_ffmpeg
dart pub get
dart run benchmark/encoder_bench.dart
```

Set `BENCH_HW=1` to also benchmark hardware encoders (NVENC/AMF/QSV/etc).
Set `BENCH_MUXER=1` to benchmark muxer write throughput.

### minigpu MJPEG throughput

```
cd miniav_tools_minigpu
dart pub get
dart run benchmark/mjpeg_bench.dart
```

---

## Example: screenshare to MP4

## License

MIT License. See [LICENSE](LICENSE) for details.
