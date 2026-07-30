# Changelog

## 0.2.0 (unreleased)

- **Web playback (video).** The player now compiles and runs on web:
  conditional backend registration (FFmpeg on native / WebCodecs on web —
  keeps `dart:ffi` out of the web build and `dart:js_interop` out of native),
  and a web present branch — a WebCodecs `VideoFrame` (already display-ready)
  is presented directly through minigpu_view's canvas (`webVideoFrame`
  PreviewSource) with no YUV→RGBA convert and no minigpu compute context. The
  scheduler now carries either YUV420P bytes (native) or a browser VideoFrame
  (web) and owns its release (VideoFrames are `close()`d on present or drop).
  Demo: the unified `examples/player` runs the same encode→decode→present
  loop on web (WebCodecs) and native (FFmpeg) from one `main.dart`, with the
  native-only container `stream`/`file` modes gated behind a conditional
  import. Web audio now works too (Opus via WebCodecs → miniaudio WASM sink).
- Stream/broadcast smoothness: `MiniavPlayer.openSource` defaults to `paced`
  (pts-clocked). `PlayerLatencyMode.live` (latest-wins) is documented as
  correct ONLY for realtime packet feeds — using it for a demuxed container
  stream collapses each fragment burst to ~1–2 presented frames (choppy).
- **Source-driven playback** — `MiniavPlayer.openSource(MediaSource)` where
  `MediaSource` is `.file(path)` / `.bytes(Uint8List)` /
  `.byteStream(Stream<List<int>>)` (live/progressive fMP4/MKV/MPEG-TS). Probes
  the container, auto-configures decoders from the tracks (codec + extradata),
  and runs an internal demux pump with decode-ahead backpressure.
- Transport surface: `duration`, `position`, `isSeekable`, `seek(Duration)`
  (keyframe seek with preroll drop + decode-pump quiesce so decoders are never
  swapped mid-decode), and `onEnded`. Paced mode is the default for sources
  (pts-clocked VOD); pass `latency: live` for realtime feeds.
- Paced audio output (`writePaced`) never drops — the ring-full wait is the
  decode-ahead throttle for VOD playback.

## 0.1.0

- Initial release: packet-driven zero-copy player.
  - Video: worker-isolate FFmpeg decode → single GPU upload → WGSL
    YUV420P→RGBA8 (BT.601 limited, byte-exact vs CPU reference) →
    `SharedOutputTexture` ping-pong → minigpu_view present (zero readback).
  - Audio: worker-isolate FFmpeg decode (AAC/Opus/MP3/Vorbis/FLAC → f32
    interleaved) → miniaudio `StreamPlayer`.
  - `PlayerLatencyMode.live` (latest-wins) and `.paced` (pts-clocked)
    scheduling; keyframe-resync catch-up on decode backlog; stats.
