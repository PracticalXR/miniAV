#include "../../include/miniav_capture.h"
#include "../../include/miniav_types.h"
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h"
#include "inject_context.h"
#include <string.h>

// --- Backend Table ---
static const MiniAVInjectBackend g_inject_backends[] = {
#if defined(_WIN32)
    {"WindowsSendInput", &g_inject_ops_win,
     miniav_inject_context_platform_init_windows},
#elif defined(__linux__) && !defined(__ANDROID__)
    {"LinuxUinput", &g_inject_ops_linux,
     miniav_inject_context_platform_init_linux},
#elif defined(__APPLE__)
    {"macOSCGEvent", &g_inject_ops_macos,
     miniav_inject_context_platform_init_macos},
#endif
    {NULL, NULL, NULL} // Sentinel
};

MiniAVResultCode
MiniAV_Inject_CreateContext(MiniAVInjectContextHandle *context_handle) {
  if (!context_handle) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *context_handle = NULL;

  MiniAVInjectContext *ctx =
      (MiniAVInjectContext *)miniav_calloc(1, sizeof(MiniAVInjectContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to allocate MiniAVInjectContext.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ctx->base = miniav_context_base_create(NULL);
  if (!ctx->base) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to create base context for injection.");
    miniav_free(ctx);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  const MiniAVInjectBackend *selected_backend = NULL;

  for (const MiniAVInjectBackend *be = g_inject_backends; be->name != NULL;
       ++be) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to initialize injection backend for context: %s",
               be->name);
    if (be->platform_init_for_selection) {
      res = be->platform_init_for_selection(ctx);
      if (res == MINIAV_SUCCESS) {
        selected_backend = be;
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "Successfully selected injection backend for context: %s",
                   selected_backend->name);
        break;
      } else {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Injection backend %s platform_init_for_selection failed "
                   "with code %d. Trying next.",
                   be->name, res);
        if (ctx->platform_ctx) {
          miniav_free(ctx->platform_ctx);
          ctx->platform_ctx = NULL;
        }
        ctx->ops = NULL;
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Injection backend %s has no platform_init_for_selection "
                 "function.",
                 be->name);
      res = MINIAV_ERROR_NOT_IMPLEMENTED;
    }
  }

  if (res != MINIAV_SUCCESS || !selected_backend) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "No suitable injection backend found or all failed to "
               "initialize for context.");
    miniav_context_base_destroy(ctx->base);
    miniav_free(ctx);
    return (res == MINIAV_SUCCESS) ? MINIAV_ERROR_NOT_SUPPORTED : res;
  }

  if (!ctx->ops || !ctx->ops->init_platform) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Platform ops or ops->init_platform not set by selected "
               "injection backend '%s'.",
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
               "ctx->ops->init_platform for injection backend '%s' failed "
               "with code %d.",
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

  *context_handle = (MiniAVInjectContextHandle)ctx;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Injection context created successfully with backend: %s",
             selected_backend->name);
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Inject_DestroyContext(MiniAVInjectContextHandle context_handle) {
  MiniAVInjectContext *ctx = (MiniAVInjectContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Destroying injection context...");
  if (ctx->ops && ctx->ops->destroy_platform) {
    MiniAVResultCode destroy_res = ctx->ops->destroy_platform(ctx);
    if (destroy_res == MINIAV_ERROR_TIMEOUT) {
      // A platform resource could not be torn down in bounded time; leak the
      // parent rather than free memory a live OS resource still references.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Inject DestroyContext: platform teardown timed out — "
                 "leaking the context.");
      return destroy_res;
    }
  } else {
    miniav_free(ctx->platform_ctx);
  }
  ctx->platform_ctx = NULL;

  if (ctx->base) {
    miniav_context_base_destroy(ctx->base);
  }
  miniav_free(ctx);
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Injection context destroyed successfully.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Inject_Configure(MiniAVInjectContextHandle context_handle,
                        uint32_t input_types) {
  MiniAVInjectContext *ctx = (MiniAVInjectContext *)context_handle;
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->ops || !ctx->ops->configure) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Injection context or configure op not available.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  MiniAVResultCode res = ctx->ops->configure(ctx, input_types);
  if (res == MINIAV_SUCCESS) {
    ctx->is_configured = 1;
    ctx->configured_types = input_types;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "Injection configured: types=0x%x",
               input_types);
  } else {
    ctx->is_configured = 0;
    ctx->configured_types = 0;
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Injection configuration failed with code: %d", res);
  }
  return res;
}

MiniAVResultCode
MiniAV_Inject_Keyboard(MiniAVInjectContextHandle context_handle,
                       const MiniAVKeyboardEvent *event) {
  MiniAVInjectContext *ctx = (MiniAVInjectContext *)context_handle;
  if (!ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_configured) {
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  if (!ctx->ops || !ctx->ops->inject_keyboard) {
    return MINIAV_ERROR_NOT_SUPPORTED;
  }
  return ctx->ops->inject_keyboard(ctx, event);
}

MiniAVResultCode
MiniAV_Inject_Mouse(MiniAVInjectContextHandle context_handle,
                    const MiniAVMouseEvent *event) {
  MiniAVInjectContext *ctx = (MiniAVInjectContext *)context_handle;
  if (!ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (!ctx->is_configured) {
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  if (!ctx->ops || !ctx->ops->inject_mouse) {
    return MINIAV_ERROR_NOT_SUPPORTED;
  }
  return ctx->ops->inject_mouse(ctx, event);
}
