// iOS motion / IMU backend (CoreMotion).
//
//  * Motion: CMMotionManager device-motion updates delivered on a dedicated
//    serial NSOperationQueue. Each CMDeviceMotion is converted to the canonical
//    MiniAVMotionEvent convention (INPUT_LAYER_PLAN.md §1.5) and handed to
//    miniav_input_deliver_motion(), which caches it for the pull API AND fires
//    config.motion_callback. We NEVER touch ctx->latest_motion / the callback
//    directly.
//  * Keyboard / mouse: not applicable on iOS.
//  * Gamepad: separate P1 concern (GameController) — enumerate_gamepads is a
//    no-op returning MINIAV_ERROR_NOT_SUPPORTED so the ops table stays valid.
//
// Manual retain/release (NO ARC), matching the other Apple backends. Every
// CMMotionManager / NSOperationQueue / notification-observer token created here
// is released or removed exactly once.
//
// See the header for the MANDATORY Info.plist NSMotionUsageDescription note.

#import <CoreMotion/CoreMotion.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <stdatomic.h>
#include <string.h>

#include "motion_context_ios_coremotion.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#if !TARGET_OS_IOS
#error "motion_context_ios_coremotion.m must only be compiled for iOS targets"
#endif

// Standard gravity used to convert CoreMotion's G-unit accelerations to m/s^2.
#define MINIAV_STANDARD_GRAVITY 9.80665

// --- Platform-specific context ----------------------------------------------
typedef struct MotionPlatformIOS {
  MiniAVInputContext *parent_ctx; // for miniav_input_deliver_motion()

  CMMotionManager *motion_manager; // strong (MRC)
  NSOperationQueue *delivery_queue; // strong (MRC) — serial deviceMotion queue
  id orientation_observer;          // strong (MRC) — NSNotification token

  // Configuration snapshot (written by configure, read by start/handler).
  uint32_t input_types;         // the configured MiniAVInputType bitmask
  uint32_t motion_rate_hz;      // 0 => default 60
  MiniAVMotionMode motion_mode; // how screen_orientation is prepared

  // Current display rotation as a MiniAVDisplayRotation ordinal (0..3). Written
  // on the MAIN thread (UIKit is main-thread only) by the orientation observer;
  // read on the CoreMotion delivery queue. Atomic to bridge the two threads.
  atomic_int screen_rotation;

  bool updates_active; // true between start_capture and stop_capture
} MotionPlatformIOS;

// --- Orientation helpers ----------------------------------------------------

// Map a UIInterfaceOrientation to the canonical MiniAVDisplayRotation ordinal.
// Ordinals are 0=0deg, 1=90deg, 2=180deg, 3=270deg (NOT degrees) and this same
// ordinal drives the screen-remap angle below, so the two are coherent.
//
// NOTE (verify on-device): the LandscapeLeft=90 / LandscapeRight=270 split is
// the one axis that cannot be validated without an iPhone. If the parallax
// tilt reads mirrored in landscape, swap these two cases — it is a one-line
// change and does not affect portrait / upside-down.
static MiniAVDisplayRotation
ios_interface_orientation_to_ordinal(UIInterfaceOrientation o) {
  switch (o) {
  case UIInterfaceOrientationPortrait:
    return MINIAV_DISPLAY_ROTATION_0;
  case UIInterfaceOrientationLandscapeLeft:
    return MINIAV_DISPLAY_ROTATION_90;
  case UIInterfaceOrientationPortraitUpsideDown:
    return MINIAV_DISPLAY_ROTATION_180;
  case UIInterfaceOrientationLandscapeRight:
    return MINIAV_DISPLAY_ROTATION_270;
  case UIInterfaceOrientationUnknown:
  default:
    return MINIAV_DISPLAY_ROTATION_0;
  }
}

// Read the current interface orientation. MAIN THREAD ONLY (UIKit). Returns the
// canonical rotation ordinal; defaults to portrait when no active scene exists.
static MiniAVDisplayRotation ios_current_rotation_ordinal(void) {
  UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]] &&
          scene.activationState == UISceneActivationStateForegroundActive) {
        orientation = ((UIWindowScene *)scene).interfaceOrientation;
        break;
      }
    }
  }
  return ios_interface_orientation_to_ordinal(orientation);
}

// Prime the cached rotation without deadlocking if start_capture runs on main.
static void ios_prime_rotation(MotionPlatformIOS *plat) {
  if ([NSThread isMainThread]) {
    atomic_store(&plat->screen_rotation,
                 (int)ios_current_rotation_ordinal());
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      atomic_store(&plat->screen_rotation,
                   (int)ios_current_rotation_ordinal());
    });
  }
}

// --- Quaternion helpers (scalar-last [x,y,z,w], Hamilton product) -----------

static MiniAVQuat ios_quat_mul(MiniAVQuat a, MiniAVQuat b) {
  MiniAVQuat r;
  r.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
  r.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
  r.y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
  r.z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
  return r;
}

// Remap the device-frame attitude into the display frame by rotating about the
// device screen-normal (+Z) by rot_ordinal * 90 degrees, so a given physical
// tilt maps identically in portrait, landscape and upside-down. Post-multiplying
// applies the correction in the device's local frame (about the viewing axis).
// rot_ordinal 0 (portrait) yields qz = identity => screen_orientation ==
// orientation, matching the raw-device-frame path in portrait.
static MiniAVQuat ios_remap_to_screen(MiniAVQuat orientation, int rot_ordinal) {
  double angle = (double)rot_ordinal * (M_PI / 2.0);
  double half = angle * 0.5;
  MiniAVQuat qz = {0.0, 0.0, sin(half), cos(half)};
  return ios_quat_mul(orientation, qz);
}

// --- CoreMotion sample handler ----------------------------------------------

static void ios_handle_device_motion(MotionPlatformIOS *plat,
                                     CMDeviceMotion *motion) {
  if (!plat || !motion) {
    return;
  }

  MiniAVMotionEvent ev;
  memset(&ev, 0, sizeof(ev));

  // timestamp: stamp on the shared A/V master clock at delivery, exactly like
  // the desktop input backends (miniav_get_time_us()). CMDeviceMotion.timestamp
  // shares this mach epoch and could be rebased via miniav_rebase_time_us() if
  // tighter inter-sample spacing is ever needed; not required for 60 Hz IMU.
  ev.timestamp_us = miniav_get_time_us();

  // gyro: CoreMotion rotationRate is already rad/s, right-handed, device frame.
  // Canonical is the same — direct copy, no conversion.
  ev.gyro.x = motion.rotationRate.x;
  ev.gyro.y = motion.rotationRate.y;
  ev.gyro.z = motion.rotationRate.z;

  // accel: CoreMotion gravity/userAcceleration are in G, device frame
  // (X-right/Y-up/Z-out — matching the canonical axes), but with iOS's
  // gravity-vector sign (face-up gravity.z ~= -1). Canonical accel is the
  // reaction-force convention (face-up z ~= +9.81), so NEGATE and scale by g.
  // Applying the same (-g) factor to gravity AND userAcceleration keeps the
  // identity accel == linear_accel + gravity intact so callers never re-derive.
  ev.gravity.x = -motion.gravity.x * MINIAV_STANDARD_GRAVITY;
  ev.gravity.y = -motion.gravity.y * MINIAV_STANDARD_GRAVITY;
  ev.gravity.z = -motion.gravity.z * MINIAV_STANDARD_GRAVITY;

  ev.linear_accel.x = -motion.userAcceleration.x * MINIAV_STANDARD_GRAVITY;
  ev.linear_accel.y = -motion.userAcceleration.y * MINIAV_STANDARD_GRAVITY;
  ev.linear_accel.z = -motion.userAcceleration.z * MINIAV_STANDARD_GRAVITY;

  ev.accel.x = ev.linear_accel.x + ev.gravity.x;
  ev.accel.y = ev.linear_accel.y + ev.gravity.y;
  ev.accel.z = ev.linear_accel.z + ev.gravity.z;

  // magnetometer: not surfaced for P0 (no calibrated reference frame started).
  ev.has_magnetometer = false; // magnetometer left zero-initialized

  // orientation: CMQuaternion is declared { double x, y, z, w; } — already
  // scalar-LAST and right-handed, matching the canonical layout. Direct copy;
  // no field reorder or sign flip. (The INPUT_LAYER_PLAN "(w,x,y,z)" note refers
  // to the mathematical scalar-first notation, not the C struct field order.)
  CMQuaternion q = motion.attitude.quaternion;
  ev.orientation.x = q.x;
  ev.orientation.y = q.y;
  ev.orientation.z = q.z;
  ev.orientation.w = q.w;

  // ref: startDeviceMotionUpdates (no explicit reference frame) yields
  // CMAttitudeReferenceFrameXArbitraryZVertical — relative, drift-free, no
  // magnetometer. heading is therefore unreferenced for P0.
  ev.ref = MINIAV_ATTITUDE_REF_RELATIVE_DRIFT_FREE;
  ev.has_heading = false; // heading_deg left zero-initialized

  // display + screen_orientation: the load-bearing parallax fields.
  int rot = atomic_load(&plat->screen_rotation);
  ev.display = (MiniAVDisplayRotation)rot;
  if (plat->motion_mode == MINIAV_MOTION_MODE_RAW_DEVICE_FRAME) {
    ev.screen_orientation = ev.orientation; // no remap
  } else {
    ev.screen_orientation = ios_remap_to_screen(ev.orientation, rot);
  }

  miniav_input_deliver_motion(plat->parent_ctx, &ev);
}

// --- Ops implementation -----------------------------------------------------

static MiniAVResultCode ios_init_platform(MiniAVInputContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  MotionPlatformIOS *plat =
      (MotionPlatformIOS *)miniav_calloc(1, sizeof(MotionPlatformIOS));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  plat->parent_ctx = ctx;
  atomic_store(&plat->screen_rotation, (int)MINIAV_DISPLAY_ROTATION_0);

  plat->motion_manager = [[CMMotionManager alloc] init];
  if (!plat->motion_manager) {
    miniav_free(plat);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  plat->delivery_queue = [[NSOperationQueue alloc] init];
  if (!plat->delivery_queue) {
    [plat->motion_manager release];
    miniav_free(plat);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  // Serial queue: deviceMotion handler runs one-at-a-time, off the main thread.
  plat->delivery_queue.maxConcurrentOperationCount = 1;
  plat->delivery_queue.name = @"ai.miniav.motion.coremotion";

  ctx->platform_ctx = plat;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "CoreMotion: Platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_destroy_platform(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  MotionPlatformIOS *plat = (MotionPlatformIOS *)ctx->platform_ctx;

  // Stop any in-flight updates first (safe if already stopped).
  if (plat->updates_active) {
    g_input_ops_ios.stop_capture(ctx);
  }

  if (plat->motion_manager) {
    [plat->motion_manager release];
    plat->motion_manager = nil;
  }
  if (plat->delivery_queue) {
    [plat->delivery_queue release];
    plat->delivery_queue = nil;
  }

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreMotion: Platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
ios_enumerate_gamepads(MiniAVDeviceInfo **devices_out, uint32_t *count_out) {
  // iOS gamepad (GameController) is a separate P1 concern; motion-only here.
  if (devices_out) {
    *devices_out = NULL;
  }
  if (count_out) {
    *count_out = 0;
  }
  return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode ios_configure(MiniAVInputContext *ctx,
                                      const MiniAVInputConfig *config) {
  if (!ctx || !ctx->platform_ctx || !config) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  MotionPlatformIOS *plat = (MotionPlatformIOS *)ctx->platform_ctx;

  plat->input_types = config->input_types;
  plat->motion_rate_hz = config->motion_rate_hz;
  plat->motion_mode = config->motion_mode;

  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_start_capture(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  MotionPlatformIOS *plat = (MotionPlatformIOS *)ctx->platform_ctx;

  if (plat->updates_active) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  // Honor input_types: if motion was not requested, start nothing. The pull API
  // stays at NOT_RUNNING (no samples delivered) and no callbacks fire.
  if ((plat->input_types & MINIAV_INPUT_TYPE_MOTION) == 0) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "CoreMotion: MOTION not selected in input_types; nothing to "
               "start (keyboard/mouse/gamepad are not provided by this "
               "backend).");
    return MINIAV_SUCCESS;
  }

  if (!plat->motion_manager.deviceMotionAvailable) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CoreMotion: deviceMotion is unavailable on this device.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  // Clamp the requested rate: default 60, hard cap 100 Hz (deviceMotion tops
  // out around there and higher just burns battery for parallax).
  uint32_t hz = plat->motion_rate_hz > 0 ? plat->motion_rate_hz : 60;
  if (hz > 100) {
    hz = 100;
  }
  plat->motion_manager.deviceMotionUpdateInterval = 1.0 / (double)hz;

  // Cache the current display rotation and keep it fresh across rotations.
  ios_prime_rotation(plat);
  [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  plat->orientation_observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:UIDeviceOrientationDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                MINIAV_UNUSED(note);
                // Runs on the main thread: re-read the interface orientation
                // (device orientation change is our trigger) and publish it.
                atomic_store(&plat->screen_rotation,
                             (int)ios_current_rotation_ordinal());
              }];
  [plat->orientation_observer retain]; // token is autoreleased; keep it alive

  // Capture the raw plat pointer (owned by ctx, alive until destroy).
  MotionPlatformIOS *plat_ref = plat;
  [plat->motion_manager
      startDeviceMotionUpdatesToQueue:plat->delivery_queue
                          withHandler:^(CMDeviceMotion *motion,
                                        NSError *error) {
                            if (error) {
                              miniav_log(MINIAV_LOG_LEVEL_WARN,
                                         "CoreMotion: deviceMotion error: %s",
                                         error.localizedDescription.UTF8String);
                              return;
                            }
                            ios_handle_device_motion(plat_ref, motion);
                          }];

  plat->updates_active = true;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "CoreMotion: Motion capture started at ~%u Hz (mode=%d).", hz,
             (int)plat->motion_mode);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_stop_capture(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  MotionPlatformIOS *plat = (MotionPlatformIOS *)ctx->platform_ctx;

  if (!plat->updates_active) {
    return MINIAV_SUCCESS;
  }

  [plat->motion_manager stopDeviceMotionUpdates];

  if (plat->orientation_observer) {
    [[NSNotificationCenter defaultCenter]
        removeObserver:plat->orientation_observer];
    [plat->orientation_observer release];
    plat->orientation_observer = nil;
  }
  [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

  // Drain any queued handler blocks so none run after stop returns.
  [plat->delivery_queue waitUntilAllOperationsAreFinished];

  plat->updates_active = false;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreMotion: Motion capture stopped.");
  return MINIAV_SUCCESS;
}

// --- Ops table + init -------------------------------------------------------

const InputContextInternalOps g_input_ops_ios = {
    .init_platform = ios_init_platform,
    .destroy_platform = ios_destroy_platform,
    .enumerate_gamepads = ios_enumerate_gamepads,
    .configure = ios_configure,
    .start_capture = ios_start_capture,
    .stop_capture = ios_stop_capture,
};

MiniAVResultCode
miniav_input_context_platform_init_ios(MiniAVInputContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  // Selection phase: just publish the ops. Allocation happens in init_platform
  // (called by input_api.c right after selection succeeds).
  ctx->ops = &g_input_ops_ios;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "CoreMotion: iOS motion backend selected.");
  return MINIAV_SUCCESS;
}
