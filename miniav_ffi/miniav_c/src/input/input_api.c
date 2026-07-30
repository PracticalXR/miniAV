#include "../../include/miniav_capture.h"
#include "../../include/miniav_types.h"
#include "../common/miniav_device_watcher.h"
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h"
#include "input_context.h"
#include <string.h>

#if defined(__APPLE__)
// macOS vs iOS backend selection below hinges on TARGET_OS_IOS. Include this
// explicitly so an undefined macro can never silently evaluate to 0 and pick
// the wrong backend. (Also pulled in transitively via input_context.h.)
#include <TargetConditionals.h>
#endif

// --- Backend Table ---
static const MiniAVInputBackend g_input_backends[] = {
#if defined(_WIN32)
    {"WindowsHooks+XInput", &g_input_ops_win,
     miniav_input_context_platform_init_windows},
#elif defined(__linux__) && !defined(__ANDROID__)
    {"LinuxEvdev", &g_input_ops_linux,
     miniav_input_context_platform_init_linux},
#elif defined(__ANDROID__)
    {"AndroidSensorMotion", &g_input_ops_android,
     miniav_input_context_platform_init_android},
#elif defined(__APPLE__)
#if TARGET_OS_IOS
    {"iOSCoreMotion", &g_input_ops_ios,
     miniav_input_context_platform_init_ios},
#else
    {"macOSEventTap+IOKit", &g_input_ops_macos,
     miniav_input_context_platform_init_macos},
#endif
#endif
    {NULL, NULL, NULL} // Sentinel
};

MiniAVResultCode MiniAV_Input_EnumerateGamepads(MiniAVDeviceInfo **devices,
                                                uint32_t *count) {
  if (!devices || !count) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *devices = NULL;
  *count = 0;

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  for (const MiniAVInputBackend *be = g_input_backends; be->name != NULL;
       ++be) {
    if (be->ops && be->ops->enumerate_gamepads) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Attempting EnumerateGamepads with input backend: %s",
                 be->name);
      res = be->ops->enumerate_gamepads(devices, count);
      if (res == MINIAV_SUCCESS) {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "EnumerateGamepads successful with input backend: %s",
                   be->name);
        return MINIAV_SUCCESS;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "EnumerateGamepads with input backend %s failed (code: %d). "
                 "Trying next.",
                 be->name, res);
    }
  }

  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Input_EnumerateGamepads: No suitable backend found or all "
             "failed.");
  return res;
}

MiniAVResultCode
MiniAV_Input_CreateContext(MiniAVInputContextHandle *context_handle) {
  if (!context_handle) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *context_handle = NULL;

  MiniAVInputContext *ctx =
      (MiniAVInputContext *)miniav_calloc(1, sizeof(MiniAVInputContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to allocate MiniAVInputContext.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ctx->base = miniav_context_base_create(NULL);
  if (!ctx->base) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to create base context for input.");
    miniav_free(ctx);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  const MiniAVInputBackend *selected_backend = NULL;

  for (const MiniAVInputBackend *be = g_input_backends; be->name != NULL;
       ++be) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to initialize input backend for context: %s",
               be->name);
    if (be->platform_init_for_selection) {
      res = be->platform_init_for_selection(ctx);
      if (res == MINIAV_SUCCESS) {
        selected_backend = be;
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "Successfully selected input backend for context: %s",
                   selected_backend->name);
        break;
      } else {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Input backend %s platform_init_for_selection failed with "
                   "code %d. Trying next.",
                   be->name, res);
        if (ctx->platform_ctx) {
          miniav_free(ctx->platform_ctx);
          ctx->platform_ctx = NULL;
        }
        ctx->ops = NULL;
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Input backend %s has no platform_init_for_selection "
                 "function.",
                 be->name);
      res = MINIAV_ERROR_NOT_IMPLEMENTED;
    }
  }

  if (res != MINIAV_SUCCESS || !selected_backend) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "No suitable input backend found or all failed to initialize "
               "for context.");
    miniav_context_base_destroy(ctx->base);
    miniav_free(ctx);
    return (res == MINIAV_SUCCESS) ? MINIAV_ERROR_NOT_SUPPORTED : res;
  }

  if (!ctx->ops || !ctx->ops->init_platform) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Platform ops or ops->init_platform not set by selected input "
               "backend '%s'.",
               selected_backend->name);
    if (ctx->platform_ctx)
      miniav_free(ctx->platform_ctx);
    miniav_context_base_destroy(ctx->base);
    miniav_free(ctx);
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  res = ctx->ops->init_platform(ctx);
  if (res != MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "ctx->ops->init_platform for input backend '%s' failed with "
               "code %d.",
               selected_backend->name, res);
    if (ctx->ops->destroy_platform) {
      ctx->ops->destroy_platform(ctx);
    } else {
      miniav_free(ctx->platform_ctx);
    }
    miniav_context_base_destroy(ctx->base);
    miniav_free(ctx);
    return res;
  }

  *context_handle = (MiniAVInputContextHandle)ctx;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Input context created successfully with backend: %s",
             selected_backend->name);
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Input_DestroyContext(MiniAVInputContextHandle context_handle) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Destroying input context...");
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Input context is running. Attempting to stop capture...");
    MiniAV_Input_StopCapture(context_handle);
  }

  if (ctx->ops && ctx->ops->destroy_platform) {
    MiniAVResultCode destroy_res = ctx->ops->destroy_platform(ctx);
    if (destroy_res == MINIAV_ERROR_TIMEOUT) {
      // A capture thread survived teardown and still dereferences THIS parent
      // context (callbacks, config) — leak it too rather than free memory a
      // live thread uses.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Input DestroyContext: platform teardown timed out — "
                 "leaking the context (a capture thread is still alive).");
      return destroy_res;
    }
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "destroy_platform op not available for input. Freeing "
               "platform_ctx directly if it exists.");
    miniav_free(ctx->platform_ctx);
  }
  ctx->platform_ctx = NULL;

  if (ctx->base) {
    miniav_context_base_destroy(ctx->base);
  }
  miniav_free(ctx);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "Input context destroyed successfully.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Input_Configure(MiniAVInputContextHandle context_handle,
                       const MiniAVInputConfig *config) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)context_handle;
  if (!ctx || !config) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->ops || !ctx->ops->configure) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Input context or configure op not available.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Cannot configure input while capture is running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  MiniAVResultCode res = ctx->ops->configure(ctx, config);
  if (res == MINIAV_SUCCESS) {
    ctx->is_configured = 1;
    ctx->config = *config;
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Input configured: types=0x%x, mouse_throttle=%u Hz, "
               "gamepad_poll=%u Hz",
               config->input_types, config->mouse_throttle_hz,
               config->gamepad_poll_hz);
  } else {
    ctx->is_configured = 0;
    memset(&ctx->config, 0, sizeof(MiniAVInputConfig));
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Input configuration failed with code: %d", res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Input_StartCapture(MiniAVInputContextHandle context_handle) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Input must be configured before starting capture.");
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  if (ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "Input capture is already running.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  if (!ctx->ops || !ctx->ops->start_capture) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "start_capture op not available for input.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  // Re-enable callback dispatch in case MiniAV_Dispose() was called previously.
  miniav_dispatch_set_enabled(1);

  MiniAVResultCode res = ctx->ops->start_capture(ctx);
  if (res == MINIAV_SUCCESS) {
    ctx->is_running = 1;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Input capture started.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to start input capture, code: %d", res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Input_StopCapture(MiniAVInputContextHandle context_handle) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Input capture not running or already stopped.");
    return MINIAV_SUCCESS;
  }
  if (!ctx->ops || !ctx->ops->stop_capture) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "stop_capture op not available for input.");
    ctx->is_running = 0;
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Stopping input capture...");
  MiniAVResultCode res = ctx->ops->stop_capture(ctx);
  ctx->is_running = 0;

  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Input capture stopped successfully.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to stop input capture, code: %d", res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Input_GetLatestMotion(MiniAVInputContextHandle context_handle,
                            MiniAVMotionEvent *out_event) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)context_handle;
  if (!ctx || !out_event) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_running || !ctx->has_latest_motion) {
    return MINIAV_ERROR_NOT_RUNNING;
  }
  *out_event = ctx->latest_motion;
  return MINIAV_SUCCESS;
}

void miniav_input_deliver_motion(MiniAVInputContext *ctx,
                                 const MiniAVMotionEvent *event) {
  if (!ctx || !event) {
    return;
  }
  ctx->latest_motion = *event;
  ctx->has_latest_motion = 1;
  if (ctx->config.motion_callback) {
    ctx->config.motion_callback(event, ctx->config.user_data);
  }
}

// --- Subscriptions ---

static MiniAVDeviceWatcher *g_input_gamepad_watcher = NULL;

static MiniAVResultCode input_gamepad_watcher_enumerate_adapter(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *user_data) {
  (void)user_data;
  return MiniAV_Input_EnumerateGamepads(devices_out, count_out);
}

MiniAVResultCode MiniAV_Input_SetGamepadChangeCallback(
    MiniAVDeviceChangeCallback callback, void *user_data) {
  return miniav_device_watcher_set(&g_input_gamepad_watcher,
                                   input_gamepad_watcher_enumerate_adapter,
                                   NULL, callback, user_data, 1500);
}
