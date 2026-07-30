#ifndef SCREEN_CONTEXT_H
#define SCREEN_CONTEXT_H

#include "../../include/miniav.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration
struct MiniAVScreenContext;

// --- Screen Context Operations ---
// These are function pointers for platform-specific implementations.
typedef struct ScreenContextInternalOps {
  MiniAVResultCode (*init_platform)(struct MiniAVScreenContext *ctx);
  MiniAVResultCode (*destroy_platform)(struct MiniAVScreenContext *ctx);

  MiniAVResultCode (*enumerate_displays)(MiniAVDeviceInfo **displays,
                                         uint32_t *count);
  MiniAVResultCode (*enumerate_windows)(MiniAVDeviceInfo **windows,
                                        uint32_t *count);

  MiniAVResultCode (*configure_display)(struct MiniAVScreenContext *ctx,
                                        const char *display_id,
                                        const MiniAVVideoInfo *format);
  MiniAVResultCode (*configure_window)(struct MiniAVScreenContext *ctx,
                                       const char *window_id,
                                       const MiniAVVideoInfo *format);
  MiniAVResultCode (*configure_region)(struct MiniAVScreenContext *ctx,
                                       const char *target_id, int x, int y,
                                       int width, int height,
                                       const MiniAVVideoInfo *format);

  MiniAVResultCode (*start_capture)(struct MiniAVScreenContext *ctx,
                                    MiniAVBufferCallback callback,
                                    void *user_data);
  MiniAVResultCode (*stop_capture)(struct MiniAVScreenContext *ctx);
  MiniAVResultCode (*release_buffer)(struct MiniAVScreenContext *ctx,
                                     void *native_buffer_payload_resource_ptr);

  MiniAVResultCode (*get_default_formats)(
      const char *device_id, MiniAVVideoInfo *video_format_out,
      MiniAVAudioInfo *audio_format_out);

  MiniAVResultCode (*get_configured_video_formats)(
      struct MiniAVScreenContext *ctx, MiniAVVideoInfo *video_format_out,
      MiniAVAudioInfo *audio_format_out);
} ScreenContextInternalOps;

// --- Screen Context Structure ---
typedef struct MiniAVScreenContext {
  void *platform_ctx; // Platform-specific context (e.g.,
                      // DXGIScreenPlatformContext)
  const ScreenContextInternalOps *ops;

  MiniAVBufferCallback app_callback;
  void *app_callback_user_data;

  bool is_running;    // TRUE if capture is active
  bool is_configured; // TRUE if the context is configured
  MiniAVVideoInfo
      configured_video_format; // The format requested by the user
                               // and/or confirmed by the backend
  MiniAVAudioInfo configured_audio_format;

  // Add any other common state needed across platforms
  MiniAVCaptureType capture_target_type; // DISPLAY, WINDOW, REGION

  bool capture_audio_requested; // Whether the user requested audio capture
  bool capture_cursor; // Draw the mouse cursor into frames (default false).
                       // Set via MiniAV_Screen_SetCaptureCursor before
                       // configure; each backend reads it when building its
                       // capture session.

  // Set via MiniAV_Screen_SetContextLostCallback. May be NULL.
  MiniAVContextLostCallback lost_cb;
  void *lost_cb_user_data;

} MiniAVScreenContext;

typedef struct {
  const char *name;
  const ScreenContextInternalOps *ops;
  MiniAVResultCode (*platform_init_for_selection)(MiniAVScreenContext *ctx);
} MiniAVScreenBackend;

#ifdef __cplusplus
}
#endif

#endif // MINIAV_SCREEN_CONTEXT_H
