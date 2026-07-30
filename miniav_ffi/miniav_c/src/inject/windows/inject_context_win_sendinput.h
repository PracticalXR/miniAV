#ifndef INJECT_CONTEXT_WIN_SENDINPUT_H
#define INJECT_CONTEXT_WIN_SENDINPUT_H

#include "../inject_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// Windows input-injection backend built on SendInput (user32). Selected by the
// injection dispatcher via the "WindowsSendInput" backend-table entry. The two
// symbols below mirror the Linux/macOS arms and are declared (for the table) in
// inject_context.h; this header exists so the backend .c has a matching pair
// like every other Windows backend in the tree.
extern const InjectContextInternalOps g_inject_ops_win;

MiniAVResultCode
miniav_inject_context_platform_init_windows(MiniAVInjectContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INJECT_CONTEXT_WIN_SENDINPUT_H
