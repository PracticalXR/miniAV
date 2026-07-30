# miniav

A Flutter library for cross-platform audio, video, and input capture with high-performance buffer management and GPU integration support.

Try it out at [miniav.practicalxr.com](https://miniav.practicalxr.com)!

## Three Things to Know

1. Native assets compilation can take time, especially on first build. Run with -v to see build progress and errors.

2. This package uses dart native assets.
For flutter, you must be on the master channel and run
`flutter config --enable-native-assets`
For dart, each run must contain the
`--enable-experiment=native-assets` flag.

3. Platform-specific permissions are required for camera, microphone, and screen capture. See the Permissions section below for detailed setup instructions.

### Platform Support

| Module | Windows | Linux | macOS | Web | Android | iOS |
|--------|---------|-------|-------|-----|---------|-----|
| **Camera** | ✅ | ✅ | ✅ | ✅ | ✅* 24+ | ✅* 13+ |
| **Screen Capture** | ✅ | ✅ | ✅ | ✅ | ✅* 26+ | ✅* 13+ |
| **Audio Input** | ✅ | ✅ | ✅ | ✅ | ✅* | ✅* |
| **Audio Loopback** | ✅ | ✅ | ✅ 15+ | ❌ | 🚧 | ❌ |
| **Input Capture** | ✅ | ✅* | ✅* | 🚧 | ❌ | ❌ |

**Legend:** ✅ Supported • ✅\* New in 0.7.0 — implemented and adversarially reviewed; on-device verification still in progress • ❌ Not Available • 🚧 Planned

Mobile notes: Android screen capture requires API 26+ (camera works from 24); iOS
supports **both** in-app capture and system-wide capture via a Broadcast Upload
Extension (see the iOS Permissions section). Android loopback (AudioPlaybackCapture)
is planned on top of the same MediaProjection consent flow. Mobile input capture is
deliberately out of scope (no OS-sanctioned global hooks on mobile).

### (Maybe) Planned Features

- **Android loopback**: system-audio capture via AudioPlaybackCapture (API 29+), reusing the MediaProjection consent flow
- **GPU Interop**: Helpers to easily manage handles and shared fences for GPU processing
- **Permission Management**: Simplified APIs for handling platform-specific permissions
- **macOS/Linux context-lost wiring**: Per-context device-loss callbacks for non-Windows platforms (currently handled via the polling watcher)

### Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  miniav: ^0.5.0
```

Then run:

```shell
dart pub get
```

### Flutter apps: use `miniav_flutter` instead

If you are building a Flutter app, add `miniav_flutter` rather than `miniav` directly.  It re-exports the full `miniav` API and adds a thin widget that automatically calls `MiniAV.dispose()` during hot reload — preventing the *"Callback invoked after it has been deleted"* crash that occurs when native capture threads hold live callbacks while the Dart isolate is rebuilt.

```yaml
dependencies:
  miniav_flutter: ^0.5.0
```

Wrap your root widget with `MiniAVBinding` once in `main()`:

```dart
import 'package:miniav_flutter/miniav_flutter.dart';

void main() {
  runApp(const MiniAVBinding(child: MyApp()));
}
```

No other changes are needed — all `MiniAV.*` APIs are available from the same import.

## Getting Started

```console
 git clone https://github.com/practicalxr/miniav.git
 cd miniav_ffi
 dart --enable-experiment=native-assets test

 dart:
 cd miniav
 dart --enable-experiment=native-assets example/miniav_example.dart

 flutter:
 cd miniav/example/flutter_example
 flutter config --enable-native-assets
 flutter run -d chrome/windows/linux

 flutter mobile:
 flutter run -d <android-device>/<ios-device>
```

Mobile builds compile the native library through the same native-assets hook:
Android needs the Android SDK + NDK, CMake, and Ninja (all installable via
Android Studio's SDK Manager); iOS needs Xcode + CMake and builds for
deployment target 13.0+. First mobile builds are slow — the whole C library is
compiled per-ABI.

## Example

```dart
import 'package:miniav/miniav.dart';

Future<void> captureCamera() async {
  // Initialize MiniAV
  MiniAV.setLogLevel(MiniAVLogLevel.info);
  
  // Enumerate camera devices
  final cameras = await MiniCamera.enumerateDevices();
  if (cameras.isEmpty) {
    print('No cameras found');
    return;
  }
  
  // Use first camera
  final selectedCamera = cameras.first;
  final format = await MiniCamera.getDefaultFormat(selectedCamera.deviceId);
  
  print('Using camera: ${selectedCamera.name}');
  print('Format: ${format.width}x${format.height} @ ${format.frameRateNumerator}/${format.frameRateDenominator} FPS');
  
  // Create and configure context
  final context = await MiniCamera.createContext();
  await context.configure(selectedCamera.deviceId, format);
  
  // Start capture with callback
  int frameCount = 0;
  await context.startCapture((buffer, userData) {
    frameCount++;
    print('Camera frame #$frameCount - ${buffer.dataSizeBytes} bytes');
    
    // Process video data here
    if (buffer.type == MiniAVBufferType.video) {
      final videoBuffer = buffer.data as MiniAVVideoBuffer;
      final rawData = videoBuffer.planes[0];
      // Use raw pixel data for computer vision, GPU upload, etc.
    }
    
    // IMPORTANT: Release buffer when done
    MiniAV.releaseBuffer(buffer);
  });
  
  // Capture for 10 seconds
  await Future.delayed(Duration(seconds: 10));
  
  // Stop and cleanup
  await context.stopCapture();
  await context.destroy();
  MiniAV.dispose();
}
```

## Features

### Multi-Stream Capture

MiniAV supports simultaneous capture from multiple sources:

- **Camera**: Access webcams and external cameras
- **Screen**: Capture displays and windows with optional audio
- **Audio Input**: Record from microphones and audio devices  
- **Loopback Audio**: Capture system audio output (platform dependent)
- **Input Capture**: Keyboard, mouse, and gamepad events with configurable throttling

### Device Change Subscriptions

Subscribe to device add/remove events without polling. Each subscription returns a disposer function — call it to unsubscribe.

```dart
// Camera devices
final cancel = MiniCamera.addDeviceChangeListener((notification) {
  print('Camera ${notification.event.name}: ${notification.device.name}');
});

// Microphone devices
final cancel = MiniAudioInput.addDeviceChangeListener((notification) {
  print('Mic ${notification.event.name}: ${notification.device.name}');
});

// Loopback (audio output) targets
final cancel = MiniLoopback.addDeviceChangeListener((notification) {
  print('Loopback target ${notification.event.name}: ${notification.device.name}');
});

// Display monitors
final cancel = MiniScreen.addDisplayChangeListener((notification) {
  print('Display ${notification.event.name}: ${notification.device.name}');
});

// Windows (visible windows list)
final cancel = MiniScreen.addWindowChangeListener((notification) {
  print('Window ${notification.event.name}: ${notification.device.name}');
});

// Gamepads
final cancel = MiniInput.addGamepadChangeListener((notification) {
  print('Gamepad ${notification.event.name}: ${notification.device.name}');
});

// notification.event is a MiniAVDeviceChangeEvent:
//   .added, .removed, .defaultChanged
```

Multiple listeners on the same module are independent; disposing one does not affect others.

### Context-Lost Notifications

For contexts that are actively capturing, you can subscribe to a notification when the underlying device becomes unavailable (e.g. a webcam is unplugged, an audio endpoint is removed, or a captured window is closed).

```dart
final context = await MiniCamera.createContext();
await context.configure(deviceId, format);

final cancelLost = context.addLostListener((reason) {
  // Fired from the capture thread — schedule UI work on the main isolate
  print('Device lost (code $reason), stopping capture...');
});

await context.startCapture((buffer, _) {
  MiniAV.releaseBuffer(buffer);
});

// ...later
cancelLost(); // unsubscribe
await context.stopCapture();
await context.destroy();
```

`addLostListener` is available on `MiniCameraContext`, `MiniAudioInputContext`, `MiniLoopbackContext`, and `MiniScreenContext`.

> **Important**: The lost callback is fired from a native capture thread. Do **not** call `context.destroy()` synchronously inside the callback — schedule it on the main isolate instead.

### High-Performance Buffers

- **Zero-Copy Design**: Direct access to native buffers where possible
- **GPU Integration**: Ready for use with compute shaders and WebGPU
- **Explicit Release**: Manual buffer management prevents resource leaks
- **Multiple Formats**: Support for RGB, YUV, and compressed formats

### Cross-Platform APIs

```dart
// Camera capture
final cameras = await MiniCamera.enumerateDevices();
final context = await MiniCamera.createContext();
final cancelCamera = MiniCamera.addDeviceChangeListener((n) { /* ... */ });

// Screen capture with audio
final displays = await MiniScreen.enumerateDisplays();
final screenContext = await MiniScreen.createContext();
final cancelDisplay = MiniScreen.addDisplayChangeListener((n) { /* ... */ });
final cancelWindow = MiniScreen.addWindowChangeListener((n) { /* ... */ });

// Audio input
final audioDevices = await MiniAudioInput.enumerateDevices();
final audioContext = await MiniAudioInput.createContext();
final cancelAudio = MiniAudioInput.addDeviceChangeListener((n) { /* ... */ });

// System audio loopback (where supported)
final loopbackDevices = await MiniLoopback.enumerateDevices();
final loopbackContext = await MiniLoopback.createContext();
final cancelLoopback = MiniLoopback.addDeviceChangeListener((n) { /* ... */ });

// Input capture (keyboard, mouse, gamepad)
final gamepads = await MiniInput.enumerateGamepads();
final inputContext = await MiniInput.createContext();
final cancelGamepad = MiniInput.addGamepadChangeListener((n) { /* ... */ });
```

## Input Capture

MiniAV includes a unified input capture module for keyboard, mouse, and gamepad events.

### Basic Input Capture

```dart
import 'package:miniav/miniav.dart';

Future<void> captureInput() async {
  // Create and configure an input context
  final context = await MiniInput.createContext();
  await context.configure(MiniAVInputConfig(
    inputTypes: MiniAVInputType.keyboard.value |
        MiniAVInputType.mouse.value |
        MiniAVInputType.gamepad.value,
    mouseThrottleHz: 120, // Limit mouse events to 120 Hz
    gamepadPollHz: 60,    // Poll gamepads at 60 Hz
  ));

  // Start capture with per-type callbacks
  await context.startCapture(
    onKeyboard: (event, userData) {
      final action = event.action == MiniAVKeyAction.down ? 'DOWN' : 'UP';
      print('Key $action: keyCode=${event.keyCode} scanCode=${event.scanCode}');
    },
    onMouse: (event, userData) {
      print('Mouse ${event.action.name}: (${event.x}, ${event.y})');
    },
    onGamepad: (event, userData) {
      print('Gamepad ${event.gamepadIndex}: '
          'buttons=0x${event.buttons.toRadixString(16)} '
          'LStick=(${event.leftStickX}, ${event.leftStickY}) '
          'triggers=(${event.leftTrigger}, ${event.rightTrigger})');
    },
  );

  // Capture for 10 seconds
  await Future.delayed(Duration(seconds: 10));

  // Cleanup
  await context.stopCapture();
  await context.destroy();
}
```

### Gamepad Enumeration

```dart
final gamepads = await MiniInput.enumerateGamepads();
for (final pad in gamepads) {
  print('Gamepad: ${pad.name} (${pad.deviceId})');
}
```

### Input Types

Input types are configured as a bitmask, so you can capture any combination:

```dart
// Keyboard only
MiniAVInputConfig(inputTypes: MiniAVInputType.keyboard.value);

// Mouse + gamepad
MiniAVInputConfig(
  inputTypes: MiniAVInputType.mouse.value | MiniAVInputType.gamepad.value,
);
```

## Permissions

**miniAV never shows permission prompts itself.** Your app is responsible for
requesting OS permissions *before* configuring a capture context — if a
permission is missing, configuration/start fails with
`MiniAVResultCode.errorPermissionDenied` and a log explaining what to request.

### macOS

Add to `macos/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera for video capture</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone for audio recording</string>
```

For screen recording, manually enable in System Settings > Privacy & Security > Screen Recording.

For input capture (CGEventTap keyboard/mouse), the app additionally needs
**Accessibility** and (macOS 10.15+) **Input Monitoring** approval under
System Settings > Privacy & Security. Gamepads (GameController framework) need
no permission.

### Windows

Camera and microphone access controlled via Windows 10+ Privacy Settings. Screen capture generally requires no special permissions for desktop applications. Input capture (keyboard/mouse hooks, XInput gamepads) works without additional permissions.

### Linux

User must be in `video` and `audio` groups (and `input` for input capture,
which reads `/dev/input/event*`):

```bash
sudo usermod -a -G audio,video,input $USER
```

Install required development packages:

```bash
# Ubuntu/Debian
sudo apt install libasound2-dev libpulse-dev libpipewire-0.3-dev libglib2.0-dev libv4l-dev

# Fedora
sudo dnf install alsa-lib-devel pulseaudio-libs-devel pipewire-devel glib2-devel libv4l-devel
```

(`libglib2.0-dev`/`glib2-devel` provides `gio-unix-2.0`, used by the screen-capture portal path.)

### Android

Declare what you use in your app's `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Request them at runtime (e.g. with the `permission_handler` package) **before**
configuring a camera or audio context — miniAV does not prompt.

**Screen capture** (API 26+) requires the user's MediaProjection consent and a
`mediaProjection`-typed foreground service. With `miniav_flutter` this is one
call — the plugin shows the system consent dialog, starts the required
foreground service (its manifest entries merge into your app automatically),
and hands the projection to the native layer:

```dart
import 'package:miniav_flutter/miniav_flutter.dart';

final granted = await MiniAVAndroidScreenConsent.requestScreenCapture();
if (granted) {
  // Now MiniScreen.createContext() / configure / startCapture work.
}

// The user can revoke via the system status-bar chip at any time:
MiniAVAndroidScreenConsent.onProjectionStopped.listen((_) {
  // stop your capture UI; the active context also fires its lost callback
});

// When you are done:
await MiniAVAndroidScreenConsent.stopScreenCapture();
```

Non-Flutter embedders pass a consented `MediaProjection` global ref through
the C seam `MiniAV_Screen_SetAndroidMediaProjection(JavaVM*, jobject)` before
configuring the display (see `include/miniav_capture.h`).

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera for video capture</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone for audio recording</string>
```

The app must obtain AVFoundation authorization (e.g. via `permission_handler`)
before configuring camera/mic — a not-yet-requested permission also reports
`errorPermissionDenied`. Camera frames are delivered in sensor-native
orientation in v1 (rotate downstream if needed).

**Screen capture** exposes two pseudo-displays from `MiniScreen.enumerateDisplays()`:

- `app_screen` — in-app capture (ReplayKit). iOS shows its own consent dialog
  when capture starts; no plist key needed.
- `system_screen_broadcast` — system-wide capture via a **Broadcast Upload
  Extension** you add to your app (started by the user from Control Center).
  Requires an App Group shared between your app and the extension. The full
  Xcode walkthrough — extension target, App Group, compiling the provided
  `miniav_broadcast_sender` + `SampleHandler.swift` — lives at
  `miniav_ffi/miniav_c/src/screen/ios/broadcast_extension/SETUP.md`.
  The host app registers its App Group before configuring this display:

  ```dart
  await MiniScreen.setIOSAppGroup('group.com.example.yourapp');
  // then configure + start the 'system_screen_broadcast' display
  ```

### Web

Requires HTTPS for camera, microphone, and screen capture APIs. All capture requires user gesture and permission.

## Architecture

MiniAV follows a modular architecture:

- **miniav_platform_interface**: Abstract interface definitions
- **miniav_ffi**: Native implementation using FFI and C library
- **miniav_web**: Web implementation using browser APIs
- **miniav_c**: Core C library with platform-specific backends

### Buffer Management

MiniAV uses explicit buffer release for optimal performance:

```dart
await context.startCapture((buffer, userData) {
  // Process buffer data
  final videoData = buffer.data as MiniAVVideoBuffer;
  
  // Access raw pixel planes
  final plane0 = videoData.planes[0]; // Y plane for YUV, or RGB data
  final plane1 = videoData.planes[1]; // U plane for YUV
  final plane2 = videoData.planes[2]; // V plane for YUV
  
  // CRITICAL: Always release when done
  MiniAV.releaseBuffer(buffer);
});
```

### GPU Integration

Buffers can contain GPU handles for zero-copy workflows:

```dart
if (buffer.contentType == MiniAVBufferContentType.gpuD3D11Handle) {
  // Direct GPU texture handle (Windows)
  final gpuHandle = videoData.planes[0];
  // Pass to minigpu or other GPU library
}
```

## GPU Interop with minigpu

MiniAV is designed to feed directly into [minigpu](https://pub.dev/packages/minigpu) for zero-copy GPU processing — camera frames and screen captures can be imported as GPU textures and processed with custom WGSL compute shaders.

### Buffer contract

Every `MiniAVVideoBuffer` delivered in a capture callback carries the fields that minigpu's `importVideoFrame` needs:

| Field | Role |
|-------|------|
| `contentType` | `cpu` = copy into GPU texture; `gpuD3D11Handle` = zero-copy shared texture (Windows) |
| `pixelFormat` | `rgba32` or `nv12` are supported by minigpu on all platforms |
| `width` / `height` | Frame dimensions in pixels |
| `planes[n]` | Raw `Uint8List` pixel data (CPU path) — one plane for RGBA, two for NV12 |
| `strideBytes[n]` | Row stride in bytes per plane |
| `nativeHandles[n]` | Platform GPU handle (D3D11 texture pointer, DMA-BUF fd, etc.) for GPU path |
| `nativeFence` | Sync fence for GPU-path handoff (D3D11 fence, sync_fd, or Metal shared event) |

### Camera → GPU texture → RGBA readback (CPU path)

```dart
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:miniav/miniav.dart';
import 'package:minigpu/minigpu.dart';

Future<void> cameraToGpu() async {
  final gpu = Minigpu();
  await gpu.init();

  MiniAV.setLogLevel(MiniAVLogLevel.warn);
  final devices = await MiniCamera.enumerateDevices();
  if (devices.isEmpty) return;

  final fmt = await MiniCamera.getDefaultFormat(devices.first.deviceId);
  final ctx = await MiniCamera.createContext();
  await ctx.configure(devices.first.deviceId, fmt);

  await ctx.startCapture((buffer, _) async {
    if (buffer.type != MiniAVBufferType.video) {
      MiniAV.releaseBuffer(buffer);
      return;
    }
    final vb = buffer.data as MiniAVVideoBuffer;

    // Copy the CPU plane onto the native heap for the duration of the GPU import.
    final plane = vb.planes[0]!;
    final ptr = malloc<Uint8>(plane.length);
    ptr.asTypedList(plane.length).setAll(0, plane);

    final tex = gpu.importVideoFrame(ExternalVideoBuffer(
      contentType: ExternalContentType.cpu,
      pixelFormat: ExternalPixelFormat.rgba32, // match fmt.pixelFormat
      width: vb.width,
      height: vb.height,
      planes: [
        ExternalPlane(
          dataPtr: ptr.address,
          width: vb.width,
          height: vb.height,
          strideBytes: vb.strideBytes[0],
        ),
      ],
    ));

    if (tex != null) {
      final out = tex.toRGBA();
      // ... dispatch a compute shader or read back ...
      out.destroy();
      tex.destroy();
    }

    malloc.free(ptr);
    MiniAV.releaseBuffer(buffer);
  });

  await Future.delayed(const Duration(seconds: 5));
  await ctx.stopCapture();
  await ctx.destroy();
}
```

### Camera → custom compute shader (colour inversion example)

```dart
const kInvertShader = '''
@group(0) @binding(0) var in_tex : texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> out_buf : array<u32>;
struct Params { width: u32, height: u32 }
@group(0) @binding(2) var<storage, read_write> params : Params;
@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x >= params.width || gid.y >= params.height) { return; }
  let px = textureLoad(in_tex, vec2<u32>(gid.x, gid.y), 0);
  let r = u32((1.0 - px.r) * 255.0);
  let g = u32((1.0 - px.g) * 255.0);
  let b = u32((1.0 - px.b) * 255.0);
  out_buf[gid.y * params.width + gid.x] =
      r | (g << 8u) | (b << 16u) | (255u << 24u);
}
''';

// In capture callback (after building tex as above):
final W = vb.width, H = vb.height;
final outBuf    = gpu.createBuffer(W * H * 4, BufferDataType.uint8);
final paramsBuf = gpu.createBuffer(8, BufferDataType.uint32);
await paramsBuf.write(Uint32List.fromList([W, H]), 2, dataType: BufferDataType.uint32);

final cs = gpu.createComputeShader();
cs.loadKernelString(kInvertShader);
tex.setOnShader(cs, 0);         // imported texture → binding 0
cs.setBufferAtSlot(1, outBuf);  // output  → binding 1
cs.setBufferAtSlot(2, paramsBuf); // params → binding 2
await cs.dispatch((W + 7) ~/ 8, (H + 7) ~/ 8, 1);

final result = Uint8List(W * H * 4);
await outBuf.read(result, W * H * 4, dataType: BufferDataType.uint8);

cs.destroy();  outBuf.destroy();  paramsBuf.destroy();
tex.destroy(); malloc.free(ptr);
```

### NV12 camera frame → GPU BT.709 conversion

Request NV12 output from the camera for more efficient GPU upload, then let minigpu's built-in `toRGBA()` apply BT.709 full-range conversion:

```dart
// Configure for NV12 output
final fmt = MiniAVVideoInfo(
  width: 1280, height: 720,
  pixelFormat: MiniAVPixelFormat.nv12,
  frameRateNumerator: 30, frameRateDenominator: 1,
  outputPreference: MiniAVOutputPreference.cpu,
);
await ctx.configure(deviceId, fmt);

// In the capture callback:
final yPlane  = vb.planes[0]!;  // width × height bytes
final uvPlane = vb.planes[1]!;  // width × (height/2) bytes

final yPtr  = malloc<Uint8>(yPlane.length)..asTypedList(yPlane.length).setAll(0, yPlane);
final uvPtr = malloc<Uint8>(uvPlane.length)..asTypedList(uvPlane.length).setAll(0, uvPlane);

final tex = gpu.importVideoFrame(ExternalVideoBuffer(
  contentType: ExternalContentType.cpu,
  pixelFormat: ExternalPixelFormat.nv12,
  width: vb.width, height: vb.height,
  planes: [
    ExternalPlane(dataPtr: yPtr.address,  width: vb.width,      height: vb.height,      strideBytes: vb.strideBytes[0]),
    ExternalPlane(dataPtr: uvPtr.address, width: vb.width ~/ 2, height: vb.height ~/ 2, strideBytes: vb.strideBytes[1]),
  ],
));

final rgba = tex!.toRGBA(); // BT.709 NV12 → RGBA on GPU
// ... use rgba buffer ...
rgba.destroy(); tex.destroy();
malloc.free(yPtr); malloc.free(uvPtr);
```

## Advanced Usage

### Multiple Stream Synchronization

```dart
// Start multiple streams
await cameraContext.startCapture(onCameraFrame);
await audioContext.startCapture(onAudioFrame);

void synchronizeStreams(MiniAVBuffer cameraBuffer, MiniAVBuffer audioBuffer) {
  final timeDiff = cameraBuffer.timestampUs - audioBuffer.timestampUs;
  if (timeDiff.abs() < 16667) { // Within ~16ms for 60fps
    // Process synchronized frame
  }
}
```

### Custom Format Selection

```dart
final formats = await MiniCamera.getSupportedFormats(deviceId);
final preferredFormat = formats.firstWhere(
  (f) => f.width >= 1920 && f.pixelFormat == MiniAVPixelFormat.nv12,
  orElse: () => formats.first,
);
await context.configure(deviceId, preferredFormat);
```

### Error Handling

Failed operations throw an `Exception` whose message ends with the native
result-code name (e.g. `MINIAV_ERROR_NOT_SUPPORTED`,
`MINIAV_ERROR_PERMISSION_DENIED`, `MINIAV_ERROR_DEVICE_BUSY`):

```dart
try {
  await context.configure(deviceId, format);
  await context.startCapture(callback);
} on Exception catch (e) {
  final msg = e.toString();
  if (msg.contains('MINIAV_ERROR_PERMISSION_DENIED')) {
    // The app has not obtained the OS permission / consent flow for this
    // capture type — see the Permissions section, then retry.
  } else if (msg.contains('MINIAV_ERROR_NOT_SUPPORTED')) {
    // This module/tier is unavailable on the current platform.
  } else {
    print('Capture error: $e');
  }
}
```

Prefer requesting permissions up front (see Permissions) so these paths are
exceptional rather than routine.

## Performance Tips

1. **Release Buffers Promptly**: Delayed release can cause frame drops
2. **Use Appropriate Formats**: Choose formats matching your processing needs  
3. **Minimize Copies**: Prefer direct buffer access over copying data
4. **GPU Preference**: Set `outputPreference: gpu` for zero-copy workflows
5. **Background Processing**: Move heavy processing off the capture callback thread

## Dependencies

### Native Dependencies

- **Windows**: Media Foundation, DirectX 11, WASAPI, XInput
- **macOS**: AVFoundation, ScreenCaptureKit, Core Audio, ApplicationServices/GameController (input)
- **Linux**: PipeWire, PulseAudio, ALSA, V4L2, evdev (input)
- **Android**: Camera2 NDK (API 24+), MediaProjection + AImageReader (API 26+), AAudio/OpenSL via miniaudio
- **iOS**: AVFoundation, ReplayKit, Metal, AVAudioSession

### Build Dependencies

- CMake 3.15+
- Platform-appropriate C++ compiler
- pkg-config (Linux)
- Android SDK + NDK r26+, Ninja (Android)
- Xcode (iOS/macOS)

## Troubleshooting

### Common Issues

**No devices found**: Check permissions and platform-specific requirements

**Frame drops or freezes**: Ensure timely buffer release and avoid blocking operations in callbacks

**Build failures**: Verify CMake version and platform dependencies are installed

**Permission denied**: Add user to required groups (Linux) or enable privacy settings

### Debug Logging

```dart
MiniAV.setLogLevel(MiniAVLogLevel.debug);
MiniAV.setLogCallback((level, message) {
  print('[$level] $message');
});
```
