# miniav_tools — Design Document

## Goal

A **federated, backend-pluggable** codec & container library that:

1. **Accepts zero-copy GPU buffers** from `miniav` capture sources (D3D11, Metal, dmabuf, AHardwareBuffer) and `minigpu` `VideoTexture` objects.
2. **Encodes / decodes** using whichever backend is registered: FFmpeg (CPU + every hardware accelerator FFmpeg supports), WebCodecs (browser), or pure GPU compute (minigpu).
3. **Muxes / demuxes** containers (MP4, MKV, WebM, fragmented MP4, raw streams).
4. **Is pure-Dart at the public surface** — no FFmpeg type leakage. Backends are private to their packages.

## Non-goals

- Replacing FFmpeg's filtergraph / `libswscale`. Use minigpu compute for that instead.
- Writing a brand-new H.264 encoder in WGSL on day one. (Long-term research project.)
- Real-time streaming protocols (RTP/RTMP/WebRTC). Those belong in a separate `miniav_streaming` package.

## Architecture

```text
                ┌────────────────────────────────────────────┐
                │           miniav_tools (facade)            │
                │   MiniAVTools.createEncoder(...)           │
                │   MiniAVTools.createDecoder(...)           │
                │   MiniAVTools.createMuxer(...)             │
                │   MiniAVTools.createDemuxer(...)           │
                └──────────────────┬─────────────────────────┘
                                   │
                                   ▼
                ┌────────────────────────────────────────────┐
                │   MiniAVToolsPlatform.instance (registry)  │
                │     • Backend prio + capability matching   │
                │     • Negotiates FrameSource compatibility │
                └──────────────────┬─────────────────────────┘
                                   │
              ┌────────────────────┼─────────────────────┐
              ▼                    ▼                     ▼
    ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │  ffmpeg backend │  │  minigpu backend │  │   web backend    │
    │  (FFI, native)  │  │ (WGSL compute)   │  │   (WebCodecs)    │
    └─────────────────┘  └──────────────────┘  └──────────────────┘
```

## Core abstractions

### `FrameSource` — the zero-copy contract

```dart
sealed class FrameSource {
  const FrameSource();

  /// CPU bytes (always supported, may incur copy/upload).
  factory FrameSource.cpu(Uint8List bytes, MiniAVPixelFormat fmt,
      int width, int height, {List<int>? strideBytes}) = _CpuFrameSource;

  /// A miniav buffer — backend may extract native handle for zero-copy.
  factory FrameSource.miniavBuffer(MiniAVBuffer buffer) = _MiniAVBufferSource;

  /// A minigpu video texture — backend may share via WebGPU shared memory.
  factory FrameSource.gpuTexture(VideoTexture tex) = _GpuTextureSource;

  /// Raw escape hatches for backends that want to bypass miniav/minigpu.
  factory FrameSource.d3d11Texture(int texturePtr, int width, int height,
      MiniAVPixelFormat fmt, {MiniAVNativeFence? fence}) = _D3D11FrameSource;
  factory FrameSource.cvPixelBuffer(int cvPixelBufferPtr) = _CvPixelBufferSource;
  factory FrameSource.dmabuf(List<int> fds, List<int> strides,
      List<int> offsets, int modifier, int width, int height,
      MiniAVPixelFormat fmt) = _DmabufFrameSource;
}
```

Each backend declares which `FrameSource` variants it can consume directly via `Backend.acceptedFrameSources`. The facade negotiates: if the incoming source isn't accepted, it falls back to a CPU readback (using `VideoTexture.toRGBA()` or `releaseBuffer` after copy) — slow, but always works.

### `EncoderConfig` / `DecoderConfig` — codec-agnostic knobs

```dart
class EncoderConfig {
  final VideoCodec codec;       // h264 | h265 | av1 | vp9 | vp8 | mjpeg
  final int width, height;
  final int bitrateBps;
  final int gopLength;          // keyframe interval in frames
  final int frameRateNumerator, frameRateDenominator;
  final MiniAVPixelFormat inputPixelFormat;
  final HwAccelPreference hwAccel; // forbidden | allowed | preferred | required
  final RateControl rateControl;   // cbr | vbr | crf
  final int? crfQuality;           // 0–51 for x264-style
  final EncoderProfile profile;    // baseline | main | high | high10 | ...
  final EncoderLevel? level;
  final Map<String, String> backendOptions; // escape hatch
}
```

`hwAccel: required` means "fail if no hardware path"; `preferred` means "try hardware, fall back to software". Backends report which combinations they support via `backend.supportsEncode(...)`.

### `EncodedPacket` — the wire-format unit

```dart
class EncodedPacket {
  final Uint8List data;       // raw codec bitstream (Annex-B for H.264, etc.)
  final int ptsUs;
  final int dtsUs;
  final bool isKeyframe;
  final int trackIndex;
  final Map<String, Object>? sideData;
}
```

Encoders emit; decoders accept; muxers consume; demuxers produce. Same type across all four — keeps composition trivial.

### `Backend` — what every backend implements

```dart
abstract class MiniAVToolsBackend {
  String get name;
  int get priority; // higher wins ties

  // Capability queries
  bool supportsEncode(VideoCodec c, {bool hwAccel = false});
  bool supportsDecode(VideoCodec c, {bool hwAccel = false});
  bool supportsMux(Container c);
  bool supportsDemux(Container c);
  Set<FrameSourceKind> get acceptedFrameSources;

  // Factories — return null if unsupported (facade tries next backend)
  Future<PlatformEncoder?> createEncoder(EncoderConfig cfg);
  Future<PlatformDecoder?> createDecoder(DecoderConfig cfg);
  Future<PlatformMuxer?>   createMuxer(MuxerConfig cfg);
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig cfg);
}
```

Backends self-register on import:

```dart
// inside miniav_tools_ffmpeg/lib/miniav_tools_ffmpeg.dart
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

class FfmpegBackend extends MiniAVToolsBackend { ... }

void registerFfmpegBackend() {
  MiniAVToolsPlatform.instance.register(FfmpegBackend());
}

// Top-level invocation so importing the package is enough.
final _ = registerFfmpegBackend();
```

## Backend specifics

### `miniav_tools_ffmpeg`

Native build via `native_toolchain_cmake` (same pattern as `miniav_ffi`), linking against either:
- **System FFmpeg** (Linux distros, Homebrew on macOS) — preferred for license & size.
- **Bundled FFmpeg** (Windows; we ship LGPL builds) — fallback for portability.

Hardware paths:

| Platform | Encoder | Path | Frame source |
|----------|---------|------|--------------|
| Windows | NVENC | `h264_nvenc` + `AV_HWDEVICE_TYPE_D3D11VA` | `FrameSource.d3d11Texture` / `FrameSource.miniavBuffer(GPU)` |
| Windows | AMF | `h264_amf` + D3D11 | same |
| Windows | QSV | `h264_qsv` + D3D11 | same |
| Linux | VAAPI | `h264_vaapi` + dmabuf | `FrameSource.dmabuf` |
| macOS | VideoToolbox | `h264_videotoolbox` + IOSurface | `FrameSource.cvPixelBuffer` |
| Android | MediaCodec | `h264_mediacodec` | `MiniAVBuffer.gpuAHardwareBuffer` |

### `miniav_tools_minigpu`

Long-term research bucket. Initial deliverables:
- Hardware-agnostic **MJPEG encoder** in WGSL (DCT + quantisation + Huffman)
- **YUV ↔ RGB color-space conversion** (already in minigpu's `VideoTexture.toRGBA`; expose as a stage)
- **Bayer demosaic** for raw-camera pipelines

Full H.264 in WGSL is a multi-year project; not on the roadmap.

### `miniav_tools_web`

Implemented via the browser's [WebCodecs API](https://www.w3.org/TR/webcodecs/).
Auto-registers on import; call `ensureInitialized()` if lazy registration needs
to be forced before first use (e.g., in tests).

**`WebCapability`** — synchronous and async runtime flags:
- `hasVideoEncoder`, `hasAudioEncoder`, `hasWebGPU`, `hasMediaRecorder`, `hasOffscreenCanvas`
- `isVideoEncoderSupported(codecString)` — async `VideoEncoder.isConfigSupported()` probe

**`WebCodecsVideoEncoder`** — implements `PlatformEncoder`:
- Accepts `FrameSourceKind.webVideoFrame` (zero-copy `VideoFrame` from `MediaStreamTrackProcessor`)
  and `FrameSourceKind.cpu` (RGBA bytes → `OffscreenCanvas` → `VideoFrame`)
- Extracts `CodecExtraData` (avcC / hvcC box) from the first IDR's `EncodedVideoChunkMetadata`
- `latencyMode: 'realtime'` for live recording
- Returns `null` (not throws) when WebCodecs is absent — the facade falls through to the next backend

**`MediaRecorderCapture`** — standalone fallback (not a `PlatformMuxer`):
- Wraps `MediaRecorder` for browsers that lack WebCodecs
- `preferredMimeType` negotiates the best available `video/webm` or `video/mp4` MIME type
- Delivers encoded+muxed chunks via `onChunk(Uint8List)` callback

**`FrameSourceKind.webVideoFrame`** (platform interface):
- Allows zero-copy `VideoFrame` objects to flow through the `FrameSource` sealed type
  without a `dart:js_interop` dependency in the platform interface.
  `WebVideoFrameSource` wraps the frame as `videoFrame: Object`.

Degradation tiers:

| Tier | Condition | Path |
|------|-----------|------|
| **Full** | WebGPU + WebCodecs | GPU effects (WGSL via `minigpu_web`) + `VideoEncoder` |
| **Encode-only** | WebCodecs, no WebGPU | GPU effects skipped; `VideoEncoder` works |
| **Fallback** | No WebCodecs | `MediaRecorderCapture` wraps `MediaRecorder` |

Still pending:
- fMP4/WebM muxer (JS interop to `mp4-muxer` / `webm-muxer` or pure-Dart writer)
- `WebCodecsAudioEncoder`
- `VideoDecoder` / `AudioDecoder` stubs
- Flutter web demo (`screenshare_mp4_web`)

## Lifecycle & threading

- **Encoders/decoders are async** — every operation returns `Future<T>` because hardware queues are inherently async.
- **`encode(FrameSource)` returns `Future<EncodedPacket?>`** — `null` means "frame consumed, no packet ready yet" (encoder is buffering for B-frames or NVENC's lookahead).
- **`flush()` drains pending packets** at end-of-stream.
- **`close()` releases GPU resources** — must always be called (Dart finalizers as backstop).
- **Fence handling** — when a `FrameSource.miniavBuffer` carries `nativeFence`, the backend must wait on it before reading the texture. This is how we avoid a tearing race between camera DMA and encoder DMA.

## Error handling

- **Unsupported codec / container** → factory returns `null`, facade tries next backend, ultimately throws `NoBackendForCodecException`.
- **Codec init failure** (e.g., NVENC driver missing) → factory throws `CodecInitException`. Caller may downgrade `hwAccel` and retry.
- **Mid-stream errors** → encoder/decoder enters an `error` state; further calls throw until `reset()` or `close()`.

## Testing strategy

Four layers:

1. **Pure-Dart contract tests** in `miniav_tools_platform_interface/test/` — verify enums,
   configs, exceptions exist with the right shapes. No backends required.
2. **Per-backend unit tests** in each backend package — verify `supportsEncode` / factory
   behaviour, smoke-test encode of a synthetic frame.
3. **Integration tests** in `miniav_tools/test/` — end-to-end: synthetic frame → encode →
   decode → compare PSNR; capture → encode → mux → demux → decode round-trips. Require at
   least one backend installed. Skip when FFmpeg is absent.
4. **Browser tests** in `miniav_tools_web/test/` — `dart test -p chrome`. Cover capability
   detection, backend auto-registration (`ensureInitialized()`), MIME-type negotiation,
   `WebVideoFrameSource` construction, and a 64×64 H.264 CPU-path encode round-trip.
   Tagged `webgpu` tests require Chrome flags:
   `--enable-unsafe-webgpu --disable-dawn-features=disallow_unsafe_apis`

## Benchmarks

Per-backend benchmarks live in `benchmark/` subdirectories:

```
# FFmpeg software + hardware encoder throughput
cd miniav_tools_ffmpeg && dart run benchmark/encoder_bench.dart
# BENCH_HW=1   → also benchmarks detected HW vendors (NVENC/AMF/QSV/etc)
# BENCH_MUXER=1 → also benchmarks muxer write throughput

# minigpu MJPEG resolution/quality sweep
cd miniav_tools_minigpu && dart run benchmark/mjpeg_bench.dart
```

The `benchmark_harness` harness runs 3 warm-up iterations then measures 20
and reports mean ms/frame and fps.

## Open questions

- **Audio codecs** — `AudioEncoder` hierarchy mirrors `PlatformEncoder`; a
  separate `AudioCodec` enum (aac | opus | mp3 | flac) is the planned approach.
  FFmpeg and WebCodecs both map cleanly to this shape.
- **Streaming sinks** — `MuxerConfig.output` accepts a `callback` variant
  today. A `Stream<List<int>>` sink would be useful for network piping; post-MVP.
- **Subtitle / metadata tracks** — out of scope for v1; `MuxerConfig.tracks`
  is a `List<TrackInfo>` that can be extended without breaking changes.
- **`miniav_recorder` on web** — currently imports `miniav_tools_ffmpeg` directly.
  Moving backend registration to the app layer (option 2 in WEB_PLAN.md) is the
  lowest-effort path to making it cross-platform.
