#ifndef MINIAV_LOOPBACK_CONTEXT_LINUX_PIPEWIRE_H
#define MINIAV_LOOPBACK_CONTEXT_LINUX_PIPEWIRE_H

#include "../../../include/miniav.h"        // For MiniAV types
#include "../loopback_context.h" // For LoopbackContextInternalOps

#ifdef __linux__

#include <pipewire/pipewire.h>
#include <spa/pod/builder.h> // For SPA_POD_BUILDER_INIT
#include <pthread.h>         // For pthread_t
#include <stdatomic.h>       // For the one-shot lost_cb guard

#define PW_LOOPBACK_MAX_REPORTED_DEVICES 32
#define PW_LOOPBACK_MAX_REPORTED_FORMATS 32

// Forward declaration
struct MiniAVLoopbackContext;

typedef struct PipeWireLoopbackTempDeviceInfo {
  MiniAVDeviceInfo info;
  uint32_t pw_global_id; // PipeWire global ID for the node
  // Add other temp info as needed during enumeration
} PipeWireLoopbackTempDeviceInfo;


typedef struct PipeWireLoopbackPlatformContext {
  struct MiniAVLoopbackContext *parent_ctx; // Back-pointer for lost_cb access
  atomic_bool lost_cb_fired; // One-shot loss-notification guard per run

  struct pw_main_loop *loop; // PipeWire main loop
  struct pw_context *context; // PipeWire context
  struct pw_core *core;       // PipeWire core
  struct spa_hook core_listener;

  struct pw_registry *registry;
  struct spa_hook registry_listener;

  struct pw_stream *stream; // Capture stream
  struct spa_hook stream_listener;

  pthread_t loop_thread;
  volatile bool loop_running; // Ensure volatile for thread safety
  int wakeup_pipe[2]; // Pipe fds: wakeup_pipe[0] for read, wakeup_pipe[1] for write

  // Configuration
  uint32_t target_node_id; // PipeWire node ID to capture from
  MiniAVAudioInfo configured_video_format;
  bool is_configured;
  bool is_streaming;

  // Application callback
  MiniAVBufferCallback app_callback;
  void *app_user_data;

  // Temporary data for enumeration/format fetching
  PipeWireLoopbackTempDeviceInfo temp_devices[PW_LOOPBACK_MAX_REPORTED_DEVICES];
  uint32_t num_temp_devices;

  MiniAVAudioInfo temp_formats[PW_LOOPBACK_MAX_REPORTED_FORMATS];
  uint32_t num_temp_formats;

  int pending_sync_ops; // For sync operations during init/enum

  // Buffer for building SPA PODs
  uint8_t spa_buffer[1024]; // Adjust size as needed
  struct spa_pod_builder spa_builder;


} PipeWireLoopbackPlatformContext;

extern const LoopbackContextInternalOps g_loopback_ops_linux_pipewire;
MiniAVResultCode miniav_loopback_context_platform_init_linux_pipewire(struct MiniAVLoopbackContext *ctx);

#endif // __linux__
#endif // MINIAV_LOOPBACK_CONTEXT_LINUX_PIPEWIRE_H