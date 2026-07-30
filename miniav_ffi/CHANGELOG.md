# miniav_ffi CHANGELOG

## 0.7.0

### GPU buffer handoff contract (Windows) — leak fixes

- **The shared NT handle handed out on the GPU path is now closed by miniav**
  in the release path of all three Windows backends (WGC screen, DXGI screen,
  MF camera). It was previously only logged as "app is responsible", and no
  caller closed it: one leaked kernel handle per captured GPU frame. The DXGI
  backend did not even store the handle, so it was unclosable.
  Callers must import the handle before releasing the buffer and must not close
  it themselves. WGC additionally keeps an outstanding-handle counter and logs
  an ERROR at context destroy if any handle was never released.
- **Buffers queued to a `NativeCallable.listener` are no longer dropped on
  close.** `stopCapture()`/`destroy()` closed the callable immediately, and
  `close()` discards undelivered messages — a dropped buffer never reaches
  `MiniAV_ReleaseBuffer`, leaking its D3D11 texture reference and shared handle.
  Screen and camera contexts now stop the native capture first, drain pending
  callbacks into a release-only branch, and close afterwards. `destroy()` also
  no longer skips the native StopCapture.
- `MiniAVBuffer.native_fence` is documented in `miniav_buffer.h` as
  never-populated, together with the 16 ms busy-poll and proceed-on-timeout
  behaviour that stands in for it.

Mobile platform catch-up: first-class **Android** and **iOS** backends for
camera and screen capture, per `miniav_c/MOBILE_PLATFORM_SPEC.md` (six Opus
implementation agents + an 8-dimension adversarial review — 17 raw findings,
11 confirmed, all fixed). Mic capture on both platforms rides the existing
portable miniaudio module. No mobile input tier in v1; Android loopback
(AudioPlaybackCapture) deferred.

### New backends

- **Android camera (Camera2 NDK, API 24+).** ACameraManager enumeration
  (facing in the device name), AImageReader YUV_420_888 CPU path with
  truthful per-frame plane labeling (NV12/NV21 by chroma pixel-stride;
  planar always delivered as I420 with explicit per-plane pointers), and a
  runtime-gated (26+) `AHARDWAREBUFFER` GPU path. Camera clock nanoseconds →
  `miniav_rebase_time_us`. No owned threads: the NDK looper model is
  documented in the backend header.
- **Android screen (MediaProjection, effective floor 26+).** The app supplies
  a consented `MediaProjection` via the new
  `MiniAV_Screen_SetAndroidMediaProjection(jvm, projection)` seam (global-ref
  ownership transfers to native; clearing with a NULL projection is the
  authoritative stop signal and fires `lost_cb`). Native builds the
  AImageReader→Surface→VirtualDisplay pipeline; RGBA CPU path +
  AHardwareBuffer GPU path; drop-oldest under backpressure.
- **iOS camera (AVFoundation port of the macOS backend).** Discovery-session
  enumeration with front/back naming, NV12-preferred formats, the same planar
  Metal zero-copy texture path (UMA), permission gate returns
  `PERMISSION_DENIED` without prompting, interruption-aware one-shot
  `lost_cb`. Sensor-native orientation in v1.
- **iOS screen (ReplayKit, two tiers).** `app_screen` = in-app
  RPScreenRecorder (video CPU+Metal GPU paths, app-audio + optional mic).
  `system_screen_broadcast` = system-wide capture via a Broadcast Upload
  Extension: the new producer kit (`miniav_broadcast_sender` + reference
  Swift `SampleHandler` + `SETUP.md`) writes NV12 into a page-aligned
  App-Group shared-memory ring (the pipeline's only pixel copy); the host
  wraps ring slots zero-copy with `newBufferWithBytesNoCopy` + Metal texture
  views and can deliver `GPU_METAL_TEXTURE`. Drop-oldest slot leases tied to
  `MiniAV_ReleaseBuffer`; host app group set via
  `MiniAV_Screen_SetIOSAppGroup`. Protocol pinned in
  `miniav_broadcast_protocol.h`.
- **iOS mic session shim.** `AVAudioSession` PlayAndRecord (+MixWithOthers,
  +DefaultToSpeaker) is activated around miniaudio start/stop — balanced on
  every failure path — so shared mic capture works on iOS unchanged.

### API / infrastructure

- New error code `MINIAV_ERROR_PERMISSION_DENIED (-23)`; miniAV never
  prompts — apps request OS permissions first. Error-string table completed
  for all codes; `MiniAV_GetVersionString()` now reports the real version.
- Dart bindings: `MINIAV_ERROR_PERMISSION_DENIED` added to
  `MiniAVResultCode` (previously an unknown code made `fromValue` throw
  `ArgumentError`), and `MiniAV_Screen_SetIOSAppGroup` is bound with a
  `MiniFFIScreenPlatform.setIOSAppGroup(String)` implementation.
- Android JNI plumbing (`common/miniav_jni_android`): explicit
  `JavaVM*` publication (dlopen does NOT run `JNI_OnLoad`; the C-API seam is
  authoritative), per-thread attach/detach helpers.
- Platform-gate hardening: Android no longer falls into bare `__linux__`
  arms, iOS no longer falls into bare `__APPLE__` arms (loopback/input are
  cleanly `NOT_SUPPORTED` on mobile); `miniav_timed_join` correctly gated to
  glibc. CMake: iOS deployment target 13.0, Metal linked on iOS, Android
  link floor API 24 with `__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__` for
  runtime-gated 26+ APIs. New GitHub Actions matrix
  (`.github/workflows/native-build.yml`): windows / linux / macos / android
  (arm64-v8a, API 24) / ios configure+build legs.
- Flutter consent piece (in `miniav_flutter`): Kotlin MethodChannel plugin
  (`requestScreenCapture()`), mediaProjection-typed foreground service
  started **before** `getMediaProjection` (Android 14 ordering), Java-side
  `MediaProjection.Callback.onStop` relay to both Dart and native, JNI shim
  handoff to the C seam.

### Remote-desktop primitives (desktop output/control direction)

Adds the sink/control half of the A/V/Input layer so a cross-platform
remote-desktop client/server can be built on miniAV. Per
`miniav_c/REMOTE_DESKTOP_AV_PLAN.md` (three Opus per-platform agents + a
three-dimension adversarial review — 1 major + 3 minor findings, all fixed).
Audio/video *playback* is intentionally NOT here — it becomes a future
`_tools` media player (bring-your-own / bundled codec, GPU hotpath preserved).

- **Input injection — new `MiniAV_Inject_*` module** (the sink twin of input
  capture): replays synthetic keyboard/mouse events onto the local machine.
  Windows `SendInput` (compiled + linked + smoke-tested), macOS `CGEventPost`
  (Accessibility-gated, MRC), Linux `/dev/uinput` (works under X11 **and**
  Wayland). Handles keyboard down/up, mouse absolute/relative move, all
  buttons (incl. X1/X2), and vertical + horizontal wheel. The same
  `MiniAVKeyboardEvent`/`MiniAVMouseEvent` structs used by capture are
  replayed, so a captured event injects verbatim on the same platform. Codes
  are platform-native; cross-platform translation is the caller's job.
  Permissions surface as `MINIAV_ERROR_PERMISSION_DENIED` (macOS Accessibility;
  Linux `/dev/uinput` access) — miniAV never prompts. Gamepad injection is
  out of scope in v1 (needs a virtual-gamepad driver).
- **Cursor in captured frames — `MiniAV_Screen_SetCaptureCursor(ctx, bool)`**
  (call before configure; off by default). Honored on Windows WGC
  (`IsCursorCaptureEnabled`), macOS ScreenCaptureKit (`showsCursor`), and
  Linux PipeWire (portal embedded cursor mode). Windows DXGI Desktop
  Duplication cannot draw the cursor — it logs a warning and captures
  cursor-less; use the WGC backend when you need the cursor.
- **Horizontal scroll** — `MiniAVMouseEvent` gains `wheel_delta_x` (horizontal
  wheel, populated by all three capture backends) alongside the existing
  vertical `wheel_delta`, plus `is_absolute` (capture sets it true;
  injection uses it to pick absolute vs relative move). Dart FFI struct
  updated to match (byte-exact, review-verified).
- **Dart**: `MiniInject`/`MiniInjectContext`, `MiniScreen.setCaptureCursor`,
  and the new mouse fields wired through all five packages; web reports
  injection as unsupported.
- Review fixes: Linux abs-positioning no longer no-ops (a single uinput device
  advertising both relative and absolute axes was classified as a mouse and
  ignored its ABS axes → split into a relative-mouse + absolute-pointer
  device); Linux partial-event-on-EAGAIN and cross-platform wheel over-scroll
  hardened; macOS relative-move bursts now accumulate against a shadow cursor
  instead of a stale async pointer read. Linux ABS device classification is
  the one item still pending real-compositor verification (see the plan doc).

## 0.6.0

- **Camera timestamps are now real microseconds on the shared monotonic
  epoch on all three platforms.** Windows/Media Foundation stored the 100 ns
  REFERENCE_TIME into `timestamp_us` unconverted (10× too large, wrong epoch);
  Linux/PipeWire stored the nanosecond graph-clock value (1000× too large);
  macOS/AVFoundation used the raw CMSampleBuffer PTS (session epoch, float
  math). All three now convert with integer math and rebase through the new
  shared `miniav_rebase_time_us()` (`common/miniav_time.h`) — first-sample
  anchored against `miniav_get_time_us()`, automatic re-anchor on device-clock
  discontinuities. The macOS ScreenCaptureKit screen path rebases its sample
  PTS the same way. Verified on hardware: c922 webcam median inter-frame delta
  32 ms at 30 fps.
- **Linux loopback audio no longer leaks (and no longer aliases freed
  memory).** Every delivered buffer now carries the standard audio release
  payload (`internal_handle`), and the PCM is copied out of PipeWire's ring
  buffer before the `pw_buffer` is requeued — previously the delivered pointer
  aliased memory PipeWire immediately reused (use-after-free for any async
  consumer) and no buffer was ever freeable.
- **`MiniAV_SetLogCallback` actually works now.** The registered callback was
  stored and never invoked — all native logs went to stderr only, i.e. nowhere
  in GUI apps. `miniav_log` now delivers to the callback when one is set
  (stderr as fallback). Contract note: the message is heap-allocated and owned
  by the receiver (release with `MiniAV_Free`) because receivers may dispatch
  asynchronously — the Dart FFI shim (`NativeCallable.listener`) does exactly
  that, and now decodes + frees accordingly.
- **Device-lost notifications (`lost_cb`) wired across the board.**
  Previously only DXGI screen, WASAPI loopback, and mic input fired it —
  everywhere else a hot-unplug/permission revoke was a silent permanent stall:
  - WGC screen: `GraphicsCaptureItem.Closed` handler + device-removed
    detection in the frame path (one-shot, unblocks the pacing wait).
  - macOS ScreenCaptureKit: `didStopWithError:` now flips `is_streaming` and
    fires `lost_cb` (it previously only logged).
  - Linux camera + Linux loopback: PipeWire stream error states fire
    `lost_cb` before teardown.
  - macOS camera: AVCaptureSession runtime-error + device-disconnected
    notification observers.
  - macOS loopback: `kAudioDevicePropertyDeviceIsAlive` listener on the
    tap/aggregate or virtual device.
- **macOS teardown races fixed.** Camera and screen stop/destroy paths now
  drain their delegate/sample dispatch queues (`dispatch_sync` barriers)
  before callbacks are cleared or the context is freed, and ScreenCaptureKit
  stop waits (bounded) for the stream's stop completion — previously in-flight
  frame callbacks could race context teardown (use-after-free class).
- **macOS ScreenCaptureKit `StartCapture` reports real failures.** The async
  setup chain is now awaited (bounded, 10 s → `MINIAV_ERROR_TIMEOUT`);
  permission/setup failures return an error instead of "success + zero frames
  forever".
- **Windows camera GPU path:** the shareable-copy texture is now owned by the
  frame payload and released in `release_buffer` (it leaked one texture per
  GPU frame — both on success and on share-failure paths); the device context
  is flushed before `CreateSharedHandle` (same producer-side race the screen
  path guards against); frame-payload cleanup now interprets the cpu/gpu
  union by the path actually taken (a GPU-preference frame that fell back to
  CPU was cleaned up as GPU — misreading CPU pointers as COM objects).
- **`MiniAV_ReleaseBuffer`** no longer leaks the payload wrapper on
  invalid-context/unknown-handle-type branches, and its logs no longer claim
  to free things they don't.
- **DXGI screen:** `GetConfiguredFormats` works again (`is_configured` was
  never set on this backend); removed the vestigial 4th parameter from
  `dxgi_configure_display` that mismatched the ops-table function-pointer
  type (formally undefined behavior).
- **`lost_cb` contract formalized** (`MiniAVContextLostCallback` docs): the
  callback runs on internal capture/notification threads — do not
  synchronously call StopCapture/DestroyContext from inside it (several
  backends join/drain the delivering thread; the Linux stop paths now also
  detect and refuse a self-join defensively). The Dart FFI shim satisfies the
  contract automatically via its asynchronous listener delivery.
- The whole pass was itself adversarially reviewed (25-agent diff review, 11
  confirmed findings, all fixed): the SCK async start chain now uses a
  generation/abandonment protocol so a timed-out start can never
  use-after-free a destroyed context (destroy waits for — or deliberately
  leaks rather than frees under — a still-pending chain); SCK destroy uses
  the same bounded stop as stop_capture; macOS dispatch_sync drains carry
  same-queue reentrancy guards; one-shot lost_cb guards are atomic on all
  platforms; the WGC `Closed` registration is revoked on stop (no stacking
  across stop/start cycles); the Linux loopback path acquires the dispatch
  guard before allocating (no per-quantum leak after `MiniAV_Dispose`);
  PipeWire's signed buffer time is validated before rebasing; MF's timebase
  also recalibrates on reconfigure.
- Added `miniav_c/NATIVE_AUDIT.md` — the full cross-platform audit (parity
  matrix, remaining P1/P2 findings, improvement roadmap).
- **Shutdown is now bounded on every platform.** The Linux PipeWire
  screen/camera/loopback stop paths use a new `miniav_timed_join()` (5 s)
  and return `MINIAV_ERROR_TIMEOUT` instead of hanging forever on a wedged
  compositor/PipeWire call; WASAPI's stop no longer waits `INFINITE` on the
  capture thread; the device watcher bounds its poll-thread join (a wedged
  platform `enumerate()` can no longer hang `MiniAV_Dispose`). Destroy paths
  retry the join and, if a thread genuinely will not exit, deliberately LEAK
  the platform context (loudly logged) rather than free memory a live thread
  still dereferences.
- **The callback-dispatch quiesce guard is real on Linux/macOS** — a
  `pthread_rwlock` mirror of the Windows SRWLOCK implementation. Previously
  the non-Windows stubs made `MiniAV_Dispose`'s
  "block until in-flight callbacks drain" guarantee (Flutter hot restart)
  a no-op.
- **Mic-input lifecycle hardening** (shared miniaudio module): a new
  `device_inited` flag decouples teardown from `is_running`, so
  Stop/Destroy after a device-lost notification actually uninitializes the
  device (previously silently leaked, device + worker thread);
  device-lost fires exactly once per run; DestroyContext force-uninits if
  Stop fails.
- **Format truth-telling:**
  - Windows camera: after committing a media type the reader's ACTUAL
    committed type is read back into the configured format (drivers may
    adjust), and frame-rate matching is rational (30000/1001 now matches an
    equivalent expression) instead of exact numerator+denominator equality.
  - Linux camera: the negotiated stream format is written back to the
    configured format (frames were stamped with the original request), and
    `GetSupportedFormats` no longer truncates the device's mode list to one
    entry — enumeration completes on the core sync-done event after ALL
    EnumFormat params have arrived.
  - macOS loopback: the tap/aggregate (and virtual-device AudioUnit) ACTUAL
    negotiated stream format is read back after start (frame counts were
    computed from the requested format, with an unguarded division);
    `GetDefaultFormat` queries the real target/default-output device instead
    of returning a hardcoded 44.1 kHz constant; `GetSupportedFormats` is
    implemented (was a NULL op that failed unconditionally).
  - Linux loopback: the negotiated audio format is persisted to the
    configured format; the format-query stubs now truthfully describe
    PipeWire's format-adaptive semantics instead of warning about a
    hardcoded device constraint.
  - Mic input: `GetDefaultFormat`/`GetSupportedFormats` query the actual
    device's native formats via miniaudio instead of returning hardcoded
    tables (the old code ran a dead enumeration loop purely to decorate a
    log line).
- **Input capture now exists on Linux and macOS** (was Windows-only). New raw
  evdev backend (`/dev/input/event*`, no libudev) and new CGEventTap +
  GameController backend deliver keyboard/mouse/gamepad events. The Windows
  input backend was hardened: shared monotonic clock, single-active-context
  guard (a second concurrent capture is rejected, not silently hijacked),
  absolute-QPC gamepad pacing (was a drifting `Sleep(1000/hz)`), and it no
  longer `TerminateThread`s the hook thread (which would have leaked a
  systemwide hook).
- **macOS camera GPU path honors planar formats** — NV12/I420 are now delivered
  as per-plane Metal textures instead of silently downgrading to CPU, and the
  buffer carries a signaled `MTLSharedEvent` in `native_fence`.
- **macOS system-audio loopback works on stock macOS 13+** — a ScreenCaptureKit
  audio tier is tried ahead of the third-party virtual-device requirement (no
  BlackHole needed).
- **macOS screen region capture** implemented via
  `SCStreamConfiguration.sourceRect` (was unsupported).
- **Clock conversions are overflow-safe** — QPC→µs and mach-time→µs use
  whole/remainder split arithmetic so they don't wrap on weeks-scale uptime.
- **Media Foundation camera** now escalates a persistently-failing read to
  device-lost (30 consecutive failures) instead of spinning the re-arm loop
  forever on a device-lost HRESULT outside the fixed terminal set.
- **GPU-sync poll no longer silently proceeds** — the pre-share
  `D3D11_QUERY_EVENT` wait on the DXGI/WGC zero-copy paths is bounded at 16 ms
  and logs (rate-limited) on timeout, surfacing a black-frame risk under GPU
  contention instead of hiding it.
- Deferred (documented in `NATIVE_AUDIT.md`, both peak improvements not
  defects): full `native_fence` handoff to the encoder consumer, transparent
  WASAPI default-device reroute, and Windows screen region-crop.
- Waves 5+6 were adversarially reviewed (17-agent diff review, 6 confirmed
  findings + several polish items, all fixed): the new Linux evdev backend
  coalesces per-axis mouse deltas into one throttled MOVE per report (a
  diagonal move was dropping its Y axis) and widens stick normalization to
  64-bit (32-bit overflow on LP32 arches); the macOS input backend no longer
  destructively clears keyboard/mouse from the configured set on a transient
  permission failure (a later restart re-attempts the tap), guards its worker
  run loop against a busy-spin, and clamps the gamepad poll rate; macOS
  SCK-audio stop now tears down an abandoned (timed-out) SCK chain and falls
  through to stop the virtual-device fallback instead of returning early;
  macOS region capture adopts the caller's frame rate and parses the
  `display_%u` id (was 0/0 fps and always the main display); the Windows input
  gamepad-creation-failure rollback routes through the never-`TerminateThread`
  stop path; and the misleading empty-command-buffer macOS camera fence was
  removed (the IOSurface path already serializes).
- Waves 3+4 were themselves adversarially reviewed (18-agent diff review, 7
  confirmed findings, all fixed): the leak-instead-of-free destroy protocol
  now returns `MINIAV_ERROR_TIMEOUT` and the `MiniAV_*_DestroyContext` API
  layers leak the PARENT context too (the wedged thread dereferences it —
  leaking only the platform half was still a use-after-free); normal
  `MiniAV_Audio_StopCapture` no longer fires a spurious
  `MINIAV_ERROR_DEVICE_LOST` (miniaudio posts its "stopped" notification
  during uninit — `is_running` now clears first); device formats with no
  MiniAV equivalent (e.g. s24) fall back to F32 instead of reporting
  format 0; the Linux camera negotiated-format write-back is mutex-guarded
  against torn reads from `GetConfiguredFormat`; the format-enumeration loop
  cannot hang when a node never reports info (initial core sync); the macOS
  loopback format read-backs happen BEFORE IO starts (realtime-thread
  publication order + render-buffer sizing) with the deprecated CoreAudio
  selector locally silenced; the GLib loop timeout path detaches coherently.

## 0.5.11

- Windows screen capture (WGC + DXGI): frame pacing rewritten against an
  **absolute QPC schedule** slept on a high-resolution waitable timer. The old
  relative sleeps (WGC's `Sleep(interval - 2)`, DXGI's GetTickCount64 +
  integer-ms `Sleep`) systematically over-delivered ~5% in
  timer-resolution-raised processes (any Flutter app): a 30 fps target
  delivered ~31.4 fps, and the recorder's fps throttle then deleted the
  surplus frame every ~20 frames — one double-length presentation hole every
  ~0.7 s, a metronomic, clearly visible stutter in recordings. In
  default-resolution processes the same sleeps tick-rounded the other way
  (~46.9 ms spacing ≈ 21 fps). Deliveries now land on the exact requested
  rational interval (measured mean 33.33 ms for a 30 fps target); after a
  stall or idle stretch the schedule resyncs instead of bursting stale
  catch-up frames, and the pacing wait watches the stop event so shutdown
  stays responsive mid-interval.

## 0.5.10

- DXGI screen capture: best-effort GPU scheduling boost at capture start so
  capture keeps its cadence when another process (e.g. a game) saturates the
  GPU — raises the process GPU scheduling priority to HIGH via
  `D3DKMTSetProcessSchedulingPriorityClass` (resolved dynamically from gdi32;
  covers every D3D device in the process, including minigpu's) and sets
  `IDXGIDevice::SetGPUThreadPriority(+7)` on the capture device. Failures are
  logged and capture proceeds at normal priority.

## 0.5.9

- override `releaseBufferSync()` to release synchronously (the underlying
  `MiniAV_ReleaseBuffer` C call is synchronous, so no `Future`/microtask is
  allocated); `releaseBuffer()` now delegates to it.
- DXGI screen capture (`screen_context_win_dxgi.c`): release the duplication
  frame immediately after the per-frame copy instead of holding it across the
  pacing `Sleep` until the next loop iteration. Desktop Duplication will not
  compose the next frame until `ReleaseFrame`, so the old ordering capped
  producer FPS and added a full frame of latency. Pacing is now driven by
  wall-clock elapsed since the last delivered frame (`max(0, interval - elapsed)`).

## 0.5.8

- fix audio buffer allocations and leak issue
## 0.5.7

- Fix logger noisiness
## 0.5.6

- fix FormatException on non-UTF-8 bytes in MiniAV log callback: use Utf8Decoder(allowMalformed: true) instead of toDartString()
- implement setLogCallback with NativeCallable.listener in miniav_ffi
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

- fixed windows screen cpu path

## 0.4.4

## 0.4.3

## 0.4.1

- fix issue with num frames not being reported for audio_inputs

## 1.0.0

- Initial version.
