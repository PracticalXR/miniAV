// Android screen capture: android.media.projection.MediaProjection +
// AImageReader (NDK). See screen_context_android_mediaprojection.h for the
// consent-flow / foreground-service / stop-detection contract.
//
// Pipeline:
//   AImageReader_new(w, h, AIMAGE_FORMAT_RGBA_8888, maxImages)
//     -> AImageReader_getWindow (ANativeWindow*)
//     -> ANativeWindow_toSurface (Java Surface, API 26+)
//     -> MediaProjection.createVirtualDisplay(name, w, h, dpi,
//          VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)
//   AImageReader image-available callback (looper thread) -> acquire newest
//     image -> deliver as CPU RGBA plane[0] or (GPU pref, API 26+)
//     GPU_AHARDWAREBUFFER -> app callback -> release_buffer frees the image.
//
// Everything Java-touching goes through JNI on a thread attached via the
// shared miniav_jni_android plumbing.

#if defined(__ANDROID__)

#include "screen_context_android_mediaprojection.h"

#include "../../../include/miniav.h"
#include "../../common/miniav_jni_android.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#include <android/api-level.h>
#include <android/hardware_buffer.h>
#include <android/native_window.h>
#include <android/native_window_jni.h> // ANativeWindow_toSurface (API 26+)
#include <jni.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaError.h> // media_status_t, AMEDIA_* (also transitive)

#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

// android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR = 16
#ifndef MINIAV_VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR
#define MINIAV_VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR 16
#endif

// AImageReader window / hardware-buffer paths need runtime API 26+.
#define MINIAV_ANDROID_MIN_API_SCREEN 26

// Max in-flight AImages. AImageReader can only ever hand out maxImages images
// simultaneously; we drop-oldest (acquire the LATEST, discard skipped) so the
// producer never stalls. Each delivered buffer holds one image until the app
// calls MiniAV_ReleaseBuffer.
#define MINIAV_ANDROID_MAX_IMAGES 4

// ---------------------------------------------------------------------------
// Process-global projection state (set via
// MiniAV_Screen_SetAndroidMediaProjection before ConfigureDisplay). The
// projection object is a JNI global ref owned by miniAV.
// ---------------------------------------------------------------------------
static _Atomic(jobject) g_media_projection_global = NULL; // GlobalRef or NULL

// The context that is currently streaming, so a mid-stream projection CLEAR
// (the app relaying the Java-side MediaProjection.Callback.onStop by calling
// SetAndroidMediaProjection(NULL, NULL)) can fire that context's lost_cb.
// This is the one authoritative, native-visible stop signal available (see the
// header's STOP DETECTION note). Registered by start_capture, cleared by
// stop_capture / destroy. Single active capture context is the model here.
struct AndroidScreenPlatformContext; // fwd
static _Atomic(struct AndroidScreenPlatformContext *) g_active_streaming_ctx =
    NULL;

// ---------------------------------------------------------------------------
// Per-frame release payload. Holds the AImage to release, plus (GPU path) the
// AHardwareBuffer we AHardwareBuffer_acquire'd for the app.
// ---------------------------------------------------------------------------
typedef struct AndroidFrameReleasePayload {
  AImage *image;                 // AImage_delete on release
  AHardwareBuffer *hw_buffer;    // GPU path: AHardwareBuffer_release on release
} AndroidFrameReleasePayload;

// ---------------------------------------------------------------------------
// Platform context.
// ---------------------------------------------------------------------------
typedef struct AndroidScreenPlatformContext {
  MiniAVScreenContext *parent_ctx;

  AImageReader *image_reader;   // owns the ANativeWindow returned by getWindow
  ANativeWindow *reader_window; // NOT separately released (owned by reader)

  jobject virtual_display; // GlobalRef to android.hardware.display.VirtualDisplay
  jobject reader_surface;  // GlobalRef to the android.view.Surface

  MiniAVBufferCallback app_callback_internal;
  void *app_callback_user_data_internal;

  MiniAVVideoInfo configured_video_format;
  uint32_t frame_width;
  uint32_t frame_height;
  uint32_t dpi;
  MiniAVOutputPreference output_preference;

  MiniAVTimebase ts_rebase; // rebases AImage_getTimestamp (ns) -> shared epoch

  atomic_bool is_streaming;
  atomic_bool lost_cb_fired; // one-shot lost_cb guard

  // The AImageReader image-available callback runs on an internal looper
  // thread that miniAV does not own. It makes NO JNI calls (pure NDK), so it
  // needs no attach; it only touches image_reader + delivers buffers.
} AndroidScreenPlatformContext;

// Forward declarations.
static void android_image_available_cb(void *ctx_v, AImageReader *reader);
static MiniAVResultCode android_stop_capture(MiniAVScreenContext *ctx);
static void android_teardown_virtual_display(AndroidScreenPlatformContext *ac);
static void android_fire_lost_cb(AndroidScreenPlatformContext *ac,
                                 MiniAVResultCode reason);

// ---------------------------------------------------------------------------
// Runtime API-level probe.
// ---------------------------------------------------------------------------
static int android_runtime_api_level(void) {
  // android_get_device_api_level() is itself API 24+; the header/symbol is
  // always present in modern NDKs. minSdk is 21, so guard with a weak fallback
  // for the (unsupported) <24 case where the symbol may be absent at runtime.
#if __ANDROID_API__ >= 24
  return android_get_device_api_level();
#else
  // Best-effort: if the symbol resolves use it, else assume too-old.
  return 21;
#endif
}

// ---------------------------------------------------------------------------
// set_media_projection: store/replace/clear the projection global ref.
// ---------------------------------------------------------------------------
MiniAVResultCode
miniav_screen_android_set_media_projection(void *jvm, void *media_projection) {
  // Publish the JavaVM first so attach_env works for subsequent config.
  if (jvm) {
    miniav_android_set_jvm((JavaVM *)jvm);
  }

  jobject new_ref = (jobject)media_projection;
  jobject old_ref = atomic_exchange(&g_media_projection_global, new_ref);

  if (old_ref && old_ref != new_ref) {
    // Release the previously-owned global ref. Needs a JNIEnv on this thread.
    JNIEnv *env = NULL;
    int did_attach = 0;
    if (miniav_android_attach_env(&env, &did_attach) == MINIAV_SUCCESS && env) {
      (*env)->DeleteGlobalRef(env, old_ref);
      if (did_attach) {
        miniav_android_detach_env();
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Android screen: released previous MediaProjection global ref.");
    } else {
      // No JVM to release against — leak rather than crash. This only happens
      // if the caller cleared without ever giving us a JVM.
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Android screen: could not attach JNI to release old "
                 "MediaProjection ref (leaking it).");
    }
  }

  // Clear is keyed on the projection alone: callers (the Flutter shim relaying
  // Java-side onStop) may still pass a cached non-NULL JVM with a NULL
  // projection, and that must still count as the authoritative stop signal.
  if (media_projection == NULL) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Android screen: MediaProjection cleared.");
    // A clear while capturing is the app relaying the Java onStop → treat as a
    // one-shot device-lost for the active capture context.
    AndroidScreenPlatformContext *active =
        atomic_load(&g_active_streaming_ctx);
    if (active) {
      android_fire_lost_cb(active, MINIAV_ERROR_DEVICE_LOST);
    }
  } else {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Android screen: MediaProjection set (global ref adopted).");
  }
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// init / destroy platform.
// ---------------------------------------------------------------------------
static MiniAVResultCode android_init_platform(MiniAVScreenContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  AndroidScreenPlatformContext *ac =
      (AndroidScreenPlatformContext *)miniav_calloc(
          1, sizeof(AndroidScreenPlatformContext));
  if (!ac) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: failed to allocate platform context.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  ac->parent_ctx = ctx;
  atomic_init(&ac->is_streaming, false);
  atomic_init(&ac->lost_cb_fired, false);
  ctx->platform_ctx = ac;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode android_destroy_platform(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  AndroidScreenPlatformContext *ac =
      (AndroidScreenPlatformContext *)ctx->platform_ctx;

  if (atomic_load(&ac->is_streaming)) {
    android_stop_capture(ctx);
  }

  // Tear down the virtual display + reader if configure ran but capture never
  // started (or stop left them, which it does not — stop tears them down too).
  android_teardown_virtual_display(ac);

  // NOTE: we do NOT DeleteGlobalRef the MediaProjection here — it is
  // process-global and owned via g_media_projection_global; it is released on
  // explicit clear (set with NULLs). The app owns the projection lifetime and
  // we must never call MediaProjection.stop().

  // Bounded-destroy protocol note: unlike the desktop backends, this backend
  // owns NO capture thread — frames arrive on an NDK looper thread whose
  // listener we detached in stop_capture BEFORE deleting the reader, so nothing
  // still references this parent context once we get here. There is therefore
  // no thread that could outlive us and force the MINIAV_ERROR_TIMEOUT /
  // leak-parent path. (AImageReader_delete inside the teardown does block until
  // the app has released any leased frames; that wait is bounded by the app's
  // MiniAV_ReleaseBuffer calls, the same assumption the DXGI/macOS backends
  // make about outstanding buffers at teardown.)
  miniav_free(ac);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: platform context destroyed.");
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// Enumerate: a single pseudo-display.
// ---------------------------------------------------------------------------
static MiniAVResultCode android_enumerate_displays(MiniAVDeviceInfo **out,
                                                    uint32_t *count) {
  if (!out || !count)
    return MINIAV_ERROR_INVALID_ARG;
  *out = NULL;
  *count = 0;

  MiniAVDeviceInfo *dev =
      (MiniAVDeviceInfo *)miniav_calloc(1, sizeof(MiniAVDeviceInfo));
  if (!dev)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  miniav_strlcpy(dev->device_id, "android_display_0",
                 MINIAV_DEVICE_ID_MAX_LEN);
  miniav_strlcpy(dev->name, "Android Screen (MediaProjection)",
                 MINIAV_DEVICE_NAME_MAX_LEN);
  dev->is_default = true;

  *out = dev;
  *count = 1;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: enumerated pseudo-display 'android_display_0'.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode android_enumerate_windows(MiniAVDeviceInfo **out,
                                                  uint32_t *count) {
  MINIAV_UNUSED(out);
  MINIAV_UNUSED(count);
  // Android projection has no window concept.
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Android screen: EnumerateWindows not supported.");
  return MINIAV_ERROR_NOT_SUPPORTED;
}

// ---------------------------------------------------------------------------
// Default formats: RGBA 32-bit, GPU preferred (AHardwareBuffer path), 60fps.
// Configured size drives the geometry, so default 0x0 unless the app asked.
// ---------------------------------------------------------------------------
static MiniAVResultCode
android_get_default_formats(const char *device_id, MiniAVVideoInfo *video_out,
                            MiniAVAudioInfo *audio_out) {
  if (!device_id || !video_out)
    return MINIAV_ERROR_INVALID_ARG;
  memset(video_out, 0, sizeof(*video_out));
  if (audio_out)
    memset(audio_out, 0, sizeof(*audio_out));

  video_out->pixel_format = MINIAV_PIXEL_FORMAT_RGBA32;
  video_out->frame_rate_numerator = 60;
  video_out->frame_rate_denominator = 1;
  video_out->output_preference = MINIAV_OUTPUT_PREFERENCE_GPU;
  // width/height/dpi are app-driven; left zero for the app to fill.

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: default formats RGBA32 @60fps (size app-driven).");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
android_get_configured_video_formats(MiniAVScreenContext *ctx,
                                     MiniAVVideoInfo *video_out,
                                     MiniAVAudioInfo *audio_out) {
  if (!ctx || !ctx->platform_ctx || !video_out)
    return MINIAV_ERROR_INVALID_ARG;
  memset(video_out, 0, sizeof(*video_out));
  if (audio_out)
    memset(audio_out, 0, sizeof(*audio_out));

  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Android screen: GetConfiguredFormats before configure.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  *video_out = ctx->configured_video_format;
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// Build the AImageReader + Surface + VirtualDisplay via JNI. Assumes env is a
// valid attached JNIEnv on the calling thread.
// ---------------------------------------------------------------------------
static MiniAVResultCode
android_create_virtual_display(AndroidScreenPlatformContext *ac, JNIEnv *env) {
  jobject projection = atomic_load(&g_media_projection_global);
  if (!projection) {
    // Consent not delivered — see the header's consent-flow docs.
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: no MediaProjection set. The app must obtain "
               "screen-capture consent (MediaProjectionManager consent Intent, "
               "handled by the miniav_flutter plugin) and call "
               "MiniAV_Screen_SetAndroidMediaProjection before configuring. "
               "Returning PERMISSION_DENIED.");
    return MINIAV_ERROR_PERMISSION_DENIED;
  }

  const int32_t w = (int32_t)ac->frame_width;
  const int32_t h = (int32_t)ac->frame_height;

  // 1. AImageReader (RGBA_8888). Usage-agnostic reader works for both CPU and
  //    the AHardwareBuffer GPU path (AImage_getHardwareBuffer works on any
  //    reader's images on API 26+).
  media_status_t ms =
      AImageReader_new(w, h, AIMAGE_FORMAT_RGBA_8888,
                       MINIAV_ANDROID_MAX_IMAGES, &ac->image_reader);
  if (ms != AMEDIA_OK || !ac->image_reader) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: AImageReader_new failed (%d).", (int)ms);
    ac->image_reader = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // 2. Image-available listener (delivers on an internal looper thread).
  AImageReader_ImageListener listener = {
      .context = ac,
      .onImageAvailable = android_image_available_cb,
  };
  ms = AImageReader_setImageListener(ac->image_reader, &listener);
  if (ms != AMEDIA_OK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: AImageReader_setImageListener failed (%d).",
               (int)ms);
    AImageReader_delete(ac->image_reader);
    ac->image_reader = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // 3. ANativeWindow from the reader (owned by the reader; do NOT release).
  ms = AImageReader_getWindow(ac->image_reader, &ac->reader_window);
  if (ms != AMEDIA_OK || !ac->reader_window) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: AImageReader_getWindow failed (%d).", (int)ms);
    AImageReader_delete(ac->image_reader);
    ac->image_reader = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // 4. Wrap the ANativeWindow into a Java Surface (API 26+). Returns a local
  //    ref; promote to a global ref for use across the createVirtualDisplay
  //    call and for later cleanup.
  jobject surface_local = ANativeWindow_toSurface(env, ac->reader_window);
  if (!surface_local) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: ANativeWindow_toSurface returned null.");
    AImageReader_delete(ac->image_reader);
    ac->image_reader = NULL;
    ac->reader_window = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  ac->reader_surface = (*env)->NewGlobalRef(env, surface_local);
  (*env)->DeleteLocalRef(env, surface_local);
  if (!ac->reader_surface) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: NewGlobalRef(Surface) failed.");
    AImageReader_delete(ac->image_reader);
    ac->image_reader = NULL;
    ac->reader_window = NULL;
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  // 5. MediaProjection.createVirtualDisplay(
  //      String name, int width, int height, int dpi, int flags,
  //      Surface surface, VirtualDisplay.Callback callback, Handler handler)
  //    -> VirtualDisplay
  // All locals used past a `goto jni_fail` are declared up-front so no jump
  // skips an initializer (keeps -Wjump-misses-init quiet).
  MiniAVResultCode rc = MINIAV_ERROR_SYSTEM_CALL_FAILED;
  jclass mp_cls = (*env)->GetObjectClass(env, projection);
  jmethodID create_vd = NULL;
  jstring name = NULL;
  jobject vd_local = NULL;
  if (!mp_cls) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: GetObjectClass(MediaProjection) failed.");
    goto jni_fail;
  }

  create_vd = (*env)->GetMethodID(
      env, mp_cls, "createVirtualDisplay",
      "(Ljava/lang/String;IIIILandroid/view/Surface;"
      "Landroid/hardware/display/VirtualDisplay$Callback;"
      "Landroid/os/Handler;)Landroid/hardware/display/VirtualDisplay;");
  if (!create_vd) {
    // Clear the pending NoSuchMethodError so later JNI calls are usable.
    if ((*env)->ExceptionCheck(env))
      (*env)->ExceptionClear(env);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: createVirtualDisplay method not found.");
    goto jni_fail;
  }

  name = (*env)->NewStringUTF(env, "miniAV_screen");
  if (!name) {
    if ((*env)->ExceptionCheck(env))
      (*env)->ExceptionClear(env);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: NewStringUTF(display name) failed.");
    goto jni_fail;
  }

  vd_local = (*env)->CallObjectMethod(
      env, projection, create_vd, name, (jint)w, (jint)h, (jint)ac->dpi,
      (jint)MINIAV_VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, ac->reader_surface,
      (jobject)NULL, (jobject)NULL);

  // A JNI exception here (e.g. missing foreground service, revoked projection)
  // OR a null return both mean the projection is unusable → treat as a native
  // stop signal.
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: createVirtualDisplay threw. The app likely "
               "lacks the required mediaProjection foreground service, or the "
               "projection was revoked.");
    goto jni_fail;
  }
  if (!vd_local) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: createVirtualDisplay returned null "
               "(projection stopped/invalid).");
    goto jni_fail;
  }

  ac->virtual_display = (*env)->NewGlobalRef(env, vd_local);
  if (!ac->virtual_display) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: NewGlobalRef(VirtualDisplay) failed.");
    rc = MINIAV_ERROR_OUT_OF_MEMORY;
    goto jni_fail;
  }

  rc = MINIAV_SUCCESS;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: VirtualDisplay created (%dx%d @ %u dpi).", w, h,
             ac->dpi);

jni_fail:
  if (vd_local)
    (*env)->DeleteLocalRef(env, vd_local);
  if (name)
    (*env)->DeleteLocalRef(env, name);
  if (mp_cls)
    (*env)->DeleteLocalRef(env, mp_cls);

  if (rc != MINIAV_SUCCESS) {
    // Roll back the reader/surface built above.
    android_teardown_virtual_display(ac);
  }
  return rc;
}

// ---------------------------------------------------------------------------
// configure_display: validate API level, remember geometry, build the
// VirtualDisplay + reader immediately (so a missing projection fails fast at
// configure time with PERMISSION_DENIED, per the contract).
// ---------------------------------------------------------------------------
static MiniAVResultCode android_configure_display(MiniAVScreenContext *ctx,
                                                  const char *display_id,
                                                  const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !display_id || !format)
    return MINIAV_ERROR_INVALID_ARG;
  AndroidScreenPlatformContext *ac =
      (AndroidScreenPlatformContext *)ctx->platform_ctx;

  if (atomic_load(&ac->is_streaming)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: cannot configure while streaming.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  int api = android_runtime_api_level();
  if (api < MINIAV_ANDROID_MIN_API_SCREEN) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: requires API %d+ (ANativeWindow_toSurface / "
               "AImage_getHardwareBuffer); device is API %d.",
               MINIAV_ANDROID_MIN_API_SCREEN, api);
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  if (format->width == 0 || format->height == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: configured size must be non-zero (the app "
               "drives VirtualDisplay geometry); got %ux%u.",
               format->width, format->height);
    return MINIAV_ERROR_INVALID_ARG;
  }

  // Tear down any prior configure state (re-configure). Mark unconfigured
  // until the rebuild succeeds, so a failed reconfigure does not leave a stale
  // is_configured=true behind.
  ctx->is_configured = false;
  android_teardown_virtual_display(ac);

  ac->frame_width = format->width;
  ac->frame_height = format->height;
  // DPI is not part of MiniAVVideoInfo; a conventional value works because the
  // VirtualDisplay is mirrored 1:1 into our reader. 160 (mdpi) is the safe
  // default density.
  ac->dpi = 160;
  ac->output_preference = format->output_preference;
  ac->configured_video_format = *format;
  ac->configured_video_format.pixel_format = MINIAV_PIXEL_FORMAT_RGBA32;
  memset(&ac->ts_rebase, 0, sizeof(ac->ts_rebase));

  // Attach JNI on this (caller) thread just for the JNI build below.
  JNIEnv *env = NULL;
  int did_attach = 0;
  MiniAVResultCode att = miniav_android_attach_env(&env, &did_attach);
  if (att != MINIAV_SUCCESS || !env) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: no JavaVM — call "
               "MiniAV_Screen_SetAndroidMediaProjection(jvm, projection) first.");
    // Without a JVM we cannot even check the projection; treat as permission
    // problem in the consent-flow sense.
    return (att == MINIAV_ERROR_NOT_INITIALIZED) ? MINIAV_ERROR_PERMISSION_DENIED
                                                 : att;
  }

  MiniAVResultCode rc = android_create_virtual_display(ac, env);
  if (did_attach)
    miniav_android_detach_env();

  if (rc != MINIAV_SUCCESS) {
    return rc;
  }

  // Mirror the confirmed format into the parent context.
  ctx->configured_video_format = ac->configured_video_format;
  ctx->configured_video_format.width = ac->frame_width;
  ctx->configured_video_format.height = ac->frame_height;
  ctx->is_configured = true;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android screen: configured display '%s' %ux%u RGBA32, pref=%d.",
             display_id, ac->frame_width, ac->frame_height,
             ac->output_preference);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode android_configure_window(MiniAVScreenContext *ctx,
                                                 const char *window_id,
                                                 const MiniAVVideoInfo *format) {
  MINIAV_UNUSED(ctx);
  MINIAV_UNUSED(window_id);
  MINIAV_UNUSED(format);
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Android screen: ConfigureWindow not supported (projection is "
             "whole-display only).");
  return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode android_configure_region(MiniAVScreenContext *ctx,
                                                 const char *target_id, int x,
                                                 int y, int width, int height,
                                                 const MiniAVVideoInfo *format) {
  MINIAV_UNUSED(ctx);
  MINIAV_UNUSED(target_id);
  MINIAV_UNUSED(x);
  MINIAV_UNUSED(y);
  MINIAV_UNUSED(width);
  MINIAV_UNUSED(height);
  MINIAV_UNUSED(format);
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Android screen: ConfigureRegion not supported.");
  return MINIAV_ERROR_NOT_SUPPORTED;
}

// ---------------------------------------------------------------------------
// Deliver one acquired AImage as a MiniAVBuffer. Takes ownership of `image`
// (frees it on any error path; hands it to the release payload on success).
// ---------------------------------------------------------------------------
static void android_deliver_image(AndroidScreenPlatformContext *ac,
                                  AImage *image) {
  int32_t w = 0, h = 0;
  AImage_getWidth(image, &w);
  AImage_getHeight(image, &h);

  int64_t ts_ns = 0;
  AImage_getTimestamp(image, &ts_ns);

  MiniAVBuffer *buffer = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  AndroidFrameReleasePayload *frame =
      (AndroidFrameReleasePayload *)miniav_calloc(
          1, sizeof(AndroidFrameReleasePayload));
  if (!buffer || !payload || !frame) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: payload allocation failed; dropping frame.");
    miniav_free(buffer);
    miniav_free(payload);
    miniav_free(frame);
    AImage_delete(image);
    return;
  }

  buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
  // AImage_getTimestamp is CLOCK_MONOTONIC ns; rebase ns->us onto shared epoch.
  buffer->timestamp_us =
      (int64_t)miniav_rebase_time_us(&ac->ts_rebase, (uint64_t)(ts_ns / 1000));
  buffer->data.video.info.width = (uint32_t)w;
  buffer->data.video.info.height = (uint32_t)h;
  buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_RGBA32;
  buffer->data.video.info.frame_rate_numerator =
      ac->configured_video_format.frame_rate_numerator;
  buffer->data.video.info.frame_rate_denominator =
      ac->configured_video_format.frame_rate_denominator;
  buffer->data.video.info.output_preference = ac->output_preference;
  buffer->user_data = ac->app_callback_user_data_internal;

  bool delivered_as_gpu = false;

  if (ac->output_preference == MINIAV_OUTPUT_PREFERENCE_GPU) {
    // GPU path: hand out the AHardwareBuffer (API 26+). Acquire a reference so
    // it outlives the AImage from the app's perspective; release_buffer
    // releases both the acquire ref and the AImage.
    AHardwareBuffer *hb = NULL;
    media_status_t ms = AImage_getHardwareBuffer(image, &hb);
    if (ms == AMEDIA_OK && hb) {
      AHardwareBuffer_acquire(hb);
      frame->hw_buffer = hb;

      buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_AHARDWAREBUFFER;
      buffer->data.video.num_planes = 1;
      buffer->data.video.planes[0].data_ptr = (void *)hb;
      buffer->data.video.planes[0].width = (uint32_t)w;
      buffer->data.video.planes[0].height = (uint32_t)h;
      buffer->data.video.planes[0].stride_bytes = 0; // opaque GPU buffer
      buffer->data.video.planes[0].offset_bytes = 0;
      buffer->data.video.planes[0].subresource_index = 0;
      buffer->data.video.planes[0].dmabuf_fd = -1;
      // No real acquire fence available from AImageReader here.
      buffer->native_fence.sync_fd = -1;
      buffer->data_size_bytes = 0;
      delivered_as_gpu = true;
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Android screen: AImage_getHardwareBuffer failed (%d); "
                 "falling back to CPU.",
                 (int)ms);
    }
  }

  if (!delivered_as_gpu) {
    // CPU path: RGBA_8888 is a single interleaved plane. Honor the row stride
    // reported by the plane (pixelStride*width padded to rowStride).
    uint8_t *data = NULL;
    int data_len = 0;
    int32_t row_stride = 0;
    media_status_t ms0 = AImage_getPlaneData(image, 0, &data, &data_len);
    media_status_t ms1 = AImage_getPlaneRowStride(image, 0, &row_stride);
    MINIAV_UNUSED(data_len); // size derived from row_stride*height below
    if (ms0 != AMEDIA_OK || !data || ms1 != AMEDIA_OK || row_stride <= 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Android screen: AImage_getPlaneData/RowStride failed "
                 "(%d/%d); dropping frame.",
                 (int)ms0, (int)ms1);
      miniav_free(buffer);
      miniav_free(payload);
      miniav_free(frame);
      AImage_delete(image);
      return;
    }

    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    buffer->data.video.num_planes = 1;
    buffer->data.video.planes[0].data_ptr = data;
    buffer->data.video.planes[0].width = (uint32_t)w;
    buffer->data.video.planes[0].height = (uint32_t)h;
    buffer->data.video.planes[0].stride_bytes = (uint32_t)row_stride;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    buffer->data.video.planes[0].dmabuf_fd = -1;
    buffer->data_size_bytes = (size_t)row_stride * (size_t)h;
  }

  // The AImage backs the delivered pixels/hardware buffer until release.
  frame->image = image;

  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
  payload->context_owner = ac->parent_ctx;
  payload->native_singular_resource_ptr = frame;
  payload->num_planar_resources_to_release = 0;
  payload->parent_miniav_buffer_ptr = buffer;
  buffer->internal_handle = payload;

  // Deliver-or-release: we MUST NOT skip-and-leak. If we let MINIAV_SAFE_DISPATCH
  // silently drop the call while callbacks are quiesced (MiniAV_Dispose / hot
  // restart), this AImage would keep one of the AImageReader's few bounded
  // reader slots forever; once all slots leak, the AImageReader_delete in
  // teardown blocks waiting for acquired images. So on every no-deliver path
  // (no consumer registered, or callbacks quiesced) we release the full
  // resource set synchronously right here. Take the dispatch guard explicitly
  // rather than via MINIAV_SAFE_DISPATCH so we can tell "delivered" from
  // "quiesced".
  bool delivered = false;
  if (ac->app_callback_internal &&
      miniav_dispatch_guard_acquire_if_enabled()) {
    ac->app_callback_internal(buffer, ac->app_callback_user_data_internal);
    miniav_dispatch_guard_release();
    delivered = true;
  }
  if (!delivered) {
    // No consumer registered, or callbacks quiesced: release everything we
    // allocated/acquired now (same resource set the consumer's release_buffer
    // would have freed) so we never hold a bounded reader slot into teardown.
    if (frame->hw_buffer)
      AHardwareBuffer_release(frame->hw_buffer);
    AImage_delete(image);
    miniav_free(frame);
    miniav_free(payload);
    miniav_free(buffer);
  }
}

// ---------------------------------------------------------------------------
// AImageReader image-available callback (looper thread, NDK-only, no JNI).
// Drop-oldest: drain to the latest available image and deliver just that one,
// so we never stall the producer nor exceed maxImages in-flight.
// ---------------------------------------------------------------------------
static void android_image_available_cb(void *ctx_v, AImageReader *reader) {
  AndroidScreenPlatformContext *ac = (AndroidScreenPlatformContext *)ctx_v;
  if (!ac || !atomic_load(&ac->is_streaming))
    return;

  // Acquire the newest image; AImageReader_acquireLatestImage internally
  // deletes the skipped older images so the reader does not back up.
  AImage *image = NULL;
  media_status_t ms = AImageReader_acquireLatestImage(reader, &image);
  if (ms == AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE) {
    // Spurious wake or already drained.
    return;
  }
  if (ms == AMEDIA_IMGREADER_MAX_IMAGES_ACQUIRED) {
    // Every slot is leased by the app (release_buffer not yet called) — drop
    // this frame rather than stall. It will be re-signaled as slots free up.
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Android screen: max images acquired; dropping frame "
               "(consumer is behind).");
    return;
  }
  if (ms != AMEDIA_OK || !image) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Android screen: acquireLatestImage failed (%d).", (int)ms);
    return;
  }

  android_deliver_image(ac, image);
}

// ---------------------------------------------------------------------------
// start / stop capture.
// ---------------------------------------------------------------------------
static MiniAVResultCode android_start_capture(MiniAVScreenContext *ctx,
                                              MiniAVBufferCallback callback,
                                              void *user_data) {
  if (!ctx || !ctx->platform_ctx || !callback)
    return MINIAV_ERROR_INVALID_ARG;
  AndroidScreenPlatformContext *ac =
      (AndroidScreenPlatformContext *)ctx->platform_ctx;

  if (atomic_load(&ac->is_streaming)) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Android screen: already streaming.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  if (!ac->image_reader || !ac->virtual_display) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android screen: not configured (call ConfigureDisplay first).");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  ac->app_callback_internal = callback;
  ac->app_callback_user_data_internal = user_data;
  ac->parent_ctx->app_callback = callback;
  ac->parent_ctx->app_callback_user_data = user_data;
  atomic_store(&ac->lost_cb_fired, false);

  // The reader + virtual display already mirror frames into the reader; simply
  // enabling delivery is all that is required. Frames flow via the listener.
  atomic_store(&ac->is_streaming, true);
  atomic_store(&g_active_streaming_ctx, ac); // for mid-stream clear→lost_cb

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Android screen: capture started.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode android_stop_capture(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  AndroidScreenPlatformContext *ac =
      (AndroidScreenPlatformContext *)ctx->platform_ctx;

  if (!atomic_load(&ac->is_streaming)) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Android screen: stop called but not streaming.");
    return MINIAV_SUCCESS;
  }

  // Stop delivery first so the listener (which checks is_streaming) becomes a
  // no-op, then remove the listener so no callback can be mid-flight against a
  // reader we are about to delete.
  atomic_store(&ac->is_streaming, false);
  // Deregister only if we are the active context (compare-and-clear).
  {
    AndroidScreenPlatformContext *expected = ac;
    atomic_compare_exchange_strong(&g_active_streaming_ctx, &expected, NULL);
  }
  if (ac->image_reader) {
    // Detach the listener: no NEW image-available dispatches are queued after
    // this. A dispatch already in flight on the NDK looper can still be
    // running; the is_streaming=false store above makes it an early no-op, and
    // AImageReader_delete (in the teardown below) is what actually
    // synchronizes with / drains the reader's callback machinery before the
    // reader is freed. We own no looper thread to join here.
    AImageReader_setImageListener(ac->image_reader, NULL);
  }

  // Release the VirtualDisplay + reader + surface. We own these; we must NOT
  // touch MediaProjection (the app owns its lifetime).
  android_teardown_virtual_display(ac);

  ac->app_callback_internal = NULL;
  ac->app_callback_user_data_internal = NULL;

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Android screen: capture stopped.");
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// Release the VirtualDisplay (JNI), the Surface global ref, and the
// AImageReader. Idempotent. Note AImageReader_delete blocks until all
// outstanding images acquired from it are released — the standard contract is
// that the app has released its buffers by teardown time; if not, delete waits
// (bounded by the app), which is acceptable here.
// ---------------------------------------------------------------------------
static void android_teardown_virtual_display(AndroidScreenPlatformContext *ac) {
  if (!ac)
    return;

  // JNI-touching cleanup (VirtualDisplay.release + global refs).
  if (ac->virtual_display || ac->reader_surface) {
    JNIEnv *env = NULL;
    int did_attach = 0;
    if (miniav_android_attach_env(&env, &did_attach) == MINIAV_SUCCESS && env) {
      if (ac->virtual_display) {
        jclass vd_cls = (*env)->GetObjectClass(env, ac->virtual_display);
        if (vd_cls) {
          jmethodID release =
              (*env)->GetMethodID(env, vd_cls, "release", "()V");
          if (release) {
            (*env)->CallVoidMethod(env, ac->virtual_display, release);
            if ((*env)->ExceptionCheck(env)) {
              (*env)->ExceptionClear(env);
              miniav_log(MINIAV_LOG_LEVEL_WARN,
                         "Android screen: VirtualDisplay.release threw "
                         "(ignored during teardown).");
            }
          } else if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
          }
          (*env)->DeleteLocalRef(env, vd_cls);
        }
        (*env)->DeleteGlobalRef(env, ac->virtual_display);
        ac->virtual_display = NULL;
      }
      if (ac->reader_surface) {
        (*env)->DeleteGlobalRef(env, ac->reader_surface);
        ac->reader_surface = NULL;
      }
      if (did_attach)
        miniav_android_detach_env();
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Android screen: no JNI env for VirtualDisplay teardown "
                 "(leaking VirtualDisplay/Surface global refs).");
      // Drop our pointers so we do not double-free; the refs leak but that is
      // safer than crashing without a JVM.
      ac->virtual_display = NULL;
      ac->reader_surface = NULL;
    }
  }

  // NDK reader (safe to delete without JNI).
  if (ac->image_reader) {
    AImageReader_delete(ac->image_reader);
    ac->image_reader = NULL;
  }
  ac->reader_window = NULL; // owned by the reader; already gone.
}

static void android_fire_lost_cb(AndroidScreenPlatformContext *ac,
                                 MiniAVResultCode reason) {
  if (!ac)
    return;
  if (atomic_exchange(&ac->lost_cb_fired, true))
    return; // already fired once
  atomic_store(&ac->is_streaming, false);
  MiniAVScreenContext *parent = ac->parent_ctx;
  if (parent) {
    parent->is_running = false;
    if (parent->lost_cb) {
      parent->lost_cb((int)reason, parent->lost_cb_user_data);
    }
  }
}

// ---------------------------------------------------------------------------
// release_buffer: free the AImage (and GPU AHardwareBuffer acquire ref).
// ---------------------------------------------------------------------------
static MiniAVResultCode android_release_buffer(MiniAVScreenContext *ctx,
                                               void *internal_handle_ptr) {
  MINIAV_UNUSED(ctx);
  if (!internal_handle_ptr)
    return MINIAV_SUCCESS;

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN &&
      payload->native_singular_resource_ptr) {
    AndroidFrameReleasePayload *frame =
        (AndroidFrameReleasePayload *)payload->native_singular_resource_ptr;
    if (frame->hw_buffer) {
      AHardwareBuffer_release(frame->hw_buffer);
      frame->hw_buffer = NULL;
    }
    if (frame->image) {
      // Returns the image slot to the AImageReader, freeing an in-flight slot.
      AImage_delete(frame->image);
      frame->image = NULL;
    }
    miniav_free(frame);
    payload->native_singular_resource_ptr = NULL;
  }

  if (payload->parent_miniav_buffer_ptr) {
    miniav_free(payload->parent_miniav_buffer_ptr);
    payload->parent_miniav_buffer_ptr = NULL;
  }
  miniav_free(payload);
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// Ops table + selection init.
// ---------------------------------------------------------------------------
const ScreenContextInternalOps g_screen_ops_android_mediaprojection = {
    .init_platform = android_init_platform,
    .destroy_platform = android_destroy_platform,
    .enumerate_displays = android_enumerate_displays,
    .enumerate_windows = android_enumerate_windows,
    .configure_display = android_configure_display,
    .configure_window = android_configure_window,
    .configure_region = android_configure_region,
    .start_capture = android_start_capture,
    .stop_capture = android_stop_capture,
    .release_buffer = android_release_buffer,
    .get_default_formats = android_get_default_formats,
    .get_configured_video_formats = android_get_configured_video_formats,
};

MiniAVResultCode miniav_screen_context_platform_init_android_mediaprojection(
    MiniAVScreenContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  ctx->ops = &g_screen_ops_android_mediaprojection;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Android screen: assigned MediaProjection screen ops.");
  return MINIAV_SUCCESS;
}

#endif // __ANDROID__
