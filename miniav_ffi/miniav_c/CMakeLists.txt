cmake_minimum_required(VERSION 3.15)

# Must be set before project() to reach the toolchain's version-min flags.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum iOS deployment target")
endif()

project(miniav_c LANGUAGES C CXX)

# Only set our own output dirs for standalone builds. When building under a
# toolchain that already pins the output location (e.g. the native-assets
# `native_toolchain_cmake` hook, which places the artifact where it then looks
# for it), DO NOT override it: appending ${CMAKE_BUILD_TYPE} here on a
# multi-config generator (Visual Studio) produced bin/Release/Release/… and the
# hook could not find the DLL to bundle.
if(NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY)
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/${CMAKE_BUILD_TYPE})
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/${CMAKE_BUILD_TYPE})
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin/${CMAKE_BUILD_TYPE})
endif()

# --- Platform Detection ---
set(MINIAV_PLATFORM_WINDOWS FALSE)
set(MINIAV_PLATFORM_MACOS FALSE)
set(MINIAV_PLATFORM_IOS FALSE)
set(MINIAV_PLATFORM_LINUX FALSE)
set(MINIAV_PLATFORM_ANDROID FALSE)
set(MINIAV_PLATFORM_WEB FALSE)

# Debug platform detection
message(STATUS "CMAKE_SYSTEM_NAME: ${CMAKE_SYSTEM_NAME}")
message(STATUS "EMSCRIPTEN: ${EMSCRIPTEN}")
message(STATUS "WIN32: ${WIN32}")
message(STATUS "CMAKE_C_COMPILER: ${CMAKE_C_COMPILER}")
message(STATUS "CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}")

# Check for Emscripten more thoroughly
if(DEFINED EMSCRIPTEN OR CMAKE_SYSTEM_NAME STREQUAL "Emscripten" OR CMAKE_C_COMPILER_ID STREQUAL "Emscripten")
    set(MINIAV_PLATFORM_WEB TRUE)
    set(MINIAV_PLATFORM_NAME "Web")
    message(STATUS "Detected Emscripten/Web platform")
elseif(WIN32)
    set(MINIAV_PLATFORM_WINDOWS TRUE)
    set(MINIAV_PLATFORM_NAME "Windows")
elseif(APPLE)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(MINIAV_PLATFORM_IOS TRUE)
        set(MINIAV_PLATFORM_NAME "iOS")
    else()
        set(MINIAV_PLATFORM_MACOS TRUE)
        set(MINIAV_PLATFORM_NAME "macOS")
    endif()
elseif(ANDROID)
    set(MINIAV_PLATFORM_ANDROID TRUE)
    set(MINIAV_PLATFORM_NAME "Android")
elseif(UNIX)
    set(MINIAV_PLATFORM_LINUX TRUE)
    set(MINIAV_PLATFORM_NAME "Linux")
else()
    message(FATAL_ERROR "Unsupported platform for miniav_c")
endif()

message(STATUS "Configuring miniav_c for ${MINIAV_PLATFORM_NAME}")

# --- Module Enable Options ---
option(MINIAV_ENABLE_AUDIO "Enable Audio Module (miniaudio)" ON)
if(NOT MINIAV_PLATFORM_WEB)
    option(MINIAV_ENABLE_CAMERA "Enable Camera Capture Module" ON)
    option(MINIAV_ENABLE_SCREEN "Enable Screen Capture Module" ON)
endif()

# Loopback is only supported on desktop platforms
if(MINIAV_PLATFORM_WINDOWS OR MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_LINUX)
    option(MINIAV_ENABLE_LOOPBACK "Enable Audio Loopback Module" ON)
else()
    set(MINIAV_ENABLE_LOOPBACK OFF CACHE BOOL "Audio Loopback not supported on mobile/web platforms" FORCE)
    message(STATUS "Loopback audio disabled: not supported on ${MINIAV_PLATFORM_NAME}")
endif()

# Input capture (keyboard/mouse/gamepad) is only supported on desktop platforms
if(MINIAV_PLATFORM_WINDOWS OR MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_LINUX)
    option(MINIAV_ENABLE_INPUT "Enable Input Capture Module" ON)
else()
    set(MINIAV_ENABLE_INPUT OFF CACHE BOOL "Input capture not supported on mobile/web platforms" FORCE)
    message(STATUS "Input capture disabled: not supported on ${MINIAV_PLATFORM_NAME}")
endif()

# Motion / IMU capture. UNLIKE keyboard/mouse/gamepad, this is FIRST-CLASS on
# mobile (the primary target: phone tilt → parallax) and a benign no-op surface
# on desktop (no built-in IMU → the pull API returns NOT_RUNNING). Enabled on
# iOS/Android + desktop; OFF on web (the browser DeviceMotion path lives in the
# Dart `miniav_web` package, not this native lib). On desktop the motion API
# rides the input module (input_api.c is already compiled under
# MINIAV_ENABLE_INPUT); on mobile it is compiled standalone (see the motion
# sources block below), which is what un-gates input on mobile for motion only.
if(MINIAV_PLATFORM_WINDOWS OR MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_LINUX OR
   MINIAV_PLATFORM_IOS OR MINIAV_PLATFORM_ANDROID)
    option(MINIAV_ENABLE_MOTION "Enable Motion/IMU Capture Module" ON)
else()
    set(MINIAV_ENABLE_MOTION OFF CACHE BOOL "Motion handled by miniav_web on web" FORCE)
    message(STATUS "Native motion disabled: handled by miniav_web on ${MINIAV_PLATFORM_NAME}")
endif()

# Input injection (event replay) is only supported on desktop platforms
if(MINIAV_PLATFORM_WINDOWS OR MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_LINUX)
    option(MINIAV_ENABLE_INJECT "Enable Input Injection Module" ON)
else()
    set(MINIAV_ENABLE_INJECT OFF CACHE BOOL "Input injection not supported on mobile/web platforms" FORCE)
    message(STATUS "Input injection disabled: not supported on ${MINIAV_PLATFORM_NAME}")
endif()

# --- Backend Options ---
# Windows Backends
if(MINIAV_PLATFORM_WINDOWS)
    option(MINIAV_BACKEND_WIN_WGC "Enable WGC for Windows screen capture" ON)
    option(MINIAV_BACKEND_WIN_DXGI "Enable DXGI for Windows screen capture" ON)
    option(MINIAV_BACKEND_WIN_MF "Enable Media Foundation for Windows camera" ON)
    option(MINIAV_BACKEND_WIN_WASAPI "Enable WASAPI for Windows loopback audio" ON)
    option(MINIAV_BACKEND_WIN_HOOKS_XINPUT "Enable low-level hooks + XInput for Windows input capture" ON)
endif()

# macOS Backends
if(MINIAV_PLATFORM_MACOS)
    option(MINIAV_BACKEND_MACOS_AVF "Enable AVFoundation for macOS camera" ON)
    option(MINIAV_BACKEND_MACOS_CG "Enable CoreGraphics for macOS screen capture" ON)
    option(MINIAV_BACKEND_MACOS_COREAUDIO "Enable CoreAudio/AudioTaps for macOS loopback audio" ON)
endif()

# iOS Backends
if(MINIAV_PLATFORM_IOS)
    option(MINIAV_BACKEND_IOS_AVF "Enable AVFoundation for iOS camera" ON)
    option(MINIAV_BACKEND_IOS_REPLAYKIT "Enable ReplayKit for iOS screen recording" ON)
endif()

# Linux Backends
if(MINIAV_PLATFORM_LINUX)
    option(MINIAV_BACKEND_LINUX_V4L2_CAMERA "Enable V4L2 for Linux camera capture" OFF)
    option(MINIAV_BACKEND_LINUX_PIPEWIRE_CAMERA "Enable PipeWire for Linux camera capture" ON)
    option(MINIAV_BACKEND_LINUX_PIPEWIRE_SCREEN "Enable PipeWire for Linux screen capture" ON)
    option(MINIAV_BACKEND_LINUX_X11_SCREEN "Enable X11 for Linux screen capture (fallback)" OFF)
    option(MINIAV_BACKEND_LINUX_PIPEWIRE_LOOPBACK "Enable PipeWire for Linux loopback audio" ON)
endif()

# Android Backends
if(MINIAV_PLATFORM_ANDROID)
    option(MINIAV_BACKEND_ANDROID_CAMERA2 "Enable Camera2 API for Android camera" ON)
    option(MINIAV_BACKEND_ANDROID_NDK_CAMERA "Enable NDK Camera API for Android camera" OFF)
    option(MINIAV_BACKEND_ANDROID_MEDIAPROJECTION "Enable MediaProjection for Android screen capture" ON)
endif()

# Web Backends
if(MINIAV_PLATFORM_WEB)
endif()

# --- Standard & Settings ---
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Enable Objective-C for Apple platforms
if(MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_IOS)
    enable_language(OBJC)
    enable_language(OBJCXX)
endif()

# --- Library Target ---
if(MINIAV_PLATFORM_WEB)
    # OBJECT library (not STATIC): every translation unit is linked into the
    # wasm module, so EMSCRIPTEN_KEEPALIVE exports on the audio functions
    # survive — wasm-ld would drop unreferenced objects out of a static archive.
    add_library(miniav_c OBJECT)

    # Executable that Emscripten turns into miniav_web.js + miniav_web.wasm.
    add_executable(miniav_c_web)
    target_sources(miniav_c_web PRIVATE $<TARGET_OBJECTS:miniav_c>)
    set_target_properties(miniav_c_web PROPERTIES OUTPUT_NAME "miniav_web")

    # Global-Module (no MODULARIZE) to match the proven minigpu_web loader +
    # js_interop pattern: functions reached via Module.ccall / Module._fn, and
    # PCM copied through HEAPF32/HEAPU8 views. No pthreads/AudioWorklets — the
    # miniaudio webaudio backend uses a main-thread ScriptProcessorNode.
    # AudioWorklet audio path: the callback runs on a Wasm Worker thread, so
    # this is a shared-memory (SharedArrayBuffer) build and device init/start
    # suspends via ASYNCIFY. Proven shape: minigpu_web runs the same combo
    # (growth + shared memory + ASYNCIFY + non-MODULARIZE global Module) with
    # a plain script-injection loader. The host page MUST be crossOriginIsolated
    # (COOP: same-origin, COEP: require-corp) or the module won't instantiate.
    target_link_options(miniav_c_web PRIVATE
        "-O3"
        "--no-entry"
        "-sENVIRONMENT=web,worker"          # worklet thread runs as a worker
        "-sMALLOC=emmalloc"
        "-sEXPORTED_FUNCTIONS=_malloc,_free"
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAP8,HEAP16,HEAP32,HEAPU8,HEAPU16,HEAPU32,HEAPF32,HEAPF64"
        "-sALLOW_MEMORY_GROWTH=1"
        "-sINITIAL_MEMORY=64MB"
        "-sMAXIMUM_MEMORY=1GB"              # required with growth + shared memory
        "-sSTACK_SIZE=1MB"
        "-sEXIT_RUNTIME=0"
        "-sWASM_BIGINT=1"
        "-sAUDIO_WORKLET=1"                 # miniaudio AudioWorklet backend
        "-sWASM_WORKERS=1"                  # worklet thread infrastructure
        "-sASYNCIFY"                        # device init/start suspends
        "-sASYNCIFY_STACK_SIZE=16MB"        # 4KB default is too small through device init
        "--emit-symbol-map"
    )
else()
    add_library(miniav_c SHARED)
endif()

# --- Initialize Lists ---
set(ALL_SOURCES "")
set(ALL_HEADERS "")
set(ALL_PRIVATE_INCLUDE_DIRS "")
set(ALL_LINK_LIBS "")
set(ALL_DEFINITIONS "")
set(ALL_COMPILE_OPTIONS "")

# --- Common Sources & Public Headers (Always Included) ---
file(GLOB COMMON_SOURCES "src/common/*.c" "src/common/*.h")
list(APPEND ALL_SOURCES ${COMMON_SOURCES})
list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/common")

list(APPEND ALL_HEADERS
    "include/miniav_buffer.h"
    "include/miniav_capture.h"
    "include/miniav_types.h"
)

target_include_directories(miniav_c PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

# --- Platform-Specific Base Setup ---
if(MINIAV_PLATFORM_WINDOWS)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_WINDOWS")
    list(APPEND ALL_DEFINITIONS "MINIAV_BUILD_DLL")
    target_compile_definitions(miniav_c PUBLIC MINIAV_DLL)
    list(APPEND ALL_LINK_LIBS ole32 uuid shlwapi)
    
elseif(MINIAV_PLATFORM_MACOS)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_MACOS")
    list(APPEND ALL_LINK_LIBS
        "-framework Foundation"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework Metal"
        "-framework MetalKit"
        "-framework CoreGraphics")
    
elseif(MINIAV_PLATFORM_IOS)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_IOS")
    # Metal: camera + broadcast-ring zero-copy texture paths (UMA).
    list(APPEND ALL_LINK_LIBS
        "-framework Foundation"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework Metal"
        "-framework UIKit"
    )
    
elseif(MINIAV_PLATFORM_LINUX)
    find_package(PkgConfig REQUIRED)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_LINUX")
    list(APPEND ALL_LINK_LIBS pthread dl m)
    
elseif(MINIAV_PLATFORM_ANDROID)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_ANDROID")
    list(APPEND ALL_LINK_LIBS android log)
    
elseif(MINIAV_PLATFORM_WEB)
    list(APPEND ALL_DEFINITIONS "MINIAV_PLATFORM_WEB")
    # Enable miniaudio's AudioWorklet backend (runs the audio callback on a
    # dedicated Wasm Worker thread with a ~128-frame quantum ≈ 2.7ms, vs the
    # ScriptProcessorNode fallback's ~42ms). Requires the -sAUDIO_WORKLET /
    # -sWASM_WORKERS / -sASYNCIFY link flags below, and a cross-origin-isolated
    # host page (COOP/COEP) for SharedArrayBuffer.
    list(APPEND ALL_DEFINITIONS "MA_ENABLE_AUDIO_WORKLETS")
    # The objects must carry the atomics + bulk-memory target features or
    # wasm-ld refuses --shared-memory (which -sWASM_WORKERS enables at link).
    # This is the compile-time half of the shared-memory build; the audio ring's
    # ma_atomic ops lower to real wasm atomics over the SharedArrayBuffer heap.
    list(APPEND ALL_COMPILE_OPTIONS "-matomics" "-mbulk-memory")
endif()

# --- Audio Module (miniaudio) ---
if(MINIAV_ENABLE_AUDIO)
    message(STATUS "Audio module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_AUDIO_ENABLED")
    
    file(GLOB AUDIO_MODULE_SOURCES "src/audio/*.c" "src/audio/*.h")
    list(APPEND ALL_SOURCES ${AUDIO_MODULE_SOURCES})
    list(APPEND ALL_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio/miniaudio.c")
    list(APPEND ALL_HEADERS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio/miniaudio.h")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS
        "${CMAKE_CURRENT_SOURCE_DIR}/src/audio"
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio"
    )

    # Audio Output (playback sink) — first-party PCM sink on miniaudio's engine.
    # Shares miniaudio.c with capture; enabled on ALL platforms (incl. Web/WASM)
    # so the miniav audio sink works natively and in the browser.
    file(GLOB AUDIO_OUTPUT_SOURCES "src/audio_output/*.c" "src/audio_output/*.h")
    list(APPEND ALL_SOURCES ${AUDIO_OUTPUT_SOURCES})
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/audio_output")
    list(APPEND ALL_HEADERS "include/miniav_playback.h")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_AUDIO_OUTPUT_ENABLED")

    # Capture sets MA_NO_DECODING/MA_NO_ENCODING (no file codecs). That in turn
    # auto-defines MA_NO_RESOURCE_MANAGER inside miniaudio, which is fine: the
    # output module only uses ma_engine + a data-source sound, never file I/O.
    list(APPEND ALL_DEFINITIONS "MA_NO_DECODING" "MA_NO_ENCODING")

    # Platform-specific audio setup
    if(MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_IOS)
        list(APPEND ALL_LINK_LIBS "-framework CoreAudio" "-framework AudioToolbox")
    endif()
    if(MINIAV_PLATFORM_IOS)
        # AVAudioSession shim: record-capable category around miniaudio start/stop.
        list(APPEND ALL_SOURCES "src/audio/ios/miniav_avaudiosession_ios.m")
        list(APPEND ALL_LINK_LIBS "-framework AVFoundation")
    endif()
else()
    message(STATUS "Audio module disabled")
endif()

# --- Camera Module ---
if(MINIAV_ENABLE_CAMERA)
    message(STATUS "Camera module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_CAMERA_ENABLED")
    list(APPEND ALL_SOURCES "src/camera/camera_api.c")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/camera")

    if(MINIAV_PLATFORM_WINDOWS AND MINIAV_BACKEND_WIN_MF)
        message(STATUS "Windows: Enabling Media Foundation for camera")
        list(APPEND ALL_SOURCES "src/camera/windows/camera_context_win_mf.c")
        list(APPEND ALL_HEADERS "src/camera/windows/camera_context_win_mf.h")
        list(APPEND ALL_LINK_LIBS mfplat mf mfreadwrite mfuuid ksuser)
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_MF_CAMERA_ENABLED")
        
    elseif(MINIAV_PLATFORM_MACOS AND MINIAV_BACKEND_MACOS_AVF)
        message(STATUS "macOS: Enabling AVFoundation for camera")
        list(APPEND ALL_SOURCES "src/camera/macos/camera_context_macos_avf.mm")
        list(APPEND ALL_HEADERS "src/camera/macos/camera_context_macos_avf.h")
        list(APPEND ALL_LINK_LIBS "-framework AVFoundation")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_MACOS_AVF_CAMERA_ENABLED")
        
    elseif(MINIAV_PLATFORM_IOS AND MINIAV_BACKEND_IOS_AVF)
        message(STATUS "iOS: Enabling AVFoundation for camera")
        list(APPEND ALL_SOURCES "src/camera/ios/camera_context_ios_avf.mm")
        list(APPEND ALL_HEADERS "src/camera/ios/camera_context_ios_avf.h")
        list(APPEND ALL_LINK_LIBS "-framework AVFoundation")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_IOS_AVF_CAMERA_ENABLED")
        
    elseif(MINIAV_PLATFORM_LINUX)
        set(LINUX_CAMERA_BACKEND_FOUND FALSE)
        
        if(MINIAV_BACKEND_LINUX_PIPEWIRE_CAMERA)
            message(STATUS "Linux: Enabling PipeWire for camera")
            list(APPEND ALL_SOURCES "src/camera/linux/camera_context_linux_pipewire.c")
            list(APPEND ALL_HEADERS "src/camera/linux/camera_context_linux_pipewire.h")
            pkg_check_modules(PIPEWIRE_CAMERA REQUIRED libpipewire-0.3)
            list(APPEND ALL_LINK_LIBS ${PIPEWIRE_CAMERA_LIBRARIES})
            list(APPEND ALL_PRIVATE_INCLUDE_DIRS ${PIPEWIRE_CAMERA_INCLUDE_DIRS})
            list(APPEND ALL_DEFINITIONS ${PIPEWIRE_CAMERA_DEFINITIONS})
            list(APPEND ALL_COMPILE_OPTIONS ${PIPEWIRE_CAMERA_COMPILE_OPTIONS})
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_PIPEWIRE_CAMERA_ENABLED")
            set(LINUX_CAMERA_BACKEND_FOUND TRUE)
        endif()
        
        if(MINIAV_BACKEND_LINUX_V4L2_CAMERA)
            message(STATUS "Linux: Enabling V4L2 for camera")
            list(APPEND ALL_SOURCES "src/camera/linux/camera_context_linux_v4l2.c")
            list(APPEND ALL_HEADERS "src/camera/linux/camera_context_linux_v4l2.h")
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_V4L2_CAMERA_ENABLED")
            set(LINUX_CAMERA_BACKEND_FOUND TRUE)
        endif()
        
        if(NOT LINUX_CAMERA_BACKEND_FOUND)
            message(WARNING "Linux: No camera backend selected. Camera capture will not be available.")
        endif()
        
    elseif(MINIAV_PLATFORM_ANDROID)
        if(MINIAV_BACKEND_ANDROID_CAMERA2)
            message(STATUS "Android: Enabling Camera2 API for camera")
            list(APPEND ALL_SOURCES "src/camera/android/camera_context_android_camera2.c")
            list(APPEND ALL_HEADERS "src/camera/android/camera_context_android_camera2.h")
            list(APPEND ALL_LINK_LIBS camera2ndk mediandk)
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_ANDROID_CAMERA2_ENABLED")
        endif()
        
        if(MINIAV_BACKEND_ANDROID_NDK_CAMERA)
            message(STATUS "Android: Enabling NDK Camera API for camera")
            list(APPEND ALL_SOURCES "src/camera/android/camera_context_android_ndk.c")
            list(APPEND ALL_HEADERS "src/camera/android/camera_context_android_ndk.h")
            list(APPEND ALL_LINK_LIBS camera2ndk)
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_ANDROID_NDK_CAMERA_ENABLED")
        endif()
    endif()
else()
    message(STATUS "Camera module disabled")
endif()

# --- Screen Module ---
if(MINIAV_ENABLE_SCREEN)
    message(STATUS "Screen module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_SCREEN_ENABLED")
    list(APPEND ALL_SOURCES "src/screen/screen_api.c")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/screen")

    if(MINIAV_PLATFORM_WINDOWS)
        set(WIN_SCREEN_BACKEND_FOUND FALSE)
        
        if(MINIAV_BACKEND_WIN_WGC)
            message(STATUS "Windows: Enabling WGC for screen capture")
            list(APPEND ALL_SOURCES "src/screen/windows/screen_context_win_wgc.cpp")
            list(APPEND ALL_HEADERS "src/screen/windows/screen_context_win_wgc.h")
            list(APPEND ALL_LINK_LIBS d3d11 dxgi)
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_WGC_ENABLED")
            set(WIN_SCREEN_BACKEND_FOUND TRUE)
        endif()
        
        if(MINIAV_BACKEND_WIN_DXGI)
            message(STATUS "Windows: Enabling DXGI for screen capture")
            list(APPEND ALL_SOURCES "src/screen/windows/screen_context_win_dxgi.c")
            list(APPEND ALL_HEADERS "src/screen/windows/screen_context_win_dxgi.h")
            list(APPEND ALL_LINK_LIBS d3d11 dxgi)
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_DXGI_ENABLED")
            set(WIN_SCREEN_BACKEND_FOUND TRUE)
        endif()
        
        if(NOT WIN_SCREEN_BACKEND_FOUND)
            message(WARNING "Windows: No screen capture backend selected")
        endif()
        
    elseif(MINIAV_PLATFORM_MACOS)     
        if(MINIAV_BACKEND_MACOS_CG)
            message(STATUS "macOS: Enabling CoreGraphics for screen capture")
            list(APPEND ALL_SOURCES "src/screen/macos/screen_context_macos_cg.mm")
            list(APPEND ALL_HEADERS "src/screen/macos/screen_context_macos_cg.h")
            list(APPEND ALL_LINK_LIBS "-framework ScreenCaptureKit")
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_MACOS_CG_SCREEN_ENABLED")
        endif()
        
    elseif(MINIAV_PLATFORM_IOS AND MINIAV_BACKEND_IOS_REPLAYKIT)
        message(STATUS "iOS: Enabling ReplayKit for screen recording")
        list(APPEND ALL_SOURCES "src/screen/ios/screen_context_ios_replaykit.mm")
        list(APPEND ALL_HEADERS
            "src/screen/ios/screen_context_ios_replaykit.h"
            "src/screen/ios/miniav_broadcast_protocol.h")
        list(APPEND ALL_LINK_LIBS "-framework ReplayKit")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_IOS_REPLAYKIT_SCREEN_ENABLED")
        
    elseif(MINIAV_PLATFORM_LINUX)
        set(LINUX_SCREEN_BACKEND_FOUND FALSE)
        
        if(MINIAV_BACKEND_LINUX_PIPEWIRE_SCREEN)
            message(STATUS "Linux: Enabling PipeWire for screen capture")
            list(APPEND ALL_SOURCES "src/screen/linux/screen_context_linux_pipewire.c")
            list(APPEND ALL_HEADERS "src/screen/linux/screen_context_linux_pipewire.h")
            pkg_check_modules(PIPEWIRE_SCREEN REQUIRED libpipewire-0.3 gio-unix-2.0)
            list(APPEND ALL_LINK_LIBS ${PIPEWIRE_SCREEN_LIBRARIES})
            list(APPEND ALL_PRIVATE_INCLUDE_DIRS ${PIPEWIRE_SCREEN_INCLUDE_DIRS})
            list(APPEND ALL_DEFINITIONS ${PIPEWIRE_SCREEN_DEFINITIONS})
            list(APPEND ALL_COMPILE_OPTIONS ${PIPEWIRE_SCREEN_COMPILE_OPTIONS})
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_PIPEWIRE_SCREEN_ENABLED")
            set(LINUX_SCREEN_BACKEND_FOUND TRUE)
        endif()
        
        if(MINIAV_BACKEND_LINUX_X11_SCREEN)
            message(STATUS "Linux: Enabling X11 for screen capture")
            list(APPEND ALL_SOURCES "src/screen/linux/screen_context_linux_x11.c")
            list(APPEND ALL_HEADERS "src/screen/linux/screen_context_linux_x11.h")
            find_package(X11 REQUIRED)
            list(APPEND ALL_LINK_LIBS ${X11_LIBRARIES})
            list(APPEND ALL_PRIVATE_INCLUDE_DIRS ${X11_INCLUDE_DIRS})
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_X11_SCREEN_ENABLED")
            set(LINUX_SCREEN_BACKEND_FOUND TRUE)
        endif()
        
        if(NOT LINUX_SCREEN_BACKEND_FOUND)
            message(WARNING "Linux: No screen capture backend selected")
        endif()
        
    elseif(MINIAV_PLATFORM_ANDROID AND MINIAV_BACKEND_ANDROID_MEDIAPROJECTION)
        message(STATUS "Android: Enabling MediaProjection for screen capture")
        list(APPEND ALL_SOURCES "src/screen/android/screen_context_android_mediaprojection.c")
        list(APPEND ALL_HEADERS "src/screen/android/screen_context_android_mediaprojection.h")
        list(APPEND ALL_LINK_LIBS mediandk)
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_ANDROID_MEDIAPROJECTION_SCREEN_ENABLED")
    endif()
else()
    message(STATUS "Screen module disabled")
endif()

# --- Loopback Audio Module (Desktop Only) ---
if(MINIAV_ENABLE_LOOPBACK)
    message(STATUS "Loopback audio module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_LOOPBACK_ENABLED")
    list(APPEND ALL_SOURCES "src/loopback/loopback_api.c")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/loopback")

    if(MINIAV_PLATFORM_WINDOWS AND MINIAV_BACKEND_WIN_WASAPI)
        message(STATUS "Windows: Enabling WASAPI for loopback audio")
        list(APPEND ALL_SOURCES "src/loopback/windows/loopback_context_win_wasapi.c")
        list(APPEND ALL_HEADERS "src/loopback/windows/loopback_context_win_wasapi.h")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_WASAPI_LOOPBACK_ENABLED")
        
    elseif(MINIAV_PLATFORM_MACOS AND MINIAV_BACKEND_MACOS_COREAUDIO)
        message(STATUS "macOS: Enabling CoreAudio/AudioTaps for loopback audio")
        list(APPEND ALL_SOURCES "src/loopback/macos/loopback_context_macos_coreaudio.mm")
        list(APPEND ALL_HEADERS "src/loopback/macos/loopback_context_macos_coreaudio.h")
        list(APPEND ALL_LINK_LIBS "-framework AudioToolbox" "-framework CoreAudio")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_MACOS_COREAUDIO_LOOPBACK_ENABLED")
        
    elseif(MINIAV_PLATFORM_LINUX AND MINIAV_BACKEND_LINUX_PIPEWIRE_LOOPBACK)
        message(STATUS "Linux: Enabling PipeWire for loopback audio")
        list(APPEND ALL_SOURCES "src/loopback/linux/loopback_context_linux_pipewire.c")
        list(APPEND ALL_HEADERS "src/loopback/linux/loopback_context_linux_pipewire.h")
        pkg_check_modules(PIPEWIRE_LOOPBACK REQUIRED libpipewire-0.3)
        list(APPEND ALL_LINK_LIBS ${PIPEWIRE_LOOPBACK_LIBRARIES})
        list(APPEND ALL_PRIVATE_INCLUDE_DIRS ${PIPEWIRE_LOOPBACK_INCLUDE_DIRS})
        list(APPEND ALL_DEFINITIONS ${PIPEWIRE_LOOPBACK_DEFINITIONS})
        list(APPEND ALL_COMPILE_OPTIONS ${PIPEWIRE_LOOPBACK_COMPILE_OPTIONS})
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_PIPEWIRE_LOOPBACK_ENABLED")
    endif()
else()
    message(STATUS "Loopback audio module disabled")
endif()

# --- Input Capture Module (Desktop Only) ---
if(MINIAV_ENABLE_INPUT)
    message(STATUS "Input capture module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_INPUT_ENABLED")
    list(APPEND ALL_SOURCES "src/input/input_api.c")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/input")
    if(MINIAV_ENABLE_MOTION)
        # Desktop motion rides the input module: input_api.c (already listed
        # above) carries MiniAV_Input_GetLatestMotion + miniav_input_deliver_motion.
        # Desktop backends have no IMU, so they never call the deliver helper and
        # the pull API returns NOT_RUNNING — the symbols exist and link cleanly.
        list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_MOTION_ENABLED")
    endif()

    if(MINIAV_PLATFORM_WINDOWS AND MINIAV_BACKEND_WIN_HOOKS_XINPUT)
        message(STATUS "Windows: Enabling low-level hooks + XInput for input capture")
        list(APPEND ALL_SOURCES "src/input/windows/input_context_win_rawinput.c")
        list(APPEND ALL_HEADERS "src/input/windows/input_context_win_rawinput.h")
        list(APPEND ALL_LINK_LIBS user32 xinput)
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_HOOKS_XINPUT_ENABLED")
    elseif(MINIAV_PLATFORM_LINUX)
        message(STATUS "Linux: Enabling evdev input capture (keyboard/mouse/gamepad)")
        list(APPEND ALL_SOURCES "src/input/linux/input_context_linux_evdev.c")
        list(APPEND ALL_HEADERS "src/input/linux/input_context_linux_evdev.h")
        # Pure /dev/input/event* + libudev-free evdev; no extra link libs.
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_EVDEV_ENABLED")
    elseif(MINIAV_PLATFORM_MACOS)
        message(STATUS "macOS: Enabling CGEventTap + IOKit input capture")
        list(APPEND ALL_SOURCES "src/input/macos/input_context_macos_cgtap.mm")
        list(APPEND ALL_HEADERS "src/input/macos/input_context_macos_cgtap.h")
        list(APPEND ALL_LINK_LIBS "-framework ApplicationServices" "-framework GameController" "-framework Foundation")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_MACOS_CGTAP_ENABLED")
    endif()
else()
    message(STATUS "Input capture module disabled")

    # --- Motion / IMU Module (Mobile) ---
    # On mobile, keyboard/mouse/gamepad capture is off but MOTION is first-class.
    # It reuses the same input context/API layer (input_api.c) with a mobile IMU
    # backend that calls miniav_input_deliver_motion() per sample. The backend
    # source + the input_context.h / input_api.c backend-table branch for this
    # platform are delivered alongside the native backend (see
    # INPUT_LAYER_PLAN.md §5); this block is the CMake seam they extend:
    #
    #   iOS      : src/input/ios/motion_context_ios_coremotion.m
    #              frameworks: CoreMotion, Foundation
    #   Android  : src/input/android/motion_context_android_sensor.c (+ JNI)
    #              link: android, log
    #
    # Uncommented by those PRs; until then mobile motion is a no-op surface.
    if(MINIAV_ENABLE_MOTION AND (MINIAV_PLATFORM_IOS OR MINIAV_PLATFORM_ANDROID))
        list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_MOTION_ENABLED")
        list(APPEND ALL_SOURCES "src/input/input_api.c")
        list(APPEND ALL_HEADERS "src/input/input_context.h")
        list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/input")

        if(MINIAV_PLATFORM_IOS)
            message(STATUS "iOS: Enabling CoreMotion for motion/IMU capture")
            list(APPEND ALL_SOURCES "src/input/ios/motion_context_ios_coremotion.m")
            list(APPEND ALL_HEADERS "src/input/ios/motion_context_ios_coremotion.h")
            # Foundation + UIKit are also in the iOS base link set; repeating a
            # -framework flag is harmless. CoreMotion is the new dependency.
            list(APPEND ALL_LINK_LIBS
                "-framework CoreMotion"
                "-framework Foundation"
                "-framework UIKit")
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_IOS_COREMOTION_ENABLED")
        else()
            message(STATUS "Android: Enabling ASensorManager (NDK) for motion/IMU capture")
            list(APPEND ALL_SOURCES "src/input/android/motion_context_android_sensor.c")
            list(APPEND ALL_HEADERS "src/input/android/motion_context_android_sensor.h")
            # ASensorManager + ALooper live in libandroid; libandroid + liblog are
            # already in the Android base link set (see the platform base setup).
            # libm is the only addition (quaternion sin/cos/sqrt for the screen
            # remap). The backend uses NO JNI on the hot path (display rotation is
            # pushed in from the Flutter host via MiniAV_Input_SetAndroidDisplayRotation
            # — see MOTION_ANDROID_NOTES.md).
            list(APPEND ALL_LINK_LIBS m)
            list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_ANDROID_SENSOR_MOTION_ENABLED")
        endif()
    endif()
endif()

# --- Input Injection Module (Desktop Only) ---
if(MINIAV_ENABLE_INJECT)
    message(STATUS "Input injection module enabled")
    list(APPEND ALL_DEFINITIONS "MINIAV_MODULE_INJECT_ENABLED")
    list(APPEND ALL_SOURCES "src/inject/inject_api.c")
    list(APPEND ALL_PRIVATE_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src/inject")

    if(MINIAV_PLATFORM_WINDOWS)
        message(STATUS "Windows: Enabling SendInput for input injection")
        list(APPEND ALL_SOURCES "src/inject/windows/inject_context_win_sendinput.c")
        list(APPEND ALL_HEADERS "src/inject/windows/inject_context_win_sendinput.h")
        list(APPEND ALL_LINK_LIBS user32)
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_WIN_SENDINPUT_ENABLED")
    elseif(MINIAV_PLATFORM_LINUX)
        message(STATUS "Linux: Enabling uinput for input injection")
        list(APPEND ALL_SOURCES "src/inject/linux/inject_context_linux_uinput.c")
        list(APPEND ALL_HEADERS "src/inject/linux/inject_context_linux_uinput.h")
        # Pure /dev/uinput; no extra link libs.
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_LINUX_UINPUT_ENABLED")
    elseif(MINIAV_PLATFORM_MACOS)
        message(STATUS "macOS: Enabling CGEventPost for input injection")
        list(APPEND ALL_SOURCES "src/inject/macos/inject_context_macos_cgevent.mm")
        list(APPEND ALL_HEADERS "src/inject/macos/inject_context_macos_cgevent.h")
        list(APPEND ALL_LINK_LIBS "-framework ApplicationServices" "-framework Foundation")
        list(APPEND ALL_DEFINITIONS "MINIAV_BACKEND_MACOS_CGEVENT_ENABLED")
    endif()
else()
    message(STATUS "Input injection module disabled")
endif()

# --- Android-specific Setup ---
if(MINIAV_PLATFORM_ANDROID)
    # Android NDK API level. libcamera2ndk.so only exists from API 24, so the
    # link floor for the camera backend is 24 (runtime gates handle the rest).
    if(NOT ANDROID_NATIVE_API_LEVEL)
        set(ANDROID_NATIVE_API_LEVEL 24)
    endif()
    
    list(APPEND ALL_DEFINITIONS "MINIAV_ANDROID_API_LEVEL=${ANDROID_NATIVE_API_LEVEL}")

    # Keep the link floor at 24 while calling 26+ APIs (AHardwareBuffer,
    # ANativeWindow_toSurface) behind runtime android_get_device_api_level()
    # gates: NDK r26+ turns above-minSdk symbols into weak references with
    # this define instead of hard compile errors.
    list(APPEND ALL_DEFINITIONS "__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__")
    
    # JNI support for accessing Java APIs
    find_library(ANDROID_JNI_LIB jnigraphics)
    if(ANDROID_JNI_LIB)
        list(APPEND ALL_LINK_LIBS ${ANDROID_JNI_LIB})
    endif()
endif()

# --- Apply all collected settings to the target ---
target_sources(miniav_c PRIVATE ${ALL_SOURCES} ${ALL_HEADERS})
target_include_directories(miniav_c PRIVATE ${ALL_PRIVATE_INCLUDE_DIRS})
target_compile_definitions(miniav_c PRIVATE ${ALL_DEFINITIONS})
target_compile_options(miniav_c PRIVATE ${ALL_COMPILE_OPTIONS})
target_link_libraries(miniav_c PRIVATE ${ALL_LINK_LIBS})

# --- Installation ---
include(GNUInstallDirs)
install(TARGETS miniav_c
    EXPORT miniav_cTargets
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY include/
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
    FILES_MATCHING PATTERN "*.h"
)

# --- Test Executables (Desktop Only) ---
if(MINIAV_PLATFORM_WINDOWS OR MINIAV_PLATFORM_MACOS OR MINIAV_PLATFORM_LINUX)
    set(TEST_INCLUDE_DIRS
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )

    if(MINIAV_ENABLE_AUDIO)
        add_executable(test_audio_capture src/audio/test/test_audio_capture.c)
        target_link_libraries(test_audio_capture PRIVATE miniav_c)
        target_include_directories(test_audio_capture PRIVATE ${TEST_INCLUDE_DIRS})
        if(MINIAV_PLATFORM_WINDOWS)
            target_link_libraries(test_audio_capture PRIVATE ole32 user32)
        endif()

        add_executable(test_audio_output src/audio_output/test/test_audio_output.c)
        target_link_libraries(test_audio_output PRIVATE miniav_c)
        target_include_directories(test_audio_output PRIVATE ${TEST_INCLUDE_DIRS})
        if(MINIAV_PLATFORM_WINDOWS)
            target_link_libraries(test_audio_output PRIVATE ole32 user32)
        endif()
    endif()

    if(MINIAV_ENABLE_CAMERA)
        add_executable(test_camera_capture src/camera/test/test_camera_capture.c)
        target_link_libraries(test_camera_capture PRIVATE miniav_c)
        target_include_directories(test_camera_capture PRIVATE ${TEST_INCLUDE_DIRS})
    endif()

    if(MINIAV_ENABLE_SCREEN)
        add_executable(test_screen_capture src/screen/test/test_screen_capture.c)
        target_link_libraries(test_screen_capture PRIVATE miniav_c)
        target_include_directories(test_screen_capture PRIVATE ${TEST_INCLUDE_DIRS})
    endif()

    if(MINIAV_ENABLE_LOOPBACK)
        add_executable(test_loopback_capture src/loopback/test/test_loopback_capture.c)
        target_link_libraries(test_loopback_capture PRIVATE miniav_c)
        target_include_directories(test_loopback_capture PRIVATE ${TEST_INCLUDE_DIRS})
    endif()

    if(MINIAV_ENABLE_INPUT)
        add_executable(test_input_capture src/input/test/test_input_capture.c)
        target_link_libraries(test_input_capture PRIVATE miniav_c)
        target_include_directories(test_input_capture PRIVATE ${TEST_INCLUDE_DIRS})
        if(MINIAV_PLATFORM_WINDOWS)
            target_link_libraries(test_input_capture PRIVATE user32 xinput)
        endif()
    endif()
else()
    message(STATUS "Test executables disabled on ${MINIAV_PLATFORM_NAME}")
endif()

# --- Configuration Summary ---
message(STATUS "")
message(STATUS "=== MiniAV Configuration Summary ===")
message(STATUS "Platform: ${MINIAV_PLATFORM_NAME}")
message(STATUS "")
message(STATUS "Enabled Modules:")
if(MINIAV_ENABLE_AUDIO)    
    message(STATUS "  ✓ Audio") 
else()
    message(STATUS "  ✗ Audio")
endif()
if(MINIAV_ENABLE_CAMERA)   
    message(STATUS "  ✓ Camera") 
else()
    message(STATUS "  ✗ Camera")
endif()
if(MINIAV_ENABLE_SCREEN)   
    message(STATUS "  ✓ Screen") 
else()
    message(STATUS "  ✗ Screen")
endif()
if(MINIAV_ENABLE_LOOPBACK) 
    message(STATUS "  ✓ Loopback Audio") 
else()
    message(STATUS "  ✗ Loopback Audio")
endif()

message(STATUS "")
message(STATUS "Active Backends:")
foreach(def ${ALL_DEFINITIONS})
    if(def MATCHES "MINIAV_BACKEND_.*_ENABLED")
        string(REGEX REPLACE "MINIAV_BACKEND_(.*)_ENABLED" "\\1" backend_name ${def})
        string(REPLACE "_" " " backend_name_clean ${backend_name})
        message(STATUS "  ✓ ${backend_name_clean}")
    endif()
endforeach()

message(STATUS "")
message(STATUS "Build Configuration:")
message(STATUS "  Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  C Standard: C${CMAKE_C_STANDARD}")
message(STATUS "  CXX Standard: C++${CMAKE_CXX_STANDARD}")
if(MINIAV_PLATFORM_ANDROID)
    message(STATUS "  Android API Level: ${ANDROID_NATIVE_API_LEVEL}")
endif()

message(STATUS "")
message(STATUS "=====================================")