// IMPORTANT: This file should be compiled as C++

#include "screen_context_win_wgc.h"
#include "../../../include/miniav.h" // For MiniAV types, MiniAV_GetErrorString
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h" // For miniav_calloc, miniav_free, strncpy_s_miniav
#include "../../loopback/loopback_context.h" // For MiniAVLoopbackContextHandle and related API

#include <DispatcherQueue.h>
#include <d3d11_4.h>
#include <dwmapi.h>  // For DwmGetWindowAttribute, DWMWA_CLOAKED
#include <dxgi1_6.h> // For DXGI_SHARED_RESOURCE_READ
#include <inspectable.h>
#include <roapi.h>
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.System.h>

// Interop header for creating GraphicsCaptureItem from HWND/HMONITOR
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <atomic>
#include <mutex> // For critical sections if not using Windows API
#include <string>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "runtimeobject.lib")

// --- WinRT and Dispatcher Queue Management ---
static std::atomic<int> g_wgc_init_count = 0;
static winrt::Windows::System::DispatcherQueueController
    g_dispatcher_queue_controller{nullptr};
static std::mutex g_wgc_init_mutex;
// NEW: track whether we actually initialized the apartment
static bool g_wgc_initialized_apartment = false;

MiniAVResultCode init_winrt_for_wgc() {
  std::lock_guard<std::mutex> lock(g_wgc_init_mutex);
  if (g_wgc_init_count == 0) {
    try {
      // Attempt MTA init. If apartment already initialized differently, handle gracefully.
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      g_wgc_initialized_apartment = true;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC: WinRT apartment initialized (MTA).");
    } catch (winrt::hresult_error const &ex) {
      if (ex.code() == RPC_E_CHANGED_MODE) {
        // Already initialized with different model; continue without re-initializing.
        g_wgc_initialized_apartment = false;
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "WGC: WinRT apartment already initialized with different threading model (0x%08X). Continuing.",
                   ex.code().value);
      } else {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "WGC: WinRT initialization failed: %ls (0x%08X)",
                   ex.message().c_str(), ex.code().value);
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
      }
    }
    try {
      g_dispatcher_queue_controller = winrt::Windows::System::DispatcherQueueController::CreateOnDedicatedThread();
      if (!g_dispatcher_queue_controller) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "WGC: Failed to create DispatcherQueueController.");
        if (g_wgc_initialized_apartment) {
          winrt::uninit_apartment();
          g_wgc_initialized_apartment = false;
        }
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
      }
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC: DispatcherQueue initialized.");
    } catch (winrt::hresult_error const &ex) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: DispatcherQueue creation failed: %ls (0x%08X)",
                 ex.message().c_str(), ex.code().value);
      if (g_wgc_initialized_apartment) {
        winrt::uninit_apartment();
        g_wgc_initialized_apartment = false;
      }
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }
  g_wgc_init_count++;
  return MINIAV_SUCCESS;
}

void shutdown_winrt_for_wgc() {
  std::lock_guard<std::mutex> lock(g_wgc_init_mutex);
  g_wgc_init_count--;
  if (g_wgc_init_count == 0) {
    if (g_dispatcher_queue_controller) {
      try {
        auto async_shutdown = g_dispatcher_queue_controller.ShutdownQueueAsync();
        async_shutdown.get();
        g_dispatcher_queue_controller = nullptr;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "WGC: DispatcherQueueController shut down.");
      } catch (winrt::hresult_error const &ex) {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "WGC: Error shutting down DispatcherQueueController: %ls",
                   ex.message().c_str());
      }
    }
    if (g_wgc_initialized_apartment) {
      winrt::uninit_apartment();
      g_wgc_initialized_apartment = false;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: WinRT apartment uninitialized.");
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC: Skipped uninit_apartment (not initialized here).");
    }
  }
}

// --- Structs ---
typedef enum WGCCaptureTargetType {
  WGC_TARGET_NONE,
  WGC_TARGET_DISPLAY,
  WGC_TARGET_WINDOW
} WGCCaptureTargetType;

// Payload for releasing WGC frame resources
typedef struct WGCFrameReleasePayload {
  MiniAVOutputPreference original_output_preference;
  MiniAVOutputPreference actual_output_preference;
  ID3D11Texture2D
      *gpu_texture_to_release; // AddRef'd texture (original or shared copy)
  HANDLE gpu_shared_handle_to_close; // Handle given to app (app should close,
                                     // but we track)

  ID3D11Texture2D *cpu_staging_texture_to_unmap_release; // AddRef'd
  ID3D11DeviceContext *d3d_context_for_unmap;            // AddRef'd if non-null
  UINT subresource_for_unmap;

} WGCFrameReleasePayload;

typedef struct WGCScreenPlatformContext {
  MiniAVScreenContext *parent_ctx;

  winrt::com_ptr<ID3D11Device> d3d_device;
  winrt::com_ptr<ID3D11DeviceContext> d3d_context;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice
      d3d_device_winrt{nullptr};

  winrt::Windows::Graphics::Capture::GraphicsCaptureItem capture_item{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool{
      nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_arrived_token{};

  MiniAVBufferCallback app_callback_internal;
  void *app_callback_user_data_internal;

  std::atomic<BOOL> is_streaming;
  HANDLE stop_event_handle;          // Manual reset event
  CRITICAL_SECTION critical_section; // To protect shared members like callback
                                     // and streaming state

  MiniAVVideoInfo
      configured_video_format; // User's request (FPS, output_preference)
  UINT target_fps;
  UINT frame_width;
  UINT frame_height;
  MiniAVPixelFormat pixel_format; // Typically BGRA32

  LARGE_INTEGER qpc_frequency;
  WGCCaptureTargetType current_target_type;
  char selected_item_id[MINIAV_DEVICE_ID_MAX_LEN]; // e.g., "HMONITOR:0x1234" or
                                                   // "HWND:0x5678"
  HWND selected_hwnd;                              // If window capture
  HMONITOR selected_hmonitor;                      // If display capture

  // --- Audio Loopback Members ---
  MiniAVLoopbackContextHandle loopback_audio_ctx;
  BOOL audio_loopback_enabled_and_configured;
  MiniAVAudioInfo configured_audio_format; // Actual format from loopback

} WGCScreenPlatformContext;

// --- Forward declarations for static functions ---
static MiniAVResultCode wgc_init_d3d_device(WGCScreenPlatformContext *wgc_ctx);
static void wgc_cleanup_d3d_device(WGCScreenPlatformContext *wgc_ctx);
static void wgc_cleanup_capture_resources(WGCScreenPlatformContext *wgc_ctx);
static void wgc_on_frame_arrived(
    WGCScreenPlatformContext *wgc_ctx,
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const &sender,
    winrt::Windows::Foundation::IInspectable const &args);

// --- Helper to get ID3D11Texture2D from IDirect3DSurface ---
static winrt::com_ptr<ID3D11Texture2D> GetTextureFromDirect3DSurface(
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface const
        &surface) {
  try {
    // Attempt to get the IDirect3DDxgiInterfaceAccess interface from the
    // surface. This uses the raw COM interface type.
    // The windows.graphics.directx.direct3d11.interop.h header should provide
    // the definition for IDirect3DDxgiInterfaceAccess.
    auto access = surface.as<::Windows::Graphics::DirectX::Direct3D11::
                                 IDirect3DDxgiInterfaceAccess>();

    winrt::com_ptr<ID3D11Texture2D> texture;
    // Attempt to get the underlying ID3D11Texture2D.
    HRESULT hr = access->GetInterface(IID_PPV_ARGS(texture.put()));
    if (FAILED(hr)) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: GetInterface for ID3D11Texture2D failed: 0x%08X", hr);
      return nullptr;
    }
    return texture;
  } catch (winrt::hresult_error const &ex) {
    // This catch block will handle errors from surface.as<>() or other WinRT
    // exceptions.
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Error obtaining IDirect3DDxgiInterfaceAccess or "
               "ID3D11Texture2D from surface (WinRT error): %ls (0x%08X)",
               ex.message().c_str(), ex.code().value);
    return nullptr;
  } catch (...) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Unknown exception in GetTextureFromDirect3DSurface.");
    return nullptr;
  }
}

// --- Platform Ops Implementation ---

static MiniAVResultCode
wgc_get_default_formats(const char *device_id_utf8,
                        MiniAVVideoInfo *video_format_out,
                        MiniAVAudioInfo *audio_format_out) {
  if (!device_id_utf8 || !video_format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_format_out) {
    memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
  }

  HMONITOR hmonitor = NULL;
  HWND hwnd = NULL;
  WGCCaptureTargetType target_type = WGC_TARGET_NONE;

  if (strncmp(device_id_utf8, "HMONITOR:0x", 11) == 0) {
    if (sscanf_s(device_id_utf8, "HMONITOR:0x%p", (void **)&hmonitor) != 1 ||
        !hmonitor) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC GetDefaultFormats: Invalid display ID format: %s",
                 device_id_utf8);
      return MINIAV_ERROR_INVALID_ARG;
    }
    target_type = WGC_TARGET_DISPLAY;
  } else if (strncmp(device_id_utf8, "HWND:0x", 7) == 0) {
    if (sscanf_s(device_id_utf8, "HWND:0x%p", (void **)&hwnd) != 1 || !hwnd ||
        !IsWindow(hwnd)) {
      miniav_log(
          MINIAV_LOG_LEVEL_ERROR,
          "WGC GetDefaultFormats: Invalid window ID format or invalid HWND: %s",
          device_id_utf8);
      return MINIAV_ERROR_INVALID_ARG;
    }
    target_type = WGC_TARGET_WINDOW;
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC GetDefaultFormats: Unknown device ID format: %s",
               device_id_utf8);
    return MINIAV_ERROR_INVALID_ARG;
  }

  // --- Video Format ---
  video_format_out->pixel_format = MINIAV_PIXEL_FORMAT_BGRA32; // WGC default
  video_format_out->frame_rate_numerator = 60;
  video_format_out->frame_rate_denominator = 1;
  video_format_out->output_preference =
      MINIAV_OUTPUT_PREFERENCE_GPU; // Default preference

  if (target_type == WGC_TARGET_DISPLAY) {
    MONITORINFOEXW mi = {0};
    mi.cbSize = sizeof(MONITORINFOEXW);

    if (GetMonitorInfoW(hmonitor, (LPMONITORINFO)&mi)) {
      // Get the device name
      char device_name_utf8[256];
      WideCharToMultiByte(CP_UTF8, 0, mi.szDevice, -1, device_name_utf8,
                          sizeof(device_name_utf8), NULL, NULL);

      // Use EnumDisplaySettings to get the ACTUAL resolution
      DEVMODEW dev_mode = {0};
      dev_mode.dmSize = sizeof(DEVMODEW);

      if (EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &dev_mode)) {
        // Use the actual display resolution, not the virtual desktop
        // coordinates
        video_format_out->width = dev_mode.dmPelsWidth;
        video_format_out->height = dev_mode.dmPelsHeight;

        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "WGC GetDefaultFormats: Device %s - Virtual coords: "
                   "(%ld,%ld,%ld,%ld) = %ldx%ld",
                   device_name_utf8, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right, mi.rcMonitor.bottom,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top);
        miniav_log(
            MINIAV_LOG_LEVEL_DEBUG,
            "WGC GetDefaultFormats: Device %s - Actual resolution: %lux%lu",
            device_name_utf8, dev_mode.dmPelsWidth, dev_mode.dmPelsHeight);
      }
    }
  } else { // WGC_TARGET_WINDOW
    RECT rc;
    if (GetWindowRect(hwnd, &rc)) {
      video_format_out->width = rc.right - rc.left;
      video_format_out->height = rc.bottom - rc.top;
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC GetDefaultFormats: GetWindowRect failed for %s",
                 device_id_utf8);
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }
  if (video_format_out->width == 0 || video_format_out->height == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "WGC GetDefaultFormats: Target %s has zero width or height.",
               device_id_utf8);
    // Allow proceeding, but this is unusual. WGC might fail later if item size
    // is 0.
  }

  // --- Audio Format (Optional) ---
  if (audio_format_out) {
    const char *loopback_target_id_str = NULL;
    char process_id_string_buffer[64];

    if (target_type == WGC_TARGET_WINDOW && hwnd) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(hwnd, &process_id);
      if (process_id != 0) {
        snprintf(process_id_string_buffer, sizeof(process_id_string_buffer),
                 "PID:%lu", process_id);
        loopback_target_id_str = process_id_string_buffer;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "WGC GetDefaultFormats: Querying default audio for PID: %lu",
                   process_id);
      } else {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "WGC GetDefaultFormats: Could not get PID for HWND %p. "
                   "Querying system default audio.",
                   hwnd);
        // loopback_target_id_str remains NULL for system default
      }
    } else {
      miniav_log(
          MINIAV_LOG_LEVEL_DEBUG,
          "WGC GetDefaultFormats: Querying system default audio format.");
      // loopback_target_id_str remains NULL for system default
    }

    MiniAVResultCode audio_res = MiniAV_Loopback_GetDefaultFormat(
        loopback_target_id_str, audio_format_out);
    if (audio_res != MINIAV_SUCCESS) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "WGC GetDefaultFormats: Failed to get default audio format "
                 "for target %s (loopback ID %s): %s. Audio format not set.",
                 device_id_utf8,
                 loopback_target_id_str ? loopback_target_id_str
                                        : "(system default)",
                 MiniAV_GetErrorString(audio_res));
      // audio_format_out is already zeroed, so no need to do anything else.
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC GetDefaultFormats: Default audio format for target %s "
                 "(loopback ID %s): Format=%d, Ch=%u, Rate=%u",
                 device_id_utf8,
                 loopback_target_id_str ? loopback_target_id_str
                                        : "(system default)",
                 audio_format_out->format, audio_format_out->channels,
                 audio_format_out->sample_rate);
    }
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "WGC GetDefaultFormats: Video: %ux%u @ %u/%u FPS, PixelFormat: "
             "%d. Audio queried: %s",
             video_format_out->width, video_format_out->height,
             video_format_out->frame_rate_numerator,
             video_format_out->frame_rate_denominator,
             video_format_out->pixel_format, audio_format_out ? "Yes" : "No");

  return MINIAV_SUCCESS;
}

static MiniAVResultCode
wgc_get_configured_video_formats(MiniAVScreenContext *ctx,
                                 MiniAVVideoInfo *video_format_out,
                                 MiniAVAudioInfo *audio_format_out) {
  if (!ctx || !ctx->platform_ctx || !video_format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;

  memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_format_out) {
    memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
  }

  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "WGC GetConfiguredFormats: Context not configured.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  // Video format is stored in the parent context's configured_video_format
  // which is updated by wgc_configure_capture_item
  *video_format_out = ctx->configured_video_format;

  // Audio format
  if (audio_format_out) {
    if (wgc_ctx->audio_loopback_enabled_and_configured) {
      *audio_format_out = wgc_ctx->configured_audio_format;
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC GetConfiguredFormats: Audio: Format=%d, Ch=%u, Rate=%u",
                 audio_format_out->format, audio_format_out->channels,
                 audio_format_out->sample_rate);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC GetConfiguredFormats: Audio loopback not enabled or not "
                 "configured. Audio format not set.");
      // audio_format_out remains zeroed
    }
  }
  miniav_log(
      MINIAV_LOG_LEVEL_INFO,
      "WGC GetConfiguredFormats: Video: %ux%u @ %u/%u FPS, PixelFormat: %d. "
      "Audio configured: %s",
      video_format_out->width, video_format_out->height,
      video_format_out->frame_rate_numerator,
      video_format_out->frame_rate_denominator, video_format_out->pixel_format,
      (wgc_ctx->audio_loopback_enabled_and_configured && audio_format_out)
          ? "Yes"
          : "No/Not Requested");

  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_init_platform(MiniAVScreenContext *ctx) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Initializing platform context.");
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  MiniAVResultCode res = init_winrt_for_wgc();
  if (res != MINIAV_SUCCESS)
    return res;

  WGCScreenPlatformContext *wgc_ctx = (WGCScreenPlatformContext *)miniav_calloc(
      1, sizeof(WGCScreenPlatformContext));
  if (!wgc_ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Failed to allocate WGCScreenPlatformContext.");
    shutdown_winrt_for_wgc();
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ctx->platform_ctx = wgc_ctx;
  wgc_ctx->parent_ctx = ctx;
  wgc_ctx->pixel_format = MINIAV_PIXEL_FORMAT_BGRA32; // WGC default
  wgc_ctx->is_streaming = FALSE;
  wgc_ctx->qpc_frequency = miniav_get_qpc_frequency();
  wgc_ctx->loopback_audio_ctx = NULL; // Initialize audio loopback members
  wgc_ctx->audio_loopback_enabled_and_configured = FALSE;

  wgc_ctx->stop_event_handle =
      CreateEvent(NULL, TRUE, FALSE, NULL); // Manual-reset, non-signaled
  if (wgc_ctx->stop_event_handle == NULL) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: Failed to create stop event.");
    miniav_free(wgc_ctx);
    ctx->platform_ctx = NULL;
    shutdown_winrt_for_wgc();
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (!InitializeCriticalSectionAndSpinCount(&wgc_ctx->critical_section,
                                             0x00000400)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Failed to initialize critical section.");
    CloseHandle(wgc_ctx->stop_event_handle);
    miniav_free(wgc_ctx);
    ctx->platform_ctx = NULL;
    shutdown_winrt_for_wgc();
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  res = wgc_init_d3d_device(wgc_ctx);
  if (res != MINIAV_SUCCESS) {
    DeleteCriticalSection(&wgc_ctx->critical_section);
    CloseHandle(wgc_ctx->stop_event_handle);
    miniav_free(wgc_ctx);
    ctx->platform_ctx = NULL;
    shutdown_winrt_for_wgc();
    return res;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "WGC: Platform context initialized successfully.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_destroy_platform(MiniAVScreenContext *ctx) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Destroying platform context.");
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;

  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;

  if (wgc_ctx->is_streaming) {
    miniav_log(
        MINIAV_LOG_LEVEL_WARN,
        "WGC: Platform being destroyed while streaming. Attempting to stop.");
    // Ensure audio is stopped first if it was running
    if (wgc_ctx->loopback_audio_ctx &&
        wgc_ctx->audio_loopback_enabled_and_configured) {
      MiniAV_Loopback_StopCapture(wgc_ctx->loopback_audio_ctx);
    }
    if (wgc_ctx->stop_event_handle)
      SetEvent(wgc_ctx->stop_event_handle);
  }
  wgc_cleanup_capture_resources(wgc_ctx); // Cleans session, frame_pool, item
  wgc_cleanup_d3d_device(wgc_ctx);

  // Destroy loopback audio context if it exists
  if (wgc_ctx->loopback_audio_ctx) {
    MiniAV_Loopback_DestroyContext(wgc_ctx->loopback_audio_ctx);
    wgc_ctx->loopback_audio_ctx = NULL;
    wgc_ctx->audio_loopback_enabled_and_configured = FALSE;
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "WGC: Loopback audio context destroyed.");
  }

  if (wgc_ctx->stop_event_handle) {
    CloseHandle(wgc_ctx->stop_event_handle);
    wgc_ctx->stop_event_handle = NULL;
  }
  DeleteCriticalSection(&wgc_ctx->critical_section);

  miniav_free(wgc_ctx);
  ctx->platform_ctx = NULL;

  shutdown_winrt_for_wgc();
  miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Platform context destroyed.");
  return MINIAV_SUCCESS;
}

struct EnumDisplayData {
  std::vector<MiniAVDeviceInfo> *devices;
  uint32_t monitor_idx;
};

BOOL CALLBACK MonitorEnumProc(HMONITOR hMonitor, HDC hdcMonitor,
                              LPRECT lprcMonitor, LPARAM dwData) {
  MINIAV_UNUSED(hdcMonitor);
  MINIAV_UNUSED(lprcMonitor);
  EnumDisplayData *data = reinterpret_cast<EnumDisplayData *>(dwData);
  MONITORINFOEXW mi;
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(hMonitor, &mi)) {
    MiniAVDeviceInfo dev_info = {0};
    // ID: "HMONITOR:0xADDRESS"
    snprintf(dev_info.device_id, MINIAV_DEVICE_ID_MAX_LEN, "HMONITOR:0x%p",
             (void *)hMonitor);
    WideCharToMultiByte(CP_UTF8, 0, mi.szDevice, -1, dev_info.name,
                        MINIAV_DEVICE_NAME_MAX_LEN, NULL, NULL);
    dev_info.is_default = (mi.dwFlags & MONITORINFOF_PRIMARY) ? TRUE : FALSE;
    data->devices->push_back(dev_info);
    data->monitor_idx++;
  }
  return TRUE;
}

static MiniAVResultCode wgc_enumerate_displays(MiniAVDeviceInfo **displays_out,
                                               uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Enumerating displays.");
  if (!displays_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *displays_out = NULL;
  *count_out = 0;

  std::vector<MiniAVDeviceInfo> devices;
  EnumDisplayData data = {&devices, 0};

  if (!EnumDisplayMonitors(NULL, NULL, MonitorEnumProc,
                           reinterpret_cast<LPARAM>(&data))) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: EnumDisplayMonitors failed: %lu",
               GetLastError());
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (!devices.empty()) {
    *displays_out = (MiniAVDeviceInfo *)miniav_calloc(devices.size(),
                                                      sizeof(MiniAVDeviceInfo));
    if (!*displays_out) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to allocate memory for display list.");
      return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    memcpy(*displays_out, devices.data(),
           devices.size() * sizeof(MiniAVDeviceInfo));
    *count_out = static_cast<uint32_t>(devices.size());
  }
  miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Enumerated %u displays.", *count_out);
  return MINIAV_SUCCESS;
}

struct EnumWindowData {
  std::vector<MiniAVDeviceInfo> *devices;
  DWORD current_pid;
};

BOOL CALLBACK WindowEnumProc(HWND hWnd, LPARAM lParam) {
  EnumWindowData *data = reinterpret_cast<EnumWindowData *>(lParam);

  // Skip non-visible, non-capturable, or own process windows
  if (!IsWindowVisible(hWnd) || GetAncestor(hWnd, GA_ROOTOWNER) != hWnd) {
    return TRUE;
  }

  // Skip tool windows, etc.
  LONG style = GetWindowLong(hWnd, GWL_STYLE);
  if (!(style & WS_VISIBLE) ||
      (style & WS_CHILD)) { // Must be visible, not child
    return TRUE;
  }
  LONG ex_style = GetWindowLong(hWnd, GWL_EXSTYLE);
  if (ex_style & WS_EX_TOOLWINDOW) { // Skip tool windows
    return TRUE;
  }

  // Check if the window is cloaked (e.g., UWP apps minimized)
  // WGC cannot capture cloaked windows.
  DWORD cloaked = 0;
  HRESULT hr_dwm =
      DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  if (SUCCEEDED(hr_dwm) && cloaked != 0) {
    return TRUE;
  }

  wchar_t title_w[MINIAV_DEVICE_NAME_MAX_LEN];
  int len = GetWindowTextW(hWnd, title_w, MINIAV_DEVICE_NAME_MAX_LEN);
  if (len == 0 &&
      GetLastError() != 0) { // GetWindowTextW sets last error on failure
    // Could log error, or just skip if title is empty / error
    return TRUE;
  }
  if (len == 0) { // Skip windows with no title
    return TRUE;
  }

  // Skip current process's windows to avoid potential issues
  DWORD window_pid;
  GetWindowThreadProcessId(hWnd, &window_pid);
  if (window_pid == data->current_pid) {
    return TRUE;
  }

  MiniAVDeviceInfo dev_info = {0};
  snprintf(dev_info.device_id, MINIAV_DEVICE_ID_MAX_LEN, "HWND:0x%p",
           (void *)hWnd);
  WideCharToMultiByte(CP_UTF8, 0, title_w, -1, dev_info.name,
                      MINIAV_DEVICE_NAME_MAX_LEN, NULL, NULL);
  dev_info.is_default = FALSE; // No concept of "default" window for capture
  data->devices->push_back(dev_info);

  return TRUE;
}

static MiniAVResultCode wgc_enumerate_windows(MiniAVDeviceInfo **windows_out,
                                              uint32_t *count_out) {
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Enumerating windows.");
  if (!windows_out || !count_out)
    return MINIAV_ERROR_INVALID_ARG;
  *windows_out = NULL;
  *count_out = 0;

  std::vector<MiniAVDeviceInfo> devices;
  EnumWindowData data = {&devices, GetCurrentProcessId()};

  if (!EnumWindows(WindowEnumProc, reinterpret_cast<LPARAM>(&data))) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: EnumWindows failed: %lu",
               GetLastError());
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (!devices.empty()) {
    *windows_out = (MiniAVDeviceInfo *)miniav_calloc(devices.size(),
                                                     sizeof(MiniAVDeviceInfo));
    if (!*windows_out) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to allocate memory for window list.");
      return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    memcpy(*windows_out, devices.data(),
           devices.size() * sizeof(MiniAVDeviceInfo));
    *count_out = static_cast<uint32_t>(devices.size());
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Enumerated %u windows.", *count_out);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_configure_capture_item(
    WGCScreenPlatformContext *wgc_ctx, const char *item_id_utf8,
    WGCCaptureTargetType target_type, const MiniAVVideoInfo *format) {
  if (wgc_ctx->is_streaming) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Cannot configure while streaming.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  wgc_cleanup_capture_resources(
      wgc_ctx); // Clean up previous item, session, pool

  // Clean up previous audio context if any, before configuring new video item
  if (wgc_ctx->loopback_audio_ctx) {
    MiniAV_Loopback_DestroyContext(wgc_ctx->loopback_audio_ctx);
    wgc_ctx->loopback_audio_ctx = NULL;
    wgc_ctx->audio_loopback_enabled_and_configured = FALSE;
  }

  HMONITOR hmonitor = NULL;
  HWND hwnd = NULL;

  if (target_type == WGC_TARGET_DISPLAY) {
    if (sscanf_s(item_id_utf8, "HMONITOR:0x%p", (void **)&hmonitor) != 1 ||
        !hmonitor) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: Invalid display ID format: %s",
                 item_id_utf8);
      return MINIAV_ERROR_INVALID_ARG;
    }
    wgc_ctx->parent_ctx->is_configured = TRUE;
    wgc_ctx->selected_hmonitor = hmonitor;
    wgc_ctx->selected_hwnd = NULL;
  } else if (target_type == WGC_TARGET_WINDOW) {
    if (sscanf_s(item_id_utf8, "HWND:0x%p", (void **)&hwnd) != 1 || !hwnd ||
        !IsWindow(hwnd)) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Invalid window ID format or invalid HWND: %s",
                 item_id_utf8);
      return MINIAV_ERROR_INVALID_ARG;
    }
    wgc_ctx->parent_ctx->is_configured = TRUE;
    wgc_ctx->selected_hwnd = hwnd;
    wgc_ctx->selected_hmonitor = NULL;
  } else {
    return MINIAV_ERROR_INVALID_ARG;
  }

  try {
    auto factory = winrt::get_activation_factory<
        winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
        IGraphicsCaptureItemInterop>();

    if (target_type == WGC_TARGET_DISPLAY) {
      factory->CreateForMonitor(
          hmonitor,
          winrt::guid_of<
              winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
          reinterpret_cast<void **>(winrt::put_abi(wgc_ctx->capture_item)));
    } else { // WGC_TARGET_WINDOW
      factory->CreateForWindow(
          hwnd,
          winrt::guid_of<
              winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
          reinterpret_cast<void **>(winrt::put_abi(wgc_ctx->capture_item)));
    }

    if (!wgc_ctx->capture_item) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to create GraphicsCaptureItem for %s.",
                 item_id_utf8);
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }

    // Store configuration
    wgc_ctx->configured_video_format = *format;
    if (format->frame_rate_denominator > 0 &&
        format->frame_rate_numerator > 0) {
      wgc_ctx->target_fps =
          format->frame_rate_numerator / format->frame_rate_denominator;
    } else {
      wgc_ctx->target_fps = 60;
    }
    if (wgc_ctx->target_fps == 0)
      wgc_ctx->target_fps = 1;

    auto item_size = wgc_ctx->capture_item.Size();
    wgc_ctx->frame_width = static_cast<UINT>(item_size.Width);
    wgc_ctx->frame_height = static_cast<UINT>(item_size.Height);

    // Update parent context's configured format
    wgc_ctx->parent_ctx->configured_video_format.width = wgc_ctx->frame_width;
    wgc_ctx->parent_ctx->configured_video_format.height = wgc_ctx->frame_height;
    wgc_ctx->parent_ctx->configured_video_format.pixel_format =
        wgc_ctx->pixel_format;
    wgc_ctx->parent_ctx->configured_video_format.frame_rate_numerator =
        wgc_ctx->target_fps;
    wgc_ctx->parent_ctx->configured_video_format.frame_rate_denominator = 1;
    wgc_ctx->parent_ctx->configured_video_format.output_preference =
        format->output_preference;

    wgc_ctx->current_target_type = target_type;
    miniav_strlcpy(wgc_ctx->selected_item_id, item_id_utf8,
                   MINIAV_DEVICE_ID_MAX_LEN);

    // --- Configure Audio Loopback (after video item is successfully created)
    // ---
    wgc_ctx->audio_loopback_enabled_and_configured = FALSE; // Default
    if (wgc_ctx->parent_ctx->capture_audio_requested) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC: Audio capture requested. Attempting to configure audio "
                 "loopback.");
      MiniAVResultCode audio_res =
          MiniAV_Loopback_CreateContext(&wgc_ctx->loopback_audio_ctx);
      if (audio_res == MINIAV_SUCCESS) {
        MiniAVAudioInfo desired_audio_format; // Define your desired format
        memset(&desired_audio_format, 0, sizeof(MiniAVAudioInfo));
        desired_audio_format.format = MINIAV_AUDIO_FORMAT_F32;
        desired_audio_format.channels = 2;
        desired_audio_format.sample_rate = 48000;

        const char *audio_target_device_id_str = NULL;
        char process_id_string_buffer[64]; // Buffer for "PID:XXXXX"

        if (target_type == WGC_TARGET_WINDOW && wgc_ctx->selected_hwnd) {
          DWORD process_id = 0;
          GetWindowThreadProcessId(wgc_ctx->selected_hwnd, &process_id);
          if (process_id != 0) {
            miniav_log(
                MINIAV_LOG_LEVEL_DEBUG,
                "WGC: Targeting audio from process PID: %lu for HWND: %p",
                process_id, wgc_ctx->selected_hwnd);
            // Construct the target_device_id_str for process
            // Ensure your MiniAV_Loopback_Configure expects this format e.g.
            // "PID:1234"
            snprintf(process_id_string_buffer, sizeof(process_id_string_buffer),
                     "PID:%lu", process_id);
            audio_target_device_id_str = process_id_string_buffer;
          } else {
            miniav_log(MINIAV_LOG_LEVEL_WARN,
                       "WGC: Could not get PID for HWND %p. Falling back to "
                       "default system audio loopback.",
                       wgc_ctx->selected_hwnd);
            // audio_target_device_id_str remains NULL for default
          }
        }
        // If not window target, or PID failed, audio_target_device_id_str
        // remains NULL for default system audio

        audio_res = MiniAV_Loopback_Configure(
            wgc_ctx->loopback_audio_ctx,
            audio_target_device_id_str, // Pass NULL for default system audio,
                                        // or "PID:XXXX" for process
            &desired_audio_format);

        if (audio_res == MINIAV_SUCCESS) {
          audio_res = MiniAV_Loopback_GetConfiguredFormat(
              wgc_ctx->loopback_audio_ctx, &wgc_ctx->configured_audio_format);
          if (audio_res == MINIAV_SUCCESS) {
            wgc_ctx->audio_loopback_enabled_and_configured = TRUE;
            miniav_log(
                MINIAV_LOG_LEVEL_INFO,
                "WGC: Audio loopback configured. Format: %d, Ch: %u, Rate: %u",
                wgc_ctx->configured_audio_format.format,
                wgc_ctx->configured_audio_format.channels,
                wgc_ctx->configured_audio_format.sample_rate);
          } else {
            miniav_log(MINIAV_LOG_LEVEL_WARN,
                       "WGC: Failed to get configured audio format: %s. Audio "
                       "disabled.",
                       MiniAV_GetErrorString(audio_res));
            MiniAV_Loopback_DestroyContext(wgc_ctx->loopback_audio_ctx);
            wgc_ctx->loopback_audio_ctx = NULL;
          }
        } else {
          miniav_log(
              MINIAV_LOG_LEVEL_WARN,
              "WGC: Failed to configure audio loopback: %s. Audio disabled.",
              MiniAV_GetErrorString(audio_res));
          MiniAV_Loopback_DestroyContext(wgc_ctx->loopback_audio_ctx);
          wgc_ctx->loopback_audio_ctx = NULL;
        }
      } else {
        miniav_log(
            MINIAV_LOG_LEVEL_WARN,
            "WGC: Failed to create audio loopback context: %s. Audio disabled.",
            MiniAV_GetErrorString(audio_res));
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Audio capture not requested.");
    }
    // --- End Audio Loopback Configuration ---

    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "WGC: Configured for item %s. Actual res: %ux%u, Target FPS: "
               "%u, OutputPref: %d, Audio: %s",
               item_id_utf8, wgc_ctx->frame_width, wgc_ctx->frame_height,
               wgc_ctx->target_fps, format->output_preference,
               wgc_ctx->audio_loopback_enabled_and_configured ? "Enabled"
                                                              : "Disabled");

  } catch (winrt::hresult_error const &ex) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Configuration failed for %s: %ls (0x%08X)", item_id_utf8,
               ex.message().c_str(), ex.code().value);
    wgc_cleanup_capture_resources(wgc_ctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_configure_display(MiniAVScreenContext *ctx,
                                              const char *display_id_utf8,
                                              const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !display_id_utf8 || !format)
    return MINIAV_ERROR_INVALID_ARG;
  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Configuring display ID: %s",
             display_id_utf8);
  return wgc_configure_capture_item(wgc_ctx, display_id_utf8,
                                    WGC_TARGET_DISPLAY, format);
}

static MiniAVResultCode wgc_configure_window(MiniAVScreenContext *ctx,
                                             const char *window_id_utf8,
                                             const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !window_id_utf8 || !format)
    return MINIAV_ERROR_INVALID_ARG;
  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Configuring window ID: %s",
             window_id_utf8);
  return wgc_configure_capture_item(wgc_ctx, window_id_utf8, WGC_TARGET_WINDOW,
                                    format);
}

static MiniAVResultCode wgc_configure_region(MiniAVScreenContext *ctx,
                                             const char *display_id_utf8, int x,
                                             int y, int width, int height,
                                             const MiniAVVideoInfo *format) {
  MINIAV_UNUSED(ctx);
  MINIAV_UNUSED(display_id_utf8);
  MINIAV_UNUSED(x);
  MINIAV_UNUSED(y);
  MINIAV_UNUSED(width);
  MINIAV_UNUSED(height);
  MINIAV_UNUSED(format);
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "WGC: ConfigureRegion is not supported. WGC captures full items.");
  return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode wgc_start_capture(MiniAVScreenContext *ctx,
                                          MiniAVBufferCallback callback,
                                          void *user_data) {
  if (!ctx || !ctx->platform_ctx || !callback)
    return MINIAV_ERROR_INVALID_ARG;
  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;
  MiniAVResultCode res = MINIAV_SUCCESS;

  EnterCriticalSection(&wgc_ctx->critical_section);
  if (wgc_ctx->is_streaming) {
    LeaveCriticalSection(&wgc_ctx->critical_section);
    miniav_log(MINIAV_LOG_LEVEL_WARN, "WGC: Capture already started.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }
  if (!wgc_ctx->capture_item || !wgc_ctx->d3d_device_winrt) {
    LeaveCriticalSection(&wgc_ctx->critical_section);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Not configured or D3D device not ready. Call "
               "ConfigureDisplay/Window first.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  wgc_ctx->app_callback_internal = callback;
  wgc_ctx->app_callback_user_data_internal = user_data;
  // Also update parent context's callback info
  wgc_ctx->parent_ctx->app_callback = callback;
  wgc_ctx->parent_ctx->app_callback_user_data = user_data;

  // --- Start Audio Loopback Capture ---
  if (wgc_ctx->loopback_audio_ctx &&
      wgc_ctx->audio_loopback_enabled_and_configured) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Starting audio loopback capture.");
    res = MiniAV_Loopback_StartCapture(
        wgc_ctx->loopback_audio_ctx,
        wgc_ctx->app_callback_internal, // Use the same callback
        wgc_ctx->app_callback_user_data_internal);
    if (res != MINIAV_SUCCESS) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to start audio loopback capture: %s. Proceeding "
                 "with video only.",
                 MiniAV_GetErrorString(res));
      // Video will still attempt to start. Audio is considered optional here.
      // To be very robust, you might set audio_loopback_enabled_and_configured
      // to FALSE here.
    } else {
      miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Audio loopback capture started.");
    }
  }
  // --- End Audio Loopback Capture ---

  try {
    // Pixel format for frame pool is typically B8G8R8A8_UNORM
    auto pixel_format_dxgi = winrt::Windows::Graphics::DirectX::
        DirectXPixelFormat::B8G8R8A8UIntNormalized;
    auto item_size = wgc_ctx->capture_item.Size();

    // Create frame pool
    wgc_ctx->frame_pool =
        winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::
            CreateFreeThreaded(wgc_ctx->d3d_device_winrt, pixel_format_dxgi,
                               2, // Number of buffers in the pool
                               item_size);

    if (!wgc_ctx->frame_pool) {
      LeaveCriticalSection(&wgc_ctx->critical_section);
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to create Direct3D11CaptureFramePool.");
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }

    // Create session
    wgc_ctx->session =
        wgc_ctx->frame_pool.CreateCaptureSession(wgc_ctx->capture_item);
    if (!wgc_ctx->session) {
      wgc_ctx->frame_pool = nullptr; // Release frame pool
      LeaveCriticalSection(&wgc_ctx->critical_section);
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to create GraphicsCaptureSession.");
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }

    wgc_ctx->frame_arrived_token = wgc_ctx->frame_pool.FrameArrived(
        [wgc_ctx_capture = wgc_ctx](auto &&sender, auto &&args) {
          wgc_on_frame_arrived(wgc_ctx_capture, sender, args);
        });

    ResetEvent(wgc_ctx->stop_event_handle);
    wgc_ctx->is_streaming =
        TRUE; // Set after potential audio start, before WGC session start
    wgc_ctx->session.StartCapture();

  } catch (winrt::hresult_error const &ex) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: StartCapture failed: %ls (0x%08X)",
               ex.message().c_str(), ex.code().value);
    wgc_cleanup_capture_resources(wgc_ctx); // Clean up session, pool, item
    wgc_ctx->is_streaming = FALSE;
    // If audio started successfully but video failed, stop audio
    if (wgc_ctx->loopback_audio_ctx &&
        wgc_ctx->audio_loopback_enabled_and_configured &&
        res == MINIAV_SUCCESS) { // res checks if audio start was ok
      MiniAV_Loopback_StopCapture(wgc_ctx->loopback_audio_ctx);
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "WGC: Stopped audio loopback due to video start failure.");
    }
    LeaveCriticalSection(&wgc_ctx->critical_section);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  LeaveCriticalSection(&wgc_ctx->critical_section);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Capture started for item %s.",
             wgc_ctx->selected_item_id);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_stop_capture(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->platform_ctx)
    return MINIAV_ERROR_NOT_INITIALIZED;
  WGCScreenPlatformContext *wgc_ctx =
      (WGCScreenPlatformContext *)ctx->platform_ctx;
  BOOL was_streaming_video = FALSE;

  EnterCriticalSection(&wgc_ctx->critical_section);
  if (!wgc_ctx->is_streaming) { // This flag covers video streaming primarily
    LeaveCriticalSection(&wgc_ctx->critical_section);
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "WGC: Video capture not started or already stopped.");
    // Audio might still be running if video failed to start but audio
    // succeeded. However, the public API stop should ideally handle this. For
    // now, if video wasn't streaming, we assume audio also isn't (or shouldn't
    // be).
    return MINIAV_SUCCESS;
  }
  was_streaming_video = wgc_ctx->is_streaming;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Stopping capture for item %s.",
             wgc_ctx->selected_item_id);
  SetEvent(
      wgc_ctx
          ->stop_event_handle);  // Signal any waiting in frame handler to stop
  wgc_ctx->is_streaming = FALSE; // Set video streaming flag early

  // Unregister event handler and close session/pool for video
  // This needs to happen before releasing wgc_ctx if the lambda captures it.
  try {
    if (wgc_ctx->frame_pool && wgc_ctx->frame_arrived_token.value != 0) {
      wgc_ctx->frame_pool.FrameArrived(wgc_ctx->frame_arrived_token);
      wgc_ctx->frame_arrived_token.value = 0; // Mark as unregistered
    }
    if (wgc_ctx->session) {
      wgc_ctx->session.Close(); // This should stop FrameArrived events
      wgc_ctx->session = nullptr;
    }
    if (wgc_ctx->frame_pool) {
      wgc_ctx->frame_pool.Close();
      wgc_ctx->frame_pool = nullptr;
    }
    // capture_item is cleaned up in configure or destroy_platform
  } catch (winrt::hresult_error const &ex) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "WGC: Exception during stop_capture resource cleanup: %ls",
               ex.message().c_str());
  }

  LeaveCriticalSection(&wgc_ctx->critical_section);
  // --- Stop Audio Loopback Capture ---
  // Check if audio was successfully configured and we *think* it might have
  // started
  if (wgc_ctx->loopback_audio_ctx &&
      wgc_ctx->audio_loopback_enabled_and_configured && was_streaming_video) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Stopping audio loopback capture.");
    MiniAVResultCode audio_stop_res =
        MiniAV_Loopback_StopCapture(wgc_ctx->loopback_audio_ctx);
    if (audio_stop_res == MINIAV_SUCCESS) {
      miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Audio loopback capture stopped.");
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "WGC: Failed to stop audio loopback capture cleanly: %s",
                 MiniAV_GetErrorString(audio_stop_res));
    }
  }
  // --- End Audio Loopback Capture ---

  miniav_log(MINIAV_LOG_LEVEL_INFO, "WGC: Capture stopped for item %s.",
             wgc_ctx->selected_item_id);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode wgc_release_buffer(MiniAVScreenContext *ctx,
                                           void *internal_handle_ptr) {
  MINIAV_UNUSED(
      ctx); // ctx might be useful for logging or D3D context if not in payload

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "WGC: release_buffer called with internal_handle_ptr=%p",
             internal_handle_ptr);

  if (!internal_handle_ptr) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "WGC: release_buffer called with NULL internal_handle_ptr.");
    return MINIAV_SUCCESS;
  }

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "WGC: payload ptr=%p, handle_type=%d, "
             "native_singular_resource_ptr=%p, num_planar_resources=%u",
             payload, payload->handle_type,
             payload->native_singular_resource_ptr,
             payload->num_planar_resources_to_release);

  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN) {

    // Handle multi-plane resources (rarely used for WGC, but supported)
    if (payload->num_planar_resources_to_release > 0) {
      for (uint32_t i = 0; i < payload->num_planar_resources_to_release; ++i) {
        if (payload->native_planar_resource_ptrs[i]) {
          // For WGC, this would typically be additional D3D11 textures
          ID3D11Texture2D *texture =
              (ID3D11Texture2D *)payload->native_planar_resource_ptrs[i];
          ULONG ref_count = texture->Release();
          miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                     "WGC: Released planar texture %u. Ref count: %lu", i,
                     ref_count);
          payload->native_planar_resource_ptrs[i] = NULL;
        }
      }
    }

    // Handle single resource (typical case)
    if (payload->native_singular_resource_ptr) {
      WGCFrameReleasePayload *frame_payload =
          (WGCFrameReleasePayload *)payload->native_singular_resource_ptr;

      if (frame_payload) {
        if (frame_payload->original_output_preference ==
                MINIAV_OUTPUT_PREFERENCE_CPU ||
            (frame_payload->cpu_staging_texture_to_unmap_release)) {
          if (frame_payload->d3d_context_for_unmap &&
              frame_payload->cpu_staging_texture_to_unmap_release) {
            frame_payload->d3d_context_for_unmap->Unmap(
                frame_payload->cpu_staging_texture_to_unmap_release,
                frame_payload->subresource_for_unmap);
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "WGC: Unmapped CPU staging texture.");
          }
          if (frame_payload->cpu_staging_texture_to_unmap_release) {
            ULONG ref_count =
                frame_payload->cpu_staging_texture_to_unmap_release->Release();
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "WGC: Released CPU staging texture. Ref count: %lu",
                       ref_count);
          }
          if (frame_payload->d3d_context_for_unmap) {
            frame_payload->d3d_context_for_unmap->Release();
            frame_payload->d3d_context_for_unmap = nullptr;
          }
        } else if (frame_payload->actual_output_preference ==
                   MINIAV_OUTPUT_PREFERENCE_GPU) {
          if (frame_payload->gpu_texture_to_release) {
            ULONG ref_count = frame_payload->gpu_texture_to_release->Release();
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "WGC: Released GPU texture for payload. Ref count: %lu",
                       ref_count);
          }
          if (frame_payload->gpu_shared_handle_to_close) {
            miniav_log(
                MINIAV_LOG_LEVEL_DEBUG,
                "WGC: App is responsible for closing GPU shared handle %p.",
                frame_payload->gpu_shared_handle_to_close);
          }
        } else {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "WGC: Unexpected preference (orig=%d actual=%d)",
                     frame_payload->original_output_preference,
                     frame_payload->actual_output_preference);
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
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: Released buffer payload.");
    return MINIAV_SUCCESS;
  } else {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "WGC: release_buffer called for unknown handle_type %d.",
               payload->handle_type);
    if (payload->parent_miniav_buffer_ptr) {
      miniav_free(payload->parent_miniav_buffer_ptr);
      payload->parent_miniav_buffer_ptr = NULL;
    }
    miniav_free(payload);
    return MINIAV_SUCCESS;
  }
}

// --- D3D and WGC Resource Management ---
static MiniAVResultCode wgc_init_d3d_device(WGCScreenPlatformContext *wgc_ctx) {
  HRESULT hr = S_OK;
  UINT creation_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#ifdef _DEBUG
  // creation_flags |= D3D11_CREATE_DEVICE_DEBUG; // Enable if SDK Layers are
  // installed
#endif
  D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL feature_level;

  winrt::com_ptr<ID3D11Device> device_com;
  winrt::com_ptr<ID3D11DeviceContext> context_com;

  hr = D3D11CreateDevice(
      nullptr, // Specify null to use the default adapter.
      D3D_DRIVER_TYPE_HARDWARE,
      nullptr, // No software rasterizer module.
      creation_flags, feature_levels, ARRAYSIZE(feature_levels),
      D3D11_SDK_VERSION,
      device_com.put(), // Returns the Direct3D device created.
      &feature_level,   // Returns feature level of device created.
      context_com.put() // Returns the device immediate context.
  );

  if (FAILED(hr)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: D3D11CreateDevice failed: 0x%X",
               hr);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  wgc_ctx->d3d_device = device_com;
  wgc_ctx->d3d_context = context_com;

  // Get the IDirect3DDevice (WinRT type) from the ID3D11Device (COM type)
  try {
    // First, get the IDXGIDevice interface from the ID3D11Device.
    // ID3D11Device inherits from IDXGIDevice.
    winrt::com_ptr<IDXGIDevice> dxgi_device = device_com.as<IDXGIDevice>();
    // If device_com doesn't support IDXGIDevice (which it should), .as<>() will
    // throw.

    // Now, use the interop function to create the WinRT IDirect3DDevice.
    // CreateDirect3DDevice is a free function from
    // <windows.graphics.directx.direct3d11.interop.h>. It expects a raw
    // IInspectable** for the output, which winrt::put_abi provides.
    hr = CreateDirect3D11DeviceFromDXGIDevice(
        dxgi_device.get(), reinterpret_cast<IInspectable **>(
                               winrt::put_abi(wgc_ctx->d3d_device_winrt)));
    if (FAILED(hr)) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: CreateDirect3DDevice failed: 0x%X", hr);
      // Throw an hresult_error to be caught by the catch block below, ensuring
      // cleanup.
      throw winrt::hresult_error(
          hr, L"CreateDirect3DDevice interop function failed");
    }

    if (!wgc_ctx->d3d_device_winrt) {
      // This case should ideally not be reached if CreateDirect3DDevice
      // succeeded (returned S_OK) and didn't set the output parameter, but it's
      // a safeguard.
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: CreateDirect3DDevice succeeded but resulted in a null "
                 "IDirect3DDevice (WinRT).");
      throw winrt::hresult_error(
          E_FAIL, L"CreateDirect3DDevice resulted in null WinRT device");
    }
  } catch (winrt::hresult_error const &ex) {
    miniav_log(
        MINIAV_LOG_LEVEL_ERROR,
        "WGC: Failed to get IDirect3DDevice from ID3D11Device: %ls (0x%08X)",
        ex.message().c_str(), ex.code().value);
    wgc_cleanup_d3d_device(
        wgc_ctx); // Ensure D3D resources are cleaned up on failure
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "WGC: D3D11 device and context initialized.");
  return MINIAV_SUCCESS;
}

static void wgc_cleanup_d3d_device(WGCScreenPlatformContext *wgc_ctx) {
  if (wgc_ctx->d3d_device_winrt) {
    wgc_ctx->d3d_device_winrt = nullptr;
  }
  if (wgc_ctx->d3d_context) {
    wgc_ctx->d3d_context->ClearState();
    wgc_ctx->d3d_context->Flush();
    wgc_ctx->d3d_context = nullptr; // Releases COM ptr
  }
  if (wgc_ctx->d3d_device) {
    wgc_ctx->d3d_device = nullptr; // Releases COM ptr
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "WGC: D3D11 device and context cleaned up.");
}

static void wgc_cleanup_capture_resources(WGCScreenPlatformContext *wgc_ctx) {
  // Critical section should be held by caller if is_streaming is modified
  if (wgc_ctx->frame_pool && wgc_ctx->frame_arrived_token.value != 0) {
    try {
      wgc_ctx->frame_pool.FrameArrived(wgc_ctx->frame_arrived_token);
    } catch (...) { /* ignore errors during cleanup */
    }
    wgc_ctx->frame_arrived_token.value = 0;
  }
  if (wgc_ctx->session) {
    try {
      wgc_ctx->session.Close();
    } catch (...) {
    }
    wgc_ctx->session = nullptr;
  }
  if (wgc_ctx->frame_pool) {
    try {
      wgc_ctx->frame_pool.Close();
    } catch (...) {
    }
    wgc_ctx->frame_pool = nullptr;
  }
  if (wgc_ctx->capture_item) {
    wgc_ctx->capture_item = nullptr;
  }
  wgc_ctx->current_target_type = WGC_TARGET_NONE;
  wgc_ctx->selected_item_id[0] = '\0';
  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "WGC: Capture-specific resources (item, pool, session) cleaned up.");
}

// --- Frame Arrived Handler ---
// --- Frame Arrived Handler ---
static void wgc_on_frame_arrived(
    WGCScreenPlatformContext *wgc_ctx,
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const &sender,
    winrt::Windows::Foundation::IInspectable const & /*args*/) {
  if (!wgc_ctx || !wgc_ctx->is_streaming) { // Check atomic bool
    if (sender) { // Try to get next frame to release it back to pool if session
                  // is active
      try {
        auto frame = sender.TryGetNextFrame();
        if (frame)
          frame.Close();
      } catch (...) {
      }
    }
    return;
  }

  // Check stop event
  if (WaitForSingleObject(wgc_ctx->stop_event_handle, 0) == WAIT_OBJECT_0) {
    if (sender) {
      try {
        auto frame = sender.TryGetNextFrame();
        if (frame)
          frame.Close();
      } catch (...) {
      }
    }
    return;
  }

  winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame frame{nullptr};
  try {
    frame = sender.TryGetNextFrame();
  } catch (winrt::hresult_error const &ex) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "WGC: TryGetNextFrame failed: %ls",
               ex.message().c_str());
    // This can happen if the session is closed or item is gone.
    // Consider stopping capture if this persists.
    return;
  }

  if (!frame) {
    // miniav_log(MINIAV_LOG_LEVEL_DEBUG, "WGC: No frame available.");
    return;
  }

  // Enter CS to safely access app_callback and user_data
  // This also protects against concurrent stop_capture changing these.
  EnterCriticalSection(&wgc_ctx->critical_section);
  if (!wgc_ctx->is_streaming || !wgc_ctx->app_callback_internal) {
    LeaveCriticalSection(&wgc_ctx->critical_section);
    if (frame)
      frame.Close();
    return;
  }

  MiniAVBuffer *buffer = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  if (!buffer) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "WGC: Failed to allocate MiniAVBuffer");
    LeaveCriticalSection(&wgc_ctx->critical_section);
    if (frame)
      frame.Close();
    return;
  }

  WGCFrameReleasePayload *frame_payload_app = nullptr;
  MiniAVNativeBufferInternalPayload *internal_payload = nullptr;
  winrt::com_ptr<ID3D11Texture2D> acquired_texture_com = nullptr;
  winrt::com_ptr<ID3D11Texture2D> texture_for_payload_ref_com =
      nullptr; // AddRef'd for payload
  HANDLE shared_handle_for_app = NULL;
  bool processed_as_gpu = false;
  HRESULT hr = S_OK;

  try {
    auto surface = frame.Surface();
    if (!surface) {
      miniav_log(MINIAV_LOG_LEVEL_WARN, "WGC: Frame has no surface.");
      throw winrt::hresult_error(E_FAIL, L"Frame has no surface");
    }
    acquired_texture_com = GetTextureFromDirect3DSurface(surface);
    if (!acquired_texture_com) {
      throw winrt::hresult_error(E_FAIL, L"Failed to get texture from surface");
    }

    auto timestamp_raw =
        frame.SystemRelativeTime(); // TimeSpan (100-nanosecond units)
    buffer->timestamp_us = static_cast<uint64_t>(timestamp_raw.count() /
                                                 10); // Convert 100ns to us

    auto frame_content_size = frame.ContentSize();
    buffer->data.video.info.width =
        static_cast<uint32_t>(frame_content_size.Width);
    buffer->data.video.info.height =
        static_cast<uint32_t>(frame_content_size.Height);
    buffer->data.video.info.pixel_format = wgc_ctx->pixel_format; // BGRA32
    buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
    buffer->user_data = wgc_ctx->app_callback_user_data_internal;

    MiniAVOutputPreference desired_output_pref =
        wgc_ctx->configured_video_format.output_preference;

    // --- GPU Path Attempt ---
    if (desired_output_pref == MINIAV_OUTPUT_PREFERENCE_GPU &&
        wgc_ctx->d3d_device) {
      D3D11_TEXTURE2D_DESC acquired_desc;
      acquired_texture_com->GetDesc(&acquired_desc);

      winrt::com_ptr<ID3D11Texture2D> texture_to_share_com =
          acquired_texture_com;
      bool needs_copy_for_sharing =
          !(acquired_desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) &&
          !(acquired_desc.MiscFlags & D3D11_RESOURCE_MISC_SHARED);

      winrt::com_ptr<ID3D11Texture2D> shareable_copy_temp_com = nullptr;

      if (needs_copy_for_sharing) {
        miniav_log(
            MINIAV_LOG_LEVEL_DEBUG,
            "WGC: Acquired texture not shareable, creating a shareable copy.");
        D3D11_TEXTURE2D_DESC shareable_desc = acquired_desc; // Start with copy
        shareable_desc.Usage = D3D11_USAGE_DEFAULT;
        shareable_desc.BindFlags =
            D3D11_BIND_SHADER_RESOURCE |
            D3D11_BIND_RENDER_TARGET; // Typical for shared
        shareable_desc.CPUAccessFlags = 0;
        shareable_desc.MiscFlags =
            D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;

        hr = wgc_ctx->d3d_device->CreateTexture2D(
            &shareable_desc, nullptr, shareable_copy_temp_com.put());
        if (SUCCEEDED(hr)) {
          wgc_ctx->d3d_context->CopyResource(shareable_copy_temp_com.get(),
                                             acquired_texture_com.get());
          texture_to_share_com = shareable_copy_temp_com;
        } else {
          miniav_log(MINIAV_LOG_LEVEL_ERROR,
                     "WGC: Failed to create shareable GPU texture copy: 0x%X. "
                     "Fallback to CPU.",
                     hr);
          // Force CPU path by not setting processed_as_gpu
        }
      }

      if (SUCCEEDED(hr) &&
          texture_to_share_com) { // Original was shareable or copy succeeded
        winrt::com_ptr<IDXGIResource1> dxgi_resource_to_share;
        hr = texture_to_share_com->QueryInterface(
            IID_PPV_ARGS(dxgi_resource_to_share.put()));

        if (SUCCEEDED(hr)) {
          hr = dxgi_resource_to_share->CreateSharedHandle(
              nullptr, DXGI_SHARED_RESOURCE_READ, nullptr,
              &shared_handle_for_app);
          if (SUCCEEDED(hr) && shared_handle_for_app) {
            texture_for_payload_ref_com =
                texture_to_share_com; // This is the texture whose handle was
                                      // shared
            texture_for_payload_ref_com->AddRef(); // AddRef for payload
            processed_as_gpu = true;
            miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                       "WGC: GPU shared handle %p created from texture %p.",
                       shared_handle_for_app,
                       texture_for_payload_ref_com.get());
          } else {
            miniav_log(MINIAV_LOG_LEVEL_ERROR,
                       "WGC: CreateSharedHandle failed: 0x%X. Fallback to CPU.",
                       hr);
            if (shared_handle_for_app) {
              CloseHandle(shared_handle_for_app);
              shared_handle_for_app = NULL;
            }
          }
        } else {
          miniav_log(
              MINIAV_LOG_LEVEL_ERROR,
              "WGC: QI for IDXGIResource1 failed: 0x%X. Fallback to CPU.", hr);
        }
      }
    } // End GPU Path Attempt

    // --- CPU Path (or fallback) ---
    if (!processed_as_gpu) {
      if (desired_output_pref == MINIAV_OUTPUT_PREFERENCE_GPU) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "WGC: GPU path failed or not preferred, using CPU path.");
      }

      D3D11_TEXTURE2D_DESC acquired_desc;
      acquired_texture_com->GetDesc(&acquired_desc);

      D3D11_TEXTURE2D_DESC staging_desc_cpu = acquired_desc;
      staging_desc_cpu.Usage = D3D11_USAGE_STAGING;
      staging_desc_cpu.BindFlags = 0;
      staging_desc_cpu.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_desc_cpu.MiscFlags =
          0; // Staging textures cannot have MiscFlags like SHARED

      winrt::com_ptr<ID3D11Texture2D> per_frame_staging_texture_com;
      hr = wgc_ctx->d3d_device->CreateTexture2D(
          &staging_desc_cpu, nullptr, per_frame_staging_texture_com.put());
      if (FAILED(hr)) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "WGC: Failed to create per-frame CPU staging texture: 0x%X",
                   hr);
        throw winrt::hresult_error(hr, L"Failed to create CPU staging texture");
      }

      wgc_ctx->d3d_context->CopyResource(per_frame_staging_texture_com.get(),
                                         acquired_texture_com.get());

      D3D11_MAPPED_SUBRESOURCE mapped_rect_cpu;
      hr = wgc_ctx->d3d_context->Map(per_frame_staging_texture_com.get(), 0,
                                     D3D11_MAP_READ, 0, &mapped_rect_cpu);
      if (FAILED(hr)) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "WGC: Failed to map per-frame CPU staging texture: 0x%X",
                   hr);
        throw winrt::hresult_error(hr, L"Failed to map CPU staging texture");
      }

      buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;

      // Set up single plane for BGRA32 format
      buffer->data.video.num_planes = 1;
      buffer->data.video.planes[0].data_ptr = mapped_rect_cpu.pData;
      buffer->data.video.planes[0].width = buffer->data.video.info.width;
      buffer->data.video.planes[0].height = buffer->data.video.info.height;
      buffer->data.video.planes[0].stride_bytes = mapped_rect_cpu.RowPitch;
      buffer->data.video.planes[0].offset_bytes = 0;
      buffer->data.video.planes[0].subresource_index = 0;

      buffer->data_size_bytes =
          mapped_rect_cpu.RowPitch * buffer->data.video.info.height;
      texture_for_payload_ref_com = per_frame_staging_texture_com;
    } else { // GPU Path successful
      buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_D3D11_HANDLE;

      // Set up single plane for GPU texture
      buffer->data.video.num_planes = 1;
      buffer->data.video.planes[0].data_ptr = (void *)shared_handle_for_app;
      buffer->data.video.planes[0].width = buffer->data.video.info.width;
      buffer->data.video.planes[0].height = buffer->data.video.info.height;
      buffer->data.video.planes[0].stride_bytes =
          0; // GPU textures don't have stride
      buffer->data.video.planes[0].offset_bytes = 0;
      buffer->data.video.planes[0].subresource_index = 0;
      // calculate data size based on width, height, and pixel format
      buffer->data_size_bytes =
          (buffer->data.video.info.width * buffer->data.video.info.height *
           4); // BGRA32 = 4 bytes per pixel
    }

    // --- Prepare Payloads and Call App ---
    frame_payload_app = (WGCFrameReleasePayload *)miniav_calloc(
        1, sizeof(WGCFrameReleasePayload));
    internal_payload = (MiniAVNativeBufferInternalPayload *)miniav_calloc(
        1, sizeof(MiniAVNativeBufferInternalPayload));

    if (!frame_payload_app || !internal_payload) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "WGC: Failed to allocate payload structures.");
      throw winrt::hresult_error(E_OUTOFMEMORY, L"Payload allocation failed");
    }

    frame_payload_app->original_output_preference = desired_output_pref;
    if (processed_as_gpu) {
      frame_payload_app->actual_output_preference =
          MINIAV_OUTPUT_PREFERENCE_GPU;
      frame_payload_app->gpu_texture_to_release =
          texture_for_payload_ref_com.detach();
      frame_payload_app->gpu_shared_handle_to_close = shared_handle_for_app;
    } else {
      frame_payload_app->actual_output_preference =
          MINIAV_OUTPUT_PREFERENCE_CPU;
      frame_payload_app->cpu_staging_texture_to_unmap_release =
          texture_for_payload_ref_com.detach();
      frame_payload_app->d3d_context_for_unmap = wgc_ctx->d3d_context.get();
      if (frame_payload_app->d3d_context_for_unmap) {
        frame_payload_app->d3d_context_for_unmap->AddRef();
      }
      frame_payload_app->subresource_for_unmap = 0;
    }

    internal_payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
    internal_payload->context_owner = wgc_ctx->parent_ctx;
    internal_payload->native_singular_resource_ptr = frame_payload_app;
    internal_payload->num_planar_resources_to_release = 0;
    internal_payload->parent_miniav_buffer_ptr =
        buffer; // Store heap-allocated buffer
    buffer->internal_handle = internal_payload;

    // Callback is already checked and wgc_ctx is valid under critical section
    wgc_ctx->app_callback_internal(buffer,
                                   wgc_ctx->app_callback_user_data_internal);
    // App now owns buffer.internal_handle and its payload, and
    // gpu_shared_handle_for_app if provided. App must call
    // MiniAV_ReleaseBuffer.

  } catch (winrt::hresult_error const &ex) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Error in on_frame_arrived: %ls (0x%08X)",
               ex.message().c_str(), ex.code().value);
    // Cleanup partially created resources
    if (shared_handle_for_app) // From GPU path attempt
      CloseHandle(shared_handle_for_app);

    if (frame_payload_app) {
      // Release any D3D textures held by the payload before freeing the struct
      if (frame_payload_app->cpu_staging_texture_to_unmap_release) {
        frame_payload_app->cpu_staging_texture_to_unmap_release->Release();
        frame_payload_app->cpu_staging_texture_to_unmap_release = nullptr;
      }
      if (frame_payload_app->gpu_texture_to_release) { // Should be null if CPU
                                                       // path was taken
        frame_payload_app->gpu_texture_to_release->Release();
        frame_payload_app->gpu_texture_to_release = nullptr;
      }
      miniav_free(frame_payload_app);
      frame_payload_app = nullptr; // Avoid double free if another catch happens
    }

    // If texture_for_payload_ref_com still holds a reference (i.e., not
    // detached yet)
    if (texture_for_payload_ref_com) {
      texture_for_payload_ref_com = nullptr; // com_ptr releases it
    }

    if (internal_payload) {
      miniav_free(internal_payload);
      internal_payload = nullptr;
    }

    // Clean up heap-allocated buffer
    if (buffer) {
      miniav_free(buffer);
      buffer = nullptr;
    }
  } catch (...) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "WGC: Unknown error in on_frame_arrived.");
    if (shared_handle_for_app)
      CloseHandle(shared_handle_for_app);

    if (frame_payload_app) {
      if (frame_payload_app->cpu_staging_texture_to_unmap_release) {
        frame_payload_app->cpu_staging_texture_to_unmap_release->Release();
        frame_payload_app->cpu_staging_texture_to_unmap_release = nullptr;
      }
      if (frame_payload_app->gpu_texture_to_release) {
        frame_payload_app->gpu_texture_to_release->Release();
        frame_payload_app->gpu_texture_to_release = nullptr;
      }
      miniav_free(frame_payload_app);
      frame_payload_app = nullptr;
    }

    if (texture_for_payload_ref_com) {
      texture_for_payload_ref_com = nullptr;
    }
    if (internal_payload) {
      miniav_free(internal_payload);
      internal_payload = nullptr;
    }

    if (buffer) {
      miniav_free(buffer);
      buffer = nullptr;
    }
  }

  LeaveCriticalSection(&wgc_ctx->critical_section);
  if (frame)
    frame.Close(); // Release frame back to pool

  // Simple FPS limiting if target_fps is set (WGC is event-driven, this is a
  // crude way) This sleep should ideally be outside the critical section.
  if (wgc_ctx->target_fps > 0 && wgc_ctx->is_streaming) {
    DWORD sleep_ms = 1000 / wgc_ctx->target_fps;
    if (sleep_ms > 0) {
      // Check stop event again before sleeping
      if (WaitForSingleObject(wgc_ctx->stop_event_handle, 0) != WAIT_OBJECT_0) {
        Sleep(sleep_ms > 5 ? sleep_ms - 2
                           : 1); // Sleep a bit less to avoid oversleeping
      }
    }
  }
}

// --- Ops struct and Platform Init ---
const ScreenContextInternalOps g_screen_ops_win_wgc = {
    wgc_init_platform,
    wgc_destroy_platform,
    wgc_enumerate_displays,
    wgc_enumerate_windows,
    wgc_configure_display,
    wgc_configure_window,
    wgc_configure_region, // Not supported
    wgc_start_capture,
    wgc_stop_capture,
    wgc_release_buffer,
    wgc_get_default_formats,
    wgc_get_configured_video_formats};

MiniAVResultCode
miniav_screen_context_platform_init_windows_wgc(MiniAVScreenContext *ctx) {
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  // Check if WGC is supported on this system
  if (!winrt::Windows::Graphics::Capture::GraphicsCaptureSession::
          IsSupported()) {
    miniav_log(
        MINIAV_LOG_LEVEL_ERROR,
        "WGC: Windows Graphics Capture is not supported on this system.");
    return MINIAV_ERROR_NOT_SUPPORTED;
  }

  ctx->ops = &g_screen_ops_win_wgc;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "WGC: Assigned Windows Graphics Capture screen ops.");
  // The caller (e.g., MiniAV_Screen_CreateContext) will call
  // ctx->ops->init_platform()
  return MINIAV_SUCCESS;
}
