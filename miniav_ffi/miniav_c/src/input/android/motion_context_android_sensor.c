// Android motion/IMU capture backend — NDK ASensorManager (pure C, no JNI on
// the hot path). Converts every signal to miniAV's ONE canonical convention at
// the sensor boundary (INPUT_LAYER_PLAN.md §1.5) and delivers a fully-populated
// MiniAVMotionEvent through miniav_input_deliver_motion() per fused sample.
//
// ACCESS PATH (see MOTION_ANDROID_NOTES.md for the full rationale):
//   - Sensors via NDK ASensorManager / ASensorEventQueue on a dedicated
//     ALooper capture thread. No JNI, no Context, no Java on the hot path.
//   - Display rotation (needed for the screen-frame remap) is Context-bound and
//     NOT reachable from the NDK sensor path, so the Flutter host pushes it in
//     via MiniAV_Input_SetAndroidDisplayRotation(). Until it is set we assume
//     ROTATION_0; RAW_DEVICE_FRAME mode does not need it at all.
//
// CANONICAL CONVERSIONS (Android already matches miniAV canonical for the raw
// signals — verified per-axis in MOTION_ANDROID_NOTES.md):
//   gyro  : TYPE_GYROSCOPE             rad/s, right-handed          -> copy
//   accel : TYPE_ACCELEROMETER         m/s^2 incl. gravity, face-up  -> copy
//                                      z ~= +9.81 (reaction-force sign)
//   linear: TYPE_LINEAR_ACCELERATION   m/s^2, gravity removed        -> copy
//   grav  : TYPE_GRAVITY               m/s^2 gravity estimate        -> copy
//   quat  : TYPE_GAME_ROTATION_VECTOR  [x,y,z,w] scalar-LAST, right- -> copy +
//                                      handed, gravity-down             w-recover
//
// THREADING mirrors the Linux evdev backend: a single capture pthread owns an
// ALooper + ASensorEventQueue; stop is signalled by an atomic flag + a
// thread-safe ALooper_wake() (never thread cancellation). The hot path makes no
// allocations and no JNI calls.

#if defined(__ANDROID__)

#include "motion_context_android_sensor.h"

#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#include <android/api-level.h>
#include <android/looper.h>
#include <android/sensor.h>

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// --- Sensor type constants -------------------------------------------------
// Defined locally as literals (not via the NDK enum, whose members are gated
// behind __ANDROID_API__ in some NDK releases) so this compiles on any NDK.
// Values are the stable android.hardware.Sensor.TYPE_* ordinals.
#define MINIAV_SENSOR_TYPE_ACCELEROMETER 1
#define MINIAV_SENSOR_TYPE_GYROSCOPE 4
#define MINIAV_SENSOR_TYPE_GRAVITY 9
#define MINIAV_SENSOR_TYPE_LINEAR_ACCELERATION 10
#define MINIAV_SENSOR_TYPE_ROTATION_VECTOR 11
#define MINIAV_SENSOR_TYPE_GAME_ROTATION_VECTOR 15

// ALooper poll identifier for our sensor queue (non-callback mode).
#define MINIAV_SENSOR_LOOPER_IDENT 0x6D6F /* 'mo' */

// Poll timeout: bounds stop responsiveness even if a wake is ever missed.
#define MINIAV_SENSOR_POLL_TIMEOUT_MS 200

// Default sampling rate when config.motion_rate_hz == 0.
#define MINIAV_SENSOR_DEFAULT_HZ 60

// ---------------------------------------------------------------------------
// Process-global display rotation, pushed in by the Flutter host as a raw
// Surface.ROTATION_* ordinal (0..3). Consumed on the hot path to fill
// MiniAVMotionEvent.display and build screen_orientation. Defaults to
// ROTATION_0 (portrait-natural) until first set.
// ---------------------------------------------------------------------------
static _Atomic int g_android_surface_rotation = 0;

MiniAVResultCode MiniAV_Input_SetAndroidDisplayRotation(int32_t surface_rotation) {
  if (surface_rotation < 0 || surface_rotation > 3) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Android motion: SetAndroidDisplayRotation ignored, ordinal %d "
               "out of range [0,3].",
               (int)surface_rotation);
    return MINIAV_ERROR_INVALID_ARG;
  }
  atomic_store(&g_android_surface_rotation, (int)surface_rotation);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Android motion: display rotation set to Surface.ROTATION_%d.",
             (int)surface_rotation * 90);
  return MINIAV_SUCCESS;
}

// ---------------------------------------------------------------------------
// Platform context.
// ---------------------------------------------------------------------------
typedef struct InputPlatformAndroid {
  MiniAVInputContext *parent; // back-pointer for miniav_input_deliver_motion()

  // Configuration snapshot (set in configure, read on the capture thread).
  uint32_t input_types;
  uint32_t motion_rate_hz;
  MiniAVMotionMode motion_mode;

  // Sensor handles resolved on the caller thread in start_capture (manager +
  // ASensor* are thread-agnostic; only the queue is looper-bound).
  ASensorManager *manager;
  const ASensor *s_accel;
  const ASensor *s_gyro;
  const ASensor *s_grav;
  const ASensor *s_lin;
  const ASensor *s_rot;              // attitude source (game- or plain rot-vec)
  MiniAVAttitudeRef attitude_ref;    // matches which rotation sensor bound

  // Capture thread.
  pthread_t thread;
  bool thread_started;
  atomic_int stop_flag;
  _Atomic(ALooper *) looper;         // set by the thread, woken by stop
  ASensorEventQueue *queue;          // thread-owned

  // Timestamp rebase: ASensorEvent.timestamp (device ns, CLOCK_BOOTTIME on most
  // HALs) -> miniav_get_time_us() epoch (CLOCK_MONOTONIC). Anchors an offset on
  // the first sample; preserves inter-sample spacing. Thread-owned.
  MiniAVTimebase ts_rebase;

  // Latest raw signals, cached from their most-recent event and folded into the
  // fused sample when a rotation-vector event drives delivery. Thread-owned.
  float gyro[3];
  float accel[3];
  float grav[3];
  float lin[3];
} InputPlatformAndroid;

// ---------------------------------------------------------------------------
// Runtime API-level probe (matches the screen backend).
// ---------------------------------------------------------------------------
static int android_runtime_api_level(void) {
#if __ANDROID_API__ >= 24
  return android_get_device_api_level();
#else
  return 21;
#endif
}

// ---------------------------------------------------------------------------
// Quaternion helpers (scalar-LAST [x,y,z,w], Hamilton product).
// ---------------------------------------------------------------------------
static MiniAVQuat quat_mul(MiniAVQuat a, MiniAVQuat b) {
  MiniAVQuat r;
  r.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
  r.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
  r.y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
  r.z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
  return r;
}

// Remap the device-frame attitude into the display frame by post-rotating about
// the screen-normal (device Z) axis by the negative display angle. This is the
// quaternion equivalent of SensorManager.remapCoordinateSystem for a pure
// Z-rotation display, and matches the repo-locked web formula (§7.1):
//   screen = orientation (X) [0, 0, sin(-a/2), cos(-a/2)],  a = rot * 90 deg
// so native Android and the web DeviceMotion path produce byte-comparable
// screen_orientation.
static MiniAVQuat screen_remap(MiniAVQuat orientation, int surface_rotation) {
  double a = (double)surface_rotation * (M_PI / 2.0); // 0, 90, 180, 270 deg
  double half = -a / 2.0;
  MiniAVQuat qz = {0.0, 0.0, sin(half), cos(half)};
  return quat_mul(orientation, qz);
}

// ---------------------------------------------------------------------------
// Build + deliver one fused MiniAVMotionEvent, driven by a rotation-vector
// event. Zero-initialized, EVERY field filled, then handed to the ONE canonical
// delivery entry point. Runs on the capture thread; allocation-free.
// ---------------------------------------------------------------------------
static void android_deliver_fused(MiniAVInputContext *ctx,
                                  InputPlatformAndroid *plat,
                                  const ASensorEvent *rot) {
  MiniAVMotionEvent ev;
  memset(&ev, 0, sizeof(ev));

  // timestamp: device ns -> us, rebased onto the miniAV master clock.
  ev.timestamp_us =
      miniav_rebase_time_us(&plat->ts_rebase, (uint64_t)(rot->timestamp / 1000));

  // Raw signals — Android already matches canonical units/axes/sign (see file
  // header + MOTION_ANDROID_NOTES.md), so these are straight copies. Any signal
  // whose sensor was absent stays zero (canonical: "zero if un-fused").
  ev.gyro.x = plat->gyro[0];
  ev.gyro.y = plat->gyro[1];
  ev.gyro.z = plat->gyro[2];
  ev.accel.x = plat->accel[0];
  ev.accel.y = plat->accel[1];
  ev.accel.z = plat->accel[2];
  ev.linear_accel.x = plat->lin[0];
  ev.linear_accel.y = plat->lin[1];
  ev.linear_accel.z = plat->lin[2];
  ev.gravity.x = plat->grav[0];
  ev.gravity.y = plat->grav[1];
  ev.gravity.z = plat->grav[2];

  // Magnetometer / heading: not captured in P0.
  ev.magnetometer.x = 0.0;
  ev.magnetometer.y = 0.0;
  ev.magnetometer.z = 0.0;
  ev.has_magnetometer = false;
  ev.heading_deg = 0.0;
  ev.has_heading = false;

  // Fused attitude quaternion. Android's rotation vector is already
  // [x,y,z,w] scalar-LAST, right-handed, gravity-down. On pre-API-18 devices
  // values[3] (w) could be absent; GAME_ROTATION_VECTOR is API 18+ and our
  // floor is 24, so w is always present — but recover + normalize defensively.
  double qx = (double)rot->data[0];
  double qy = (double)rot->data[1];
  double qz = (double)rot->data[2];
  double qw = (double)rot->data[3];
  double sq = qx * qx + qy * qy + qz * qz;
  if (qw == 0.0 && sq <= 1.0) {
    // w unset (or genuine 180 deg): reconstruct from the unit constraint.
    qw = sqrt(1.0 - sq);
  }
  double n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
  if (n > 1e-9) {
    qx /= n;
    qy /= n;
    qz /= n;
    qw /= n;
  } else {
    qx = 0.0;
    qy = 0.0;
    qz = 0.0;
    qw = 1.0;
  }
  ev.orientation.x = qx;
  ev.orientation.y = qy;
  ev.orientation.z = qz;
  ev.orientation.w = qw;
  ev.ref = plat->attitude_ref;

  // Display rotation + screen-frame remap.
  int sr = atomic_load(&g_android_surface_rotation);
  ev.display = (MiniAVDisplayRotation)sr; // Surface.ROTATION_* == ordinal 0..3
  if (plat->motion_mode == MINIAV_MOTION_MODE_RAW_DEVICE_FRAME) {
    ev.screen_orientation = ev.orientation; // no remap requested
  } else {
    ev.screen_orientation = screen_remap(ev.orientation, sr);
  }

  // ONE canonical delivery point: caches latest_motion for the pull API AND
  // fires config.motion_callback. Never touch config/latest_motion directly.
  miniav_input_deliver_motion(ctx, &ev);
}

// ---------------------------------------------------------------------------
// Drain + translate all queued sensor events. Caches the 3-axis signals and
// delivers a fused sample on each rotation-vector event.
// ---------------------------------------------------------------------------
static void android_drain_queue(MiniAVInputContext *ctx,
                                InputPlatformAndroid *plat) {
  ASensorEvent events[64];
  ssize_t n;
  while ((n = ASensorEventQueue_getEvents(plat->queue, events,
                                          sizeof(events) / sizeof(events[0]))) >
         0) {
    for (ssize_t i = 0; i < n; ++i) {
      const ASensorEvent *e = &events[i];
      switch (e->type) {
      case MINIAV_SENSOR_TYPE_GYROSCOPE:
        plat->gyro[0] = e->vector.x;
        plat->gyro[1] = e->vector.y;
        plat->gyro[2] = e->vector.z;
        break;
      case MINIAV_SENSOR_TYPE_ACCELEROMETER:
        plat->accel[0] = e->vector.x;
        plat->accel[1] = e->vector.y;
        plat->accel[2] = e->vector.z;
        break;
      case MINIAV_SENSOR_TYPE_GRAVITY:
        plat->grav[0] = e->vector.x;
        plat->grav[1] = e->vector.y;
        plat->grav[2] = e->vector.z;
        break;
      case MINIAV_SENSOR_TYPE_LINEAR_ACCELERATION:
        plat->lin[0] = e->vector.x;
        plat->lin[1] = e->vector.y;
        plat->lin[2] = e->vector.z;
        break;
      case MINIAV_SENSOR_TYPE_GAME_ROTATION_VECTOR:
      case MINIAV_SENSOR_TYPE_ROTATION_VECTOR:
        // Attitude drives delivery: fold the latest cached raw signals in and
        // emit one fused sample stamped with THIS event's timestamp.
        android_deliver_fused(ctx, plat, e);
        break;
      default:
        break;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Set the per-sensor event rate, clamped to the sensor's minimum period.
// ---------------------------------------------------------------------------
static void android_enable_sensor(InputPlatformAndroid *plat,
                                  const ASensor *sensor, int32_t period_us) {
  if (!sensor) {
    return;
  }
  int32_t min_us = ASensor_getMinDelay(sensor);
  if (min_us > 0 && period_us < min_us) {
    period_us = min_us;
  }
  ASensorEventQueue_enableSensor(plat->queue, sensor);
  ASensorEventQueue_setEventRate(plat->queue, sensor, period_us);
}

// ---------------------------------------------------------------------------
// Capture thread: owns the ALooper + ASensorEventQueue for its whole lifetime.
// ---------------------------------------------------------------------------
static void *android_capture_thread(void *arg) {
  MiniAVInputContext *ctx = (MiniAVInputContext *)arg;
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;

  // A looper for THIS thread (non-callback: we poll the queue by ident).
  ALooper *looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
  if (!looper) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android motion: ALooper_prepare failed; thread exiting.");
    return NULL;
  }
  atomic_store(&plat->looper, looper);

  // Create the sensor queue bound to this looper (non-callback mode).
  plat->queue = ASensorManager_createEventQueue(
      plat->manager, looper, MINIAV_SENSOR_LOOPER_IDENT, NULL, NULL);
  if (!plat->queue) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android motion: createEventQueue failed; thread exiting.");
    atomic_store(&plat->looper, NULL);
    return NULL;
  }

  int32_t period_us = (plat->motion_rate_hz > 0)
                          ? (int32_t)(1000000u / plat->motion_rate_hz)
                          : (int32_t)(1000000u / MINIAV_SENSOR_DEFAULT_HZ);
  android_enable_sensor(plat, plat->s_accel, period_us);
  android_enable_sensor(plat, plat->s_gyro, period_us);
  android_enable_sensor(plat, plat->s_grav, period_us);
  android_enable_sensor(plat, plat->s_lin, period_us);
  android_enable_sensor(plat, plat->s_rot, period_us);

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android motion: capture thread started (rate ~%u Hz, mode=%d).",
             (plat->motion_rate_hz > 0) ? plat->motion_rate_hz
                                        : MINIAV_SENSOR_DEFAULT_HZ,
             (int)plat->motion_mode);

  while (!atomic_load(&plat->stop_flag)) {
    int id = ALooper_pollOnce(MINIAV_SENSOR_POLL_TIMEOUT_MS, NULL, NULL, NULL);
    if (atomic_load(&plat->stop_flag)) {
      break;
    }
    if (id == MINIAV_SENSOR_LOOPER_IDENT) {
      android_drain_queue(ctx, plat);
    }
    // ALOOPER_POLL_WAKE (stop), ALOOPER_POLL_TIMEOUT, and ALOOPER_POLL_ERROR
    // all fall through to the top-of-loop stop check.
  }

  // Tear down the queue on the SAME thread that created it.
  if (plat->s_accel) ASensorEventQueue_disableSensor(plat->queue, plat->s_accel);
  if (plat->s_gyro)  ASensorEventQueue_disableSensor(plat->queue, plat->s_gyro);
  if (plat->s_grav)  ASensorEventQueue_disableSensor(plat->queue, plat->s_grav);
  if (plat->s_lin)   ASensorEventQueue_disableSensor(plat->queue, plat->s_lin);
  if (plat->s_rot)   ASensorEventQueue_disableSensor(plat->queue, plat->s_rot);
  ASensorManager_destroyEventQueue(plat->manager, plat->queue);
  plat->queue = NULL;
  atomic_store(&plat->looper, NULL);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Android motion: capture thread exiting.");
  return NULL;
}

// ---------------------------------------------------------------------------
// Acquire the ASensorManager (NDK, Context-free; no JNI).
// ---------------------------------------------------------------------------
static ASensorManager *android_get_manager(void) {
  if (android_runtime_api_level() >= 26) {
    // Preferred (API 26+): package-scoped instance. Empty package is accepted
    // and works for the NDK sensor path; no Context/JNI required.
    return ASensorManager_getInstanceForPackage("");
  }
  // API 24/25 fallback (deprecated but functional).
  return ASensorManager_getInstance();
}

// ---------------------------------------------------------------------------
// InputContextInternalOps implementation.
// ---------------------------------------------------------------------------
static MiniAVResultCode input_android_init_platform(MiniAVInputContext *ctx) {
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  plat->parent = ctx;
  atomic_init(&plat->stop_flag, 0);
  atomic_init(&plat->looper, NULL);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_android_destroy_platform(MiniAVInputContext *ctx) {
  if (!ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;

  if (plat->thread_started) {
    ctx->ops->stop_capture(ctx);
  }

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Android motion: platform context destroyed.");
  return MINIAV_SUCCESS;
}

// Gamepad enumeration is a separate P1 JNI backend; motion backend does not
// provide it.
static MiniAVResultCode
input_android_enumerate_gamepads(MiniAVDeviceInfo **devices_out,
                                 uint32_t *count_out) {
  if (devices_out) {
    *devices_out = NULL;
  }
  if (count_out) {
    *count_out = 0;
  }
  return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode
input_android_configure(MiniAVInputContext *ctx,
                        const MiniAVInputConfig *config) {
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  plat->input_types = config->input_types;
  plat->motion_rate_hz = config->motion_rate_hz;
  plat->motion_mode = config->motion_mode;

  if (!(config->input_types & MINIAV_INPUT_TYPE_MOTION)) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Android motion: configured without MINIAV_INPUT_TYPE_MOTION; "
               "start_capture will be a no-op (this backend only serves "
               "motion; gamepad is a separate P1 backend).");
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_android_start_capture(MiniAVInputContext *ctx) {
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (plat->thread_started) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  if (!(plat->input_types & MINIAV_INPUT_TYPE_MOTION)) {
    // Nothing to capture — succeed quietly; the pull API stays NOT_RUNNING.
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "Android motion: MOTION not requested; no sensor thread started.");
    return MINIAV_SUCCESS;
  }

  // Resolve the manager + sensors on the caller thread (thread-agnostic) so a
  // missing fused-attitude sensor fails fast BEFORE we spawn the thread.
  plat->manager = android_get_manager();
  if (!plat->manager) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android motion: no ASensorManager available.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  plat->s_accel = ASensorManager_getDefaultSensor(
      plat->manager, MINIAV_SENSOR_TYPE_ACCELEROMETER);
  plat->s_gyro = ASensorManager_getDefaultSensor(plat->manager,
                                                 MINIAV_SENSOR_TYPE_GYROSCOPE);
  plat->s_grav = ASensorManager_getDefaultSensor(plat->manager,
                                                 MINIAV_SENSOR_TYPE_GRAVITY);
  plat->s_lin = ASensorManager_getDefaultSensor(
      plat->manager, MINIAV_SENSOR_TYPE_LINEAR_ACCELERATION);

  // Prefer the drift-free, magnetometer-free game rotation vector (no north
  // reference). Fall back to the mag-referenced rotation vector if absent.
  plat->s_rot = ASensorManager_getDefaultSensor(
      plat->manager, MINIAV_SENSOR_TYPE_GAME_ROTATION_VECTOR);
  if (plat->s_rot) {
    plat->attitude_ref = MINIAV_ATTITUDE_REF_RELATIVE_DRIFT_FREE;
  } else {
    plat->s_rot = ASensorManager_getDefaultSensor(
        plat->manager, MINIAV_SENSOR_TYPE_ROTATION_VECTOR);
    plat->attitude_ref = MINIAV_ATTITUDE_REF_ABSOLUTE_MAG_NORTH;
    if (plat->s_rot) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Android motion: GAME_ROTATION_VECTOR absent; using "
                 "ROTATION_VECTOR (magnetometer-referenced).");
    }
  }
  if (!plat->s_rot) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android motion: device has no rotation-vector sensor; the "
               "fused attitude the parallax path needs is unavailable.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  // Fresh capture state.
  atomic_store(&plat->stop_flag, 0);
  atomic_store(&plat->looper, NULL);
  memset(&plat->ts_rebase, 0, sizeof(plat->ts_rebase));
  memset(plat->gyro, 0, sizeof(plat->gyro));
  memset(plat->accel, 0, sizeof(plat->accel));
  memset(plat->grav, 0, sizeof(plat->grav));
  memset(plat->lin, 0, sizeof(plat->lin));

  int rc = pthread_create(&plat->thread, NULL, android_capture_thread, ctx);
  if (rc != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Android motion: pthread_create failed: %d", rc);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->thread_started = true;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_android_stop_capture(MiniAVInputContext *ctx) {
  InputPlatformAndroid *plat = (InputPlatformAndroid *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (!plat->thread_started) {
    return MINIAV_SUCCESS;
  }

  // Signal stop, then wake the poll. ALooper_wake is thread-safe; if the thread
  // has not published its looper yet it will observe stop_flag at loop entry.
  atomic_store(&plat->stop_flag, 1);
  ALooper *looper = atomic_load(&plat->looper);
  if (looper) {
    ALooper_wake(looper);
  }

  // Bionic lacks pthread_timedjoin_np in this project's gate, so join plainly.
  // The wake + bounded poll timeout guarantee prompt exit; the thread owns and
  // frees the queue itself before returning.
  pthread_join(plat->thread, NULL);
  plat->thread_started = false;

  // Sensor handles belong to the (process-lived) manager; just drop our refs.
  plat->s_accel = plat->s_gyro = plat->s_grav = plat->s_lin = plat->s_rot = NULL;

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Android motion: capture stopped.");
  return MINIAV_SUCCESS;
}

// --- Ops table and selection entrypoint ------------------------------------

const InputContextInternalOps g_input_ops_android = {
    .init_platform = input_android_init_platform,
    .destroy_platform = input_android_destroy_platform,
    .enumerate_gamepads = input_android_enumerate_gamepads,
    .configure = input_android_configure,
    .start_capture = input_android_start_capture,
    .stop_capture = input_android_stop_capture,
};

MiniAVResultCode
miniav_input_context_platform_init_android(MiniAVInputContext *ctx) {
  InputPlatformAndroid *plat =
      (InputPlatformAndroid *)miniav_calloc(1, sizeof(InputPlatformAndroid));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  ctx->platform_ctx = plat;
  ctx->ops = &g_input_ops_android;
  return MINIAV_SUCCESS;
}

#endif // __ANDROID__
