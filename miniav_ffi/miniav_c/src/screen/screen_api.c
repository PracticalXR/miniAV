#include "../common/miniav_device_watcher.h"
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h" // For miniav_calloc, miniav_free
#include "screen_context.h"
#include <string.h> // For memset, memcpy

// Platform-specific includes and external declarations for backend table.
// Gate specificity: Android defines __linux__ and iOS defines __APPLE__ —
// the mobile backends take the #if arm and desktop entries sit in the #elif
// arm (a bare gate would reference desktop ops symbols not compiled on
// mobile → link error).
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#ifdef _WIN32
#include "windows/screen_context_win_wgc.h"
extern const ScreenContextInternalOps g_screen_ops_win_wgc;
extern MiniAVResultCode
miniav_screen_context_platform_init_windows_wgc(MiniAVScreenContext *ctx);
#include "windows/screen_context_win_dxgi.h"
extern const ScreenContextInternalOps g_screen_ops_win_dxgi;
extern MiniAVResultCode
miniav_screen_context_platform_init_windows_dxgi(MiniAVScreenContext *ctx);
#endif
#if defined(__ANDROID__)
#include "android/screen_context_android_mediaprojection.h"
extern const ScreenContextInternalOps g_screen_ops_android_mediaprojection;
extern MiniAVResultCode
miniav_screen_context_platform_init_android_mediaprojection(
    MiniAVScreenContext *ctx);
#elif defined(__linux__)
#include "linux/screen_context_linux_pipewire.h" // Ensure this header declares the ops and init function
extern const ScreenContextInternalOps g_screen_ops_linux_pipewire;
extern MiniAVResultCode
miniav_screen_context_platform_init_linux_pipewire(MiniAVScreenContext *ctx);
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
#include "ios/screen_context_ios_replaykit.h"
extern const ScreenContextInternalOps g_screen_ops_ios_replaykit;
extern MiniAVResultCode
miniav_screen_context_platform_init_ios_replaykit(MiniAVScreenContext *ctx);
#elif defined(__APPLE__)
#include "macos/screen_context_macos_cg.h" // Ensure this header declares the ops and init function
extern const ScreenContextInternalOps g_screen_ops_macos_cg;
extern MiniAVResultCode
miniav_screen_context_platform_init_macos_cg(MiniAVScreenContext *ctx);
#endif

// --- Backend Table ---
// Order matters here for default preference.
// For Windows, WGC is listed first to make it the default.
static const MiniAVScreenBackend g_screen_backends[] = {
#ifdef _WIN32
    {"Windows Graphics Capture", &g_screen_ops_win_wgc,
     miniav_screen_context_platform_init_windows_wgc},
    {"DXGI", &g_screen_ops_win_dxgi,
     miniav_screen_context_platform_init_windows_dxgi},
#endif
#if defined(__ANDROID__)
    {"MediaProjection", &g_screen_ops_android_mediaprojection,
     miniav_screen_context_platform_init_android_mediaprojection},
#elif defined(__linux__)
    {"Pipewire", &g_screen_ops_linux_pipewire,
     miniav_screen_context_platform_init_linux_pipewire}, // This function now
                                                          // acts as
                                                          // platform_init_for_selection
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
    {"ReplayKit", &g_screen_ops_ios_replaykit,
     miniav_screen_context_platform_init_ios_replaykit},
#elif defined(__APPLE__)
    {"CoreGraphics", &g_screen_ops_macos_cg,
     miniav_screen_context_platform_init_macos_cg},
#endif
    {NULL, NULL, NULL} // Sentinel
};

MiniAVResultCode MiniAV_Screen_CreateContext(MiniAVScreenContext **ctx_out) {
  if (!ctx_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *ctx_out = NULL;

  MiniAVScreenContext *ctx =
      (MiniAVScreenContext *)miniav_calloc(1, sizeof(MiniAVScreenContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to allocate MiniAVScreenContext.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  const MiniAVScreenBackend *selected_backend_entry = NULL;

  for (const MiniAVScreenBackend *backend_entry = g_screen_backends;
       backend_entry->name != NULL; ++backend_entry) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to initialize screen backend for context: %s",
               backend_entry->name);
    // Assuming MiniAVScreenBackend struct's 3rd member is now
    // platform_init_for_selection
    if (backend_entry->platform_init_for_selection) {
      res = backend_entry->platform_init_for_selection(
          ctx); // This sets ctx->ops and ctx->platform_ctx
      if (res == MINIAV_SUCCESS) {
        selected_backend_entry = backend_entry;
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "Successfully selected screen backend for context: %s",
                   selected_backend_entry->name);
        break;
      } else {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Backend %s platform_init_for_selection failed for context "
                   "with code %d. Trying next.",
                   backend_entry->name, res);
        if (ctx->platform_ctx) { // Clean up if platform_init_for_selection
                                 // allocated but failed
          miniav_free(ctx->platform_ctx);
          ctx->platform_ctx = NULL;
        }
        ctx->ops =
            NULL; // Ensure ops is cleared if platform_init_for_selection failed
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Backend %s has no platform_init_for_selection function.",
                 backend_entry->name);
      res = MINIAV_ERROR_NOT_IMPLEMENTED; // Or keep previous res
    }
  }

  if (res != MINIAV_SUCCESS || !selected_backend_entry) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "No suitable screen backend found or "
                                       "all failed to initialize for context.");
    miniav_free(ctx);
    return (res == MINIAV_SUCCESS && !selected_backend_entry)
               ? MINIAV_ERROR_NOT_SUPPORTED
               : res;
  }

  if (!ctx->ops || !ctx->ops->init_platform) {
    miniav_log(
        MINIAV_LOG_LEVEL_ERROR,
        "Platform ops or ops->init_platform not set by selected backend '%s'.",
        selected_backend_entry->name);
    if (ctx->platform_ctx)
      miniav_free(ctx->platform_ctx);
    miniav_free(ctx);
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  res = ctx->ops->init_platform(ctx);
  if (res != MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "ctx->ops->init_platform for backend '%s' failed with code %d.",
               selected_backend_entry->name, res);
    if (ctx->ops->destroy_platform) { // Attempt to use the backend's destroy
      ctx->ops->destroy_platform(ctx);
    } else {
      miniav_free(ctx->platform_ctx); // Fallback
    }
    miniav_free(ctx);
    return res;
  }

  ctx->is_running = false;
  *ctx_out = ctx;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "MiniAV_Screen_CreateContext successful with backend: %s",
             selected_backend_entry->name);
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Screen_DestroyContext(MiniAVScreenContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Destroying screen context...");
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Screen context is running. Attempting to stop capture...");
    MiniAV_Screen_StopCapture(ctx);
  }

  if (ctx->ops && ctx->ops->destroy_platform) {
    MiniAVResultCode destroy_res = ctx->ops->destroy_platform(ctx);
    if (destroy_res == MINIAV_ERROR_TIMEOUT) {
      // The platform layer could not reap a capture thread and leaked its
      // platform context. That thread also dereferences THIS parent context
      // (callbacks, configured format), so it must be leaked too — freeing
      // it here would be a use-after-free.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Screen DestroyContext: platform teardown timed out — "
                 "leaking the context (a capture thread is still alive).");
      return destroy_res;
    }
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "destroy_platform op not available or ops not set. Freeing "
               "platform_ctx directly if it exists.");
    miniav_free(ctx->platform_ctx);
  }
  ctx->platform_ctx = NULL;

  miniav_free(ctx);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "MiniAV_Screen_DestroyContext successful.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Screen_EnumerateDisplays(MiniAVDeviceInfo **displays_out,
                                uint32_t *count_out) {
  if (!displays_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *displays_out = NULL;
  *count_out = 0;

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVScreenBackend *backend_entry = g_screen_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->enumerate_displays) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting EnumerateDisplays with backend: %s",
                 backend_entry->name);
      res = backend_entry->ops->enumerate_displays(displays_out, count_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "EnumerateDisplays successful with backend: %s",
                   backend_entry->name);
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "EnumerateDisplays with backend %s failed or found no devices "
                 "(code: %d). Trying next.",
                 backend_entry->name, res);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Backend %s does not support enumerate_displays.",
                 backend_entry->name);
    }
  }

  miniav_log(
      MINIAV_LOG_LEVEL_WARN,
      "Screen_EnumerateDisplays: No suitable backend found or all failed.");
  return res; // Return last error or MINIAV_ERROR_NOT_SUPPORTED
}

MiniAVResultCode MiniAV_Screen_EnumerateWindows(MiniAVDeviceInfo **windows_out,
                                                uint32_t *count_out) {
  if (!windows_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *windows_out = NULL;
  *count_out = 0;

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVScreenBackend *backend_entry = g_screen_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->enumerate_windows) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting EnumerateWindows with backend: %s",
                 backend_entry->name);
      res = backend_entry->ops->enumerate_windows(windows_out, count_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "EnumerateWindows successful with backend: %s",
                   backend_entry->name);
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "EnumerateWindows with backend %s failed or found no devices "
                 "(code: %d). Trying next.",
                 backend_entry->name, res);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Backend %s does not support enumerate_windows.",
                 backend_entry->name);
    }
  }
  miniav_log(
      MINIAV_LOG_LEVEL_WARN,
      "Screen_EnumerateWindows: No suitable backend found or all failed.");
  return res;
}

MiniAVResultCode
MiniAV_Screen_GetDefaultFormats(const char *device_id,
                                MiniAVVideoInfo *video_format_out,
                                MiniAVAudioInfo *audio_format_out) {

  if (!device_id || !video_format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_format_out) {
    memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
  }

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVScreenBackend *backend_entry = g_screen_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->get_default_formats) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting GetDefaultFormats with backend: %s for device: %s",
                 backend_entry->name, device_id);
      res = backend_entry->ops->get_default_formats(device_id, video_format_out,
                                                    audio_format_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(
            MINIAV_LOG_LEVEL_INFO,
            "GetDefaultFormats successful with backend: %s for device: %s",
            backend_entry->name, device_id);
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "GetDefaultFormats with backend %s failed for device %s "
                 "(code: %d). Trying next.",
                 backend_entry->name, device_id, res);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Backend %s does not support get_default_formats.",
                 backend_entry->name);
    }
  }
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Screen_GetDefaultFormats: No suitable backend found or all "
             "failed for device: %s",
             device_id);
  return res;
}

MiniAVResultCode MiniAV_Screen_ConfigureDisplay(MiniAVScreenContext *ctx,
                                                const char *display_id,
                                                const MiniAVVideoInfo *format,
                                                bool capture_audio) {

  if (!ctx || !ctx->ops || !ctx->ops->configure_display || !display_id ||
      !format) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure display while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  ctx->capture_target_type = MINIAV_CAPTURE_TYPE_DISPLAY;
  ctx->capture_audio_requested = capture_audio;

  MiniAVResultCode res = ctx->ops->configure_display(ctx, display_id, format);
  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Screen display configured successfully (API layer).");
  } else {
    // On failure, clear the configured format in the main context.
    memset(&ctx->configured_video_format, 0, sizeof(MiniAVVideoInfo));
    memset(&ctx->configured_audio_format, 0,
           sizeof(MiniAVAudioInfo)); // Also clear audio format
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to configure screen display (API layer), code: %d", res);
  }
  return res;
}

MiniAVResultCode MiniAV_Screen_ConfigureWindow(MiniAVScreenContext *ctx,
                                               const char *window_id,
                                               const MiniAVVideoInfo *format,
                                               bool capture_audio) {

  if (!ctx || !ctx->ops || !ctx->ops->configure_window || !window_id ||
      !format) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure window while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  ctx->capture_target_type = MINIAV_CAPTURE_TYPE_WINDOW;
  ctx->capture_audio_requested = capture_audio;

  MiniAVResultCode res = ctx->ops->configure_window(ctx, window_id, format);
  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Screen window configured successfully (API layer).");
  } else {
    memset(&ctx->configured_video_format, 0, sizeof(MiniAVVideoInfo));
    memset(&ctx->configured_audio_format, 0, sizeof(MiniAVAudioInfo));
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to configure screen window (API layer), code: %d", res);
  }
  return res;
}

MiniAVResultCode MiniAV_Screen_ConfigureRegion(MiniAVScreenContext *ctx,
                                               const char *target_id, int x,
                                               int y, int width, int height,
                                               const MiniAVVideoInfo *format,
                                               bool capture_audio) {

  if (!ctx || !ctx->ops || !ctx->ops->configure_region || !target_id ||
      !format || width <= 0 || height <= 0) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure region while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  ctx->capture_target_type = MINIAV_CAPTURE_TYPE_REGION;
  ctx->capture_audio_requested = capture_audio;

  MiniAVResultCode res =
      ctx->ops->configure_region(ctx, target_id, x, y, width, height, format);
  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Screen region configured successfully (API layer).");
  } else {
    memset(&ctx->configured_video_format, 0, sizeof(MiniAVVideoInfo));
    memset(&ctx->configured_audio_format, 0, sizeof(MiniAVAudioInfo));
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to configure screen region (API layer), code: %d", res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Screen_GetConfiguredFormats(MiniAVScreenContext *ctx,
                                   MiniAVVideoInfo *video_format_out,
                                   MiniAVAudioInfo *audio_format_out) {

  if (!ctx || !video_format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_format_out) {
    memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
  }

  if (ctx->ops && ctx->ops->get_configured_video_formats) {
    return ctx->ops->get_configured_video_formats(ctx, video_format_out,
                                                  audio_format_out);
  }
  miniav_log(
      MINIAV_LOG_LEVEL_WARN,
      "get_configured_video_formats op not available for the current context. "
      "Using generic context video format if set.");
  if (ctx->configured_video_format.width > 0 &&
      ctx->configured_video_format.height > 0) {
    memcpy(video_format_out, &ctx->configured_video_format,
           sizeof(MiniAVVideoInfo));
    if (audio_format_out) {
      miniav_log(
          MINIAV_LOG_LEVEL_WARN,
          "Audio configured format cannot be retrieved without backend op.");
    }
    return MINIAV_SUCCESS;
  }
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Screen context not configured or get_configured_video_formats op "
             "failed/unavailable.");
  return MINIAV_ERROR_NOT_INITIALIZED;
}

MiniAVResultCode MiniAV_Screen_StartCapture(MiniAVScreenContext *ctx,
                                            MiniAVBufferCallback callback,
                                            void *user_data) {

  if (!ctx || !ctx->ops || !ctx->ops->start_capture || !callback) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Screen capture already running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  // Re-enable callback dispatch in case MiniAV_Dispose() was called previously
  // (e.g. during Flutter hot restart).
  miniav_dispatch_set_enabled(1);

  ctx->app_callback = callback;
  ctx->app_callback_user_data = user_data;

  MiniAVResultCode res = ctx->ops->start_capture(ctx, callback, user_data);
  if (res == MINIAV_SUCCESS) {
    ctx->is_running = true;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Screen capture started successfully.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to start screen capture, code: %d", res);
    ctx->app_callback = NULL;
    ctx->app_callback_user_data = NULL;
  }
  return res;
}

MiniAVResultCode MiniAV_Screen_StopCapture(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->ops || !ctx->ops->stop_capture) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Screen capture not running or already stopped.");
    return MINIAV_SUCCESS; // Already stopped, consider it success.
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Stopping screen capture...");
  MiniAVResultCode res = ctx->ops->stop_capture(ctx);

  // These should be cleared regardless of platform op success, as we are
  // stopping.
  ctx->is_running = false;
  ctx->app_callback = NULL;
  ctx->app_callback_user_data = NULL;

  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Screen capture stopped successfully.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to stop screen capture, code: %d", res);
  }
  return res;
}

// --- Display/window change subscriptions (uses generic polling watcher) ---

static MiniAVDeviceWatcher *g_screen_display_watcher = NULL;
static MiniAVDeviceWatcher *g_screen_window_watcher = NULL;

static MiniAVResultCode screen_displays_enum_adapter(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *ud) {
  (void)ud;
  return MiniAV_Screen_EnumerateDisplays(devices_out, count_out);
}
static MiniAVResultCode screen_windows_enum_adapter(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *ud) {
  (void)ud;
  return MiniAV_Screen_EnumerateWindows(devices_out, count_out);
}

MiniAVResultCode MiniAV_Screen_SetDisplayChangeCallback(
    MiniAVDeviceChangeCallback callback, void *user_data) {
  return miniav_device_watcher_set(&g_screen_display_watcher,
                                   screen_displays_enum_adapter, NULL,
                                   callback, user_data, 1500);
}
MiniAVResultCode MiniAV_Screen_SetWindowChangeCallback(
    MiniAVDeviceChangeCallback callback, void *user_data) {
  // Heavier polling; use a longer interval to limit EnumWindows cost.
  return miniav_device_watcher_set(&g_screen_window_watcher,
                                   screen_windows_enum_adapter, NULL,
                                   callback, user_data, 2500);
}

MiniAVResultCode MiniAV_Screen_SetContextLostCallback(
    MiniAVScreenContextHandle context_handle, MiniAVContextLostCallback callback,
    void *user_data) {
  MiniAVScreenContext *ctx = (MiniAVScreenContext *)context_handle;
  if (!ctx) return MINIAV_ERROR_INVALID_ARG;
  ctx->lost_cb = callback;
  ctx->lost_cb_user_data = user_data;
  return MINIAV_SUCCESS;
}

// --- Mobile seams: thin dispatch to the platform backends (no-ops off
// their platform so the FFI surface stays uniform). The platform functions
// are defined in the respective backend files.

#if defined(__ANDROID__)
extern MiniAVResultCode
miniav_screen_android_set_media_projection(void *jvm, void *media_projection);
#endif

MiniAVResultCode MiniAV_Screen_SetAndroidMediaProjection(
    void *jvm, void *media_projection) {
#if defined(__ANDROID__)
  return miniav_screen_android_set_media_projection(jvm, media_projection);
#else
  MINIAV_UNUSED(jvm);
  MINIAV_UNUSED(media_projection);
  return MINIAV_ERROR_NOT_SUPPORTED;
#endif
}

#if defined(__APPLE__) && TARGET_OS_IPHONE
extern MiniAVResultCode
miniav_screen_ios_set_app_group(const char *app_group_id);
#endif

MiniAVResultCode MiniAV_Screen_SetIOSAppGroup(const char *app_group_id) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
  return miniav_screen_ios_set_app_group(app_group_id);
#else
  MINIAV_UNUSED(app_group_id);
  return MINIAV_ERROR_NOT_SUPPORTED;
#endif
}

MiniAVResultCode MiniAV_Screen_SetCaptureCursor(
    MiniAVScreenContextHandle context, bool enabled) {
  MiniAVScreenContext *ctx = (MiniAVScreenContext *)context;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_configured) {
    // Backends read capture_cursor when they build the session at configure
    // time; toggling afterward would not take effect uniformly.
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "MiniAV_Screen_SetCaptureCursor called after configure; call it "
               "before ConfigureDisplay/Window.");
    return MINIAV_ERROR_INVALID_OPERATION;
  }
  ctx->capture_cursor = enabled;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "Screen: capture_cursor = %d.",
             enabled ? 1 : 0);
  return MINIAV_SUCCESS;
}
