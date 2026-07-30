#ifndef MOTION_CONTEXT_ANDROID_SENSOR_H
#define MOTION_CONTEXT_ANDROID_SENSOR_H

#include "../input_context.h"
#include "export.h"

#ifdef __cplusplus
extern "C" {
#endif

// Ops table for the Android motion/IMU backend (NDK ASensorManager: fused
// game-rotation-vector attitude + gyro + accel + gravity + linear-accel, no
// JNI on the hot path). Keyboard/mouse/gamepad are NOT captured here (mobile
// gamepad is a separate P1 JNI backend); enumerate_gamepads returns
// MINIAV_ERROR_NOT_SUPPORTED.
extern const InputContextInternalOps g_input_ops_android;

// Selects the Android sensor backend for a freshly-created input context:
// allocates the platform context and wires ctx->ops. Mirrors
// miniav_input_context_platform_init_linux().
MiniAVResultCode
miniav_input_context_platform_init_android(MiniAVInputContext *ctx);

// --- Display-rotation seam (Flutter-supplied) ------------------------------
//
// The NDK sensor path is Context-free, so it cannot read Display.getRotation()
// itself. The Flutter host pushes the CURRENT display rotation in here as a
// raw android.view.Surface.ROTATION_* ordinal (0,1,2,3 == 0/90/180/270 deg).
// The motion backend consumes it to (a) fill MiniAVMotionEvent.display and
// (b) build MiniAVMotionEvent.screen_orientation (the attitude remapped into
// the display frame) so tilt maps the same way in every orientation.
//
// Process-global (one display assumed), atomic, allocation-free. Safe to call
// from any thread, at any time; defaults to ROTATION_0 until first set. See
// MOTION_ANDROID_NOTES.md for the exact host-side contract. Returns
// MINIAV_ERROR_INVALID_ARG for an out-of-range ordinal (state unchanged).
// (This header is compiled only on Android; the symbol does not exist off it.)
MINIAV_API MiniAVResultCode
MiniAV_Input_SetAndroidDisplayRotation(int32_t surface_rotation);

#ifdef __cplusplus
}
#endif

#endif // MOTION_CONTEXT_ANDROID_SENSOR_H
