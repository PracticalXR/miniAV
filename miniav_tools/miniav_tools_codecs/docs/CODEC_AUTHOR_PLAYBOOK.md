# Codec-Author Playbook

How to add a codec/container backend to `miniav_tools_codecs` without
re-learning the traps. Every rule here was earned in a real debugging session.

## 1. Backend + negotiation

- Implement `MiniAVToolsBackend`; register it in the barrel's `register*()`
  and (for the player) `backend_register_native.dart` / `web.dart`.
- **Report only HONEST capabilities.** `supports*() => true` for a codec you
  can't actually open is a negotiator lie — it turns "clean fallback to the
  next backend" into a crash (the prores lesson). Return `null` from a
  `create*` on unsupported input so the negotiator falls through.
- Priorities: container_framing 55 > FFmpeg 50; audio SW 55; opus 60; pcm 70;
  MF-AAC 55 (Windows-only); MF-encode 45 (opt-in). Pick > 50 only when the
  backend should beat FFmpeg by default.
- All factories (`createDecoder/Encoder/AudioDecoder/AudioEncoder/Muxer/
  Demuxer`) go through `_negotiateCandidates` — a new backend gets negotiation
  (incl. `BackendPreference.excluded/pinned`) for free.
- Every `implements DecodedFrame` class must declare ALL members —
  `pixelLayout`, `isFullRange`, `colorMatrix`, `webVideoFrame`, `outputKind`,
  `gpuHandle`, `subresourceIndex` — Dart does not inherit default bodies
  across `implements`.

## 2. Native code (the C asset)

- Sources live in `native/`, built by `hook/build.dart` (CMake). List sources
  unconditionally; guard platform-specific files with `#if defined(_WIN32)`
  etc. so they compile to empty TUs elsewhere — the source list stays
  identical on every OS.
- **Cache-bust trap:** the hooks runner does NOT reliably rebuild on `.c`
  edits. `rm -rf .dart_tool/hooks_runner` in the package (and in any consumer
  package that built its own copy) before testing a native change.
- Per-OS link rules (CMakeLists): `m` on `UNIX AND NOT APPLE` (dr_libs/stb
  math); MF/D3D11 libs only under `WIN32`; `-fvisibility=hidden` off-Windows;
  export macro per file (`__declspec(dllexport)` / visibility default).
- Editing C strings with escapes: use the harness Edit tool — python
  `str.replace` has silently mangled `\n` into real newlines here (C2001).
- Debug native parsers/pipelines with an env-gated stderr trace
  (`MFAAC_DEBUG=1` pattern) or a structure dump tool, not by staring.

## 3. Colour conversion — one source of truth

- Coefficient tables + the pure-Dart reference loops live in
  `miniav_tools_platform_interface` (`lib/src/color/` — `YuvRgbCoeffs` /
  `RgbaYuvCoeffs` `.of(matrix, fullRange:)`, `dartI420ToRgba` /
  `dartRgbaToI420` / `dartI422ToRgba`). That package is pure Dart with no
  build hooks, so web builds, backend packages, and external consumers
  (livetensor) share the math without dragging in FFI/minigpu. The tables are
  MIRRORED in this package's `native/frame_convert.c` (`pick()` /
  `inv_pick()`; matrix: 0=601, 1=709, 2=2020-NCL) and in the GPU kernels'
  params. If you touch one, touch all of them; the byte-exact tests
  (`test/rgba_yuv_convert_test.dart`, `test/gpu_planar_yuv_test.dart`,
  `test/gpu_rgba_yuv420_test.dart`) will catch drift.
- Entry points by boundary: `convert.dart` (pure math re-export),
  `gpu.dart` (minigpu converters, web-safe), main barrel (adds the C-backed
  `CpuFrameConverter` — the fast native path).
- Both directions exist: YUV→RGBA (decode/display) AND RGBA→YUV420
  (encode-side, `bgra:` flag for BGRA sources, chroma = rounded 2x2 box
  average, odd dims edge-replicate). Don't hand-roll either direction in a
  consumer again.
- The pipeline default is BT.601-limited (miniAV's own encode family). Tag
  709/2020/full-range ONLY from explicit bitstream metadata — never guess
  from resolution.
- PQ/HLG transfer is deliberately NOT applied (no tone mapping); BT.2020 is
  the matrix only. Don't "fix" HDR by scaling in a converter.

## 4. Test pattern (what "verified" means here)

- **Byte-exact vs an independent reference.** C converters test against a
  Dart mirror of the fixed-point math (`frame_convert_test.dart`); the GPU
  kernel tests against the C converter (`gpu_planar_yuv_test.dart`) — GPU
  suites `markTestSkipped` when Dawn can't init, and pass on the dev 4090.
- Round-trip through the real other half (mux→demux, encode→decode), not
  synthetic expectations.
- Fixtures come from the ffmpeg CLI (choco/apt), generated into
  `test/assets/` (untracked); fixture-dependent tests SKIP cleanly when the
  file is absent. Generation commands live in the test header comments and in
  `.github/workflows/dart-ci.yml`.
- Run with `dart test` (NOT `flutter test` — native-assets under flutter
  master crashes).
- Agent-written specs/implementations are DRAFTS: verify against the spec's
  own claims before trusting (Ogg lacing, ADTS header, MF sample-allocation
  bugs were all caught this way).

## 5. FFmpeg shim ABI

- Any change to `miniav_tools_ffmpeg`'s shim exports bumps
  `FfmpegShim.kExpectedAbiVersion` AND the pinned assertion in
  `test/ensure_mta_test.dart` (doc + `equals(N)`). Both, every time.

## 6. CI legs (what a green run proves)

- `codecs-native-build.yml`: the native asset CONFIGURES + COMPILES on
  windows/linux/macos/android/ios. No runtime claims.
- `dart-ci.yml`: analyze across the stack; the FFmpeg-free codec suites on
  Windows (native asset via the CMake hook, fixtures generated on the
  runner); pure-Dart suites on Ubuntu; `flutter build web` of the player
  example. GPU byte-exactness is only guaranteed by a run on a machine with a
  working Dawn adapter (the dev box) — CI runners may skip those.
- Windows-only runtime behaviour (MF decode/encode/AAC) is NOT covered by CI
  hardware; it's covered by the dev-box suites.
