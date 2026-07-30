cmake_minimum_required(VERSION 3.15)
project(miniav_tools_codecs_native C)

# First-party, FFmpeg-FREE native codecs for miniav_tools_codecs:
#   - opus_decode.c : libopus (static, built from source by cmake/opus.cmake)
#   - mf_decoder.c  : Windows Media Foundation H.264/HEVC → D3D11 NV12 decode
#                     (added in phase 2; self-guarded by `#if defined(_WIN32)`)
# This library links NO avcodec/avutil/avformat — that is what makes the
# MF-video + Opus-audio decode path genuinely FFmpeg-independent.

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/opus.cmake)

if(EMSCRIPTEN)
  # --- Web (WASM): the GENERAL miniav_codecs module -------------------------
  # The web twin of miniav_tools_codecs_native. Opus is the first codec exposed;
  # add more PORTABLE codec sources here over time (dr_mp3/dr_flac/stb_vorbis are
  # portable and could join later). Windows-only Media Foundation sources are
  # excluded. Emitted as a MODULARIZE factory (EXPORT_NAME=MiniavCodecs) so it
  # coexists with miniav_web's own Emscripten module (which uses a global
  # `Module`). The miniav_opus_* symbols are retained/exported via
  # EMSCRIPTEN_KEEPALIVE (MOPUS_API). Pure synchronous opus_encode/decode → no
  # ASYNCIFY / AudioWorklet / shared memory, so NO crossOriginIsolated needed.
  add_executable(miniav_codecs opus_decode.c)
  set_target_properties(miniav_codecs PROPERTIES
    C_STANDARD 11
    OUTPUT_NAME "miniav_codecs")
  target_compile_definitions(miniav_codecs PRIVATE HAVE_OPUS=1)
  target_link_libraries(miniav_codecs PRIVATE opus::opus)
  target_link_options(miniav_codecs PRIVATE
    "-O3"
    "--no-entry"
    "-sENVIRONMENT=web,worker"
    "-sMALLOC=emmalloc"
    "-sMODULARIZE=1"
    "-sEXPORT_NAME=MiniavCodecs"
    "-sEXPORTED_FUNCTIONS=_malloc,_free"
    "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAP8,HEAPU8,HEAP32,HEAPU32,HEAPF32"
    "-sALLOW_MEMORY_GROWTH=1"
    "-sINITIAL_MEMORY=16MB"
    "-sMAXIMUM_MEMORY=256MB"
    "-sSTACK_SIZE=1MB"
    "-sEXIT_RUNTIME=0"
    "-sWASM_BIGINT=1")
else()
  # mf_decoder.c is Windows-only (guarded by `#if defined(_WIN32)`); it compiles
  # to an empty TU on other platforms, so it can always be listed.
  # mp3/flac/vorbis: public-domain single-header decoders (dr_mp3, dr_flac,
  # stb_vorbis) vendored under third_party/ — FFmpeg-free SW audio decode.
  # frame_convert.c: pure-C YUV(I420/NV12)->RGBA for the player's cross-platform
  # CPU present fallback (no platform APIs — compiles everywhere).
  add_library(miniav_tools_codecs_native SHARED
    opus_decode.c
    mf_decoder.c
    mf_aac.c
    mf_encoder.c
    mp3_decode.c
    flac_decode.c
    vorbis_decode.c
    frame_convert.c
  )
  set_target_properties(miniav_tools_codecs_native PROPERTIES C_STANDARD 11)

  target_compile_definitions(miniav_tools_codecs_native PRIVATE HAVE_OPUS=1)
  target_link_libraries(miniav_tools_codecs_native PRIVATE opus::opus)

  # Hide internal symbols on POSIX (matches the dllexport visibility on Windows).
  if(NOT WIN32)
    target_compile_options(miniav_tools_codecs_native PRIVATE -fvisibility=hidden)
  endif()

  # --- Per-OS link matrix (P3.1) ---------------------------------------------
  # Linux/Android: dr_mp3/dr_flac/stb_vorbis use libm math functions; glibc and
  # bionic do NOT auto-link m into shared libraries. Apple's libSystem bundles
  # the math functions (no extra link); Windows gets them from the CRT. The
  # Windows-only sources (mf_*.c) compile to empty TUs elsewhere, so the source
  # list is identical on every OS.
  if(UNIX AND NOT APPLE)
    target_link_libraries(miniav_tools_codecs_native PRIVATE m)
  endif()
  # Android needs nothing further today (no NDK log/jni use). This is the seam
  # for future Android-only backends (e.g. MediaCodec via mediandk).

  # --- Windows: Media Foundation + D3D11 (mf_decoder.c) ----------------------
  # mfplat/mfuuid for the hardware H.264/HEVC decode MFT; d3d11/dxgi/dxguid for
  # the D3D11 NV12 texture + shared-handle export; ole32 for CoInitializeEx. NO
  # avcodec/avutil/avformat — this is the FFmpeg-free path.
  if(WIN32)
    target_compile_definitions(miniav_tools_codecs_native PRIVATE WIN32_LEAN_AND_MEAN)
    target_link_libraries(miniav_tools_codecs_native PRIVATE
      d3d11 dxguid dxgi ole32 mfplat mfuuid)
  endif()
endif()
