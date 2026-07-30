// Android Camera2 NDK camera backend (pure C).
//
// Enumeration + capture go through the NDK Camera2 API (ACameraManager,
// ACameraDevice, ACameraCaptureSession) with an AImageReader as the capture
// target. The whole file is fenced by __ANDROID__ so it can sit in the shared
// source glob without breaking desktop builds.
//
// API-level policy (spec §A.6, runtime gates — the link floor is 24):
//   - ACameraManager / Camera2 NDK: API 24+  (hard requirement; <24 ->
//     NOT_SUPPORTED, but the toolchain floors us at 24 for camera2ndk anyway).
//   - AImageReader_newWithUsage + AImage_getHardwareBuffer (GPU AHardwareBuffer
//     path): API 26+  — gated at runtime with android_get_device_api_level(),
//     falling back to the CPU YUV_420_888 path below 26.
//
// Threading: the Camera2 NDK owns the callback threads. AImageReader spins up
// its own dedicated internal ALooper thread for onImageAvailable, and
// ACameraDevice / ACameraCaptureSession dispatch their state callbacks on
// their own internal looper threads too — the app never supplies a looper and
// must not assume any particular caller thread. We therefore run NO thread of
// our own; shared mutable state is guarded by the ctx mutex, the app buffer
// callback goes through MINIAV_SAFE_DISPATCH (so MiniAV_Dispose can quiesce
// it), and the device/session lost path uses a one-shot atomic guard. Teardown
// is via the NDK's synchronous *_close/*_delete calls (they internally drain
// their loopers) — see android_cam_stop_capture for the bounded-shutdown note.
#if defined(__ANDROID__)

#include "camera_context_android_camera2.h"
#include "../../../include/miniav_buffer.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#include <camera/NdkCameraCaptureSession.h>
#include <camera/NdkCameraDevice.h>
#include <camera/NdkCameraError.h>
#include <camera/NdkCameraManager.h>
#include <camera/NdkCameraMetadata.h>
#include <camera/NdkCameraMetadataTags.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>

#include <android/api-level.h>
#include <android/hardware_buffer.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// AImageReader in-flight cap. Camera2 stops producing frames once this many
// acquired images are outstanding; we DROP (log at DEBUG) rather than stall the
// NDK callback thread waiting for the app to release.
#define ANDROID_CAM_MAX_IMAGES 4

typedef struct AndroidCamPlatformContext {
  MiniAVCameraContext *parent_ctx;

  // --- Camera2 objects (created in start_capture, torn down in stop) ---
  ACameraManager *manager;      // owned; created in init_platform
  ACameraDevice *device;        // opened camera
  AImageReader *image_reader;   // capture target
  ANativeWindow *reader_window; // AImageReader's window (owned by the reader)

  ACaptureSessionOutputContainer *output_container;
  ACaptureSessionOutput *session_output;
  ACameraOutputTarget *output_target;
  ACaptureRequest *capture_request;
  ACameraCaptureSession *capture_session;

  // Selected camera id (ASCII, from ACameraManager_getCameraIdList).
  char camera_id[MINIAV_DEVICE_ID_MAX_LEN];

  // AImage format actually requested of the reader (AIMAGE_FORMAT_*).
  int32_t image_format;
  // Whether the reader was created for the GPU (HardwareBuffer) path.
  bool gpu_path;

  // Rebases the sensor timestamp (CLOCK_MONOTONIC-ish ns) onto the shared
  // miniav_get_time_us() epoch. Reset at start_capture. Touched only from the
  // AImageReader callback thread (single delivery thread).
  MiniAVTimebase timebase;

  // One-shot guard so a cascade of device/session error callbacks fires the
  // context lost_cb exactly once (device + session callbacks can race across
  // their separate internal threads).
  atomic_bool lost_cb_fired;

  // Guards is_streaming and the shared Camera2 object pointers between the app
  // thread (configure/start/stop/destroy) and the NDK callback threads.
  pthread_mutex_t lock;
  bool is_streaming;

  MiniAVVideoInfo configured_video_format;
  bool is_configured;
} AndroidCamPlatformContext;

// Per-frame release payload hung off the internal buffer payload.
typedef struct AndroidCamFrameReleasePayload {
  MiniAVOutputPreference type;      // CPU or GPU path actually taken
  AImage *image;                    // always present; AImage_delete on release
  AHardwareBuffer *hardware_buffer; // GPU path only (acquired); release on free
} AndroidCamFrameReleasePayload;

// --- Forward declarations of the ops ---
static MiniAVResultCode android_cam_init_platform(MiniAVCameraContext *ctx);
static MiniAVResultCode android_cam_destroy_platform(MiniAVCameraContext *ctx);
static MiniAVResultCode
android_cam_enumerate_devices(MiniAVDeviceInfo **devices_out,
                              uint32_t *count_out);
static MiniAVResultCode
android_cam_get_supported_formats(const char *device_id,
                                  MiniAVVideoInfo **formats_out,
                                  uint32_t *count_out);
static MiniAVResultCode
android_cam_get_default_format(const char *device_id,
                              MiniAVVideoInfo *format_out);
static MiniAVResultCode android_cam_configure(MiniAVCameraContext *ctx,
                                              const char *device_id,
                                              const MiniAVVideoInfo *format);
static MiniAVResultCode android_cam_start_capture(MiniAVCameraContext *ctx);
static MiniAVResultCode android_cam_stop_capture(MiniAVCameraContext *ctx);
static MiniAVResultCode
android_cam_release_buffer(MiniAVCameraContext *ctx, void *internal_handle_ptr);
static MiniAVResultCode
android_cam_get_configured_video_format(MiniAVCameraContext *ctx,
                                        MiniAVVideoInfo *format_out);

// --- Helpers -------------------------------------------------------------

// Map an ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS entry format
// (HAL_PIXEL_FORMAT / AIMAGE_FORMAT values coincide) to a MiniAV pixel format
// for enumeration. Only formats we can actually deliver are reported.
static MiniAVPixelFormat android_stream_format_to_miniav(int32_t fmt) {
  switch (fmt) {
  case AIMAGE_FORMAT_YUV_420_888:
    return MINIAV_PIXEL_FORMAT_I420; // reported as an I420-family YUV
  case AIMAGE_FORMAT_JPEG:
    return MINIAV_PIXEL_FORMAT_MJPEG;
  default:
    return MINIAV_PIXEL_FORMAT_UNKNOWN;
  }
}

static int32_t miniav_format_to_android_image_format(MiniAVPixelFormat fmt) {
  switch (fmt) {
  case MINIAV_PIXEL_FORMAT_I420:
  case MINIAV_PIXEL_FORMAT_YV12:
  case MINIAV_PIXEL_FORMAT_NV12:
  case MINIAV_PIXEL_FORMAT_NV21:
    return AIMAGE_FORMAT_YUV_420_888;
  case MINIAV_PIXEL_FORMAT_MJPEG:
    return AIMAGE_FORMAT_JPEG;
  default:
    return 0;
  }
}

static int android_runtime_api_level(void) {
  // android_get_device_api_level() is API 24+. On older devices fall back to
  // the compile-time floor so 26+-only features are conservatively disabled.
#if __ANDROID_API__ >= 24
  return android_get_device_api_level();
#else
  return __ANDROID_API__;
#endif
}

// Fire the one-shot context-lost callback. Safe to call from any Camera2
// callback thread; NEVER calls stop/destroy synchronously (contract in
// miniav_capture.h). Marks is_streaming=false so no more frames are delivered.
static void android_cam_signal_lost(AndroidCamPlatformContext *pctx,
                                    MiniAVResultCode reason) {
  if (!pctx)
    return;
  pthread_mutex_lock(&pctx->lock);
  pctx->is_streaming = false;
  pthread_mutex_unlock(&pctx->lock);
  if (pctx->parent_ctx && pctx->parent_ctx->lost_cb &&
      !atomic_exchange(&pctx->lost_cb_fired, true)) {
    pctx->parent_ctx->lost_cb((int)reason, pctx->parent_ctx->lost_cb_user_data);
  }
}

// --- Camera2 device / session state callbacks ---------------------------
// These run on NDK-internal looper threads.

static void on_device_disconnected(void *context, ACameraDevice *device) {
  MINIAV_UNUSED(device);
  AndroidCamPlatformContext *pctx = (AndroidCamPlatformContext *)context;
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "AndroidCam: camera device disconnected (unplugged / evicted).");
  android_cam_signal_lost(pctx, MINIAV_ERROR_DEVICE_LOST);
}

static void on_device_error(void *context, ACameraDevice *device, int error) {
  MINIAV_UNUSED(device);
  AndroidCamPlatformContext *pctx = (AndroidCamPlatformContext *)context;
  miniav_log(MINIAV_LOG_LEVEL_ERROR, "AndroidCam: camera device error %d.",
             error);
  android_cam_signal_lost(pctx, MINIAV_ERROR_DEVICE_LOST);
}

static void on_session_closed(void *context, ACameraCaptureSession *session) {
  MINIAV_UNUSED(context);
  MINIAV_UNUSED(session);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "AndroidCam: capture session closed.");
}

static void on_session_ready(void *context, ACameraCaptureSession *session) {
  MINIAV_UNUSED(context);
  MINIAV_UNUSED(session);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "AndroidCam: capture session ready.");
}

static void on_session_active(void *context, ACameraCaptureSession *session) {
  MINIAV_UNUSED(context);
  MINIAV_UNUSED(session);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "AndroidCam: capture session active.");
}

// --- CPU plane layout from a YUV_420_888 AImage --------------------------
//
// YUV_420_888 exposes 3 planes. The concrete on-wire layout is discovered from
// the chroma plane pixelStride:
//   pixelStride == 1 on U and V  -> fully planar (I420 if U precedes V, YV12 if
//                                    V precedes U — labelled truthfully; each
//                                    chroma plane described with its own base).
//   pixelStride == 2             -> interleaved chroma (NV12 if the U-plane base
//                                    precedes the V-plane base, NV21 if V
//                                    precedes U). Labelled truthfully.
// Android planes can live in separate allocations, so each MiniAVVideoPlane
// gets its OWN base pointer with offset_bytes = 0; row padding (rowStride >
// width) is reported via stride_bytes (consumers honor per-plane stride).
static bool build_cpu_planes(AImage *image, MiniAVBuffer *buf, uint32_t width,
                             uint32_t height) {
  int32_t num_planes = 0;
  if (AImage_getNumberOfPlanes(image, &num_planes) != AMEDIA_OK ||
      num_planes < 1) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: AImage_getNumberOfPlanes failed.");
    return false;
  }

  uint8_t *y_data = NULL;
  int y_len = 0;
  int32_t y_row_stride = 0, y_pixel_stride = 0;
  if (AImage_getPlaneData(image, 0, &y_data, &y_len) != AMEDIA_OK ||
      AImage_getPlaneRowStride(image, 0, &y_row_stride) != AMEDIA_OK ||
      AImage_getPlanePixelStride(image, 0, &y_pixel_stride) != AMEDIA_OK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: failed reading Y plane data/strides.");
    return false;
  }

  if (num_planes < 3) {
    // Not the YUV_420_888 triplet (e.g. an RGBA/JPEG reader). One opaque plane.
    buf->data.video.num_planes = 1;
    buf->data.video.planes[0].data_ptr = y_data;
    buf->data.video.planes[0].width = width;
    buf->data.video.planes[0].height = height;
    buf->data.video.planes[0].stride_bytes = (uint32_t)y_row_stride;
    buf->data.video.planes[0].offset_bytes = 0;
    buf->data.video.planes[0].subresource_index = 0;
    buf->data.video.planes[0].dmabuf_fd = -1;
    buf->data.video.planes[0].drm_format_modifier = 0;
    buf->data_size_bytes = (size_t)y_len;
    return true;
  }

  uint8_t *u_data = NULL, *v_data = NULL;
  int u_len = 0, v_len = 0;
  int32_t u_row_stride = 0, u_pixel_stride = 0;
  int32_t v_row_stride = 0, v_pixel_stride = 0;
  if (AImage_getPlaneData(image, 1, &u_data, &u_len) != AMEDIA_OK ||
      AImage_getPlaneRowStride(image, 1, &u_row_stride) != AMEDIA_OK ||
      AImage_getPlanePixelStride(image, 1, &u_pixel_stride) != AMEDIA_OK ||
      AImage_getPlaneData(image, 2, &v_data, &v_len) != AMEDIA_OK ||
      AImage_getPlaneRowStride(image, 2, &v_row_stride) != AMEDIA_OK ||
      AImage_getPlanePixelStride(image, 2, &v_pixel_stride) != AMEDIA_OK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: failed reading U/V plane data/strides.");
    return false;
  }
  // y_pixel_stride is always 1 for YUV_420_888 Y; read for completeness only.
  MINIAV_UNUSED(y_pixel_stride);

  const uint32_t chroma_w = width / 2;
  const uint32_t chroma_h = height / 2;

  // Y plane is common to every layout.
  buf->data.video.planes[0].data_ptr = y_data;
  buf->data.video.planes[0].width = width;
  buf->data.video.planes[0].height = height;
  buf->data.video.planes[0].stride_bytes = (uint32_t)y_row_stride;
  buf->data.video.planes[0].offset_bytes = 0;
  buf->data.video.planes[0].subresource_index = 0;
  buf->data.video.planes[0].dmabuf_fd = -1;
  buf->data.video.planes[0].drm_format_modifier = 0;

  if (u_pixel_stride == 2 || v_pixel_stride == 2) {
    // Interleaved chroma -> semi-planar (NV12 or NV21). The two chroma "planes"
    // alias the same interleaved buffer one byte apart; base ordering tells
    // NV12 (U first) from NV21 (V first). Deliver ONE (UV/VU) chroma plane.
    bool is_nv21 = (v_data < u_data);
    buf->data.video.info.pixel_format =
        is_nv21 ? MINIAV_PIXEL_FORMAT_NV21 : MINIAV_PIXEL_FORMAT_NV12;

    uint8_t *chroma_base = is_nv21 ? v_data : u_data;
    buf->data.video.num_planes = 2;
    buf->data.video.planes[1].data_ptr = chroma_base;
    buf->data.video.planes[1].width = chroma_w;
    buf->data.video.planes[1].height = chroma_h;
    // Interleaved UV row stride == the reported chroma rowStride (bytes/row).
    buf->data.video.planes[1].stride_bytes = (uint32_t)u_row_stride;
    buf->data.video.planes[1].offset_bytes = 0;
    buf->data.video.planes[1].subresource_index = 1;
    buf->data.video.planes[1].dmabuf_fd = -1;
    buf->data.video.planes[1].drm_format_modifier = 0;

    // The chroma plane's reported length covers the interleaved run.
    buf->data_size_bytes = (size_t)y_len + (size_t)u_len + 1;
    return true;
  }

  // Fully planar chroma (pixelStride == 1). We always assign planes[1]=U and
  // planes[2]=V below, so the label MUST be I420 (U-plane first) to stay
  // consistent — YV12 means V-plane first. A raw plane-pointer-order heuristic
  // (v_data < u_data) is meaningless for separately-allocated planes and would
  // mislabel the buffer while the U/V plane assignment stays fixed, delivering
  // swapped chroma to format-conforming consumers. Each plane carries its own
  // explicit base pointer, so labeling I420 loses no information.
  buf->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_I420;
  buf->data.video.num_planes = 3;

  buf->data.video.planes[1].data_ptr = u_data;
  buf->data.video.planes[1].width = chroma_w;
  buf->data.video.planes[1].height = chroma_h;
  buf->data.video.planes[1].stride_bytes = (uint32_t)u_row_stride;
  buf->data.video.planes[1].offset_bytes = 0;
  buf->data.video.planes[1].subresource_index = 1;
  buf->data.video.planes[1].dmabuf_fd = -1;
  buf->data.video.planes[1].drm_format_modifier = 0;

  buf->data.video.planes[2].data_ptr = v_data;
  buf->data.video.planes[2].width = chroma_w;
  buf->data.video.planes[2].height = chroma_h;
  buf->data.video.planes[2].stride_bytes = (uint32_t)v_row_stride;
  buf->data.video.planes[2].offset_bytes = 0;
  buf->data.video.planes[2].subresource_index = 2;
  buf->data.video.planes[2].dmabuf_fd = -1;
  buf->data.video.planes[2].drm_format_modifier = 0;

  buf->data_size_bytes = (size_t)y_len + (size_t)u_len + (size_t)v_len;
  return true;
}

// --- AImageReader frame-available callback -------------------------------
// Runs on the AImageReader's dedicated internal thread. Acquires the latest
// image, wraps it, and hands it to the app callback. The AImage is retained
// until MiniAV_ReleaseBuffer.
static void on_image_available(void *context, AImageReader *reader) {
  AndroidCamPlatformContext *pctx = (AndroidCamPlatformContext *)context;
  if (!pctx)
    return;

  pthread_mutex_lock(&pctx->lock);
  bool streaming = pctx->is_streaming;
  MiniAVCameraContext *parent = pctx->parent_ctx;
  bool gpu_path = pctx->gpu_path;
  MiniAVVideoInfo cfg = pctx->configured_video_format;
  pthread_mutex_unlock(&pctx->lock);

  if (!streaming || !parent) {
    // Drain so the reader does not wedge on maxImages after a stop race.
    AImage *drain = NULL;
    if (AImageReader_acquireNextImage(reader, &drain) == AMEDIA_OK && drain) {
      AImage_delete(drain);
    }
    return;
  }

  AImage *image = NULL;
  media_status_t st = AImageReader_acquireNextImage(reader, &image);
  if (st != AMEDIA_OK || !image) {
    // AMEDIA_IMGREADER_MAX_IMAGES_ACQUIRED == the app holds
    // ANDROID_CAM_MAX_IMAGES buffers; drop this frame (never stall).
    if (st == AMEDIA_IMGREADER_MAX_IMAGES_ACQUIRED) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "AndroidCam: max images acquired — dropping frame.");
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "AndroidCam: acquireNextImage returned %d (no frame).",
                 (int)st);
    }
    return;
  }

  int32_t img_w = (int32_t)cfg.width, img_h = (int32_t)cfg.height;
  AImage_getWidth(image, &img_w);
  AImage_getHeight(image, &img_h);

  int64_t ts_ns = 0;
  AImage_getTimestamp(image, &ts_ns); // sensor clock, nanoseconds

  MiniAVBuffer *buf = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  if (!buf) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: failed to allocate MiniAVBuffer.");
    AImage_delete(image);
    return;
  }

  buf->type = MINIAV_BUFFER_TYPE_VIDEO;
  // AImage_getTimestamp returns nanoseconds on the sensor clock. Convert to µs
  // and rebase onto the shared miniav_get_time_us() epoch (same discipline as
  // every other backend). Timebase is touched only on this delivery thread. A
  // zero/negative timestamp falls back to arrival time.
  buf->timestamp_us =
      ts_ns > 0 ? (int64_t)miniav_rebase_time_us(&pctx->timebase,
                                                 (uint64_t)(ts_ns / 1000))
                : (int64_t)miniav_get_time_us();
  buf->data.video.info = cfg;
  buf->data.video.info.width = (uint32_t)img_w;
  buf->data.video.info.height = (uint32_t)img_h;
  buf->user_data = parent->app_callback_user_data;

  AndroidCamFrameReleasePayload *frame_payload =
      (AndroidCamFrameReleasePayload *)miniav_calloc(
          1, sizeof(AndroidCamFrameReleasePayload));
  if (!frame_payload) {
    miniav_free(buf);
    AImage_delete(image);
    return;
  }
  frame_payload->image = image;

  bool ok = false;
  if (gpu_path) {
    // GPU path: hand out the AHardwareBuffer. AImage_getHardwareBuffer does NOT
    // transfer ownership, so acquire an extra reference the release path drops;
    // the AImage is retained separately (deleting it too early would invalidate
    // the AHardwareBuffer's backing store).
    AHardwareBuffer *hb = NULL;
    if (AImage_getHardwareBuffer(image, &hb) == AMEDIA_OK && hb) {
      AHardwareBuffer_acquire(hb);
      frame_payload->hardware_buffer = hb;
      frame_payload->type = MINIAV_OUTPUT_PREFERENCE_GPU;

      buf->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_AHARDWAREBUFFER;
      buf->data.video.num_planes = 1;
      buf->data.video.planes[0].data_ptr = (void *)hb; // AHardwareBuffer*
      buf->data.video.planes[0].width = (uint32_t)img_w;
      buf->data.video.planes[0].height = (uint32_t)img_h;
      buf->data.video.planes[0].stride_bytes = 0; // opaque to CPU
      buf->data.video.planes[0].offset_bytes = 0;
      buf->data.video.planes[0].subresource_index = 0;
      buf->data.video.planes[0].dmabuf_fd = -1;
      buf->data.video.planes[0].drm_format_modifier = 0;
      buf->data_size_bytes = 0;
      // No real acquire fence available from AImageReader here.
      buf->native_fence.sync_fd = -1;
      ok = true;
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "AndroidCam: AImage_getHardwareBuffer failed on GPU path.");
    }
  }

  if (!ok) {
    // CPU path (either configured CPU, or GPU fell through).
    frame_payload->type = MINIAV_OUTPUT_PREFERENCE_CPU;
    buf->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    if (build_cpu_planes(image, buf, (uint32_t)img_w, (uint32_t)img_h)) {
      ok = true;
    }
  }

  if (!ok) {
    miniav_free(frame_payload);
    miniav_free(buf);
    AImage_delete(image);
    return;
  }

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  if (!payload) {
    if (frame_payload->hardware_buffer) {
      AHardwareBuffer_release(frame_payload->hardware_buffer);
    }
    miniav_free(frame_payload);
    miniav_free(buf);
    AImage_delete(image);
    return;
  }
  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA;
  payload->context_owner = parent;
  payload->native_singular_resource_ptr = frame_payload;
  payload->num_planar_resources_to_release = 0;
  payload->parent_miniav_buffer_ptr = buf;
  buf->internal_handle = payload;

  // Deliver-or-release: we MUST NOT skip-and-leak. If MINIAV_SAFE_DISPATCH
  // silently dropped the call while callbacks are quiesced (MiniAV_Dispose / hot
  // restart), this AImage would keep one of the AImageReader's few bounded
  // reader slots forever; once all slots leak, AImageReader deletion in teardown
  // blocks waiting for acquired images. So on every no-deliver path (no callback
  // registered, or callbacks quiesced) we release the full resource set
  // synchronously here. Take the dispatch guard explicitly rather than via
  // MINIAV_SAFE_DISPATCH so we can tell "delivered" from "quiesced".
  bool delivered = false;
  if (parent->app_callback && miniav_dispatch_guard_acquire_if_enabled()) {
    parent->app_callback(buf, parent->app_callback_user_data);
    miniav_dispatch_guard_release();
    delivered = true;
  }
  if (!delivered) {
    // No callback registered, or callbacks quiesced: release everything now
    // (same resource set the consumer's release_buffer would have freed) so we
    // never hold a bounded reader slot into teardown.
    if (frame_payload->hardware_buffer) {
      AHardwareBuffer_release(frame_payload->hardware_buffer);
    }
    AImage_delete(frame_payload->image);
    miniav_free(frame_payload);
    miniav_free(payload);
    miniav_free(buf);
  }
}

// --- Enumeration / formats (stateless; transient ACameraManager) ---------

static MiniAVResultCode
android_cam_enumerate_devices(MiniAVDeviceInfo **devices_out,
                              uint32_t *count_out) {
  if (!devices_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *devices_out = NULL;
  *count_out = 0;

  ACameraManager *mgr = ACameraManager_create();
  if (!mgr) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: ACameraManager_create failed.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ACameraIdList *id_list = NULL;
  camera_status_t cs = ACameraManager_getCameraIdList(mgr, &id_list);
  if (cs != ACAMERA_OK || !id_list) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: getCameraIdList failed (%d).", (int)cs);
    ACameraManager_delete(mgr);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (id_list->numCameras <= 0) {
    miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: no cameras found.");
    ACameraManager_deleteCameraIdList(id_list);
    ACameraManager_delete(mgr);
    return MINIAV_SUCCESS; // not an error
  }

  MiniAVDeviceInfo *devices = (MiniAVDeviceInfo *)miniav_calloc(
      (size_t)id_list->numCameras, sizeof(MiniAVDeviceInfo));
  if (!devices) {
    ACameraManager_deleteCameraIdList(id_list);
    ACameraManager_delete(mgr);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  uint32_t out_count = 0;
  for (int i = 0; i < id_list->numCameras; ++i) {
    const char *cam_id = id_list->cameraIds[i];
    if (!cam_id)
      continue;

    miniav_strlcpy(devices[out_count].device_id, cam_id,
                   MINIAV_DEVICE_ID_MAX_LEN);

    // Human-readable name from the LENS_FACING metadata.
    const char *facing_str = "External";
    ACameraMetadata *chars = NULL;
    if (ACameraManager_getCameraCharacteristics(mgr, cam_id, &chars) ==
            ACAMERA_OK &&
        chars) {
      ACameraMetadata_const_entry facing_entry;
      if (ACameraMetadata_getConstEntry(chars, ACAMERA_LENS_FACING,
                                        &facing_entry) == ACAMERA_OK &&
          facing_entry.count > 0) {
        switch (facing_entry.data.u8[0]) {
        case ACAMERA_LENS_FACING_FRONT:
          facing_str = "Front";
          break;
        case ACAMERA_LENS_FACING_BACK:
          facing_str = "Back";
          break;
        case ACAMERA_LENS_FACING_EXTERNAL:
        default:
          facing_str = "External";
          break;
        }
      }
      ACameraMetadata_free(chars);
    }
    snprintf(devices[out_count].name, MINIAV_DEVICE_NAME_MAX_LEN,
             "%s Camera (%s)", facing_str, cam_id);
    // Convention: the first camera (usually id "0", the main back camera) is
    // the default.
    devices[out_count].is_default = (out_count == 0);
    out_count++;
  }

  ACameraManager_deleteCameraIdList(id_list);
  ACameraManager_delete(mgr);

  *devices_out = devices;
  *count_out = out_count;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: enumerated %u camera(s).",
             out_count);
  return MINIAV_SUCCESS;
}

// Read the scaler stream configurations for a device and emit MiniAVVideoInfo
// entries for the formats we can deliver. Frame rate is reported at a nominal
// 30fps per resolution (Camera2 advertises per-format min-durations rather than
// discrete size/format/fps triples like V4L2/MF; 30 is the sane pick and what
// GetDefaultFormat targets).
static MiniAVResultCode
android_cam_get_supported_formats(const char *device_id,
                                  MiniAVVideoInfo **formats_out,
                                  uint32_t *count_out) {
  if (!device_id || !formats_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *formats_out = NULL;
  *count_out = 0;

  ACameraManager *mgr = ACameraManager_create();
  if (!mgr)
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;

  ACameraMetadata *chars = NULL;
  camera_status_t cs =
      ACameraManager_getCameraCharacteristics(mgr, device_id, &chars);
  if (cs != ACAMERA_OK || !chars) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: getCameraCharacteristics failed for %s (%d).",
               device_id, (int)cs);
    ACameraManager_delete(mgr);
    return (cs == ACAMERA_ERROR_INVALID_PARAMETER)
               ? MINIAV_ERROR_DEVICE_NOT_FOUND
               : MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ACameraMetadata_const_entry stream_entry;
  cs = ACameraMetadata_getConstEntry(
      chars, ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS, &stream_entry);
  if (cs != ACAMERA_OK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: no stream configurations for %s.", device_id);
    ACameraMetadata_free(chars);
    ACameraManager_delete(mgr);
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  // Layout: repeated { format, width, height, isInput } int32 quadruples.
  const int32_t *e = stream_entry.data.i32;
  const uint32_t quads = stream_entry.count / 4;

  MiniAVVideoInfo *list =
      (MiniAVVideoInfo *)miniav_calloc(quads ? quads : 1,
                                       sizeof(MiniAVVideoInfo));
  if (!list) {
    ACameraMetadata_free(chars);
    ACameraManager_delete(mgr);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  uint32_t n = 0;
  for (uint32_t i = 0; i < quads; ++i) {
    int32_t fmt = e[i * 4 + 0];
    int32_t w = e[i * 4 + 1];
    int32_t h = e[i * 4 + 2];
    int32_t is_input = e[i * 4 + 3];
    if (is_input) // ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_INPUT
      continue;

    MiniAVPixelFormat pf = android_stream_format_to_miniav(fmt);
    if (pf == MINIAV_PIXEL_FORMAT_UNKNOWN || w <= 0 || h <= 0)
      continue;

    // De-dup identical (format,w,h) entries.
    bool dup = false;
    for (uint32_t j = 0; j < n; ++j) {
      if (list[j].width == (uint32_t)w && list[j].height == (uint32_t)h &&
          list[j].pixel_format == pf) {
        dup = true;
        break;
      }
    }
    if (dup)
      continue;

    list[n].width = (uint32_t)w;
    list[n].height = (uint32_t)h;
    list[n].pixel_format = pf;
    list[n].frame_rate_numerator = 30;
    list[n].frame_rate_denominator = 1;
    list[n].output_preference = MINIAV_OUTPUT_PREFERENCE_CPU;
    n++;
  }

  ACameraMetadata_free(chars);
  ACameraManager_delete(mgr);

  if (n == 0) {
    miniav_free(list);
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "AndroidCam: no deliverable formats for %s.", device_id);
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  *formats_out = list;
  *count_out = n;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: %u supported format(s) for %s.",
             n, device_id);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
android_cam_get_default_format(const char *device_id,
                               MiniAVVideoInfo *format_out) {
  if (!device_id || !format_out)
    return MINIAV_ERROR_INVALID_ARG;
  memset(format_out, 0, sizeof(MiniAVVideoInfo));

  MiniAVVideoInfo *formats = NULL;
  uint32_t count = 0;
  MiniAVResultCode res =
      android_cam_get_supported_formats(device_id, &formats, &count);
  if (res != MINIAV_SUCCESS || count == 0) {
    // Fallback: a sane YUV 1280x720@30 pick (spec).
    format_out->width = 1280;
    format_out->height = 720;
    format_out->frame_rate_numerator = 30;
    format_out->frame_rate_denominator = 1;
    format_out->pixel_format = MINIAV_PIXEL_FORMAT_I420;
    format_out->output_preference = MINIAV_OUTPUT_PREFERENCE_CPU;
    if (formats)
      miniav_free(formats);
    return MINIAV_SUCCESS;
  }

  // Prefer 1280x720 YUV; else the largest YUV <= 1920x1080; else first.
  MiniAVVideoInfo *selected = &formats[0];
  MiniAVVideoInfo *best_720 = NULL;
  MiniAVVideoInfo *best_yuv = NULL;
  for (uint32_t i = 0; i < count; ++i) {
    bool is_yuv = formats[i].pixel_format == MINIAV_PIXEL_FORMAT_I420 ||
                  formats[i].pixel_format == MINIAV_PIXEL_FORMAT_NV12 ||
                  formats[i].pixel_format == MINIAV_PIXEL_FORMAT_YV12;
    if (!is_yuv)
      continue;
    if (formats[i].width == 1280 && formats[i].height == 720) {
      best_720 = &formats[i];
      break;
    }
    if (formats[i].width <= 1920 && formats[i].height <= 1080) {
      if (!best_yuv || (formats[i].width * formats[i].height >
                        best_yuv->width * best_yuv->height)) {
        best_yuv = &formats[i];
      }
    }
  }
  if (best_720)
    selected = best_720;
  else if (best_yuv)
    selected = best_yuv;

  *format_out = *selected;
  format_out->output_preference = MINIAV_OUTPUT_PREFERENCE_CPU;
  miniav_free(formats);

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "AndroidCam: default format for %s: %ux%u @ %u/%u, fmt=%d",
             device_id, format_out->width, format_out->height,
             format_out->frame_rate_numerator,
             format_out->frame_rate_denominator, format_out->pixel_format);
  return MINIAV_SUCCESS;
}

// --- Platform lifecycle --------------------------------------------------

static MiniAVResultCode android_cam_init_platform(MiniAVCameraContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  if (android_runtime_api_level() < 24) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: Camera2 NDK requires API 24+ (device is %d).",
               android_runtime_api_level());
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  AndroidCamPlatformContext *pctx = (AndroidCamPlatformContext *)miniav_calloc(
      1, sizeof(AndroidCamPlatformContext));
  if (!pctx)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  pctx->parent_ctx = ctx;
  atomic_store(&pctx->lost_cb_fired, false);

  if (pthread_mutex_init(&pctx->lock, NULL) != 0) {
    miniav_free(pctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pctx->manager = ACameraManager_create();
  if (!pctx->manager) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: ACameraManager_create failed in init.");
    pthread_mutex_destroy(&pctx->lock);
    miniav_free(pctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ctx->platform_ctx = pctx;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "AndroidCam: platform context initialized.");
  return MINIAV_SUCCESS;
}

// Tears down the Camera2 capture graph (session/request/reader/device). The
// NDK *_close/*_delete calls are synchronous and internally drain their looper
// threads, so on return no further callbacks reference our context. Order
// matters: stop the session, close it (drains in-flight callbacks), free the
// request/target/output/container, close the device, then delete the reader
// LAST (app-held AImages stay valid until their own AImage_delete). Idempotent.
static void android_cam_teardown_capture(AndroidCamPlatformContext *p) {
  if (p->capture_session) {
    ACameraCaptureSession_stopRepeating(p->capture_session);
    ACameraCaptureSession_close(p->capture_session);
    p->capture_session = NULL;
  }
  if (p->capture_request) {
    ACaptureRequest_free(p->capture_request);
    p->capture_request = NULL;
  }
  if (p->output_target) {
    ACameraOutputTarget_free(p->output_target);
    p->output_target = NULL;
  }
  if (p->session_output) {
    ACaptureSessionOutput_free(p->session_output);
    p->session_output = NULL;
  }
  if (p->output_container) {
    ACaptureSessionOutputContainer_free(p->output_container);
    p->output_container = NULL;
  }
  if (p->device) {
    ACameraDevice_close(p->device);
    p->device = NULL;
  }
  if (p->image_reader) {
    // Removing the listener first prevents a late onImageAvailable from racing
    // the delete. Deleting the reader invalidates reader_window and any
    // un-acquired images; app-held images remain valid until AImage_delete.
    AImageReader_setImageListener(p->image_reader, NULL);
    AImageReader_delete(p->image_reader);
    p->image_reader = NULL;
    p->reader_window = NULL;
  }
}

static MiniAVResultCode android_cam_destroy_platform(MiniAVCameraContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_SUCCESS;
  AndroidCamPlatformContext *p = (AndroidCamPlatformContext *)ctx->platform_ctx;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "AndroidCam: destroying platform context.");

  pthread_mutex_lock(&p->lock);
  p->is_streaming = false;
  pthread_mutex_unlock(&p->lock);

  // The NDK owns the callback threads; its synchronous close/delete calls drain
  // them, so there is no thread of ours to time-join here — teardown is
  // bounded by the NDK. (The MINIAV_ERROR_TIMEOUT retry-then-leak protocol
  // still exists in stop_capture for the pathological case where the NDK close
  // itself hangs; destroy proceeds unconditionally since the context is going
  // away regardless.)
  android_cam_teardown_capture(p);

  if (p->manager) {
    ACameraManager_delete(p->manager);
    p->manager = NULL;
  }

  pthread_mutex_destroy(&p->lock);
  miniav_free(p);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
android_cam_get_configured_video_format(MiniAVCameraContext *ctx,
                                        MiniAVVideoInfo *format_out) {
  if (!ctx || !ctx->platform_ctx || !format_out)
    return MINIAV_ERROR_INVALID_ARG;
  AndroidCamPlatformContext *p = (AndroidCamPlatformContext *)ctx->platform_ctx;

  pthread_mutex_lock(&p->lock);
  MiniAVVideoInfo snap = p->configured_video_format;
  bool configured = p->is_configured;
  pthread_mutex_unlock(&p->lock);

  if (!configured || snap.width == 0 || snap.height == 0)
    return MINIAV_ERROR_NOT_INITIALIZED;
  *format_out = snap;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode android_cam_configure(MiniAVCameraContext *ctx,
                                              const char *device_id,
                                              const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !format)
    return MINIAV_ERROR_INVALID_ARG;
  AndroidCamPlatformContext *p = (AndroidCamPlatformContext *)ctx->platform_ctx;

  pthread_mutex_lock(&p->lock);
  if (p->is_streaming) {
    pthread_mutex_unlock(&p->lock);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: cannot configure while streaming.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  int32_t img_fmt = miniav_format_to_android_image_format(format->pixel_format);
  if (img_fmt == 0) {
    pthread_mutex_unlock(&p->lock);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: unsupported pixel format %d for configure.",
               format->pixel_format);
    return MINIAV_ERROR_FORMAT_NOT_SUPPORTED;
  }

  // device_id NULL => default (camera "0"); resolved here so start_capture is
  // simple. The API layer already caches selected_device_id separately.
  if (device_id && device_id[0]) {
    miniav_strlcpy(p->camera_id, device_id, sizeof(p->camera_id));
  } else {
    miniav_strlcpy(p->camera_id, "0", sizeof(p->camera_id));
  }

  p->configured_video_format = *format;
  p->image_format = img_fmt;
  p->is_configured = true;
  pthread_mutex_unlock(&p->lock);

  ctx->configured_video_format = *format;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "AndroidCam: configured device '%s' %ux%u fmt=%d pref=%d.",
             p->camera_id, format->width, format->height, format->pixel_format,
             format->output_preference);
  return MINIAV_SUCCESS;
}

static ACameraDevice_StateCallbacks
make_device_callbacks(AndroidCamPlatformContext *pctx) {
  ACameraDevice_StateCallbacks cb;
  memset(&cb, 0, sizeof(cb));
  cb.context = pctx;
  cb.onDisconnected = on_device_disconnected;
  cb.onError = on_device_error;
  return cb;
}

static ACameraCaptureSession_stateCallbacks
make_session_callbacks(AndroidCamPlatformContext *pctx) {
  ACameraCaptureSession_stateCallbacks cb;
  memset(&cb, 0, sizeof(cb));
  cb.context = pctx;
  cb.onClosed = on_session_closed;
  cb.onReady = on_session_ready;
  cb.onActive = on_session_active;
  return cb;
}

static MiniAVResultCode android_cam_start_capture(MiniAVCameraContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  AndroidCamPlatformContext *p = (AndroidCamPlatformContext *)ctx->platform_ctx;

  pthread_mutex_lock(&p->lock);
  if (!p->is_configured) {
    pthread_mutex_unlock(&p->lock);
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  if (p->is_streaming) {
    pthread_mutex_unlock(&p->lock);
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  MiniAVVideoInfo cfg = p->configured_video_format;
  int32_t img_fmt = p->image_format;
  char cam_id[MINIAV_DEVICE_ID_MAX_LEN];
  miniav_strlcpy(cam_id, p->camera_id, sizeof(cam_id));
  pthread_mutex_unlock(&p->lock);

  // Fresh per-run calibration + lost guard.
  memset(&p->timebase, 0, sizeof(p->timebase));
  atomic_store(&p->lost_cb_fired, false);

  // Decide GPU vs CPU. GPU requires API 26+ AND YUV_420_888. Below 26 or on a
  // non-YUV format, fall back to CPU.
  bool want_gpu = (cfg.output_preference == MINIAV_OUTPUT_PREFERENCE_GPU);
  bool gpu_ok = want_gpu && (android_runtime_api_level() >= 26) &&
                (img_fmt == AIMAGE_FORMAT_YUV_420_888);
  if (want_gpu && !gpu_ok) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "AndroidCam: GPU AHardwareBuffer path unavailable (API<26 or "
               "non-YUV) — using CPU path.");
  }
  p->gpu_path = gpu_ok;

  MiniAVResultCode result = MINIAV_SUCCESS;
  camera_status_t cs;
  media_status_t ms;
  // Declared up-front (not after a goto target) so the error gotos below never
  // jump over an initializer (a -Wjump-misses-init error in these builds).
  AImageReader_ImageListener listener;
  ACameraDevice_StateCallbacks dev_cb;
  ACameraCaptureSession_stateCallbacks sess_cb;

  // --- AImageReader (capture target) ---
  if (p->gpu_path) {
    ms = AImageReader_newWithUsage(
        (int32_t)cfg.width, (int32_t)cfg.height, img_fmt,
        AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, ANDROID_CAM_MAX_IMAGES,
        &p->image_reader);
  } else {
    ms = AImageReader_new((int32_t)cfg.width, (int32_t)cfg.height, img_fmt,
                          ANDROID_CAM_MAX_IMAGES, &p->image_reader);
  }
  if (ms != AMEDIA_OK || !p->image_reader) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: AImageReader creation failed (%d).", (int)ms);
    result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto fail;
  }

  listener.context = p;
  listener.onImageAvailable = on_image_available;
  AImageReader_setImageListener(p->image_reader, &listener);

  ms = AImageReader_getWindow(p->image_reader, &p->reader_window);
  if (ms != AMEDIA_OK || !p->reader_window) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: AImageReader_getWindow failed (%d).", (int)ms);
    result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto fail;
  }

  // --- Open the camera device ---
  dev_cb = make_device_callbacks(p);
  cs = ACameraManager_openCamera(p->manager, cam_id, &dev_cb, &p->device);
  if (cs != ACAMERA_OK || !p->device) {
    if (cs == ACAMERA_ERROR_PERMISSION_DENIED) {
      // App must hold android.permission.CAMERA. miniAV never prompts.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "AndroidCam: CAMERA permission denied opening %s.", cam_id);
      result = MINIAV_ERROR_PERMISSION_DENIED;
    } else if (cs == ACAMERA_ERROR_CAMERA_IN_USE ||
               cs == ACAMERA_ERROR_MAX_CAMERA_IN_USE) {
      result = MINIAV_ERROR_DEVICE_BUSY;
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "AndroidCam: openCamera(%s) failed (%d).", cam_id, (int)cs);
      result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    goto fail;
  }

  // --- Build the capture session graph ---
  cs = ACaptureSessionOutputContainer_create(&p->output_container);
  if (cs != ACAMERA_OK)
    goto fail_syscall;

  cs = ACaptureSessionOutput_create(p->reader_window, &p->session_output);
  if (cs != ACAMERA_OK)
    goto fail_syscall;
  cs = ACaptureSessionOutputContainer_add(p->output_container,
                                          p->session_output);
  if (cs != ACAMERA_OK)
    goto fail_syscall;

  cs = ACameraOutputTarget_create(p->reader_window, &p->output_target);
  if (cs != ACAMERA_OK)
    goto fail_syscall;

  cs = ACameraDevice_createCaptureRequest(p->device, TEMPLATE_PREVIEW,
                                          &p->capture_request);
  if (cs != ACAMERA_OK)
    goto fail_syscall;
  cs = ACaptureRequest_addTarget(p->capture_request, p->output_target);
  if (cs != ACAMERA_OK)
    goto fail_syscall;

  sess_cb = make_session_callbacks(p);
  cs = ACameraDevice_createCaptureSession(p->device, p->output_container,
                                          &sess_cb, &p->capture_session);
  if (cs != ACAMERA_OK || !p->capture_session) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: createCaptureSession failed (%d).", (int)cs);
    result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto fail;
  }

  // Mark streaming BEFORE the first frames can be dispatched by the reader.
  pthread_mutex_lock(&p->lock);
  p->is_streaming = true;
  pthread_mutex_unlock(&p->lock);

  cs = ACameraCaptureSession_setRepeatingRequest(p->capture_session, NULL, 1,
                                                 &p->capture_request, NULL);
  if (cs != ACAMERA_OK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AndroidCam: setRepeatingRequest failed (%d).", (int)cs);
    pthread_mutex_lock(&p->lock);
    p->is_streaming = false;
    pthread_mutex_unlock(&p->lock);
    result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto fail;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "AndroidCam: capture started on '%s' (%s path).", cam_id,
             p->gpu_path ? "GPU AHardwareBuffer" : "CPU YUV");
  return MINIAV_SUCCESS;

fail_syscall:
  miniav_log(MINIAV_LOG_LEVEL_ERROR,
             "AndroidCam: capture graph setup failed (%d).", (int)cs);
  result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
  // fallthrough

fail:
  pthread_mutex_lock(&p->lock);
  p->is_streaming = false;
  pthread_mutex_unlock(&p->lock);
  android_cam_teardown_capture(p);
  return result;
}

static MiniAVResultCode android_cam_stop_capture(MiniAVCameraContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  AndroidCamPlatformContext *p = (AndroidCamPlatformContext *)ctx->platform_ctx;

  pthread_mutex_lock(&p->lock);
  bool was_streaming = p->is_streaming;
  p->is_streaming = false;
  pthread_mutex_unlock(&p->lock);

  if (!was_streaming && !p->capture_session && !p->device && !p->image_reader) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "AndroidCam: stop with nothing running.");
    return MINIAV_SUCCESS;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: stopping capture.");

  // The NDK owns the callback threads and its close/delete calls synchronously
  // drain them — there is no thread of ours to time-join, and these calls must
  // NOT be issued from inside a Camera2 callback (the contract in
  // miniav_capture.h forbids synchronous Stop/Destroy from lost_cb, which is
  // exactly what would deadlock here). teardown flips is_streaming off first
  // (above) so any in-flight onImageAvailable drains its image and returns.
  android_cam_teardown_capture(p);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "AndroidCam: capture stopped.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
android_cam_release_buffer(MiniAVCameraContext *ctx,
                           void *internal_handle_ptr) {
  MINIAV_UNUSED(ctx);
  if (!internal_handle_ptr)
    return MINIAV_SUCCESS;

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA &&
      payload->native_singular_resource_ptr) {
    AndroidCamFrameReleasePayload *fp =
        (AndroidCamFrameReleasePayload *)payload->native_singular_resource_ptr;
    if (fp) {
      // GPU path: drop the extra AHardwareBuffer reference taken in
      // on_image_available, then delete the AImage (its backing owns the HB
      // pages, so release the extra ref first). CPU path: AImage_delete frees
      // the mapped plane data.
      if (fp->hardware_buffer) {
        AHardwareBuffer_release(fp->hardware_buffer);
        fp->hardware_buffer = NULL;
      }
      if (fp->image) {
        AImage_delete(fp->image);
        fp->image = NULL;
      }
      miniav_free(fp);
      payload->native_singular_resource_ptr = NULL;
    }
  }

  if (payload->parent_miniav_buffer_ptr) {
    miniav_free(payload->parent_miniav_buffer_ptr);
    payload->parent_miniav_buffer_ptr = NULL;
  }
  miniav_free(payload);
  return MINIAV_SUCCESS;
}

// --- Ops table + selection init -----------------------------------------

const CameraContextInternalOps g_camera_ops_android_camera2 = {
    .init_platform = android_cam_init_platform,
    .destroy_platform = android_cam_destroy_platform,
    .enumerate_devices = android_cam_enumerate_devices,
    .get_supported_formats = android_cam_get_supported_formats,
    .get_default_format = android_cam_get_default_format,
    .configure = android_cam_configure,
    .start_capture = android_cam_start_capture,
    .stop_capture = android_cam_stop_capture,
    .release_buffer = android_cam_release_buffer,
    .get_configured_video_format = android_cam_get_configured_video_format,
};

MiniAVResultCode
miniav_camera_context_platform_init_android_camera2(MiniAVCameraContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  ctx->ops = &g_camera_ops_android_camera2;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "AndroidCam: assigned Camera2 NDK camera ops.");
  return MINIAV_SUCCESS;
}

#endif // __ANDROID__
