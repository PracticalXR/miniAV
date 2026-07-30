#ifndef INPUT_CONTEXT_H
#define INPUT_CONTEXT_H

#include "../../include/miniav_types.h"
#include "../../include/miniav_capture.h"
#include "../common/miniav_context_base.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration of the main context structure
typedef struct MiniAVInputContext MiniAVInputContext;

// Defines the operations for a platform-specific input implementation
typedef struct InputContextInternalOps {
    MiniAVResultCode (*init_platform)(MiniAVInputContext *ctx);
    MiniAVResultCode (*destroy_platform)(MiniAVInputContext *ctx);
    MiniAVResultCode (*enumerate_gamepads)(MiniAVDeviceInfo **devices_out, uint32_t *count_out);
    MiniAVResultCode (*configure)(MiniAVInputContext *ctx, const MiniAVInputConfig *config);
    MiniAVResultCode (*start_capture)(MiniAVInputContext *ctx);
    MiniAVResultCode (*stop_capture)(MiniAVInputContext *ctx);
} InputContextInternalOps;

// --- Input Backend Entry Structure ---
typedef struct MiniAVInputBackend {
    const char *name;
    const InputContextInternalOps *ops;
    MiniAVResultCode (*platform_init_for_selection)(MiniAVInputContext *ctx);
} MiniAVInputBackend;

// Main input context structure
struct MiniAVInputContext {
    MiniAVContextBase *base;
    const InputContextInternalOps *ops;
    void *platform_ctx;

    MiniAVInputConfig config;

    int is_configured;
    int is_running;

    // Latest IMU sample, cached for the MiniAV_Input_GetLatestMotion() pull
    // surface. Set only via miniav_input_deliver_motion(); has_latest_motion
    // stays 0 on platforms without an IMU (desktop) → pull returns NOT_RUNNING.
    MiniAVMotionEvent latest_motion;
    int has_latest_motion;
};

// Canonical motion delivery — the ONE entry point a platform backend calls per
// IMU sample (after converting to the canonical convention, see
// INPUT_LAYER_PLAN.md §1.5): caches the sample for the pull API AND fires the
// configured motion callback. Backends must not touch config/latest_motion
// directly.
void miniav_input_deliver_motion(MiniAVInputContext *ctx,
                                 const MiniAVMotionEvent *event);

// Platform-specific initialization functions
#if defined(_WIN32)
#include "windows/input_context_win_rawinput.h"
extern MiniAVResultCode miniav_input_context_platform_init_windows(MiniAVInputContext *ctx);
extern const InputContextInternalOps g_input_ops_win;
#elif defined(__linux__) && !defined(__ANDROID__)
extern MiniAVResultCode miniav_input_context_platform_init_linux(MiniAVInputContext *ctx);
extern const InputContextInternalOps g_input_ops_linux;
#elif defined(__ANDROID__)
#include "android/motion_context_android_sensor.h"
extern MiniAVResultCode miniav_input_context_platform_init_android(MiniAVInputContext *ctx);
extern const InputContextInternalOps g_input_ops_android;
#elif defined(__APPLE__)
// macOS and iOS are BOTH __APPLE__; split them via TargetConditionals so macOS
// keeps its CGEventTap+GameController backend and iOS gets the CoreMotion IMU
// backend (motion-only; no keyboard/mouse/gamepad on iOS for P0).
#include <TargetConditionals.h>
#if TARGET_OS_IOS
extern MiniAVResultCode miniav_input_context_platform_init_ios(MiniAVInputContext *ctx);
extern const InputContextInternalOps g_input_ops_ios;
#else
extern MiniAVResultCode miniav_input_context_platform_init_macos(MiniAVInputContext *ctx);
extern const InputContextInternalOps g_input_ops_macos;
#endif
#endif

#ifdef __cplusplus
}
#endif

#endif // INPUT_CONTEXT_H
