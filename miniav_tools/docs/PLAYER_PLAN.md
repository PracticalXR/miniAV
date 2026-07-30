# miniav_player — Zero-Copy A/V Player Plan

**Status: Phase 2 DONE (2026-07-11) — STREAM/FILE PLAYBACK + WEB VIDEO.** Web video
playback added and runtime-verified in Chrome (WebCodecs decode → VideoFrame → canvas,
no YUV convert; §4c). Also: **fixed a "slow stream" report** — a demuxed broadcast played
with `PlayerLatencyMode.live` collapses each fragment burst to ~2 presented frames
(19.5 fps, half the frames dropped); `paced` (the `openSource` default) is smooth 30 fps
with zero drops. The GPU hot path was never the bottleneck. Details below.

**Phase 2 stream/file (2026-07-11).** `MiniavPlayer.openSource`
plays a **container source** — file, in-memory bytes, or a **live/progressive byte
stream** (fMP4/MKV/MPEG-TS over the network) — with auto-configured decoders,
decode-ahead backpressure, `seek`/`position`/`duration`/`onEnded`, and both live
(latest-wins) and paced (pts-clocked VOD) modes. This required implementing the FFmpeg
**demuxer** (was a throwing scaffold): `FfmpegDemuxer` + `IsolateDemuxer` over a new shim
**blocking byte-pipe** AVIO (ABI 15), seekable in-memory input/output sinks, `av_read_frame`
→ µs-rescaled `EncodedPacket`s (inverse of the muxer's rescale), keyframe seek with preroll
drop, and **open-timeout robustness** so a dead/stalled live connection errors instead of
hanging. `FfmpegMuxer` gained bytes/callback outputs (the "server side" of a live stream).
Verified: 9 demuxer tests (bytes / file+seek / live-fMP4 / **starved-close returns in 3 ms** /
stalled-open times out), and **E2E all 3 example modes PASS** — `packet` 179/179,
`stream` (live fMP4 → openSource, 206 decoded, non-seekable, latest-wins), `file`
(openSource + mid-play seek + onEnded, 10/10 checks, 173 decoded/148 presented with correct
preroll drop). See §5 for what remains (exact lip-sync, web WebCodecs, D3D11VA zero-upload).

---

**Phase 1 (2026-07-11) — CODE-COMPLETE + E2E CLOSED.** `miniav_player` package created
(live latest-wins + paced modes, keyframe-resync catch-up, stats, `MiniavPlayerView`);
codec seams shipped (audio-decode contract + `FfmpegAudioDecoder` + isolate decoder
hosts + extradata shim ABI 14 + decoder pts fix). Validated on the dev box:
GPU WGSL YUV→RGBA **byte-exact vs CPU reference 7/7 cases** (incl. 1080p +
non-multiple-of-8 dims, `tool/gpu_player_validate.dart`), AAC encode→decode
roundtrip green in both decoder hosts, H.264 roundtrip PSNR 49.4 dB through the
isolate decode path, 18 player unit tests green. **E2E gate CLOSED (2026-07-11):**
`examples/player` in its native `stream`/`file` container modes (self-verifying
Flutter Windows app: synthetic A/V → H.264/AAC encode → fMP4/MP4 mux → demux →
player; formerly `examples/player_loopback`) **PASSED all 8 checks** —
179/179 packets decoded, 178 presented (1 latest-wins supersede), 0 present/
decode/pipeline errors, 5.9 s audio via WASAPI with 0 drops; per-frame at
640×360: decode 0.49 ms, GPU convert+upload 0.71 ms, shared-texture copy
1.98 ms, present 0.15 ms — zero readback. Dawn bound via
`Minigpu.preferDisplayAdapter()` (primary display = RTX 4090 on the dev box).
Phase 1 is DONE; next work items live in §5.

Date: 2026-07-11 · This is the "future `_tools` media player" that
`miniav_ffi/miniav_c/REMOTE_DESKTOP_AV_PLAN.md` §Decision (2026-07-10) deferred output to,
and the "sequencing, audio sync, and demux/decode live in `miniav_tools` + app code"
counterpart that `miniav_view_design.MD` (minigpu_view) declares a non-goal for the view
layer. Read both first.

Goal: a network-first player that takes **EncodedPacket streams** (video + audio) from any
transport, decodes via the `miniav_tools` codec stack, and presents through
**minigpu_view** with the GPU hot path intact: **zero readback, zero redundant CPU pixel
copies, exactly one GPU upload per frame** (the unavoidable network→GPU load).

---

## 1. The hot path (Windows first, the shipping target)

```
network packet (CPU bytes — given)
  │  submitVideoPacket(EncodedPacket)                     [UI isolate: enqueue only]
  ▼
video decode worker isolate                                [TransferableTypedData in]
  │  FfmpegSoftwareDecoder → YUV420P planes (1.5 B/px)
  │  planes → TransferableTypedData                        [1 copy + zero-copy transfer]
  ▼
UI isolate: VideoFramePresenter (minigpu)
  │  Buffer.write(yuvBytes)                                [THE one GPU upload, 1.5 B/px]
  │  WGSL yuv420p→rgba8 dispatch (BT.601 limited,
  │     exact integer inverse family of GpuYuv420Converter)
  │  SharedOutputTexture.copyFromBufferAsync(rgba)         [GPU→GPU]
  ▼
MinigpuPreviewController.present(tex.asPreviewSource())    [D3D11 NT handle only]
  ▼
Flutter Texture widget samples the shared texture          [ZERO readback anywhere]
```

Accounting per 1080p frame: decode output materialisation (3.1 MB memcpy, worker), the
transferable copy (3.1 MB, worker), one 3.1 MB GPU upload (UI isolate, async Dawn queue
write), one GPU-side convert dispatch, one GPU-GPU texture copy. The UI isolate never
touches pixels — it only submits GPU commands. Compare the legacy
`decodeImageFromPixels` path this replaces: GPU readback + 8.3 MB RGBA CPU traffic + Skia
decode + re-upload, per frame.

Why decode on a worker isolate: libavcodec calls are synchronous FFI (tens of ms for
big frames) — same reason as `IsolateSoftwareEncoder` (which this mirrors 1:1, including
the TransferableTypedData protocol and `errorsAreFatal` handshake).

Why convert on the UI isolate (for now): the per-frame GPU work is a handful of async
command submissions (~sub-ms CPU). The gsplats420 offload experiment proved
GPU-in-worker + present-handle relay works (after main-isolate Dawn pre-init) if this
ever shows up in a profile — that is the escape hatch, not the default.

### Backpressure / drop policy (live mode)
- Present ping-pongs **two** `SharedOutputTexture`s + two RGBA scratch buffers (the
  two-frame steady state from the minigpu_view design). Never more than one
  decode-result in flight through the GPU stage.
- **Latest-wins**: if a newer decoded frame arrives while one is queued for present, the
  queued one is dropped (remote-desktop latency beats completeness). `paced` mode (VOD)
  instead schedules by PTS against the player clock.
- Decode input queue is bounded (default 2 packets + always-keep-keyframes); overflow
  drops oldest-first and requests… nothing (no RTCP here) — the transport layer owns
  retransmit/keyframe-request; we surface `stats.droppedPackets` so it can.

## 2. Audio path

```
submitAudioPacket → audio decode worker isolate (FfmpegAudioDecoder: AAC/Opus/MP3 → f32 interleaved)
                  → StreamPlayer.writeFloat32 (miniaudio_dart, ring ≈ bufferMs)
```

- New contract: `PlatformAudioDecoder` / `AudioDecoderConfig` / `DecodedAudio` in
  `miniav_tools_platform_interface` (the `supportsAudioDecode()` capability existed with
  no factory — this completes the seam), `MiniAVTools.createAudioDecoder()` facade.
- FFmpeg decodes to whatever the codec produces (usually `fltp`); the decoder
  interleaves to f32 during the mandatory copy-out (no extra pass).
- Output rate/channels come from the **first decoded frame** (new shim getters), so the
  `StreamPlayer` inits lazily to the true stream format; no resampler in Phase 1.

### A/V sync (Phase 1 scope, honest version)
- `PlayerClock`: pts-anchored monotonic wall clock. First accepted **audio** frame
  anchors it (video anchors if there is no audio track). Video presents when
  `pts ≤ clock.mediaTimeUs + slack` (paced mode) or immediately (live mode).
- Audio drift control is **queue-depth based**: `writeFloat32` returning short counts
  = ring full → drop the chunk tail and step the anchor (overrun); underrun just plays
  silence (miniaudio) and the anchor re-syncs on the next write.
- Exact lip-sync (`playedFrames` cursor from miniaudio's ring) needs a tiny
  `miniaudio_dart` native getter — **Phase 2**, noted seam, cross-repo.

## 3. Codec-side changes shipped with Phase 1

1. **`FfmpegSoftwareDecoder` PTS bug**: packets are fed `pts = ptsUs` with no
   `time_base`, so decoded `frame.pts` IS microseconds already — the current
   `f.pts * (1e6/30)` multiplication corrupts timestamps. Fix: pass through, with a
   duration-accumulating fallback for `AV_NOPTS`.
2. **Extradata**: `DecoderConfig.extraData` is currently ignored (avcC H.264 / AAC ASC
   streams can't init). New shim export `miniav_shim_codec_set_extradata`
   (`av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE)`, owned by the codec ctx) wired
   into both video and audio decoder open paths.
3. New shim getters `miniav_shim_frame_sample_rate` / `miniav_shim_frame_nb_channels`
   (read `AVFrame` fields beyond the mapped Dart prefix — C reads are layout-safe).
   Shim ABI version bumps; remember the hooks_runner stale-cache trap when rebuilding.
4. `IsolateVideoDecoder` / `IsolateAudioDecoder` in `miniav_tools_ffmpeg` — worker-isolate
   hosts mirroring `IsolateSoftwareEncoder` (these are what the player actually uses; they
   are also independently useful, e.g. for the recorder's future preview-while-recording).

## 4. Package layout

```
miniav_tools/
  miniav_player/                ← NEW Flutter package (present needs minigpu_view)
    lib/miniav_player.dart
    lib/src/
      player.dart               MiniavPlayer facade (open/submit*/flush/close/stats)
      player_config.dart        VideoStreamSpec / AudioStreamSpec / PlayerLatency
      player_clock.dart         pts-anchored wall clock (fake-clock injectable)
      video_scheduler.dart      live latest-wins / paced pts scheduling + drop stats
      video_presenter.dart      minigpu YUV420P→RGBA8 + SharedOutputTexture ping-pong
                                + MinigpuPreviewController.present
      audio_output.dart         StreamPlayer sink + queue-depth drift control
      yuv_rgba_reference.dart   CPU reference (lockstep target for the WGSL kernel)
      player_view.dart          MiniavPlayerView widget (wraps MiniavGpuPreview)
    tool/gpu_player_validate.dart   main-isolate GPU==CPU byte-exact check
                                    (Dawn cannot init in `dart test` isolates on the
                                    dev box — same pattern as gpu_v9_validate)
    test/                       pure-Dart: scheduler, clock, reference conversion
```

Dependencies: miniav_tools (+ _ffmpeg, _platform_interface), minigpu, minigpu_view,
miniaudio_dart, flutter. Local dev via pubspec_overrides (workspace convention).

Color space note: Phase 1 pins BT.601 limited range — the exact inverse family of the
recorder's `GpuYuv420Converter` and `pixel_convert.dart`, so a miniAV-encoded →
miniav_player round trip is colorimetrically consistent. BT.709 tagging is Phase 2
(one more WGSL constant set, switched by config).

## 4b. Phase 2 stream/file playback (2026-07-11 — DONE)

**Source API.** `MiniavPlayer.openSource(MediaSource)` where `MediaSource` is
`.file(path)` | `.bytes(Uint8List)` | `.byteStream(Stream<List<int>>)`. It probes the
container, auto-builds decoders from the discovered tracks (codec + avcC/ASC extradata),
and runs an internal **demux pump** with **decode-ahead backpressure** (bounds
undecoded-packet + unpresented-frame depth; the paced-audio ring-full wait is the
transitive throttle). Paced mode is the default for sources (pts-clocked VOD); pass
`latency: live` for realtime feeds. `duration` / `position` / `isSeekable` / `seek()` /
`onEnded` round out the transport surface.

**Demuxer (was a throwing scaffold).**
- `FfmpegDemuxer` — `avformat_open_input` + `find_stream_info`, `av_read_frame` →
  `EncodedPacket` with pts/dts/duration rescaled stream-time-base → **microseconds**
  (the exact inverse of `FfmpegMuxer.writePacket`, so mux→demux is pts-exact), track
  filtering (unsupported streams skipped), extradata surfaced per track.
- `IsolateDemuxer` — worker-isolate host (mirrors `IsolateVideoDecoder`). `av_read_frame`
  is synchronous FFI that **BLOCKS** on a live pipe, so it must be off the UI isolate.
- **Shim byte pipe (ABI 15).** A native blocking ring (`miniav_shim_bytepipe_*`): the
  feed side (main isolate) writes without blocking + applies stream pause/resume
  backpressure when the ring fills; the read side blocks inside `av_read_frame` until
  bytes arrive or the pipe is closed (→ EOF). **Closing the pipe is the only way to
  unblock a natively-stuck worker** — `Isolate.kill` cannot preempt synchronous FFI.
  Verified: closing a starved live demuxer returns in **3 ms**.
- **Seekable in-memory IO.** `openBytes` demuxes a C-owned copy behind a read+seek AVIO
  (moov-at-end MP4 needs seeks — a forward-only pipe can't probe it). `BytesMuxerOutput`
  muxes into a seekable memory sink (so +faststart's moov rewrite works); the streaming
  `CallbackMuxerOutput` uses the non-seekable pipe (streamable containers only).
- **fMP4 fragmentation** — `Container.fmp4` now sets `+frag_keyframe+empty_moov+
  default_base_moof` (init segment up-front → live-streamable); `fragmentDurationUs`
  caps fragment length.
- **Open-timeout robustness** — a live stream that stalls mid-probe would hang `open()`
  forever; stream inputs default to a 15 s bound (`backendOptions {'open_timeout_ms'}`),
  on timeout unblocking the worker via `bytepipeClose` and surfacing a `CodecInitException`.

**Seek.** `av_seek_frame(BACKWARD)` lands on the keyframe at/before the target; the
player quiesces the decode pumps (they honor `_seeking` so a decoder is never closed
mid-decode), recreates decoders (libav reference state is invalidated by a container
seek), then drops decoded preroll frames until the target pts — so the first frame
shown/heard is the seek target.

## 4c. Web video playback (2026-07-11 — DONE, runtime-verified in Chrome)

The player now compiles for web (`flutter build web`) and runs (Chrome: 148/148 frames
presented, 0 errors — a WebCodecs encode→decode→canvas loopback, the default `packet`
mode of the unified `examples/player`, which runs the same demo on web and native).
Web is architecturally the *reverse-simpler* path for video: WebCodecs `VideoDecoder`
outputs a `VideoFrame` that is ALREADY a display surface (browser-decoded, GPU-backed),
so it is presented **directly** — no YUV→RGBA convert, no minigpu compute context, no
`SharedOutputTexture`.

```
native:  EncodedPacket → FFmpeg decode → YUV420P → GPU convert → SharedOutputTexture → present
web:     EncodedPacket → WebCodecs VideoDecoder → VideoFrame → minigpu_view canvas present
```

- **`WebCodecsVideoDecoder`** (`miniav_tools_web`) — implements `PlatformDecoder`; the
  decoded frame exposes the JS `VideoFrame` via the new `DecodedFrame.webVideoFrame`
  accessor (`Object?`, null on native — keeps the interface platform-neutral). Bridges
  WebCodecs' async output-callback to `decode() → DecodedFrame?` without per-frame
  `flush()` (which would reset reference state). Codec description (avcC/hvcC) from
  `DecoderConfig.extraData`.
- **Conditional compilation** — the player selects its codec backend registration by
  platform (`backend_register_native.dart` / `_web.dart` via `if (dart.library.js_interop)`),
  so `dart:ffi` (FFmpeg) never reaches the web build and `dart:js_interop` (WebCodecs)
  never reaches the native build. On web the player skips `Minigpu` + `VideoFramePresenter`.
- **Present branch** — `ScheduledVideoFrame` carries EITHER YUV420P bytes (native) OR a
  browser `VideoFrame` (web); the scheduler owns release (a VideoFrame is `close()`d on
  present OR drop, so none leak). The present closure branches: web → `webVideoFrame`
  PreviewSource → `controller.present`.
- **The non-obvious web fix** — a raw JS `VideoFrame` cannot cross the method-channel
  `StandardMessageCodec` ("Invalid argument: Instance of 'LegacyJavaScriptObject'"). So
  the frame is stashed in a shared JS-global registry (`globalThis.miniavVideoFrameRegistry`)
  and only a codec-safe int handle is sent; the minigpu_view web plugin pops it back out —
  mirroring the existing WebGPU `bufferHandle` pattern. (The plugin's prior `webVideoFrame`
  branch expected the JSObject directly and was never actually reachable.)

## 5. Still remaining (post-Phase-2)

- **Web audio** — video-only on web today. Needs a `WebCodecsAudioDecoder` + verifying
  the miniaudio web `StreamPlayer` sink (miniaudio_dart_web currently uses legacy
  `package:js` → a WASM-dry-run incompatibility; JS builds are fine). The player already
  tolerates `audio == null`.
- **Web container demux** — `openSource(file/byteStream)` is native-only (no web demuxer);
  on web, feed `EncodedPacket`s (`MiniavPlayer.open` + `submitVideoPacket`) or use MSE.
- **HW decode (D3D11VA)** — the native zero-upload dream (decode→GPU NV12→Dawn import→
  convert→present, no CPU pixels at all). `DecoderConfig.requestGpuOutput` and
  `BackendContext.d3d11DeviceHandle` are the waiting seams. Big native lift.
- **Exact lip-sync cursor** — audio drift is currently queue-depth based; a miniaudio
  ring-position getter would give sample-accurate a/v alignment.
- **B-frame reorder** — our encoders emit `bFrameCount: 0` and the scheduler orders by
  pts, so VOD sources with B-frames only need a deeper reorder window before present.
- **BT.709 tagging** — the YUV→RGBA kernel pins BT.601 limited (matches our encoders);
  a 709 constant set switched by container/stream color metadata is a follow-up.

## 6. Test / validation plan

- Pure-Dart unit tests: scheduler (fake clock: pacing, latest-wins drops, pause), clock
  anchoring/re-anchor, CPU YUV→RGBA reference vs the recorder's RGBA→YUV reference
  (round-trip tolerance ≤1 LSB per plane sample where in-gamut).
- `tool/gpu_player_validate.dart`: GPU kernel output byte-exact vs CPU reference on
  synthetic + gradient frames (run on main isolate; skips in `dart test` — dev-box Dawn
  limitation, see gsplats420 GPU test env notes).
- E2E smoke (manual, examples/): loopback pipe — `Recorder`-side H.264/AAC encode →
  in-process packet channel → player; verify motion smoothness + stats + no UI jank.
