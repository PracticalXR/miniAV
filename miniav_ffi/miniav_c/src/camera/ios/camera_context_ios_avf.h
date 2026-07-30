#ifndef CAMERA_CONTEXT_IOS_AVF_H
#define CAMERA_CONTEXT_IOS_AVF_H

#include "../camera_context.h" // Provides MiniAVCameraContext and CameraContextInternalOps

// iOS AVFoundation camera backend.
//
// This is a PORT of src/camera/macos/camera_context_macos_avf.mm. It shares the
// full macOS capture pipeline (AVCaptureSession -> CVPixelBuffer -> zero-copy
// planar CVMetalTexture path + CPU fallback + rebased timestamps + one-shot
// lost_cb + bounded-drain teardown). It diverges only where iOS demands:
//   - AVCaptureDeviceDiscoverySession restricted to the built-in physical
//     cameras (wide/ultra-wide/telephoto); position (front/back) is baked into
//     the device name string. Mac-only device types (External, Continuity,
//     DeskView) are dropped.
//   - Permission is REPORTED, never prompted: authorizationStatusForMediaType
//     Denied/Restricted -> MINIAV_ERROR_PERMISSION_DENIED at Configure;
//     NotDetermined ALSO -> MINIAV_ERROR_PERMISSION_DENIED (miniAV never issues
//     the async requestAccessForMediaType prompt — the app must do that first).
//   - No CGDisplay / external-screen logic.
//   - Session-interruption + runtime-error notifications feed the one-shot
//     lost_cb (unrecoverable interruption / runtime error only).
//
// ORIENTATION (spec §B.1 decision): v1 delivers frames in their sensor-native
// orientation. NO rotation/orientation handling is performed here — rotation
// metadata is explicitly deferred to a later release.
//
// Memory management: MRC (NO ARC), exactly like the macOS backend. This target
// is compiled WITHOUT -fobjc-arc.

#ifdef __cplusplus
extern "C" {
#endif

// Declare the platform initialization function for AVFoundation on iOS.
// This function will be called by camera_api.c to select and do minimal setup
// for this backend.
MiniAVResultCode
miniav_camera_context_platform_init_ios_avf(MiniAVCameraContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // CAMERA_CONTEXT_IOS_AVF_H
