cmake_minimum_required(VERSION 3.10)

# Options
option(OPUS_USE_SYSTEM "Prefer a system-installed libopus if available" ON)
set(OPUS_VERSION "1.5.2" CACHE STRING "libopus version to fetch when not using system")
set(OPUS_DISABLE_INTRINSICS ON CACHE STRING "Disable opus SIMD/intrinsics (safer for cross/wasm)" FORCE)

set(_OPUS_DL_DIR "${CMAKE_CURRENT_BINARY_DIR}/_deps")
set(_OPUS_TARBALL "${_OPUS_DL_DIR}/opus-${OPUS_VERSION}.tar.gz")
set(_OPUS_SRC_DIR "${_OPUS_DL_DIR}/opus-${OPUS_VERSION}")

set(OPUS_FOUND FALSE)

# Try system first
if(OPUS_USE_SYSTEM)
    find_path(OPUS_INCLUDE_DIR opus/opus.h)
    find_library(OPUS_LIBRARY NAMES opus)
    if(OPUS_INCLUDE_DIR AND OPUS_LIBRARY)
        add_library(opus::opus UNKNOWN IMPORTED)
        set_target_properties(opus::opus PROPERTIES
            IMPORTED_LOCATION "${OPUS_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${OPUS_INCLUDE_DIR}")
        set(OPUS_FOUND TRUE)
        message(STATUS "Found system libopus: ${OPUS_LIBRARY}")
    endif()
endif()

if(NOT OPUS_FOUND)
    file(MAKE_DIRECTORY "${_OPUS_DL_DIR}")
    if(NOT EXISTS "${_OPUS_TARBALL}")
        message(STATUS "Downloading libopus v${OPUS_VERSION}")
        file(DOWNLOAD
            "https://github.com/xiph/opus/archive/refs/tags/v${OPUS_VERSION}.tar.gz"
            "${_OPUS_TARBALL}"
            SHOW_PROGRESS
            STATUS _dl_status
        )
        list(GET _dl_status 0 _dl_code)
        if(NOT _dl_code EQUAL 0)
            message(FATAL_ERROR "Download of libopus failed: ${_dl_status}")
        endif()
    endif()
    if(NOT EXISTS "${_OPUS_SRC_DIR}")
        message(STATUS "Extracting libopus")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar xzf "${_OPUS_TARBALL}"
            WORKING_DIRECTORY "${_OPUS_DL_DIR}"
            RESULT_VARIABLE _ext_res
        )
        if(NOT _ext_res EQUAL 0)
            message(FATAL_ERROR "Extraction of libopus failed")
        endif()
    endif()

    # Collect sources (full standard subset; excludes tests, bench, examples)
    file(GLOB OPUS_TOP_SRC   "${_OPUS_SRC_DIR}/src/*.c")
    file(GLOB OPUS_CELT_SRC  "${_OPUS_SRC_DIR}/celt/*.c")
    file(GLOB OPUS_SILK_SRC  "${_OPUS_SRC_DIR}/silk/*.c" "${_OPUS_SRC_DIR}/silk/float/*.c")

    # Remove arch-specific sources for non-native (wasm) builds to avoid armcpu.h, x86 headers, etc.
    if(EMSCRIPTEN)
        foreach(_lst OPUS_CELT_SRC OPUS_SILK_SRC)
            list(FILTER ${_lst} EXCLUDE REGEX "/(celt|silk)/arm/")
            list(FILTER ${_lst} EXCLUDE REGEX "/(celt|silk)/x86/")
            list(FILTER ${_lst} EXCLUDE REGEX "/(celt|silk)/mips/")
            set(${_lst} "${${_lst}}")
        endforeach()
    endif()

    add_library(opus STATIC
        ${OPUS_TOP_SRC}
        ${OPUS_CELT_SRC}
        ${OPUS_SILK_SRC}
    )

    set_target_properties(opus PROPERTIES POSITION_INDEPENDENT_CODE ON)

    target_include_directories(opus PUBLIC
        "${_OPUS_SRC_DIR}/include"
    )
    target_include_directories(opus PRIVATE
        "${_OPUS_SRC_DIR}"
        "${_OPUS_SRC_DIR}/celt"
        "${_OPUS_SRC_DIR}/silk"
        "${_OPUS_SRC_DIR}/silk/float"
    )

    target_compile_definitions(opus PRIVATE OPUS_BUILD)

    if(MSVC)
        target_compile_definitions(opus PRIVATE NONTHREADSAFE_PSEUDOSTACK)
    else()
        target_compile_definitions(opus PRIVATE VAR_ARRAYS)
    endif()

    # Generic (no SIMD / no RTCD) toggle
    if(EMSCRIPTEN OR OPUS_DISABLE_INTRINSICS)
        target_compile_definitions(opus PRIVATE OPUS_HAVE_RTCD=0)
        # IMPORTANT: do NOT define any OPUS_ARM_* or OPUS_X86_* macros at all.
    endif()

    if(EMSCRIPTEN)
        # Ensure we did not leak prior defines (in case of cache)
        target_compile_options(opus PRIVATE
            $<$<COMPILE_LANGUAGE:C>:-UOPUS_ARM_ASM -UOPUS_ARM_INLINE_ASM -UOPUS_ARM_NEON_INTR -UOPUS_X86_MAY_HAVE_SSE -UOPUS_X86_MAY_HAVE_SSE2 -UOPUS_X86_MAY_HAVE_SSE4_1 -UOPUS_X86_MAY_HAVE_AVX -UOPUS_X86_MAY_HAVE_AVX2>
        )
    endif()

    if(MSVC)
        target_compile_definitions(opus PRIVATE _CRT_SECURE_NO_WARNINGS)
    else()
        target_compile_options(opus PRIVATE -w)
    endif()

    add_library(opus::opus ALIAS opus)
    set(OPUS_FOUND TRUE)
    set(OPUS_INCLUDE_DIR "${_OPUS_SRC_DIR}/include" CACHE INTERNAL "")
    message(STATUS "Bundled libopus built (v${OPUS_VERSION})")
endif()

# Export helpful vars
set(HAVE_OPUS ${OPUS_FOUND} CACHE INTERNAL "Whether opus is available")
