#ifndef SCREEN_CONTEXT_IOS_REPLAYKIT_H
#define SCREEN_CONTEXT_IOS_REPLAYKIT_H

#include "../screen_context.h"
#include "../../../include/miniav_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// iOS ReplayKit screen-capture backend. Exposes TWO pseudo-displays via
// EnumerateDisplays:
//   "app_screen"               — in-app tier (RPScreenRecorder, B.3a)
//   "system_screen_broadcast"  — system-wide tier via a Broadcast Upload
//                                Extension producing frames into an App Group
//                                shared-memory ring (B.3b).
// See MOBILE_PLATFORM_SPEC.md §B.3 and src/screen/ios/miniav_broadcast_protocol.h.
extern const ScreenContextInternalOps g_screen_ops_ios_replaykit;

// Platform-init-for-selection: binds ctx->ops to the ReplayKit backend.
MiniAVResultCode
miniav_screen_context_platform_init_ios_replaykit(MiniAVScreenContext *ctx);

// Free function dispatched from MiniAV_Screen_SetIOSAppGroup(). Must be called
// before configuring the "system_screen_broadcast" pseudo-display so the host
// can locate the App Group container (socket + ring file). Copies the string;
// pass NULL to clear.
MiniAVResultCode miniav_screen_ios_set_app_group(const char *app_group_id);

#ifdef __cplusplus
}
#endif

#endif // SCREEN_CONTEXT_IOS_REPLAYKIT_H
