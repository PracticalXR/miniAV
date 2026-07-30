# miniav_tools_ffmpeg

FFmpeg backend for [`miniav_tools`](../miniav_tools).
Wraps `libavcodec` / `libavformat` / `libavutil` over FFI and self-registers
with the `miniav_tools_platform_interface` registry on import.

> Call `registerFfmpegBackend()` once at startup (idempotent) — importing
> the library alone does **not** register it, because Dart top-level finals
> are lazy. Apps using `miniav_recorder` get this for free:
> `Recorder.warmup()` and `Recorder.start()` both register the backend.
> Once registered, `MiniAVTools.createEncoder(...)` etc. will pick this
> backend whenever it can satisfy the requested codec/container.

## What it provides

- **Software encoders**: H.264 / HEVC / VP9 / VP8 / AV1 / MJPEG / ProRes via
  libx264, libx265, libvpx, libaom, etc.
- **Stage A hardware encoders** (CPU frame in → encoded packet out):
  NVENC, AMF, QSV, VideoToolbox, MediaFoundation, V4L2 M2M.
- **Stage B zero-copy D3D11 encoder** on Windows: takes an
  `ID3D11Texture2D` NT shared handle directly. No PCIe transfer, no colour
  conversion, no readback. See [Stage B](#stage-b--zero-copy-d3d11-windows).
- **Muxers**: MP4, Matroska/WebM, MPEG-TS — with file, byte-buffer, and
  streaming-callback outputs.
- **Decoder + demuxer** for the same set of codecs/containers.

## Auto-download of FFmpeg shared libraries

On first `ensureFFmpegLoaded()` (called implicitly by `createEncoder` etc.)
the package downloads BtbN's **LGPL** shared FFmpeg build for the current OS
into a per-user cache and loads the DLLs / `.so` from there. macOS has no
BtbN shared build — install via `brew install ffmpeg`; the loader probes the
Homebrew lib directories automatically.

### Why LGPL (and what it costs)

We pull the `lgpl` build, not the `gpl` one, so that products dynamically
linking these libraries are **not** subject to GPL copyleft — the LGPL build
keeps `libav*` under LGPL-2.1, which is safe for proprietary downstream use.
The trade-off: the LGPL build omits the GPL-only software encoders
**libx264 / libx265**, so there is no CPU-side H.264/HEVC fallback. Hardware
H.264/HEVC (NVENC / QSV / AMF / MediaFoundation / VideoToolbox) and software
VP8/VP9 (libvpx), AV1 (SVT-AV1), MJPEG and ProRes are all still present. On
Windows the `h264_mf` / `hevc_mf` MediaFoundation encoders act as the
universal H.264/HEVC fallback when no vendor SDK is available. The licence
variant is controlled by `kFfmpegLicense` in `ffmpeg_downloader.dart`; the
cache is namespaced per-variant so changing it forces a fresh download.

Default cache root (the release tag is appended as a subdirectory):

| OS | Cache root |
|---|---|
| Windows | `%LOCALAPPDATA%\miniav_tools\ffmpeg` |
| Linux | `$XDG_CACHE_HOME/miniav_tools/ffmpeg` (or `~/.cache/miniav_tools/ffmpeg`) |
| macOS | `~/Library/Caches/miniav_tools/ffmpeg` (auto-download not available — see above) |

Environment variables:

| Variable | Effect |
|---|---|
| `MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1` | Disable auto-download — caller must set `FFMPEG_LIB_DIR` or install FFmpeg system-wide |
| `MINIAV_TOOLS_FFMPEG_CACHE=<path>` | Override the cache root |
| `FFMPEG_LIB_DIR=<path>` | Probe FFmpeg libs from a specific directory first |

Concurrent processes are safe: downloaders serialise on an OS-level file
lock inside the cache and re-probe after acquiring it, so two app instances
starting at once produce one download.

## Warming up FFmpeg

On a fresh machine the first `createEncoder` / `Recorder.start()` blocks on
the download + extraction (tens of MB — seconds to minutes depending on the
connection). Warm up at app startup instead so the first recording starts
instantly.

**Simplest — load (and download if needed) ahead of time:**

```dart
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

// At app startup. Returns true once libav* are loaded. Safe to call
// repeatedly; a no-op when the cache is already populated.
final ok = await ensureFFmpegLoaded(
  onDownloadProgress: (received, total) =>
      print('ffmpeg: $received / $total'),
);
```

**With UI progress — `MiniAVTools.warmup()`:**

Runs every registered backend's warmup tasks (this backend reports a
`"Downloading FFmpeg"` task) and streams `WarmupProgress` events. The stream
never errors — failures arrive as events with `error` set — so no `onError`
handler is needed.

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

registerFfmpegBackend(); // required — warmup only covers registered backends

MiniAVTools.warmup().listen(
  (p) {
    if (p.fraction != null) {
      setState(() => _downloadProgress = p.fraction!); // 0.0 – 1.0
    }
  },
  onDone: () => setState(() => _ready = true),
);

// Or block until everything is warm:
await MiniAVTools.warmup().last;
```

Apps built on `miniav_recorder` should call `Recorder.warmup()` instead —
same stream, but it registers this backend first and needs no extra import.

**Lower level — direct downloader control:**

```dart
final result = await FfmpegDownloader.ensureFfmpeg(
  progress: (received, total) { /* total is -1 when unknown */ },
  force: true, // re-download even if a cached install exists
);
print(result?.libDir); // directory the DLLs were loaded from
```

On Windows, hardware-encoder SDKs (QSV / MF / NVENC / AMF) also have a
one-time driver cold-start. The recorder triggers `ffmpegD3d11WarmUp`
automatically when zero-copy is enabled, so the first session doesn't fall
back to CPU; direct users of `FfmpegD3d11HwEncoder` can call it themselves
after `ensureFFmpegLoaded()`.

## Logging

All Dart-side diagnostics (downloader, encoder selection, vendor probing,
fallbacks) flow through one hook:

```dart
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

setFfmpegToolsLogLevel(MiniAVLogLevel.debug); // default: info
setFfmpegToolsLogCallback((level, msg) => myLogger.log(level, msg));
```

Without a callback, messages go to `print` — deliberately **not** `dart:io`
`stderr`/`stdout`: in a console-less Windows GUI app (a packaged Flutter
desktop build) the OS stdio handles are invalid and `dart:io` stdio writes
crash with an uncatchable async `FileSystemException` (errno 6). Custom
callbacks should avoid `stderr` for the same reason.

Native `av_log` messages from the FFmpeg libraries are a separate stream,
bridged via `FfmpegShim.setFfmpegLogCallback`.

Apps using `miniav_recorder` don't need any of this directly:
`Recorder.setLogCallback` / `Recorder.setLogLevel` wire both hooks (plus
MiniAV and minigpu) automatically, tagging messages from this package as
`RecorderLogSource.ffmpeg`.

## Stage B — zero-copy D3D11 (Windows)

When the source frame already lives in a D3D11 texture (DXGI screen
capture, minigpu compute output, browser GPU canvas via D3D11 interop, …)
the encoder pulls it straight into the hwframes pool with a single
`CopySubresourceRegion` between two GPU-resident textures.

```dart
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

await ensureFFmpegLoaded();

final enc = FfmpegD3d11HwEncoder.open(EncoderConfig(
  codec: VideoCodec.hevc,
  width: 1920, height: 1080,
  bitrateBps: 6_000_000,
  hwAccel: HwAccelPreference.required,
));

final pkt = await enc.encode(FrameSource.d3d11Texture(
  texturePtr: ntHandle.address,        // DXGI NT shared handle
  width: 1920, height: 1080,
  pixelFormat: MiniAVPixelFormat.bgra32,
  timestampUs: i * 33333,
));
```

### Vendor selection

`open(cfg, vendorOrder: ...)` walks the list in priority order, opens the
first vendor that succeeds, and returns the encoder. The default order is
**AMF → QSV → MediaFoundation**. NVENC has its own CUDA path and is
selected automatically by `FfmpegHwEncoder.open` when zero-copy is
requested with an NVIDIA GPU.

To force a single vendor and surface the raw failure, call:

```dart
final enc = FfmpegD3d11HwEncoder.openWith(cfg, D3d11HwVendor.amf);
```

### Sharing a `ID3D11Device` with another GPU API (`existingD3d11Device`)

Cross-API NT-handle sharing only works **when both producer and consumer
are on the same DXGI adapter.** Different adapters fail with
`E_INVALIDARG` from `OpenSharedResource1`. To pin FFmpeg's D3D11 device to
a specific adapter — typically the one Dawn / WebGPU is already using —
pass an existing `ID3D11Device*`:

```dart
// 1) Get the cached D3D11 device that minigpu created on the Dawn adapter.
final d3d11DevicePtr = gpu.createD3D11DeviceOnDawnAdapter();

// 2) Hand it to FFmpeg. FFmpeg AddRef's the device; you may continue to
//    use it for your own work.
final enc = FfmpegD3d11HwEncoder.openWith(
  cfg,
  D3d11HwVendor.nvenc,                  // or .amf / .qsv / .mediaFoundation
  existingD3d11Device: d3d11DevicePtr,  // address of an ID3D11Device*
);
```

When `existingD3d11Device == 0` (the default) FFmpeg creates its own
device on adapter 0 (the display adapter) — fine for the single-adapter
case.

### Source texture format (`sourceTextureFormat`)

The hwframes pool the encoder allocates is bound to a single DXGI format.
`CopySubresourceRegion` requires the source and destination textures to
be in the **same DXGI type group** (BGRA cannot be copied to RGBA), so
the pool's `sw_format` must match the format of the textures the caller
will hand the encoder in `encode(...)`.

| `sourceTextureFormat` | DXGI source format | Use for |
|---|---|---|
| `D3d11HwSourceFormat.bgra` (default) | `DXGI_FORMAT_B8G8R8A8_UNORM` | DXGI Desktop Duplication, Windows.Graphics.Capture, miniav screen capture, minigpu `SharedOutputTexture` (BGRA8 storage) |
| `D3d11HwSourceFormat.rgba` | `DXGI_FORMAT_R8G8B8A8_UNORM` | Direct copies from RGBA8 storage textures (some custom WebGPU pipelines) |

Not every driver accepts RGBA in a D3D11VA hwframes pool — if it doesn't,
`av_hwframe_ctx_init` returns an error and `openWith` raises a
`CodecInitException` describing the format. BGRA is universally supported
on AMF / QSV / NVENC / MediaFoundation, which is why it is the default.

## Tests

```pwsh
dart test                                 # full suite
dart test test/d3d11_hw_encoder_test.dart # Stage B only
```

Tests are tagged `windows-gpu` and skip cleanly on machines without
FFmpeg, the shim asset, or a D3D11VA-capable encoder. The end-to-end test
synthesises an NT-shared BGRA texture via the test-only shim helpers — no
display or capture device required.

## License

Apache 2.0
