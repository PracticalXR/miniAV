cmake_minimum_required(VERSION 3.15)
project(miniav_tools_ffmpeg_shim C)

# Required cache entries supplied by hook/build.dart:
#   FFMPEG_INCLUDE_DIR  → contains libavcodec/, libavutil/, ...
#   FFMPEG_LIB_DIR      → contains avcodec.lib / libavcodec.so / etc.
set(FFMPEG_INCLUDE_DIR "" CACHE PATH "FFmpeg headers root")
set(FFMPEG_LIB_DIR     "" CACHE PATH "FFmpeg import-libs / shared-libs root")

if(NOT FFMPEG_INCLUDE_DIR OR NOT FFMPEG_LIB_DIR)
  message(FATAL_ERROR "FFMPEG_INCLUDE_DIR and FFMPEG_LIB_DIR must be set")
endif()

add_library(miniav_tools_ffmpeg_shim SHARED shim.c)
set_target_properties(miniav_tools_ffmpeg_shim PROPERTIES C_STANDARD 11)

target_include_directories(miniav_tools_ffmpeg_shim PRIVATE "${FFMPEG_INCLUDE_DIR}")
target_link_directories(miniav_tools_ffmpeg_shim PRIVATE "${FFMPEG_LIB_DIR}")
# avformat: demux open/byte-pipe helpers (shim ABI v15+).
target_link_libraries(miniav_tools_ffmpeg_shim PRIVATE avcodec avutil avformat)

# Hide internal symbols on POSIX (matches MIO_API visibility on Windows).
if(NOT WIN32)
  target_compile_options(miniav_tools_ffmpeg_shim PRIVATE -fvisibility=hidden)
endif()

if(WIN32)
  # The shim uses ID3D11Device from <d3d11.h>; SDK is on the toolchain
  # include path automatically when invoked through native_toolchain_cmake.
  target_compile_definitions(miniav_tools_ffmpeg_shim PRIVATE WIN32_LEAN_AND_MEAN)
  # d3d11.lib for OpenSharedResource1 / CopyResource; dxguid.lib for
  # IID_ID3D11Device1 / IID_ID3D11Texture2D linked via DEFINE_GUID;
  # dxgi.lib for IDXGIResource1 (test helpers); ole32.lib for
  # CoInitializeEx (apartment management for QSV / MediaFoundation encode).
  # (The MF hardware DECODER moved to miniav_tools_codecs — no mfplat/mfuuid.)
  target_link_libraries(miniav_tools_ffmpeg_shim PRIVATE d3d11 dxguid dxgi ole32)
endif()

# --- macOS / iOS: VideoToolbox interop --------------------------------------
# CoreVideo for CVPixelBuffer; CoreFoundation for CFRetain/Release;
# IOSurface for the shared GPU surface; VideoToolbox is pulled in by the
# FFmpeg headers but listed here so the linker is explicit.
if(APPLE)
  find_library(COREVIDEO_FRAMEWORK    CoreVideo)
  find_library(COREFOUNDATION_FRAMEWORK CoreFoundation)
  find_library(IOSURFACE_FRAMEWORK    IOSurface)
  find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox)
  target_link_libraries(miniav_tools_ffmpeg_shim PRIVATE
    "${COREVIDEO_FRAMEWORK}"
    "${COREFOUNDATION_FRAMEWORK}"
    "${IOSURFACE_FRAMEWORK}"
    "${VIDEOTOOLBOX_FRAMEWORK}")
endif()

# --- Linux (non-Android): VAAPI / DRM-PRIME ---------------------------------
# We only need the FFmpeg-side symbols (av_hwframe_map etc.) which already
# come from libavutil. libva itself is loaded indirectly through libavutil.
# Nothing extra to link here — the headers (hwcontext_vaapi.h /
# hwcontext_drm.h) are part of the FFmpeg dev install.
if(UNIX AND NOT APPLE AND NOT ANDROID)
  # Make sure the linker finds libavutil's vaapi symbols when the host
  # FFmpeg was built with --enable-vaapi (BtbN lgpl-shared is).
  # No additional libs; left as a section anchor for future flags.
endif()

# --- Android: AHardwareBuffer interop ---------------------------------------
# AHardwareBuffer + AHardwareBuffer_lock live in libandroid (API 26+).
if(ANDROID)
  target_link_libraries(miniav_tools_ffmpeg_shim PRIVATE android log)
  # Require API 26 for AHardwareBuffer_lock; native_toolchain_cmake sets
  # ANDROID_PLATFORM via the input target, but enforce a floor here so a
  # too-old toolchain fails loudly rather than at runtime.
  if(DEFINED ANDROID_PLATFORM_LEVEL AND ANDROID_PLATFORM_LEVEL LESS 26)
    message(FATAL_ERROR
      "miniav_tools_ffmpeg shim requires Android API >= 26 "
      "(AHardwareBuffer_lock); have ${ANDROID_PLATFORM_LEVEL}.")
  endif()
endif()
