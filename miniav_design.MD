# MiniAV Design Document

## Overview

MiniAV is a lightweight, cross-platform library focused on encapsulating audio and video buffers for computer vision and signal processing pipelines. It provides a `miniAVBuffer` type for video and audio data, designed for direct transfer of raw data (pixels or samples) to a GPU compute shader pipeline (like `minigpu`).

## Goals

* **Cross-Platform Compatibility:** Support Windows, macOS, Linux, Android, iOS, and Web (via Emscripten/WASM).
* **Specific Capture APIs:** Provide distinct, tailored C APIs for camera, screen, and audio capture.
* **Rich Buffer Management:** Develop a `miniAVBuffer` struct that encapsulates raw data along with essential metadata (resolution, pixel format, timestamps, audio format, etc.).
* **High-Performance Data Transfer:** Enable zero (or minimal) copy paradigms on native platforms and efficient data transfer on the web for direct use in compute pipelines.
* **Modularity and Extensibility:** Organize the project with clear separation between the core C library (`miniav_c` within `miniav_ffi`), the Dart FFI package (`miniav_ffi`), the web integration (`miniav_web`), and the Dart platform interface (`miniav_platform_interface`).
* **Leverage Existing Libraries:** Utilize `miniaudio` for cross-platform audio capture within the C library.

## Folder Structure

```console
miniav(monorepo)/
├── miniav_ffi/                     # Dart package providing FFI bindings and building the native library.
│   ├── lib/
│   │   ├── src/
│   │   │   ├── miniav_bindings.dart      # Generated FFI bindings (using ffigen).
│   │   │   ├── miniav_impl_ffi.dart      # FFI implementation of the platform interface.
│   │   │   ├── camera_controller_ffi.dart # FFI implementation for camera.
│   │   │   ├── screen_controller_ffi.dart # FFI implementation for screen.
│   │   │   └── audio_controller_ffi.dart  # FFI implementation for audio.
│   │   └── miniav_ffi.dart             # Main package export file.
│   ├── pubspec.yaml
│   ├── build.dart                    # Native assets build script (invokes CMake).
│   └── miniav_c/                     # Core C implementation.
│       ├── CMakeLists.txt            # Main CMake build configuration for miniav_c.
│       ├── cmake/                      # CMake helper modules.
│       │   └── FindMiniAudio.cmake     # Example CMake module.
│       ├── include/                  # Public C headers.
│       │   ├── miniav_buffer.h         # Defines MiniAVBuffer, format enums.
│       │   ├── miniav_capture.h        # Defines capture API functions, callback types.
│       │   └── miniav_types.h          # Defines MiniAVResultCode, MiniAVDeviceInfo, handles, etc.
│       └── src/                      # Native C/C++ source code.
│           ├── common/               # Platform-independent utilities.
│           │   ├── miniav_context_base.h # Base struct/functions for contexts.
│           │   ├── miniav_logging.c
│           │   ├── miniav_logging.h
│           │   ├── miniav_utils.c      # Memory allocation, string helpers.
│           │   ├── miniav_utils.h
│           │   └── miniav_time.c       # Monotonic clock functions.
│           │   └── miniav_time.h
│           ├── audio/                # Audio capture implementation (wraps miniaudio).
│           │   ├── audio_context.c     # Implementation of audio context functions.
│           │   └── audio_context.h     # Internal audio context struct.
│           ├── loopback/             # Loopback audio capture (system/application audio output).
│           │   ├── loopback_api.c      # Implementation of public MiniAV_Loopback_* functions.
│           │   ├── loopback_context.h  # Internal loopback context struct and common logic interface.
│           │   ├── windows/
│           │   │   └── loopback_context_win_wasapi.c
│           │   ├── macos/
│           │   │   └── loopback_context_macos_coreaudio.m
│           │   └── linux/
│           │       └── loopback_context_linux_pipewire.c  # PipeWire for system/app audio loopback
│           ├── camera/               # Camera capture implementation.
│           │   ├── camera_api.c        # Implementation of public MiniAV_Camera_* functions.
│           │   ├── camera_context.h    # Internal camera context struct and common logic interface.
│           │   ├── windows/
│           │   │   ├── camera_context_win_mf.c # Media Foundation implementation.
│           │   │   └── camera_context_win_mf.h
│           │   │   └── (camera_context_win_ds.c) # Optional DirectShow fallback.
│           │   ├── macos/
│           │   │   ├── camera_context_macos_avf.m # AVFoundation implementation (Objective-C).
│           │   │   └── camera_context_macos_avf.h
│           │   └── linux/
│           │       ├── camera_context_linux_pipewire.c # PipeWire implementation.
│           │       └── camera_context_linux_pipewire.h
│           ├── input/                # Input capture implementation.
│           │   ├── input_api.c        # Implementation of public MiniAV_Input_* functions.
│           │   ├── input_context.h    # Internal input context struct and common logic interface.
│           │   ├── windows/
│           │   │   ├── input_context_win_rawinput.c # Low-level hooks + XInput implementation.
│           │   │   └── input_context_win_rawinput.h
│           │   └── linux/
│           │       ├── input_context_linux_libinput.c # libinput implementation (future).
│           │       └── input_context_linux_libinput.h
│           └── screen/               # Screen capture implementation.
│               ├── screen_api.c        # Implementation of public MiniAV_Screen_* functions.
│               ├── screen_context.h    # Internal screen context struct and common logic interface.
│               ├── windows/
│               │   ├── screen_context_win_dxgi.c # Desktop Duplication implementation.
│               │   └── screen_context_win_dxgi.h
│               │   └── (screen_context_win_gdi.c) # Optional GDI fallback.
│               ├── macos/
│               │   ├── screen_context_macos_cg.m # CoreGraphics implementation (Objective-C).
│               │   └── screen_context_macos_cg.h
│               │   └── (screen_context_macos_avf.m) # Optional AVFoundation screen input.
│               └── linux/
│                   ├── screen_context_linux_pipewire.c # PipeWire portal implementation.
│                   └── screen_context_linux_pipewire.h
│
├── miniav_web/                     # Web-specific implementation.
│   ├── lib/
│   │   ├── src/
│   │   │   ├── miniav_impl_web.dart      # Web implementation of the platform interface.
│   │   │   ├── camera_controller_web.dart # Web implementation for camera.
│   │   │   ├── screen_controller_web.dart # Web implementation for screen.
│   │   │   └── audio_controller_web.dart  # Web implementation for audio.
│   │   └── miniav_web.dart             # Main package export file.
│   ├── pubspec.yaml
│   └── web/                          # Potential location for JS interop files or WASM artifacts.
│       └── interop.js
│
└── miniav_platform_interface/      # Defines the common Dart API interface.
    ├── lib/
    │   ├── src/
    │   │   ├── miniav_platform_interface_base.dart # Base class for platform implementations.
    │   │   ├── miniav_controller.dart    # Abstract controller interface.
    │   │   ├── miniav_models.dart        # Dart equivalents of MiniAVBuffer, MiniAVDeviceInfo etc.
    │   │   └── miniav_enums.dart         # Dart equivalents of C enums.
    │   └── miniav_platform_interface.dart # Main package export file.
    └── pubspec.yaml
```

## Dependencies

MiniAV requires various system libraries, development packages, and runtime components depending on the platform and enabled modules. This section outlines the required dependencies for building and running MiniAV applications.

### Build Dependencies (All Platforms)

* **CMake:** Version 3.15 or later
* **C/C++ Compiler:**
  * **Windows:** Visual Studio 2019+ or MinGW-w64
  * **macOS:** Xcode Command Line Tools (clang)
  * **Linux:** GCC 9+ or Clang 10+
  * **Android:** Android NDK r21+
* **Dart SDK:** Version 3.0+ (for FFI package development)
* **pkg-config:** Required on Linux for library detection

### Windows Dependencies

#### Runtime Libraries

* **Visual C++ Redistributable:** 2019 or later (if using MSVC-built binaries)
* **Windows 10 Version 1903+:** Required for Windows Graphics Capture (WGC)

#### Development Libraries (Automatically Linked)

* **Media Foundation:** `mfplat.lib`, `mf.lib`, `mfreadwrite.lib`, `mfuuid.lib`
* **DirectX:** `d3d11.lib`, `dxgi.lib`
* **Core Windows:** `ole32.lib`, `uuid.lib`, `shlwapi.lib`, `ksuser.lib`

#### Optional Components

* **Windows SDK:** Version 10.0.18362.0+ (for latest WGC features)

### macOS Dependencies

#### System Requirements

* **macOS 10.15+:** Required for screen recording permissions
* **macOS 12.3+:** Required for ScreenCaptureKit (optional, fallback available)
* **macOS 14.2+:** Required for Audio Taps API (optional, fallback available)

#### Development Tools

* **Xcode:** Version 12+ (for Objective-C/C++ compilation)
* **Command Line Tools:** `xcode-select --install`

#### System Frameworks (Automatically Linked)

* **Foundation.framework**
* **CoreMedia.framework**
* **CoreVideo.framework**
* **AVFoundation.framework**
* **CoreGraphics.framework**
* **ScreenCaptureKit.framework** (macOS 12.3+)
* **CoreAudio.framework**
* **AudioToolbox.framework**

#### Optional Fallback Dependencies

* **BlackHole:** Virtual audio driver for system audio capture fallback
* **SoundFlower:** Alternative virtual audio driver (legacy)
* **Loopback by Rogue Amoeba:** Commercial virtual audio solution

### Linux Dependencies

Linux has the most complex dependency requirements due to the variety of distributions and desktop environments.

#### Core Development Packages

**Ubuntu/Debian:**

```bash
# Essential build tools
sudo apt update
sudo apt install build-essential cmake pkg-config

# Core libraries
sudo apt install libc6-dev libpthread-stubs0-dev

# Audio dependencies (miniaudio)
sudo apt install libasound2-dev libpulse-dev

# PipeWire dependencies (recommended)
sudo apt install libpipewire-0.3-dev libspa-0.2-dev

# D-Bus and Portal support
sudo apt install libdbus-1-dev libgio-2.0-dev libglib2.0-dev

# X11 dependencies (fallback screen capture)
sudo apt install libx11-dev libxext-dev libxfixes-dev libxrandr-dev libxcomposite-dev

# V4L2 dependencies (fallback camera)
sudo apt install libv4l-dev linux-libc-dev
```

**Fedora/CentOS/RHEL:**

```bash
# Essential build tools
sudo dnf install gcc gcc-c++ cmake pkgconf-pkg-config

# Core libraries
sudo dnf install glibc-devel

# Audio dependencies
sudo dnf install alsa-lib-devel pulseaudio-libs-devel

# PipeWire dependencies
sudo dnf install pipewire-devel

# D-Bus and Portal support  
sudo dnf install dbus-devel glib2-devel

# X11 dependencies
sudo dnf install libX11-devel libXext-devel libXfixes-devel libXrandr-devel libXcomposite-devel

# V4L2 dependencies
sudo dnf install libv4l-devel kernel-headers
```

**Arch Linux:**

```bash
# Essential build tools
sudo pacman -S base-devel cmake pkgconf

# Audio dependencies
sudo pacman -S alsa-lib libpulse

# PipeWire dependencies
sudo pacman -S pipewire libpipewire

# D-Bus and Portal support
sudo pacman -S dbus glib2

# X11 dependencies
sudo pacman -S libx11 libxext libxfixes libxrandr libxcomposite

# V4L2 dependencies
sudo pacman -S v4l-utils linux-headers
```

#### Runtime Dependencies

**Portal Support (Flatpak/Snap):**

* **xdg-desktop-portal:** Base portal daemon
* **xdg-desktop-portal-gtk:** GTK portal backend
* **xdg-desktop-portal-kde:** KDE portal backend
* **xdg-desktop-portal-wlr:** wlroots portal backend (Sway, etc.)

**PipeWire Runtime:**

```bash
# Ubuntu/Debian
sudo apt install pipewire pipewire-audio-client-libraries

# Fedora
sudo dnf install pipewire pipewire-pulseaudio

# Arch
sudo pacman -S pipewire pipewire-pulse
```

**User Groups and Permissions:**

```bash
# Add user to necessary groups
sudo usermod -a -G audio,video $USER

# Verify group membership
groups $USER

# Log out and back in for changes to take effect
```

#### Distribution-Specific Notes

**Ubuntu 20.04 LTS:**

* PipeWire support limited - may need to enable PipeWire PPA
* PulseAudio and X11 backend fallbacks welcome

**Ubuntu 22.04 LTS / Fedora 36+:**

* Full PipeWire support available
* Wayland default on GNOME - portal support required

**Debian Stable:**

* May need backports repository for latest PipeWire
* Consider using Flatpak for newer dependencies

### Android Dependencies

#### Build Requirements

* **Android SDK:** API level 21+ (Android 5.0+)
* **Android NDK:** r21c or later
* **Java/Kotlin:** OpenJDK 11+ or Oracle JDK 11+

#### NDK Libraries (Automatically Linked)

* **libcamera2ndk.so:** Camera2 NDK API
* **libmediandk.so:** Media NDK API  
* **libandroid.so:** Android native activity
* **liblog.so:** Android logging

#### Gradle Dependencies (app-level)

```gradle
dependencies {
    implementation 'androidx.camera:camera-core:1.3.0'
    implementation 'androidx.camera:camera-lifecycle:1.3.0'
    implementation 'androidx.camera:camera-view:1.3.0'
}
```

#### Permissions (AndroidManifest.xml)

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
```

### iOS Dependencies

#### Development Requirements

* **Xcode:** Version 14+
* **iOS SDK:** 13.0+ minimum deployment target
* **Swift:** 5.7+ (for mixed Swift/Objective-C projects)

#### System Frameworks (iOS - Automatically Linked)

* **Foundation.framework**
* **AVFoundation.framework**
* **CoreMedia.framework**
* **CoreVideo.framework**
* **ReplayKit.framework**
* **UIKit.framework**
* **Metal.framework** (for GPU buffer support)

#### Info.plist Requirements

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera for video capture</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone for audio recording</string>
```

### Web Dependencies

#### Browser Requirements

* **Chrome/Chromium:** Version 88+ (for getDisplayMedia improvements)
* **Firefox:** Version 85+ (for screen sharing)
* **Safari:** Version 14+ (limited MediaRecorder support)
* **Edge:** Version 88+ (Chromium-based)

#### Web APIs Required

* **getUserMedia():** Camera and microphone access
* **getDisplayMedia():** Screen capture
* **WebRTC:** Real-time communication
* **WebAssembly:** For shared C code (optional)
* **SharedArrayBuffer:** For efficient data transfer (optional, requires COOP/COEP headers)

#### HTTPS Requirement

* All capture APIs require secure context (HTTPS or localhost)
* Self-signed certificates acceptable for development

#### Emscripten Build Dependencies

```bash
# Install Emscripten SDK
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh
```

### Development Environment Setup

#### Ubuntu 22.04 LTS (Recommended Linux Development)

```bash
#!/bin/bash
# Complete MiniAV development setup script

# Update system
sudo apt update && sudo apt upgrade -y

# Install build essentials
sudo apt install -y build-essential cmake pkg-config git

# Install MiniAV dependencies
sudo apt install -y \
  libasound2-dev libpulse-dev \
  libpipewire-0.3-dev libspa-0.2-dev \
  libdbus-1-dev libgio-2.0-dev libglib2.0-dev \
  libx11-dev libxext-dev libxfixes-dev libxrandr-dev libxcomposite-dev \
  libv4l-dev linux-libc-dev

# Install PipeWire runtime
sudo apt install -y pipewire pipewire-audio-client-libraries

# Add user to groups
sudo usermod -a -G audio,video $USER

# Install Dart SDK
sudo apt-get update
sudo apt-get install apt-transport-https
wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' | sudo tee /etc/apt/sources.list.d/dart_stable.list
sudo apt-get update
sudo apt-get install dart

echo "Setup complete! Please log out and back in for group changes to take effect."
```

#### macOS Development Setup

```bash
#!/bin/bash
# MiniAV macOS development setup

# Install Xcode Command Line Tools
xcode-select --install

# Install Homebrew if not present
if ! command -v brew &> /dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install development tools
brew install cmake pkg-config

# Install Dart SDK
brew tap dart-lang/dart
brew install dart

# Optional: Install BlackHole for audio loopback testing
brew install blackhole-2ch

echo "Setup complete! Consider installing Xcode for full iOS development support."
```

### Troubleshooting Common Dependency Issues

#### Linux: PipeWire Not Working

```bash
# Check if PipeWire is running
systemctl --user status pipewire

# Start PipeWire if not running
systemctl --user start pipewire

# Check PipeWire version
pipewire --version

# Test camera access
v4l2-ctl --list-devices
```

#### Linux: Permission Denied Errors

```bash
# Check current groups
groups

# Verify device permissions
ls -la /dev/video* /dev/snd/*

# Test camera access without MiniAV
ffmpeg -f v4l2 -list_formats all -i /dev/video0
```

#### macOS: Framework Not Found

```bash
# Verify Xcode installation
xcode-select -p

# Check framework locations
find /System/Library/Frameworks -name "ScreenCaptureKit.framework" 2>/dev/null

# Verify macOS version for ScreenCaptureKit
sw_vers
```

#### Windows: Media Foundation Errors

```batch
REM Check Windows version
winver

REM Verify Media Foundation registration
regsvr32 mfplat.dll

REM Check DirectX installation
dxdiag
```

### Minimum System Requirements Summary

| Platform | OS Version | RAM | Additional Notes |
|----------|------------|-----|------------------|
| Windows | 10 1903+ | 4GB | DirectX 11 compatible GPU recommended |
| macOS | 10.15+ | 8GB | Intel or Apple Silicon |
| Linux | Ubuntu 20.04+ / equivalent | 4GB | PipeWire recommended, X11/Wayland |
| Android | API 21+ (5.0) | 3GB | Camera2 API support |
| iOS | 13.0+ | 3GB | 64-bit processor required |
| Web | Modern browser | 2GB | HTTPS required for capture APIs |

## Module Breakdown

### 1. MiniAV Core C Library (`miniav_ffi/miniav_c`)

This standalone C library contains the core buffer definitions, the public C capture APIs (split by type: camera, screen, audio), and all platform-specific native implementations (excluding web). It is built as a native asset by the `miniav_ffi` package.

* **Buffer Definition (`include/miniav_buffer.h`):** Defines `miniAVBuffer` struct, pixel/sample format enums, etc. Includes `internal_handle` for explicit buffer release.
* **Capture API (`include/miniav_capture.h`, `include/miniav_types.h`):** Defines the public C functions (e.g., `MiniAV_Camera_CreateContext`, `MiniAV_Screen_StartCapture`, `MiniAV_Audio_Configure`, `MiniAV_ReleaseBuffer`, etc.) and types (`MiniAVDeviceInfo`, `MiniAVResultCode`, `MiniAVBufferCallback`, etc.). This header is used by `miniav_ffi` to generate Dart bindings.
* **Implementation (`src/`):** Contains platform-independent logic (`src/common`), the `miniaudio` wrapper for audio (`src/audio`), and platform-specific implementations for camera and screen capture located within their respective directories (`src/camera/<platform>`, `src/screen/<platform>`). The common logic within `src/camera` and `src/screen` utilizes the platform-specific code.

#### Platform-Specific Native APIs

* **Windows:**
  * **Camera:** Media Foundation (preferred: `IMFSourceReader`), DirectShow (fallback).
  * **Screen:** Desktop Duplication API (preferred), GDI/BitBlt (fallback).
    * **System Audio (Loopback):** If requested via `MiniAV_Screen_StartCapture`, WASAPI loopback capture will be initiated via miniaudio.
  * **Audio (Input):** WASAPI (via `miniaudio`).
  * **Loopback Audio (Output Capture):** Direct WASAPI loopback capture (`IAudioClient3` with `AUDCLNT_STREAMFLAGS_LOOPBACK`).

  * **Zero-Copy / GPU Handles:**
    * **Media Foundation / DXGI:** Leverage `IMFDXGIDeviceManager` for camera and DXGI for screen to obtain `ID3D11Texture2D*`. These can be copied to textures created with `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` (or `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX`) to export an NT `HANDLE`. This `HANDLE` can then be imported by other D3D11/D3D12/WebGPU instances.
    * **CPU Buffers:** `IMFMediaBuffer::Lock` (Media Foundation), mapping DXGI staging textures, or GDI access.
  * **Buffer Release:** Involves unlocking/releasing MF buffers, unmapping staging textures, or releasing D3D11 textures and closing NT `HANDLE`s.

* **macOS:**
  * **Camera:** AVFoundation (`AVCaptureSession`, `AVCaptureVideoDataOutput`).
  * **Screen:** AVFoundation (`AVCaptureScreenInput`), Core Graphics (`CGDisplayStream`).
    * **System Audio:** If requested, the AVFoundation session will be configured to include system audio output, or appropriate Core Audio APIs will be used for loopback.
  * **Audio (Input):** Core Audio (via `miniaudio`).
  * **Loopback Audio (Output Capture):** Core Audio APIs (e.g., `AudioUnit` with a tap on an output device, or `AVAudioEngine` taps) to capture system audio or attempt per-application audio.

  * **Zero-Copy / GPU Handles:**
    * **AVFoundation:** `CVPixelBufferRef` from `CMSampleBufferRef` can often be backed by an `IOSurfaceRef` or a Metal texture (`MTLTexture`). `IOSurfaceRef` can be shared between processes or converted to `MTLTexture`.
    * **CPU Buffers:** `CVPixelBufferGetBaseAddress` on `CMSampleBufferRef`.
  * **Buffer Release:** Involves releasing the `CMSampleBufferRef`, `CVPixelBufferRef`, `IOSurfaceRef`, or `MTLTexture`.

* **Linux:**
  * **Camera:** PipeWire camera portal (preferred for modern systems and sandboxed applications).
  * **Screen:** PipeWire screen capture portal (preferred for Wayland and modern desktop environments).
    * **System Audio:** If requested, PipeWire will be asked to provide a system audio loopback stream alongside the screen video stream.
  * **Audio:** ALSA / PulseAudio (via `miniaudio`). PipeWire for modern systems.
  * **Loopback Audio (Output Capture):**
    * **PipeWire:** Preferred. If capturing screen via PipeWire portal, request associated audio stream from the portal for per-application/window audio. For standalone system audio, connect to appropriate PipeWire audio sink/monitor.
  * **Zero-Copy / GPU Handles:**
    * **PipeWire:** Can provide DMA-BUF file descriptors (`dmabuf fd`). These can be imported into Vulkan (`vkImportSemaphoreFdKHR`, `vkImportMemoryFdKHR`) or EGL/OpenGL (`eglCreateImageKHR` with `EGL_LINUX_DMA_BUF_EXT`) to create GPU textures.
    * **CPU Buffers:** PipeWire buffer mapping.
  * **Buffer Release:** Involves returning buffers to PipeWire, or closing `dmabuf fd`s and releasing associated GPU resources.

* **Android (Future):**
  * **Camera:** Camera2 API (Java/Kotlin via JNI) or NDK Camera (`ACameraManager`).
  * **Screen:** `MediaProjection` API (Java/Kotlin via JNI).
  * **Audio:** AAudio (preferred), OpenSL ES (fallback) - likely via `miniaudio`.
  * **Zero-Copy / GPU Handles:** `AHardwareBuffer` can be acquired and imported into Vulkan or OpenGL ES.
  * **Buffer Release:** Specific NDK/API calls for `AHardwareBuffer` or `ImageReader` buffers.
  * **Loopback Audio (Output Capture):** **Not supported.** Android security model prohibits system audio capture. Alternatives include using a hardware loopback dongle or circuit.

* **iOS (Future):**
  * **Camera:** AVFoundation (`AVCaptureSession`, `AVCaptureVideoDataOutput`).
  * **Screen:** ReplayKit (`RPScreenRecorder`).
  * **Audio:** Core Audio (via `miniaudio` or direct implementation).
  * **Zero-Copy / GPU Handles:** `CVPixelBufferRef` can be backed by `IOSurfaceRef` or `MTLTexture`.
  * **Buffer Release:** Releasing `CMSampleBufferRef`, `CVPixelBufferRef`, `IOSurfaceRef`, or `MTLTexture`.
  * **Loopback Audio (Output Capture):** **Not supported.** iOS sandboxing and lack of public APIs prevent system audio capture. Alternatives include using a hardware loopback dongle or circuit.

## Permissions and Security Requirements

Modern operating systems require explicit user consent and proper application configuration for accessing cameras, microphones, screen content, and system audio. MiniAV applications must handle these requirements appropriately.

### macOS

* **Camera Access:**
  * **Info.plist:** `NSCameraUsageDescription` key with user-facing explanation
  * **Runtime:** System prompts user on first access; subsequent access uses stored preference
  * **Enterprise:** Can be managed via MDM profiles

* **Microphone Access:**
  * **Info.plist:** `NSMicrophoneUsageDescription` key with user-facing explanation  
  * **Runtime:** System prompts user on first access; subsequent access uses stored preference

* **Screen Recording:**
  * **Info.plist:** No key required, but recommended to include usage description for clarity
  * **Runtime:** macOS 10.15+ requires manual user approval in System Preferences > Security & Privacy > Privacy > Screen Recording
  * **Note:** Applications must be restarted after granting permission

* **System Audio Capture (Audio Taps):**
  * **Info.plist:** `NSAudioCaptureUsageDescription` key required for Audio Tap API (macOS 14.2+)
  * **Runtime:** System prompts for "system audio recording" permission on first tap creation
  * **Fallback:** Virtual audio drivers (BlackHole, etc.) don't require special permissions but must be user-installed

* **Sandboxing Considerations:**
  * App Store apps with sandboxing may have additional restrictions
  * Camera/microphone entitlements: `com.apple.security.device.camera`, `com.apple.security.device.microphone`
  * ScreenCaptureKit may require additional entitlements in sandboxed environments

### Windows

* **Camera Access:**
  * **Modern Apps:** Windows 10+ Privacy Settings > Camera > Allow apps to access camera
  * **Registry:** Can be controlled via group policy in enterprise environments
  * **Manifest:** UWP apps require `webcam` capability in Package.appxmanifest

* **Microphone Access:**
  * **Modern Apps:** Windows 10+ Privacy Settings > Microphone > Allow apps to access microphone
  * **Registry:** Can be controlled via group policy
  * **Manifest:** UWP apps require `microphone` capability

* **Screen Capture:**
  * **Desktop Apps:** Generally no special permissions required for traditional Win32 applications
  * **Modern Apps:** May require additional capabilities or user consent
  * **Enterprise:** Can be restricted via group policy (e.g., preventing screen capture APIs)

* **System Audio (WASAPI Loopback):**
  * **Desktop Apps:** Generally no special permissions for loopback capture
  * **Modern Apps:** May require audio capabilities in manifest
  * **Note:** Some enterprise security software may block audio loopback

### Linux

* **Camera/Microphone Access:**
  * **Permissions:** Typically requires user to be in `video` and `audio` groups
  * **Device Files:** Direct access to `/dev/video*` and `/dev/snd/*` devices
  * **Flatpak/Snap:** Require portal permissions for camera/microphone access

* **Screen Capture:**
  * **X11:** Generally unrestricted, but some compositors may require user consent
  * **Wayland:** Requires portal permissions; user consent via desktop environment
  * **PipeWire Portal:** Modern preferred method with user consent dialogs

* **System Audio (PipeWire Loopback):**
  * **Permissions:** User must be in `audio` group
  * **PipeWire:** Modern systems use PipeWire for audio routing and capture
  * **Pulse/ALSA:** Legacy systems may require additional configuration

* **Sandboxing (Flatpak/Snap):**
  * **Camera:** `--device=all` or `--socket=camera`
  * **Microphone:** `--device=all` or `--socket=microphone`
  * **Screen:** `--socket=x11` or Wayland portal permissions
  * **Audio:** `--socket=audio` or `--socket=pulse`

### Android (Future)

* **Camera Permission:**
  * **Manifest:** `<uses-permission android:name="android.permission.CAMERA" />`
  * **Runtime:** Android 6.0+ requires runtime permission request
  * **Target API:** Android 13+ requires more granular camera permissions

* **Microphone Permission:**
  * **Manifest:** `<uses-permission android:name="android.permission.RECORD_AUDIO" />`
  * **Runtime:** Requires runtime permission request

* **Screen Capture:**
  * **MediaProjection:** Requires user consent via system dialog (`MediaProjectionManager.createScreenCaptureIntent()`)
  * **No Manifest Permission:** Screen capture intent handles permission

* **System Audio Capture (Loopback):**
  * **Not Supported:** Android security model prohibits system audio capture
  * **Alternative:** Audio loopback dongle or circuit for hardware capture like a microphone

### iOS (Future)

* **Camera Access:**
  * **Info.plist:** `NSCameraUsageDescription` required
  * **Runtime:** System prompts user; uses stored preference thereafter
  * **App Review:** Apple requires legitimate use case explanation

* **Microphone Access:**
  * **Info.plist:** `NSMicrophoneUsageDescription` required
  * **Runtime:** System prompts user

* **Screen Recording:**
  * **ReplayKit:** No special permissions required for in-app recording
  * **System Screen Recording:** iOS 11+ requires user consent via control center
  * **Broadcast Extensions:** Special considerations for live streaming

* **System Audio Capture (Loopback):**
  * **Not Supported:** iOS sandboxing prevents system audio capture
  * **Alternative:** Apps can only capture their own audio output via ReplayKit.
  Audio loopback dongle or circuit for hardware capture like a microphone

### Web

* **Camera/Microphone Access:**
  * **HTTPS Required:** Secure context mandatory for `getUserMedia()`
  * **User Gesture:** Many browsers require user interaction to trigger permission prompt
  * **Permissions API:** Query permission status: `navigator.permissions.query({name: 'camera'})`

* **Screen Capture:**
  * **getDisplayMedia():** Always requires user gesture and shows system picker
  * **No Manifest:** Browser handles permission UI
  * **Feature Policy:** Can be controlled by embedding page headers

* **Audio Context:**
  * **User Gesture:** Required for `AudioContext.resume()` due to autoplay policies
  * **Cross-Origin:** Audio capture subject to CORS restrictions

### Implementation Recommendations

1. **Graceful Degradation:** Always check permission status before attempting capture
2. **User Education:** Provide clear explanations of why permissions are needed
3. **Fallback Strategies:** Offer alternative capture methods when primary methods are restricted
4. **Permission Caching:** Cache permission status to avoid repeated system calls
5. **Error Handling:** Provide specific error messages for permission-related failures
6. **Documentation:** Clearly document all required permissions and Info.plist entries

### Common Error Scenarios

* **macOS:** Screen recording permission denied - requires manual user action in System Preferences
* **Windows:** Camera blocked by privacy settings - user must enable in Windows Privacy Settings  
* **Linux:** User not in video/audio groups - requires system administrator action
* **Web:** Non-HTTPS context - getUserMedia() will fail silently or with error
* **Sandboxed Apps:** Missing capabilities/entitlements - app may crash or receive empty device lists

### Testing Considerations

* **Fresh Installs:** Test on systems where permissions haven't been granted
* **Denied Permissions:** Test behavior when user denies access
* **Revoked Permissions:** Test when user later revokes previously granted access
* **Enterprise Policies:** Test in managed environments with restrictive policies
* **Multiple Apps:** Test permission sharing behavior when multiple apps access same resources

### 2. MiniAV FFI (`miniav_ffi`)

* Dart package responsible for interfacing with the native `miniav_c` library.
* Uses `package:ffigen` or similar tools to generate Dart bindings from the headers in `miniav_c/include/`.
* Contains a `build.dart` script that uses the native assets feature to compile `miniav_c` (using CMake) for the target platform.
* Implements the Dart interface defined in `miniav_platform_interface` by calling the C functions via FFI.
* Manages pointer passing, struct marshalling, callback setup (using `NativeCallable`), and **calling `MiniAV_ReleaseBuffer`** between Dart and C.

### 3. MiniAV Web (`miniav_web`)

* Dart package providing the web implementation.
* Uses `dart:html` and `dart:js_interop` to interact with browser APIs (`navigator.mediaDevices.getUserMedia`, `getDisplayMedia`).
* May potentially use a WASM module compiled from parts of `miniav_c` for shared logic or buffer handling if beneficial, but primary capture relies on browser APIs.
* Implements the Dart interface defined in `miniav_platform_interface`.
* Handles data transfer from JavaScript (`ImageData`, `VideoFrame`, `AudioBuffer`) into Dart representations compatible with the platform interface, likely involving copies. (Web platform generally does not support zero-copy access in the same way as native).

### 4. MiniAV Platform Interface (`miniav_platform_interface`)

* A Dart package defining the abstract interface (e.g., using abstract classes or `plugin_platform_interface`) for MiniAV functionality (Camera, Screen, Audio capture).
* Crucially, the interface must now accommodate the concept of **buffer release**. This might involve returning a Dart object that holds the buffer data/pointers *and* a mechanism (e.g., a `dispose()` method) to trigger the underlying native release.
* Both `miniav_ffi` and `miniav_web` implement this interface.
* Allows application code to depend on this package and use the MiniAV features without knowing the underlying platform (native vs. web).

## Core C API Design (`miniav_c/include/`)

This section details the public C API exposed by `miniav_c`.

### Common Types and Concepts

* **Handles (`MiniAVHandle`):** Opaque pointers representing contexts (e.g., `MiniAVCameraContextHandle`, `MiniAVScreenContextHandle`, `MiniAVAudioContextHandle`). Created by `_CreateContext` functions, destroyed by `_DestroyContext` functions. Invalidated after destruction.
* **Result Codes (`MiniAVResultCode`):** Enum defining success (`MINIAV_SUCCESS = 0`) and various error conditions (e.g., `MINIAV_ERROR_INVALID_ARG`, `MINIAV_ERROR_NOT_INITIALIZED`, `MINIAV_ERROR_SYSTEM_CALL_FAILED`, `MINIAV_ERROR_NOT_SUPPORTED`, `MINIAV_ERROR_BUFFER_TOO_SMALL`, `MINIAV_ERROR_INVALID_HANDLE`). Most functions return a `MiniAVResultCode`.
* **Device Info (`MiniAVDeviceInfo`):** Struct containing device ID (unique string, platform-specific format), human-readable name (UTF-8 string), and potentially other metadata like model or manufacturer.

    ```c
    // filepath: miniav_ffi/miniav_c/include/miniav_types.h
    typedef struct {
        char device_id[256]; // Platform-specific unique identifier
        char name[256];      // Human-readable name (UTF-8)
        // Potentially other fields like model, manufacturer, etc.
    } MiniAVDeviceInfo;
    ```

* **Buffer (`MiniAVBuffer`):** Struct containing the core data and metadata. **The data pointers or GPU handles are valid after the callback returns, until `MiniAV_ReleaseBuffer` is called.**

    ```c
    // filepath: miniav_ffi/miniav_c/include/miniav_buffer.h
    typedef enum {
        MINIAV_BUFFER_TYPE_UNKNOWN = 0,
        MINIAV_BUFFER_TYPE_VIDEO,
        MINIAV_BUFFER_TYPE_AUDIO
    } MiniAVBufferType;

    // Indicates the nature of the buffer's primary data content
    typedef enum {
        MINIAV_BUFFER_CONTENT_TYPE_CPU,
        MINIAV_BUFFER_CONTENT_TYPE_GPU_D3D11_HANDLE, // GPU handle for D3D11 NT HANDLE
        MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE, // GPU handle for Metal texture
        MINIAV_BUFFER_CONTENT_TYPE_GPU_DMABUF_FD,     // GPU handle for DMA-BUF file descriptor
    } MiniAVBufferContentType;

    // Output Preference (set during configuration)
    typedef enum {
        MINIAV_OUTPUT_PREFERENCE_CPU,         // Prefer CPU-accessible buffers.
        MINIAV_OUTPUT_PREFERENCE_GPU          // Prefer GPU handles if supported, otherwise fallback to CPU.
    } MiniAVOutputPreference;

    // Common Pixel Formats (Extend as needed)
    typedef enum {
        MINIAV_PIXEL_FORMAT_UNKNOWN = 0,
        MINIAV_PIXEL_FORMAT_I420,    // Planar YUV 4:2:0 (YYYY... UU... VV...)
        MINIAV_PIXEL_FORMAT_NV12,    // Semi-Planar YUV 4:2:0 (YYYY... UVUV...)
        MINIAV_PIXEL_FORMAT_NV21,    // Semi-Planar YUV 4:2:0 (YYYY... VUVU...)
        MINIAV_PIXEL_FORMAT_YUY2,    // Packed YUV 4:2:2 (YUYV YUYV...)
        MINIAV_PIXEL_FORMAT_UYVY,    // Packed YUV 4:2:2 (UYVY UYVY...)
        MINIAV_PIXEL_FORMAT_RGB24,   // Packed RGB (RGB RGB...)
        MINIAV_PIXEL_FORMAT_BGR24,   // Packed BGR (BGR BGR...)
        MINIAV_PIXEL_FORMAT_RGBA32,  // Packed RGBA (RGBA RGBA...)
        MINIAV_PIXEL_FORMAT_BGRA32,  // Packed BGRA (BGRA BGRA...)
        MINIAV_PIXEL_FORMAT_ARGB32,  // Packed ARGB (ARGB ARGB...)
        MINIAV_PIXEL_FORMAT_ABGR32,  // Packed ABGR (ABGR ABGR...)
        MINIAV_PIXEL_FORMAT_MJPEG,   // Motion JPEG (Compressed format)
    } MiniAVPixelFormat;

    // Common Audio Sample Formats (Align with miniaudio where possible)
    typedef enum {
        MINIAV_AUDIO_FORMAT_UNKNOWN = 0,
        MINIAV_AUDIO_FORMAT_U8,      // Unsigned 8-bit integer
        MINIAV_AUDIO_FORMAT_S16,     // Signed 16-bit integer
        MINIAV_AUDIO_FORMAT_S24,     // Signed 24-bit integer (often packed in 32 bits)
        MINIAV_AUDIO_FORMAT_S32,     // Signed 32-bit integer
        MINIAV_AUDIO_FORMAT_F32,     // 32-bit floating point
    } MiniAVAudioFormat;

    typedef enum {
        MINIAV_LOOPBACK_TARGET_NONE,          // No target specified or invalid
        MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO,  // Capture all system audio output (e.g., speaker output)
        MINIAV_LOOPBACK_TARGET_PROCESS,       // Capture audio from a specific process ID
        MINIAV_LOOPBACK_TARGET_WINDOW         // Capture audio associated with a specific window (platform-dependent feasibility)
    } MiniAVLoopbackTargetType;

    typedef struct {
        MiniAVLoopbackTargetType type;
        union {
            uint32_t process_id;        // For MINIAV_LOOPBACK_TARGET_PROCESS
            void* window_handle;        // For MINIAV_LOOPBACK_TARGET_WINDOW (platform-specific: HWND, NSWindow*, XID, etc.)
        } target_handle; 
    } MiniAVLoopbackTargetInfo;

    // Video Format Information (used for configuration)
    typedef struct {
        uint32_t width;                       // Desired width (can be 0 for default)
        uint32_t height;                      // Desired height (can be 0 for default)
        MiniAVPixelFormat pixel_format;       // Desired pixel format for CPU output, or hint for GPU.
        uint32_t frame_rate_numerator;
        uint32_t frame_rate_denominator;
        MiniAVOutputPreference output_preference; // User's preference for CPU or GPU output.
        // Potentially other fields like color_space, etc.
    } MiniAVVideoInfo;

    // Audio Format Information (used for configuration)
    typedef struct {
        uint32_t sample_rate;
        uint32_t channel_count;
        MiniAVAudioFormat format;
        // MiniAVOutputPreference output_preference; // Currently ignored for audio, defaults to CPU.
        // uint32_t buffer_frame_count; // Desired number of frames per callback
    } MiniAVAudioInfo;

    // Unified plane structure for video data
    typedef struct {
        void* data_ptr;               // Pointer to plane data (CPU) or GPU handle
        uint32_t width;               // Plane width in pixels/samples
        uint32_t height;              // Plane height in pixels/lines
        uint32_t stride_bytes;        // Bytes per row/line (0 for GPU handles)
        uint32_t offset_bytes;        // Offset from base buffer start
        uint32_t subresource_index;   // GPU subresource index (0 for CPU)
    } MiniAVPlane;

    typedef struct {
        MiniAVBufferType type;
        MiniAVBufferContentType content_type;
        int64_t timestamp_us; // Monotonic timestamp in microseconds since an arbitrary epoch

        union {
            struct {
                MiniAVVideoInfo info;           // Video format information
                uint8_t num_planes;             // Number of valid planes (1-4)
                MiniAVPlane planes[4];          // Unified plane data (CPU pointers or GPU handles)
            } video;
            struct {
                uint32_t frame_count;
                uint32_t channel_count;
                MiniAVAudioFormat format;
                void* data; // Pointer to interleaved or planar audio data. Valid until MiniAV_ReleaseBuffer is called.
            } audio;
        } data;

        size_t data_size_bytes; // Total size of the raw data pointed to (useful for copying if needed)
        void* user_data;        // User data pointer passed back in the callback
        void* internal_handle;  // Opaque handle required by MiniAV_ReleaseBuffer to release the underlying native buffer.
    } MiniAVBuffer;
    ```

* **Buffer Callback (`MiniAVBufferCallback`):** Function pointer type for receiving buffers.

    ```c
    // filepath: miniav_ffi/miniav_c/include/miniav_capture.h
    // The buffer passed is valid beyond the callback; the user MUST eventually call MiniAV_ReleaseBuffer.
    typedef void (*MiniAVBufferCallback)(const MiniAVBuffer* buffer, void* user_data);
    ```

* **Logging Callback (`MiniAVLogCallback`):** Function pointer type for receiving log messages.

    ```c
    // filepath: miniav_ffi/miniav_c/include/miniav_types.h
    typedef enum {
        MINIAV_LOG_LEVEL_DEBUG = 0,
        MINIAV_LOG_LEVEL_INFO,
        MINIAV_LOG_LEVEL_WARN,
        MINIAV_LOG_LEVEL_ERROR
    } MiniAVLogLevel;

    typedef void (*MiniAVLogCallback)(MiniAVLogLevel level, const char* message, void* user_data);
    ```

### Common / Utility API

* `MiniAVResultCode MiniAV_GetVersion(uint32_t* major, uint32_t* minor, uint32_t* patch);`
* `const char* MiniAV_GetVersionString();`
* `MiniAVResultCode MiniAV_SetLogCallback(MiniAVLogCallback callback, void* user_data);`
* `MiniAVResultCode MiniAV_SetLogLevel(MiniAVLogLevel level);`
* `const char* MiniAV_GetErrorString(MiniAVResultCode code);` // Get human-readable string for an error code
* `MiniAVResultCode MiniAV_ReleaseBuffer(void* internal_handle);` // **New:** Releases the native buffer associated with the handle. Must be called by the user when done with the buffer data.

### Camera Capture API

* `MiniAVResultCode MiniAV_Camera_EnumerateDevices(MiniAVDeviceInfo** devices, uint32_t* count);`
  * Allocates memory for the device list; caller must free using `MiniAV_FreeDeviceList`.
* `MiniAVResultCode MiniAV_FreeDeviceList(MiniAVDeviceInfo* devices, uint32_t count);`
* `MiniAVResultCode MiniAV_Camera_GetSupportedFormats(const char* device_id, MiniAVVideoInfo** formats, uint32_t* count);`
  * Describes supported resolution, pixel format, frame rate combinations.
  * Allocates memory; caller must free using `MiniAV_FreeFormatList`.
* `MiniAVResultCode MiniAV_FreeFormatList(MiniAVVideoInfo* formats, uint32_t count);`
* `MiniAVResultCode MiniAV_Camera_CreateContext(MiniAVCameraContextHandle* context);`
* `MiniAVResultCode MiniAV_Camera_DestroyContext(MiniAVCameraContextHandle context);`
* `MiniAVResultCode MiniAV_Camera_Configure(MiniAVCameraContextHandle context, const char* device_id, const MiniAVVideoInfo* format);`
  * `format->output_preference` guides the library on whether to attempt GPU handle output.
* `MiniAVResultCode MiniAV_Camera_StartCapture(MiniAVCameraContextHandle context, MiniAVBufferCallback callback, void* user_data);`
* `MiniAVResultCode MiniAV_Camera_StopCapture(MiniAVCameraContextHandle context);`
* *(Property API - TBD: Define `MiniAVPropertyKey` enum and `MiniAVPropertyValue` variant struct/union)*
  * `MiniAV_Camera_GetPropertyInfo(...)`
  * `MiniAV_Camera_GetProperty(...)`
  * `MiniAV_Camera_SetProperty(...)`
  * `MiniAV_Camera_SetAutoProperty(...)`

### Screen Capture API

* `MiniAVResultCode MiniAV_Screen_EnumerateDisplays(MiniAVDeviceInfo** displays, uint32_t* count);`
  * Allocates memory; caller must free using `MiniAV_FreeDeviceList`.
* `MiniAVResultCode MiniAV_Screen_EnumerateWindows(MiniAVDeviceInfo** windows, uint32_t* count);` // Optional, platform support varies
  * Allocates memory; caller must free using `MiniAV_FreeDeviceList`.
* `MiniAVResultCode MiniAV_Screen_CreateContext(MiniAVScreenContextHandle* context);`
* `MiniAVResultCode MiniAV_Screen_DestroyContext(MiniAVScreenContextHandle context);`
* `MiniAVResultCode MiniAV_Screen_ConfigureDisplay(MiniAVScreenContextHandle context, const char* display_id, const MiniAVVideoInfo* video_format);`
  * `video_format->output_preference` guides the library for video. Audio is configured at StartCapture.
* `MiniAVResultCode MiniAV_Screen_ConfigureWindow(MiniAVScreenContextHandle context, const char* window_id, const MiniAVVideoInfo* video_format);`
  * `video_format->output_preference` guides the library for video. Audio is configured at StartCapture.
* `MiniAVResultCode MiniAV_Screen_ConfigureRegion(MiniAVScreenContextHandle context, const char* display_id, int x, int y, int width, int height, const MiniAVVideoInfo* video_format);`
  * `video_format->output_preference` guides the library for video. Audio is configured at StartCapture.
* `MiniAVResultCode MiniAV_Screen_StartCapture(MiniAVScreenContextHandle context, MiniAVBufferCallback callback, void* user_data, const MiniAVAudioInfo* optional_audio_format_for_loopback);`
  * If `optional_audio_format_for_loopback` is not NULL, the library will attempt to capture system/application audio (depending on platform capabilities and configuration of the screen capture target) alongside the screen video **by utilizing the audio buffer the screen capture api provides or the Loopback Audio module**.
  * The callback will receive buffers of `type = MINIAV_BUFFER_TYPE_VIDEO` and, if audio capture is enabled and successful, `type = MINIAV_BUFFER_TYPE_AUDIO`.
* `MiniAVResultCode MiniAV_Screen_StopCapture(MiniAVScreenContextHandle context);`
* *(Property API - TBD: Define specific properties like cursor visibility, capture rate control, audio source selection if multiple loopbacks exist)*
  * `MiniAV_Screen_GetProperty(...)`
  * `MiniAV_Screen_SetProperty(...)`

### Audio Capture API

* `MiniAVResultCode MiniAV_Audio_EnumerateDevices(MiniAVDeviceInfo** devices, uint32_t* count);`
  * Allocates memory; caller must free using `MiniAV_FreeDeviceList`.
* `MiniAVResultCode MiniAV_Audio_GetSupportedFormats(const char* device_id, MiniAVAudioInfo** formats, uint32_t* count);`
  * Describes supported sample format, channel count, sample rate combinations.
  * Allocates memory; caller must free using `MiniAV_FreeFormatList`.
* `MiniAVResultCode MiniAV_Audio_CreateContext(MiniAVAudioContextHandle* context);`
* `MiniAVResultCode MiniAV_Audio_DestroyContext(MiniAVAudioContextHandle context);`
* `MiniAVResultCode MiniAV_Audio_Configure(MiniAVAudioContextHandle context, const char* device_id, const MiniAVAudioInfo* format);`
* `MiniAVResultCode MiniAV_Audio_StartCapture(MiniAVAudioContextHandle context, MiniAVBufferCallback callback, void* user_data);`
* `MiniAVResultCode MiniAV_Audio_StopCapture(MiniAVAudioContextHandle context);`
* *(Property API - TBD: Define specific properties like gain/volume/loopback if available)*
  * `MiniAV_Audio_GetProperty(...)`
  * `MiniAV_Audio_SetProperty(...)`

### Loopback Audio API

This API is for capturing audio output from the system or specific applications. It is distinct from the `MiniAV_Audio_*` API which targets input devices like microphones. The Screen Capture API may internally use this module.

* `MiniAVResultCode MiniAV_Loopback_EnumerateTargets(MiniAVLoopbackTargetType target_type_filter, MiniAVDeviceInfo** targets, uint32_t* count);`
  * Enumerates potential audio loopback targets based on the `target_type_filter`.
  * If `target_type_filter` is `MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO`, lists available system-level loopback options (e.g., "Default Output Monitor"). The `device_id` in `MiniAVDeviceInfo` would be a special identifier for these.
  * If `target_type_filter` is `MINIAV_LOOPBACK_TARGET_PROCESS` or `MINIAV_LOOPBACK_TARGET_WINDOW`, attempts to list currently audio-producing applications or windows. The `device_id` in `MiniAVDeviceInfo` would be an identifier that the library can use to resolve to a specific process or window internally for configuration.
  * Platform support for enumerating specific applications/windows varies.
  * Allocates memory for the target list; caller must free using `MiniAV_FreeDeviceList`.

* `MiniAVResultCode MiniAV_Loopback_CreateContext(MiniAVLoopbackContextHandle* context);`
* `MiniAVResultCode MiniAV_Loopback_DestroyContext(MiniAVLoopbackContextHandle context);`

* `MiniAVResultCode MiniAV_Loopback_Configure(MiniAVLoopbackContextHandle context, const char* target_device_id, const MiniAVAudioInfo* format);`
  * Configures loopback using a `target_device_id`.
  * If `target_device_id` is `NULL` or a special predefined string (e.g., `"system_default"` or an ID from `MiniAV_Loopback_EnumerateTargets` with `MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO`), it configures system-wide audio loopback.
  * If `target_device_id` is an ID obtained from `MiniAV_Loopback_EnumerateTargets` (for process/window types) or `MiniAV_Screen_EnumerateWindows`, the library attempts to derive the necessary internal process ID or native window handle to target audio from that specific source.
  * Platform support for reliably targeting specific windows/applications from a generic ID varies.

* `MiniAVResultCode MiniAV_Loopback_ConfigureWithTargetInfo(MiniAVLoopbackContextHandle context, const MiniAVLoopbackTargetInfo* target_info, const MiniAVAudioInfo* format);`
  * Advanced configuration using explicit low-level target information.
  * `target_info` directly specifies whether to capture system-wide audio, or provides a specific process ID or native window handle. Useful when the application obtains this information through other means.

* `MiniAVResultCode MiniAV_Loopback_StartCapture(MiniAVLoopbackContextHandle context, MiniAVBufferCallback callback, void* user_data);`
* `MiniAVResultCode MiniAV_Loopback_StopCapture(MiniAVLoopbackContextHandle context);`
* `MiniAVResultCode MiniAV_Loopback_GetConfiguredFormat(MiniAVLoopbackContextHandle context, MiniAVAudioInfo* format_out);`
  * Gets the actual format configured by the backend.
* *(Property API - TBD: Define specific properties like confirming if per-process capture is active, or selecting a specific underlying audio device if multiple system loopback options exist)*
  * `MiniAV_Loopback_GetProperty(...)`
  * `MiniAV_Loopback_SetProperty(...)`

## Technical Considerations

* **Data Ownership & Buffer Strategy:**
  * The `MiniAVBuffer` passed to the `MiniAVBufferCallback` has its `content_type` field indicating the nature of its data.
  * If `content_type` is `MINIAV_BUFFER_CONTENT_TYPE_CPU`, the relevant `planes[].data_ptr` pointers in the video union are valid CPU-accessible memory.
  * If `content_type` is a GPU type, the relevant `planes[0].data_ptr` contains the GPU handle (cast appropriately).
  * The library attempts to honor the `MiniAVOutputPreference` set during configuration. If `MINIAV_OUTPUT_PREFERENCE_GPU` was set but GPU output failed or is not supported, the buffer's `content_type` will be `MINIAV_BUFFER_CONTENT_TYPE_CPU`.
  * The user (e.g., the Dart FFI layer) is **responsible for explicitly releasing** the underlying native buffer/resource when it is no longer needed by calling `MiniAV_ReleaseBuffer(buffer->internal_handle)` via FFI.
  * **Failure to call `MiniAV_ReleaseBuffer` will result in resource leaks** (e.g., holding onto camera frames, screen capture resources, D3D11 textures, NT HANDLES, audio buffers).
  * **Frame Drops:** If the user does not release buffers promptly, underlying native capture APIs may run out of internal buffers or resources, potentially leading to dropped frames or errors.
  * This explicit release mechanism allows the user to:
    * Pass raw CPU data pointers (`buffer->data.video.planes[0].data_ptr`) for direct processing or CPU->GPU uploads.
    * Pass native GPU handles (`buffer->data.video.planes[0].data_ptr` cast to appropriate handle type) to other GPU-aware libraries (like `minigpu` or WebGPU) for direct import and use, enabling true zero-copy GPU-to-GPU pipelines.
  * **Internal Buffering:** `miniav_c` aims to be a thin layer. If the consuming application requires more complex buffering, it should implement that logic *after* receiving the buffer and its release handle.
  * **Zero-Copy Goal:**
    * **CPU Path:** `miniav_c` aims for minimal copies to provide CPU pointers. The explicit release enables consumers to avoid further copies in the FFI layer for CPU->GPU uploads.
    * **GPU Path:** When `MiniAVBuffer` provides a GPU handle in `planes[0].data_ptr`, the goal is to enable true zero-copy by allowing direct import of this GPU resource into another GPU context (e.g., WebGPU, another D3D11 device). This is highly platform-specific. The `internal_handle` and `MiniAV_ReleaseBuffer` will manage the lifetime of these shared GPU resources (e.g., releasing the underlying `ID3D11Texture2D` and closing the NT `HANDLE`).

* **Threading:**
  * The `MiniAVBufferCallback` is invoked on an **internal library thread** managed by `miniav_c` (or potentially the underlying native API's thread).
  * Users **should still avoid long-running or blocking operations** within the callback itself to prevent potential frame drops or deadlocks. The recommended practice is to quickly extract the necessary pointers, metadata, and the `internal_handle`, then dispatch processing and the eventual call to `MiniAV_ReleaseBuffer` to a separate application thread or manage it asynchronously (e.g., after a GPU operation completes).
* **API Thread Safety:**
  * `_CreateContext`, `_DestroyContext`, `_Configure`, `_StartCapture`, `_StopCapture` functions remain generally **not thread-safe** for the *same* context handle.
  * `MiniAV_ReleaseBuffer` **must be thread-safe** internally within `miniav_c`, as it might be called from a different thread than the one invoking the callback. The implementation needs to handle potential synchronization if required by the underlying native API's buffer release mechanism.

* **Buffer Synchronization:**
  * The `timestamp_us` field in `MiniAVBuffer` provides the primary mechanism for synchronization.
  * It uses a **monotonic clock** source available on the platform (e.g., `QueryPerformanceCounter` on Windows, `mach_absolute_time` on macOS, `clock_gettime(CLOCK_MONOTONIC)` on Linux).
  * The epoch (zero point) of the timestamp is consistent *within a single capture session* (from `StartCapture` to `StopCapture`) for a given context, but may not be comparable across different contexts or application runs without calibration. It's often relative to the time `StartCapture` was called or system boot time.
  * Users needing to synchronize streams from different contexts (e.g., camera and audio) should record the timestamps from each stream and align them in their application logic. Small clock drifts between different hardware sources are possible.

* **Error Handling:**
  * Most functions return a `MiniAVResultCode`. `MINIAV_SUCCESS` indicates success.
  * Specific error codes provide context. `MiniAV_GetErrorString` can convert these to human-readable messages.
  * Logging (`MiniAV_SetLogCallback`) provides more detailed diagnostic information, especially for internal or system call failures.
  * There is no "get last error" function; errors are reported directly via return codes.
  * `MiniAV_ReleaseBuffer` should return a `MiniAVResultCode` (e.g., `MINIAV_SUCCESS`, `MINIAV_ERROR_INVALID_HANDLE`).

* **FFI Considerations (Dart):**
  * **Callbacks:** `miniav_ffi` manages `NativeCallable`.
  * **Pointer/Handle Ownership & Release:** The FFI layer receives `MiniAVBuffer`. It inspects `content_type`.
    * If CPU data, it extracts pointers, metadata, and `internal_handle`.
    * If GPU handle, it extracts the GPU handle from `planes[0].data_ptr`, metadata, and `internal_handle`.
    * It provides a Dart object representing the buffer, holding the `internal_handle` and relevant data/handles, ensuring `MiniAV_ReleaseBuffer` is called via FFI when the Dart object is disposed.
  * **Structs & String Handling:** Match C layout. Use `Utf8` for strings.

## Data Flow (Native via FFI - Explicit Release)

1. **Initialization:** Dart application calls an initialization method defined in `miniav_platform_interface`. The `miniav_ffi` implementation might call `MiniAV_Initialize` (C API) if needed.
2. **Context Creation:** Application requests a camera/screen/audio context via the platform interface. `miniav_ffi` calls the corresponding `MiniAV_<Type>_CreateContext` (C API) via FFI.
3. **Device Discovery:** Application calls device listing methods. `miniav_ffi` calls `MiniAV_<Type>_EnumerateDevices` (C API) via FFI. `miniav_c` executes platform-specific discovery code. Results are marshalled back to Dart, and the native list is freed using `MiniAV_FreeDeviceList`.
4. **Configuration:** Application selects device/format and sets `output_preference` in `MiniAVVideoInfo` (or `MiniAVAudioInfo`). `miniav_ffi` translates these to C structs/calls (e.g., `MiniAV_Camera_Configure`). `miniav_c` stores this preference.
5. **Capture Start:** Application calls start capture method, providing a Dart callback. `miniav_ffi` sets up a native FFI callback (`NativeCallable`) that wraps the Dart callback (potentially sending data via a `SendPort`) and passes its pointer (and user data containing necessary Dart state/ports) to `MiniAV_<Type>_StartCapture` (C API). `miniav_c` sets up the platform context and registers the native FFI callback.
6. **Data Production (C Library):**
    * Platform-specific C code captures data, respecting the stored `output_preference`.
    * For video:
      * **If `output_preference` was `_GPU` and GPU output is successful:**
          * Populates `MiniAVBuffer` with `type = MINIAV_BUFFER_TYPE_VIDEO`, `content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_...`, GPU handles in `planes[0].data_ptr`, metadata, and `internal_handle`.
      * **Else (preference was `_CPU`, or GPU preferred but failed/unavailable):**
          * Populates `MiniAVBuffer` with `type = MINIAV_BUFFER_TYPE_VIDEO`, `content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU`, CPU data pointers in appropriate planes, metadata, and `internal_handle`.
    * For audio (if screen capture with audio is active):
        * Captures system audio.
        * Populates `MiniAVBuffer` with `type = MINIAV_BUFFER_TYPE_AUDIO`, `content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU`, audio data, metadata, and `internal_handle`.
    * Invokes the native FFI callback for each buffer (video or audio).
7. **Callback Invocation (FFI Layer):**
    * Native FFI callback executes. Reads `MiniAVBuffer`.
    * Based on `content_type`, extracts either CPU data pointers from planes or GPU handles from `planes[0].data_ptr`, along with metadata and `internal_handle`.
    * Passes these (e.g., in a Dart object) to the Dart callback/`SendPort`.
8. **Buffer Consumption (Dart Application):**
    * Receives the Dart object representing the buffer.
    * **If GPU Handle:** Passes the GPU handle and metadata to a GPU-aware library (e.g., `minigpu`, WebGPU interop layer) for import and direct GPU processing.
    * **If CPU Data:** Passes data pointers and metadata for CPU processing or CPU->GPU upload.
    * The Dart object holds the `internal_handle`.
9. **GPU Interaction / Processing:** The consumer library (`minigpu`) uses the provided data pointer and metadata to perform its operations (e.g., upload to texture).
10. **Buffer Release:** Once the Dart application determines the buffer data is no longer needed (e.g., GPU upload is complete, processing is finished), it **must** trigger the release. This typically involves calling a method on the Dart `MiniAVBuffer` object which, in turn, calls the `MiniAV_ReleaseBuffer(internal_handle)` C function via FFI.
11. **Capture Stop:** Application calls stop method. `miniav_ffi` calls `MiniAV_<Type>_StopCapture` (C API). The associated `NativeCallable` can be freed. Any outstanding buffers should ideally be released before or shortly after stopping.
12. **Cleanup:** Application disposes of the context object. `miniav_ffi` calls `MiniAV_<Type>_DestroyContext` (C API).

## Pixel Formats

### MiniAV Unified Format Mapping

Based on platform analysis, MiniAV defines a unified format enum:

```c
// --- Pixel Formats
typedef enum {
    MINIAV_PIXEL_FORMAT_UNKNOWN = 0,
    
    // --- Standard RGB Formats (8-bit) ---
    MINIAV_PIXEL_FORMAT_RGB24,          // 24-bit RGB (no alpha)
    MINIAV_PIXEL_FORMAT_BGR24,          // 24-bit BGR (no alpha)
    MINIAV_PIXEL_FORMAT_RGBA32,         // 32-bit RGBA (alpha in MSB)
    MINIAV_PIXEL_FORMAT_BGRA32,         // 32-bit BGRA (alpha in MSB)
    MINIAV_PIXEL_FORMAT_ARGB32,         // 32-bit ARGB (alpha in LSB)
    MINIAV_PIXEL_FORMAT_ABGR32,         // 32-bit ABGR (alpha in LSB)
    MINIAV_PIXEL_FORMAT_RGBX32,         // 32-bit RGB with padding (X = unused)
    MINIAV_PIXEL_FORMAT_BGRX32,         // 32-bit BGR with padding (X = unused)
    MINIAV_PIXEL_FORMAT_XRGB32,         // 32-bit RGB with leading padding
    MINIAV_PIXEL_FORMAT_XBGR32,         // 32-bit BGR with leading padding
    
    // --- Standard YUV Formats (8-bit) ---
    MINIAV_PIXEL_FORMAT_I420,           // Planar YUV 4:2:0 (YYYY... UU... VV...)
    MINIAV_PIXEL_FORMAT_YV12,           // Planar YUV 4:2:0 (YYYY... VV... UU...)
    MINIAV_PIXEL_FORMAT_NV12,           // Semi-planar YUV 4:2:0 (YYYY... UVUV...)
    MINIAV_PIXEL_FORMAT_NV21,           // Semi-planar YUV 4:2:0 (YYYY... VUVU...)
    MINIAV_PIXEL_FORMAT_YUY2,           // Packed YUV 4:2:2 (YUYV YUYV...)
    MINIAV_PIXEL_FORMAT_UYVY,           // Packed YUV 4:2:2 (UYVY UYVY...)
    
    // --- High-End RGB Formats ---
    MINIAV_PIXEL_FORMAT_RGB30,          // 30-bit RGB (10-bit per channel)
    MINIAV_PIXEL_FORMAT_RGB48,          // 48-bit RGB (16-bit per channel)
    MINIAV_PIXEL_FORMAT_RGBA64,         // 64-bit RGBA (16-bit per channel)
    MINIAV_PIXEL_FORMAT_RGBA64_HALF,    // 64-bit RGBA half-precision float
    MINIAV_PIXEL_FORMAT_RGBA128_FLOAT,  // 128-bit RGBA IEEE float
    
    // --- High-End YUV Formats ---
    MINIAV_PIXEL_FORMAT_YUV420_10BIT,   // 10-bit YUV 4:2:0
    MINIAV_PIXEL_FORMAT_YUV422_10BIT,   // 10-bit YUV 4:2:2
    MINIAV_PIXEL_FORMAT_YUV444_10BIT,   // 10-bit YUV 4:4:4
    
    // --- Grayscale Formats ---
    MINIAV_PIXEL_FORMAT_GRAY8,          // 8-bit grayscale
    MINIAV_PIXEL_FORMAT_GRAY16,         // 16-bit grayscale
    
    // --- Compressed Formats ---
    MINIAV_PIXEL_FORMAT_MJPEG,          // Motion JPEG
    MINIAV_PIXEL_FORMAT_H264,           // H.264 (future)
    MINIAV_PIXEL_FORMAT_H265,           // H.265 (future)
    
    // --- Raw/Bayer Formats ---
    MINIAV_PIXEL_FORMAT_BAYER_GRBG8,    // 8-bit Bayer GRBG
    MINIAV_PIXEL_FORMAT_BAYER_RGGB8,    // 8-bit Bayer RGGB
    MINIAV_PIXEL_FORMAT_BAYER_BGGR8,    // 8-bit Bayer BGGR
    MINIAV_PIXEL_FORMAT_BAYER_GBRG8,    // 8-bit Bayer GBRG
    MINIAV_PIXEL_FORMAT_BAYER_GRBG16,   // 16-bit Bayer GRBG
    MINIAV_PIXEL_FORMAT_BAYER_RGGB16,   // 16-bit Bayer RGGB
    MINIAV_PIXEL_FORMAT_BAYER_BGGR16,   // 16-bit Bayer BGGR
    MINIAV_PIXEL_FORMAT_BAYER_GBRG16,   // 16-bit Bayer GBRG
    
    MINIAV_PIXEL_FORMAT_COUNT
} MiniAVPixelFormat;
```

### Platform Format Support Matrix

| Format | Windows MF/DXGI | macOS/iOS AVF | Linux V4L2 | Linux PipeWire | Android Camera2 | Web |
|--------|-----------------|---------------|-------------|----------------|-----------------|-----|
| **RGB24** | ✓ | ✓ | ✓ | ✓ | ✗ | ✓* |
| **BGR24** | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| **RGBA32** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **BGRA32** | ✓ (native) | ✓ (native) | ✓ | ✓ | ✗ | ✗ |
| **ARGB32** | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| **ABGR32** | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| **RGBX32** | ✓ (DXGI) | ✓ (rare) | ✓ | ✓ | ✗ | ✗ |
| **BGRX32** | ✓ (DXGI native) | ✓ (rare) | ✓ (X11 common) | ✓ | ✗ | ✗ |
| **XRGB32** | ✓ (legacy) | ✗ | ✓ | ✓ | ✗ | ✗ |
| **XBGR32** | ✓ (rare) | ✗ | ✓ | ✓ | ✗ | ✗ |
| **I420** | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **YV12** | ✓ | ✗ | ✓ | ✓ | ✗ | ✗ |
| **NV12** | ✓ (native) | ✓ (native) | ✓ | ✓ | ✓ (flexible) | ✗ |
| **NV21** | ✗ | ✗ | ✓ | ✓ | ✓ (native) | ✗ |
| **YUY2** | ✓ (native) | ✓ | ✓ | ✓ | ✗ | ✗ |
| **UYVY** | ✓ | ✓ (native) | ✓ | ✓ | ✗ | ✗ |
| **MJPEG** | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **RGB30** | ✓ (DXGI) | ✓ (native) | ✗ | ✓** | ✗ | ✗ |
| **RGB48** | ✓ (DXGI) | ✓ (native) | ✗ | ✓** | ✗ | ✗ |
| **RGBA64** | ✓ (DXGI) | ✓ (native) | ✗ | ✓** | ✗ | ✗ |
| **RGBA64_HALF** | ✓ (DXGI) | ✓ (native) | ✗ | ✓** | ✗ | ✗ |
| **RGBA128_FLOAT** | ✓ (DXGI) | ✓ (native) | ✗ | ✓** | ✗ | ✗ |
| **YUV420_10BIT** | ✓ (newer HW) | ✓ (native) | ✓*** | ✓** | ✓ (newer) | ✗ |
| **YUV422_10BIT** | ✓ (newer HW) | ✓ (native) | ✓*** | ✓** | ✓ (newer) | ✗ |
| **YUV444_10BIT** | ✓ (newer HW) | ✓ (native) | ✗ | ✓** | ✓ (newer) | ✗ |
| **GRAY8** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓* |
| **GRAY16** | ✓ | ✓ (native) | ✓ | ✓ | ✓ | ✗ |
| **BAYER_GRBG8** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_RGGB8** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_BGGR8** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_GBRG8** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_GRBG16** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_RGGB16** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_BGGR16** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |
| **BAYER_GBRG16** | ✗ | ✓ (pro cameras) | ✓ | ✓ | ✓ (RAW API) | ✗ |

**Legend:**

* ✓ = Supported natively by platform APIs
* ✓ (native) = Preferred/most efficient format for this platform
* ✓ (common) = Commonly encountered format
* ✓ (rare) = Supported but rarely used
* ✓ (legacy) = Supported for backward compatibility
* ✓* = Supported via browser conversion to standard formats
* ✓** = Supported in modern PipeWire with capable hardware/drivers
* ✓*** = Supported with V4L2 and capable hardware
* ✓ (future) = Planned future support for compressed formats
* ✗ = Not supported or extremely rare

### Platform-Specific Format Notes

#### Windows (Media Foundation/DXGI)

* **BGRA32**: Most common for both camera and screen capture
* **BGRX32**: Native DXGI format (`DXGI_FORMAT_B8G8R8X8_UNORM`) for screen capture
* **NV12**: Preferred for hardware-accelerated video processing
* **RGB30**: Available on HDR-capable displays via DXGI

#### macOS/iOS (Core Video/AVFoundation)

* **BGRA32**: Most common camera format (`kCVPixelFormatType_32BGRA`)
* **NV12**: Native format for efficient video processing
* **High-end formats**: Full support for professional video workflows
* **Bayer formats**: Available with professional cameras

#### Linux V4L2

* **BGRX32**: Common with X11 screen capture (24-bit padded to 32-bit)
* **YUY2/UYVY**: Most common camera formats
* **Limited 10-bit**: Depends on camera hardware capabilities

#### Linux PipeWire

* **Modern format support**: Best compatibility with high-end formats
* **Portal-based**: Format support depends on desktop environment
* **Hardware acceleration**: GPU formats available with modern drivers

#### Android Camera2

* **YUV_420_888**: Flexible format that can represent multiple layouts
* **NV21**: Traditional Android camera format
* **Limited RGB**: RGBA32 mainly for surface rendering
* **RAW support**: Bayer formats available with Camera2 RAW API

#### Web Browsers

* **RGBA32**: Native ImageData format for Canvas
* **Limited YUV**: Browsers handle YUV internally, expose as RGB
* **No direct access**: Formats are abstracted by browser APIs

### Format Recommendations by Use Case

#### Real-time Computer Vision

1. **BGRA32** - Universal compatibility, direct GPU upload
2. **NV12** - Efficient for video processing pipelines
3. **RGB24** - Lightweight for CPU-only processing

#### High-Quality Imaging

1. **RGB30** - 10-bit color for HDR workflows
2. **RGBA64_HALF** - Professional imaging applications
3. **Bayer formats** - Raw sensor data processing

#### Cross-Platform Applications

1. **BGRA32** - Best overall compatibility
2. **NV12** - Good video processing support
3. **RGBA32** - Web-compatible fallback

#### Performance-Critical Applications

1. **Platform native formats** - Avoid conversions
2. **GPU-compatible formats** - Enable zero-copy workflows
3. **Hardware-accelerated formats** - Leverage platform strengths

## Input Capture Module

### Overview

The Input Capture module provides raw input event capture for keyboard, mouse, and gamepad devices. Unlike the other MiniAV modules which deal with media buffers, the Input module delivers **structured typed events** via separate callbacks — it does not use `MiniAVBuffer` packing.

This module is designed to be consumed by higher-level services (e.g., input tracking, recording, replay systems) that handle event batching, serialization, and mapping (such as VK→W3C key code translation).

### Design Decisions

* **Typed Callbacks (not buffer packing):** Each input type (keyboard, mouse, gamepad) has its own callback type and event struct. This avoids unnecessary serialization overhead and provides type safety at the C API level.
* **Configurable Throttle:** Mouse move events can be throttled at the C layer (default 60 Hz) to avoid flooding consumers. Gamepad polling rate is also configurable.
* **Unified Context:** A single `MiniAVInputContext` handles all enabled input types. A bitmask (`MiniAVInputType`) selects which input types to capture.
* **No Device Enumeration for Keyboard/Mouse:** Keyboard and mouse are system-wide hooks — no enumeration needed. Gamepad devices support enumeration.
* **Windows-First Implementation:** Initial backend uses `SetWindowsHookEx` with `WH_KEYBOARD_LL` and `WH_MOUSE_LL` for keyboard/mouse (requires a dedicated thread with a message pump), and XInput for gamepad polling.
* **Raw Events:** MiniAV delivers platform-native event data (e.g., Windows virtual key codes, raw coordinates). Higher-level mapping (VK→W3C, coordinate normalization) is the consumer's responsibility.

### C API Types

```c
// Input type bitmask for selecting which inputs to capture
typedef enum {
    MINIAV_INPUT_TYPE_KEYBOARD = 0x01,
    MINIAV_INPUT_TYPE_MOUSE    = 0x02,
    MINIAV_INPUT_TYPE_GAMEPAD  = 0x04,
} MiniAVInputType;

// Keyboard action
typedef enum {
    MINIAV_KEY_ACTION_DOWN = 0,
    MINIAV_KEY_ACTION_UP   = 1,
} MiniAVKeyAction;

// Mouse action
typedef enum {
    MINIAV_MOUSE_ACTION_MOVE        = 0,
    MINIAV_MOUSE_ACTION_BUTTON_DOWN = 1,
    MINIAV_MOUSE_ACTION_BUTTON_UP   = 2,
    MINIAV_MOUSE_ACTION_WHEEL       = 3,
} MiniAVMouseAction;

// Mouse button identifiers
typedef enum {
    MINIAV_MOUSE_BUTTON_NONE   = 0,
    MINIAV_MOUSE_BUTTON_LEFT   = 1,
    MINIAV_MOUSE_BUTTON_RIGHT  = 2,
    MINIAV_MOUSE_BUTTON_MIDDLE = 3,
    MINIAV_MOUSE_BUTTON_X1     = 4,
    MINIAV_MOUSE_BUTTON_X2     = 5,
} MiniAVMouseButton;

// Event structs
typedef struct {
    uint64_t timestamp_us;
    uint32_t key_code;     // Platform virtual key code
    uint32_t scan_code;    // Hardware scan code
    MiniAVKeyAction action;
} MiniAVKeyboardEvent;

typedef struct {
    uint64_t timestamp_us;
    int32_t x;             // Absolute screen X
    int32_t y;             // Absolute screen Y
    int32_t delta_x;       // Relative movement X
    int32_t delta_y;       // Relative movement Y
    int32_t wheel_delta;   // Scroll wheel delta
    MiniAVMouseAction action;
    MiniAVMouseButton button;
} MiniAVMouseEvent;

typedef struct {
    uint64_t timestamp_us;
    uint32_t gamepad_index;
    uint16_t buttons;      // Bitmask of pressed buttons
    int16_t left_stick_x;
    int16_t left_stick_y;
    int16_t right_stick_x;
    int16_t right_stick_y;
    uint8_t left_trigger;
    uint8_t right_trigger;
    bool connected;
} MiniAVGamepadEvent;

// Typed callbacks
typedef void (*MiniAVKeyboardCallback)(const MiniAVKeyboardEvent* event, void* user_data);
typedef void (*MiniAVMouseCallback)(const MiniAVMouseEvent* event, void* user_data);
typedef void (*MiniAVGamepadCallback)(const MiniAVGamepadEvent* event, void* user_data);

// Configuration
typedef struct {
    uint32_t input_types;       // Bitmask of MiniAVInputType
    uint32_t mouse_throttle_hz; // 0 = no throttle, default = 60
    uint32_t gamepad_poll_hz;   // 0 = default (60)
    MiniAVKeyboardCallback keyboard_callback;
    MiniAVMouseCallback mouse_callback;
    MiniAVGamepadCallback gamepad_callback;
    void* user_data;
} MiniAVInputConfig;

typedef struct MiniAVInputContext* MiniAVInputContextHandle;
```

### C API Functions

```c
// Gamepad enumeration
MiniAVResultCode MiniAV_Input_EnumerateGamepads(MiniAVDeviceInfo** devices, uint32_t* count);

// Context lifecycle
MiniAVResultCode MiniAV_Input_CreateContext(MiniAVInputContextHandle* context);
MiniAVResultCode MiniAV_Input_DestroyContext(MiniAVInputContextHandle context);
MiniAVResultCode MiniAV_Input_Configure(MiniAVInputContextHandle context, const MiniAVInputConfig* config);
MiniAVResultCode MiniAV_Input_StartCapture(MiniAVInputContextHandle context);
MiniAVResultCode MiniAV_Input_StopCapture(MiniAVInputContextHandle context);
```

### Folder Structure Additions

```
miniav_ffi/miniav_c/src/
    input/
        input_context.h         # Internal vtable, backend table, context struct
        input_api.c             # Public API implementation
        windows/
            input_context_win_rawinput.h
            input_context_win_rawinput.c   # WH_KEYBOARD_LL, WH_MOUSE_LL, XInput
        test/
            test_input_capture.c
```

### Platform-Specific Implementation Notes

**Windows:**
* Keyboard/Mouse: `SetWindowsHookEx` with `WH_KEYBOARD_LL` / `WH_MOUSE_LL` on a dedicated thread running `GetMessage` message pump.
* Gamepad: XInput polling on a timer thread at configurable rate.
* Libraries: `user32.lib`, `xinput.lib` (or `xinput9_1_0.lib`)

**Future Platforms:**
* Linux: libinput or `/dev/input/event*` for keyboard/mouse, evdev for gamepad
* macOS: IOKit HID / CGEventTap for keyboard/mouse, IOKit HID for gamepad

### Dart Layer

The Dart layer follows the same pattern as other modules:
* `miniav_platform_interface`: `MiniInputPlatformInterface` + `MiniInputContextPlatformInterface`
* `miniav_ffi`: `MiniAVFFIInputPlatform` + `MiniAVFFIInputContextPlatform` with `NativeCallable.listener` for each typed callback
* `miniav`: `MiniInput` + `MiniInputContext` top-level facades

Platform types added to `miniav_platform_types.dart`:
* `MiniAVInputType`, `MiniAVKeyAction`, `MiniAVMouseAction`, `MiniAVMouseButton` enums
* `MiniAVKeyboardEvent`, `MiniAVMouseEvent`, `MiniAVGamepadEvent` classes
* `MiniAVInputConfig` class

## Considerations for Computer Vision

* **Metadata:** Accurate timestamps (monotonic clock), resolution, pixel format, and camera intrinsics (where available) are paramount. `miniav_c` must query these accurately.
* **Performance:** Prioritize low-latency paths within `miniav_c`. FFI overhead exists but the mandatory CPU copy is avoided with explicit release, enabling faster CPU->GPU transfers. Release call overhead should be minimal.
* **Synchronization:** Rely on accurate `timestamp_us` fields in `MiniAVBuffer` (passed through FFI) for application-level synchronization.
* **Intrinsics:** `miniav_c` implementations should attempt to query intrinsics. Provide API mechanisms (via FFI property system) to override or supply externally calibrated intrinsics.

## Conclusion

MiniAV provides a modular architecture designed for efficient AV capture and integration with compute pipelines like `minigpu`. By adopting an **explicit buffer release** mechanism in its C API (`MiniAV_ReleaseBuffer`), it allows consumers (via the `miniav_ffi` package) to access raw buffer pointers directly. This avoids CPU-side copies in Dart, enabling zero-copy workflows (direct CPU->GPU upload) on supported platforms and reducing latency for demanding CV tasks. The responsibility for timely buffer release lies with the user of the library.
