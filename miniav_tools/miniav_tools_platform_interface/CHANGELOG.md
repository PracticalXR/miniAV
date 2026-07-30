# Changelog

## 0.5.3 (unreleased)

- Audio **decode** contract (the `supportsAudioDecode()` capability existed
  with no factory): `PlatformAudioDecoder`, `DecodedAudio` (interleaved f32),
  `AudioDecoderConfig`, and `MiniAVToolsBackend.createAudioDecoder`
  (default `null` — non-breaking for existing backends).
- **Demuxer stream support** (for miniav_player stream/file playback):
  `DemuxerInput.byteStream(Stream<List<int>>)` (`StreamDemuxerInput`) for
  live/progressive containers; `PlatformDemuxer.durationUs` (nullable) and
  `PlatformDemuxer.isSeekable` (both default no-op → non-breaking). Packet
  `trackIndex` on demuxer output indexes into `tracks`.
- `DecodedFrame.webVideoFrame` (`Object?`, default `null`) — an
  already-presentable browser `VideoFrame` handle for the web WebCodecs
  decode path (presented directly, no readback). Native `implements
  DecodedFrame` classes must return `null`.

## 0.5.2

## 0.5.1

## 0.5.0

- Version bump to keep the miniav_tools family in lockstep; no changes in this package.

## 0.4.10

- Add `CpuExecutor` — a platform-agnostic seam for running CPU-bound work off
  the main isolate. Native (`dart:io`) uses a long-lived background `Isolate`
  reused across calls; web (`dart:js_interop`) runs inline (browser already
  threads the codec/GPU paths). Resolved via conditional import so `dart:isolate`
  never reaches web builds (verified with `dart compile js`). Intended for the
  pure-Dart CPU hotspots that have no native thread to hide behind (software
  pixel conversion fallback, AV1 entropy coder).
- Add `FrameSource.yuv420p` — a pre-converted planar YUV420P (I420) frame source
  (three tightly-packed u8 planes), so a GPU color-conversion step can feed an
  encoder directly with no further conversion.
- Add `PlatformEncoder.acceptsYuv420pPlanes` (default `false`) so the recorder
  can detect encoders that consume YUV420P planes natively.

## 0.4.9

- Increment to keep in step with others.

## 0.4.8

- Increment to keep in step with others.

## 0.4.7

- Increment to keep in step with others.

## 0.4.6

- Increment to keep in step with others.

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

## 0.2.5

## 0.2.4

## 0.2.3

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

## 0.1.0 — 2026-05-02

- Initial release. Defines `MiniAVToolsPlatform`, `MiniAVToolsBackend`,
  `EncoderConfig`, `DecoderConfig`, `MuxerConfig`, `DemuxerConfig`,
  `EncodedPacket`, `FrameSource`, codec/container enums, and exception types.
