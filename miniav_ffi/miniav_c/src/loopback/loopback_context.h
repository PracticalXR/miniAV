#ifndef MINIAV_LOOPBACK_CONTEXT_H
#define MINIAV_LOOPBACK_CONTEXT_H

#include "../../include/miniav.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration
struct MiniAVLoopbackContext;

// --- Loopback Context Operations ---
// These are function pointers for platform-specific implementations.
typedef struct LoopbackContextInternalOps {
  MiniAVResultCode (*init_platform)(struct MiniAVLoopbackContext *ctx);
  MiniAVResultCode (*destroy_platform)(struct MiniAVLoopbackContext *ctx);

  // Enumerates loopback targets for the specific platform.
  MiniAVResultCode (*enumerate_targets_platform)(
      MiniAVLoopbackTargetType target_type_filter, MiniAVDeviceInfo **targets,
      uint32_t *count);

  // Gets the supported audio formats for a given loopback target.
  MiniAVResultCode (*get_supported_formats)(
      const char
          *target_device_id, // Can be NULL for system default, or specific ID
      MiniAVAudioInfo **formats_out, // Array of supported audio formats
      uint32_t *count_out);          // Number of formats found

  // Gets the default audio format for a given loopback target.
  MiniAVResultCode (*get_default_format)(
      const char
          *target_device_id, // Can be NULL for system default, or specific ID
      MiniAVAudioInfo *format_out);
  MiniAVResultCode (*get_default_format_platform)(
      const char
          *target_device_id_utf8, // Specific device ID, or NULL for default
      MiniAVAudioInfo *format_out);
  // Configure the loopback capture.
  MiniAVResultCode (*configure_loopback)(
      struct MiniAVLoopbackContext *ctx,
      const MiniAVLoopbackTargetInfo *target_info, const char *target_device_id,
      const MiniAVAudioInfo *requested_format);

  MiniAVResultCode (*start_capture)(struct MiniAVLoopbackContext *ctx,
                                    MiniAVBufferCallback callback,
                                    void *user_data);
  MiniAVResultCode (*stop_capture)(struct MiniAVLoopbackContext *ctx);

  MiniAVResultCode (*release_buffer_platform)(
      struct MiniAVLoopbackContext *ctx,
      void *native_buffer_payload_resource_ptr);

  MiniAVResultCode (*get_configured_video_format)(struct MiniAVLoopbackContext *ctx,
                                            MiniAVAudioInfo *format_out);

} LoopbackContextInternalOps;

// Represents a platform-specific process identifier.
typedef uint32_t MiniAVProcessId;

// Represents a platform-specific window handle.
typedef void *MiniAVWindowHandle;

// --- Loopback Backend Entry Structure ---
// Used in the backend table for dynamic selection.
typedef struct MiniAVLoopbackBackend {
  const char *name;
  const LoopbackContextInternalOps *ops;
  MiniAVResultCode (*platform_init)(
      struct MiniAVLoopbackContext
          *ctx); // Initial, minimal platform init for selection
} MiniAVLoopbackBackend;

// --- Loopback Context Structure ---
typedef struct MiniAVLoopbackContext {
  void *platform_ctx;
  const LoopbackContextInternalOps *ops;

  MiniAVBufferCallback app_callback;
  void *app_callback_user_data;

  bool is_configured;
  bool is_running;

  MiniAVAudioInfo configured_video_format;
  MiniAVLoopbackTargetInfo current_target_info;
  char current_target_device_id[MINIAV_DEVICE_ID_MAX_LEN];

  // Set via MiniAV_Loopback_SetContextLostCallback. May be NULL.
  MiniAVContextLostCallback lost_cb;
  void *lost_cb_user_data;

} MiniAVLoopbackContext;

#ifdef __cplusplus
}
#endif

#endif // MINIAV_LOOPBACK_CONTEXT_H