# miniav_flutter

Flutter companion for [miniav](../miniav). Re-exports the full `miniav` API and adds a thin widget that automatically calls `MiniAV.dispose()` during Flutter hot reload — preventing the *"Callback invoked after it has been deleted"* fatal crash.

## Why this package exists

`miniav` uses long-lived `NativeCallable` function pointers for capture callbacks. During a Flutter hot reload the Dart isolate is torn down and rebuilt, but native capture threads keep running. If a thread fires a callback into a dead `NativeCallable` handle the VM aborts unconditionally — there is no way to recover.

`MiniAVBinding` is a `StatefulWidget` whose `reassemble()` calls `MiniAV.dispose()` before the isolate is rebuilt. This atomically disables the C-layer callback dispatch so native threads silently drop in-flight callbacks instead of crashing. The next call to any `startCapture` re-enables dispatch automatically.

## Installation

```yaml
dependencies:
  miniav_flutter: ^0.5.4
```

Use `miniav_flutter` **instead of** `miniav` — it re-exports everything, so no other imports need to change.

## Usage

Wrap your root widget with `MiniAVBinding` once in `main()`:

```dart
import 'package:miniav_flutter/miniav_flutter.dart';

void main() {
  runApp(const MiniAVBinding(child: MyApp()));
}
```

That is all that is required. All `MiniAV.*` APIs (`MiniCamera`, `MiniScreen`, `MiniAudioInput`, `MiniLoopback`, `MiniInput`, etc.) are available from the same `package:miniav_flutter/miniav_flutter.dart` import.

## Android screen capture (MediaProjection consent)

On Android, screen capture requires the user's MediaProjection consent and a
`mediaProjection`-typed foreground service (mandatory on Android 10+, strictly
ordered on Android 14+). This package handles the whole flow natively — the
system consent dialog, the foreground service (with notification), and the
handoff of the projection to miniAV's native layer:

```dart
import 'package:miniav_flutter/miniav_flutter.dart';

// 1. Ask for consent (shows the system dialog, starts the FGS, hands the
//    projection to native). Must complete before configuring screen capture.
final granted = await MiniAVAndroidScreenConsent.requestScreenCapture();
if (!granted) return; // user declined

// 2. Normal miniAV screen capture now works.
final displays = await MiniScreen.enumerateDisplays();
final ctx = await MiniScreen.createContext();
await ctx.configure(displays.first.deviceId, format);
await ctx.startCapture((buffer, _) => MiniAV.releaseBuffer(buffer));

// 3. The user can revoke at any time via the system status-bar chip:
final sub = MiniAVAndroidScreenConsent.onProjectionStopped.listen((_) {
  // capture has ended; the active context's lost callback also fires
});

// 4. When finished:
await MiniAVAndroidScreenConsent.stopScreenCapture();
```

Setup notes:

- The plugin's manifest entries (foreground-service permissions + the typed
  service declaration) merge into your app automatically — no manifest edits
  are needed for screen capture itself.
- Camera / microphone are separate: declare `CAMERA` / `RECORD_AUDIO` in your
  app manifest and request them at runtime (e.g. `permission_handler`) before
  configuring those contexts. miniAV never prompts — it fails with
  `MINIAV_ERROR_PERMISSION_DENIED` if consent is missing.
- Screen capture requires Android 8.0 (API 26)+; requesting on older devices
  reports not-supported.
- A foreground notification is shown while capture runs (an Android
  requirement). It uses your app's launcher icon.

iOS needs no plugin piece: in-app ReplayKit capture shows its own system
consent when started, and the system-wide broadcast tier is configured at the
native layer (see the main README's iOS Permissions section and
`miniav_c/src/screen/ios/broadcast_extension/SETUP.md`).

### Pure-Dart projects

If you are **not** using Flutter (e.g. a CLI tool or a Dart-only test), import `package:miniav/miniav.dart` directly and call `MiniAV.dispose()` manually when tearing down.

## API surface

Everything exported by `package:miniav/miniav.dart`, plus:

| Symbol | Description |
|--------|-------------|
| `MiniAVBinding` | Root widget — call `reassemble()` hook wires up `MiniAV.dispose()` |
| `MiniAVAndroidScreenConsent` | Android MediaProjection consent flow: `requestScreenCapture()`, `stopScreenCapture()`, `onProjectionStopped` |
