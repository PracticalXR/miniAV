# miniav_recorder

High-level multi-source A/V recorder for Dart.  Combines screen, camera, microphone and loopback sources into one or more MP4/MKV/M4A/MP3 outputs (or live chunked streams) with a shared master clock.

Built on [`miniav`](../miniAV/miniav/) + [`miniav_tools`](../miniav_tools/) + [`miniav_tools_ffmpeg`](../miniav_tools_ffmpeg/).

---

## Quick start

```dart
import 'package:miniav_recorder/miniav_recorder.dart';

final rec = (RecorderBuilder()
      ..addScreen(codec: VideoCodec.h264, scale: ScreenScalePolicy.h264Friendly)
      ..addMic(deviceId: mic.deviceId)
      ..addFileOutput('output.mkv'))
    .build();

await rec.start();
await Future.delayed(const Duration(seconds: 10));
await rec.stop();
```

---

## Enumerate devices

Use `RecorderDevices` to list available capture devices before building a recorder.  Every `deviceId` returned can be passed directly to the matching builder method.

```dart
final displays = await RecorderDevices.displays();     // for addScreen(displayId:)
final windows  = await RecorderDevices.windows();      // for addScreen(windowId:)
final cameras  = await RecorderDevices.cameras();      // for addCamera(deviceId:)
final mics     = await RecorderDevices.microphones();  // for addMic(deviceId:)
final loops    = await RecorderDevices.loopbacks();    // for addLoopback(deviceId:)

print(displays.map((d) => '${d.name}: ${d.deviceId}').join('\n'));
```

All lists carry a `MiniAVDeviceInfo` with `deviceId`, `name`, and `isDefault`.

---

## Sources

### Screen / display

`addScreen` accepts the display ID string returned by `RecorderDevices.displays()` (or `MiniScreen.enumerateDisplays()`) directly, or `null` to capture the platform's default display.

```dart
// Use a specific display by ID
builder.addScreen(
  displayId: display.deviceId,   // from RecorderDevices.displays()
  codec:     VideoCodec.h264,
  hwAccel:   HwAccelPreference.preferred,   // default
  scale:     ScreenScalePolicy.h264Friendly, // optional downscale
);

// Platform default display
builder.addScreen();

// Specific application window
builder.addScreen(windowId: win.deviceId);
```

### Camera

```dart
builder.addCamera(
  deviceId: camera.deviceId,    // from RecorderDevices.cameras()
  codec:    VideoCodec.h264,
);
```

### Microphone / Loopback

```dart
builder.addMic(deviceId: mic.deviceId, codec: AudioCodec.aac);
builder.addLoopback(deviceId: loopback.deviceId, codec: AudioCodec.aac);
```

---

## Sinks

```dart
// Write to a container file — container is auto-selected (see below).
builder.addFileOutput('rec.mkv');

// Override the container explicitly.
builder.addFileOutput('audio.m4a', container: Container.m4a);

// Receive raw encoded packets for live streaming / network forwarding.
builder.addStreamOutput((Object chunk) {
  if (chunk is TrackChunk) {
    // chunk.bytes, chunk.kind, chunk.ptsUs, chunk.isKeyframe, …
  }
});
```

### Auto-container selection

When no `container:` override is supplied, the recorder infers the most natural container:

| Track mix | Auto-selected container |
|---|---|
| Video + audio | `.mkv` |
| Video only | `.mp4` |
| Audio-only (AAC) | `.m4a` |
| Audio-only (MP3) | `.mp3` |
| Audio-only (Opus) | `.ogg` |
| Audio-only (mixed/other) | `.mkv` |

---

## Audio-only recorders

A recorder with no video sources is fully supported. Useful for recording mic or loopback audio to a standalone audio file:

```dart
final micRec = (RecorderBuilder()
      ..addMic(deviceId: mic.deviceId, codec: AudioCodec.aac)
      ..addFileOutput('mic.m4a'))  // auto-picks Container.m4a
    .build();

await micRec.start();
await Future.delayed(const Duration(seconds: 30));
await micRec.stop();
```

---

## Synchronised multi-recorder (`RecorderGroup`)

Record to multiple outputs simultaneously with clock-synchronised start.  The prepare phase (encoder/muxer init, GPU bringup) runs concurrently on all recorders, then all master clocks are started in a tight sequential loop to minimise clock skew.

```dart
final avRec = (RecorderBuilder()
      ..addScreen()                   // null = platform default display
      ..addLoopback(deviceId: loop.deviceId)
      ..addFileOutput('av.mp4'))
    .build();

final micRec = (RecorderBuilder()
      ..addMic(deviceId: mic.deviceId, codec: AudioCodec.aac)
      ..addFileOutput('mic.m4a'))     // auto-picks Container.m4a
    .build();

final group = RecorderGroup([avRec, micRec]);
await group.start();
await Future.delayed(const Duration(seconds: 10));
await group.stop();
```

`RecorderGroup.recorders` exposes each individual `Recorder` so you can query state or add per-recorder error handling.

---

## Zero-copy GPU path (Windows)

`RecorderBuilder.preferZeroCopy` defaults to **`true`**.

When recording a screen source on Windows with a compatible hardware encoder (NVENC, AMD VCE, Intel QSV, Media Foundation), the recorder:

1. Initialises a shared **Dawn D3D12** context via [minigpu](../../minigpu/minigpu/).
2. Creates a matching **`ID3D11Device`** on the same GPU adapter.
3. Requests **GPU output** (`MiniAVOutputPreference.gpu`) from the DXGI capture so each frame arrives as a D3D11 NT shared handle — no pixel data crosses PCIe.
4. Passes the shared device handle to the FFmpeg backend, which opens `FfmpegD3d11HwEncoder` with `existingD3d11Device`.  The encoder reads the texture directly without any CPU copy.

Falls back silently to the CPU-upload path on any failure (unsupported GPU, non-Windows, no HW encoder).

### Process-global GPU singleton & hot restart

The shared `Minigpu` + Dawn-allocated `ID3D11Device` are **lifetime-of-the-isolate** singletons.  `Recorder.start()` / `stop()` never tear them down — re-initialising Dawn within a single process can pick a different backend on the second run (D3D12 vs D3D11) and break the cross-API shared-texture path with errors like *“The D3D11 device of the texture and the D3D11 device of [Device "MGPU.MainDevice"] must be same”*.

For Flutter **hot restart**, the MiniAV C library's `MiniAV_Dispose()` is called automatically via `MiniAV.dispose()`.  It acquires an exclusive write lock, waits for every in-flight native callback to finish, then disables further dispatch — so native worker threads can never invoke a closed `NativeCallable`.  The next `Recorder.start()` re-enables callbacks automatically.

Wire both teardowns into your app's hot-restart hook so the Dawn/D3D11 device is also released cleanly:

```dart
import 'package:flutter/widgets.dart';
import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';

class _MyAppState extends State<MyApp> {
  @override
  void reassemble() {
    super.reassemble();
    // Quiesce all native callbacks, then release the shared GPU.
    MiniAV.dispose();            // disables C-level callbacks atomically
    Recorder.disposeSharedGpu(); // tears down Dawn / D3D11 device
  }
}
```

Static helpers:

| API | Purpose |
|---|---|
| `Recorder.ensureSharedGpu()` | Idempotently bring up the shared `Minigpu` + D3D11 device.  Called automatically by `start()` when needed. |
| `Recorder.sharedGpu` | The live `Minigpu` instance after `ensureSharedGpu()`, or `null` when GPU is unsupported.  Use to run custom compute passes (e.g. `gpu.copyBuffer`, a custom WGSL effect, or a `GpuScreenProcessor` for live preview) on the same Dawn device without a second `gpu.init()`. |
| `Recorder.disposeSharedGpu()` | Explicitly destroy the shared GPU singleton.  Safe to call multiple times.  After this, the next `start()` re-initialises. |

---

## Logging

`miniav_recorder` exposes a unified log API that routes messages from the Dart recorder runtime, the MiniAV C library, and FFmpeg through a single callback — all accessible from a single `import 'package:miniav_recorder/miniav_recorder.dart'`.

### Log level

```dart
// Only emit warnings and errors (default: RecorderLogLevel.info).
Recorder.setLogLevel(RecorderLogLevel.warning);
```

| Level | What is shown |
|---|---|
| `verbose` | All debug output from recorder, MiniAV, and FFmpeg |
| `info` | Informational messages + warnings + errors (default) |
| `warning` | Warnings and errors only |
| `error` | Errors only |
| `quiet` | Silence all logs |

### Custom callback

```dart
Recorder.setLogCallback((source, level, message) {
  print('[${source.name}] ${level.name}: $message');
});
```

The callback receives:

| Parameter | Type | Values |
|---|---|---|
| `source` | `RecorderLogSource` | `recorder` · `miniav` · `ffmpeg` · `minigpu` |
| `level` | `RecorderLogLevel` | `verbose` · `info` · `warning` · `error` |
| `message` | `String` | The log line (no trailing newline) |

`source` tells you which subsystem emitted the message so you can filter or
route them independently. `ffmpeg` covers both native `av_log` messages and
the `miniav_tools_ffmpeg` Dart layer (auto-downloader, encoder selection).

To remove the callback and revert to the default console output via `print`:

```dart
Recorder.setLogCallback(null);
```

Avoid writing to `dart:io` `stderr`/`stdout` from your callback: in a
console-less Windows GUI app (a packaged Flutter desktop build) the OS stdio
handles are invalid and those writes crash with an uncatchable async
`FileSystemException` (errno 6). Use `print`, a file sink, or a logging
package instead.

### Combined example

```dart
// Verbose FFmpeg output only, everything else at warning+.
Recorder.setLogLevel(RecorderLogLevel.verbose);
Recorder.setLogCallback((source, level, message) {
  if (source == RecorderLogSource.ffmpeg || level.index >= RecorderLogLevel.warning.index) {
    myLogger.log('[${source.name}] $message');
  }
});
```

> **Note:** Dawn / minigpu logs are written directly to native `stderr` by the Dawn library and cannot be intercepted by this callback.

---

## GPU downscaling

Screen sources can be downscaled on the GPU before encoding using `ScreenScalePolicy`.

| Policy | Behaviour |
|---|---|
| `ScreenScalePolicy.none` | No scaling (default). |
| `ScreenScalePolicy.h264Friendly` | Auto-downscale so `max(width, height) ≤ 4096`, preserving aspect ratio. Avoids the automatic H.264 → HEVC codec promotion on ultrawide / 4K+ displays. |
| `ScreenScalePolicy.fixedSize(w, h)` | Encode at an explicit pixel size (rounded to even). |
| `ScreenScalePolicy.scaleFactor(f)` | Uniform fractional scale, e.g. `0.5` = half each axis (rounded to even). |

### How it works

When zero-copy is active **and** a non-`none` policy is set, a `GpuScreenProcessor` is created for the track.  Per frame:

```
MiniAVBuffer (D3D11 NT handle)
  → gpu.importVideoFrame()          VideoTexture  (BGRA, srcW×srcH)
  → VideoTexture.toRGBA()           Buffer        (RGBA u32[], srcW×srcH)
  → WGSL bilinear dispatch          Buffer        (RGBA u32[], dstW×dstH)
  → effects chain                   Buffer        (RGBA u32[], outW×outH)
  → SharedOutputTexture.copyFromBuffer
                                    SharedOutputTexture (RGBA, outW×outH)
  → D3D11TextureFrameSource → FfmpegD3d11HwEncoder
```

All GPU memory — no pixel data reaches the CPU.

### Example: ultrawide display → H.264

```dart
builder.addScreen(
  displayId: display.deviceId,
  codec: VideoCodec.h264,                    // stays h264 after downscale
  scale: ScreenScalePolicy.h264Friendly,     // 5120×1440 → 4096×1152
);
```

### Example: custom scale

```dart
// Half resolution
builder.addScreen(scale: ScreenScalePolicy.scaleFactor(0.5));

// Fixed 1920×1080
builder.addScreen(scale: ScreenScalePolicy.fixedSize(1920, 1080));
```

---

## GPU effects pipeline

Screen sources support an ordered chain of GPU post-processing effects applied **after** any `ScreenScalePolicy` downscaling.  All effects run as WGSL compute shaders — no pixel data reaches the CPU.

Effects are passed to `addScreen()` as a `List<ScreenEffect>`.  They are applied left-to-right; each receives the output dimensions of the preceding step.

```dart
builder.addScreen(
  displayId: display.deviceId,
  scale: ScreenScalePolicy.h264Friendly,
  effects: [
    ScreenEffect.crop(0, 0, 1920, 1040),   // 1. strip taskbar
    ScreenEffect.vignette(strength: 0.4),  // 2. colour grade
  ],
);
```

### Built-in effects

| Factory | Changes dimensions? | Description |
|---|---|---|
| `ScreenEffect.vignette({strength})` | No | Radial vignette + warm colour grade. `strength` 0–1 (default `1.0`). |
| `ScreenEffect.crop(x, y, width, height)` | **Yes** | Crop to a sub-rectangle. Encoder is opened at `width×height`. |
| `ScreenEffect.flip({horizontal, vertical})` | No | Mirror horizontally and/or vertically. Uses a separate GPU buffer (avoids in-place race conditions). |
| `ScreenEffect.rotate(ScreenRotation)` | **Yes** for 90°/270° | Clockwise rotation. 90°/270° swap width ↔ height. |
| `ScreenEffect.scale(width, height)` | **Yes** | Bilinear resize to an arbitrary target size. Useful after a crop to upscale a region back to a standard resolution. |
| `ScreenEffect.wgsl(source, {extraParams})` | No | Custom in-place WGSL compute shader. |

#### Rotation values

```dart
ScreenEffect.rotate(ScreenRotation.r90)   // 90° clockwise  — output: H×W
ScreenEffect.rotate(ScreenRotation.r180)  // 180° — output: W×H (unchanged)
ScreenEffect.rotate(ScreenRotation.r270)  // 270° clockwise — output: H×W
```

### Dimension-changing effects

When an effect changes the frame dimensions (`crop`, `rotate` 90°/270°, `scale`), the encoder and shared output texture are automatically opened at the correct final size — no configuration needed beyond listing the effects.

```dart
// 2560×1440 display → crop taskbar → portrait rotate → upscale
builder.addScreen(
  effects: [
    ScreenEffect.crop(0, 0, 2560, 1400),      // → 2560×1400
    ScreenEffect.rotate(ScreenRotation.r90),   // → 1400×2560
    ScreenEffect.scale(700, 1280),             // → 700×1280
  ],
);
```

### Composing effects

Some useful patterns:

```dart
// Correct a front-facing webcam (mirrored by default):
effects: [ScreenEffect.flip(horizontal: true)]

// Record a portion of the screen at full HD:
effects: [
  ScreenEffect.crop(640, 360, 640, 360),  // crop a 640×360 region from the centre
  ScreenEffect.scale(1920, 1080),         // upscale to 1080p for the encoder
]

// Fix a sideways phone screen share:
effects: [ScreenEffect.rotate(ScreenRotation.r270)]
```

### Custom WGSL effects

Provide your own compute shader source via `ScreenEffect.wgsl()`.  The shader runs in-place on the current buffer (same dimensions in and out):

```dart
ScreenEffect.wgsl(
  '''
  struct Params { width: u32, height: u32, gamma: f32, _pad: f32 };
  @group(0) @binding(0) var<storage, read_write> pixels : array<u32>;
  @group(0) @binding(1) var<storage, read_write> params : Params;

  @compute @workgroup_size(8, 8, 1)
  fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    if (gid.x >= params.width || gid.y >= params.height) { return; }
    let idx = gid.y * params.width + gid.x;
    // … transform pixels[idx] in place …
  }
  ''',
  extraParams: [2.2], // passed as f32 from byte 8 in the Params struct
)
```

#### WGSL shader contract

| Binding | Type | Meaning |
|---|---|---|
| `@binding(0)` | `array<u32>` (read_write) | Packed RGBA8 pixels, row-major. Modify in-place. |
| `@binding(1)` | user-defined struct (read_write) | `width: u32` at offset 0, `height: u32` at offset 4, then the `extraParams` values as consecutive `f32` fields from byte 8. |

Workgroups are dispatched at 8×8 threads. Always guard: `if (gid.x >= params.width || gid.y >= params.height) { return; }`.

### Effects + scale policy together

Downscaling from `ScreenScalePolicy` runs first (still on the full-resolution D3D11 texture), then the effects chain runs on the smaller buffer — maximising efficiency.

```dart
builder.addScreen(
  scale: ScreenScalePolicy.h264Friendly,   // 1. GPU bilinear downscale
  effects: [
    ScreenEffect.crop(0, 0, 3840, 2000),   // 2. strip taskbar
    ScreenEffect.vignette(strength: 0.4),  // 3. colour grade
  ],
);
```

### Requirements

- Zero-copy GPU path must be active (`preferZeroCopy = true`, Windows D3D12).  
- If the GPU context is unavailable the effects chain is skipped and a warning is printed; recording continues normally at the downscaled (or original) size.

---

## DVR clip buffer

A `ClipBuffer` keeps a rolling in-memory ring of encoded packets covering the last `maxWindow` of recording.  Call `saveClip` at any point to materialise any sub-window to a file without pausing or splitting the active recording.

```dart
// Keep up to 3 minutes in RAM.
final clip = builder.addClipBuffer(maxWindow: Duration(minutes: 3));
final rec  = builder.build();
await rec.start();

// … record continuously …

// Save clips of different lengths from the same buffer — non-destructive.
await clip.saveClip('moment_5s.mp4',  duration: Duration(seconds: 5));
await clip.saveClip('moment_30s.mp4', duration: Duration(seconds: 30));
await clip.saveClip('replay_3min.mp4');  // omit duration → full maxWindow
```

### API

| Member | Description |
|---|---|
| `addClipBuffer({required maxWindow, maxPackets})` | Register a `ClipBuffer` on the builder. Returns the buffer. |
| `ClipBuffer.maxWindow` | Buffered duration (longest possible clip). |
| `ClipBuffer.maxPackets` | Optional hard cap on ring size (bounds memory). |
| `ClipBuffer.length` | Number of packets currently buffered. |
| `ClipBuffer.oldestPtsUs` / `newestPtsUs` | Timestamp span of buffered data. |
| `ClipBuffer.saveClip(path, {duration, container})` | Write the last `duration` (default: `maxWindow`) to `path`. |
| `ClipBuffer.clear()` | Discard all buffered packets. |

### Notes

- The clip always starts on a **video keyframe** to ensure the file is playable.
- Timestamps are **remapped to start from 0** in the output file.
- `saveClip` can be called **multiple times concurrently** with different durations from the same `ClipBuffer`.
- Memory scales with `maxWindow × average_bitrate`.  At 8 Mbps video + 128 Kbps audio, 3 minutes ≈ ~180 MB.
- Add a `maxPackets` cap if memory is a concern:

```dart
// Cap at ~10 000 packets regardless of duration.
builder.addClipBuffer(
  maxWindow: Duration(minutes: 3),
  maxPackets: 10000,
);
```

---

## Warmup

On first run, the recorder may need to download FFmpeg shared libraries before encoding can start.  Call `Recorder.warmup()` early in your app — in `main()` or `initState` — to trigger heavy initialisation up front and get byte-level download progress.

```dart
import 'package:miniav_recorder/miniav_recorder.dart';

// Flutter — show a progress bar while FFmpeg downloads:
@override
void initState() {
  super.initState();
  Recorder.warmup().listen(
    (p) {
      if (p.fraction != null) {
        setState(() => _downloadProgress = p.fraction!);
      }
      if (p.isDone && p.error != null) {
        debugPrint('Warmup error [${p.backendName}]: ${p.error}');
      }
    },
    onDone: () => setState(() => _ready = true),
  );
}

// Command-line / background — block until all backends are ready:
await Recorder.warmup().drain<void>();
```

If the libraries are already cached on disk, `warmup()` completes immediately with no events.  It is safe to call multiple times.

> Prefer `Recorder.warmup()` over calling `MiniAVTools.warmup()` directly:
> backends are only warmed once **registered**, and the FFmpeg backend is
> otherwise registered lazily inside `Recorder.start()`. `Recorder.warmup()`
> registers it first, so the FFmpeg download is included even when no
> recorder has been built yet.

Warmup is **optional**: `createEncoder`, `createMuxer`, etc. trigger auto-download on demand.  The benefit of calling `warmup()` early is that you control when the download happens and can give the user feedback instead of silently stalling.

### `WarmupProgress` fields

| Field | Type | Meaning |
|---|---|---|
| `backendName` | `String` | Backend that emitted the event (`"ffmpeg"`, etc.). |
| `task` | `String` | Human-readable task description (e.g. `"Downloading FFmpeg"`). |
| `isDone` | `bool` | `true` on the final event for this task — success **or** failure. |
| `bytesReceived` | `int?` | Bytes received so far; `null` for non-download events. |
| `totalBytes` | `int?` | Total expected bytes; `null` when server omits `Content-Length`. |
| `fraction` | `double?` | Computed `bytesReceived / totalBytes` in `[0.0, 1.0]`, or `null`. |
| `error` | `Object?` | Non-null when the task failed. The stream **never** errors itself. |

---

## Builder options

```dart
final builder = RecorderBuilder()
  ..defaultVideoBitrate = 6_000_000   // bits/s
  ..defaultAudioBitrate = 128_000     // bits/s
  ..defaultFrameRate    = 30
  ..backendPreference   = BackendPreference.auto
  ..preferZeroCopy      = true;       // default — safe to leave on
```

---

## Codec selection

The recorder calls `FfmpegBackend.bestCodecForResolution` automatically.  When hardware encoding is preferred and the source (or downscaled) dimensions exceed 4096 px in any dimension, it promotes `h264 → hevc` to stay within hardware encoder limits.  Using `ScreenScalePolicy.h264Friendly` avoids this promotion.

---

## Examples

See [`examples/recorder/`](../examples/recorder/):

| Script | Description |
|---|---|
| `screen_mic.dart` | Screen + microphone → MKV (zero-copy + h264Friendly by default). |
| `camera_mic.dart` | Webcam + microphone → MP4. |
| `screen_mic_loopback_chunked.dart` | Screen + loopback → chunked stream packets. |
