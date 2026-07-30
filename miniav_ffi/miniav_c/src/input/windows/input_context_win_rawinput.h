#ifndef INPUT_CONTEXT_WIN_RAWINPUT_H
#define INPUT_CONTEXT_WIN_RAWINPUT_H

#include "../input_context.h"

#ifdef __cplusplus
extern "C" {
#endif

extern const InputContextInternalOps g_input_ops_win;

MiniAVResultCode
miniav_input_context_platform_init_windows(MiniAVInputContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INPUT_CONTEXT_WIN_RAWINPUT_H
