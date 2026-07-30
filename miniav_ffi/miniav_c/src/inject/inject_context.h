#ifndef INJECT_CONTEXT_H
#define INJECT_CONTEXT_H

#include "../../include/miniav_capture.h"
#include "../../include/miniav_types.h"
#include "../common/miniav_context_base.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration of the main context structure
typedef struct MiniAVInjectContext MiniAVInjectContext;

// Operations for a platform-specific injection implementation. Injection is
// synchronous — inject_keyboard/inject_mouse perform the event immediately;
// there is no capture thread or callback.
typedef struct InjectContextInternalOps {
  MiniAVResultCode (*init_platform)(MiniAVInjectContext *ctx);
  MiniAVResultCode (*destroy_platform)(MiniAVInjectContext *ctx);
  MiniAVResultCode (*configure)(MiniAVInjectContext *ctx, uint32_t input_types);
  MiniAVResultCode (*inject_keyboard)(MiniAVInjectContext *ctx,
                                      const MiniAVKeyboardEvent *event);
  MiniAVResultCode (*inject_mouse)(MiniAVInjectContext *ctx,
                                   const MiniAVMouseEvent *event);
} InjectContextInternalOps;

// --- Injection Backend Entry Structure ---
typedef struct MiniAVInjectBackend {
  const char *name;
  const InjectContextInternalOps *ops;
  MiniAVResultCode (*platform_init_for_selection)(MiniAVInjectContext *ctx);
} MiniAVInjectBackend;

// Main injection context structure
struct MiniAVInjectContext {
  MiniAVContextBase *base;
  const InjectContextInternalOps *ops;
  void *platform_ctx;

  uint32_t configured_types; // Bitmask of MiniAVInputType
  int is_configured;
};

// Platform-specific initialization functions. Injection is a desktop-only
// module (CMake forces it OFF on mobile/web), so the Apple arm is bare
// __APPLE__ like the input-capture module — it is never compiled on iOS.
#if defined(_WIN32)
extern MiniAVResultCode
miniav_inject_context_platform_init_windows(MiniAVInjectContext *ctx);
extern const InjectContextInternalOps g_inject_ops_win;
#elif defined(__linux__) && !defined(__ANDROID__)
extern MiniAVResultCode
miniav_inject_context_platform_init_linux(MiniAVInjectContext *ctx);
extern const InjectContextInternalOps g_inject_ops_linux;
#elif defined(__APPLE__)
extern MiniAVResultCode
miniav_inject_context_platform_init_macos(MiniAVInjectContext *ctx);
extern const InjectContextInternalOps g_inject_ops_macos;
#endif

#ifdef __cplusplus
}
#endif

#endif // INJECT_CONTEXT_H
