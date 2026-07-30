#ifndef INJECT_CONTEXT_MACOS_CGEVENT_H
#define INJECT_CONTEXT_MACOS_CGEVENT_H

#include "../inject_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// macOS input-injection backend built on CGEventPost (ApplicationServices).
// Selected by the injection dispatcher via the "macOSCGEvent" backend-table
// entry. The two symbols below mirror the Windows/Linux arms and are declared
// (for the table) in inject_context.h; this header exists so the backend .mm
// has a matching pair like every other macOS backend in the tree.
//
// Requires Accessibility approval (System Settings > Privacy & Security >
// Accessibility). miniAV never PROMPTS for it — configure returns
// MINIAV_ERROR_PERMISSION_DENIED when the process is not trusted.
extern const InjectContextInternalOps g_inject_ops_macos;

MiniAVResultCode
miniav_inject_context_platform_init_macos(MiniAVInjectContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INJECT_CONTEXT_MACOS_CGEVENT_H
