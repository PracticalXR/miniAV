#define _GNU_SOURCE // For pipe2 with O_CLOEXEC if needed, and other GNU
                    // extensions
#include "loopback_context_linux_pipewire.h"
#include "../../../include/miniav_buffer.h" // For MiniAVBuffer
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"  // For miniav_calloc, miniav_free, etc.
#include "../../common/miniav_utils.h" // For miniav_calloc, miniav_free, etc.

#ifdef __linux__

#include <pipewire/pipewire.h>
#include <spa/debug/types.h> // For spa_debug_type_find_name
#include <spa/param/audio/format-utils.h>
#include <spa/param/param.h> // For SPA_PARAM_EnumFormat, SPA_PARAM_Format
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>

#include <errno.h>   // For errno
#include <fcntl.h>   // For O_CLOEXEC, fcntl
#include <pthread.h> // For threading
#include <string.h>  // For strcmp, strncpy, memset
#include <unistd.h>  // For pipe, read, write, close

// --- Forward Declarations for Static Functions ---
static void *pipewire_loopback_thread_func(void *arg);
static void on_loopback_wakeup_pipe_event(void *data, int fd, uint32_t mask);

// Core listener
static void on_pw_core_error(void *data, uint32_t id, int seq, int res,
                             const char *message);
static void on_pw_core_done(void *data, uint32_t id, int seq);

// Registry listener
static void on_registry_global(void *data, uint32_t id, uint32_t permissions,
                               const char *type, uint32_t version,
                               const struct spa_dict *props);
static void on_registry_global_remove(void *data, uint32_t id);

// Stream listener
static void on_stream_state_changed(void *data, enum pw_stream_state old,
                                    enum pw_stream_state state,
                                    const char *error);
static void on_stream_param_changed(void *data, uint32_t id,
                                    const struct spa_pod *param);
static void on_stream_process(void *data);
// static void on_stream_add_buffer(void *data, struct pw_buffer *buffer); //
// Less common for capture-only static void on_stream_remove_buffer(void *data,
// struct pw_buffer *buffer); // Less common for capture-only

// --- Helper Functions (Placeholders) ---
static MiniAVAudioFormat
spa_audio_format_to_miniav(enum spa_audio_format spa_fmt) {
  switch (spa_fmt) {
  case SPA_AUDIO_FORMAT_S16_LE:
    return MINIAV_AUDIO_FORMAT_S16;
  case SPA_AUDIO_FORMAT_S32_LE:
    return MINIAV_AUDIO_FORMAT_S32;
  case SPA_AUDIO_FORMAT_F32_LE:
    return MINIAV_AUDIO_FORMAT_F32;
  // Add other mappings as needed (e.g., BE variants, planar, etc.)
  default:
    return MINIAV_AUDIO_FORMAT_UNKNOWN;
  }
}

static enum spa_audio_format
miniav_audio_format_to_spa(MiniAVAudioFormat miniav_fmt) {
  switch (miniav_fmt) {
  case MINIAV_AUDIO_FORMAT_S16:
    return SPA_AUDIO_FORMAT_S16_LE;
  case MINIAV_AUDIO_FORMAT_S32:
    return SPA_AUDIO_FORMAT_S32_LE;
  case MINIAV_AUDIO_FORMAT_F32:
    return SPA_AUDIO_FORMAT_F32_LE;
  default:
    return SPA_AUDIO_FORMAT_UNKNOWN;
  }
}

// --- Ops Implementation ---

static MiniAVResultCode
pw_loopback_init_platform(struct MiniAVLoopbackContext *ctx) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  pw_ctx->parent_ctx = ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Initializing platform context.");

  pw_ctx->loop = pw_main_loop_new(NULL);
  if (!pw_ctx->loop) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to create main loop.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  pw_ctx->context =
      pw_context_new(pw_main_loop_get_loop(pw_ctx->loop), NULL, 0);
  if (!pw_ctx->context) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to create context.");
    pw_main_loop_destroy(pw_ctx->loop);
    pw_ctx->loop = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  pw_ctx->core = pw_context_connect(pw_ctx->context, NULL, 0);
  if (!pw_ctx->core) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to connect to core.");
    pw_context_destroy(pw_ctx->context);
    pw_ctx->context = NULL;
    pw_main_loop_destroy(pw_ctx->loop);
    pw_ctx->loop = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Init wakeup pipe
  if (pipe2(pw_ctx->wakeup_pipe, O_CLOEXEC | O_NONBLOCK) == -1) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to create wakeup pipe: %s",
               strerror(errno));
    // Cleanup PipeWire resources
    pw_core_disconnect(pw_ctx->core);
    pw_context_destroy(pw_ctx->context);
    pw_main_loop_destroy(pw_ctx->loop);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  // Set read end to non-blocking if not already done by pipe2 O_NONBLOCK
  // int flags = fcntl(pw_ctx->wakeup_pipe[0], F_GETFL, 0);
  // fcntl(pw_ctx->wakeup_pipe[0], F_SETFL, flags | O_NONBLOCK);

  pw_ctx->is_configured = false;
  pw_ctx->is_streaming = false;
  pw_ctx->loop_running = false;
  pw_ctx->spa_builder =
      SPA_POD_BUILDER_INIT(pw_ctx->spa_buffer, sizeof(pw_ctx->spa_buffer));

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_loopback_destroy_platform(struct MiniAVLoopbackContext *ctx) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  if (!pw_ctx)
    return MINIAV_SUCCESS;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Destroying platform context.");

  if (pw_ctx->is_streaming || pw_ctx->loop_running) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Loopback: Stream or loop running "
                                      "during destroy, attempting to stop.");

    // Signal the loop to quit (which will clean up the stream)
    if (pw_ctx->loop_running && pw_ctx->wakeup_pipe[1] != -1) {
      write(pw_ctx->wakeup_pipe[1], "q", 1); // Signal loop to quit and clean up
    } else if (pw_ctx->loop) {
      pw_main_loop_quit(pw_ctx->loop);
    }

    // Wait for thread to finish — bounded; if it will not exit, LEAK the
    // platform context rather than free memory a live thread dereferences.
    if (pw_ctx->loop_thread) {
      if (miniav_timed_join(pw_ctx->loop_thread, 7000) != 0) {
        // The loop thread also dereferences the parent context —
        // MINIAV_ERROR_TIMEOUT tells MiniAV_Loopback_DestroyContext to skip
        // freeing that too.
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Loopback: loop thread still alive at destroy — "
                   "leaking the context to avoid a use-after-free.");
        ctx->platform_ctx = NULL;
        return MINIAV_ERROR_TIMEOUT;
      }
      pw_ctx->loop_thread = 0;
    }
    pw_ctx->is_streaming = false;
    pw_ctx->loop_running = false;
  }

  // Don't clean up the stream here - let the loop thread handle it
  if (pw_ctx->stream) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Loopback: Stream still exists during destroy - should have "
               "been cleaned by loop thread.");
  }

  if (pw_ctx->core) {
    pw_core_disconnect(pw_ctx->core);
    pw_ctx->core = NULL;
  }
  if (pw_ctx->context) {
    pw_context_destroy(pw_ctx->context);
    pw_ctx->context = NULL;
  }

  if (pw_ctx->wakeup_pipe[0] != -1)
    close(pw_ctx->wakeup_pipe[0]);
  if (pw_ctx->wakeup_pipe[1] != -1)
    close(pw_ctx->wakeup_pipe[1]);
  pw_ctx->wakeup_pipe[0] = pw_ctx->wakeup_pipe[1] = -1;

  miniav_free(pw_ctx);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Platform context destroyed.");
  return MINIAV_SUCCESS;
}

// --- Data for enumeration ---
typedef struct PipeWireLoopbackData {
  struct pw_main_loop *loop; // For sync
  MiniAVDeviceInfo *devices_list;
  uint32_t *devices_count; // Pointer to the output count
  uint32_t allocated_devices;
  MiniAVResultCode result;
  int sync_seq;
  int pending_seq;
  struct spa_hook registry_listener_hook;
  MiniAVLoopbackTargetType target_type_filter; // Added
} PipeWireLoopbackData;

static const struct pw_core_events core_events_enum_sync = {
    PW_VERSION_CORE_EVENTS,
    .done = on_pw_core_done, // For sync
    .error = on_pw_core_error,
};

static const struct pw_registry_events registry_events_enum = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_registry_global,
    .global_remove = on_registry_global_remove,
};

static MiniAVResultCode pw_loopback_enumerate_targets_platform(
    MiniAVLoopbackTargetType target_type_filter, MiniAVDeviceInfo **targets_out,
    uint32_t *count_out) {

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Enumerating targets (filter: %d).",
             target_type_filter);
  if (!targets_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *targets_out = NULL;
  *count_out = 0;

  MiniAVResultCode overall_res = MINIAV_SUCCESS;
  struct pw_main_loop *loop = NULL;
  struct pw_context *context = NULL;
  struct pw_core *core = NULL;
  struct pw_registry *registry = NULL;
  struct spa_hook core_listener_local;

  pw_init(NULL, NULL);

  loop = pw_main_loop_new(NULL);
  if (!loop)
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
  if (!context) {
    overall_res = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto enum_cleanup;
  }
  core = pw_context_connect(context, NULL, 0);
  if (!core) {
    overall_res = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    goto enum_cleanup;
  }

  PipeWireLoopbackData enum_data = {0};
  enum_data.loop = loop;
  enum_data.target_type_filter = target_type_filter; // Set the filter
  enum_data.devices_list = (MiniAVDeviceInfo *)miniav_calloc(
      PW_LOOPBACK_MAX_REPORTED_DEVICES, sizeof(MiniAVDeviceInfo));
  if (!enum_data.devices_list) {
    overall_res = MINIAV_ERROR_OUT_OF_MEMORY;
    goto enum_cleanup;
  }
  enum_data.allocated_devices = PW_LOOPBACK_MAX_REPORTED_DEVICES;
  enum_data.devices_count = count_out;
  *enum_data.devices_count = 0;
  enum_data.result = MINIAV_SUCCESS;

  pw_core_add_listener(core, &core_listener_local, &core_events_enum_sync,
                       &enum_data);
  registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
  pw_registry_add_listener(registry, &enum_data.registry_listener_hook,
                           &registry_events_enum, &enum_data);

  enum_data.pending_seq = pw_core_sync(core, PW_ID_CORE, 0);
  pw_main_loop_run(loop);

  if (enum_data.result != MINIAV_SUCCESS) {
    overall_res = enum_data.result;
    miniav_free(enum_data.devices_list);
    enum_data.devices_list = NULL;
    *count_out = 0;
  } else {
    if (*count_out > 0) {
      *targets_out = (MiniAVDeviceInfo *)miniav_realloc(
          enum_data.devices_list, *count_out * sizeof(MiniAVDeviceInfo));
      if (!*targets_out) {
        miniav_free(enum_data.devices_list);
        *count_out = 0;
        overall_res = MINIAV_ERROR_OUT_OF_MEMORY;
      }
    } else {
      miniav_free(enum_data.devices_list);
      *targets_out = NULL;
    }
  }

enum_cleanup:
  if (registry)
    pw_proxy_destroy((struct pw_proxy *)registry);
  if (core)
    pw_core_disconnect(core);
  if (context)
    pw_context_destroy(context);
  if (loop)
    pw_main_loop_destroy(loop);

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Enumeration finished with %u devices, result: %d.",
             *count_out, overall_res);
  return overall_res;
}

// --- Data for format enumeration ---
typedef struct PipeWireLoopbackFormatEnumData {
  struct pw_main_loop *loop;
  struct pw_remote *remote; // Needed for pw_remote_get_node_info
  uint32_t target_node_id;
  MiniAVAudioInfo *formats_list;
  uint32_t *formats_count;
  uint32_t allocated_formats;
  MiniAVResultCode result;
  struct pw_node_info *node_info; // To store node info
  int pending_seq;
} PipeWireLoopbackFormatEnumData;

static MiniAVResultCode
pw_loopback_get_supported_formats(const char *target_device_id,
                                  MiniAVAudioInfo **formats_out,
                                  uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: GetSupportedFormats for target: %s",
             target_device_id ? target_device_id : "NULL (not supported)");
  if (!target_device_id || !formats_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;

  *formats_out = NULL;
  *count_out = 0;

  *formats_out = (MiniAVAudioInfo *)miniav_calloc(1, sizeof(MiniAVAudioInfo));
  if (!*formats_out)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  (*formats_out)[0].format = MINIAV_AUDIO_FORMAT_F32;
  (*formats_out)[0].sample_rate = 48000;
  (*formats_out)[0].channels = 2;
  *count_out = 1;

  // PipeWire streams are format-adaptive: the graph converts/resamples to
  // whatever the stream requests, so unlike a hardware device there is no
  // fixed capability list to enumerate. The entry above is the suggested
  // request; the format actually negotiated is written back to the
  // configured format when the stream connects (on_stream_param_changed).
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: GetSupportedFormats — PipeWire adapts to the "
             "requested format; suggesting F32/48kHz/2ch.");
  return MINIAV_SUCCESS;
}
static MiniAVResultCode
pw_loopback_get_default_format_platform(const char *target_device_id,
                                        MiniAVAudioInfo *format_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: GetDefaultFormat for target: %s",
             target_device_id ? target_device_id : "System Default");
  if (!format_out)
    return MINIAV_ERROR_INVALID_ARG;

  // PipeWire converts/resamples to whatever the stream requests, so the
  // "default" here is a suggestion, not a device constraint (48 kHz matches
  // the typical graph clock). The format actually negotiated at connect time
  // is written back to the configured format (on_stream_param_changed).
  format_out->format = MINIAV_AUDIO_FORMAT_F32;
  format_out->sample_rate = 48000;
  format_out->channels = 2;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: GetDefaultFormat — suggesting F32/48kHz/2ch "
             "(PipeWire adapts to the requested format).");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode pw_loopback_configure_loopback(
    struct MiniAVLoopbackContext *ctx,
    const MiniAVLoopbackTargetInfo
        *target_info, // May be NULL if device_id is used
    const char
        *target_device_id, // PipeWire node ID as string, or NULL for default
    const MiniAVAudioInfo *requested_format) {

  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  if (!requested_format)
    return MINIAV_ERROR_INVALID_ARG;

  if (target_info && target_info->type != MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Only SYSTEM_AUDIO target type supported for "
               "configure via target_info.");
    return MINIAV_ERROR_NOT_SUPPORTED; // PipeWire loopback usually targets
                                       // specific nodes (monitors)
  }

  if (!target_device_id) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Target device ID (PipeWire Node ID) must be "
               "provided for configuration.");
    // TODO: Could try to find default sink's monitor if NULL, but that's more
    // complex enum logic here.
    return MINIAV_ERROR_INVALID_ARG;
  }

  // Assuming target_device_id is a string representing the numeric node ID
  if (sscanf(target_device_id, "%u", &pw_ctx->target_node_id) != 1) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to parse target_node_id from string: %s",
               target_device_id);
    return MINIAV_ERROR_INVALID_ARG;
  }

  pw_ctx->configured_video_format = *requested_format;
  pw_ctx->is_configured = true;

  miniav_log(
      MINIAV_LOG_LEVEL_INFO,
      "PW Loopback: Configured for Node ID %u with Format %s, %uHz, %uch.",
      pw_ctx->target_node_id,
      spa_debug_type_find_name(
          spa_type_audio_format,
          miniav_audio_format_to_spa(requested_format->format)),
      requested_format->sample_rate, requested_format->channels);

  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_loopback_start_capture(struct MiniAVLoopbackContext *ctx,
                          MiniAVBufferCallback callback, void *user_data) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  if (!pw_ctx->is_configured)
    return MINIAV_ERROR_NOT_INITIALIZED;
  if (pw_ctx->is_streaming || pw_ctx->loop_running)
    return MINIAV_ERROR_ALREADY_RUNNING;

  pw_ctx->app_callback = callback;
  pw_ctx->app_user_data = user_data;
  // Fresh loss-notification guard per run.
  atomic_store(&pw_ctx->lost_cb_fired, false);

  static const struct pw_stream_events stream_events = {
      PW_VERSION_STREAM_EVENTS,
      .state_changed = on_stream_state_changed,
      .param_changed = on_stream_param_changed,
      .process = on_stream_process,
  };

  pw_ctx->stream = pw_stream_new(
      pw_ctx->core, "miniav-loopback-capture",
      pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY,
                        "Capture", PW_KEY_MEDIA_ROLE, "Music", // Or "Generic"
                        NULL));
  if (!pw_ctx->stream) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Loopback: Failed to create stream.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  pw_stream_add_listener(pw_ctx->stream, &pw_ctx->stream_listener,
                         &stream_events, pw_ctx);

  // Build params for connecting
  uint8_t buffer[1024];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  const struct spa_pod *params[1];

  enum spa_audio_format spa_fmt =
      miniav_audio_format_to_spa(pw_ctx->configured_video_format.format);
  if (spa_fmt == SPA_AUDIO_FORMAT_UNKNOWN) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Unknown Miniaudio format for SPA: %d",
               pw_ctx->configured_video_format.format);
    pw_stream_destroy(pw_ctx->stream);
    pw_ctx->stream = NULL;
    return MINIAV_ERROR_INVALID_ARG;
  }

  params[0] = spa_format_audio_raw_build(
      &b, SPA_PARAM_EnumFormat,
      &SPA_AUDIO_INFO_RAW_INIT(
              .format = spa_fmt,
              .channels = pw_ctx->configured_video_format.channels,
              .rate = pw_ctx->configured_video_format.sample_rate));

  if (pw_stream_connect(
          pw_ctx->stream,
          PW_DIRECTION_INPUT,     // We are capturing (stream is an input to our
                                  // app)
          pw_ctx->target_node_id, // The node we want to capture FROM
          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
              PW_STREAM_FLAG_RT_PROCESS,
          params, 1) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to connect stream to node %u.",
               pw_ctx->target_node_id);
    pw_stream_destroy(pw_ctx->stream);
    pw_ctx->stream = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Start the loop thread
  if (pthread_create(&pw_ctx->loop_thread, NULL, pipewire_loopback_thread_func,
                     ctx) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to create PipeWire loop thread.");
    pw_stream_destroy(pw_ctx->stream);
    pw_ctx->stream = NULL;
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  // is_streaming will be set true by the stream state callback
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "PW Loopback: Capture stream connecting, loop thread starting.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_loopback_stop_capture(struct MiniAVLoopbackContext *ctx) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  if (!pw_ctx->loop_running &&
      !pw_ctx->is_streaming) { // Check both as loop might run briefly after
                               // stream stops
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Loopback: Capture not running or loop already stopped.");
    return MINIAV_SUCCESS;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Loopback: Stopping capture.");

  pw_ctx->is_streaming = false; // Set this early

  // Signal the loop thread to clean up the stream and quit
  if (pw_ctx->loop_running && pw_ctx->loop) {
    miniav_log(
        MINIAV_LOG_LEVEL_DEBUG,
        "PW Loopback: Signaling PipeWire loop to quit and clean up stream.");
    if (pw_ctx->wakeup_pipe[1] != -1) {
      if (write(pw_ctx->wakeup_pipe[1], "q", 1) == -1 && errno != EAGAIN) {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "PW Loopback: Failed to write to wakeup pipe: %s",
                   strerror(errno));
      }
    } else { // Fallback if pipe is not working
      pw_main_loop_quit(pw_ctx->loop);
    }
  }

  // Wait for the loop thread to finish (it will clean up the stream)
  if (pw_ctx->loop_thread) { // Check if thread was actually created
    if (pthread_equal(pw_ctx->loop_thread, pthread_self())) {
      // Called from the loop thread itself (e.g. an app violating the
      // lost_cb contract by stopping synchronously from the callback):
      // joining would self-deadlock. Leave the join to a later call from
      // another thread.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Loopback: StopCapture called from the loop thread — "
                 "skipping self-join (see MiniAVContextLostCallback docs).");
      return MINIAV_ERROR_INVALID_OPERATION;
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "PW Loopback: Joining PipeWire loop thread.");
    if (miniav_timed_join(pw_ctx->loop_thread, 5000) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Loopback: loop thread did not exit within 5s — "
                 "deferring (a later Stop/Destroy will retry the join).");
      return MINIAV_ERROR_TIMEOUT; // loop_thread left set for retry
    }
    pw_ctx->loop_thread = 0; // Mark as joined
  }
  pw_ctx->loop_running = false; // Ensure this is false after join

  // The stream should have been cleaned up by the loop thread
  if (pw_ctx->stream) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Loopback: Stream still exists after "
                                      "loop thread cleanup - potential leak.");
    // Don't clean it up here to avoid "wrong context" errors
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "PW Loopback: Capture stopped.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_loopback_release_buffer_platform(struct MiniAVLoopbackContext *ctx,
                                    void *native_buffer_payload_resource_ptr) {
  MINIAV_UNUSED(ctx);

  if (native_buffer_payload_resource_ptr) {
    // Simply free the heap-allocated MiniAVBuffer structure
    miniav_free(native_buffer_payload_resource_ptr);
  }

  return MINIAV_SUCCESS;
}

static MiniAVResultCode
pw_loopback_get_configured_video_format(struct MiniAVLoopbackContext *ctx,
                                        MiniAVAudioInfo *format_out) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  if (!pw_ctx->is_configured)
    return MINIAV_ERROR_NOT_INITIALIZED;
  *format_out = pw_ctx->configured_video_format;
  return MINIAV_SUCCESS;
}

// --- PipeWire Thread and Event Handlers ---

static void *pipewire_loopback_thread_func(void *arg) {
  struct MiniAVLoopbackContext *ctx = (struct MiniAVLoopbackContext *)arg;
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: PipeWire loop thread started.");
  pw_ctx->loop_running = true;

  struct pw_loop *loop_ptr = pw_main_loop_get_loop(pw_ctx->loop);
  struct spa_source *wakeup_source = NULL;

  if (pw_ctx->wakeup_pipe[0] != -1) {
    wakeup_source =
        pw_loop_add_io(loop_ptr, pw_ctx->wakeup_pipe[0], SPA_IO_IN,
                       false, // Don't close fd on destroy, we manage it
                       on_loopback_wakeup_pipe_event, pw_ctx);
    if (!wakeup_source) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Loopback: Failed to add wakeup IO "
                                         "source. Loop may not exit cleanly.");
    }
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "PW Loopback: Wakeup pipe read end is invalid in loop thread.");
  }

  pw_main_loop_run(pw_ctx->loop); // Blocks here until pw_main_loop_quit

  if (wakeup_source) {
    pw_loop_remove_source(loop_ptr, wakeup_source);
  }
  // pw_ctx->loop_running = false; // Set by stop_capture or destroy
  // before/after join
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: PipeWire loop thread finished.");
  return NULL;
}

static void on_loopback_wakeup_pipe_event(void *data, int fd, uint32_t mask) {
  MINIAV_UNUSED(mask);
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)data;
  char buf[16]; // Read a bit to clear the pipe
  ssize_t len;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Wakeup pipe event received.");

  // Drain the pipe
  while ((len = read(pw_ctx->wakeup_pipe[0], buf, sizeof(buf) - 1)) > 0) {
    buf[len] = '\0';
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Loopback: Wakeup pipe read: %s",
               buf);
    if (strchr(buf, 'q')) { // Check if 'q' was in the read data
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Loopback: Quit signal received in "
                 "wakeup pipe. Cleaning up stream and quitting main loop.");

      // Clean up stream in the correct thread context
      if (pw_ctx->stream) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Loopback: Disconnecting and destroying stream in loop "
                   "context.");
        pw_stream_disconnect(pw_ctx->stream);
        spa_hook_remove(&pw_ctx->stream_listener);
        pw_stream_destroy(pw_ctx->stream);
        pw_ctx->stream = NULL;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "PW Loopback: Stream cleaned up in loop context.");
      }

      pw_main_loop_quit(pw_ctx->loop);
      return; // Exit once 'q' is processed
    }
  }

  if (len == 0) { // EOF
    miniav_log(MINIAV_LOG_LEVEL_WARN, "PW Loopback: Wakeup pipe EOF.");
  } else if (len < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      // This is expected if pipe was empty or partially drained
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Loopback: Wakeup pipe read would block (drained).");
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "PW Loopback: Wakeup pipe read error: %s. Quitting loop.",
                 strerror(errno));
      pw_main_loop_quit(pw_ctx->loop);
    }
  }
}

// Core listener callbacks
static void on_pw_core_error(void *data, uint32_t id, int seq, int res,
                             const char *message) {
  PipeWireLoopbackData *enum_data =
      (PipeWireLoopbackData *)data; // Could be other types of data too
  miniav_log(MINIAV_LOG_LEVEL_ERROR,
             "PW Loopback: Core error: id=%u, seq=%d, res=%d: %s", id, seq, res,
             message);
  if (enum_data && enum_data->loop &&
      enum_data->pending_seq == seq) { // Check if it's for our sync
    enum_data->result = MINIAV_ERROR_SYSTEM_CALL_FAILED;
    pw_main_loop_quit(enum_data->loop);
  }
  // If it's a general context's core, might need to signal app or cleanup.
}

static void on_pw_core_done(void *data, uint32_t id, int seq) {
  MINIAV_UNUSED(id);
  PipeWireLoopbackData *enum_data = (PipeWireLoopbackData *)data;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Core done: seq=%d, pending_seq=%d", seq,
             enum_data ? enum_data->pending_seq : -1);
  if (enum_data && enum_data->loop && enum_data->pending_seq == seq) {
    // Sync point reached for enumeration or other ops
    pw_main_loop_quit(enum_data->loop);
  }
}

// Registry listener callbacks
static void on_registry_global(void *data, uint32_t id, uint32_t permissions,
                               const char *type, uint32_t version,
                               const struct spa_dict *props) {
  MINIAV_UNUSED(permissions);
  MINIAV_UNUSED(version);
  PipeWireLoopbackData *enum_data = (PipeWireLoopbackData *)data;

  if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
    const char *media_class =
        props ? spa_dict_lookup(props, PW_KEY_MEDIA_CLASS) : NULL;
    const char *node_name =
        props ? spa_dict_lookup(props, PW_KEY_NODE_NAME) : NULL;
    const char *node_description =
        props ? spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION) : NULL;
    const char *app_name =
        props ? spa_dict_lookup(props, PW_KEY_APP_ICON_NAME) : NULL;
    const char *app_process_id_str =
        props ? spa_dict_lookup(props, PW_KEY_APP_PROCESS_ID) : NULL;

    bool add_this_device = false;
    char name_buffer[MINIAV_DEVICE_NAME_MAX_LEN] = {0};
    char id_buffer[MINIAV_DEVICE_ID_MAX_LEN] = {0};

    snprintf(id_buffer, MINIAV_DEVICE_ID_MAX_LEN, "%u",
             id); // Default ID is the node ID

    if (enum_data->target_type_filter == MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO ||
        enum_data->target_type_filter == MINIAV_LOOPBACK_TARGET_NONE) {
      if (media_class && strstr(media_class, "Audio/Source") != NULL) {
        // This includes actual hardware inputs and monitor sources of sinks
        add_this_device = true;
        if (node_description && strlen(node_description) > 0) {
          strncpy(name_buffer, node_description, sizeof(name_buffer) - 1);
        } else if (node_name && strlen(node_name) > 0) {
          strncpy(name_buffer, node_name, sizeof(name_buffer) - 1);
        } else {
          snprintf(name_buffer, sizeof(name_buffer), "PipeWire Source Node %u",
                   id);
        }
      }
    } else if (enum_data->target_type_filter ==
                   MINIAV_LOOPBACK_TARGET_PROCESS ||
               enum_data->target_type_filter == MINIAV_LOOPBACK_TARGET_WINDOW) {
      // For process/window, look for application streams
      // These are often Stream/Output/Audio or have application.name
      if ((app_name && strlen(app_name) > 0) ||
          (media_class && strstr(media_class, "Stream/Output/Audio") != NULL)) {

        add_this_device = true;
        if (app_name && strlen(app_name) > 0) {
          strncpy(name_buffer, app_name, sizeof(name_buffer) - 1);
        } else if (node_description && strlen(node_description) > 0) {
          strncpy(name_buffer, node_description, sizeof(name_buffer) - 1);
        } else if (node_name && strlen(node_name) > 0) {
          strncpy(name_buffer, node_name, sizeof(name_buffer) - 1);
        } else {
          snprintf(name_buffer, sizeof(name_buffer), "PipeWire App Node %u",
                   id);
        }

        if (app_process_id_str && strlen(app_process_id_str) > 0) {
          char pid_suffix[32];
          snprintf(pid_suffix, sizeof(pid_suffix), " (PID: %s)",
                   app_process_id_str);
          strncat(name_buffer, pid_suffix,
                  sizeof(name_buffer) - strlen(name_buffer) - 1);
        }
      }
    }

    if (add_this_device && enum_data &&
        *enum_data->devices_count < enum_data->allocated_devices) {
      MiniAVDeviceInfo *dev_info =
          &enum_data->devices_list[*enum_data->devices_count];
      memset(dev_info, 0, sizeof(MiniAVDeviceInfo));

      strncpy(dev_info->device_id, id_buffer, MINIAV_DEVICE_ID_MAX_LEN - 1);
      dev_info->device_id[MINIAV_DEVICE_ID_MAX_LEN - 1] = '\0';

      strncpy(dev_info->name, name_buffer, MINIAV_DEVICE_NAME_MAX_LEN - 1);
      dev_info->name[MINIAV_DEVICE_NAME_MAX_LEN - 1] = '\0';

      dev_info->is_default = false; // PipeWire default handling is complex; not
                                    // easily determined here.

      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "PW Loopback Enum (Filter: %d): Found Node: ID='%s', "
                 "Name='%s', MediaClass='%s', AppName='%s'",
                 enum_data->target_type_filter, dev_info->device_id,
                 dev_info->name, media_class ? media_class : "N/A",
                 app_name ? app_name : "N/A");
      (*enum_data->devices_count)++;
    }
  }
}

static void on_registry_global_remove(void *data, uint32_t id) {
  MINIAV_UNUSED(data);
  MINIAV_UNUSED(id);
  // Can handle device removal if needed, e.g., update a cached list.
  // For one-shot enumeration, this might not be critical.
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Registry global remove: ID=%u", id);
}

// Stream listener callbacks
static void on_stream_state_changed(void *data, enum pw_stream_state old,
                                    enum pw_stream_state state,
                                    const char *error) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)data; // Corrected cast

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Stream state changed from %s to %s.",
             pw_stream_state_as_string(old), pw_stream_state_as_string(state));

  switch (state) {
  case PW_STREAM_STATE_ERROR:
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "PW Loopback: Stream error: %s",
               error ? error : "Unknown error");
    // Tell the app the stream is gone instead of letting buffers silently
    // stop (mirrors WASAPI's AUDCLNT_E_DEVICE_INVALIDATED -> lost_cb path).
    // NOTE: fires on the PipeWire loop thread — see the
    // MiniAVContextLostCallback contract (no synchronous Stop/Destroy).
    if (pw_ctx->is_streaming && pw_ctx->parent_ctx &&
        pw_ctx->parent_ctx->lost_cb &&
        !atomic_exchange(&pw_ctx->lost_cb_fired, true)) {
      pw_ctx->parent_ctx->lost_cb((int)MINIAV_ERROR_DEVICE_LOST,
                                  pw_ctx->parent_ctx->lost_cb_user_data);
    }
    pw_ctx->is_streaming = false;
    if (pw_ctx->loop_running && pw_ctx->loop && pw_ctx->wakeup_pipe[1] != -1) {
      write(pw_ctx->wakeup_pipe[1], "q", 1);
    }
    break;
  case PW_STREAM_STATE_UNCONNECTED:
    pw_ctx->is_streaming = false;
    if (pw_ctx->loop_running && pw_ctx->loop && pw_ctx->wakeup_pipe[1] != -1 &&
        old != PW_STREAM_STATE_CONNECTING) {
    }
    break;
  case PW_STREAM_STATE_CONNECTING:
    break;
  case PW_STREAM_STATE_PAUSED:   // Ready for format negotiation / buffers
    pw_ctx->is_streaming = true; // Or a "ready_for_buffers" flag
    // This is where we would typically negotiate format if not done at connect.
    // For capture, often format is set at connect time.
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "PW Loopback: Stream paused (ready).");
    break;
  case PW_STREAM_STATE_STREAMING:
    pw_ctx->is_streaming = true;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "PW Loopback: Stream is now streaming.");
    break;
  }
}

static void on_stream_param_changed(void *data, uint32_t id,
                                    const struct spa_pod *param) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)data; // Corrected cast
  MINIAV_UNUSED(pw_ctx); // If pw_ctx is not used after this, to avoid unused
                         // variable warning. Or use it as intended.

  if (!param || id != SPA_PARAM_Format) {
    return;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: Stream param changed (Format).");

  struct spa_audio_info_raw info = {0};
  if (spa_format_audio_raw_parse(param, &info) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "PW Loopback: Failed to parse SPA_PARAM_Format into "
               "spa_audio_info_raw.");
    return;
  }

  MiniAVAudioInfo negotiated_format = {0};
  negotiated_format.format = spa_audio_format_to_miniav(info.format);
  negotiated_format.channels = info.channels;
  negotiated_format.sample_rate = info.rate;

  if (negotiated_format.format != MINIAV_AUDIO_FORMAT_UNKNOWN) {
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "PW Loopback: Negotiated format: %s, %uHz, %uch.",
               spa_debug_type_find_name(spa_type_audio_format, info.format),
               info.rate, info.channels);
    // Persist what the graph ACTUALLY negotiated so delivered buffers and
    // get_configured_video_format() report the real format (buffers used to
    // be stamped with the original request even when PipeWire negotiated a
    // different rate/layout).
    if (pw_ctx) {
      pw_ctx->configured_video_format = negotiated_format;
    }
  } else {
    miniav_log(
        MINIAV_LOG_LEVEL_WARN,
        "PW Loopback: Received unknown SPA audio format in param_changed: %u",
        info.format);
  }
}

static void on_stream_process(void *data) {
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)data;
  struct pw_buffer *pw_buf;

  if (!pw_ctx || !pw_ctx->app_callback)
    return;

  while ((pw_buf = pw_stream_dequeue_buffer(pw_ctx->stream)) != NULL) {
    struct spa_buffer *spa_buf = pw_buf->buffer;
    struct spa_data *spa_d = &spa_buf->datas[0]; // Assuming single plane audio

    if (spa_d->data && spa_d->chunk && spa_d->chunk->size > 0 &&
        miniav_dispatch_guard_acquire_if_enabled()) {
      // Copy the PCM out of PipeWire's buffer and attach the release payload
      // (mirrors the WASAPI path, loopback_context_win_wasapi.c:277-311).
      // The pw_buf memory is requeued to PipeWire right below and reused for
      // the next quantum, so delivering a pointer into it would be a
      // use-after-free for any consumer that holds the buffer across an
      // async boundary — which the Dart FFI layer always does. The payload
      // is what makes MiniAV_ReleaseBuffer able to free the copy + buffer
      // (previously every delivery leaked).
      //
      // The dispatch guard is acquired BEFORE allocating and held across the
      // callback: when callbacks are disabled (MiniAV_Dispose mid hot
      // restart) nothing is allocated — otherwise every quantum would leak a
      // payload nobody can ever release.
      const size_t audio_bytes = spa_d->chunk->size;
      MiniAVNativeBufferInternalPayload *payload =
          (MiniAVNativeBufferInternalPayload *)miniav_calloc(
              1, sizeof(MiniAVNativeBufferInternalPayload));
      MiniAVBuffer *buffer =
          (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
      void *audio_copy = miniav_calloc(1, audio_bytes);
      if (!payload || !buffer || !audio_copy) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "PW Loopback: OOM allocating audio buffer payload.");
        miniav_free(payload);
        miniav_free(buffer);
        miniav_free(audio_copy);
        miniav_dispatch_guard_release();
        pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
        continue;
      }
      memcpy(audio_copy, (uint8_t *)spa_d->data + spa_d->chunk->offset,
             audio_bytes);

      buffer->type = MINIAV_BUFFER_TYPE_AUDIO;
      buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
      buffer->timestamp_us = miniav_get_time_us();
      buffer->user_data = pw_ctx->app_user_data;
      buffer->data_size_bytes = audio_bytes;
      buffer->data.audio.info = pw_ctx->configured_video_format;
      buffer->data.audio.data = audio_copy;

      payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
      payload->context_owner = pw_ctx->parent_ctx;
      payload->native_singular_resource_ptr = audio_copy;
      payload->parent_miniav_buffer_ptr = buffer;
      buffer->internal_handle = payload;

      pw_ctx->app_callback(buffer, pw_ctx->app_user_data);
      miniav_dispatch_guard_release();
    }

    // Return the PipeWire buffer immediately after callback — the delivered
    // MiniAVBuffer owns a private copy, so this is now safe.
    pw_stream_queue_buffer(pw_ctx->stream, pw_buf);
  }
}

// --- Ops Structure Definition ---
const LoopbackContextInternalOps g_loopback_ops_linux_pipewire = {
    .init_platform = pw_loopback_init_platform,
    .destroy_platform = pw_loopback_destroy_platform,
    .enumerate_targets_platform = pw_loopback_enumerate_targets_platform,
    .get_supported_formats = pw_loopback_get_supported_formats,
    .get_default_format_platform =
        pw_loopback_get_default_format_platform, // Simplified
    .configure_loopback = pw_loopback_configure_loopback,
    .start_capture = pw_loopback_start_capture,
    .stop_capture = pw_loopback_stop_capture,
    .release_buffer_platform = pw_loopback_release_buffer_platform,
    .get_configured_video_format = pw_loopback_get_configured_video_format,
};

// --- Platform Init Function (called by loopback_api.c) ---
MiniAVResultCode miniav_loopback_context_platform_init_linux_pipewire(
    struct MiniAVLoopbackContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "PW Loopback: "
             "miniav_loopback_context_platform_init_linux_pipewire called.");

  // Minimal check: can PipeWire be initialized?
  // pw_init(NULL, NULL);
  PipeWireLoopbackPlatformContext *pw_ctx =
      (PipeWireLoopbackPlatformContext *)miniav_calloc(
          1, sizeof(PipeWireLoopbackPlatformContext));
  if (!pw_ctx) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  pw_ctx->wakeup_pipe[0] = -1; // Initialize pipe fds
  pw_ctx->wakeup_pipe[1] = -1;

  ctx->platform_ctx = pw_ctx;
  ctx->ops = &g_loopback_ops_linux_pipewire;

  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "PW Loopback: Platform selected. Full init in ops->init_platform.");
  return MINIAV_SUCCESS;
}

#endif // __linux__