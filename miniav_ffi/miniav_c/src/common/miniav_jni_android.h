// Android JNI plumbing shared by JNI-needing backends. See the .c for the
// dlopen-vs-System.loadLibrary caveat: the JavaVM* set explicitly through
// the public C API is authoritative; JNI_OnLoad is best-effort.
#ifndef MINIAV_JNI_ANDROID_H
#define MINIAV_JNI_ANDROID_H

#if defined(__ANDROID__)

#include "../../include/miniav_types.h"
#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

// Store the process JavaVM (idempotent; NULL ignored).
void miniav_android_set_jvm(JavaVM *vm);
// NULL until set via JNI_OnLoad or miniav_android_set_jvm.
JavaVM *miniav_android_get_jvm(void);

// Get a JNIEnv for the CURRENT thread, attaching it if needed.
// *did_attach_out = 1 means the caller must call miniav_android_detach_env()
// on the SAME thread before it exits (long-lived capture threads should
// attach once at thread start and detach at thread end, not per call).
MiniAVResultCode miniav_android_attach_env(JNIEnv **env_out,
                                           int *did_attach_out);
void miniav_android_detach_env(void);

#ifdef __cplusplus
}
#endif

#endif // __ANDROID__
#endif // MINIAV_JNI_ANDROID_H
