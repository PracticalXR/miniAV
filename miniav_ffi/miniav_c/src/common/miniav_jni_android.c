// Android JNI plumbing shared by JNI-needing backends (MediaProjection
// screen capture; future AudioPlaybackCapture loopback).
//
// The whole file is Android-only but lives in src/common (which is globbed
// on every platform), so its content is fenced by __ANDROID__.
//
// IMPORTANT loading caveat: Dart FFI loads this .so via dlopen, which does
// NOT invoke JNI_OnLoad (only Java's System.loadLibrary does). JNI_OnLoad is
// kept as a best-effort cache for embedders that DO load through Java, but
// the authoritative JavaVM* is the one the app passes through
// MiniAV_Screen_SetAndroidMediaProjection — backends must treat
// miniav_android_set_jvm() as the primary source.
#if defined(__ANDROID__)

#include "miniav_jni_android.h"
#include "miniav_logging.h"

#include <stdatomic.h>

static _Atomic(JavaVM *) g_miniav_jvm = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  atomic_store(&g_miniav_jvm, vm);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "JNI_OnLoad: JavaVM cached.");
  return JNI_VERSION_1_6;
}

void miniav_android_set_jvm(JavaVM *vm) {
  if (vm) {
    atomic_store(&g_miniav_jvm, vm);
  }
}

JavaVM *miniav_android_get_jvm(void) { return atomic_load(&g_miniav_jvm); }

MiniAVResultCode miniav_android_attach_env(JNIEnv **env_out,
                                           int *did_attach_out) {
  if (!env_out || !did_attach_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *env_out = NULL;
  *did_attach_out = 0;
  JavaVM *vm = atomic_load(&g_miniav_jvm);
  if (!vm) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "JNI: no JavaVM — call MiniAV_Screen_SetAndroidMediaProjection "
               "(or load via System.loadLibrary) first.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  JNIEnv *env = NULL;
  jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
  if (rc == JNI_OK) {
    *env_out = env;
    return MINIAV_SUCCESS;
  }
  if (rc == JNI_EDETACHED) {
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) == JNI_OK) {
      *env_out = env;
      *did_attach_out = 1; // caller must miniav_android_detach_env()
      return MINIAV_SUCCESS;
    }
  }
  miniav_log(MINIAV_LOG_LEVEL_ERROR, "JNI: GetEnv/AttachCurrentThread failed (%d).",
             (int)rc);
  return MINIAV_ERROR_SYSTEM_CALL_FAILED;
}

void miniav_android_detach_env(void) {
  JavaVM *vm = atomic_load(&g_miniav_jvm);
  if (vm) {
    (*vm)->DetachCurrentThread(vm);
  }
}

#endif // __ANDROID__
