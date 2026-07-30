# Changelog

## 0.5.3 (unreleased)

- **Demuxer + live-stream muxing for miniav_player stream/file playback**
  (shim ABI 14 -> 15):
  - `FfmpegDemuxer` (was a throwing scaffold) + `IsolateDemuxer` — file / bytes
    / live byte-stream → `EncodedPacket`s with pts/dts/duration rescaled to
    microseconds (inverse of the muxer's rescale). `createDemuxer` returns the
    isolate host by default (`av_read_frame` blocks on live input and must be
    off the UI isolate); `backendOptions {'sw_isolate': '0'}` = in-isolate
    (file/bytes only). `durationUs` / `isSeekable` / keyframe `seek`.
  - Shim **blocking byte pipe** (`miniav_shim_bytepipe_*`) — feeds libavformat
    from a live `Stream<List<int>>` with pause/resume backpressure; closing the
    pipe unblocks a natively-stuck `av_read_frame` (the only way — `Isolate.kill`
    can't preempt synchronous FFI).
  - Seekable in-memory IO: `miniav_shim_open_input_bytes` (read+seek AVIO over a
    C-owned copy, so moov-at-end MP4 probes) and `..._memsink_*` (seekable output
    for `BytesMuxerOutput` so +faststart works). `FfmpegMuxer` now supports
    `BytesMuxerOutput` (seekable memsink) and `CallbackMuxerOutput` (streaming
    byte-pipe, streamable containers).
  - `Container.fmp4` now sets real fragmentation movflags
    (`+frag_keyframe+empty_moov+default_base_moof` + optional `frag_duration`) —
    init segment up-front, live-streamable.
  - Open-timeout robustness: a live stream stalling mid-probe surfaces a
    `CodecInitException` (default 15 s, `backendOptions {'open_timeout_ms'}`)
    instead of hanging `open()` forever.
- **Decode side for the miniav_player work** (shim ABI 13 -> 14):
  - `FfmpegAudioDecoder` — AAC/Opus/MP3/Vorbis/FLAC -> interleaved f32
    (planar formats interleaved during the mandatory AVFrame copy-out;
    stream rate/channels read per-frame via new shim getters
    `miniav_shim_frame_sample_rate` / `_nb_channels`).
  - `miniav_shim_codec_set_extradata`: `DecoderConfig.extraData` /
    `AudioDecoderConfig.extraData` now actually reach the codec context
    (avcC / hvcC / AAC ASC / OpusHead) instead of being ignored.
  - `IsolateVideoDecoder` / `IsolateAudioDecoder` — worker-isolate decoder
    hosts mirroring `IsolateSoftwareEncoder`'s TransferableTypedData
    protocol; `createDecoder`/`createAudioDecoder` return them by default
    (`backendOptions {'sw_isolate': '0'}` keeps the in-isolate path).
  - Fixed `FfmpegSoftwareDecoder` pts: decoded `frame.pts` is already in
    microseconds (packets are fed us with no time_base), so the old
    `* (1e6/30)` scaling corrupted timestamps; now passthrough with a
    delta-extrapolating AV_NOPTS fallback.

## 0.5.2

- Isolate-hosted **CPU-fed hardware** encoder (fixes the recording freeze on
  the software/CPU-fed path). `IsolateSoftwareEncoder.open` gained
  `hwVendorOrder` / `requireHardware`: the worker now tries each CPU-fed
  hardware vendor (looping `FfmpegHwEncoder.openWith`) before the software
  encoder, all on the worker isolate. Two things this unblocks:
  - **QSV / MediaFoundation now initialise.** Their COM objects require the
    MTA apartment; Flutter's UI isolate is STA (`miniav_shim_ensure_mta` →
    `RPC_E_CHANGED_MODE`), so on the UI isolate they failed at
    `avcodec_open2`. The worker runs on a fresh OS thread that enters MTA, so
    e.g. `h264_mf` and `h264_qsv` finally open. (Verified on an AMD iGPU box:
    the worker opens `h264_mf` where AMF fails its NV12 pool and NVENC has no
    device.)
  - **No UI freeze.** The blocking `avcodec_open2` probes and the per-frame
    encode both run off the calling (UI) isolate; frames cross as
    `TransferableTypedData` (~1 ms at 720p). Previously the Stage-A hardware
    open ran synchronously on the UI isolate.
  `FfmpegBackend.createEncoder` now routes the post-zero-copy path through this
  isolate encoder (removing the UI-isolate Stage-A open) and derives the
  vendor order from the capture adapter via the new `hwVendorOrderForDevice`
  (AMD→MF-before-AMF to dodge AMF's silent-black on AMD, Intel→QSV, NVIDIA→
  NVENC). `IsolateSoftwareEncoder` reports its actual encoder's
  `acceptsYuv420pPlanes` and an `activeEncoderDescription`. The `sw_isolate:'0'`
  escape hatch keeps the legacy in-isolate path.

## 0.5.1

- D3D11 HW-encoder vendor order now follows the injected device's adapter.
  `FfmpegD3d11HwEncoder.open` with an injected `ID3D11Device` (the recorder's
  zero-copy path) previously always tried the global default order
  (NVENC → AMF → QSV → MF), so on an AMD/Intel device it wasted an NVENC
  `avcodec_open2` — "OpenEncodeSessionEx failed: no encode device" — before
  falling through to the native vendor. It now derives the order from the
  device's DXGI vendor (AMD→AMF, Intel→QSV, NVIDIA→NVENC, + MediaFoundation
  fallback), so the native encoder is tried first and no cross-vendor attempt
  is made. The adapter-aware helper already backed the probe/warm-up paths;
  this wires it into `open()` too. `vendorOrder` is now optional; passing it
  explicitly still overrides.

## 0.5.0

- Software encoding no longer freezes the app: `createEncoder`'s software
  fallback now returns `IsolateSoftwareEncoder`, which hosts the exact same
  `FfmpegSoftwareEncoder` on a long-lived worker isolate. The synchronous libav
  encode (tens of ms/frame at 720p+) runs off the calling (UI) isolate; frames
  cross as `TransferableTypedData` (~1 ms), packets come back the same way, and
  codec extradata (SPS/PPS) is captured at open. Opt out with
  `backendOptions: {'sw_isolate': '0'}` (returns the classic in-isolate
  encoder, e.g. for tests that wire its `FfmpegEncoderBridge` directly).
- AMF (AMD) D3D11 zero-copy: BGRA input to `h264_amf`/`hevc_amf` is broken on
  real AMD hardware — AMD iGPUs reject BGRA frames at `avcodec_send_frame`
  ("Unknown error"), and some driver combos accept them but silently encode
  black. AMF now always uses the NV12 + D3D11 VideoProcessor pool (AMF's
  native input format; same fixed-function path QSV/MF use).
- NV12 hwframes-pool creation is now adaptive: bind-flag sets are tried from
  richest (Intel's SR|RT|DECODER|VIDEO_ENCODER) down to minimal (SR|RT),
  re-allocating the frames context per attempt — AMD rejects
  DECODER|RENDER_TARGET combinations with E_INVALIDARG. If no set works
  (some adapters cannot create NV12 texture arrays with RENDER_TARGET at
  all), the vendor is reported cleanly unavailable and encoding falls back to
  the next vendor / CPU — correct output instead of black video.

## 0.4.10

- Software encoder (`FfmpegSoftwareEncoder`) now accepts pre-converted planar
  YUV420P frames (`FrameSource.yuv420p`) directly — the planes are copied
  straight into the `AVFrame` with no internal RGBA→YUV conversion. Advertised
  via `acceptsYuv420pPlanes => true`. Lets the recorder convert RGBA→YUV420P on
  the GPU and skip the per-pixel Dart conversion on the software-encode path.
  The HW encoders (`d3d11`, generic `hw`/NV12, `nvenc`) keep their existing
  RGBA/NV12 input (`acceptsYuv420pPlanes => false`).

## 0.4.9

- **Licensing: switch to the BtbN LGPL FFmpeg build** (`kFfmpegLicense`). The
  previous GPL build (`-gpl-shared`) links libx264/libx265 and makes the whole
  binary GPLv2+, imposing copyleft on downstream products. The LGPL build keeps
  `libav*` under LGPL-2.1 (safe for proprietary dynamic linking). The cache dir
  is namespaced per-licence (`latest-lgpl`) so the change forces a fresh
  download instead of reusing a cached GPL install.
- Consequences of LGPL (no libx264/libx265): software H.264 now comes from
  `libopenh264` (BSD) and Windows MediaFoundation `h264_mf`; the MF spec no
  longer forces `hw_encoding=1`, so its software MFT works as a true CPU
  fallback. There is no software HEVC — `createEncoder` falls back to a
  downscaled (≤4096px) H.264 stream when a >4096px or HEVC request has no
  hardware encoder. AV1 (SVT-AV1) and VP9 (libvpx) remain available at any
  resolution.

## 0.4.8

- Increment to keep in step with others.

## 0.4.7

- Remove the inert auto-register top-level final and fix the docs: importing
  the package never actually registered the backend (Dart top-level finals
  are lazy and nothing read it). Call `registerFfmpegBackend()` explicitly
  (idempotent); `miniav_recorder` does it in `warmup()` and `start()`.

## 0.4.6

- Replace all direct `stderr.writeln` diagnostics with a levelled log hook:
  `setFfmpegToolsLogCallback` / `setFfmpegToolsLogLevel` (uses
  `MiniAVLogLevel`). Default sink is `print` — `dart:io` stdio writes crash
  console-less Windows GUI apps with an uncatchable async
  `FileSystemException` (errno 6), which also masked the real error when the
  FFmpeg auto-download failed.
- README: document FFmpeg warmup (`ensureFFmpegLoaded`,
  `MiniAVTools.warmup()`, `FfmpegDownloader.ensureFfmpeg`), correct the cache
  paths (`%LOCALAPPDATA%\miniav_tools\ffmpeg` etc. — not
  `~/.miniav_tools_ffmpeg`), and describe the new logging hook.

## 0.4.5

- Version bump for coordinated release with `miniav_recorder` 0.4.5.

## 0.4.4

- fixing recorder loopback drift

## 0.4.3

- audio data issue, increment miniav

## 0.4.2

- fix timing issue

## 0.4.1

- fix audio timing, add frame duplication

## 0.4.0

- fix frame rate scheduling

## 0.3.12

- fused shader cache fix

## 0.3.11

- Use GPU until we cant.

## 0.3.9

- AMF Fix, fix unknown audio error

## 0.3.8

- Fix vendor Order

## 0.3.7

- fix NV12 path

## 0.3.6

- fix cpu path

## 0.3.5

- fix recorder sync drift

## 0.3.4

- attempt fix resolution issue

## 0.3.3

- fix precheck

## 0.3.2

- fix property

## 0.3.1

- fix scaling crazy, attempt fix other HW encoders

## 0.3.0

- fix recorder logging, Tier A path, deps to 1.5.0

## 0.2.21

- increments minigpu to 1.4.15

## 0.2.20

- increments minigpu to 1.4.14

## 0.2.19

- increments minigpu to 1.4.12

## 0.2.18

- increments minigpu to 1.4.11

## 0.2.17

- increments minigpu to 1.4.9

## 0.2.16

- increments minigpu to 1.4.8, hopefully fix cpu fallback

## 0.2.15

- increments minigpu to 1.4.7

## 0.2.14

- fixes unicode, increments minigpu to 1.4.7

## 0.2.12

- Increment minigpu to 1.4.6

## 0.2.11

## 0.2.9

## 0.2.8

- add RecorderLogSource.minigpu: routes native minigpu/Dawn log lines through the unified Recorder log callback; Recorder.minigpuLevelFor public helper for tests; 12 new tests in log_level_test.dart

## 0.2.7

- fix FormatException on non-UTF-8 bytes in MiniAV log callback: use Utf8Decoder(allowMalformed: true) instead of toDartString()
- Increment minigpu to 1.4.4

## 0.2.6

- fix: add missing `dart:convert` import for `Utf8Decoder` (compilation error introduced in 0.2.5).

## 0.2.5

- fix: `FfmpegShim.setFfmpegLogCallback` now uses `Utf8Decoder(allowMalformed: true)` when decoding native C strings, so FFmpeg log messages containing non-UTF-8 bytes (Latin-1 filenames, Windows-1252 error strings, etc.) no longer throw `FormatException: Unexpected extension byte`.

## 0.2.4

- fix: `FfmpegShim.tryLoad()` no longer poisons its cache when called before FFmpeg has been loaded. The shim DLL imports avcodec/avutil; if those aren't loaded yet on Windows, the shim load fails and previously the failure was cached forever — breaking the audio encoder when `Recorder.setLogLevel`/`setLogCallback` was called early. tryLoad now skips silently (without caching) until FFmpeg is loaded.

## 0.2.3

- FFmpeg log forwarding shim bridge (miniav_shim_set_ffmpeg_log_callback, miniav_shim_set_ffmpeg_log_level); FfmpegShim.setFfmpegLogLevel, setFfmpegLogCallback; ABI bumped to 8; export FfmpegShim from barrel
- add unified Recorder.setLogLevel and Recorder.setLogCallback routing all native logs (MiniAV + FFmpeg) through a single Dart callback

## 0.2.1

- fixes dawn find issue

## 0.2.0

- add more quality control, fix ffmpeg usage issue

## 0.1.9

- fixes timestamp issues

## 0.1.8

- recorder scaling, warmup feature

## 0.1.7

- adds transform effects

## 0.1.6

- adds clip buffer

## 0.1.5

- fix loopback issue

## 0.1.4

- fix loopback issue, add tests

## 0.1.3

- update with fixes

## 0.1.2

- recorder sync and multi files

## 0.1.1

- updated to latest miniav/minigpu deps

## 0.1.0

- Initial release. FFmpeg-backed encoder, decoder, muxer and demuxer
  registered against `miniav_tools_platform_interface`.
- Software encode for H.264 / HEVC / VP9 / VP8 / AV1 / MJPEG / ProRes via
  libavcodec.
- Stage A hardware encode (CPU frame in, encoded packet out) using
  NVENC / AMF / QSV / VideoToolbox / MediaFoundation / V4L2 M2M.
- Stage B zero-copy D3D11 encode on Windows: takes an `ID3D11Texture2D` NT
  shared handle directly without any PCIe transfer or colour conversion.
  - `FfmpegD3d11HwEncoder.openWith(cfg, vendor, existingD3d11Device, sourceTextureFormat)`
    lets callers inject their own `ID3D11Device*` so the encoder runs on the
    same DXGI adapter as an external GPU API (Dawn / WebGPU). Required for
    cross-API NT-handle sharing — different adapters fail with `E_INVALIDARG`.
  - `sourceTextureFormat` selects `bgra` (default; matches DXGI screen
    capture and minigpu `SharedOutputTexture`) or `rgba`. The hwframes pool
    is allocated with this `sw_format` so `CopySubresourceRegion` from the
    caller's texture stays in the same DXGI type group.
- MP4 / Matroska / MPEG-TS muxer with byte-buffer, file and streaming
  callback outputs. Container-level fragmenting for low-latency streaming.
- Auto-download of FFmpeg shared libraries (BtbN GPL builds) on first run;
  set `MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1` to opt out.
