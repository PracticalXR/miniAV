#ifndef MINIAV_LOOPBACK_CONTEXT_WIN_WASAPI_H
#define MINIAV_LOOPBACK_CONTEXT_WIN_WASAPI_H

#include "../loopback_context.h" // For MiniAVLoopbackContext, LoopbackContextInternalOps, etc.

#ifdef _WIN32

// Windows and WASAPI headers
#include <audioclient.h> // For IAudioClient, IAudioCaptureClient
#include <functiondiscoverykeys_devpkey.h> // For PKEY_Device_FriendlyName etc.
#include <mmdeviceapi.h>                   // For IMMDeviceEnumerator, IMMDevice
#include <windows.h>

extern const LoopbackContextInternalOps g_loopback_ops_wasapi;

MiniAVResultCode miniav_loopback_context_platform_init_windows_wasapi(
    MiniAVLoopbackContext *ctx);

// --- WASAPI Platform-Specific Context ---
typedef struct LoopbackPlatformContextWinWasapi {
  MiniAVLoopbackContext *parent_ctx;
  IMMDeviceEnumerator *device_enumerator;
  IMMDevice *audio_device;
  IAudioClient *audio_client; // Could be IAudioClient or IAudioClient3
  IAudioCaptureClient *capture_client;
  WAVEFORMATEX *capture_format; // Actual format used by WASAPI
  WAVEFORMATEX *mix_format;     // Device's mix format
  UINT32 buffer_frame_count;
  HANDLE capture_thread_handle;
  HANDLE stop_event_handle;
  HANDLE buffer_event_handle;
  BOOL event_driven_capture;
  BOOL attempt_process_specific_capture;
  DWORD target_process_id; // For logging/debugging if process-specific
  LARGE_INTEGER qpc_frequency;
} LoopbackPlatformContextWinWasapi;

// --- WASAPI Platform-Specific Function Declarations ---
// These functions will implement the LoopbackContextInternalOps

MiniAVResultCode wasapi_init_platform(MiniAVLoopbackContext *ctx);
MiniAVResultCode wasapi_destroy_platform(MiniAVLoopbackContext *ctx);

MiniAVResultCode wasapi_configure_loopback(
    MiniAVLoopbackContext *ctx, const MiniAVLoopbackTargetInfo *target_info,
    const char *target_device_id, const MiniAVAudioInfo *requested_format);

MiniAVResultCode wasapi_start_capture(MiniAVLoopbackContext *ctx,
                                      MiniAVBufferCallback callback,
                                      void *user_data);
MiniAVResultCode wasapi_stop_capture(MiniAVLoopbackContext *ctx);
MiniAVResultCode
wasapi_release_buffer_platform(MiniAVLoopbackContext *ctx,
                               void *native_buffer_payload_resource_ptr);
MiniAVResultCode wasapi_get_configured_video_format(MiniAVLoopbackContext *ctx,
                                              MiniAVAudioInfo *format_out);

#endif // _WIN32

#endif // MINIAV_LOOPBACK_CONTEXT_WIN_WASAPI_H
