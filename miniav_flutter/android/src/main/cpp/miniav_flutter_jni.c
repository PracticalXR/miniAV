// miniav_flutter JNI shim.
//
// The one native bridge the Flutter consent helper needs: take the app-obtained
// android.media.projection.MediaProjection (from the consent Intent) plus the
// process JavaVM*, and forward them to the pure-FFI native layer via
//   MiniAV_Screen_SetAndroidMediaProjection(void* jvm, void* media_projection)
// (contract in miniav_c/include/miniav_capture.h §"Mobile screen-capture seams":
//  the app passes a JavaVM* and a GLOBAL-REF MediaProjection jobject; ownership
//  of the global ref transfers to native).
//
// This shim lives in the PLUGIN's own native code so miniav_c stays untouched.
// It resolves the C symbol from libminiav_c.so at runtime (dlopen RTLD_NOLOAD
// first — the library is already loaded by the Dart native-assets runtime — then
// a normal dlopen fallback) and dlsym'd, so there is no link-time dependency on
// miniav_c (which is built and packaged by miniav_ffi, not this plugin).
//
// Binding strategy: we export the correctly-mangled JNI symbol AND also perform
// RegisterNatives from JNI_OnLoad as a belt-and-suspenders fallback.
//   * The Kotlin side declares `nativeSetMediaProjection` as a
//     `@JvmStatic external fun` inside a `companion object`. The `@JvmStatic`
//     annotation *lifts* the method onto the enclosing class: Kotlin emits the
//     actual `native` method as a `static native` on the OUTER class
//     (MiniavFlutterPlugin), NOT on $Companion (which keeps only a non-native
//     delegate). The mangled symbol is therefore
//     Java_com_practicalxr_miniav_1flutter_MiniavFlutterPlugin_nativeSetMediaProjection
//     ('_' -> "_1"; there is no '$' in the path because the method is on the
//     outer class). Because it is a static method the JNI receiver is a jclass.
//     The VM resolves this lazily using the declaring class's own classloader
//     (the app classloader), which avoids the classic JNI_OnLoad+FindClass
//     system-classloader pitfall.
//   * RegisterNatives is attempted too for robustness against future
//     compiler/name changes; it is best-effort and its failure is non-fatal.

#include <jni.h>
#include <dlfcn.h>
#include <stddef.h>

// Signature of the C seam we call. Kept local so we don't need miniav_c headers.
typedef int (*MiniAV_Screen_SetAndroidMediaProjection_fn)(void *jvm,
                                                          void *media_projection);

// Cached process JavaVM*, captured in JNI_OnLoad.
static JavaVM *g_jvm = NULL;

// Resolves MiniAV_Screen_SetAndroidMediaProjection from libminiav_c.so.
// Returns NULL if the symbol / library cannot be found.
static MiniAV_Screen_SetAndroidMediaProjection_fn resolve_set_projection(void) {
  // The library is already resident (loaded by the Dart native-assets runtime),
  // so RTLD_NOLOAD gives us its handle without re-initializing it.
  void *handle = dlopen("libminiav_c.so", RTLD_NOLOAD | RTLD_NOW);
  if (handle == NULL) {
    // Not yet resident (e.g. native handoff attempted before any FFI call):
    // load it normally.
    handle = dlopen("libminiav_c.so", RTLD_NOW);
  }
  if (handle == NULL) {
    return NULL;
  }
  return (MiniAV_Screen_SetAndroidMediaProjection_fn)dlsym(
      handle, "MiniAV_Screen_SetAndroidMediaProjection");
}

// Core implementation shared by the exported symbol and the RegisterNatives
// binding. `media_projection` is a local ref (or NULL) to the app's
// MediaProjection; we promote it to a GLOBAL ref and transfer ownership to
// native per the C contract.
static void do_set_media_projection(JNIEnv *env, jobject media_projection) {
  MiniAV_Screen_SetAndroidMediaProjection_fn set_fn = resolve_set_projection();
  if (set_fn == NULL) {
    // libminiav_c.so or the symbol is unavailable. Nothing to hand off. The
    // Kotlin side reports handoff success/failure via its own MethodChannel
    // result; a silent no-op here means "not handed off".
    return;
  }

  if (media_projection == NULL) {
    // Clear request: hand native NULLs so it drops any projection it owns.
    // Per the public contract in miniav_capture.h, "NULL for both clears". The
    // native side actually keys the clear on projection==NULL alone (the jvm arg
    // is ignored on clear), so either form works — but we pass (NULL, NULL) to
    // match the documented public contract exactly.
    set_fn(NULL, NULL);
    return;
  }

  // Create a GLOBAL ref (survives the return of this JNI call) and transfer
  // ownership to native per the C contract. We do NOT delete it here on success.
  jobject global = (*env)->NewGlobalRef(env, media_projection);
  if (global == NULL) {
    // OOM creating the global ref: hand nothing off.
    return;
  }

  int rc = set_fn((void *)g_jvm, (void *)global);
  if (rc != 0) {
    // Native rejected it (e.g. an internal error). It did NOT take ownership, so
    // we must free the global ref to avoid a leak.
    (*env)->DeleteGlobalRef(env, global);
    return;
  }
  // On success native now owns `global` and will DeleteGlobalRef it on its own
  // teardown (or when handed a NULL/replacement). We keep no copy.
}

// Exported, correctly-mangled JNI entry point for the outer class's static
// native method (lifted there by @JvmStatic). The receiver is a jclass because
// the method is static. (Bound lazily by the VM using the app classloader.)
JNIEXPORT void JNICALL
Java_com_practicalxr_miniav_1flutter_MiniavFlutterPlugin_nativeSetMediaProjection(
    JNIEnv *env, jclass clazz, jobject media_projection) {
  (void)clazz;
  do_set_media_projection(env, media_projection);
}

// RegisterNatives shim (best-effort fallback). The native method is static
// (lifted onto the outer class by @JvmStatic), so the receiver is the jclass.
static void register_natives_shim(JNIEnv *env, jclass clazz,
                                  jobject media_projection) {
  (void)clazz;
  do_set_media_projection(env, media_projection);
}

static const JNINativeMethod kMethods[] = {
    {"nativeSetMediaProjection",
     "(Landroid/media/projection/MediaProjection;)V",
     (void *)register_natives_shim},
};

// The class that actually declares the `native` method. @JvmStatic lifts the
// static native onto the OUTER class, so we register against it (not $Companion).
static const char *kDeclaringClassName =
    "com/practicalxr/miniav_flutter/MiniavFlutterPlugin";

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  g_jvm = vm;

  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK ||
      env == NULL) {
    // No JNIEnv available here — still fine: the exported mangled symbol above
    // will be bound lazily. Report the JNI version so the library loads.
    return JNI_VERSION_1_6;
  }

  // Best-effort explicit registration. FindClass in JNI_OnLoad uses the system
  // classloader and may not see the app class; if so, we simply rely on the
  // exported symbol. Any failure is swallowed.
  jclass clazz = (*env)->FindClass(env, kDeclaringClassName);
  if (clazz != NULL) {
    (*env)->RegisterNatives(env, clazz, kMethods,
                            (jint)(sizeof(kMethods) / sizeof(kMethods[0])));
    (*env)->DeleteLocalRef(env, clazz);
  }
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
  }
  return JNI_VERSION_1_6;
}
