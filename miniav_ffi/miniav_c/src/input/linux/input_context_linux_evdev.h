#ifndef INPUT_CONTEXT_LINUX_EVDEV_H
#define INPUT_CONTEXT_LINUX_EVDEV_H

#include "../input_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// Ops table for the Linux evdev input backend (keyboard + mouse + gamepad
// captured directly from /dev/input/event* with no external dependencies).
extern const InputContextInternalOps g_input_ops_linux;

// Selects the evdev backend for a freshly-created input context: allocates the
// platform context and wires ctx->ops. Mirrors
// miniav_input_context_platform_init_windows().
MiniAVResultCode
miniav_input_context_platform_init_linux(MiniAVInputContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INPUT_CONTEXT_LINUX_EVDEV_H
