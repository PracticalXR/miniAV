#include "../include/miniav.h"
#include "../camera/camera_context.h" // For MiniAVCameraContext and ops (for camera case)
#include "../include/miniav_buffer.h" // For MiniAVNativeBufferInternalPayload
#include "../screen/screen_context.h" // Add when screen capture is
#include "miniav_logging.h"
#include "miniav_utils.h"
// implemented #include "../audio/audio_context.h"   // Add if audio needs
// explicit buffer release

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Version info
// Keep in lockstep with miniav_ffi's pubspec version (was stale at 0.1.0
// for years while the packages moved on — meaningless self-reporting).
#define MINIAV_VERSION_MAJOR 0
#define MINIAV_VERSION_MINOR 7
#define MINIAV_VERSION_PATCH 0
#define MINIAV_VERSION_STRING "0.7.0"

// --- Error Strings ---
static const char *miniav_error_string(MiniAVResultCode code) {
  switch (code) {
  case MINIAV_SUCCESS:
    return "Success";
  case MINIAV_ERROR_UNKNOWN:
    return "Unknown error";
  case MINIAV_ERROR_INVALID_ARG:
    return "Invalid argument";
  case MINIAV_ERROR_NOT_INITIALIZED:
    return "Not initialized";
  case MINIAV_ERROR_SYSTEM_CALL_FAILED:
    return "System call failed";
  case MINIAV_ERROR_NOT_SUPPORTED:
    return "Not supported";
  case MINIAV_ERROR_BUFFER_TOO_SMALL:
    return "Buffer too small";
  case MINIAV_ERROR_INVALID_HANDLE:
    return "Invalid handle";
  case MINIAV_ERROR_DEVICE_NOT_FOUND:
    return "Device not found";
  case MINIAV_ERROR_DEVICE_BUSY:
    return "Device busy";
  case MINIAV_ERROR_ALREADY_RUNNING:
    return "Already running";
  case MINIAV_ERROR_NOT_RUNNING:
    return "Not running";
  case MINIAV_ERROR_OUT_OF_MEMORY:
    return "Out of memory";
  case MINIAV_ERROR_TIMEOUT:
    return "Timeout";
  case MINIAV_ERROR_DEVICE_LOST:
    return "Device lost";
  case MINIAV_ERROR_FORMAT_NOT_SUPPORTED:
    return "Format not supported";
  case MINIAV_ERROR_INVALID_OPERATION:
    return "Invalid operation";
  case MINIAV_ERROR_NOT_IMPLEMENTED:
    return "Not implemented";
  case MINIAV_ERROR_NOT_CONFIGURED:
    return "Not configured";
  case MINIAV_ERROR_PORTAL_FAILED:
    return "Desktop portal request failed";
  case MINIAV_ERROR_STREAM_FAILED:
    return "Stream failed";
  case MINIAV_ERROR_PORTAL_CLOSED:
    return "Desktop portal session closed";
  case MINIAV_ERROR_USER_CANCELLED:
    return "Cancelled by user";
  case MINIAV_ERROR_PERMISSION_DENIED:
    return "Permission denied (request the OS permission app-side first)";
  default:
    return "Unrecognized error code";
  }
}

// --- API Implementations ---

MiniAVResultCode MiniAV_GetVersion(uint32_t *major, uint32_t *minor,
                                   uint32_t *patch) {
  if (!major || !minor || !patch)
    return MINIAV_ERROR_INVALID_ARG;
  *major = MINIAV_VERSION_MAJOR;
  *minor = MINIAV_VERSION_MINOR;
  *patch = MINIAV_VERSION_PATCH;
  return MINIAV_SUCCESS;
}

const char *MiniAV_GetVersionString(void) { return MINIAV_VERSION_STRING; }

const char *MiniAV_GetErrorString(MiniAVResultCode code) {
  return miniav_error_string(code);
}

MiniAVResultCode MiniAV_SetLogCallback(MiniAVLogCallback callback,
                                       void *user_data) {
  miniav_set_log_callback(callback, user_data);
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_SetLogLevel(MiniAVLogLevel level) {
  miniav_set_log_level(level);
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_ReleaseBuffer(void *internal_handle_payload_ptr) {
  if (!internal_handle_payload_ptr) {
    //miniav_log(MINIAV_LOG_LEVEL_ERROR, "MiniAV_ReleaseBuffer: NULL payload.");
    return MINIAV_SUCCESS;
  }

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_payload_ptr;

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "Releasing payload: %p, Type: %d", payload,
             payload->handle_type);

  // Release the native resource
  MiniAVResultCode res = MINIAV_ERROR_NOT_SUPPORTED;
  if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA) {
    MiniAVCameraContext *cam_ctx =
        (MiniAVCameraContext *)payload->context_owner;
    if (cam_ctx && cam_ctx->ops && cam_ctx->ops->release_buffer) {
      res = cam_ctx->ops->release_buffer(cam_ctx, payload);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Invalid camera context or release_buffer op for payload %p. "
                 "Freeing the payload wrapper only (native resources may "
                 "leak).",
                 payload);
      miniav_free(payload);
      return MINIAV_ERROR_INVALID_HANDLE;
    }
  } else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN) {
    MiniAVScreenContext *screen_ctx =
        (MiniAVScreenContext *)payload->context_owner;
    if (screen_ctx && screen_ctx->ops && screen_ctx->ops->release_buffer) {
      res = screen_ctx->ops->release_buffer(screen_ctx, payload);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "Invalid screen context or release_buffer op for payload %p. "
                 "Freeing the payload wrapper only (native resources may "
                 "leak).",
                 payload);
      miniav_free(payload);
      return MINIAV_ERROR_INVALID_HANDLE;
    }
  } else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_AUDIO) {
    // Free the heap-copied PCM data (native_singular_resource_ptr) and the
    // heap-allocated MiniAVBuffer (parent_miniav_buffer_ptr) that were
    // created in the capture thread before dispatching to the Dart event queue.
    if (payload->native_singular_resource_ptr) {
      miniav_free(payload->native_singular_resource_ptr);
      payload->native_singular_resource_ptr = NULL;
    }
    MiniAVBuffer *parent_buf =
        (MiniAVBuffer *)payload->parent_miniav_buffer_ptr;
    miniav_free(payload);
    if (parent_buf) {
      miniav_free(parent_buf);
    }
    res = MINIAV_SUCCESS;
  }
   else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Unsupported payload handle_type: %d for payload %p. Freeing "
               "the payload wrapper only (native resources may leak).",
               payload->handle_type, payload);
    miniav_free(payload);
    return MINIAV_ERROR_INVALID_HANDLE;
  }

  // NOTE: the platform release op owns and frees `payload` — do not touch it
  // (even for logging its address) past this point.
  if (res == MINIAV_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "Platform release_buffer successful.");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Platform release_buffer failed (%d).", (int)res);
  }
  return res;
}

MiniAVResultCode MiniAV_Free(void *ptr) {
  if (ptr) {
    free(ptr);
  }
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_FreeDeviceList(MiniAVDeviceInfo *devices,
                                       uint32_t count) {
  MINIAV_UNUSED(count); // If count is not needed
  if (devices) {
    miniav_free(devices);
  }
  return MINIAV_SUCCESS;
}

// Helper to free the list allocated by GetSupportedFormats
MiniAVResultCode MiniAV_FreeFormatList(void *formats, uint32_t count) {
  MINIAV_UNUSED(count); // count might be useful if allocation was complex
  if (formats) {
    miniav_free(formats);
  }
  return MINIAV_SUCCESS;
}

// ---- Global lifecycle ----------------------------------------------------------
MiniAVResultCode MiniAV_Dispose(void) {
  // Acquire exclusive write lock: blocks until all in-flight callback
  // invocations finish, then disables future dispatches.
  miniav_dispatch_set_enabled(0);
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_EnableCallbacks(void) {
  miniav_dispatch_set_enabled(1);
  return MINIAV_SUCCESS;
}