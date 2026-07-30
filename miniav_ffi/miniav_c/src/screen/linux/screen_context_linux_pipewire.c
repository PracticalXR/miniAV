#define _GNU_SOURCE
#include "screen_context_linux_pipewire.h"

#ifdef __linux__ // Guard for Linux-specific code

#include "../../../include/miniav_buffer.h" // For MiniAVBuffer
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"  // For miniav_get_time_us
#include "../../common/miniav_utils.h" // For miniav_calloc, miniav_free, etc.

#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h> // For SPA_META_Header
#include <spa/debug/types.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/format-utils.h> // For spa_format_parse
#include <spa/param/props.h>        // For SPA_PROP_ требуют and SPA_PROPS_flags
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h> // For spa_type_video_format
#include <spa/pod/builder.h>
#include <spa/utils/defs.h>   // For SPA_FRACTION_INIT
#include <spa/utils/result.h> // For spa_strerror

#include <ctype.h>          // For isspace
#include <dirent.h>         // For opendir, readdir
#include <drm/drm_fourcc.h> // For formats
#include <errno.h>
#include <fcntl.h>         // For O_CLOEXEC, F_DUPFD_CLOEXEC
#include <gio/gio.h>       // For D-Bus (GDBus)
#include <glib.h>          // For GVariant, GError, etc.
#include <inttypes.h>      // For PRIu64
#include <linux/dma-buf.h> // For DMA_BUF_IOCTL_SYNC and struct dma_buf_sync
#include <pthread.h>
#include <string.h>    // For memset, strcmp
#include <sys/ioctl.h> // For ioctl
#include <sys/mman.h>  // For shm, if using DMABUF or similar
#include <unistd.h>    // For pipe, read, write, close, getpid

// Portal D-Bus definitions
#define XDP_BUS_NAME "org.freedesktop.portal.Desktop"
#define XDP_OBJECT_PATH "/org/freedesktop/portal/desktop"
#define XDP_IFACE_SCREENCAST "org.freedesktop.portal.ScreenCast"
#define XDP_IFACE_REQUEST "org.freedesktop.portal.Request"
#define XDP_IFACE_SESSION "org.freedesktop.portal.Session"

static GMainLoop *gloop = NULL;
static pthread_t gloop_thread;

static void *glib_main_loop_thread(void *arg) {
  g_main_loop_run(gloop);
  return NULL;
}

typedef struct PipeWireFrameReleasePayload {
  MiniAVOutputPreference type;
  union {
    struct {             // For CPU
      void *cpu_ptr;     // Allocated CPU buffer (copied from DMABUF)
      size_t cpu_size;   // Size of the buffer
      int src_dmabuf_fd; // Original DMABUF fd (for debugging, not owned)
    } cpu;
    struct {             // For GPU
      int dup_dmabuf_fd; // Duplicated DMABUF fd (must be closed)
    } gpu;
  };
} PipeWireFrameReleasePayload;

// --- Helper to convert formats (Simplified) ---
static enum spa_video_format
miniav_video_format_to_spa(MiniAVPixelFormat pixel_fmt) {
  switch (pixel_fmt) {
  case MINIAV_PIXEL_FORMAT_BGRA32:
    return SPA_VIDEO_FORMAT_BGRA;
  case MINIAV_PIXEL_FORMAT_RGBA32:
    return SPA_VIDEO_FORMAT_RGBA;
  case MINIAV_PIXEL_FORMAT_I420:
    return SPA_VIDEO_FORMAT_I420;
  case MINIAV_PIXEL_FORMAT_BGRX32:
    return SPA_VIDEO_FORMAT_BGRx;
  default:
    return SPA_VIDEO_FORMAT_UNKNOWN;
  }
}

static MiniAVPixelFormat
spa_video_format_to_miniav(enum spa_video_format spa_fmt) {
  switch (spa_fmt) {
  case SPA_VIDEO_FORMAT_BGRA:
    return MINIAV_PIXEL_FORMAT_BGRA32;
  case SPA_VIDEO_FORMAT_RGBA:
    return MINIAV_PIXEL_FORMAT_RGBA32;
  case SPA_VIDEO_FORMAT_I420:
    return MINIAV_PIXEL_FORMAT_I420;
  case SPA_VIDEO_FORMAT_BGRx:
    return MINIAV_PIXEL_FORMAT_BGRX32;
  // Add more mappings
  default:
    return MINIAV_PIXEL_FORMAT_UNKNOWN;
  }
}

static enum spa_audio_format
miniav_audio_format_to_spa_audio(MiniAVAudioFormat fmt) {
  switch (fmt) {
  case MINIAV_AUDIO_FORMAT_S16:
    return SPA_AUDIO_FORMAT_S16_LE; // Assuming Little Endian
  case MINIAV_AUDIO_FORMAT_S32:
    return SPA_AUDIO_FORMAT_S32_LE;
  case MINIAV_AUDIO_FORMAT_F32:
    return SPA_AUDIO_FORMAT_F32_LE;
  default:
    return SPA_AUDIO_FORMAT_UNKNOWN;
  }
}

static MiniAVAudioFormat
spa_audio_format_to_miniav_audio(enum spa_audio_format spa_fmt) {
  switch (spa_fmt) {
  case SPA_AUDIO_FORMAT_S16_LE:
  case SPA_AUDIO_FORMAT_S16_BE: // Consider endianness if needed
    return MINIAV_AUDIO_FORMAT_S16;
  case SPA_AUDIO_FORMAT_S32_LE:
  case SPA_AUDIO_FORMAT_S32_BE:
    return MINIAV_AUDIO_FORMAT_S32;
  case SPA_AUDIO_FORMAT_F32_LE:
  case SPA_AUDIO_FORMAT_F32_BE:
    return MINIAV_AUDIO_FORMAT_F32;
  // Add more mappings
  default:
    return MINIAV_AUDIO_FORMAT_UNKNOWN;
  }
}

static uint32_t get_miniav_pixel_format_planes(MiniAVPixelFormat pixel_fmt) {
  switch (pixel_fmt) {
  case MINIAV_PIXEL_FORMAT_I420:
    // case MINIAV_PIXEL_FORMAT_YV12: // If you support it
    return 3;
  case MINIAV_PIXEL_FORMAT_NV12:
  case MINIAV_PIXEL_FORMAT_NV21:
    return 2;
  case MINIAV_PIXEL_FORMAT_YUY2:
  case MINIAV_PIXEL_FORMAT_UYVY:
  case MINIAV_PIXEL_FORMAT_RGB24:
  case MINIAV_PIXEL_FORMAT_BGR24:
  case MINIAV_PIXEL_FORMAT_RGBA32:
  case MINIAV_PIXEL_FORMAT_BGRA32:
  case MINIAV_PIXEL_FORMAT_ARGB32:
  case MINIAV_PIXEL_FORMAT_ABGR32:
  case MINIAV_PIXEL_FORMAT_MJPEG:
  case MINIAV_PIXEL_FORMAT_BGRX32:
    return 1;
  case MINIAV_PIXEL_FORMAT_UNKNOWN:
  default:
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Unknown pixel format %d, assuming 0 planes.",
               pixel_fmt);
    return 0;
  }
}

static const char *screen_pixel_format_to_string(MiniAVPixelFormat format) {
  switch (format) {
  case MINIAV_PIXEL_FORMAT_UNKNOWN:
    return "UNKNOWN";
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
  case MINIAV_PIXEL_FORMAT_BGRX32:
    return "BGRX32";
  case MINIAV_PIXEL_FORMAT_MJPEG:
    return "MJPEG";
  default:
    return "InvalidFormat";
  }
}

static void setup_cpu_planes_for_format(MiniAVBuffer *buffer,
                                        MiniAVPixelFormat format,
                                        uint32_t width, uint32_t height,
                                        void *base_ptr, size_t total_size) {
  switch (format) {
  case MINIAV_PIXEL_FORMAT_BGRA32:
  case MINIAV_PIXEL_FORMAT_RGBA32:
  case MINIAV_PIXEL_FORMAT_ARGB32:
  case MINIAV_PIXEL_FORMAT_ABGR32:
  case MINIAV_PIXEL_FORMAT_BGRX32: {
    // Single-plane RGB formats
    buffer->data.video.num_planes = 1;
    buffer->data.video.planes[0].data_ptr = base_ptr;
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 4; // 4 bytes per pixel
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    break;
  }

  case MINIAV_PIXEL_FORMAT_RGB24:
  case MINIAV_PIXEL_FORMAT_BGR24: {
    // Single-plane RGB formats
    buffer->data.video.num_planes = 1;
    buffer->data.video.planes[0].data_ptr = base_ptr;
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 3; // 3 bytes per pixel
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    break;
  }

  case MINIAV_PIXEL_FORMAT_I420: {
    // Three-plane YUV format
    buffer->data.video.num_planes = 3;
    uint32_t y_size = width * height;
    uint32_t uv_size = (width / 2) * (height / 2);

    // Y plane
    buffer->data.video.planes[0].data_ptr = base_ptr;
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;

    // U plane
    buffer->data.video.planes[1].data_ptr = (uint8_t *)base_ptr + y_size;
    buffer->data.video.planes[1].width = width / 2;
    buffer->data.video.planes[1].height = height / 2;
    buffer->data.video.planes[1].stride_bytes = width / 2;
    buffer->data.video.planes[1].offset_bytes = y_size;
    buffer->data.video.planes[1].subresource_index = 1;

    // V plane
    buffer->data.video.planes[2].data_ptr =
        (uint8_t *)base_ptr + y_size + uv_size;
    buffer->data.video.planes[2].width = width / 2;
    buffer->data.video.planes[2].height = height / 2;
    buffer->data.video.planes[2].stride_bytes = width / 2;
    buffer->data.video.planes[2].offset_bytes = y_size + uv_size;
    buffer->data.video.planes[2].subresource_index = 2;
    break;
  }

  case MINIAV_PIXEL_FORMAT_NV12: {
    // Two-plane YUV format
    buffer->data.video.num_planes = 2;
    uint32_t y_size = width * height;

    // Y plane
    buffer->data.video.planes[0].data_ptr = base_ptr;
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;

    // UV plane (interleaved)
    buffer->data.video.planes[1].data_ptr = (uint8_t *)base_ptr + y_size;
    buffer->data.video.planes[1].width = width / 2;
    buffer->data.video.planes[1].height = height / 2;
    buffer->data.video.planes[1].stride_bytes = width; // UV stride = Y stride
    buffer->data.video.planes[1].offset_bytes = y_size;
    buffer->data.video.planes[1].subresource_index = 1;
    break;
  }

  default: {
    // Unknown format - assume single plane
    buffer->data.video.num_planes = 1;
    buffer->data.video.planes[0].data_ptr = base_ptr;
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 4; // Assume 4 bytes
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Unknown pixel format %d, assuming single plane",
               format);
    break;
  }
  }
}

static void setup_gpu_planes_for_format(MiniAVBuffer *buffer,
                                        MiniAVPixelFormat format,
                                        uint32_t width, uint32_t height,
                                        int dmabuf_fd, size_t total_size) {
// Helper: set both legacy data_ptr cast and new typed dmabuf_fd field
#define PW_SET_PLANE_DMABUF(buf, idx, fd) \
  do { \
    (buf)->data.video.planes[(idx)].data_ptr = (void *)(intptr_t)(fd); \
    (buf)->data.video.planes[(idx)].dmabuf_fd = (fd); \
    (buf)->data.video.planes[(idx)].drm_format_modifier = 0; /* DRM_FORMAT_MOD_LINEAR */ \
  } while (0)

  switch (format) {
  case MINIAV_PIXEL_FORMAT_BGRA32:
  case MINIAV_PIXEL_FORMAT_RGBA32:
  case MINIAV_PIXEL_FORMAT_ARGB32:
  case MINIAV_PIXEL_FORMAT_ABGR32:
  case MINIAV_PIXEL_FORMAT_BGRX32: {
    buffer->data.video.num_planes = 1;
    PW_SET_PLANE_DMABUF(buffer, 0, dmabuf_fd);
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 4;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    break;
  }

  case MINIAV_PIXEL_FORMAT_RGB24:
  case MINIAV_PIXEL_FORMAT_BGR24: {
    buffer->data.video.num_planes = 1;
    PW_SET_PLANE_DMABUF(buffer, 0, dmabuf_fd);
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 3;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    break;
  }

  case MINIAV_PIXEL_FORMAT_I420: {
    buffer->data.video.num_planes = 3;
    uint32_t y_size = width * height;
    uint32_t uv_size = (width / 2) * (height / 2);

    PW_SET_PLANE_DMABUF(buffer, 0, dmabuf_fd);
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;

    PW_SET_PLANE_DMABUF(buffer, 1, dmabuf_fd);
    buffer->data.video.planes[1].width = width / 2;
    buffer->data.video.planes[1].height = height / 2;
    buffer->data.video.planes[1].stride_bytes = width / 2;
    buffer->data.video.planes[1].offset_bytes = y_size;
    buffer->data.video.planes[1].subresource_index = 1;

    PW_SET_PLANE_DMABUF(buffer, 2, dmabuf_fd);
    buffer->data.video.planes[2].width = width / 2;
    buffer->data.video.planes[2].height = height / 2;
    buffer->data.video.planes[2].stride_bytes = width / 2;
    buffer->data.video.planes[2].offset_bytes = y_size + uv_size;
    buffer->data.video.planes[2].subresource_index = 2;
    break;
  }

  case MINIAV_PIXEL_FORMAT_NV12: {
    buffer->data.video.num_planes = 2;
    uint32_t y_size = width * height;

    PW_SET_PLANE_DMABUF(buffer, 0, dmabuf_fd);
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;

    PW_SET_PLANE_DMABUF(buffer, 1, dmabuf_fd);
    buffer->data.video.planes[1].width = width / 2;
    buffer->data.video.planes[1].height = height / 2;
    buffer->data.video.planes[1].stride_bytes = width;
    buffer->data.video.planes[1].offset_bytes = y_size;
    buffer->data.video.planes[1].subresource_index = 1;
    break;
  }

  default: {
    buffer->data.video.num_planes = 1;
    PW_SET_PLANE_DMABUF(buffer, 0, dmabuf_fd);
    buffer->data.video.planes[0].width = width;
    buffer->data.video.planes[0].height = height;
    buffer->data.video.planes[0].stride_bytes = width * 4;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    miniav_log(
        MINIAV_LOG_LEVEL_WARN,
        "PW Screen: Unknown pixel format %d for GPU, assuming single plane",
        format);
    break;
  }
  }

#undef PW_SET_PLANE_DMABUF
}

static uint32_t get_display_refresh_rate_hz(void) {
  uint32_t detected_rate = 60; // Default fallback

  // Method 1: Try to read from /sys/class/drm (improved parsing)
  DIR *drm_dir = opendir("/sys/class/drm");
  if (drm_dir) {
    struct dirent *entry;
    while ((entry = readdir(drm_dir)) != NULL) {
      // Look for connector entries (card0-HDMI-A-1, card0-eDP-1, etc.)
      if (strncmp(entry->d_name, "card0-", 6) == 0) {
        char modes_path[256];
        snprintf(modes_path, sizeof(modes_path), "/sys/class/drm/%s/modes",
                 entry->d_name);

        FILE *fp = fopen(modes_path, "r");
        if (fp) {
          char line[256];
          // Read first mode line (usually the preferred/current mode)
          if (fgets(line, sizeof(line), fp)) {
            // Parse mode line like "1920x1080" or "1920x1080@60.00"
            char *at_pos = strchr(line, '@');
            if (at_pos) {
              float rate = strtof(at_pos + 1, NULL);
              if (rate > 0 && rate <= 1000) {
                detected_rate = (uint32_t)(rate + 0.5f);
                miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                           "PW Screen: Detected refresh rate from %s: %u Hz",
                           modes_path, detected_rate);
                fclose(fp);
                closedir(drm_dir);
                return detected_rate;
              }
            } else {
              // No @rate, try to get it from status file
              fclose(fp);

              char status_path[256];
              snprintf(status_path, sizeof(status_path),
                       "/sys/class/drm/%s/status", entry->d_name);
              fp = fopen(status_path, "r");
              if (fp) {
                char status[32];
                if (fgets(status, sizeof(status), fp) &&
                    strncmp(status, "connected", 9) == 0) {
                  // This connector is active, try to get mode from
                  // /sys/class/drm/card0/card0-*/modes
                  fclose(fp);

                  // Try reading from the main card modes
                  FILE *card_fp = fopen("/proc/fb", "r");
                  if (card_fp) {
                    // Fallback: assume 60Hz for connected display
                    detected_rate = 60;
                    fclose(card_fp);
                    closedir(drm_dir);
                    miniav_log(
                        MINIAV_LOG_LEVEL_INFO,
                        "PW Screen: Connected display found, assuming %u Hz",
                        detected_rate);
                    return detected_rate;
                  }
                }
                fclose(fp);
              }
            }
          }
          fclose(fp);
        }
      }
    }
    closedir(drm_dir);
  }

  // Method 2: Try xrandr with better parsing
  FILE *fp = popen("xrandr 2>/dev/null | grep '\\*' | head -1", "r");
  if (fp) {
    char line[512];
    if (fgets(line, sizeof(line), fp)) {
      // Parse xrandr line like "   1920x1080     60.00*+  59.93    ..."
      char *asterisk_pos = strchr(line, '*');
      if (asterisk_pos) {
        // Go backwards to find the refresh rate
        char *rate_start = asterisk_pos;
        while (rate_start > line && !isspace(*rate_start)) {
          rate_start--;
        }
        if (rate_start > line) {
          rate_start++; // Move past the space
          float rate = strtof(rate_start, NULL);
          if (rate > 0 && rate <= 1000) {
            detected_rate = (uint32_t)(rate + 0.5f);
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Screen: Detected refresh rate from xrandr: %u Hz",
                       detected_rate);
            pclose(fp);
            return detected_rate;
          }
        }
      }
    }
    pclose(fp);
  }

  // Method 3: Try Wayland compositor info (for Wayland sessions)
  fp = popen("wlr-randr 2>/dev/null | grep -A5 'current' | grep -E "
             "'[0-9]+\\.[0-9]+ Hz' | head -1",
             "r");
  if (fp) {
    char line[256];
    if (fgets(line, sizeof(line), fp)) {
      // Parse wlr-randr line like "    60.00 Hz"
      char *hz_pos = strstr(line, " Hz");
      if (hz_pos) {
        // Go backwards to find the rate
        char *rate_start = hz_pos;
        while (rate_start > line && !isspace(*rate_start)) {
          rate_start--;
        }
        if (rate_start > line) {
          float rate = strtof(rate_start, NULL);
          if (rate > 0 && rate <= 1000) {
            detected_rate = (uint32_t)(rate + 0.5f);
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Screen: Detected refresh rate from wlr-randr: %u Hz",
                       detected_rate);
            pclose(fp);
            return detected_rate;
          }
        }
      }
    }
    pclose(fp);
  }

  // Method 4: Check environment variable (for manual override)
  const char *env_rate = getenv("MINIAV_DISPLAY_REFRESH_RATE");
  if (env_rate) {
    uint32_t env_rate_val = (uint32_t)strtoul(env_rate, NULL, 10);
    if (env_rate_val > 0 && env_rate_val <= 1000) {
      detected_rate = env_rate_val;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: Using refresh rate from environment: %u Hz",
                 detected_rate);
      return detected_rate;
    }
  }

  // Method 5: Try reading from X11 if available
  fp = popen("xdpyinfo 2>/dev/null | grep 'dimensions:' -A5 | grep "
             "'resolution:' | head -1",
             "r");
  if (fp) {
    char line[256];
    if (fgets(line, sizeof(line), fp)) {
      // This doesn't give refresh rate directly, but confirms X11 is running
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: X11 detected, using fallback rate");
    }
    pclose(fp);
  }

  miniav_log(
      MINIAV_LOG_LEVEL_WARN,
      "PW Screen: Could not detect display refresh rate, defaulting to %u Hz. "
      "You can override with: export MINIAV_DISPLAY_REFRESH_RATE=60",
      detected_rate);
  return detected_rate;
}

// --- Forward Declarations for Static Functions ---
static void *pw_screen_loop_thread_func(void *arg);

// PipeWire Core Events
static void on_pw_core_info(void *data, const struct pw_core_info *info);
static void on_pw_core_done(void *data, uint32_t id, int seq);
static void on_pw_core_error(void *data, uint32_t id, int seq, int res,
                             const char *message);

// PipeWire Stream Events (Video)
static void on_video_stream_state_changed(void *data, enum pw_stream_state old,
                                          enum pw_stream_state new_state,
                                          const char *error);
static void on_video_stream_param_changed(void *data, uint32_t id,
                                          const struct spa_pod *param);
static void on_video_stream_process(void *data);
static void on_video_stream_add_buffer(void *data, struct pw_buffer *buffer);
static void on_video_stream_remove_buffer(void *data, struct pw_buffer *buffer);

// PipeWire Stream Events (Audio) - if separate audio stream
static void on_audio_stream_state_changed(void *data, enum pw_stream_state old,
                                          enum pw_stream_state new_state,
                                          const char *error);
static void on_audio_stream_param_changed(void *data, uint32_t id,
                                          const struct spa_pod *param);
static void on_audio_stream_process(void *data);

// --- Forward Declarations for D-Bus callbacks and setup ---
static void
pw_screen_setup_pipewire_streams(PipeWireScreenPlatformContext *pctx);
static void on_portal_create_session_dbus_response(GObject *source_object,
                                                   GAsyncResult *res,
                                                   gpointer user_data);
static void on_portal_request_response(GObject *source_object,
                                       GAsyncResult *res, gpointer user_data);
static void on_portal_request_signal_response(
    GDBusConnection *connection, const gchar *sender_name,
    const gchar *object_path, const gchar *interface_name,
    const gchar *signal_name, GVariant *parameters, gpointer user_data);
static void portal_initiate_select_sources(PipeWireScreenPlatformContext *pctx);
static void portal_initiate_start_stream(PipeWireScreenPlatformContext *pctx);
static void
on_portal_select_sources_response(PipeWireScreenPlatformContext *pctx,
                                  GVariant *results);
static void on_portal_start_response(PipeWireScreenPlatformContext *pctx,
                                     GVariant *results);
static void on_portal_session_closed(GDBusConnection *connection,
                                     const gchar *sender_name,
                                     const gchar *object_path,
                                     const gchar *interface_name,
                                     const gchar *signal_name,
                                     GVariant *parameters, gpointer user_data);

static void on_dbus_method_call_completed_cb(GObject *source_object,
                                             GAsyncResult *res,
                                             gpointer user_data);

// Helper to generate a unique token
static char *generate_token(const char *prefix) {
  // GLib provides g_random_int() which is good enough for a handle token.
  return g_strdup_printf("%s_%d_%u", prefix, getpid(), g_random_int());
}

// --- Ops Implementation ---

static MiniAVResultCode
pw_screen_init_platform(struct MiniAVScreenContext *ctx) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Initializing platform context.");
  GError *error = NULL;

  pctx->cancellable = g_cancellable_new();

  pctx->dbus_conn =
      g_bus_get_sync(G_BUS_TYPE_SESSION, pctx->cancellable, &error);
  if (error) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to connect to D-Bus: %s", error->message);
    g_error_free(error);
    g_object_unref(pctx->cancellable);
    pctx->cancellable = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Connected to D-Bus session bus.");

  pctx->loop = pw_main_loop_new(NULL);
  if (!pctx->loop) {
    g_object_unref(pctx->dbus_conn);
    g_object_unref(pctx->cancellable);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pctx->context = pw_context_new(pw_main_loop_get_loop(pctx->loop), NULL, 0);
  // Create and run a GLib main loop to process asynchronous D-Bus calls.
  gloop = g_main_loop_new(NULL, FALSE);
  if (pthread_create(&gloop_thread, NULL, glib_main_loop_thread, NULL) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to create GLib main loop thread.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if (!pctx->context) {
    pw_main_loop_destroy(pctx->loop);
    g_object_unref(pctx->dbus_conn);
    g_object_unref(pctx->cancellable);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pctx->core = pw_context_connect(pctx->context, NULL, 0);
  if (!pctx->core) {
    pw_context_destroy(pctx->context);
    pw_main_loop_destroy(pctx->loop);
    g_object_unref(pctx->dbus_conn);
    g_object_unref(pctx->cancellable);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  static const struct pw_core_events core_events = {
      PW_VERSION_CORE_EVENTS,
      .info = on_pw_core_info,
      .done = on_pw_core_done,
      .error = on_pw_core_error,
  };
  pw_core_add_listener(pctx->core, &pctx->core_listener, &core_events, pctx);

  // Initialize DMABUF FD array
  for (int i = 0; i < PW_SCREEN_MAX_BUFFERS; ++i) {
    pctx->video_dmabuf_fds[i] = -1;
  }

  if (pipe2(pctx->wakeup_pipe, O_CLOEXEC | O_NONBLOCK) == -1) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to create wakeup pipe: %s", strerror(errno));
    pw_core_disconnect(pctx->core);
    pw_context_destroy(pctx->context);
    pw_main_loop_destroy(pctx->loop);
    g_object_unref(pctx->dbus_conn);
    g_object_unref(pctx->cancellable);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pctx->video_node_id = PW_ID_ANY;
  pctx->audio_node_id = PW_ID_ANY;
  pctx->core_connected = false;
  pctx->portal_session_handle_str = NULL;
  pctx->current_portal_request_token_str = NULL;
  pctx->current_portal_request_object_path_str = NULL;
  pctx->current_portal_op_state = PORTAL_OP_STATE_NONE;
  pctx->current_request_signal_subscription_id = 0;
  pctx->session_closed_signal_subscription_id = 0;
  pctx->app_callback_pending = NULL;
  pctx->app_callback_user_data_pending = NULL;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Platform context initialized. "
                                     "Waiting for core connection...");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_get_default_formats(const char *device_id,
                              MiniAVVideoInfo *video_format_out,
                              MiniAVAudioInfo *audio_format_out) {
  MINIAV_UNUSED(device_id);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: GetDefaultFormats for device: %s",
             device_id ? device_id : "Any (Portal)");

  if (video_format_out) {
    video_format_out->pixel_format =
        MINIAV_PIXEL_FORMAT_BGRX32; // Common, good quality default
    video_format_out->width = 0;    // Request native/negotiated width
    video_format_out->height = 0;   // Request native/negotiated height
    video_format_out->frame_rate_numerator = 30; // Common default FPS
    video_format_out->frame_rate_denominator = 1;
  }
  if (audio_format_out) {
    audio_format_out->format = MINIAV_AUDIO_FORMAT_F32;
    audio_format_out->sample_rate = 48000;
    audio_format_out->channels = 2;
  }
  miniav_log(
      MINIAV_LOG_LEVEL_INFO, // Changed to INFO as this is important behavior
      "PW Screen: GetDefaultFormats provides common placeholders. "
      "Resolution 0x0 requests native/negotiated size. "
      "Actual formats depend on source negotiation after StartCapture.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_get_configured_video_formats(struct MiniAVScreenContext *ctx,
                                       MiniAVVideoInfo *video_format_out,
                                       MiniAVAudioInfo *audio_format_out) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;

  if (video_format_out) {
    // Prefer actually negotiated and valid format stored in the parent context
    if (ctx->configured_video_format.pixel_format !=
            MINIAV_PIXEL_FORMAT_UNKNOWN &&
        ctx->configured_video_format.width > 0 &&
        ctx->configured_video_format.height > 0) {
      *video_format_out = ctx->configured_video_format;
      video_format_out->output_preference =
          pctx->requested_video_format.output_preference;
    } else if (ctx->is_configured) { // Fallback to what was initially
                                     // requested/configured
      *video_format_out = pctx->requested_video_format;
    } else { // Not configured at all
      memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
      video_format_out->pixel_format = MINIAV_PIXEL_FORMAT_UNKNOWN;
    }
  }

  if (audio_format_out) {
    // Prefer actually negotiated audio format stored in the parent context
    if (ctx->configured_audio_format.format != MINIAV_AUDIO_FORMAT_UNKNOWN &&
        ctx->configured_audio_format.sample_rate > 0) {
      *audio_format_out = ctx->configured_audio_format;
    } else if (ctx->is_configured &&
               pctx->audio_requested_by_user) { // Fallback to requested
      *audio_format_out = pctx->requested_audio_format;
    } else { // Not configured or audio not requested
      memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
      audio_format_out->format = MINIAV_AUDIO_FORMAT_UNKNOWN;
    }
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_enumerate_displays(MiniAVDeviceInfo **displays_out,
                             uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: EnumerateDisplays called.");
  *displays_out =
      (MiniAVDeviceInfo *)miniav_calloc(1, sizeof(MiniAVDeviceInfo));
  if (!*displays_out)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  strncpy((*displays_out)[0].device_id, "portal_display", // Generic ID
          MINIAV_DEVICE_ID_MAX_LEN - 1);
  strncpy((*displays_out)[0].name, "Screen (select via Portal)",
          MINIAV_DEVICE_NAME_MAX_LEN - 1);
  (*displays_out)[0].is_default = true;
  *count_out = 1;

  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "PW Screen: EnumerateDisplays is simplified. Full enumeration "
             "requires portal interaction.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_enumerate_windows(MiniAVDeviceInfo **windows_out,
                            uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: EnumerateWindows called.");
  // Similar to displays, portal interaction is key.
  *windows_out = (MiniAVDeviceInfo *)miniav_calloc(1, sizeof(MiniAVDeviceInfo));
  if (!*windows_out)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  strncpy((*windows_out)[0].device_id, "portal_window", // Generic ID
          MINIAV_DEVICE_ID_MAX_LEN - 1);
  strncpy((*windows_out)[0].name, "Window/Application (select via Portal)",
          MINIAV_DEVICE_NAME_MAX_LEN - 1);
  *count_out = 1;

  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "PW Screen: EnumerateWindows is simplified. Full enumeration "
             "requires portal interaction.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_configure_display(struct MiniAVScreenContext *ctx,
                            const char *display_id,
                            const MiniAVVideoInfo *video_format) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: ConfigureDisplay for ID: %s",
             display_id ? display_id : "any_portal_selected");

  if (display_id) {
    strncpy(pctx->target_id_str, display_id, sizeof(pctx->target_id_str) - 1);
  } else {
    strncpy(pctx->target_id_str, "portal_selected_display",
            sizeof(pctx->target_id_str) - 1);
  }

  // Start with defaults for both video and audio (if requested)
  pw_screen_get_default_formats(
      display_id, &pctx->requested_video_format,
      (ctx->capture_audio_requested ? &pctx->requested_audio_format : NULL));

  uint32_t display_refresh_rate = get_display_refresh_rate_hz();

  // Overlay user-provided video format specifics if they are valid
  if (video_format) {
    if (video_format->width > 0 && video_format->height > 0) {
      pctx->requested_video_format.width = video_format->width;
      pctx->requested_video_format.height = video_format->height;
    }

    if (video_format->pixel_format != MINIAV_PIXEL_FORMAT_UNKNOWN) {
      pctx->requested_video_format.pixel_format = video_format->pixel_format;
    }

    if (video_format->frame_rate_numerator > 0 &&
        video_format->frame_rate_denominator > 0) {

      uint32_t requested_fps = video_format->frame_rate_numerator /
                               video_format->frame_rate_denominator;
      uint32_t capped_fps = requested_fps;

      // Cap to display refresh rate + small margin
      uint32_t max_reasonable_fps =
          display_refresh_rate + (display_refresh_rate / 4); // 25% margin

      if (requested_fps > max_reasonable_fps) {
        capped_fps = display_refresh_rate;
        miniav_log(
            MINIAV_LOG_LEVEL_WARN,
            "PW Screen: Requested FPS (%u) exceeds display refresh rate (%u "
            "Hz) + margin. "
            "Capping to %u FPS to avoid PipeWire format negotiation failure.",
            requested_fps, display_refresh_rate, capped_fps);
      } else if (requested_fps > display_refresh_rate) {
        miniav_log(
            MINIAV_LOG_LEVEL_INFO,
            "PW Screen: Requested FPS (%u) slightly exceeds display refresh "
            "rate (%u Hz). "
            "Will attempt negotiation but may fall back to display rate.",
            requested_fps, display_refresh_rate);
      }

      pctx->requested_video_format.frame_rate_numerator = capped_fps;
      pctx->requested_video_format.frame_rate_denominator = 1;

    } else if (video_format->frame_rate_numerator > 0 &&
               pctx->requested_video_format.frame_rate_denominator == 0) {
      // User provided numerator but not denominator, assume /1 and validate
      uint32_t requested_fps = video_format->frame_rate_numerator;
      uint32_t max_reasonable_fps =
          display_refresh_rate + (display_refresh_rate / 4);

      if (requested_fps > max_reasonable_fps) {
        pctx->requested_video_format.frame_rate_numerator =
            display_refresh_rate;
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "PW Screen: Requested FPS (%u) exceeds display "
                   "capabilities. Capped to %u FPS.",
                   requested_fps, display_refresh_rate);
      } else {
        pctx->requested_video_format.frame_rate_numerator = requested_fps;
      }
      pctx->requested_video_format.frame_rate_denominator = 1;
    }
  }

  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "PW Screen: ConfigureDisplay - Effective requested video format: %ux%u, "
      "%s (%d), %u/%u FPS (display: %u Hz), Pref: %d",
      pctx->requested_video_format.width, pctx->requested_video_format.height,
      screen_pixel_format_to_string(pctx->requested_video_format.pixel_format),
      pctx->requested_video_format.pixel_format,
      pctx->requested_video_format.frame_rate_numerator,
      pctx->requested_video_format.frame_rate_denominator, display_refresh_rate,
      pctx->requested_video_format.output_preference);

  pctx->capture_type = MINIAV_CAPTURE_TYPE_DISPLAY;
  pctx->audio_requested_by_user = ctx->capture_audio_requested;

  if (pctx->audio_requested_by_user) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: ConfigureDisplay - Effective requested audio "
               "format: %u Hz, %u Ch, Format %d",
               pctx->requested_audio_format.sample_rate,
               pctx->requested_audio_format.channels,
               pctx->requested_audio_format.format);
  }

  ctx->is_configured = true;
  ctx->configured_video_format = pctx->requested_video_format;
  if (ctx->capture_audio_requested) {
    ctx->configured_audio_format = pctx->requested_audio_format;
  }

  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_configure_window(struct MiniAVScreenContext *ctx,
                           const char *window_id,
                           const MiniAVVideoInfo *video_format) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: ConfigureWindow for ID: %s",
             window_id ? window_id : "any_portal_selected");

  if (window_id) {
    strncpy(pctx->target_id_str, window_id, sizeof(pctx->target_id_str) - 1);
  } else {
    strncpy(pctx->target_id_str, "portal_selected_window",
            sizeof(pctx->target_id_str) - 1);
  }

  pw_screen_get_default_formats(
      window_id, &pctx->requested_video_format,
      (ctx->capture_audio_requested ? &pctx->requested_audio_format : NULL));

  if (video_format) {
    if (video_format->width > 0 && video_format->height > 0) {
      pctx->requested_video_format.width = video_format->width;
      pctx->requested_video_format.height = video_format->height;
    }
    if (video_format->pixel_format != MINIAV_PIXEL_FORMAT_UNKNOWN) {
      pctx->requested_video_format.pixel_format = video_format->pixel_format;
    }
    if (video_format->frame_rate_numerator > 0 &&
        video_format->frame_rate_denominator > 0) {
      pctx->requested_video_format.frame_rate_numerator =
          video_format->frame_rate_numerator;
      pctx->requested_video_format.frame_rate_denominator =
          video_format->frame_rate_denominator;
    } else if (video_format->frame_rate_numerator > 0 &&
               pctx->requested_video_format.frame_rate_denominator == 0) {
      pctx->requested_video_format.frame_rate_numerator =
          video_format->frame_rate_numerator;
      pctx->requested_video_format.frame_rate_denominator = 1;
    }
    pctx->requested_video_format.output_preference =
        video_format->output_preference;
  }

  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "PW Screen: ConfigureWindow - Effective requested video format: %ux%u, "
      "%s (%d), %u/%u FPS, Pref: %d",
      pctx->requested_video_format.width, pctx->requested_video_format.height,
      screen_pixel_format_to_string(pctx->requested_video_format.pixel_format),
      pctx->requested_video_format.pixel_format,
      pctx->requested_video_format.frame_rate_numerator,
      pctx->requested_video_format.frame_rate_denominator,
      pctx->requested_video_format.output_preference);

  pctx->capture_type = MINIAV_CAPTURE_TYPE_WINDOW;
  pctx->audio_requested_by_user = ctx->capture_audio_requested;

  if (pctx->audio_requested_by_user) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: ConfigureWindow - Effective requested audio format: "
               "%u Hz, %u Ch, Format %d",
               pctx->requested_audio_format.sample_rate,
               pctx->requested_audio_format.channels,
               pctx->requested_audio_format.format);
  }

  ctx->is_configured = true;
  ctx->configured_video_format = pctx->requested_video_format;
  if (ctx->capture_audio_requested) {
    ctx->configured_audio_format = pctx->requested_audio_format;
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_configure_region(struct MiniAVScreenContext *ctx,
                           const char *target_id, int x, int y, int width,
                           int height, const MiniAVVideoInfo *video_format) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: ConfigureRegion for ID: %s, Rect: %d,%d %dx%d",
             target_id ? target_id : "any_portal_selected", x, y, width,
             height);

  if (target_id) {
    strncpy(pctx->target_id_str, target_id, sizeof(pctx->target_id_str) - 1);
  } else {
    strncpy(pctx->target_id_str, "portal_selected_region_base",
            sizeof(pctx->target_id_str) - 1);
  }

  pw_screen_get_default_formats(
      target_id, &pctx->requested_video_format,
      (ctx->capture_audio_requested ? &pctx->requested_audio_format : NULL));

  // For region, the width/height from parameters are primary
  if (width > 0 && height > 0) {
    pctx->requested_video_format.width = width;
    pctx->requested_video_format.height = height;
  }
  // Then overlay other specifics from user's video_format
  if (video_format) {
    if (video_format->width > 0 && video_format->height > 0) {
      pctx->requested_video_format.width = video_format->width;
      pctx->requested_video_format.height = video_format->height;
    }
    if (video_format->pixel_format != MINIAV_PIXEL_FORMAT_UNKNOWN) {
      pctx->requested_video_format.pixel_format = video_format->pixel_format;
    }
    if (video_format->frame_rate_numerator > 0 &&
        video_format->frame_rate_denominator > 0) {
      pctx->requested_video_format.frame_rate_numerator =
          video_format->frame_rate_numerator;
      pctx->requested_video_format.frame_rate_denominator =
          video_format->frame_rate_denominator;
    } else if (video_format->frame_rate_numerator > 0 &&
               pctx->requested_video_format.frame_rate_denominator == 0) {
      pctx->requested_video_format.frame_rate_numerator =
          video_format->frame_rate_numerator;
      pctx->requested_video_format.frame_rate_denominator = 1;
    }
    pctx->requested_video_format.output_preference =
        video_format->output_preference;
  }

  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "PW Screen: ConfigureRegion - Effective requested video format: %ux%u, "
      "%s (%d), %u/%u FPS, Pref: %d",
      pctx->requested_video_format.width, pctx->requested_video_format.height,
      screen_pixel_format_to_string(pctx->requested_video_format.pixel_format),
      pctx->requested_video_format.pixel_format,
      pctx->requested_video_format.frame_rate_numerator,
      pctx->requested_video_format.frame_rate_denominator,
      pctx->requested_video_format.output_preference);

  pctx->capture_type = MINIAV_CAPTURE_TYPE_REGION;
  pctx->audio_requested_by_user = ctx->capture_audio_requested;
  pctx->region_x = x;
  pctx->region_y = y;
  // pctx->region_width and pctx->region_height are effectively set via
  // pctx->requested_video_format.width/height

  if (pctx->audio_requested_by_user) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: ConfigureRegion - Effective requested audio format: "
               "%u Hz, %u Ch, Format %d",
               pctx->requested_audio_format.sample_rate,
               pctx->requested_audio_format.channels,
               pctx->requested_audio_format.format);
  }

  // HONESTY NOTE: region_x/region_y are stored but the PipeWire delivery path
  // does NOT crop to them — xdg-desktop-portal negotiates a whole source
  // (monitor/window), and client-side cropping of the delivered buffer is not
  // implemented. So the app receives the FULL source, not the sub-rectangle.
  // The config is still accepted (the portal may honor the requested size for
  // some sources) but callers must not assume the frame is cropped. See
  // NATIVE_AUDIT.md "region capture" (deferred). macOS honors regions via
  // SCStreamConfiguration.sourceRect; Windows returns NOT_SUPPORTED.
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "PW Screen: region capture is NOT cropped client-side — the app "
             "receives the full portal source, not the %dx%d sub-rectangle. "
             "Crop downstream if you need the exact region.",
             width, height);

  ctx->is_configured = true;
  ctx->configured_video_format = pctx->requested_video_format;
  if (ctx->capture_audio_requested) {
    ctx->configured_audio_format = pctx->requested_audio_format;
  }
  return MINIAV_SUCCESS;
}

static void on_portal_request_response(GObject *source_object,
                                       GAsyncResult *res, gpointer user_data) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)user_data;
  GError *error = NULL;
  GVariant *result_variant = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source_object), res, &error);

  if (error) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: D-Bus request call failed: %s", error->message);
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    g_error_free(error);
    if (result_variant)
      g_variant_unref(result_variant);
    if (pctx->loop_running && pctx->wakeup_pipe[1] != -1) {
      write(pctx->wakeup_pipe[1], "f", 1);
    }
    return;
  }

  const gchar *variant_type = g_variant_get_type_string(result_variant);
  if (g_strcmp0(variant_type, "(o)") != 0) {
    gchar *dbg_str = g_variant_print(result_variant, TRUE);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Unexpected D-Bus reply type: %s, value: %s",
               variant_type, dbg_str);
    g_free(dbg_str);
    g_variant_unref(result_variant);
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    if (pctx->loop_running && pctx->wakeup_pipe[1] != -1) {
      write(pctx->wakeup_pipe[1], "f", 1);
    }
    return;
  }

  char *request_handle_path_temp;
  g_variant_get(result_variant, "(o)", &request_handle_path_temp);
  char *request_handle_path = g_strdup(request_handle_path_temp);
  g_variant_unref(result_variant);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: D-Bus request initiated, handle: %s. Waiting for "
             "Response signal.",
             request_handle_path);

  // Unsubscribe any previous request signal before subscribing to a new one
  if (pctx->current_request_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->current_request_signal_subscription_id);
    pctx->current_request_signal_subscription_id = 0;
  }

  pctx->current_request_signal_subscription_id =
      g_dbus_connection_signal_subscribe(
          pctx->dbus_conn, XDP_BUS_NAME, XDP_IFACE_REQUEST, "Response",
          request_handle_path,      // Object path of the request
          NULL,                     // arg0 filter
          G_DBUS_SIGNAL_FLAGS_NONE, // CORRECTED FLAG
          (GDBusSignalCallback)on_portal_request_signal_response,
          pctx, // Pass pctx as user_data
          NULL);

  if (pctx->current_request_signal_subscription_id == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to subscribe to Response signal for %s",
               request_handle_path);
    // Handle error: subscription failed
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    if (pctx->loop_running && pctx->wakeup_pipe[1] != -1) {
      write(pctx->wakeup_pipe[1], "f", 1);
    }
  }
  g_free(request_handle_path); // Free the duplicated path
}

static void on_dbus_method_call_completed_cb(GObject *source_object,
                                             GAsyncResult *res,
                                             gpointer user_data) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)user_data;
  GError *error = NULL;
  GVariant *result_variant = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source_object), res, &error);

  if (error) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: D-Bus method call failed (op_state %d): %s",
               pctx->current_portal_op_state, error->message);
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    g_error_free(error);
    if (result_variant)
      g_variant_unref(result_variant);
    // TODO: Notify application of failure, potentially clean up
    // For now, just reset state
    pctx->current_portal_op_state = PORTAL_OP_STATE_NONE;
    g_free(pctx->current_portal_request_token_str);
    pctx->current_portal_request_token_str = NULL;
    return;
  }

  char *request_obj_path_temp = NULL;
  g_variant_get(result_variant, "(o)", &request_obj_path_temp);
  g_free(pctx->current_portal_request_object_path_str); // Free old one if any
  pctx->current_portal_request_object_path_str =
      g_strdup(request_obj_path_temp);
  g_variant_unref(result_variant);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: D-Bus method call for op_state %d initiated. Request "
             "object: %s. Token: %s. Waiting for Response signal.",
             pctx->current_portal_op_state,
             pctx->current_portal_request_object_path_str,
             pctx->current_portal_request_token_str
                 ? pctx->current_portal_request_token_str
                 : "N/A");

  // Unsubscribe any previous request signal before subscribing to a new one
  if (pctx->current_request_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->current_request_signal_subscription_id);
    pctx->current_request_signal_subscription_id = 0;
  }

  pctx->current_request_signal_subscription_id =
      g_dbus_connection_signal_subscribe(
          pctx->dbus_conn,
          XDP_BUS_NAME,                                 // Sender
          XDP_IFACE_REQUEST,                            // Interface
          "Response",                                   // Signal name
          pctx->current_portal_request_object_path_str, // Object path of the
                                                        // request
          NULL, // arg0 filter (NULL for no filter)
          G_DBUS_SIGNAL_FLAGS_NONE,
          (GDBusSignalCallback)on_portal_request_signal_response,
          pctx, // user_data
          NULL  // GDestroyNotify for user_data
      );

  if (pctx->current_request_signal_subscription_id == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to subscribe to Response signal for %s",
               pctx->current_portal_request_object_path_str);
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    g_free(pctx->current_portal_request_object_path_str);
    pctx->current_portal_request_object_path_str = NULL;
    g_free(pctx->current_portal_request_token_str);
    pctx->current_portal_request_token_str = NULL;
    pctx->current_portal_op_state = PORTAL_OP_STATE_NONE;
  }
}

static void on_portal_request_signal_response(
    GDBusConnection *connection, const gchar *sender_name,
    const gchar *object_path, // Path of the Request object that emitted signal
    const gchar *interface_name, const gchar *signal_name,
    GVariant *parameters, // (uint response_code, dict results)
    gpointer user_data) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)user_data;

  // Defensive check: ensure this signal is for the request we're expecting
  if (!pctx->current_portal_request_object_path_str ||
      strcmp(object_path, pctx->current_portal_request_object_path_str) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Received Response signal for unexpected request "
               "object %s (expected %s). Ignoring.",
               object_path,
               pctx->current_portal_request_object_path_str
                   ? pctx->current_portal_request_object_path_str
                   : "null");
    return;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Received Response signal for request object %s "
             "(op_state %d, token %s)",
             object_path, pctx->current_portal_op_state,
             pctx->current_portal_request_token_str
                 ? pctx->current_portal_request_token_str
                 : "N/A");

  // Unsubscribe from this signal now that we've received it.
  if (pctx->current_request_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        connection, pctx->current_request_signal_subscription_id);
    pctx->current_request_signal_subscription_id = 0;
  }
  g_free(pctx->current_portal_request_object_path_str); // We are done with this
                                                        // request object path
  pctx->current_portal_request_object_path_str = NULL;
  // We keep current_portal_request_token_str for logging/debugging until the
  // next request is made.

  guint response_code;
  GVariant *results_dict = NULL;
  g_variant_get(parameters, "(u@a{sv})", &response_code,
                &results_dict); // results_dict is new ref

  if (response_code != 0) { // 0 = success, 1 = user cancelled, 2 = error
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Portal request (op_state %d, token %s) "
               "failed/cancelled with code %u.",
               pctx->current_portal_op_state,
               pctx->current_portal_request_token_str
                   ? pctx->current_portal_request_token_str
                   : "N/A",
               response_code);
    pctx->last_error = (response_code == 1) ? MINIAV_ERROR_USER_CANCELLED
                                            : MINIAV_ERROR_PORTAL_FAILED;

    // TODO: Notify application of failure, clean up state
    pctx->current_portal_op_state = PORTAL_OP_STATE_NONE;
    g_free(pctx->current_portal_request_token_str);
    pctx->current_portal_request_token_str = NULL;
    return;
  }

  // Process successful response based on current operation state
  PortalOperationState completed_op_state = pctx->current_portal_op_state;
  pctx->current_portal_op_state =
      PORTAL_OP_STATE_NONE; // Reset before potentially starting next

  switch (completed_op_state) {
  case PORTAL_OP_STATE_CREATING_SESSION: {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Processing CreateSession response (token %s).",
               pctx->current_portal_request_token_str
                   ? pctx->current_portal_request_token_str
                   : "N/A");
    const char *session_handle_temp = NULL;
    gboolean found_handle = FALSE;

    // Try to look up as object path first (standard)
    if (g_variant_lookup(results_dict, "session_handle", "o",
                         &session_handle_temp)) {
      found_handle = TRUE;
    }
    // If not found as object path, try as string (for robustness)
    else if (g_variant_lookup(results_dict, "session_handle", "s",
                              &session_handle_temp)) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: 'session_handle' found as type 's' (string), "
                 "though 'o' (object path) was expected.");
      found_handle = TRUE;
    }

    if (found_handle && session_handle_temp != NULL) {
      g_free(pctx->portal_session_handle_str);
      pctx->portal_session_handle_str = g_strdup(session_handle_temp);
      miniav_log(MINIAV_LOG_LEVEL_INFO, "PW Screen: Portal session created: %s",
                 pctx->portal_session_handle_str);

      // Subscribe to SessionClosed signal
      if (pctx->session_closed_signal_subscription_id > 0) {
        g_dbus_connection_signal_unsubscribe(
            pctx->dbus_conn, pctx->session_closed_signal_subscription_id);
      }
      pctx->session_closed_signal_subscription_id =
          g_dbus_connection_signal_subscribe(
              pctx->dbus_conn, XDP_BUS_NAME, XDP_IFACE_SESSION, "Closed",
              pctx->portal_session_handle_str, // Object path of the session
              NULL, G_DBUS_SIGNAL_FLAGS_NONE,
              (GDBusSignalCallback)on_portal_session_closed, pctx, NULL);
      if (pctx->session_closed_signal_subscription_id == 0) {
        miniav_log(
            MINIAV_LOG_LEVEL_WARN,
            "PW Screen: Failed to subscribe to SessionClosed signal for %s",
            pctx->portal_session_handle_str);
      }

      portal_initiate_select_sources(pctx); // Proceed to next step
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Screen: 'session_handle' (type "
                                         "'o' or 's') not found or is NULL in "
                                         "CreateSession response dict.");
      // Optional: Log the actual type for detailed debugging if the key exists
      if (results_dict && g_variant_is_container(results_dict)) {
        GVariant *value =
            g_variant_lookup_value(results_dict, "session_handle", NULL);
        if (value) {
          const char *type_str = g_variant_get_type_string(value);
          miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                     "PW Screen: 'session_handle' exists, actual GVariant type "
                     "is '%s'.",
                     type_str);
          // If it's a string-like type, you could try to print its value too,
          // e.g. with g_variant_get_string(value, NULL)
          g_variant_unref(value);
        } else {
          miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                     "PW Screen: 'session_handle' key truly does not exist in "
                     "results_dict.");
        }
      }
      pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
      // TODO: Cleanup
    }
    break;
  }
  case PORTAL_OP_STATE_SELECTING_SOURCES: {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Processing SelectSources response (token %s). User "
               "made a selection.",
               pctx->current_portal_request_token_str
                   ? pctx->current_portal_request_token_str
                   : "N/A");
    // SelectSources response dict is usually empty on success.
    // The success is implied by response_code == 0.
    portal_initiate_start_stream(pctx); // Proceed to next step
    break;
  }
  case PORTAL_OP_STATE_STARTING_STREAM: {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Processing Start response (token %s).",
               pctx->current_portal_request_token_str
                   ? pctx->current_portal_request_token_str
                   : "N/A");

    if (results_dict) {
      gchar *results_str = g_variant_print(results_dict, TRUE);
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: Full Start response results_dict: %s",
                 results_str);
      g_free(results_str);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Start response results_dict is NULL, but "
                 "response_code was success.");
    }

    GVariant *streams_variant =
        g_variant_lookup_value(results_dict, "streams", NULL);
    gboolean video_node_found = FALSE;
    if (streams_variant) {
      // Unwrap if it's a variant
      if (g_variant_is_of_type(streams_variant, G_VARIANT_TYPE_VARIANT)) {
        GVariant *unwrapped = g_variant_get_variant(streams_variant);
        g_variant_unref(streams_variant);
        streams_variant = unwrapped;
      }
      if (g_variant_is_of_type(streams_variant, G_VARIANT_TYPE_ARRAY)) {
        gsize n_streams = g_variant_n_children(streams_variant);
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Screen: streams array has %zu children", n_streams);
        for (gsize i = 0; i < n_streams; ++i) {
          GVariant *stream_tuple =
              g_variant_get_child_value(streams_variant, i);
          guint32 stream_node_id_temp = 0;
          GVariant *stream_props_dict_variant = NULL;
          g_variant_get(stream_tuple, "(ua{sv})", &stream_node_id_temp,
                        &stream_props_dict_variant);

          if (!video_node_found) {
            pctx->video_node_id = stream_node_id_temp;
            video_node_found = TRUE;
            miniav_log(MINIAV_LOG_LEVEL_INFO,
                       "PW Screen: Found video stream node ID: %u",
                       pctx->video_node_id);
          } else if (pctx->audio_requested_by_user &&
                     pctx->audio_node_id == PW_ID_ANY) {
            pctx->audio_node_id = stream_node_id_temp;
            miniav_log(MINIAV_LOG_LEVEL_INFO,
                       "PW Screen: Found audio stream node ID: %u",
                       pctx->audio_node_id);
          }

          if (stream_props_dict_variant)
            g_variant_unref(stream_props_dict_variant);
          g_variant_unref(stream_tuple);
        }
      } else {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Screen: streams is not an array!");
      }
      g_variant_unref(streams_variant);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Screen: 'streams' key (a(ua{sv})) "
                                         "not found in Start response dict.");
    }
    if (!video_node_found) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Did not find a video node ID from portal Start.");
      pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
      // TODO: Cleanup
    } else {
      miniav_log(MINIAV_LOG_LEVEL_INFO, "Screen capture started successfully.");
      pw_screen_setup_pipewire_streams(pctx);
    }
    break;
  }
  case PORTAL_OP_STATE_NONE:
  default:
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Received portal response in unexpected state: %d "
               "(token %s)",
               completed_op_state,
               pctx->current_portal_request_token_str
                   ? pctx->current_portal_request_token_str
                   : "N/A");
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    break;
  }

  if (results_dict)
    g_variant_unref(results_dict);
  // current_portal_request_token_str will be freed/reset when the next request
  // is made
}

static void
on_portal_session_closed(GDBusConnection *connection, const gchar *sender_name,
                         const gchar *object_path, // Session object path
                         const gchar *interface_name, const gchar *signal_name,
                         GVariant *parameters, // (uint reason)
                         gpointer user_data) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)user_data;
  guint reason;
  const gchar *ptype = g_variant_get_type_string(parameters);

  if (g_strcmp0(ptype, "(u)") == 0) {
    g_variant_get(parameters, "(u)", &reason);
  } else if (g_strcmp0(ptype, "(a{sv})") == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Received Session Closed parameters as (a{sv}), "
               "assuming reason 0.");
    reason = 0;
  } else {
    miniav_log(
        MINIAV_LOG_LEVEL_WARN,
        "PW Screen: Unexpected parameters type %s in Session Closed signal.",
        ptype);
    reason = 0;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW Screen: Portal session %s closed, reason: %u", object_path,
             reason);

  if (pctx->portal_session_handle_str &&
      strcmp(pctx->portal_session_handle_str, object_path) == 0) {

    // Clear the session handle first to prevent double cleanup
    g_free(pctx->portal_session_handle_str);
    pctx->portal_session_handle_str = NULL;

    // Unsubscribe from the session closed signal
    if (pctx->session_closed_signal_subscription_id > 0) {
      g_dbus_connection_signal_unsubscribe(
          connection, pctx->session_closed_signal_subscription_id);
      pctx->session_closed_signal_subscription_id = 0;
    }

    if (pctx->parent_ctx->is_running) {
      miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Screen: Active capture session "
                                        "closed by portal. Stopping capture.");
      pctx->last_error = MINIAV_ERROR_PORTAL_CLOSED;

      // Signal the loop thread to stop
      if (pctx->loop_running && pctx->wakeup_pipe[1] != -1) {
        write(pctx->wakeup_pipe[1], "q", 1);
      }
      pctx->parent_ctx->is_running = false;
    }
  }
}

static MiniAVResultCode pw_screen_start_capture(struct MiniAVScreenContext *ctx,
                                                MiniAVBufferCallback callback,
                                                void *user_data) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Not configured before StartCapture.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (pctx->parent_ctx->is_running || pctx->loop_running ||
      pctx->current_portal_op_state != PORTAL_OP_STATE_NONE) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Start capture called but already running or portal "
               "operation pending (state %d).",
               pctx->current_portal_op_state);
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Starting capture via xdg-desktop-portal (async)...");

  pctx->app_callback_pending = callback;
  pctx->app_callback_user_data_pending = user_data;
  pctx->last_error = MINIAV_SUCCESS; // Reset last error

  if (!pctx->dbus_conn) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: D-Bus connection not available for portal.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (g_cancellable_is_cancelled(pctx->cancellable)) {
    g_object_unref(pctx->cancellable);
    pctx->cancellable = g_cancellable_new();
  }

  // --- If a valid portal session already exists, reuse it ---
  if (pctx->portal_session_handle_str != NULL) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Reusing existing portal session: %s",
               pctx->portal_session_handle_str);
    pctx->current_portal_op_state = PORTAL_OP_STATE_SELECTING_SOURCES;
    portal_initiate_select_sources(pctx);
    return MINIAV_SUCCESS;
  }

  // --- Otherwise, create a new session ---
  pctx->current_portal_op_state = PORTAL_OP_STATE_CREATING_SESSION;

  g_free(pctx->current_portal_request_token_str); // Free previous if any
  pctx->current_portal_request_token_str =
      generate_token("miniav_session_req"); // For CreateSession options

  char *session_handle_token_for_options =
      generate_token("miniav_session_handle_opt"); // For CreateSession options

  GVariantBuilder options_builder;
  g_variant_builder_init(&options_builder, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &options_builder, "{sv}", "handle_token",
      g_variant_new_string(pctx->current_portal_request_token_str));
  g_variant_builder_add(&options_builder, "{sv}", "session_handle_token",
                        g_variant_new_string(session_handle_token_for_options));
  GVariant *options_variant = g_variant_builder_end(&options_builder);
  g_free(session_handle_token_for_options);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Calling CreateSession with token %s",
             pctx->current_portal_request_token_str);

  g_dbus_connection_call(
      pctx->dbus_conn, XDP_BUS_NAME, XDP_OBJECT_PATH, XDP_IFACE_SCREENCAST,
      "CreateSession",
      g_variant_new_tuple(&options_variant,
                          1), // Parameters as a tuple: (a{sv})
      G_VARIANT_TYPE("(o)"),  // Expected reply type: (o)
      G_DBUS_CALL_FLAGS_NONE,
      -1, // Default timeout
      pctx->cancellable, (GAsyncReadyCallback)on_dbus_method_call_completed_cb,
      pctx // user_data
  );
  return MINIAV_SUCCESS;
}

// xdg-desktop-portal ScreenCast cursor modes (bitmask values, per the portal
// spec). AvailableCursorModes advertises which the backend supports.
#define XDP_CURSOR_MODE_HIDDEN 1u   // default here — no cursor in frames
#define XDP_CURSOR_MODE_EMBEDDED 2u // cursor drawn into the frame pixels
#define XDP_CURSOR_MODE_METADATA 4u // cursor delivered as separate metadata

// Read the ScreenCast "AvailableCursorModes" property (a uint32 bitmask) via
// the org.freedesktop.DBus.Properties.Get method. Returns 0 if it cannot be
// read (older portal without the property, or an error) — callers then fall
// back to hidden-cursor behaviour.
static uint32_t
portal_get_available_cursor_modes(PipeWireScreenPlatformContext *pctx) {
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_sync(
      pctx->dbus_conn, XDP_BUS_NAME, XDP_OBJECT_PATH,
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", XDP_IFACE_SCREENCAST, "AvailableCursorModes"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, pctx->cancellable,
      &error);
  if (!reply) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: could not read AvailableCursorModes (%s); assuming "
               "cursor-mode support is limited to hidden.",
               error ? error->message : "unknown");
    if (error) {
      g_error_free(error);
    }
    return 0;
  }

  uint32_t modes = 0;
  GVariant *inner = NULL;
  g_variant_get(reply, "(v)", &inner);
  if (inner) {
    if (g_variant_is_of_type(inner, G_VARIANT_TYPE_UINT32)) {
      modes = g_variant_get_uint32(inner);
    }
    g_variant_unref(inner);
  }
  g_variant_unref(reply);
  return modes;
}

static void
portal_initiate_select_sources(PipeWireScreenPlatformContext *pctx) {
  pctx->current_portal_op_state = PORTAL_OP_STATE_SELECTING_SOURCES;
  g_free(pctx->current_portal_request_token_str);
  pctx->current_portal_request_token_str = generate_token("miniav_select_req");

  GVariantBuilder options_builder;
  g_variant_builder_init(&options_builder, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &options_builder, "{sv}", "handle_token",
      g_variant_new_string(pctx->current_portal_request_token_str));
  g_variant_builder_add(&options_builder, "{sv}", "multiple",
                        g_variant_new_boolean(FALSE));

  uint32_t source_types = 0;
  if (pctx->capture_type == MINIAV_CAPTURE_TYPE_DISPLAY)
    source_types = (1 << 0);
  else if (pctx->capture_type == MINIAV_CAPTURE_TYPE_WINDOW)
    source_types = (1 << 1);
  else
    source_types = (1 << 0) | (1 << 1); // Region or default
  g_variant_builder_add(&options_builder, "{sv}", "types",
                        g_variant_new_uint32(source_types));

  // Cursor mode: honour MiniAVScreenContext.capture_cursor (set via
  // MiniAV_Screen_SetCaptureCursor before configure). Embedded (2) draws the
  // cursor into the frame; hidden (1) is the default cursor-less behaviour.
  // The portal advertises which modes it supports via AvailableCursorModes —
  // fall back gracefully if the requested mode is unsupported.
  bool want_cursor = pctx->parent_ctx && pctx->parent_ctx->capture_cursor;
  uint32_t available_modes = portal_get_available_cursor_modes(pctx);
  uint32_t cursor_mode;
  if (want_cursor) {
    if (available_modes & XDP_CURSOR_MODE_EMBEDDED) {
      cursor_mode = XDP_CURSOR_MODE_EMBEDDED;
    } else if (available_modes & XDP_CURSOR_MODE_METADATA) {
      // Embedded unsupported but metadata is: request metadata so the cursor
      // is at least reported. (This backend does not yet composite the
      // metadata cursor into frames, but the mode is valid and future-proof.)
      cursor_mode = XDP_CURSOR_MODE_METADATA;
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: capture_cursor requested but portal lacks EMBEDDED "
                 "cursor mode; requesting METADATA (cursor not composited into "
                 "frames by this backend).");
    } else {
      cursor_mode = XDP_CURSOR_MODE_HIDDEN;
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: capture_cursor requested but portal advertises no "
                 "embedded/metadata cursor mode (available=0x%x); falling back "
                 "to hidden.",
                 available_modes);
    }
  } else {
    cursor_mode = XDP_CURSOR_MODE_HIDDEN;
  }
  g_variant_builder_add(&options_builder, "{sv}", "cursor_mode",
                        g_variant_new_uint32(cursor_mode));
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: SelectSources cursor_mode=%u (want_cursor=%d, "
             "available=0x%x).",
             cursor_mode, want_cursor, available_modes);

  GVariant *params_for_select_sources = g_variant_new(
      "(oa{sv})", pctx->portal_session_handle_str, &options_builder);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Calling SelectSources for session %s with token %s",
             pctx->portal_session_handle_str,
             pctx->current_portal_request_token_str);

  g_dbus_connection_call(
      pctx->dbus_conn, XDP_BUS_NAME, XDP_OBJECT_PATH, XDP_IFACE_SCREENCAST,
      "SelectSources",
      params_for_select_sources, // This is (oa{sv})
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, pctx->cancellable,
      (GAsyncReadyCallback)on_dbus_method_call_completed_cb, pctx);
}

static void portal_initiate_start_stream(PipeWireScreenPlatformContext *pctx) {
  pctx->current_portal_op_state = PORTAL_OP_STATE_STARTING_STREAM;
  g_free(pctx->current_portal_request_token_str);
  pctx->current_portal_request_token_str = generate_token("miniav_start_req");

  GVariantBuilder options_builder;
  g_variant_builder_init(&options_builder, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(
      &options_builder, "{sv}", "handle_token",
      g_variant_new_string(pctx->current_portal_request_token_str));
  const char *parent_window_handle = "";
  GVariant *params_for_start =
      g_variant_new("(osa{sv})", pctx->portal_session_handle_str,
                    parent_window_handle, &options_builder);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Calling Start for session %s with token %s",
             pctx->portal_session_handle_str,
             pctx->current_portal_request_token_str);

  g_dbus_connection_call(
      pctx->dbus_conn, XDP_BUS_NAME,
      XDP_OBJECT_PATH,      // Object path is the session handle
      XDP_IFACE_SCREENCAST, // Interface is Session
      "Start",
      params_for_start, // This is (sa{sv})
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, pctx->cancellable,
      (GAsyncReadyCallback)on_dbus_method_call_completed_cb, pctx);
}

static void
pw_screen_setup_pipewire_streams(PipeWireScreenPlatformContext *pctx) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Portal interaction successful, proceeding to setup "
             "PipeWire streams.");

  pctx->parent_ctx->app_callback = pctx->app_callback_pending;
  pctx->parent_ctx->app_callback_user_data =
      pctx->app_callback_user_data_pending;
  pctx->app_callback_pending = NULL;
  pctx->app_callback_user_data_pending = NULL;

  if (pctx->video_node_id == PW_ID_ANY) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: No valid video_node_id from portal. Cannot start "
               "PipeWire streams.");
    pctx->last_error = MINIAV_ERROR_PORTAL_FAILED;
    if (pctx->parent_ctx->app_callback) {
      // TODO: Consider how to signal this specific error to the app if needed
    }
    return;
  }

  // --- Create Video Stream ---
  if (pctx->video_node_id != PW_ID_ANY) {
    pctx->video_stream = pw_stream_new(
        pctx->core, "miniav-screen-video",
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY,
                          "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL));
    if (!pctx->video_stream) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to create video stream.");
      pctx->last_error = MINIAV_ERROR_SYSTEM_CALL_FAILED;
      goto error_cleanup_pw_setup;
    }

    static const struct pw_stream_events video_stream_events = {
        PW_VERSION_STREAM_EVENTS,
        .state_changed = on_video_stream_state_changed,
        .param_changed = on_video_stream_param_changed,
        .process = on_video_stream_process,
        .add_buffer = on_video_stream_add_buffer,
        .remove_buffer = on_video_stream_remove_buffer,
    };
    pw_stream_add_listener(pctx->video_stream, &pctx->video_stream_listener,
                           &video_stream_events, pctx);
    uint8_t video_params_buffer[2048];
    struct spa_pod_builder b =
        SPA_POD_BUILDER_INIT(video_params_buffer, sizeof(video_params_buffer));
    const struct spa_pod *params[2];
    uint32_t n_params = 0;

    // 1. SPA_PARAM_Buffers
    uint32_t buffer_types =
        (1 << SPA_DATA_DmaBuf) | (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr);
    params[n_params++] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers,
        SPA_POD_CHOICE_RANGE_Int(PW_SCREEN_MAX_BUFFERS, 1,
                                 PW_SCREEN_MAX_BUFFERS),
        SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1), SPA_PARAM_BUFFERS_dataType,
        SPA_POD_CHOICE_FLAGS_Int(buffer_types));

    // 2. SPA_PARAM_EnumFormat
    enum spa_video_format spa_fmt_req =
        miniav_video_format_to_spa(pctx->requested_video_format.pixel_format);
    if (spa_fmt_req == SPA_VIDEO_FORMAT_UNKNOWN) {
      spa_fmt_req = SPA_VIDEO_FORMAT_BGRA;
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Requested pixel format unknown to SPA, defaulting "
                 "to BGRA for negotiation.");
    }

    struct spa_pod_frame frame_format;
    spa_pod_builder_push_object(&b, &frame_format, SPA_TYPE_OBJECT_Format,
                                SPA_PARAM_EnumFormat);
    uint32_t min_fps =
        SPA_MIN(pctx->requested_video_format.frame_rate_numerator /
                    pctx->requested_video_format.frame_rate_denominator,
                30);
    uint32_t max_fps = pctx->requested_video_format.frame_rate_numerator /
                       pctx->requested_video_format.frame_rate_denominator;

    if (pctx->requested_video_format.output_preference ==
        MINIAV_OUTPUT_PREFERENCE_CPU) {
      spa_pod_builder_add(
          &b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
          SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
          SPA_FORMAT_VIDEO_format, SPA_POD_Id(spa_fmt_req),
          SPA_FORMAT_VIDEO_maxFramerate,
          SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(max_fps, 1),  // preferred
                                        &SPA_FRACTION(min_fps, 1),  // min
                                        &SPA_FRACTION(max_fps, 1)), // max
          0);
    } else {
      spa_pod_builder_add(
          &b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
          SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
          SPA_FORMAT_VIDEO_format, SPA_POD_Id(spa_fmt_req),
          SPA_FORMAT_VIDEO_modifier,
          SPA_POD_CHOICE_FLAGS_Long(0 /* any modifier */),
          SPA_FORMAT_VIDEO_maxFramerate,
          SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(max_fps, 1),  // preferred
                                        &SPA_FRACTION(min_fps, 1),  // min
                                        &SPA_FRACTION(max_fps, 1)), // max
          0);
    }
    params[n_params++] = spa_pod_builder_pop(&b, &frame_format);

    miniav_log(
        MINIAV_LOG_LEVEL_INFO,
        "PW Screen: Requesting video format %s with DRM_FORMAT_MOD_LINEAR.",
        spa_debug_type_find_name(spa_type_video_format, spa_fmt_req));

    if (pw_stream_connect(
            pctx->video_stream, PW_DIRECTION_INPUT, pctx->video_node_id,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
                PW_STREAM_FLAG_RT_PROCESS,
            params, n_params) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to connect video stream to node %u: %s",
                 pctx->video_node_id, spa_strerror(errno));
      pctx->last_error = MINIAV_ERROR_STREAM_FAILED;
      goto error_cleanup_pw_setup;
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Video stream connecting to node %u...",
               pctx->video_node_id);
  } else {
    // This case should be caught earlier by video_node_id == PW_ID_ANY check
  }

  // --- Create Audio Stream ---
  if (pctx->audio_requested_by_user) {
    pctx->audio_stream = pw_stream_new(
        pctx->core, "miniav-screen-audio",
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY,
                          "Capture", PW_KEY_MEDIA_ROLE, "ScreenAudio", NULL));
    if (!pctx->audio_stream) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to create audio stream.");
      pctx->last_error = MINIAV_ERROR_SYSTEM_CALL_FAILED;
      goto error_cleanup_pw_setup; // Cleanup video stream if it was created
    }

    static const struct pw_stream_events audio_stream_events = {
        PW_VERSION_STREAM_EVENTS,
        .state_changed = on_audio_stream_state_changed,
        .param_changed = on_audio_stream_param_changed,
        .process = on_audio_stream_process,
    };
    pw_stream_add_listener(pctx->audio_stream, &pctx->audio_stream_listener,
                           &audio_stream_events, pctx);

    uint8_t audio_params_buffer[1024];
    struct spa_pod_builder audio_b =
        SPA_POD_BUILDER_INIT(audio_params_buffer, sizeof(audio_params_buffer));
    const struct spa_pod *audio_params[1];
    enum spa_audio_format spa_audio_fmt_req =
        miniav_audio_format_to_spa_audio(pctx->requested_audio_format.format);
    if (spa_audio_fmt_req == SPA_AUDIO_FORMAT_UNKNOWN)
      spa_audio_fmt_req = SPA_AUDIO_FORMAT_F32_LE;

    audio_params[0] = spa_format_audio_raw_build(
        &audio_b, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(.format = spa_audio_fmt_req,
                                 .channels =
                                     pctx->requested_audio_format.channels,
                                 .rate =
                                     pctx->requested_audio_format.sample_rate));

    if (pw_stream_connect(pctx->audio_stream, PW_DIRECTION_INPUT,
                          pctx->audio_node_id, // Use the audio_node_id from
                                               // portal if available
                          PW_STREAM_FLAG_AUTOCONNECT |
                              PW_STREAM_FLAG_MAP_BUFFERS |
                              PW_STREAM_FLAG_RT_PROCESS,
                          audio_params, 1) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to connect audio stream to node %u: %s",
                 pctx->audio_node_id, spa_strerror(errno));
      pctx->last_error = MINIAV_ERROR_STREAM_FAILED;
      goto error_cleanup_pw_setup;
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Audio stream connecting to node %u...",
               pctx->audio_node_id);
  }

  // --- Start PipeWire Loop Thread ---
  if (pthread_create(&pctx->loop_thread, NULL, pw_screen_loop_thread_func,
                     pctx->parent_ctx) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to create PipeWire loop thread.");
    pctx->last_error = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto error_cleanup_pw_setup;
  }

  miniav_log(
      MINIAV_LOG_LEVEL_INFO,
      "PW Screen: PipeWire streams configured and loop thread starting.");
  return;

error_cleanup_pw_setup:
  if (pctx->video_stream) {
    pw_stream_destroy(pctx->video_stream);
    pctx->video_stream = NULL;
  }
  if (pctx->audio_stream) {
    pw_stream_destroy(pctx->audio_stream);
    pctx->audio_stream = NULL;
  }
  if (pctx->parent_ctx->app_callback) {
    miniav_log(
        MINIAV_LOG_LEVEL_ERROR,
        "PW Screen: Failed to setup PipeWire streams. Capture will not start.");
  }
  pctx->parent_ctx->is_running = false; // Ensure it's marked as not running
}

static MiniAVResultCode
pw_screen_stop_capture(struct MiniAVScreenContext *ctx) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Stopping capture.");

  // Cancel any ongoing D-Bus portal operations
  if (pctx->cancellable && !g_cancellable_is_cancelled(pctx->cancellable)) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Cancelling pending D-Bus operations.");
    g_cancellable_cancel(pctx->cancellable);
  }

  pctx->app_callback_pending = NULL;
  pctx->app_callback_user_data_pending = NULL;

  if (!pctx->loop_running && !pctx->video_stream_active &&
      !pctx->audio_stream_active) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Capture not running or already stopped.");
    return MINIAV_SUCCESS;
  }

  // Signal the loop thread to clean up streams and quit
  if (pctx->loop_running && pctx->wakeup_pipe[1] != -1) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Signaling PipeWire loop to quit.");
    char buf = 'q'; // quit signal
    if (write(pctx->wakeup_pipe[1], &buf, 1) == -1 && errno != EAGAIN) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Failed to write to wakeup pipe: %s",
                 strerror(errno));
    }
  }

  // Wait for the loop thread to finish (it will clean up streams) — bounded,
  // so a wedged compositor/PipeWire call cannot hang StopCapture forever.
  if (pctx->loop_thread) {
    if (pthread_equal(pctx->loop_thread, pthread_self())) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: StopCapture called from the loop thread — "
                 "skipping self-join (see MiniAVContextLostCallback docs).");
      return MINIAV_ERROR_INVALID_OPERATION;
    }
    if (miniav_timed_join(pctx->loop_thread, 5000) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: loop thread did not exit within 5s — deferring "
                 "(a later Stop/Destroy will retry the join).");
      return MINIAV_ERROR_TIMEOUT; // loop_thread left set for retry
    }
    pctx->loop_thread = 0;
  }

  pctx->loop_running = false;
  pctx->video_stream_active = false;
  pctx->audio_stream_active = false;

  // Streams should have been cleaned up by the loop thread
  if (pctx->video_stream || pctx->audio_stream) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: Streams still exist after loop thread cleanup");
    // Don't clean them up here to avoid context errors
  }

  // Unsubscribe from D-Bus signals before closing session
  if (pctx->current_request_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->current_request_signal_subscription_id);
    pctx->current_request_signal_subscription_id = 0;
  }
  if (pctx->session_closed_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->session_closed_signal_subscription_id);
    pctx->session_closed_signal_subscription_id = 0;
  }

  // Close portal session
  if (pctx->portal_session_handle_str && pctx->dbus_conn) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Closing portal session %s",
               pctx->portal_session_handle_str);
    GError *error = NULL;
    GCancellable *close_cancellable = g_cancellable_new();
    g_dbus_connection_call_sync(
        pctx->dbus_conn, XDP_BUS_NAME, pctx->portal_session_handle_str,
        XDP_IFACE_SESSION, "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE, 5000,
        close_cancellable, &error);
    if (error) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Failed to close portal session: %s",
                 error->message);
      g_error_free(error);
    }
    g_object_unref(close_cancellable);
    g_free(pctx->portal_session_handle_str);
    pctx->portal_session_handle_str = NULL;
  }

  // Clean up portal request strings
  if (pctx->current_portal_request_token_str) {
    g_free(pctx->current_portal_request_token_str);
    pctx->current_portal_request_token_str = NULL;
  }
  if (pctx->current_portal_request_object_path_str) {
    g_free(pctx->current_portal_request_object_path_str);
    pctx->current_portal_request_object_path_str = NULL;
  }

  ctx->is_running = false;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW Screen: Capture stopped.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_destroy_platform(struct MiniAVScreenContext *ctx) {
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;
  if (!pctx)
    return MINIAV_SUCCESS;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Destroying platform context.");

  // Stop capture if still running (this will clean up streams properly)
  if (pctx->loop_running || pctx->video_stream_active ||
      pctx->audio_stream_active) {
    pw_screen_stop_capture(ctx);
  }

  // If a stop attempt timed out, the loop thread is still alive and still
  // dereferences pctx — retry the join here and, if it STILL won't exit,
  // deliberately LEAK the platform context rather than free memory a live
  // thread uses.
  if (pctx->loop_thread) {
    if (miniav_timed_join(pctx->loop_thread, 7000) != 0) {
      // The loop thread also dereferences the parent context —
      // MINIAV_ERROR_TIMEOUT tells MiniAV_Screen_DestroyContext to skip
      // freeing that too.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: loop thread still alive at destroy — leaking "
                 "the context to avoid a use-after-free.");
      ctx->platform_ctx = NULL;
      return MINIAV_ERROR_TIMEOUT;
    }
    pctx->loop_thread = 0;
  }

  // Clean up D-Bus subscriptions first
  if (pctx->current_request_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->current_request_signal_subscription_id);
    pctx->current_request_signal_subscription_id = 0;
  }
  if (pctx->session_closed_signal_subscription_id > 0) {
    g_dbus_connection_signal_unsubscribe(
        pctx->dbus_conn, pctx->session_closed_signal_subscription_id);
    pctx->session_closed_signal_subscription_id = 0;
  }

  // Cancel and cleanup cancellable
  if (pctx->cancellable) {
    if (!g_cancellable_is_cancelled(pctx->cancellable)) {
      g_cancellable_cancel(pctx->cancellable);
    }
    g_object_unref(pctx->cancellable);
    pctx->cancellable = NULL;
  }

  // Clean up remaining PipeWire objects
  if (pctx->core) {
    pw_core_disconnect(pctx->core);
    pctx->core = NULL;
  }
  if (pctx->context) {
    pw_context_destroy(pctx->context);
    pctx->context = NULL;
  }

  // Close wakeup pipe
  if (pctx->wakeup_pipe[0] != -1) {
    close(pctx->wakeup_pipe[0]);
    pctx->wakeup_pipe[0] = -1;
  }
  if (pctx->wakeup_pipe[1] != -1) {
    close(pctx->wakeup_pipe[1]);
    pctx->wakeup_pipe[1] = -1;
  }

  // Clean up D-Bus connection last
  if (pctx->dbus_conn) {
    g_object_unref(pctx->dbus_conn);
    pctx->dbus_conn = NULL;
  }

  // Clean up portal strings
  if (pctx->portal_session_handle_str) {
    g_free(pctx->portal_session_handle_str);
    pctx->portal_session_handle_str = NULL;
  }
  if (pctx->current_portal_request_token_str) {
    g_free(pctx->current_portal_request_token_str);
    pctx->current_portal_request_token_str = NULL;
  }
  if (pctx->current_portal_request_object_path_str) {
    g_free(pctx->current_portal_request_object_path_str);
    pctx->current_portal_request_object_path_str = NULL;
  }

  // Stop the GLib main loop thread — bounded so a wedged GLib dispatch can't
  // hang DestroyContext. On timeout the thread is DETACHED and the loop ref
  // deliberately leaked (quit was already requested, so the thread exits and
  // self-reaps whenever it unwedges); gloop_thread is cleared so the next
  // context init doesn't clobber a still-joinable thread id.
  if (gloop) {
    g_main_loop_quit(gloop);
    if (gloop_thread) {
      if (miniav_timed_join(gloop_thread, 5000) != 0) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Screen: GLib loop thread did not exit within 5s — "
                   "detaching it and leaking the GLib loop.");
        pthread_detach(gloop_thread);
        gloop_thread = 0;
        gloop = NULL; // leak the ref; the detached thread still runs on it
      } else {
        gloop_thread = 0;
        g_main_loop_unref(gloop);
        gloop = NULL;
      }
    } else {
      g_main_loop_unref(gloop);
      gloop = NULL;
    }
  }

  miniav_free(pctx);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_screen_release_buffer(struct MiniAVScreenContext *ctx,
                         void *internal_handle_ptr) {
  MINIAV_UNUSED(ctx);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: release_buffer called with internal_handle_ptr=%p",
             internal_handle_ptr);

  if (!internal_handle_ptr) {
    miniav_log(
        MINIAV_LOG_LEVEL_DEBUG,
        "PW Screen: release_buffer called with NULL internal_handle_ptr.");
    return MINIAV_SUCCESS;
  }

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: payload ptr=%p, handle_type=%d, "
             "native_singular_resource_ptr=%p, num_planar_resources=%u",
             payload, payload->handle_type,
             payload->native_singular_resource_ptr,
             payload->num_planar_resources_to_release);

  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN) {

    // Handle multi-plane resources (rarely used for screen capture, but
    // supported)
    if (payload->num_planar_resources_to_release > 0) {
      for (uint32_t i = 0; i < payload->num_planar_resources_to_release; ++i) {
        if (payload->native_planar_resource_ptrs[i]) {
          // For screen capture, this would typically be additional DMA-BUF FDs
          int fd = (int)(intptr_t)payload->native_planar_resource_ptrs[i];
          if (fd > 0) {
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Screen: Closing planar DMA-BUF FD: %d", fd);
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
                       "PW Screen: Freeing CPU buffer from DMABUF/MemFd copy.");
            miniav_free(frame_payload->cpu.cpu_ptr);
            frame_payload->cpu.cpu_ptr = NULL;
          }
          // src_dmabuf_fd is not owned, do not close
        } else if (frame_payload->type == MINIAV_OUTPUT_PREFERENCE_GPU) {
          if (frame_payload->gpu.dup_dmabuf_fd > 0) {
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "PW Screen: Closing duplicated DMABUF FD: %d",
                       frame_payload->gpu.dup_dmabuf_fd);
            if (close(frame_payload->gpu.dup_dmabuf_fd) == -1) {
              miniav_log(MINIAV_LOG_LEVEL_WARN,
                         "PW Screen: Failed to close DMABUF FD %d: %s",
                         frame_payload->gpu.dup_dmabuf_fd, strerror(errno));
            }
            frame_payload->gpu.dup_dmabuf_fd = -1;
          }
        } else {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "PW Screen: release_buffer: Unknown frame_payload type %d",
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
  } else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_AUDIO) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Releasing audio buffer with copied data.");

    // Free the copied audio data
    if (payload->native_singular_resource_ptr) {
      miniav_free(payload->native_singular_resource_ptr);
      payload->native_singular_resource_ptr = NULL;
    }

    if (payload->parent_miniav_buffer_ptr) {
      miniav_free(payload->parent_miniav_buffer_ptr);
      payload->parent_miniav_buffer_ptr = NULL;
    }
    miniav_free(payload);
    return MINIAV_SUCCESS;
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Screen: release_buffer called for unknown handle_type %d.",
               payload->handle_type);
    if (payload->parent_miniav_buffer_ptr) {
      miniav_free(payload->parent_miniav_buffer_ptr);
      payload->parent_miniav_buffer_ptr = NULL;
    }
    miniav_free(payload);
    return MINIAV_SUCCESS;
  }
}

// --- PipeWire Thread and Event Handlers ---

static void on_wakeup_pipe_event(void *data, int fd, uint32_t mask) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  char buf[16];
  ssize_t len;

  while ((len = read(fd, buf, sizeof(buf) - 1)) > 0) {
    buf[len] = '\0';
    for (int i = 0; i < len; i++) {
      switch (buf[i]) {
      case 'q': // Quit signal
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Screen: Quit signal received in loop thread");

        // Clean up streams in the correct thread context
        if (pctx->video_stream) {
          pw_stream_set_active(pctx->video_stream, false);
          pw_stream_disconnect(pctx->video_stream);
          pw_stream_destroy(pctx->video_stream);
          pctx->video_stream = NULL;
        }
        if (pctx->audio_stream) {
          pw_stream_set_active(pctx->audio_stream, false);
          pw_stream_disconnect(pctx->audio_stream);
          pw_stream_destroy(pctx->audio_stream);
          pctx->audio_stream = NULL;
        }

        pw_main_loop_quit(pctx->loop);
        return;
      case 'e': // Error signal
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Error signal received");
        pw_main_loop_quit(pctx->loop);
        return;
      case 's': // Stop signal (clean stop)
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Stop signal received");
        if (pctx->video_stream) {
          pw_stream_set_active(pctx->video_stream, false);
        }
        if (pctx->audio_stream) {
          pw_stream_set_active(pctx->audio_stream, false);
        }
        // Don't quit loop immediately, let streams finish cleanly
        break;
      }
    }
  }

  if (len == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Screen: Wakeup pipe EOF");
    pw_main_loop_quit(pctx->loop);
  } else if (len < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Screen: Wakeup pipe read error: %s",
               strerror(errno));
    pw_main_loop_quit(pctx->loop);
  }
}

static void *pw_screen_loop_thread_func(void *arg) {
  struct MiniAVScreenContext *ctx = (struct MiniAVScreenContext *)arg;
  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)ctx->platform_ctx;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: PipeWire loop thread started.");
  pctx->loop_running = true;
  ctx->is_running = true;

  // Add wakeup pipe to the loop
  struct pw_loop *loop_ptr = pw_main_loop_get_loop(pctx->loop);
  struct spa_source *wakeup_source = NULL;

  if (pctx->wakeup_pipe[0] != -1) {
    wakeup_source = pw_loop_add_io(loop_ptr, pctx->wakeup_pipe[0], SPA_IO_IN,
                                   false, on_wakeup_pipe_event, pctx);
    if (!wakeup_source) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to add wakeup IO source");
    }
  }

  pw_main_loop_run(pctx->loop); // Blocks here

  if (wakeup_source) {
    pw_loop_remove_source(loop_ptr, wakeup_source);
  }

  pctx->loop_running = false;
  ctx->is_running = false;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: PipeWire loop thread finished.");
  return NULL;
}

// --- Core Listener Callbacks ---
static void on_pw_core_info(void *data, const struct pw_core_info *info) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Core info: id=%u, cookie=%u, name='%s', version='%s'",
             info->id, info->cookie, info->name ? info->name : "(null)",
             info->props ? spa_dict_lookup(info->props, PW_KEY_CORE_VERSION)
                         : "N/A");
  pctx->core_connected = true;
}

static void on_pw_core_done(void *data, uint32_t id, int seq) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Core done: id=%u, seq=%d", id,
             seq);
  if (id == PW_ID_CORE && seq == pctx->core_sync_seq) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Core sync complete.");
  }
}
static void on_pw_core_error(void *data, uint32_t id, int seq, int res,
                             const char *message) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(
      MINIAV_LOG_LEVEL_ERROR,
      "PW Screen: Core error: id=%u, source_id=%u, seq=%d, res=%d (%s): %s", id,
      PW_ID_CORE, seq, res, spa_strerror(res), message);
  pctx->last_error = MINIAV_ERROR_SYSTEM_CALL_FAILED;
  if (pctx->loop_running && pctx->loop) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Quitting main loop due to core error.");
    pw_main_loop_quit(pctx->loop);
  }
  pctx->parent_ctx->is_running = false;
}

// --- Video Stream Listener Callbacks ---
static void on_video_stream_state_changed(void *data, enum pw_stream_state old,
                                          enum pw_stream_state new_state,
                                          const char *error) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Video stream state changed from %s to %s.",
             pw_stream_state_as_string(old),
             pw_stream_state_as_string(new_state));

  switch (new_state) {
  case PW_STREAM_STATE_ERROR:
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Screen: Video stream error: %s",
               error ? error : "Unknown");
    pctx->video_stream_active = false;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    pctx->last_error = MINIAV_ERROR_STREAM_FAILED;
    if (pctx->loop_running && pctx->wakeup_pipe[1] != -1)
      write(pctx->wakeup_pipe[1], "e", 1);
    break;
  case PW_STREAM_STATE_UNCONNECTED:
    pctx->video_stream_active = false;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    if (old == PW_STREAM_STATE_CONNECTING || old == PW_STREAM_STATE_PAUSED ||
        old == PW_STREAM_STATE_STREAMING) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Video stream became unconnected.");
      if (pctx->last_error == MINIAV_SUCCESS)
        pctx->last_error = MINIAV_ERROR_STREAM_FAILED;
    }
    break;
  case PW_STREAM_STATE_CONNECTING:
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Screen: Video stream connecting...");
    break;
  case PW_STREAM_STATE_PAUSED:
    miniav_log(
        MINIAV_LOG_LEVEL_DEBUG,
        "PW Screen: Video stream paused (format negotiated, buffers ready).");
    if (pw_stream_set_active(pctx->video_stream, true) < 0) {
      miniav_log(
          MINIAV_LOG_LEVEL_ERROR,
          "PW Screen: Failed to set video stream active from PAUSED state.");
      pctx->last_error = MINIAV_ERROR_STREAM_FAILED;
    }
    break;
  case PW_STREAM_STATE_STREAMING:
    pctx->video_stream_active = true;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "PW Screen: Video stream is now streaming.");
    pctx->last_error =
        MINIAV_SUCCESS; // Clear previous errors if streaming starts
    break;
  }
}

static void on_video_stream_param_changed(void *data, uint32_t id,
                                          const struct spa_pod *param) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  if (!param || id != SPA_PARAM_Format) {
    return;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Video stream SPA_PARAM_Format received.");

  enum spa_media_type parsed_media_type;
  enum spa_media_subtype parsed_media_subtype;

  if (spa_format_parse(param, &parsed_media_type, &parsed_media_subtype) < 0) {
    miniav_log(
        MINIAV_LOG_LEVEL_ERROR,
        "PW Screen: Failed to parse media type/subtype for video format.");
    // Ensure current format is marked as unknown to prevent using
    // stale/invalid data
    pctx->current_video_format_details.spa_format.format =
        SPA_VIDEO_FORMAT_UNKNOWN;
    pctx->current_video_format_details.derived_num_planes = 0;
    pctx->parent_ctx->configured_video_format.pixel_format =
        MINIAV_PIXEL_FORMAT_UNKNOWN;
    pctx->parent_ctx->configured_video_format.width = 0;
    pctx->parent_ctx->configured_video_format.height = 0;
    return;
  }

  if (parsed_media_type != SPA_MEDIA_TYPE_video ||
      parsed_media_subtype != SPA_MEDIA_SUBTYPE_raw) {
    struct spa_video_info_dsp format_info_dsp = {0};
    if (spa_format_video_dsp_parse(param, &format_info_dsp) == 0) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Parsed as DSP video format (unexpected for raw "
                 "screen capture). Format: %u",
                 format_info_dsp.format);
    } else {
      miniav_log(
          MINIAV_LOG_LEVEL_ERROR,
          "PW Screen: Received non-raw video format (%s/%s) and failed to "
          "parse as DSP.",
          spa_debug_type_find_name(spa_type_media_type, parsed_media_type),
          spa_debug_type_find_name(spa_type_media_subtype,
                                   parsed_media_subtype));
    }
    pctx->current_video_format_details.spa_format.format =
        SPA_VIDEO_FORMAT_UNKNOWN;
    pctx->current_video_format_details.derived_num_planes = 0;
    pctx->parent_ctx->configured_video_format.pixel_format =
        MINIAV_PIXEL_FORMAT_UNKNOWN;
    pctx->parent_ctx->configured_video_format.width = 0;
    pctx->parent_ctx->configured_video_format.height = 0;
    return;
  }

  // It's raw video, parse the detailed parameters
  if (spa_format_video_raw_parse(
          param, &pctx->current_video_format_details.spa_format) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to parse spa_video_info_raw for raw video.");
    pctx->current_video_format_details.spa_format.format =
        SPA_VIDEO_FORMAT_UNKNOWN;
    pctx->current_video_format_details.derived_num_planes = 0;
    pctx->parent_ctx->configured_video_format.pixel_format =
        MINIAV_PIXEL_FORMAT_UNKNOWN;
    pctx->parent_ctx->configured_video_format.width = 0;
    pctx->parent_ctx->configured_video_format.height = 0;
    return;
  }

  // Validate parsed dimensions
  if (pctx->current_video_format_details.spa_format.size.width == 0 ||
      pctx->current_video_format_details.spa_format.size.height == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Parsed video format has zero dimensions (%ux%u). "
               "Treating as invalid.",
               pctx->current_video_format_details.spa_format.size.width,
               pctx->current_video_format_details.spa_format.size.height);
    pctx->current_video_format_details.spa_format.format =
        SPA_VIDEO_FORMAT_UNKNOWN; // Mark as invalid
    pctx->current_video_format_details.derived_num_planes = 0;
    pctx->parent_ctx->configured_video_format.pixel_format =
        MINIAV_PIXEL_FORMAT_UNKNOWN;
    pctx->parent_ctx->configured_video_format.width = 0;
    pctx->parent_ctx->configured_video_format.height = 0;
    return;
  }

  // Proceed only if we have a successfully parsed and validated raw video
  // format
  if (pctx->current_video_format_details.spa_format.format !=
      SPA_VIDEO_FORMAT_UNKNOWN) {
    pctx->current_video_format_details.negotiated_modifier =
        pctx->current_video_format_details.spa_format.modifier;

    MiniAVPixelFormat miniav_fmt = spa_video_format_to_miniav(
        pctx->current_video_format_details.spa_format.format);
    pctx->current_video_format_details.derived_num_planes =
        get_miniav_pixel_format_planes(miniav_fmt);

    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "PW Screen: Negotiated video format: %s (MiniAV: %d), %ux%u @ "
               "%u/%u fps, derived_planes: %u, modifier: %" PRIu64,
               spa_debug_type_find_name(
                   spa_type_video_format,
                   pctx->current_video_format_details.spa_format.format),
               miniav_fmt,
               pctx->current_video_format_details.spa_format.size.width,
               pctx->current_video_format_details.spa_format.size.height,
               pctx->current_video_format_details.spa_format.framerate.num,
               pctx->current_video_format_details.spa_format.framerate.denom,
               pctx->current_video_format_details.derived_num_planes,
               pctx->current_video_format_details.negotiated_modifier);

    // Update parent context's view of the format (MiniAVVideoInfo)
    pctx->parent_ctx->configured_video_format.pixel_format = miniav_fmt;
    pctx->parent_ctx->configured_video_format.width =
        pctx->current_video_format_details.spa_format.size.width;
    pctx->parent_ctx->configured_video_format.height =
        pctx->current_video_format_details.spa_format.size.height;
    pctx->parent_ctx->configured_video_format.frame_rate_numerator =
        pctx->current_video_format_details.spa_format.framerate.num;
    pctx->parent_ctx->configured_video_format.frame_rate_denominator =
        pctx->current_video_format_details.spa_format.framerate.denom;
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Screen: Video format is unknown or "
                                      "not usable after param changed.");
    pctx->parent_ctx->configured_video_format.pixel_format =
        MINIAV_PIXEL_FORMAT_UNKNOWN;
    pctx->parent_ctx->configured_video_format.width = 0;
    pctx->parent_ctx->configured_video_format.height = 0;
    pctx->current_video_format_details.derived_num_planes = 0;
  }
}

static void on_video_stream_add_buffer(void *data, struct pw_buffer *buffer) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  struct spa_buffer *spa_buf = buffer->buffer;

  if (spa_buf->n_datas == 0)
    return;

  for (int i = 0; i < PW_SCREEN_MAX_BUFFERS; ++i) {
    if (pctx->video_pw_buffers[i] == NULL) {
      pctx->video_pw_buffers[i] = buffer; // Store PipeWire's buffer pointer
      if (spa_buf->datas[0].type == SPA_DATA_DmaBuf ||
          spa_buf->datas[0].type == SPA_DATA_MemFd) {
        pctx->video_dmabuf_fds[i] =
            spa_buf->datas[0].fd; // Store original FD (owned by PW)
        pctx->current_video_format_details.is_dmabuf = true;
        miniav_log(
            MINIAV_LOG_LEVEL_DEBUG,
            "PW Screen: Video add_buffer (idx %d): type %s, FD %ld, size %u", i,
            spa_debug_type_find_name(spa_type_data_type,
                                     spa_buf->datas[0].type),
            spa_buf->datas[0].fd, spa_buf->datas[0].maxsize);
      } else {
        pctx->current_video_format_details.is_dmabuf = false;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Screen: Video add_buffer (idx %d): type %s (CPU "
                   "path), size %u",
                   i,
                   spa_debug_type_find_name(spa_type_data_type,
                                            spa_buf->datas[0].type),
                   spa_buf->datas[0].maxsize);
      }
      break;
    }
  }
}

static void on_video_stream_remove_buffer(void *data,
                                          struct pw_buffer *buffer) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Video remove_buffer for pw_buffer %p", (void *)buffer);
  for (int i = 0; i < PW_SCREEN_MAX_BUFFERS; ++i) {
    if (pctx->video_pw_buffers[i] == buffer) {
      pctx->video_pw_buffers[i] = NULL;
      pctx->video_dmabuf_fds[i] = -1; // Clear stored original FD
      break;
    }
  }
}

static void on_video_stream_process(void *data) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  struct pw_buffer *pw_buf;
  MiniAVNativeBufferInternalPayload *payload_alloc = NULL;

  if (!pctx->parent_ctx->app_callback || !pctx->video_stream_active)
    return;

  while ((pw_buf = pw_stream_dequeue_buffer(pctx->video_stream))) {
    struct spa_buffer *spa_buf = pw_buf->buffer;
    payload_alloc = NULL;

    if (spa_buf->n_datas < 1) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Video buffer has no data planes.");
      goto queue_and_continue_video;
    }

    // ALLOCATE BUFFER ON HEAP - This was the issue!
    MiniAVBuffer *miniav_buffer =
        (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
    if (!miniav_buffer) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to allocate MiniAVBuffer");
      goto queue_and_continue_video;
    }

    miniav_buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
    miniav_buffer->user_data = pctx->parent_ctx->app_callback_user_data;
    miniav_buffer->timestamp_us = miniav_get_time_us();
    miniav_buffer->data.video.info = pctx->parent_ctx->configured_video_format;

    PipeWireFrameReleasePayload *frame_payload =
        miniav_calloc(1, sizeof(PipeWireFrameReleasePayload));
    if (!frame_payload) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to alloc PipeWireFrameReleasePayload.");
      miniav_free(miniav_buffer); // Clean up the buffer we just allocated
      goto queue_and_continue_video;
    }

    int buf_type = spa_buf->datas[0].type;
    int fd = spa_buf->datas[0].fd;
    size_t size = spa_buf->datas[0].maxsize;

    MiniAVPixelFormat format =
        pctx->parent_ctx->configured_video_format.pixel_format;
    uint32_t width = pctx->parent_ctx->configured_video_format.width;
    uint32_t height = pctx->parent_ctx->configured_video_format.height;

    bool success = false;

    if (buf_type == SPA_DATA_DmaBuf) {
      // --- DMA-BUF path ---
      if (pctx->requested_video_format.output_preference ==
          MINIAV_OUTPUT_PREFERENCE_CPU) {
        if (pctx->current_video_format_details.negotiated_modifier !=
            DRM_FORMAT_MOD_LINEAR) {
          miniav_log(
              MINIAV_LOG_LEVEL_ERROR,
              "PW Screen: DMABUF has non-linear modifier (%" PRIu64
              "). Cannot directly mmap for CPU pixel copy. Skipping frame.",
              pctx->current_video_format_details.negotiated_modifier);
          miniav_free(frame_payload);
          miniav_free(miniav_buffer);
          goto queue_and_continue_video;
        }
        void *mapped = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
        if (mapped == MAP_FAILED) {
          miniav_log(MINIAV_LOG_LEVEL_ERROR,
                     "PW Screen: Failed to mmap DMABUF for CPU copy: %s. "
                     "Modifier: %" PRIu64,
                     strerror(errno),
                     pctx->current_video_format_details.negotiated_modifier);
          miniav_free(frame_payload);
          miniav_free(miniav_buffer);
          goto queue_and_continue_video;
        }

        struct dma_buf_sync sync_args;
        int ret;
        sync_args.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
        do {
          ret = ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync_args);
        } while (ret == -1 && (errno == EAGAIN || errno == EINTR));
        if (ret == -1) {
          if (errno == ENOTTY) {
            miniav_log(MINIAV_LOG_LEVEL_WARN,
                       "PW Screen: DMA_BUF_IOCTL_SYNC not supported on this "
                       "buffer. Proceeding without sync.");
          } else {
            miniav_log(MINIAV_LOG_LEVEL_ERROR,
                       "PW Screen: DMA_BUF_IOCTL_SYNC (START) failed: %s. "
                       "Skipping frame.",
                       strerror(errno));
            munmap(mapped, size);
            miniav_free(frame_payload);
            miniav_free(miniav_buffer);
            goto queue_and_continue_video;
          }
        }

        uint8_t *cpu_copy = (uint8_t *)miniav_calloc(1, size);
        if (!cpu_copy) {
          miniav_log(MINIAV_LOG_LEVEL_ERROR,
                     "PW Screen: Failed to alloc CPU buffer for DMABUF copy.");
          sync_args.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
          ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync_args);
          munmap(mapped, size);
          miniav_free(frame_payload);
          miniav_free(miniav_buffer);
          goto queue_and_continue_video;
        }
        memcpy(cpu_copy, mapped, size);
        sync_args.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
        ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync_args);
        munmap(mapped, size);

        miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;

        // Set up CPU plane pointers based on format
        setup_cpu_planes_for_format(miniav_buffer, format, width, height,
                                    cpu_copy, size);

        miniav_buffer->data_size_bytes = size;

        frame_payload->type = MINIAV_OUTPUT_PREFERENCE_CPU;
        frame_payload->cpu.cpu_ptr = cpu_copy;
        frame_payload->cpu.cpu_size = size;
        frame_payload->cpu.src_dmabuf_fd = fd;
        success = true;

        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Screen: DMABUF (linear, synced) mapped and copied to "
                   "CPU buffer for app.");
      } else {
        // --- GPU path: pass DMABUF FD ---
        int dup_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (dup_fd == -1) {
          miniav_log(
              MINIAV_LOG_LEVEL_ERROR,
              "PW Screen: Failed to dup DMABUF FD %d: %s. Skipping frame.", fd,
              strerror(errno));
          miniav_free(frame_payload);
          miniav_free(miniav_buffer);
          goto queue_and_continue_video;
        }

        miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_DMABUF_FD;

        // Set up GPU plane pointers based on format
        setup_gpu_planes_for_format(miniav_buffer, format, width, height,
                                    dup_fd, size);

        miniav_buffer->data_size_bytes = size;

        frame_payload->type = MINIAV_OUTPUT_PREFERENCE_GPU;
        frame_payload->gpu.dup_dmabuf_fd = dup_fd;
        success = true;

        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Screen: DMABUF frame: FD %d (orig %d), ts %" PRIu64 "us",
                   dup_fd, fd, miniav_buffer->timestamp_us);
      }
    } else if (buf_type == SPA_DATA_MemFd) {
      // --- MemFd path ---
      void *mapped = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
      if (mapped == MAP_FAILED) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Screen: Failed to mmap MemFd: %s", strerror(errno));
        miniav_free(frame_payload);
        miniav_free(miniav_buffer);
        goto queue_and_continue_video;
      }
      uint8_t *cpu_copy = (uint8_t *)miniav_calloc(1, size);
      if (!cpu_copy) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Screen: Failed to alloc CPU buffer for MemFd copy.");
        munmap(mapped, size);
        miniav_free(frame_payload);
        miniav_free(miniav_buffer);
        goto queue_and_continue_video;
      }
      memcpy(cpu_copy, mapped, size);
      munmap(mapped, size);

      miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;

      // Set up CPU plane pointers based on format
      setup_cpu_planes_for_format(miniav_buffer, format, width, height,
                                  cpu_copy, size);

      miniav_buffer->data_size_bytes = size;

      frame_payload->type = MINIAV_OUTPUT_PREFERENCE_CPU;
      frame_payload->cpu.cpu_ptr = cpu_copy;
      frame_payload->cpu.cpu_size = size;
      frame_payload->cpu.src_dmabuf_fd = fd;
      success = true;

      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: MemFd mapped and copied to CPU buffer for app.");
    } else if (buf_type == SPA_DATA_MemPtr) {
      // --- MemPtr path ---
      miniav_buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;

      // Set up CPU plane pointers based on format - direct pointer to PipeWire
      // data
      setup_cpu_planes_for_format(miniav_buffer, format, width, height,
                                  spa_buf->datas[0].data, size);

      miniav_buffer->data_size_bytes = size;

      frame_payload->type = MINIAV_OUTPUT_PREFERENCE_CPU;
      frame_payload->cpu.cpu_ptr = NULL; // Direct pointer, don't copy
      frame_payload->cpu.cpu_size = size;
      frame_payload->cpu.src_dmabuf_fd = -1;
      success = true;

      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Screen: MemPtr buffer passed directly to app.");
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Screen: Unhandled buffer type %d",
                 buf_type);
      miniav_free(frame_payload);
      miniav_free(miniav_buffer);
      goto queue_and_continue_video;
    }

    if (!success) {
      miniav_free(frame_payload);
      miniav_free(miniav_buffer);
      goto queue_and_continue_video;
    }

    // Attach the payload to the MiniAV buffer
    payload_alloc = miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
    if (!payload_alloc) {
      miniav_log(
          MINIAV_LOG_LEVEL_ERROR,
          "PW Screen: Failed to alloc MiniAVNativeBufferInternalPayload.");
      if (frame_payload->type == MINIAV_OUTPUT_PREFERENCE_CPU &&
          frame_payload->cpu.cpu_ptr)
        miniav_free(frame_payload->cpu.cpu_ptr);
      else if (frame_payload->type == MINIAV_OUTPUT_PREFERENCE_GPU &&
               frame_payload->gpu.dup_dmabuf_fd > 0)
        close(frame_payload->gpu.dup_dmabuf_fd);
      miniav_free(frame_payload);
      miniav_free(miniav_buffer);
      goto queue_and_continue_video;
    }
    payload_alloc->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
    payload_alloc->context_owner = pctx->parent_ctx;
    payload_alloc->native_singular_resource_ptr = frame_payload;
    payload_alloc->num_planar_resources_to_release = 0;
    payload_alloc->parent_miniav_buffer_ptr =
        miniav_buffer; // Store pointer to heap buffer
    miniav_buffer->internal_handle = payload_alloc;

    // Deliver to app
    MINIAV_SAFE_DISPATCH(pctx->parent_ctx->app_callback(
        miniav_buffer, pctx->parent_ctx->app_callback_user_data));
    payload_alloc = NULL; // Ownership passed to app

  queue_and_continue_video:
    if (payload_alloc) {
      PipeWireFrameReleasePayload *fp =
          (PipeWireFrameReleasePayload *)
              payload_alloc->native_singular_resource_ptr;
      if (fp) {
        if (fp->type == MINIAV_OUTPUT_PREFERENCE_CPU && fp->cpu.cpu_ptr)
          miniav_free(fp->cpu.cpu_ptr);
        else if (fp->type == MINIAV_OUTPUT_PREFERENCE_GPU &&
                 fp->gpu.dup_dmabuf_fd > 0)
          close(fp->gpu.dup_dmabuf_fd);
        miniav_free(fp);
      }
      if (payload_alloc->parent_miniav_buffer_ptr) {
        miniav_free(payload_alloc->parent_miniav_buffer_ptr);
      }
      miniav_free(payload_alloc);
    }
    pw_stream_queue_buffer(pctx->video_stream, pw_buf);
  }
}

// --- Audio Stream Listener Callbacks ---
static void on_audio_stream_state_changed(void *data, enum pw_stream_state old,
                                          enum pw_stream_state new_state,
                                          const char *error) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Audio stream state changed from %s to %s.",
             pw_stream_state_as_string(old),
             pw_stream_state_as_string(new_state));
  switch (new_state) {
  case PW_STREAM_STATE_ERROR:
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Screen: Audio stream error: %s",
               error ? error : "Unknown");
    pctx->audio_stream_active = false;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    break;
  case PW_STREAM_STATE_UNCONNECTED:
    pctx->audio_stream_active = false;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    if (old == PW_STREAM_STATE_CONNECTING || old == PW_STREAM_STATE_PAUSED ||
        old == PW_STREAM_STATE_STREAMING) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "PW Screen: Audio stream became unconnected.");
    }
    break;
  case PW_STREAM_STATE_CONNECTING:
    break;
  case PW_STREAM_STATE_PAUSED:
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Audio stream paused (format negotiated).");
    if (pw_stream_set_active(pctx->audio_stream, true) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to set audio stream active from PAUSED.");
    }
    break;
  case PW_STREAM_STATE_STREAMING:
    pctx->audio_stream_active = true;
    pctx->parent_ctx->is_running =
        pctx->video_stream_active || pctx->audio_stream_active;
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "PW Screen: Audio stream is now streaming.");
    break;
  }
}

static void on_audio_stream_param_changed(void *data, uint32_t id,
                                          const struct spa_pod *param) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  if (!param || id != SPA_PARAM_Format) {
    return;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Audio stream SPA_PARAM_Format received.");

  if (spa_format_audio_raw_parse(param, &pctx->current_audio_format) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to parse audio SPA_PARAM_Format.");
    // Mark parent context's audio format as unknown
    if (pctx->parent_ctx) {
      pctx->parent_ctx->configured_audio_format.format =
          MINIAV_AUDIO_FORMAT_UNKNOWN;
      pctx->parent_ctx->configured_audio_format.channels = 0;
      pctx->parent_ctx->configured_audio_format.sample_rate = 0;
    }
    return;
  }
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW Screen: Negotiated audio format: %s, %u channels, %u Hz",
             spa_debug_type_find_name(spa_type_audio_format,
                                      pctx->current_audio_format.format),
             pctx->current_audio_format.channels,
             pctx->current_audio_format.rate);

  if (pctx->parent_ctx) {
    pctx->parent_ctx->configured_audio_format.format =
        spa_audio_format_to_miniav_audio(pctx->current_audio_format.format);
    pctx->parent_ctx->configured_audio_format.channels =
        pctx->current_audio_format.channels;
    pctx->parent_ctx->configured_audio_format.sample_rate =
        pctx->current_audio_format.rate;
  }
}

static void on_audio_stream_process(void *data) {
  PipeWireScreenPlatformContext *pctx = (PipeWireScreenPlatformContext *)data;
  struct pw_buffer *pw_buf;
  MiniAVNativeBufferInternalPayload *payload_alloc = NULL;

  if (!pctx->parent_ctx->app_callback || !pctx->audio_stream_active)
    return;

  while ((pw_buf = pw_stream_dequeue_buffer(pctx->audio_stream))) {
    struct spa_buffer *spa_buf = pw_buf->buffer;
    struct spa_meta_header *h;
    payload_alloc = NULL; // Reset for each buffer

    if (spa_buf->n_datas < 1 || !spa_buf->datas[0].data ||
        spa_buf->datas[0].chunk->size == 0) {
      goto queue_audio_and_continue;
    }

    // ALLOCATE AUDIO BUFFER ON HEAP - This was stack allocated!
    MiniAVBuffer *miniav_buffer =
        (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
    if (!miniav_buffer) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to allocate audio MiniAVBuffer");
      goto queue_audio_and_continue;
    }

    miniav_buffer->type = MINIAV_BUFFER_TYPE_AUDIO;
    miniav_buffer->user_data = pctx->parent_ctx->app_callback_user_data;

    if ((h = spa_buffer_find_meta_data(spa_buf, SPA_META_Header, sizeof(*h))) &&
        h->pts != SPA_ID_INVALID) {
      miniav_buffer->timestamp_us = h->pts / 1000; // pts is usually nsec
    } else if (pw_buf->time !=
               SPA_ID_INVALID) { // pw_buf->time is uint64_t nsec
      miniav_buffer->timestamp_us = pw_buf->time / 1000; // Convert nsec to usec
    } else {
      miniav_buffer->timestamp_us = miniav_get_time_us();
    }

    miniav_buffer->content_type =
        MINIAV_BUFFER_CONTENT_TYPE_CPU; // Audio is always CPU for now

    if (pctx->parent_ctx) {
      miniav_buffer->data.audio.info =
          pctx->parent_ctx->configured_audio_format;
    } else {
      memset(&miniav_buffer->data.audio.info, 0, sizeof(MiniAVAudioInfo));
      miniav_buffer->data.audio.info.format = MINIAV_AUDIO_FORMAT_UNKNOWN;
    }

    // For audio, we need to copy the data since it's from PipeWire's buffer
    uint8_t *audio_data_copy =
        (uint8_t *)miniav_calloc(1, spa_buf->datas[0].chunk->size);
    if (!audio_data_copy) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to allocate audio data copy");
      miniav_free(miniav_buffer);
      goto queue_audio_and_continue;
    }

    memcpy(audio_data_copy,
           (uint8_t *)spa_buf->datas[0].data + spa_buf->datas[0].chunk->offset,
           spa_buf->datas[0].chunk->size);

    miniav_buffer->data.audio.data = audio_data_copy;
    miniav_buffer->data_size_bytes = spa_buf->datas[0].chunk->size;

    // Calculate frame_count
    uint32_t bytes_per_sample_times_channels = 0;
    uint32_t bytes_per_sample = 0;
    switch (miniav_buffer->data.audio.info.format) {
    case MINIAV_AUDIO_FORMAT_U8:
      bytes_per_sample = 1;
      break;
    case MINIAV_AUDIO_FORMAT_S16:
      bytes_per_sample = 2;
      break;
    case MINIAV_AUDIO_FORMAT_S32:
      bytes_per_sample = 4;
      break;
    case MINIAV_AUDIO_FORMAT_F32:
      bytes_per_sample = 4;
      break;
    default:
      break;
    }
    if (miniav_buffer->data.audio.info.channels > 0 && bytes_per_sample > 0) {
      bytes_per_sample_times_channels =
          miniav_buffer->data.audio.info.channels * bytes_per_sample;
      miniav_buffer->data.audio.frame_count =
          miniav_buffer->data_size_bytes / bytes_per_sample_times_channels;
    } else {
      miniav_buffer->data.audio.frame_count = 0;
    }

    payload_alloc = (MiniAVNativeBufferInternalPayload *)miniav_calloc(
        1, sizeof(MiniAVNativeBufferInternalPayload));
    if (!payload_alloc) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Screen: Failed to allocate payload for audio buffer.");
      miniav_free(audio_data_copy);
      miniav_free(miniav_buffer);
      goto queue_audio_and_continue;
    }
    payload_alloc->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
    payload_alloc->context_owner = pctx->parent_ctx;
    payload_alloc->native_singular_resource_ptr =
        audio_data_copy; // Store the copied data
    payload_alloc->parent_miniav_buffer_ptr =
        miniav_buffer; // Store pointer to heap buffer
    miniav_buffer->internal_handle = payload_alloc;

    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Screen: Audio frame, size %u, frames %u, ts %" PRIu64 "us",
               miniav_buffer->data_size_bytes,
               miniav_buffer->data.audio.frame_count,
               miniav_buffer->timestamp_us);
    MINIAV_SAFE_DISPATCH(pctx->parent_ctx->app_callback(
        miniav_buffer, pctx->parent_ctx->app_callback_user_data));
    payload_alloc = NULL; // Callback owns it now

  queue_audio_and_continue:
    if (payload_alloc) { // If we allocated but didn't send to callback
      if (payload_alloc->native_singular_resource_ptr) {
        miniav_free(payload_alloc->native_singular_resource_ptr);
      }
      if (payload_alloc->parent_miniav_buffer_ptr) {
        miniav_free(payload_alloc->parent_miniav_buffer_ptr);
      }
      miniav_free(payload_alloc);
    }
    pw_stream_queue_buffer(pctx->audio_stream, pw_buf);
  }
}

// --- Ops Structure Definition ---
const ScreenContextInternalOps g_screen_ops_linux_pipewire = {
    .init_platform = pw_screen_init_platform,
    .destroy_platform = pw_screen_destroy_platform,
    .enumerate_displays = pw_screen_enumerate_displays,
    .enumerate_windows = pw_screen_enumerate_windows,
    .configure_display = pw_screen_configure_display,
    .configure_window = pw_screen_configure_window,
    .configure_region = pw_screen_configure_region,
    .start_capture = pw_screen_start_capture,
    .stop_capture = pw_screen_stop_capture,
    .release_buffer = pw_screen_release_buffer,
    .get_default_formats = pw_screen_get_default_formats,
    .get_configured_video_formats = pw_screen_get_configured_video_formats,
};

// --- Platform Init Function (called by screen_api.c) ---
MiniAVResultCode
miniav_screen_context_platform_init_linux_pipewire(MiniAVScreenContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Screen: Initializing PipeWire platform backend for screen "
             "context.");

  pw_init(NULL, NULL);

  PipeWireScreenPlatformContext *pctx =
      (PipeWireScreenPlatformContext *)miniav_calloc(
          1, sizeof(PipeWireScreenPlatformContext));
  if (!pctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Screen: Failed to allocate platform context.");
    // pw_deinit(); // If pw_init was the very first, consider deinit. But
    // usually not here.
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  pctx->parent_ctx = ctx;
  pctx->wakeup_pipe[0] = pctx->wakeup_pipe[1] = -1; // Initialize pipe FDs

  ctx->platform_ctx = pctx;
  ctx->ops = &g_screen_ops_linux_pipewire;

  return MINIAV_SUCCESS;
}
#endif
