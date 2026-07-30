#include "../common/miniav_device_watcher.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h" // For miniav_calloc, miniav_free, miniav_strdup
#include "loopback_context.h"
#include <stdio.h>  // For sscanf
#include <string.h> // For memset, strncpy

// --- Platform-Specific Ops and Init Declarations ---
// These need to be defined in their respective platform files.
// Example for Windows (e.g., in loopback_context_win_wasapi.c)
#ifdef _WIN32
extern const LoopbackContextInternalOps
    g_loopback_ops_wasapi;
extern MiniAVResultCode miniav_loopback_context_platform_init_windows_wasapi(
    MiniAVLoopbackContext *ctx);
#endif

// Example for macOS (e.g., in loopback_context_macos_coreaudio.c)
#if defined(__APPLE__) && !TARGET_OS_IPHONE
extern const LoopbackContextInternalOps
    g_loopback_ops_macos_coreaudio;
extern MiniAVResultCode miniav_loopback_context_platform_init_macos_coreaudio(
    MiniAVLoopbackContext *ctx);
#endif

#if defined(__linux__) && !defined(__ANDROID__)
extern const LoopbackContextInternalOps
    g_loopback_ops_linux_pipewire;
extern MiniAVResultCode miniav_loopback_context_platform_init_linux_pipewire(
    MiniAVLoopbackContext *ctx);
// Potentially add PipeWire or others here too
#endif

// --- Backend Table ---
// Order matters for default preference.
static const MiniAVLoopbackBackend g_loopback_backends[] = {
#ifdef _WIN32
    {"WASAPI", &g_loopback_ops_wasapi,
     miniav_loopback_context_platform_init_windows_wasapi},
#endif
#if defined(__APPLE__) && !TARGET_OS_IPHONE
    {"CoreAudio", &g_loopback_ops_macos_coreaudio,
     miniav_loopback_context_platform_init_macos_coreaudio},
#endif
#if defined(__linux__) && !defined(__ANDROID__)
    {"PipeWire", &g_loopback_ops_linux_pipewire,
     miniav_loopback_context_platform_init_linux_pipewire},
#endif
    {NULL, NULL, NULL} // Sentinel
};

MiniAVResultCode
MiniAV_Loopback_EnumerateTargets(MiniAVLoopbackTargetType target_type_filter,
                                 MiniAVDeviceInfo **targets_out,
                                 uint32_t *count_out) {
  if (!targets_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *targets_out = NULL;
  *count_out = 0;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Enumerating loopback audio targets with filter: %d",
             target_type_filter);

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVLoopbackBackend *backend_entry = g_loopback_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->enumerate_targets_platform) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting EnumerateTargets with loopback backend: %s",
                 backend_entry->name);
      res = backend_entry->ops->enumerate_targets_platform(
          target_type_filter, targets_out, count_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "EnumerateTargets successful with loopback backend: %s",
                   backend_entry->name);
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "EnumerateTargets with loopback backend %s failed or found no "
                 "targets (code: %d). Trying next.",
                 backend_entry->name, res);
    } else {
      miniav_log(
          MINIAV_LOG_LEVEL_DEBUG,
          "Loopback backend %s does not support enumerate_targets_platform.",
          backend_entry->name);
    }
  }

  miniav_log(
      MINIAV_LOG_LEVEL_WARN,
      "Loopback_EnumerateTargets: No suitable backend found or all failed.");
  return res;
}

MiniAVResultCode MiniAV_Loopback_GetSupportedFormats(
    const char *target_device_id, MiniAVAudioInfo **formats_out,
    uint32_t *count_out) {
  if (!formats_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *formats_out = NULL;
  *count_out = 0;

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVLoopbackBackend *backend_entry = g_loopback_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->get_supported_formats) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting GetSupportedFormats with loopback backend: %s for "
                 "target: %s",
                 backend_entry->name,
                 target_device_id ? target_device_id : "(system default)");
      res = backend_entry->ops->get_supported_formats(
          target_device_id, formats_out, count_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "GetSupportedFormats successful with loopback backend: %s "
                   "for target: %s",
                   backend_entry->name,
                   target_device_id ? target_device_id : "(system default)");
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "GetSupportedFormats with loopback backend %s failed for "
                 "target %s (code: %d). Trying next.",
                 backend_entry->name,
                 target_device_id ? target_device_id : "(system default)", res);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Loopback backend %s does not support get_supported_formats.",
                 backend_entry->name);
    }
  }
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Loopback_GetSupportedFormats: No suitable backend found or all "
             "failed for target: %s",
             target_device_id ? target_device_id : "(system default)");
  return res;
}

MiniAVResultCode MiniAV_Loopback_GetDefaultFormat(const char *target_device_id,
                                                  MiniAVAudioInfo *format_out) {
  if (!format_out) { // target_device_id can be NULL for system default
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(format_out, 0, sizeof(MiniAVAudioInfo));

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVLoopbackBackend *backend_entry = g_loopback_backends;
       backend_entry->name != NULL; ++backend_entry) {
    if (backend_entry->ops && backend_entry->ops->get_default_format_platform) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting GetDefaultFormat with loopback backend: %s for "
                 "target: %s",
                 backend_entry->name,
                 target_device_id ? target_device_id : "(system default)");
      res =
          backend_entry->ops->get_default_format_platform(target_device_id, format_out);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "GetDefaultFormat successful with loopback backend: %s for "
                   "target: %s",
                   backend_entry->name,
                   target_device_id ? target_device_id : "(system default)");
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "GetDefaultFormat with loopback backend %s failed for target "
                 "%s (code: %d). Trying next.",
                 backend_entry->name,
                 target_device_id ? target_device_id : "(system default)", res);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Loopback backend %s does not support get_default_format.",
                 backend_entry->name);
    }
  }
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Loopback_GetDefaultFormat: No suitable backend found or all "
             "failed for target: %s",
             target_device_id ? target_device_id : "(system default)");
  return res;
}

MiniAVResultCode
MiniAV_Loopback_CreateContext(MiniAVLoopbackContextHandle *context_handle_out) {
  if (!context_handle_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *context_handle_out = NULL;

  MiniAVLoopbackContext *ctx =
      (MiniAVLoopbackContext *)miniav_calloc(1, sizeof(MiniAVLoopbackContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to allocate memory for LoopbackContext.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  const MiniAVLoopbackBackend *selected_backend_entry = NULL;

  for (const MiniAVLoopbackBackend *backend_entry = g_loopback_backends;
       backend_entry->name != NULL; ++backend_entry) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to initialize loopback backend for context: %s",
               backend_entry->name);
    // The backend_entry->platform_init is responsible for minimal setup
    // and setting ctx->ops and potentially ctx->platform_ctx if needed early.
    res = backend_entry->platform_init(ctx);
    if (res == MINIAV_SUCCESS) {
      selected_backend_entry = backend_entry;
      miniav_log(MINIAV_LOG_LEVEL_INFO,
                 "Successfully selected loopback backend for context: %s",
                 selected_backend_entry->name);
      break;
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Loopback backend %s init failed for context with code %d. "
                 "Trying next.",
                 backend_entry->name, res);
      if (ctx->platform_ctx) {
        miniav_free(ctx->platform_ctx);
        ctx->platform_ctx = NULL;
      }
      ctx->ops = NULL;
    }
  }

  if (res != MINIAV_SUCCESS || !selected_backend_entry) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "No suitable loopback backend found or "
                                       "all failed to initialize for context.");
    miniav_free(ctx);
    return (res == MINIAV_SUCCESS) ? MINIAV_ERROR_NOT_SUPPORTED : res;
  }

  // Ops should be set by backend_entry->platform_init. Now call the main
  // init_platform.
  if (!ctx->ops || !ctx->ops->init_platform) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Platform ops or ops->init_platform not set by selected "
               "loopback backend '%s'.",
               selected_backend_entry->name);
    if (ctx->platform_ctx)
      miniav_free(ctx->platform_ctx);
    miniav_free(ctx);
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  res = ctx->ops->init_platform(
      ctx); // This performs further platform-specific initialization.
  if (res != MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "ctx->ops->init_platform for loopback backend '%s' failed with "
               "code %d.",
               selected_backend_entry->name, res);
    if (ctx->ops->destroy_platform) {
      ctx->ops->destroy_platform(ctx);
    } else {
      miniav_free(ctx->platform_ctx);
    }
    miniav_free(ctx);
    return res;
  }

  ctx->is_configured = false;
  ctx->is_running = false;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "LoopbackContext created successfully with backend: %s",
             selected_backend_entry->name);
  *context_handle_out = (MiniAVLoopbackContextHandle)ctx;
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Loopback_DestroyContext(MiniAVLoopbackContextHandle context_handle) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_HANDLE;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "Destroying LoopbackContext...");
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Loopback capture is running during "
                                      "DestroyContext. Attempting to stop.");
    if (ctx->ops && ctx->ops->stop_capture) {
      ctx->ops->stop_capture(ctx); // Best effort to stop
    }
    ctx->is_running = false;
  }

  if (ctx->ops && ctx->ops->destroy_platform) {
    MiniAVResultCode destroy_res =
        ctx->ops->destroy_platform(ctx); // This should free ctx->platform_ctx
    if (destroy_res == MINIAV_ERROR_TIMEOUT) {
      // The platform layer could not reap a capture thread and leaked its
      // platform context. That thread also dereferences THIS parent context
      // (callbacks, configured format), so it must be leaked too — freeing
      // it here would be a use-after-free.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Loopback DestroyContext: platform teardown timed out — "
                 "leaking the context (a capture thread is still alive).");
      return destroy_res;
    }
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "destroy_platform op not available for loopback context. "
               "Freeing platform_ctx directly.");
    miniav_free(ctx->platform_ctx);
  }
  ctx->platform_ctx = NULL;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "LoopbackContext destroyed.");
  miniav_free(ctx);
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Loopback_Configure(MiniAVLoopbackContextHandle context_handle,
                          const char *target_device_id_str,
                          const MiniAVAudioInfo *format) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx || !ctx->ops || !ctx->ops->configure_loopback) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Configure: Invalid context or ops.");
    return MINIAV_ERROR_INVALID_HANDLE;
  }
  if (!format) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Configure: Format cannot be NULL.");
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure loopback while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  MiniAVLoopbackTargetInfo target_info_struct;
  const MiniAVLoopbackTargetInfo *target_info_to_pass = NULL;
  const char *device_id_to_pass =
      NULL; // For platforms that use device ID string directly

  if (target_device_id_str) {
    if (strncmp(target_device_id_str, "hwnd:", 5) == 0) {
      memset(&target_info_struct, 0, sizeof(MiniAVLoopbackTargetInfo));
      target_info_struct.type = MINIAV_LOOPBACK_TARGET_WINDOW;
      void *temp_hwnd_ptr = NULL;
      if (sscanf(target_device_id_str + 5, "%p", &temp_hwnd_ptr) == 1) {
        target_info_struct.TARGETHANDLE.window_handle =
            (MiniAVWindowHandle)temp_hwnd_ptr;
        target_info_to_pass = &target_info_struct;
      } else {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to parse HWND from ID: %s",
                   target_device_id_str);
        return MINIAV_ERROR_INVALID_ARG;
      }
    } else if (strncmp(target_device_id_str, "pid:", 4) == 0) {
      memset(&target_info_struct, 0, sizeof(MiniAVLoopbackTargetInfo));
      target_info_struct.type = MINIAV_LOOPBACK_TARGET_PROCESS;
      if (sscanf(target_device_id_str + 4, "%u",
                 &target_info_struct.TARGETHANDLE.process_id) ==
          1) { // %u for uint32_t
        target_info_to_pass = &target_info_struct;
      } else {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to parse PID from ID: %s",
                   target_device_id_str);
        return MINIAV_ERROR_INVALID_ARG;
      }
    } else {
      device_id_to_pass =
          target_device_id_str; // Assumed to be a system audio device ID string
    }
  } else {
    // NULL target_device_id_str means system default audio device
    // The platform layer's configure_loopback op should interpret NULL
    // device_id_to_pass as system default.
    device_id_to_pass = NULL;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Configuring loopback with target_info: %p, device_id: %s",
             (void *)target_info_to_pass,
             device_id_to_pass ? device_id_to_pass : "(null)");

  MiniAVResultCode res = ctx->ops->configure_loopback(
      ctx, target_info_to_pass, device_id_to_pass, format);

  if (res == MINIAV_SUCCESS) {
    ctx->is_configured = true;
    ctx->configured_video_format =
        *format; // Cache the requested format, backend might adjust and update
                 // via get_configured_video_format
    if (target_info_to_pass) {
      ctx->current_target_info = *target_info_to_pass;
      memset(ctx->current_target_device_id, 0, MINIAV_DEVICE_ID_MAX_LEN);
    } else {
      if (device_id_to_pass) {
        strncpy(ctx->current_target_device_id, device_id_to_pass,
                MINIAV_DEVICE_ID_MAX_LEN - 1);
        ctx->current_target_device_id[MINIAV_DEVICE_ID_MAX_LEN - 1] = '\0';
      } else {
        memset(ctx->current_target_device_id, 0,
               MINIAV_DEVICE_ID_MAX_LEN); // System default
      }
      ctx->current_target_info.type =
          MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO; // Default if device_id was used
      ctx->current_target_info.TARGETHANDLE.process_id = 0;
      ctx->current_target_info.TARGETHANDLE.window_handle = NULL;
    }
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Loopback configured successfully.");
  } else {
    ctx->is_configured = false;
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Loopback configuration failed (code: %d).", res);
  }
  return res;
}

MiniAVResultCode MiniAV_Loopback_ConfigureWithTargetInfo(
    MiniAVLoopbackContextHandle context_handle,
    const MiniAVLoopbackTargetInfo *target_info,
    const MiniAVAudioInfo *format) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx || !ctx->ops || !ctx->ops->configure_loopback) {
    return MINIAV_ERROR_INVALID_HANDLE;
  }
  if (!target_info || !format) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure loopback while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Configuring loopback with explicit TargetInfo (type: %d).",
             target_info->type);
  MiniAVResultCode res = ctx->ops->configure_loopback(
      ctx, target_info, NULL, format); // device_id is NULL
  if (res == MINIAV_SUCCESS) {
    ctx->is_configured = true;
    ctx->configured_video_format = *format; // Cache requested
    ctx->current_target_info = *target_info;
    memset(ctx->current_target_device_id, 0, MINIAV_DEVICE_ID_MAX_LEN);
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Loopback configured successfully with TargetInfo.");
  } else {
    ctx->is_configured = false;
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Loopback configuration with TargetInfo failed (code: %d).",
               res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Loopback_StartCapture(MiniAVLoopbackContextHandle context_handle,
                             MiniAVBufferCallback callback, void *user_data) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx || !ctx->ops || !ctx->ops->start_capture) {
    return MINIAV_ERROR_INVALID_HANDLE;
  }
  if (!callback) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Loopback must be configured before starting capture.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Loopback capture is already running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  // Re-enable callback dispatch in case MiniAV_Dispose() was called previously.
  miniav_dispatch_set_enabled(1);

  ctx->app_callback = callback;
  ctx->app_callback_user_data = user_data;

  MiniAVResultCode res = ctx->ops->start_capture(ctx, callback, user_data);
  if (res == MINIAV_SUCCESS) {
    ctx->is_running = true;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Loopback capture started.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to start loopback capture (code: %d).", res);
    ctx->app_callback = NULL;
    ctx->app_callback_user_data = NULL;
  }
  return res;
}

MiniAVResultCode
MiniAV_Loopback_StopCapture(MiniAVLoopbackContextHandle context_handle) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx || !ctx->ops || !ctx->ops->stop_capture) {
    return MINIAV_ERROR_INVALID_HANDLE;
  }
  if (!ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Loopback capture is not running.");
    return MINIAV_SUCCESS; // Not an error to stop an already stopped capture
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Stopping loopback capture...");
  MiniAVResultCode res = ctx->ops->stop_capture(ctx);
  ctx->is_running = false; // Update state regardless of backend result

  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Loopback capture stopped successfully.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to stop loopback capture (code: %d).", res);
  }
  // Do not clear app_callback here, user might want to restart with same
  // callback.
  return res;
}

MiniAVResultCode
MiniAV_Loopback_GetConfiguredFormat(MiniAVLoopbackContextHandle context_handle,
                                    MiniAVAudioInfo *format_out) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_HANDLE;
  }
  if (!format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(format_out, 0, sizeof(MiniAVAudioInfo));

  if (!ctx->is_configured) {
    miniav_log(
        MINIAV_LOG_LEVEL_WARN,
        "Loopback not configured. Format information may be incomplete.");
  }

  if (ctx->ops && ctx->ops->get_configured_video_format) {
    return ctx->ops->get_configured_video_format(ctx, format_out);
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "get_configured_video_format op not available. "
                                      "Using cached format if configured.");
    // Fallback to the cached format if the op is missing (should ideally not
    // happen for a valid context)
    if (ctx->is_configured) {
      *format_out = ctx->configured_video_format;
      return MINIAV_SUCCESS;
    }
  }
  miniav_log(
      MINIAV_LOG_LEVEL_ERROR,
      "Cannot get configured format: context not configured or op missing.");
  return MINIAV_ERROR_NOT_INITIALIZED;
}
// --- Loopback device change / context-lost subscriptions ---

static MiniAVDeviceWatcher *g_loopback_watcher = NULL;

static MiniAVResultCode loopback_enum_adapter(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *ud) {
  (void)ud;
  return MiniAV_Loopback_EnumerateTargets(MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO,
                                          devices_out, count_out);
}

MiniAVResultCode MiniAV_Loopback_SetDeviceChangeCallback(
    MiniAVDeviceChangeCallback callback, void *user_data) {
  return miniav_device_watcher_set(&g_loopback_watcher, loopback_enum_adapter,
                                   NULL, callback, user_data, 1500);
}

MiniAVResultCode MiniAV_Loopback_SetContextLostCallback(
    MiniAVLoopbackContextHandle context_handle,
    MiniAVContextLostCallback callback, void *user_data) {
  MiniAVLoopbackContext *ctx = (MiniAVLoopbackContext *)context_handle;
  if (!ctx) return MINIAV_ERROR_INVALID_ARG;
  ctx->lost_cb = callback;
  ctx->lost_cb_user_data = user_data;
  return MINIAV_SUCCESS;
}
