#ifndef MOTION_CONTEXT_IOS_COREMOTION_H
#define MOTION_CONTEXT_IOS_COREMOTION_H

#include "../input_context.h"

// iOS motion / IMU backend: CoreMotion CMMotionManager -> deviceMotion.
//
// This is the mobile counterpart of the desktop input backends. It streams the
// OS-fused CMDeviceMotion sample (attitude quaternion + gravity + userAccel +
// rotationRate) and converts each sample to the ONE canonical MiniAVMotionEvent
// convention (see INPUT_LAYER_PLAN.md §1.5) before handing it to the shared
// delivery helper miniav_input_deliver_motion(). It does NOT implement
// keyboard/mouse (n/a on iOS); gamepad is a separate P1 concern
// (GameController) so enumerate_gamepads returns MINIAV_ERROR_NOT_SUPPORTED.
//
// Memory management: MRC (NO ARC), exactly like the macOS/iOS AVFoundation
// backends. This target is compiled WITHOUT -fobjc-arc.
//
// ============================================================================
// HOST APP REQUIREMENT — Info.plist NSMotionUsageDescription (MANDATORY)
// ----------------------------------------------------------------------------
// The host application's Info.plist MUST contain an `NSMotionUsageDescription`
// string. CoreMotion CRASHES the app the moment device-motion updates start if
// this key is absent — it is not a soft failure. miniAV NEVER prompts for
// permission and cannot add the key for you; the embedding app owns its
// Info.plist. (Device-motion *streaming* does not itself trigger a runtime
// permission dialog — the usage-description key is the only hard requirement.)
// ============================================================================
//
// These EXACT symbols are referenced by input_api.c and input_context.h.

#ifdef __cplusplus
extern "C" {
#endif

extern const InputContextInternalOps g_input_ops_ios;

MiniAVResultCode
miniav_input_context_platform_init_ios(MiniAVInputContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // MOTION_CONTEXT_IOS_COREMOTION_H
