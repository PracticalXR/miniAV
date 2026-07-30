#ifndef CAMERA_CONTEXT_ANDROID_CAMERA2_H
#define CAMERA_CONTEXT_ANDROID_CAMERA2_H

#include "../camera_context.h" // For MiniAVCameraContext and CameraContextInternalOps

#ifdef __cplusplus
extern "C" {
#endif

// Global ops struct for the Android Camera2 NDK implementation.
// Used by camera_api.c for stateless calls (enumerate, get_formats,
// get_default_format) and by
// miniav_camera_context_platform_init_android_camera2 to assign to a context
// instance.
extern const CameraContextInternalOps g_camera_ops_android_camera2;

// Initializes the Android Camera2 (NDK) specific parts of the camera context.
// This function sets ctx->ops = &g_camera_ops_android_camera2; the caller
// (MiniAV_Camera_CreateContext) then invokes ops->init_platform(ctx).
MiniAVResultCode
miniav_camera_context_platform_init_android_camera2(MiniAVCameraContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // CAMERA_CONTEXT_ANDROID_CAMERA2_H
