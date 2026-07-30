# player — cross-platform miniav_player demo

One codebase, runs on **both web and native**. A synthetic A/V source is
encoded through the `MiniAVTools` facade (WebCodecs on web, FFmpeg on native),
looped back as `EncodedPacket`s, and played through `MiniavPlayer` (GPU
YUV→RGBA present with zero readback + miniaudio audio).

## Modes

| Mode     | Platforms | What it does                                                            |
| -------- | --------- | ----------------------------------------------------------------------- |
| `packet` | web + native | (default) synthetic H.264 + Opus → packet loopback → `MiniavPlayer.open`. Shows a PASS/FAIL verdict on-page; prints `PLAYER-SMOKE:`. |
| `stream` | native only | encode → fMP4 mux → live byte-stream → `openSource` (paced demux).       |
| `file`   | native only | encode → MP4 file → `openSource` + mid-playback seek + `onEnded` (VOD).  |

The container modes need the FFmpeg muxer + `dart:io`, so they live behind
`lib/container_modes.dart`'s conditional import and never reach the web build.
On web, only `packet` is reachable.

## Run

```sh
# Web (needs cross-origin isolation for the audio WASM + WebGPU shared memory —
# the bundled coi-serviceworker.js handles it, or pass the headers directly):
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp

# Native packet demo:
flutter run -d windows

# Native container modes (self-verifying — writes player_smoke_result_<mode>.json,
# exits 0/1). Pass the mode (and optional stream latency) as program args:
flutter run -d windows --dart-entrypoint-args stream        # or: stream live
flutter run -d windows --dart-entrypoint-args file
```
