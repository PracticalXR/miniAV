#ifndef INPUT_CONTEXT_MACOS_CGTAP_H
#define INPUT_CONTEXT_MACOS_CGTAP_H

#include "../input_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// macOS input backend: keyboard + mouse via CGEventTap, gamepad via the
// GameController framework. These EXACT symbols are referenced by input_api.c
// and input_context.h.
extern const InputContextInternalOps g_input_ops_macos;

MiniAVResultCode
miniav_input_context_platform_init_macos(MiniAVInputContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INPUT_CONTEXT_MACOS_CGTAP_H
