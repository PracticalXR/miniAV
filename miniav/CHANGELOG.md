# miniav CHANGELOG

## 0.7.0

### GPU buffer handoff contract (Windows)

- **FIXED (leak): the shared NT handle on the GPU path is now closed by
  miniav.** Previously `MiniAV.releaseBuffer` only *logged* that the app was
  responsible for closing it and no caller ever did — one leaked kernel handle
  per captured GPU frame (60/s at 60 fps). miniav now owns the handle and
  closes it in the release path.
  - **Contract:** finish importing the handle (`OpenSharedResource1`, minigpu
    `importVideoFrame`, …) *before* calling `releaseBuffer` / `releaseBufferSync`,
    and do **not** `CloseHandle` it yourself. Release **every** buffer, including
    ones you skip — the handle is only closed on release.
- **DOCS FIX:** the README GPU example said the handle lives in `planes[0]`. It
  does not: it is in **`nativeHandles[0]`** (a plain Dart `int`). On the GPU path
  `planes[0]` is a non-null but **empty** `Uint8List` with stride 0, so
  `planes[0] != null` is *not* a CPU/GPU discriminator — use `buffer.contentType`.
- **`MiniAVNativeFence` is documented as unimplemented.** No backend populates
  it: `d3d11FencePtr`/`metalSharedEventPtr`/`metalFenceValue` are always `0`,
  `syncFd` always `-1`. The Windows backends instead insert a
  `D3D11_QUERY_EVENT`, `Flush()`, and busy-poll for ≤16 ms — **on timeout they
  hand the frame over anyway**, so a consumer can receive a texture whose
  producer-side copy has not finished.

- `MiniScreen.setIOSAppGroup(String)` — register the App Group shared with
  the iOS Broadcast Upload Extension before configuring the
  `system_screen_broadcast` display.

## 0.6.0

## 0.5.11

## 0.5.10

## 0.5.9

- add `MiniAV.releaseBufferSync()`: synchronous, fire-and-forget variant of
  `releaseBuffer()` for hot paths (e.g. a per-frame capture callback) that must
  avoid a per-call `Future`/microtask allocation. Delegates to the platform's
  synchronous release where available.

## 0.5.8

- fix audio buffer allocations and leak issue

## 0.5.7

- Fix logger noisiness

## 0.5.6

- fix FormatException on non-UTF-8 bytes in MiniAV log callback: use Utf8Decoder(allowMalformed: true) instead of toDartString()
- add setLogCallback and installStderrLogger to route native MiniAV C library logs to a Dart callback

## 0.5.5

- fix wasapi loopback issue

## 0.5.4

- adds bindings observer lib to fix crash on hot restart

## 0.5.3

- Fix crash bug on hot refresh, fix crash on second use of recorder

## 0.5.2

- adds shared textures

## 0.5.1

- adds subscriptions and fixes lost device crashes

## 0.5.0

- adding input support

## 0.4.7

- fix loopback crackles

## 0.4.6

- fix build hook null
- update cmake toolchain

## 0.4.5

## 0.4.1

- fix issue with num frames not being reported for audio_inputs

## 1.0.0

- Initial version.
