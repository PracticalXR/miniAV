# Builds the tiny miniav_flutter JNI shim (libminiav_flutter_jni.so).
#
# This library has NO link-time dependency on miniav_c: it resolves
# MiniAV_Screen_SetAndroidMediaProjection from libminiav_c.so at runtime via
# dlopen/dlsym (that library is built and packaged by miniav_ffi's native-assets
# hook, not by this Gradle plugin). We only need the NDK's log/dl libs.

cmake_minimum_required(VERSION 3.18)

project(miniav_flutter_jni C)

add_library(miniav_flutter_jni SHARED
    miniav_flutter_jni.c)

# libdl (dlopen/dlsym) is part of libc on Android, but link it explicitly for
# clarity / older NDK compatibility. The JNI headers ship with the NDK toolchain.
find_library(log-lib log)

target_link_libraries(miniav_flutter_jni
    ${log-lib})
