# miniAV — System-wide iOS Screen Capture (Broadcast Upload Extension) Setup

This guide sets up **system-wide** iOS screen capture — capturing the *whole
device screen*, not just your app — via a **Broadcast Upload Extension**.

Apple runs the extension in a **separate process** it starts on the user's
behalf, so miniAV cannot ship it inside the framework: **you must create the
extension target in your own app** and compile the miniAV producer library into
it. This walkthrough does exactly that.

> If you only need to capture *your own app's* screen, you do **not** need any of
> this — use the in-app tier (`"app_screen"` display) instead. The broadcast
> tier below is only for capturing the entire system.

Architecture recap (see `MOBILE_PLATFORM_SPEC.md` §B.3b and
`../miniav_broadcast_protocol.h`): the extension (**producer**) copies each NV12
frame into a shared-memory ring in an **App Group container** and posts a tiny
descriptor over a unix-domain socket; your host app (**consumer**, inside
`screen_context_ios_replaykit.mm`) wraps the ring pages zero-copy. One CPU copy,
in the extension, is unavoidable on iOS — this design makes it the *only* copy.

---

## 0. What you'll end up with

- Your existing **host app** target (the consumer; already links miniAV).
- A new **Broadcast Upload Extension** target (the producer).
- An **App Group** capability on **both** targets, sharing the same id
  (e.g. `group.com.example.miniav`).
- Three miniAV files compiled into the extension target:
  `miniav_broadcast_sender.h`, `miniav_broadcast_sender.m`,
  `miniav_broadcast_protocol.h`.
- A reference `SampleHandler.swift` and a one-line **bridging header**.

---

## 1. Create the Broadcast Upload Extension target

1. In Xcode: **File ▸ New ▸ Target… ▸ Broadcast Upload Extension**.
2. Name it (e.g. `MiniAVBroadcast`). When asked, **do NOT** include a
   "Broadcast Setup UI" extension (not needed).
3. Set its **iOS Deployment Target to 13.0** (or your app's floor; ≥ 13.0).
4. Xcode generates a `SampleHandler.swift` in the new target — you'll replace
   its contents in step 4.

The extension is embedded in your app bundle automatically. Only **one**
extension per app is needed; it captures the entire system screen once started.

---

## 2. Add the App Group capability to BOTH targets

The ring file and socket live in the App Group container shared by the host app
and the extension. Both targets must be in the **same** App Group.

1. Select the **host app** target ▸ **Signing & Capabilities** ▸ **+ Capability**
   ▸ **App Groups**. Add a group, e.g. `group.com.example.miniav`.
2. Select the **extension** target ▸ **Signing & Capabilities** ▸ **+ Capability**
   ▸ **App Groups**. Add the **same** group id.
3. Both must be under the **same Apple Developer Team** (App Groups are
   team-scoped — see "Deployment model" below).

> The group id string is used verbatim in three places: the host app's
> `MiniAV_Screen_SetIOSAppGroup(...)` call, the extension's
> `APP_GROUP_ID` constant in `SampleHandler.swift`, and both entitlements. They
> must match exactly.

---

## 3. Compile the miniAV producer into the extension target

1. Add these files to the **extension** target's **Compile Sources** /
   header search path (drag them in, tick **only** the extension target):
   - `src/screen/ios/miniav_broadcast_sender.m`
   - `src/screen/ios/miniav_broadcast_sender.h`
   - `src/screen/ios/miniav_broadcast_protocol.h`
2. Ensure the extension target's **Header Search Paths** can find the protocol
   header (add `src/screen/ios` if needed).
3. The producer is **MRC** (manual reference counting). The extension target's
   Swift/ObjC mix is fine, but if you set a target-wide
   `CLANG_ENABLE_OBJC_ARC = YES`, add a per-file flag `-fno-objc-arc` on
   `miniav_broadcast_sender.m` (Build Phases ▸ Compile Sources ▸ that file ▸
   Compiler Flags). The library is written to build cleanly either way, but it
   is designed for **`-fno-objc-arc`** and never relies on ARC.
4. Frameworks the extension already links (no action usually needed):
   `ReplayKit`, `CoreVideo`, `CoreMedia`, `Foundation`. The producer uses only
   CoreVideo + POSIX + `os_log` + Foundation (for the App Group container path).

### Optional: silence producer logging

The producer logs via `os_log`. To strip all of it (size/noise-sensitive
builds), add `MBS_LOG_SILENT` to the extension target's **Preprocessor Macros**.

---

## 4. Bridging header + reference SampleHandler

The extension is a mixed Swift/ObjC target, so Swift needs a **bridging header**
to see the C API.

1. Create `MiniAVBroadcast-Bridging-Header.h` in the extension target with:

   ```objc
   #import "miniav_broadcast_sender.h"
   ```

2. Set the extension target's Build Setting **Objective-C Bridging Header** to
   that file's path, e.g.
   `$(SRCROOT)/MiniAVBroadcast/MiniAVBroadcast-Bridging-Header.h`.

3. Replace the generated `SampleHandler.swift` contents with the reference in
   `src/screen/ios/broadcast_extension/SampleHandler.swift`. **Edit its
   `APP_GROUP_ID`** to your group id from step 2.

The reference handler:
- opens the ring **lazily on the first video buffer** (dimensions come from it),
- copies each NV12 `CVPixelBuffer` into the ring (`mbs_send_video`),
- forwards app audio as interleaved PCM (`mbs_send_audio`),
- closes on `broadcastFinished` (`mbs_close`).

---

## 5. Host app: select the broadcast display

In your host app (which already links miniAV), before configuring capture:

```c
// Point miniAV at the SAME App Group id the extension uses.
MiniAV_Screen_SetIOSAppGroup("group.com.example.miniav");
```

Then enumerate displays and configure the **broadcast** pseudo-display.
`MiniAV_Screen_EnumerateDisplays` returns two pseudo-displays on iOS:

| id | tier |
|---|---|
| `app_screen` | in-app capture (this app only, no extension needed) |
| `system_screen_broadcast` | **system-wide** via the extension (this guide) |

Configure `system_screen_broadcast`, then start capture. Frames arrive as CPU
NV12 buffers over the ring (GPU handles cannot cross the iOS process boundary).

---

## 6. Starting the broadcast (the user's action)

A broadcast is **started by the user**, one of two ways:

- **Control Center:** long-press the Screen Recording button → pick your
  extension → **Start Broadcast**. (Add the Screen Recording control to Control
  Center in Settings if it isn't there.)
- **In-app picker:** present an `RPSystemBroadcastPickerView` (UIKit, main
  thread). Set its `preferredExtension` to your extension's bundle id to
  pre-select it. The host side can auto-present this on `StartCapture`.

Capture begins when the user confirms the picker. Your host app's
`StartCapture` returns immediately; frames begin once the extension connects to
the socket and publishes the first slot. The host applies a no-connection
timeout (fires `lost_cb` with timeout semantics if nothing connects).

---

## 7. Deployment model (multi-app)

- The extension is embedded in **one** host app per developer, but once started
  it captures the **entire system screen**, regardless of which app is
  foregrounded (the host need not be foregrounded to *start* it, either).
- **Any same-team app sharing the App Group can be the ring consumer** — one
  extension serves a developer's whole portfolio.
- **Cross-developer sharing is impossible:** App Groups are team-scoped. Third
  parties embed their own extension from this template.

---

## 8. Caveats & honest limits

- **Memory ceiling (~50 MB):** the extension process is tightly bounded. The
  producer keeps exactly one heap allocation plus the ring mmap (4 NV12 slots
  ≈ 12.7 MB @ 1080p) and does **no** per-frame allocation. Don't add heavy
  processing in the extension.
- **Host-app suspension:** a backgrounded host **without a background mode** is
  suspended and stops draining the ring. The extension keeps capturing and
  **drops the oldest un-leased frames harmlessly** (counted, no crash). For
  continuous capture while backgrounded, give the host a background mode
  (background audio is the common one).
- **CPU frames only:** the broadcast tier delivers CPU NV12 buffers — GPU
  texture handles cannot cross the iOS app↔extension boundary. (The host still
  wraps the ring pages zero-copy on its side.)
- **User controls the broadcast:** the user can stop it from the status bar /
  Control Center at any time; that's a normal end-of-capture (`lost_cb`).
- **App Store review** requires a justification for shipping a broadcast
  extension — be ready to explain the system-capture use case.
- **v1 pins NV12 at fixed geometry:** the ring is sized to the first frame's
  dimensions. If ReplayKit ever hands a non-NV12 or differently-sized buffer,
  the producer drops it (logged once). ReplayKit delivers
  `420YpCbCr8BiPlanar` (NV12) in practice.

---

## 9. Troubleshooting

- **`mbs_open` returns nil (extension log "App Group container not found"):**
  the App Group capability is missing/misspelled on the **extension** target,
  or the id doesn't match. Recheck step 2.
- **Host never receives frames:** confirm the host called
  `MiniAV_Screen_SetIOSAppGroup` with the *exact* same id, and that the user
  actually started the broadcast (picker confirmed).
- **Producer builds but link errors on ARC:** add `-fno-objc-arc` to
  `miniav_broadcast_sender.m` (step 3.3).
- **Nothing in Control Center:** add the **Screen Recording** control in
  *Settings ▸ Control Center*, then long-press it to see your extension.
