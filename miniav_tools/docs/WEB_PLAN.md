# Web support — current state and plan

> Status as of 2026-05. This document captures (a) where each piece of the
> miniav / minigpu / miniav_tools trio stands on the web target today and
> (b) the concrete next steps to bring the missing pieces online and to
> add automated browser-side test coverage.

## TL;DR

| Layer | Browser status | Test coverage |
|---|---|---|
| `minigpu_web` (compute / WGSL) | ✅ Working — emscripten WASM + Dart `dart:js_interop` bindings, `importVideoFrameWeb` zero-copy `VideoFrame → GPUExternalTexture` | ✅ `dart test -p chrome` (6 pass, 2 skip) |
| `miniav_web` (capture) | ✅ Working — `package:web` over `getUserMedia` / `getDisplayMedia` / `ImageCapture` | None on browser |
| `miniav_tools_web` (codecs + mux) | ✅ **WebCodecsVideoEncoder implemented** — real `VideoEncoder` wrapper, GPU-effect-less fallback when WebGPU absent, `MediaRecorderCapture` for no-WebCodecs browsers | ✅ `dart test -p chrome` (18 pass) |
| CI matrix | ⚠️ Not yet wired to GitHub Actions | Run locally: `dart test -p chrome` |

## Degradation tiers

The stack degrades gracefully across three tiers, checked via `WebCapability`:

| Tier | Condition | Path |
|---|---|---|
| **Full** | WebGPU + WebCodecs | GPU effects (WGSL via `minigpu_web`) → `WebCodecsVideoEncoder` → fMP4/WebM |
| **Encode-only** | WebCodecs, no WebGPU | GPU effects skipped; `WebCodecsVideoEncoder` still works |
| **Fallback** | No WebCodecs | `MediaRecorderCapture` wraps `MediaRecorder(stream)` → WebM/MP4 chunks |

```dart
// Runtime branch:
if (WebCapability.hasVideoEncoder) {
  // Full or encode-only path via MiniAVTools.createEncoder()
  final encoder = await MiniAVTools.createEncoder(config);
  // minigpu GPU effects are a separate opt-in, checked before init:
  final gpuAvail = WebCapability.hasWebGPU;
} else {
  // Fallback: stream-level recording
  final capture = MediaRecorderCapture(
    stream: displayMediaStream,
    mimeType: MediaRecorderCapture.preferredMimeType,
    onChunk: (bytes) => sink.add(bytes),
  );
  await capture.start();
}
```

## What already works

### `minigpu_web` build pipeline

```makefile
# minigpu/Makefile
BUILD_WEB_DIR := ./minigpu_ffi/src/build_web/

build_weblib:
	@cd $(BUILD_WEB_DIR) && emcmake cmake .. \
	  -DCMAKE_TOOLCHAIN_FILE=$(EMSDK)/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake \
	  && cmake --build .
```

- Builds the same C++ source as `minigpu_ffi` through Emscripten,
  producing `minigpu_web.wasm` + `minigpu_web.js` glue.
- `MinigpuWeb` implements `MinigpuPlatform` and additionally exposes
  `importVideoFrameWeb(JSAny videoFrame)` which wraps a WebCodecs
  `VideoFrame` as a `GPUExternalTexture` — the web equivalent of the
  `SharedOutputTexture` zero-copy path on Windows.

### `miniav_web` capture surface

- Uses `package:web` (typed JS interop) over native browser APIs.
- Implements every `MiniAVPlatformInterface` sub-surface.
- Backed by `MediaDevices.getUserMedia`, `getDisplayMedia`, `ImageCapture`,
  `enumerateDevices`, audio context loopback.

### `miniav_tools_web` — now implemented

The following pieces landed in this iteration:

**`WebCapability`** (`lib/src/web_capability.dart`):
- `hasVideoEncoder` / `hasAudioEncoder` / `hasWebGPU` / `hasMediaRecorder` — synchronous runtime flags.
- `isVideoEncoderSupported(codecString, width, height)` — async probe via
  `VideoEncoder.isConfigSupported()`.

**`WebCodecsVideoEncoder`** (`lib/src/web_codecs_encoder.dart`):
- Implements `PlatformEncoder` using the `VideoEncoder` JS API.
- Accepts `FrameSourceKind.webVideoFrame` (zero-copy from `MediaStreamTrackProcessor`)
  and `FrameSourceKind.cpu` (RGBA bytes → `OffscreenCanvas` → `VideoFrame`).
- Extracts `CodecExtraData` (avcC / hvcC) from the first IDR's `EncodedVideoChunkMetadata`.
- Defaults to `latencyMode: 'realtime'` for live recording.

**`MediaRecorderCapture`** (`lib/src/media_recorder_fallback.dart`):
- Standalone class (not a `PlatformMuxer`) wrapping the `MediaRecorder` API.
- Used directly when `WebCapability.hasVideoEncoder` is `false`.
- `preferredMimeType` negotiates the best available `video/webm` or `video/mp4` MIME type.
- Delivers encoded+muxed chunks via `onChunk(Uint8List)` callback.
- Supports timesliced delivery (default 1 s) or on-stop delivery.

**Updated `WebCodecsBackend`**:
- `createEncoder()` returns `null` (not throws) when WebCodecs is unavailable
  or the codec is not supported — the backend chain falls through correctly.
- Capability and `isConfigSupported()` checks happen before constructing the encoder.
- `supportsEncode()` reflects runtime availability, not just static codec list.

**`FrameSourceKind.webVideoFrame`** (platform interface):
- New kind in the `FrameSourceKind` enum + `WebVideoFrameSource` class.
- Allows zero-copy `VideoFrame` objects to flow through the `FrameSource` 
  sealed type without a `dart:js_interop` dependency in the platform interface.

**Test infrastructure**:
- `dart_test.yaml` with `browser` and `webgpu` tags.
- `test/smoke_web_test.dart` covering capability detection, backend registration,
  MIME type negotiation, frame source construction, and a CPU-path H.264 encode
  round-trip (skipped gracefully if the API is absent).

## What's still missing

### Streaming app: cross-platform `miniav_recorder` on web

`miniav_recorder` currently imports `miniav_tools_ffmpeg` directly (for
`FfmpegD3d11HwEncoder` / `D3D11TextureFrameSource`). These are Windows-only
and won't compile on web.

Options (priority order):
1. **Conditional imports** — guard the FFmpeg-specific code with
   `dart:io` conditional imports or `if (dart.library.ffi)` library
   declarations, and provide a no-op stub on web.
2. **Backend-only dependency** — move the `miniav_tools_ffmpeg` registration
   out of `miniav_recorder` into the app layer (the app imports both and
   registers the FFmpeg backend before calling `Recorder.start()`).
3. **`miniav_recorder_web` package** — a separate thin package that
   re-exports `miniav_recorder` with the FFmpeg dep replaced by
   `miniav_tools_web`.

Option 2 is the lowest-effort path for cross-platform code sharing.

### fMP4 / WebM muxer

`WebCodecsBackend.createMuxer()` returns `null` (pending). Two options:
- Pure-Dart fragmented-MP4 writer (MP4Box-compatible; ~500 LOC).
  JS library via `dart:js_interop`.

Until this lands, apps should use `MediaRecorderCapture` (which produces
a complete WebM/MP4 from the MediaStream without a separate muxer).

### Audio encoder

`WebCodecsBackend.createAudioEncoder()` is not yet implemented.
`WebCodecs AudioEncoder` maps cleanly to `PlatformAudioEncoder` — the
pattern is identical to `WebCodecsVideoEncoder`.

### `VideoDecoder` / `AudioDecoder`

Decoder stubs return `null`. Implement as mirror of `WebCodecsVideoEncoder`.

## Zero-copy path on web

The native pipeline that landed this cycle (`minigpu` `SharedOutputTexture`
→ FFmpeg D3D11 NVENC) has a clean web equivalent:

```text
miniav.screen → MediaStreamTrack → MediaStreamTrackProcessor →
  VideoFrame  → minigpu importVideoFrameWeb(GPUExternalTexture)
              → minigpu compute pipeline (effect shader)
              → GPUTexture → new VideoFrame(GPUTexture, …)
              → WebCodecs VideoEncoder
              → EncodedVideoChunk → fMP4 muxer
```

Every hop except the last two is already implemented. Once
`miniav_tools_web` lands a `VideoEncoder` wrapper that accepts a Dart
`VideoFrame` (already exposed by `minigpu_web`'s
`importVideoFrameWeb`-adjacent code) and a fMP4 writer, the trio works
end-to-end in a browser.

### Flutter web demo

`miniav_tools/examples/screenshare_mp4_web/`) that mirrors
`screenshare_mp4`'s flow: pick a screen via `getDisplayMedia`, run the
vignette+warmth shader, encode to fMP4, and offer the result as a
download Blob. This is the web counterpart of the existing native
`screenshare_mp4` example and is the natural smoke-test target.

## Proposed test infrastructure

### What exists

- `miniav_tools_web/dart_test.yaml` — `browser` and `webgpu` tag definitions.
- `miniav_tools_web/test/smoke_web_test.dart` — covers:
  - `WebCapability` synchronous flags (all return `bool` without throwing)
  - `WebCapability.isVideoEncoderSupported()` async probe
  - Backend auto-registration and deduplication
  - `createEncoder()` returns `null` (not throws) for unsupported codecs
  - `MediaRecorderCapture.preferredMimeType` negotiation
  - `FrameSource.webVideoFrame()` construction and kind check
  - H.264 64×64 CPU-path encode round-trip (skipped if API absent)

Run locally:
```
cd miniav_tools_web
dart test -p chrome --tags browser
```

WebGPU tests (tagged `webgpu`) require Chrome flags:
```
--enable-unsafe-webgpu --disable-dawn-features=disallow_unsafe_apis
```

### CI matrix (next PR)

```yaml
# .github/workflows/test_web.yml
jobs:
  test-web:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        package: [miniav_tools_web, minigpu_web]
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: stable }
      - uses: nanasess/setup-chromedriver@v2
      - run: dart pub get
        working-directory: miniav_tools/${{ matrix.package }}
      - run: |
          dart test -p chrome --tags browser \
            --reporter=github
        working-directory: miniav_tools/${{ matrix.package }}
        env:
          CHROME_FLAGS: --headless --no-sandbox --disable-gpu
```

WebGPU tests are excluded from CI by default (GPU-less runners);
they run on the `webgpu` tag which is not included in the base matrix.

## Risks / open questions

- **WebGPU availability in headless Chrome.** Chromium 121+ enables WebGPU
  by default on capable GPUs; CI runners may fall back to the SwiftShader
  Vulkan path which is functional but slow. A `?fallback=cpu` test mode
  may be necessary so smoke tests don't fail on GPU-less runners.
- **WebCodecs in Firefox.** Firefox ships WebCodecs `VideoFrame`/
  `VideoDecoder` but **not** `VideoEncoder` as of writing. The encoder
  tests should be tagged `chrome-only`.
- **`MediaStreamTrackProcessor`** is Chromium-only (Firefox uses
  `MediaStreamTrack.captureStream` differently). We will need a fallback
  reader that draws the track to an `OffscreenCanvas` and pulls
  `VideoFrame`s from there.
- **Zero-copy `GPUTexture → VideoFrame`** requires Chromium 119+ and the
  `--enable-unsafe-webgpu` flag. We document that, just as the Makefile
  documents the same flag for native Dawn.
