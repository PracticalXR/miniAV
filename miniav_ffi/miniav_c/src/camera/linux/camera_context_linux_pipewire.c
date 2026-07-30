#define _GNU_SOURCE
#include "camera_context_linux_pipewire.h"
#include "../../../include/miniav_buffer.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#include <pipewire/pipewire.h>
#include <spa/debug/types.h>
#include <spa/param/props.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>

#include <fcntl.h>   // For O_CLOEXEC with pipe
#include <pthread.h> // For threading the main loop
#include <stdatomic.h> // For the one-shot lost_cb guard
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h> // For usleep (optional, for shutdown)

// Max number of formats we'll try to report for a device
#define PW_MAX_REPORTED_FORMATS 128
// Max number of devices we'll report
#define PW_MAX_REPORTED_DEVICES 32

typedef struct PipeWireDeviceTempInfo {
  MiniAVDeviceInfo info;
  bool is_video_source;
} PipeWireDeviceTempInfo;

typedef struct PipeWireEnumData {
  struct pw_main_loop *loop;
  MiniAVDeviceInfo *devices_list;
  uint32_t *devices_count;
  uint32_t allocated_devices;
  MiniAVResultCode result;
  int pending_sync; // Counter for pending sync events
} PipeWireEnumData;

typedef struct PipeWireFormatEnumData {
  struct pw_main_loop *loop;
  MiniAVVideoInfo *formats_list;
  uint32_t *formats_count;
  uint32_t allocated_formats;
  MiniAVResultCode result;
  int pending_sync;
  uint32_t node_id;
  struct pw_core *core;
  struct pw_node *node_proxy;
} PipeWireFormatEnumData;

typedef struct PipeWireStopRequest {
  bool stop_requested;
  bool stop_completed;
  pthread_mutex_t mutex;
  pthread_cond_t cond;
} PipeWireStopRequest;

typedef struct PipeWirePlatformContext {
  MiniAVCameraContext *parent_ctx;

  struct pw_main_loop *loop;
  struct pw_context *context;
  struct pw_core *core;
  struct pw_registry *registry;
  struct spa_hook registry_listener;

  struct pw_stream *stream;
  struct spa_hook stream_listener;

  pthread_t loop_thread;
  bool loop_running;
  int wakeup_pipe[2]; // Pipe to wake up the loop for shutdown

  PipeWireStopRequest stop_request;

  // Configuration
  uint32_t target_node_id;
  MiniAVVideoInfo configured_video_format;
  bool is_configured;
  bool is_streaming;

  // Rebases PipeWire's nanosecond graph-clock buffer time onto the shared
  // miniav_get_time_us() epoch (reset at start_capture).
  MiniAVTimebase timebase;
  // One-shot guard so a cascade of error state changes fires lost_cb once
  // (atomic: the loop thread and the app thread can race here).
  atomic_bool lost_cb_fired;

  // Temporary data for enumeration/format fetching
  PipeWireDeviceTempInfo temp_devices[PW_MAX_REPORTED_DEVICES];
  uint32_t num_temp_devices;

  uint32_t num_temp_formats;

  int pending_sync_ops; // For sync operations during init/enum

} PipeWirePlatformContext;

typedef struct PipeWireFrameReleasePayload {
  MiniAVOutputPreference type;
  union {
    struct { // For CPU
      void *cpu_ptr;
      size_t cpu_size;
      int src_dmabuf_fd; // Not owned, for debug
    } cpu;
    struct {             // For GPU
      int dup_dmabuf_fd; // Must be closed
    } gpu;
  };
} PipeWireFrameReleasePayload;

// Forward declarations for static functions

static MiniAVResultCode pw_init_platform(MiniAVCameraContext *ctx);
static MiniAVResultCode pw_destroy_platform(MiniAVCameraContext *ctx);
static MiniAVResultCode pw_enumerate_devices(MiniAVDeviceInfo **devices_out,
                                             uint32_t *count_out);
static MiniAVResultCode pw_get_supported_formats(const char *device_id_str,
                                                 MiniAVVideoInfo **formats_out,
                                                 uint32_t *count_out);
static MiniAVResultCode pw_configure(MiniAVCameraContext *ctx,
                                     const char *device_id,
                                     const MiniAVVideoInfo *format);
static MiniAVResultCode pw_start_capture(MiniAVCameraContext *ctx);
static MiniAVResultCode pw_get_buffer(MiniAVCameraContext *ctx,
                                      MiniAVBuffer *buffer,
                                      uint32_t timeout_ms);
static MiniAVResultCode pw_release_buffer(MiniAVCameraContext *ctx,
                                          void *buffer);
static MiniAVResultCode
pw_stop_capture(MiniAVCameraContext *ctx); // <--- ADD THIS FORWARD DECLARATION

// --- Helper Functions ---

static MiniAVPixelFormat
spa_video_format_to_miniav(uint32_t spa_format,
                           const struct spa_pod *format_pod) {
  switch (spa_format) {
  case SPA_VIDEO_FORMAT_RGB:
    return MINIAV_PIXEL_FORMAT_RGB24;
  case SPA_VIDEO_FORMAT_BGR:
    return MINIAV_PIXEL_FORMAT_BGR24;
  case SPA_VIDEO_FORMAT_RGBA:
    return MINIAV_PIXEL_FORMAT_RGBA32;
  case SPA_VIDEO_FORMAT_BGRA:
    return MINIAV_PIXEL_FORMAT_BGRA32;
  case SPA_VIDEO_FORMAT_ARGB:
    return MINIAV_PIXEL_FORMAT_ARGB32;
  case SPA_VIDEO_FORMAT_ABGR:
    return MINIAV_PIXEL_FORMAT_ABGR32;
  case SPA_VIDEO_FORMAT_YUY2:
    return MINIAV_PIXEL_FORMAT_YUY2;
  case SPA_VIDEO_FORMAT_UYVY:
    return MINIAV_PIXEL_FORMAT_UYVY;
  case SPA_VIDEO_FORMAT_I420:
    return MINIAV_PIXEL_FORMAT_I420;
  case SPA_VIDEO_FORMAT_NV12:
    return MINIAV_PIXEL_FORMAT_NV12;
    // No direct SPA_VIDEO_FORMAT_MJPG in spa-0.2/raw.h
    // case SPA_VIDEO_FORMAT_MJPG:      return MINIAV_PIXEL_FORMAT_MJPEG;

  case SPA_VIDEO_FORMAT_ENCODED:
    if (format_pod) {
      struct spa_pod_prop *prop;
      struct spa_pod_object *obj = (struct spa_pod_object *)format_pod;
      SPA_POD_OBJECT_FOREACH(obj, prop) {
        if (prop->key == SPA_FORMAT_mediaSubtype) {
          // The value of SPA_FORMAT_mediaSubtype is expected to be an Id pod
          if (spa_pod_is_id(&prop->value)) {
            uint32_t subtype_id;
            if (spa_pod_get_id(&prop->value, &subtype_id) == 0) {
              const char *subtype_name =
                  spa_debug_type_find_name(spa_type_media_subtype, subtype_id);
              if (subtype_name) {
                miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                           "PW: Media subtype ID %u is '%s'", subtype_id,
                           subtype_name);
                if (strcmp(subtype_name, "jpeg") == 0 ||
                    strcmp(subtype_name, "mjpeg") == 0) {
                  return MINIAV_PIXEL_FORMAT_MJPEG;
                }
              } else {
                miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                           "PW: Media subtype ID %u not found in debug types.",
                           subtype_id);
              }
            }
          } else if (spa_pod_is_string(&prop->value)) {
            // Less common for mediaSubtype, but handle if it's a direct string
            const char *subtype_name_str = NULL;
            if (spa_pod_get_string(&prop->value, &subtype_name_str) == 0 &&
                subtype_name_str) {
              miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                         "PW: Media subtype string is '%s'", subtype_name_str);
              if (strcmp(subtype_name_str, "jpeg") == 0 ||
                  strcmp(subtype_name_str, "mjpeg") == 0) {
                return MINIAV_PIXEL_FORMAT_MJPEG;
              }
            }
          }
          break;
        }
      }
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: SPA_VIDEO_FORMAT_ENCODED found, but subtype not MJPEG or "
               "not identifiable from pod.");
    return MINIAV_PIXEL_FORMAT_UNKNOWN; // Or a generic encoded type if you have
                                        // one

  default:
    return MINIAV_PIXEL_FORMAT_UNKNOWN;
  }
}

static uint32_t miniav_pixel_format_to_spa(MiniAVPixelFormat miniav_format) {
  switch (miniav_format) {
  case MINIAV_PIXEL_FORMAT_RGB24:
    return SPA_VIDEO_FORMAT_RGB;
  case MINIAV_PIXEL_FORMAT_BGR24:
    return SPA_VIDEO_FORMAT_BGR;
  case MINIAV_PIXEL_FORMAT_RGBA32:
    return SPA_VIDEO_FORMAT_RGBA;
  case MINIAV_PIXEL_FORMAT_BGRA32:
    return SPA_VIDEO_FORMAT_BGRA;
  case MINIAV_PIXEL_FORMAT_ARGB32:
    return SPA_VIDEO_FORMAT_ARGB;
  case MINIAV_PIXEL_FORMAT_ABGR32:
    return SPA_VIDEO_FORMAT_ABGR;
  case MINIAV_PIXEL_FORMAT_YUY2:
    return SPA_VIDEO_FORMAT_YUY2;
  case MINIAV_PIXEL_FORMAT_UYVY:
    return SPA_VIDEO_FORMAT_UYVY;
  case MINIAV_PIXEL_FORMAT_I420:
    return SPA_VIDEO_FORMAT_I420;
  case MINIAV_PIXEL_FORMAT_NV12:
    return SPA_VIDEO_FORMAT_NV12;
  case MINIAV_PIXEL_FORMAT_MJPEG:
    return SPA_VIDEO_FORMAT_ENCODED;
  default:
    return SPA_VIDEO_FORMAT_UNKNOWN;
  }
}

const char *miniav_pixel_format_to_string_short(MiniAVPixelFormat format) {
  switch (format) {
  case MINIAV_PIXEL_FORMAT_UNKNOWN:
    return "UNKN";
  case MINIAV_PIXEL_FORMAT_I420:
    return "I420";
  case MINIAV_PIXEL_FORMAT_NV12:
    return "NV12";
  case MINIAV_PIXEL_FORMAT_NV21:
    return "NV21";
  case MINIAV_PIXEL_FORMAT_YUY2:
    return "YUY2";
  case MINIAV_PIXEL_FORMAT_UYVY:
    return "UYVY";
  case MINIAV_PIXEL_FORMAT_RGB24:
    return "RGB24";
  case MINIAV_PIXEL_FORMAT_BGR24:
    return "BGR24";
  case MINIAV_PIXEL_FORMAT_RGBA32:
    return "RGBA32";
  case MINIAV_PIXEL_FORMAT_BGRA32:
    return "BGRA32";
  case MINIAV_PIXEL_FORMAT_ARGB32:
    return "ARGB32";
  case MINIAV_PIXEL_FORMAT_ABGR32:
    return "ABGR32";
  case MINIAV_PIXEL_FORMAT_MJPEG:
    return "MJPG";
  default:
    return "INV"; // Invalid/Unknown
  }
}

static void parse_spa_format(const struct spa_pod *format_pod,
                             MiniAVVideoInfo *info) {
  struct spa_video_info_raw raw_info = {0};

  if (spa_format_video_raw_parse(format_pod, &raw_info) >= 0) {
    info->pixel_format = spa_video_format_to_miniav(
        raw_info.format, format_pod); // Pass format_pod for MJPEG subtype check
    info->width = raw_info.size.width;
    info->height = raw_info.size.height;
    info->frame_rate_numerator = raw_info.framerate.num;
    info->frame_rate_denominator = raw_info.framerate.denom;

    // It's good practice to ensure framerate denominator is not zero if num is
    // non-zero
    if (info->frame_rate_numerator != 0 && info->frame_rate_denominator == 0) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW: Parsed format with numerator %u but denominator 0. "
                 "Setting denominator to 1.",
                 info->frame_rate_numerator);
      info->frame_rate_denominator = 1; // Avoid division by zero later
    }

  } else {
    if (spa_pod_is_choice(format_pod)) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: parse_spa_format called with a CHOICE/ANY type pod. This "
                 "should be handled by parse_spa_format_choices.");
    } else {
      struct spa_video_info_dsp dsp_info = {0}; // Declare the struct
      uint32_t spa_fmt_id = SPA_VIDEO_FORMAT_UNKNOWN;

      if (spa_format_video_dsp_parse(format_pod, &dsp_info) >=
          0) {                        // Pass address of struct
        spa_fmt_id = dsp_info.format; // Extract the format
      } else {
        miniav_log(
            MINIAV_LOG_LEVEL_DEBUG,
            "PW: spa_format_video_dsp_parse also failed for non-raw format.");
      }

      info->pixel_format = spa_video_format_to_miniav(spa_fmt_id, format_pod);
      if (info->pixel_format == MINIAV_PIXEL_FORMAT_MJPEG) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW: Identified MJPEG from non-raw/dsp parse. W/H/FPS might "
                   "be missing from this path.");
      } else if (spa_fmt_id != SPA_VIDEO_FORMAT_UNKNOWN) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW: Could not parse as spa_video_info_raw, but got format "
                   "%u from dsp_parse.",
                   spa_fmt_id);
      } else {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW: Could not parse as spa_video_info_raw and not "
                   "identifiable as MJPEG or from dsp_parse. Format unknown.");
      }
    }
    if (info->pixel_format ==
        MINIAV_PIXEL_FORMAT_UNKNOWN) { // Ensure it's set if all parsing fails
      info->pixel_format = MINIAV_PIXEL_FORMAT_UNKNOWN;
    }
  }
}
// --- Stream Callbacks ---
static void on_stream_process(void *userdata) {
  PipeWirePlatformContext *pw_ctx = (PipeWirePlatformContext *)userdata;
  struct pw_buffer *pw_buf;
  if (!pw_ctx || !pw_ctx->parent_ctx || !pw_ctx->parent_ctx->app_callback)
    return;

  pw_buf = pw_stream_dequeue_buffer(pw_ctx->stream);
  if (!pw_buf)
    return;

  struct spa_buffer *spa_buf = pw_buf->buffer;
  struct spa_data *d = &spa_buf->datas[0];

  // Log the buffer type
  const char *type_str = "UNKNOWN";
  switch (d->type) {
  case SPA_DATA_DmaBuf:
    type_str = "DmaBuf";
    break;
  case SPA_DATA_MemFd:
    type_str = "MemFd";
    break;
  case SPA_DATA_MemPtr:
    type_str = "MemPtr";
    break;
  }
  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Received buffer type: %s (type=%d)",
             type_str, d->type);

  MiniAVBuffer *miniav_buffer =
      (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  if (!miniav_buffer) {
    pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
    return;
  }

  miniav_buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
  // pw_buf->time is PipeWire's graph/driver clock in NANOSECONDS (signed)
  // with its own epoch. Convert to µs and rebase onto the shared
  // miniav_get_time_us() (CLOCK_MONOTONIC) timeline so camera timestamps are
  // comparable with the other tracks. Buffers without a valid driver
  // timestamp (zero or negative) use arrival time without touching the
  // calibration.
  miniav_buffer->timestamp_us =
      pw_buf->time > 0
          ? miniav_rebase_time_us(&pw_ctx->timebase,
                                  (uint64_t)pw_buf->time / 1000)
          : miniav_get_time_us();
  miniav_buffer->data.video.info = pw_ctx->configured_video_format;
  miniav_buffer->user_data = pw_ctx->parent_ctx->app_callback_user_data;

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  if (!payload) {
    miniav_free(miniav_buffer);
    pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
    return;
  }
  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA;
  payload->context_owner = pw_ctx->parent_ctx;
  payload->parent_miniav_buffer_ptr = miniav_buffer;

  PipeWireFrameReleasePayload *frame_payload =
      (PipeWireFrameReleasePayload *)miniav_calloc(
          1, sizeof(PipeWireFrameReleasePayload));
  if (!frame_payload) {
    miniav_free(payload);
    miniav_free(miniav_buffer);
    pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
    return;
  }

  bool ok = false;
  MiniAVPixelFormat format = pw_ctx->configured_video_format.pixel_format;
  uint32_t width = pw_ctx->configured_video_format.width;
  uint32_t height = pw_ctx->configured_video_format.height;

  // Handle GPU path (DMA-BUF)
  if (d->type == SPA_DATA_DmaBuf && d->fd >= 0) {
    int dup_fd = fcntl(d->fd, F_DUPFD_CLOEXEC, 0);
    if (dup_fd != -1) {
      miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_DMABUF_FD;

      // Set up planes based on pixel format
      if (format == MINIAV_PIXEL_FORMAT_NV12) {
        miniav_buffer->data.video.num_planes = 2;

        // Y plane (full resolution)
        miniav_buffer->data.video.planes[0].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes = width;
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;

        // UV plane (half resolution, interleaved)
        miniav_buffer->data.video.planes[1].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[1].width = width / 2;
        miniav_buffer->data.video.planes[1].height = height / 2;
        miniav_buffer->data.video.planes[1].stride_bytes =
            width; // UV stride = Y stride for NV12
        miniav_buffer->data.video.planes[1].offset_bytes =
            width * height; // UV starts after Y
        miniav_buffer->data.video.planes[1].subresource_index = 1;

      } else if (format == MINIAV_PIXEL_FORMAT_I420) {
        miniav_buffer->data.video.num_planes = 3;
        uint32_t y_size = width * height;
        uint32_t uv_size = (width / 2) * (height / 2);

        // Y plane
        miniav_buffer->data.video.planes[0].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes = width;
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;

        // U plane
        miniav_buffer->data.video.planes[1].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[1].width = width / 2;
        miniav_buffer->data.video.planes[1].height = height / 2;
        miniav_buffer->data.video.planes[1].stride_bytes = width / 2;
        miniav_buffer->data.video.planes[1].offset_bytes = y_size;
        miniav_buffer->data.video.planes[1].subresource_index = 1;

        // V plane
        miniav_buffer->data.video.planes[2].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[2].width = width / 2;
        miniav_buffer->data.video.planes[2].height = height / 2;
        miniav_buffer->data.video.planes[2].stride_bytes = width / 2;
        miniav_buffer->data.video.planes[2].offset_bytes = y_size + uv_size;
        miniav_buffer->data.video.planes[2].subresource_index = 2;

      } else {
        // Non-planar formats (BGRA, RGB, etc.)
        miniav_buffer->data.video.num_planes = 1;
        miniav_buffer->data.video.planes[0].data_ptr = (void *)(intptr_t)dup_fd;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes =
            d->chunk ? d->chunk->stride : width * 4; // Assume 4 bytes for BGRA
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;
      }

      miniav_buffer->data_size_bytes = d->maxsize;
      frame_payload->type = MINIAV_OUTPUT_PREFERENCE_GPU;
      frame_payload->gpu.dup_dmabuf_fd = dup_fd;
      payload->native_singular_resource_ptr = frame_payload;
      payload->num_planar_resources_to_release =
          0; // Single DMA-BUF FD to release
      ok = true;

      miniav_log(
          MINIAV_LOG_LEVEL_DEBUG,
          "PW: GPU Path - DMA-BUF FD %d, format %s, %u planes, total size %zu",
          dup_fd, miniav_pixel_format_to_string_short(format),
          miniav_buffer->data.video.num_planes, miniav_buffer->data_size_bytes);
    }
  }
  // Handle CPU path (MemFd/MemPtr)
  else if ((d->type == SPA_DATA_MemFd || d->type == SPA_DATA_MemPtr) &&
           d->data && d->chunk && d->chunk->size > 0) {

    void *cpu_ptr = miniav_malloc(d->chunk->size);
    if (cpu_ptr) {
      memcpy(cpu_ptr, d->data, d->chunk->size);

      miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;

      // Set up CPU plane pointers based on format
      if (format == MINIAV_PIXEL_FORMAT_NV12) {
        miniav_buffer->data.video.num_planes = 2;

        // Y plane
        miniav_buffer->data.video.planes[0].data_ptr = cpu_ptr;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes = width;
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;

        // UV plane (interleaved, starts after Y)
        miniav_buffer->data.video.planes[1].data_ptr =
            (uint8_t *)cpu_ptr + (width * height);
        miniav_buffer->data.video.planes[1].width = width / 2;
        miniav_buffer->data.video.planes[1].height = height / 2;
        miniav_buffer->data.video.planes[1].stride_bytes =
            width; // UV stride = Y stride for NV12
        miniav_buffer->data.video.planes[1].offset_bytes = width * height;
        miniav_buffer->data.video.planes[1].subresource_index = 1;

      } else if (format == MINIAV_PIXEL_FORMAT_I420) {
        miniav_buffer->data.video.num_planes = 3;
        uint32_t y_size = width * height;
        uint32_t uv_size = (width / 2) * (height / 2);

        // Y plane
        miniav_buffer->data.video.planes[0].data_ptr = cpu_ptr;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes = width;
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;

        // U plane
        miniav_buffer->data.video.planes[1].data_ptr =
            (uint8_t *)cpu_ptr + y_size;
        miniav_buffer->data.video.planes[1].width = width / 2;
        miniav_buffer->data.video.planes[1].height = height / 2;
        miniav_buffer->data.video.planes[1].stride_bytes = width / 2;
        miniav_buffer->data.video.planes[1].offset_bytes = y_size;
        miniav_buffer->data.video.planes[1].subresource_index = 1;

        // V plane
        miniav_buffer->data.video.planes[2].data_ptr =
            (uint8_t *)cpu_ptr + y_size + uv_size;
        miniav_buffer->data.video.planes[2].width = width / 2;
        miniav_buffer->data.video.planes[2].height = height / 2;
        miniav_buffer->data.video.planes[2].stride_bytes = width / 2;
        miniav_buffer->data.video.planes[2].offset_bytes = y_size + uv_size;
        miniav_buffer->data.video.planes[2].subresource_index = 2;

      } else {
        // Non-planar formats
        miniav_buffer->data.video.num_planes = 1;
        miniav_buffer->data.video.planes[0].data_ptr = cpu_ptr;
        miniav_buffer->data.video.planes[0].width = width;
        miniav_buffer->data.video.planes[0].height = height;
        miniav_buffer->data.video.planes[0].stride_bytes = d->chunk->stride;
        miniav_buffer->data.video.planes[0].offset_bytes = 0;
        miniav_buffer->data.video.planes[0].subresource_index = 0;
      }

      miniav_buffer->data_size_bytes = d->chunk->size;
      frame_payload->type = MINIAV_OUTPUT_PREFERENCE_CPU;
      frame_payload->cpu.cpu_ptr = cpu_ptr;
      frame_payload->cpu.cpu_size = d->chunk->size;
      frame_payload->cpu.src_dmabuf_fd =
          (d->type == SPA_DATA_MemFd) ? d->fd : -1;
      payload->native_singular_resource_ptr = frame_payload;
      payload->num_planar_resources_to_release = 0;
      ok = true;

      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: CPU Path - copied %zu bytes, format %s, %u planes",
                 d->chunk->size, miniav_pixel_format_to_string_short(format),
                 miniav_buffer->data.video.num_planes);
    }
  }

  if (!ok) {
    miniav_free(frame_payload);
    miniav_free(payload);
    miniav_free(miniav_buffer);
    pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
    return;
  }

  miniav_buffer->internal_handle = payload;
  MINIAV_SAFE_DISPATCH(pw_ctx->parent_ctx->app_callback(
      miniav_buffer, pw_ctx->parent_ctx->app_callback_user_data));

  pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
}

static void on_stream_state_changed(void *userdata, enum pw_stream_state old,
                                    enum pw_stream_state state,
                                    const char *error) {
  PipeWirePlatformContext *pw_ctx = (PipeWirePlatformContext *)userdata;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Stream state changed from %s to %s.",
             pw_stream_state_as_string(old), pw_stream_state_as_string(state));

  if (error) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Stream error: %s", error);
    bool was_streaming = pw_ctx->is_streaming;
    pw_ctx->is_streaming = false; // Stop on error
    // Hot-unplug / stream failure: tell the app instead of letting frames
    // silently stop (mirrors the Windows terminal-HRESULT -> lost_cb path).
    // NOTE: fires on the PipeWire loop thread — see the
    // MiniAVContextLostCallback contract (no synchronous Stop/Destroy).
    if (was_streaming && pw_ctx->parent_ctx && pw_ctx->parent_ctx->lost_cb &&
        !atomic_exchange(&pw_ctx->lost_cb_fired, true)) {
      pw_ctx->parent_ctx->lost_cb((int)MINIAV_ERROR_DEVICE_LOST,
                                  pw_ctx->parent_ctx->lost_cb_user_data);
    }
    if (pw_ctx->loop_running && pw_ctx->loop) {
      if (pw_ctx->wakeup_pipe[1] != -1) {
        ssize_t written =
            write(pw_ctx->wakeup_pipe[1], "q", 1); // Wake loop to exit
        if (written == -1 && errno != EAGAIN) {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "PW: Failed to write quit signal: %s", strerror(errno));
        }
      }
    }
    return;
  }

  switch (state) {
  case PW_STREAM_STATE_ERROR:
    // Errored without an error string: still a device/stream loss the app
    // must hear about while it believes capture is running.
    if (pw_ctx->is_streaming && pw_ctx->parent_ctx &&
        pw_ctx->parent_ctx->lost_cb &&
        !atomic_exchange(&pw_ctx->lost_cb_fired, true)) {
      pw_ctx->parent_ctx->lost_cb((int)MINIAV_ERROR_DEVICE_LOST,
                                  pw_ctx->parent_ctx->lost_cb_user_data);
    }
    // fall through to the shared teardown below
  case PW_STREAM_STATE_UNCONNECTED:
    pw_ctx->is_streaming = false;
    if (pw_ctx->loop_running && pw_ctx->loop) {
      if (pw_ctx->wakeup_pipe[1] != -1) {
        ssize_t written = write(pw_ctx->wakeup_pipe[1], "q", 1);
        if (written == -1 && errno != EAGAIN) {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "PW: Failed to write quit signal: %s", strerror(errno));
        }
      }
    }
    break;
  case PW_STREAM_STATE_CONNECTING:
    break;
  case PW_STREAM_STATE_PAUSED: // Should mean ready to receive/negotiate format
    pw_ctx->is_streaming = true; // Or a "ready" flag
    // Negotiate format
    {
      uint8_t buffer[1024];
      struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
      const struct spa_pod *params[1];
      uint32_t spa_format = miniav_pixel_format_to_spa(
          pw_ctx->configured_video_format.pixel_format);

      params[0] = spa_format_video_raw_build(
          &b, SPA_PARAM_EnumFormat,
          &SPA_VIDEO_INFO_RAW_INIT(
                  .format = spa_format,
                  .size = SPA_RECTANGLE(pw_ctx->configured_video_format.width,
                                        pw_ctx->configured_video_format.height),
                  .framerate = SPA_FRACTION(
                      pw_ctx->configured_video_format.frame_rate_numerator,
                      pw_ctx->configured_video_format.frame_rate_denominator)));

      if (pw_stream_update_params(pw_ctx->stream, params, 1) < 0) {
        miniav_log(
            MINIAV_LOG_LEVEL_ERROR,
            "PW: Failed to update stream params for format negotiation.");
      } else {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW: Requested stream format %s, %ux%u @ %u/%u.",
                   spa_debug_type_find_name(spa_type_video_format, spa_format),
                   pw_ctx->configured_video_format.width,
                   pw_ctx->configured_video_format.height,
                   pw_ctx->configured_video_format.frame_rate_numerator,
                   pw_ctx->configured_video_format.frame_rate_denominator);
      }
    }
    break;
  case PW_STREAM_STATE_STREAMING:
    miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Stream is now streaming.");
    pw_ctx->is_streaming = true;
    break;
  default:
    break;
  }
}

static void on_stream_param_changed(void *userdata, uint32_t id,
                                    const struct spa_pod *param) {
  PipeWirePlatformContext *pw_ctx = (PipeWirePlatformContext *)userdata;
  if (!param || id != SPA_PARAM_Format) {
    return;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Stream SPA_PARAM_Format changed.");

  MiniAVVideoInfo current_stream_format = {0};
  parse_spa_format(param, &current_stream_format);

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW: Negotiated stream format: %s, %ux%u @ %u/%u.",
             miniav_pixel_format_to_string_short(
                 current_stream_format
                     .pixel_format), // Assuming you have such a helper
             current_stream_format.width, current_stream_format.height,
             current_stream_format.frame_rate_numerator,
             current_stream_format.frame_rate_denominator);

  // Persist what the device ACTUALLY negotiated so delivered frames and
  // get_configured_video_format() report the real format — frames used to be
  // stamped with the originally requested format even when the device chose
  // a compatible alternative. Written under stop_request.mutex because this
  // runs on the PipeWire loop thread while the app thread may concurrently
  // read the parent field via get_configured_video_format (torn struct read
  // otherwise).
  if (current_stream_format.width != 0 && current_stream_format.height != 0) {
    current_stream_format.output_preference =
        pw_ctx->configured_video_format.output_preference;
    pthread_mutex_lock(&pw_ctx->stop_request.mutex);
    pw_ctx->configured_video_format = current_stream_format;
    if (pw_ctx->parent_ctx) {
      pw_ctx->parent_ctx->configured_video_format = current_stream_format;
    }
    pthread_mutex_unlock(&pw_ctx->stop_request.mutex);
  }

  // After format is set, we can connect the stream if it's not already
  // connecting to streaming
  if (pw_stream_get_state(pw_ctx->stream, NULL) == PW_STREAM_STATE_PAUSED) {
    if (pw_stream_set_active(pw_ctx->stream, true) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Failed to set stream active.");
    }
  }
}

static void on_stop_request_event(void *data, int fd, uint32_t mask) {
  PipeWirePlatformContext *ctx = (PipeWirePlatformContext *)data;
  char buf[1];
  ssize_t len = read(fd, buf, sizeof(buf));

  if (len > 0 && buf[0] == 's') { // 's' for stop
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Processing stop request in loop context.");

    pthread_mutex_lock(&ctx->stop_request.mutex);

    if (ctx->stream) {
      pw_stream_set_active(ctx->stream, false);
      pw_stream_disconnect(ctx->stream);
      spa_hook_remove(&ctx->stream_listener);
      pw_stream_destroy(ctx->stream);
      ctx->stream = NULL;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: Stream destroyed in loop context (stop signal).");
    }

    ctx->stop_request.stop_completed = true;
    pthread_cond_signal(&ctx->stop_request.cond);
    pthread_mutex_unlock(&ctx->stop_request.mutex);

    pw_main_loop_quit(ctx->loop);
  } else if (len > 0 &&
             buf[0] == 'q') { // 'q' for quit, from pw_destroy_platform
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Quit signal received in loop context.");
    // Perform stream cleanup similar to 's' path, if stream exists and loop is
    // active. This ensures stream is cleaned up by the loop thread before loop
    // quits.
    if (ctx->stream) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: Cleaning up stream due to quit signal in loop context.");
      pw_stream_set_active(ctx->stream, false);
      pw_stream_disconnect(ctx->stream);
      spa_hook_remove(&ctx->stream_listener); // Ensure listener is removed
      pw_stream_destroy(ctx->stream);
      ctx->stream = NULL;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: Stream destroyed in loop context (quit signal).");
    }
    pw_main_loop_quit(ctx->loop);
  } else if (len == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
    // This is normal for non-blocking pipes
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Pipe read would block.");
  } else if (len == 0) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Pipe EOF received.");
    pw_main_loop_quit(ctx->loop); // Quit if pipe closes unexpectedly
  } else if (len < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Pipe read error: %s",
               strerror(errno));
    pw_main_loop_quit(ctx->loop); // Quit on error
  }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .param_changed = on_stream_param_changed,
    .process = on_stream_process,
};

// --- Registry Callbacks ---
static void registry_event_global(void *data, uint32_t id, uint32_t permissions,
                                  const char *type, uint32_t version,
                                  const struct spa_dict *props) {
  PipeWireEnumData *enum_data = (PipeWireEnumData *)data;

  if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    const char *node_name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    const char *node_description =
        spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    const char *device_api = spa_dict_lookup(props, PW_KEY_DEVICE_API);

    if (media_class && strstr(media_class, "Video/Source")) {
      // It's a video source, potentially a camera
      if (enum_data->devices_list && enum_data->devices_count &&
          (*enum_data->devices_count < enum_data->allocated_devices)) {
        MiniAVDeviceInfo *dev_info =
            &enum_data
                 ->devices_list[*enum_data->devices_count]; // Corrected line
        memset(dev_info, 0, sizeof(MiniAVDeviceInfo));

        snprintf(dev_info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "%u", id);
        if (node_description) {
          miniav_strlcpy(dev_info->name, node_description,
                         MINIAV_DEVICE_NAME_MAX_LEN);
        } else if (node_name) {
          miniav_strlcpy(dev_info->name, node_name, MINIAV_DEVICE_NAME_MAX_LEN);
        } else {
          snprintf(dev_info->name, MINIAV_DEVICE_NAME_MAX_LEN,
                   "PipeWire Node %u", id);
        }
        dev_info->is_default = false;

        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW: Found Video/Source: ID=%s, Name='%s', MediaClass='%s', "
                   "API='%s'",
                   dev_info->device_id, dev_info->name, media_class,
                   device_api ? device_api : "N/A");

        (*enum_data->devices_count)++;
      }
    }
  }
}

static void registry_event_global_remove(void *data, uint32_t id) {
  // Handle device removal if necessary, e.g., update UI or internal lists.
  // For a one-shot enumeration, this might not be critical.
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_event_global,
    .global_remove = registry_event_global_remove,
};

// --- Core Callbacks for sync ---
static void on_core_sync_done_enum(void *data, uint32_t id,
                                   int seq) { // Added uint32_t id
  PipeWireEnumData *enum_data = (PipeWireEnumData *)data;
  MINIAV_UNUSED(id); // If id is not used
  if (enum_data->pending_sync == seq) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Core sync done for enumeration.");
    pw_main_loop_quit(enum_data->loop);
  }
}
static void on_core_sync_done_format(void *data, uint32_t id,
                                     int seq) { // Added uint32_t id
  PipeWireFormatEnumData *format_data = (PipeWireFormatEnumData *)data;
  MINIAV_UNUSED(id); // If id is not used
  if (format_data->pending_sync == seq) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Core sync done for format enumeration.");
    pw_main_loop_quit(format_data->loop);
  }
}

static const struct pw_core_events core_sync_events = {
    PW_VERSION_CORE_EVENTS,
    .done = on_core_sync_done_enum, // Will be replaced for format enum
};

// --- Platform Ops Implementation ---

static void *pipewire_loop_thread_func(void *arg) {
  PipeWirePlatformContext *pw_ctx = (PipeWirePlatformContext *)arg;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: PipeWire loop thread started.");

  struct pw_loop *loop = pw_main_loop_get_loop(pw_ctx->loop);
  struct spa_source *wakeup_source = NULL;

  // Set loop_running BEFORE adding the source
  pw_ctx->loop_running = true;

  if (pw_ctx->wakeup_pipe[0] != -1) {
    wakeup_source = pw_loop_add_io(loop, pw_ctx->wakeup_pipe[0], SPA_IO_IN,
                                   true, on_stop_request_event, pw_ctx);

    if (!wakeup_source) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW: Failed to add wakeup_pipe IO source to loop.");
      pw_ctx->loop_running = false;
      return NULL;
    }
  }

  pw_main_loop_run(pw_ctx->loop);

  // CRITICAL: Remove the source IMMEDIATELY after loop exits, while we're still
  // in the loop thread context
  if (wakeup_source) {
    pw_loop_remove_source(loop, wakeup_source);
    wakeup_source = NULL;
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Removed wakeup source in loop thread.");
  }

  pw_ctx->loop_running = false;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: PipeWire loop thread ended.");
  return NULL;
}

static MiniAVResultCode pw_init_platform(MiniAVCameraContext *ctx) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Initializing platform context.");
  PipeWirePlatformContext *pw_ctx = (PipeWirePlatformContext *)miniav_calloc(
      1, sizeof(PipeWirePlatformContext));
  if (!pw_ctx) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  ctx->platform_ctx = pw_ctx;
  pw_ctx->parent_ctx = ctx;
  pw_ctx->target_node_id = PW_ID_ANY; // Default
  pw_ctx->wakeup_pipe[0] = -1;
  pw_ctx->wakeup_pipe[1] = -1;

  // Initialize stop request mechanism FIRST
  if (pthread_mutex_init(&pw_ctx->stop_request.mutex, NULL) != 0) {
    miniav_free(pw_ctx);
    ctx->platform_ctx = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if (pthread_cond_init(&pw_ctx->stop_request.cond, NULL) != 0) {
    pthread_mutex_destroy(&pw_ctx->stop_request.mutex);
    miniav_free(pw_ctx);
    ctx->platform_ctx = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  pw_ctx->stop_request.stop_requested = false;
  pw_ctx->stop_request.stop_completed = false;

  // Create pipe
  if (pipe2(pw_ctx->wakeup_pipe, O_CLOEXEC | O_NONBLOCK) == -1) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Failed to create wakeup pipe: %s",
               strerror(errno));
    pthread_cond_destroy(&pw_ctx->stop_request.cond);
    pthread_mutex_destroy(&pw_ctx->stop_request.mutex);
    miniav_free(pw_ctx);
    ctx->platform_ctx = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pw_init(NULL, NULL); // Initialize PipeWire library

  pw_ctx->loop = pw_main_loop_new(NULL);
  if (!pw_ctx->loop) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Failed to create main loop.");
    goto error_cleanup;
  }

  pw_ctx->context =
      pw_context_new(pw_main_loop_get_loop(pw_ctx->loop), NULL, 0);
  if (!pw_ctx->context) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Failed to create context.");
    goto error_cleanup;
  }

  pw_ctx->core = pw_context_connect(pw_ctx->context, NULL, 0);
  if (!pw_ctx->core) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to connect to PipeWire core/daemon.");
    goto error_cleanup;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW: Platform context initialized successfully.");
  return MINIAV_SUCCESS;

error_cleanup:
  if (pw_ctx->core)
    pw_core_disconnect(pw_ctx->core);
  if (pw_ctx->context)
    pw_context_destroy(pw_ctx->context);
  if (pw_ctx->loop)
    pw_main_loop_destroy(pw_ctx->loop);
  if (pw_ctx->wakeup_pipe[0] != -1)
    close(pw_ctx->wakeup_pipe[0]);
  if (pw_ctx->wakeup_pipe[1] != -1)
    close(pw_ctx->wakeup_pipe[1]);
  pthread_cond_destroy(&pw_ctx->stop_request.cond);
  pthread_mutex_destroy(&pw_ctx->stop_request.mutex);
  miniav_free(pw_ctx);
  ctx->platform_ctx = NULL;
  return MINIAV_ERROR_SYSTEM_CALL_FAILED;
}

static MiniAVResultCode pw_destroy_platform(MiniAVCameraContext *ctx) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Destroying platform context.");
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  PipeWirePlatformContext *pw_ctx =
      (PipeWirePlatformContext *)ctx->platform_ctx;

  if (pw_ctx->loop_running && pw_ctx->wakeup_pipe[1] != -1) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Sending quit signal to loop for destruction. Loop thread "
               "will handle stream cleanup.");
    ssize_t written = write(pw_ctx->wakeup_pipe[1], "q", 1);
    if (written == -1 && errno != EAGAIN &&
        errno != EPIPE) { // EPIPE can happen if read end is already closed
      miniav_log(MINIAV_LOG_LEVEL_WARN, "PW: Failed to write quit signal: %s",
                 strerror(errno));
    }
  }

  if (pw_ctx->loop_thread != 0) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Waiting for loop thread to finish...");
    if (miniav_timed_join(pw_ctx->loop_thread, 7000) != 0) {
      // The loop thread still dereferences pw_ctx AND its parent_ctx —
      // deliberately LEAK both rather than free memory a live thread uses.
      // MINIAV_ERROR_TIMEOUT tells MiniAV_Camera_DestroyContext to skip
      // freeing the parent context too.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW: loop thread still alive at destroy — leaking the "
                 "context to avoid a use-after-free.");
      ctx->platform_ctx = NULL;
      return MINIAV_ERROR_TIMEOUT;
    }
    pw_ctx->loop_thread = 0; // Mark thread as joined
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Loop thread finished and joined.");
  }

  if (pw_ctx->stream) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW: Stream object pointer is still non-NULL after loop thread "
               "exit. This indicates a potential leak if the loop thread did "
               "not clean it up as expected.");
    // Fallback cleanup removed:
    spa_hook_remove(&pw_ctx->stream_listener);
    pw_stream_destroy(pw_ctx->stream);
    pw_ctx->stream = NULL;
  }

  // Close pipes (safe to do after thread is joined and its wakeup_source
  // removed)
  if (pw_ctx->wakeup_pipe[0] != -1) {
    close(pw_ctx->wakeup_pipe[0]);
    pw_ctx->wakeup_pipe[0] = -1;
  }
  if (pw_ctx->wakeup_pipe[1] != -1) {
    close(pw_ctx->wakeup_pipe[1]);
    pw_ctx->wakeup_pipe[1] = -1;
  }

  if (pw_ctx->context) {
    pw_context_destroy(pw_ctx->context);
    pw_ctx->context = NULL;
    pw_ctx->core = NULL;
  }
  
  // Clean up threading primitives for stop_request (used by pw_stop_capture)
  pthread_cond_destroy(&pw_ctx->stop_request.cond);
  pthread_mutex_destroy(&pw_ctx->stop_request.mutex);

  miniav_free(pw_ctx);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Platform context destroyed.");
  return MINIAV_SUCCESS;
}
static MiniAVResultCode pw_enumerate_devices(MiniAVDeviceInfo **devices_out,
                                             uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Enumerating devices.");
  if (!devices_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *devices_out = NULL;
  *count_out = 0;

  MiniAVResultCode overall_res = MINIAV_SUCCESS;
  struct pw_main_loop *loop = NULL;
  struct pw_context *context = NULL;
  struct pw_core *core = NULL;
  struct pw_registry *registry = NULL;
  struct spa_hook registry_listener_local;
  struct spa_hook core_listener_local;

  pw_init(NULL,
          NULL); // Ensure library is initialized

  loop = pw_main_loop_new(NULL);
  context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
  core = pw_context_connect(context, NULL, 0);

  if (!loop || !context || !core) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to init PW core for enumeration.");
    overall_res = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto enum_cleanup;
  }

  PipeWireEnumData enum_data = {0};
  enum_data.loop = loop;
  enum_data.devices_list = (MiniAVDeviceInfo *)miniav_calloc(
      PW_MAX_REPORTED_DEVICES, sizeof(MiniAVDeviceInfo));
  if (!enum_data.devices_list) {
    overall_res = MINIAV_ERROR_OUT_OF_MEMORY;
    goto enum_cleanup;
  }
  enum_data.allocated_devices = PW_MAX_REPORTED_DEVICES;
  enum_data.devices_count = count_out; // Point to the output param
  *enum_data.devices_count = 0;        // Initialize count
  enum_data.result = MINIAV_SUCCESS;

  registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
  pw_registry_add_listener(registry, &registry_listener_local, &registry_events,
                           &enum_data);

  // Setup sync mechanism
  struct pw_core_events local_core_events = core_sync_events; // Copy base
  local_core_events.done = on_core_sync_done_enum; // Set specific done callback
  pw_core_add_listener(core, &core_listener_local, &local_core_events,
                       &enum_data);
  enum_data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);

  pw_main_loop_run(loop); // This will run until pw_main_loop_quit is called
                          // in on_core_sync_done_enum

  if (enum_data.result == MINIAV_SUCCESS) {
    if (*count_out > 0) {
      *devices_out = enum_data.devices_list;
      MiniAVDeviceInfo *final_list =
          miniav_realloc(*devices_out, (*count_out) * sizeof(MiniAVDeviceInfo));
      if (final_list)
        *devices_out = final_list;
      // else keep original larger allocation
    } else {
      miniav_free(enum_data.devices_list); // No devices found
      *devices_out = NULL;
    }
  } else {
    miniav_free(enum_data.devices_list);
    *devices_out = NULL;
    *count_out = 0;
    overall_res = enum_data.result;
  }

enum_cleanup:
  if (registry)
    pw_proxy_destroy((struct pw_proxy *)registry);
  if (core) {
    spa_hook_remove(&core_listener_local); // Remove before disconnect if added
    pw_core_disconnect(core);
  }
  if (context)
    pw_context_destroy(context);
  if (loop)
    pw_main_loop_destroy(loop);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Enumerated %u devices.", *count_out);
  return overall_res;
}

static void parse_spa_format_choices(const struct spa_pod *format_pod,
                                     PipeWireFormatEnumData *format_data) {
  MiniAVVideoInfo info = {0};
  parse_spa_format(format_pod, &info);

  if (info.pixel_format != MINIAV_PIXEL_FORMAT_UNKNOWN) {
    if (info.width == 0 || info.height == 0) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW: Fallback format %s resulted in 0 width/height. Skipping.",
                 miniav_pixel_format_to_string_short(info.pixel_format));
    } else if (*format_data->formats_count < format_data->allocated_formats) {
      format_data->formats_list[*format_data->formats_count] = info;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Added format: %s, %ux%u @ %u/%u",
                 miniav_pixel_format_to_string_short(info.pixel_format),
                 info.width, info.height, info.frame_rate_numerator,
                 info.frame_rate_denominator);
      (*format_data->formats_count)++;
    } else {
      miniav_log(
          MINIAV_LOG_LEVEL_WARN,
          "PW: Reached allocated format limit (%u) with fallback parser.",
          format_data->allocated_formats);
    }
  }
}

static void on_node_param(void *data, int seq, uint32_t id, uint32_t index,
                          uint32_t next, const struct spa_pod *param) {
  PipeWireFormatEnumData *format_data = (PipeWireFormatEnumData *)data;
  const char *id_name = spa_debug_type_find_name(spa_type_param, id);
  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "PW: on_node_param: seq=%d, id=%s (%u), index=%u, next=%u, param_ptr=%p",
      seq, id_name ? id_name : "UNKNOWN_ID", id, index, next, (void *)param);

  if (param && id == SPA_PARAM_EnumFormat) {
    // Accumulate — PipeWire delivers ONE param event per supported mode, so
    // quitting the loop here (as this used to) truncated the device's real
    // format list to a single entry. The loop is quit by the core sync-done
    // event issued after enum_params (see on_node_info /
    // on_core_sync_done_format).
    parse_spa_format_choices(param, format_data);
  }
}

static void on_node_info(void *data, const struct pw_node_info *info) {
  PipeWireFormatEnumData *format_data = (PipeWireFormatEnumData *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW: Received node info for format enumeration (node %u).",
             format_data->node_id);

  if (info) {
    pw_node_enum_params(format_data->node_proxy, 1, SPA_PARAM_EnumFormat, 0,
                        UINT32_MAX, NULL);
    // Sync AFTER enum_params: the server processes the sync only once every
    // pending param event has been delivered, so on_core_sync_done_format
    // quits the loop exactly when the full format list has arrived.
    format_data->pending_sync =
        pw_core_sync(format_data->core, PW_ID_CORE, 0);
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW: on_node_info called with NULL info.");
    format_data->result = MINIAV_ERROR_DEVICE_NOT_FOUND;
    if (format_data->loop) {
      pw_main_loop_quit(format_data->loop);
    }
  }
}

static const struct pw_node_events node_info_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_node_info,
    .param = on_node_param,
};

// Core events for the format-enumeration loop: quit on the sync issued after
// enum_params (i.e. after ALL param events have been delivered).
static const struct pw_core_events core_sync_events_format = {
    PW_VERSION_CORE_EVENTS,
    .done = on_core_sync_done_format,
};

static MiniAVResultCode pw_get_supported_formats(const char *device_id_str,
                                                 MiniAVVideoInfo **formats_out,
                                                 uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW: Getting supported formats for device ID %s.", device_id_str);
  if (!device_id_str || !formats_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *formats_out = NULL;
  *count_out = 0;

  uint32_t node_id = (uint32_t)atoi(device_id_str);
  if (node_id == 0 &&
      strcmp(device_id_str, "0") != 0) { // Basic check for valid uint
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Invalid device_id string for format enumeration: %s",
               device_id_str);
    return MINIAV_ERROR_INVALID_ARG;
  }

  MiniAVResultCode overall_res = MINIAV_SUCCESS;
  struct pw_main_loop *loop = NULL;
  struct pw_context *context = NULL;
  struct pw_core *core = NULL;
  struct pw_node *node_proxy = NULL;
  struct spa_hook node_listener_local;

  pw_init(NULL, NULL);

  loop = pw_main_loop_new(NULL);
  context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
  core = pw_context_connect(context, NULL, 0);

  if (!loop || !context || !core) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to init PW core for format enumeration.");
    overall_res = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto format_enum_cleanup;
  }

  PipeWireFormatEnumData format_data = {0};
  format_data.loop = loop;
  format_data.formats_list = (MiniAVVideoInfo *)miniav_calloc(
      PW_MAX_REPORTED_FORMATS, sizeof(MiniAVVideoInfo));
  if (!format_data.formats_list) {
    overall_res = MINIAV_ERROR_OUT_OF_MEMORY;
    goto format_enum_cleanup;
  }
  format_data.allocated_formats = PW_MAX_REPORTED_FORMATS;
  format_data.formats_count = count_out;
  *format_data.formats_count = 0;
  format_data.result = MINIAV_SUCCESS; // Default to success
  format_data.node_id = node_id;
  format_data.core = core;

  // Bind to the node to get its info
  node_proxy = (struct pw_node *)pw_registry_bind(
      pw_core_get_registry(core, PW_VERSION_REGISTRY, 0), node_id,
      PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
  format_data.node_proxy = node_proxy;
  if (!node_proxy) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to bind to node %u for format enumeration.",
               node_id);
    overall_res = MINIAV_ERROR_DEVICE_NOT_FOUND; // Or system call failed
    miniav_free(format_data.formats_list);       // Free the list we allocated
    format_data.formats_list = NULL;
    goto format_enum_cleanup;
  }
  pw_node_add_listener(node_proxy, &node_listener_local, &node_info_events,
                       &format_data);
  struct spa_hook core_listener_local;
  spa_zero(core_listener_local);
  pw_core_add_listener(core, &core_listener_local, &core_sync_events_format,
                       &format_data);

  // Initial sync so the loop ALWAYS terminates: if the bound id never emits
  // node info (wrong object type, dead node), this sync's done event quits
  // the loop with zero formats instead of blocking the caller forever. When
  // node info DOES arrive first, on_node_info overwrites pending_sync with
  // the post-enum_params sync, so this initial done no longer matches and
  // the loop keeps running until the format list is complete.
  format_data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW: Running loop for node info (node %u).", node_id);
  pw_main_loop_run(loop);
  spa_hook_remove(&core_listener_local);

  if (format_data.result == MINIAV_SUCCESS) {
    if (*count_out > 0) {
      *formats_out = format_data.formats_list;
      MiniAVVideoInfo *final_list =
          miniav_realloc(*formats_out, (*count_out) * sizeof(MiniAVVideoInfo));
      if (final_list)
        *formats_out = final_list;
    } else {
      miniav_free(format_data.formats_list);
      *formats_out = NULL;
    }
  } else {
    miniav_free(format_data.formats_list);
    *formats_out = NULL;
    *count_out = 0;
    overall_res = format_data.result;
  }

format_enum_cleanup:
  if (node_proxy) {
    spa_hook_remove(&node_listener_local);
    pw_proxy_destroy((struct pw_proxy *)node_proxy);
  }
  if (core)
    pw_core_disconnect(core);
  if (context)
    pw_context_destroy(context);
  if (loop)
    pw_main_loop_destroy(loop);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Found %u formats for device %s.",
             *count_out, device_id_str);
  return overall_res;
}

static MiniAVResultCode pw_get_default_format(const char *device_id,
                                              MiniAVVideoInfo *format_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PipeWire: Getting default format for device %s", device_id);

  if (!device_id || !format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(format_out, 0, sizeof(MiniAVVideoInfo));

  // Get supported formats and pick a reasonable default
  MiniAVVideoInfo *formats = NULL;
  uint32_t count = 0;
  MiniAVResultCode res = pw_get_supported_formats(device_id, &formats, &count);

  if (res != MINIAV_SUCCESS || count == 0) {
    // Fallback to common format
    format_out->width = 640;
    format_out->height = 480;
    format_out->frame_rate_numerator = 30;
    format_out->frame_rate_denominator = 1;
    format_out->pixel_format = MINIAV_PIXEL_FORMAT_YUY2;
    format_out->output_preference = MINIAV_OUTPUT_PREFERENCE_CPU;
    return MINIAV_SUCCESS;
  }

  // Same selection logic
  MiniAVVideoInfo *selected = &formats[0];

  for (uint32_t i = 0; i < count; i++) {
    if (formats[i].width == 1280 && formats[i].height == 720 &&
        formats[i].frame_rate_numerator == 30 &&
        formats[i].frame_rate_denominator == 1) {
      selected = &formats[i];
      break;
    }
    if (formats[i].width == 1920 && formats[i].height == 1080 &&
        formats[i].frame_rate_numerator == 30 &&
        formats[i].frame_rate_denominator == 1) {
      selected = &formats[i];
      break;
    }
    if (formats[i].frame_rate_numerator == 30 &&
        formats[i].frame_rate_denominator == 1) {
      selected = &formats[i];
    }
  }

  *format_out = *selected;
  miniav_free(formats);

  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_get_configured_video_format(MiniAVCameraContext *ctx,
                               MiniAVVideoInfo *format_out) {
  if (!ctx || !format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  // Read under the same mutex the loop thread's negotiated-format write-back
  // takes (on_stream_param_changed) so the multi-field struct copy can't be
  // torn mid-update.
  PipeWirePlatformContext *pw_ctx =
      (PipeWirePlatformContext *)ctx->platform_ctx;
  if (pw_ctx) {
    pthread_mutex_lock(&pw_ctx->stop_request.mutex);
  }
  MiniAVVideoInfo snapshot = ctx->configured_video_format;
  if (pw_ctx) {
    pthread_mutex_unlock(&pw_ctx->stop_request.mutex);
  }

  if (snapshot.width == 0 || snapshot.height == 0) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  *format_out = snapshot;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode pw_configure(MiniAVCameraContext *ctx,
                                     const char *device_id_str,
                                     const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !device_id_str || !format)
    return MINIAV_ERROR_INVALID_ARG;
  PipeWirePlatformContext *pw_ctx =
      (PipeWirePlatformContext *)ctx->platform_ctx;

  if (pw_ctx->is_streaming) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Cannot configure while streaming.");
    return MINIAV_ERROR_INVALID_OPERATION;
  }

  uint32_t node_id = (uint32_t)atoi(device_id_str);
  if (node_id == 0 && strcmp(device_id_str, "0") != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Invalid device_id string for configure: %s", device_id_str);
    return MINIAV_ERROR_INVALID_ARG;
  }

  pw_ctx->target_node_id = node_id;
  pw_ctx->configured_video_format = *format; // Store a copy
  pw_ctx->is_configured = true;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW: Configured for device ID %u, Format: %s %ux%u @ %u/%u.",
             pw_ctx->target_node_id,
             miniav_pixel_format_to_string_short(format->pixel_format),
             format->width, format->height, format->frame_rate_numerator,
             format->frame_rate_denominator);

  return MINIAV_SUCCESS;
}

static MiniAVResultCode pw_start_capture(MiniAVCameraContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  PipeWirePlatformContext *pw_ctx =
      (PipeWirePlatformContext *)ctx->platform_ctx;

  if (!pw_ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Context not configured before start_capture.");
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  if (pw_ctx->is_streaming || pw_ctx->loop_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW: Already streaming or loop running.");
    return MINIAV_ERROR_INVALID_OPERATION;
  }

  // Fresh timestamp calibration + lost-notification guard per capture run.
  memset(&pw_ctx->timebase, 0, sizeof(pw_ctx->timebase));
  atomic_store(&pw_ctx->lost_cb_fired, false);

  pw_ctx->stream = pw_stream_new(
      pw_ctx->core, "miniav-camera-capture",
      pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY,
                        "Capture", PW_KEY_MEDIA_ROLE, "Camera", NULL));
  if (!pw_ctx->stream) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW: Failed to create stream.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pw_stream_add_listener(pw_ctx->stream, &pw_ctx->stream_listener,
                         &stream_events, pw_ctx);

  // In pw_start_capture or stream setup
  MiniAVOutputPreference pref =
      pw_ctx->configured_video_format.output_preference;
  uint32_t buffer_types = 0;
  switch (pref) {
  case MINIAV_OUTPUT_PREFERENCE_GPU:
    buffer_types = (1 << SPA_DATA_DmaBuf);
    break;
  case MINIAV_OUTPUT_PREFERENCE_CPU:
    buffer_types = (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr);
    break;
  default:
    buffer_types =
        (1 << SPA_DATA_DmaBuf) | (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr);
    break;
  }

  uint8_t params_buffer[1024];
  struct spa_pod_builder b =
      SPA_POD_BUILDER_INIT(params_buffer, sizeof(params_buffer));
  const struct spa_pod *params[2];
  uint32_t n_params = 0;

  // Buffers param
  params[n_params++] = spa_pod_builder_add_object(
      &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
      SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 1, 32),
      SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1), SPA_PARAM_BUFFERS_dataType,
      SPA_POD_CHOICE_FLAGS_Int(buffer_types));

  // Format param (allow any modifier)
  params[n_params++] = spa_pod_builder_add_object(
      &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType,
      SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
      SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
      SPA_POD_Id(miniav_pixel_format_to_spa(
          pw_ctx->configured_video_format.pixel_format)),
      SPA_FORMAT_VIDEO_modifier, SPA_POD_CHOICE_FLAGS_Long(0),
      SPA_FORMAT_VIDEO_size,
      SPA_POD_Rectangle(&SPA_RECTANGLE(pw_ctx->configured_video_format.width,
                                       pw_ctx->configured_video_format.height)),
      SPA_FORMAT_VIDEO_framerate,
      SPA_POD_Fraction(&SPA_FRACTION(
          pw_ctx->configured_video_format.frame_rate_numerator,
          pw_ctx->configured_video_format.frame_rate_denominator)),
      0);

  // Connect stream
  if (pw_stream_connect(
          pw_ctx->stream, PW_DIRECTION_INPUT, pw_ctx->target_node_id,
          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params,
          n_params) < 0) { // No specific params to pass at connect time
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to connect stream to node %u.",
               pw_ctx->target_node_id);
    pw_stream_destroy(pw_ctx->stream);
    pw_ctx->stream = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Start the loop thread
  if (pthread_create(&pw_ctx->loop_thread, NULL, pipewire_loop_thread_func,
                     pw_ctx) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW: Failed to create PipeWire loop thread.");
    pw_stream_destroy(pw_ctx->stream); // Clean up stream
    pw_ctx->stream = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW: Capture started (stream connecting, loop thread running).");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode pw_stop_capture(MiniAVCameraContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  PipeWirePlatformContext *pw_ctx =
      (PipeWirePlatformContext *)ctx->platform_ctx;

  if (!pw_ctx->loop_running && !pw_ctx->is_streaming) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW: Capture not running or loop already stopped.");
    return MINIAV_SUCCESS;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Stopping capture.");
  pw_ctx->is_streaming = false;

  if (pw_ctx->loop_running && pw_ctx->loop_thread) {
    pthread_mutex_lock(&pw_ctx->stop_request.mutex);

    // Only proceed if stop hasn't been requested yet
    if (!pw_ctx->stop_request.stop_requested) {
      // Request stop from loop thread
      pw_ctx->stop_request.stop_requested = true;
      pw_ctx->stop_request.stop_completed = false;

      // Signal the loop thread to process stop request
      if (pw_ctx->wakeup_pipe[1] != -1) {
        ssize_t written = write(pw_ctx->wakeup_pipe[1], "s", 1);
        if (written == -1 && errno != EAGAIN) {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "PW: Failed to write stop signal to wakeup pipe: %s",
                     strerror(errno));
        }
      }

      // Wait for stop to complete with timeout
      struct timespec timeout;
      clock_gettime(CLOCK_REALTIME, &timeout);
      timeout.tv_sec += 5; // 5 second timeout

      while (!pw_ctx->stop_request.stop_completed) {
        int ret = pthread_cond_timedwait(&pw_ctx->stop_request.cond,
                                         &pw_ctx->stop_request.mutex, &timeout);
        if (ret == ETIMEDOUT) {
          miniav_log(MINIAV_LOG_LEVEL_WARN, "PW: Stop request timed out.");
          break;
        }
      }
    }

    pthread_mutex_unlock(&pw_ctx->stop_request.mutex);

    // Join the thread
    if (pw_ctx->loop_running || pw_ctx->loop_thread != 0) {
      if (pthread_equal(pw_ctx->loop_thread, pthread_self())) {
        // Called from the loop thread itself (e.g. an app violating the
        // lost_cb contract by stopping synchronously from the callback):
        // joining would self-deadlock. Bail and leave the join to a later
        // call from another thread.
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW: StopCapture called from the loop thread — skipping "
                   "self-join (see MiniAVContextLostCallback docs).");
        return MINIAV_ERROR_INVALID_OPERATION;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Joining PipeWire loop thread.");
      if (miniav_timed_join(pw_ctx->loop_thread, 5000) != 0) {
        // The cond-timedwait above already expired once; an unconditional
        // join here used to defeat that timeout entirely and hang
        // StopCapture forever on a wedged PipeWire call.
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW: loop thread did not exit within 5s — deferring (a "
                   "later Stop/Destroy will retry the join).");
        return MINIAV_ERROR_TIMEOUT; // loop_thread left set for retry
      }
      pw_ctx->loop_thread = 0;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: PipeWire loop thread joined.");
    }

    // Reset stop request state for next time
    pthread_mutex_lock(&pw_ctx->stop_request.mutex);
    pw_ctx->stop_request.stop_requested = false;
    pw_ctx->stop_request.stop_completed = false;
    pthread_mutex_unlock(&pw_ctx->stop_request.mutex);
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW: Capture stopped.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode pw_release_buffer(MiniAVCameraContext *ctx,
                                          void *internal_handle_ptr) {
  MINIAV_UNUSED(ctx);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Camera: release_buffer called with internal_handle_ptr=%p",
             internal_handle_ptr);

  if (!internal_handle_ptr) {
    miniav_log(
        MINIAV_LOG_LEVEL_DEBUG,
        "PW Camera: release_buffer called with NULL internal_handle_ptr.");
    return MINIAV_SUCCESS;
  }

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Camera: payload ptr=%p, handle_type=%d, "
             "native_singular_resource_ptr=%p, num_planar_resources=%u",
             payload, payload->handle_type,
             payload->native_singular_resource_ptr,
             payload->num_planar_resources_to_release);

  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA) {

    // Handle multi-plane resources first (rarely used for PipeWire, but
    // supported)
    if (payload->num_planar_resources_to_release > 0) {
      for (uint32_t i = 0; i < payload->num_planar_resources_to_release; ++i) {
        if (payload->native_planar_resource_ptrs[i]) {
          // For PipeWire, this would typically be additional DMA-BUF FDs
          int fd = (int)(intptr_t)payload->native_planar_resource_ptrs[i];
          if (fd > 0) {
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Camera: Closing planar DMA-BUF FD: %d", fd);
            close(fd);
          }
          payload->native_planar_resource_ptrs[i] = NULL;
        }
      }
    }

    // Handle single resource (typical case)
    if (payload->native_singular_resource_ptr) {
      PipeWireFrameReleasePayload *frame_payload =
          (PipeWireFrameReleasePayload *)payload->native_singular_resource_ptr;

      if (frame_payload) {
        if (frame_payload->type == MINIAV_OUTPUT_PREFERENCE_CPU) {
          if (frame_payload->cpu.cpu_ptr) {
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Camera: Freeing CPU buffer from DMABUF/MemFd copy.");
            miniav_free(frame_payload->cpu.cpu_ptr);
            frame_payload->cpu.cpu_ptr = NULL;
          }
          // src_dmabuf_fd is not owned, do not close
        } else if (frame_payload->type == MINIAV_OUTPUT_PREFERENCE_GPU) {
          if (frame_payload->gpu.dup_dmabuf_fd > 0) {
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Camera: Closing duplicated DMABUF FD: %d",
                       frame_payload->gpu.dup_dmabuf_fd);
            if (close(frame_payload->gpu.dup_dmabuf_fd) == -1) {
              miniav_log(MINIAV_LOG_LEVEL_WARN,
                         "PW Camera: Failed to close DMABUF FD %d: %s",
                         frame_payload->gpu.dup_dmabuf_fd, strerror(errno));
            }
            frame_payload->gpu.dup_dmabuf_fd = -1;
          }
        } else {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "PW Camera: release_buffer: Unknown frame_payload type %d",
                     frame_payload->type);
        }
        miniav_free(frame_payload);
        payload->native_singular_resource_ptr = NULL;
      }
    }

    // Clean up parent buffer
    if (payload->parent_miniav_buffer_ptr) {
      miniav_free(payload->parent_miniav_buffer_ptr);
      payload->parent_miniav_buffer_ptr = NULL;
    }

    miniav_free(payload);
    return MINIAV_SUCCESS;
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Camera: release_buffer called for unknown handle_type %d.",
               payload->handle_type);
    miniav_free(payload);
    return MINIAV_SUCCESS;
  }
}

// --- Global Ops Struct ---
const CameraContextInternalOps g_camera_ops_pipewire = {
    .init_platform = pw_init_platform,
    .destroy_platform = pw_destroy_platform,
    .enumerate_devices = pw_enumerate_devices,
    .get_supported_formats = pw_get_supported_formats,
    .get_default_format = pw_get_default_format,
    .configure = pw_configure,
    .start_capture = pw_start_capture,
    .stop_capture = pw_stop_capture,
    .release_buffer = pw_release_buffer,
    .get_configured_video_format = pw_get_configured_video_format};

MiniAVResultCode
miniav_camera_context_platform_init_linux_pipewire(MiniAVCameraContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  ctx->ops = &g_camera_ops_pipewire;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW: Assigned Linux PipeWire camera ops.");
  return MINIAV_SUCCESS;
}