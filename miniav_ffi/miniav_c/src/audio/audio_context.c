// Core type definitions first
#include "../../include/miniav_buffer.h" // Defines MiniAVBuffer, MiniAVBufferType, MiniAVPixelFormat, MiniAVSampleFormat
#include "../../include/miniav_types.h" // Defines MiniAVResultCode, handles, MiniAVDeviceInfo, MiniAVAudioInfo, MiniAVVideoInfo, etc.

// API header using the types
#include "../../include/miniav_capture.h" // Defines MiniAVBufferCallback and the capture functions

// Internal headers for this module
#include "../common/miniav_context_base.h"
#include "../common/miniav_device_watcher.h"
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h"
#include "../common/miniav_time.h"
#include "audio_context.h" // Specific internal header for this file (if any)

// Standard library headers
#include <stdlib.h>
#include <string.h>

// iOS: capture requires an active record-capable AVAudioSession category
// before the device starts (see src/audio/ios/miniav_avaudiosession_ios.m).
// No-ops everywhere else.
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
extern int miniav_ios_audio_session_begin(void);
extern void miniav_ios_audio_session_end(void);
#define MINIAV_AUDIO_SESSION_BEGIN() miniav_ios_audio_session_begin()
#define MINIAV_AUDIO_SESSION_END() miniav_ios_audio_session_end()
#else
#define MINIAV_AUDIO_SESSION_BEGIN() 0
#define MINIAV_AUDIO_SESSION_END() ((void)0)
#endif

// --- Helper Functions ---

// Convert MiniAVSampleFormat to ma_format
static ma_format miniav_format_to_ma_format(MiniAVAudioFormat format) {
  switch (format) {
  case MINIAV_AUDIO_FORMAT_U8:
    return ma_format_u8;
  case MINIAV_AUDIO_FORMAT_S16:
    return ma_format_s16;
  case MINIAV_AUDIO_FORMAT_S32:
    return ma_format_s32;
  case MINIAV_AUDIO_FORMAT_F32:
    return ma_format_f32;
  default:
    return ma_format_unknown;
  }
}

// Convert ma_format to MiniAVSampleFormat
static MiniAVAudioFormat ma_format_to_miniav_format(ma_format format) {
  switch (format) {
  case ma_format_u8:
    return MINIAV_AUDIO_FORMAT_U8;
  case ma_format_s16:
    return MINIAV_AUDIO_FORMAT_S16;
  case ma_format_s32:
    return MINIAV_AUDIO_FORMAT_S32;
  case ma_format_f32:
    return MINIAV_AUDIO_FORMAT_F32;
  default:
    return ma_format_unknown;
  }
}

// Internal audio context struct
struct MiniAVAudioContext {
  MiniAVContextBase *base;
  int is_configured;
  int is_running;
  // Whether ma_device holds an initialized device that needs
  // ma_device_uninit. Distinct from is_running: a device-lost notification
  // clears is_running but the device still needs teardown — keying
  // Stop/Destroy off is_running alone leaked the device in that case.
  int device_inited;
  // One-shot guard for the lost notification (miniaudio has a single
  // notification thread, so a plain int is race-free here; reset in
  // StartCapture).
  int lost_cb_fired;
  ma_context ma_ctx;
  ma_device ma_device;
  ma_device_id ma_capture_device_id; // Store the actual miniaudio device ID
  MiniAVAudioInfo format_info;       // Store the configured format
  MiniAVBufferCallback callback;
  void *callback_user_data;
  int has_ma_context; // Flag to track ma_context initialization

  // Set via MiniAV_Audio_SetContextLostCallback. May be NULL.
  MiniAVContextLostCallback lost_cb;
  void *lost_cb_user_data;

  // --- Pull (buffered) capture: web/WASM polling path ---
  // When use_buffered_capture is set, the data callback writes captured PCM
  // straight into pcm_rb (f32 SPSC ring) instead of heap-allocating a
  // MiniAVBuffer and invoking the Dart callback. A consumer (e.g. the web
  // input impl) then drains the ring via MiniAV_Audio_ReadFrames. Native
  // callers never set the flag, so the classic push path is byte-identical.
  ma_pcm_rb pcm_rb;         // f32 ring; audio thread writes, reader polls
  int rb_inited;           // pcm_rb allocated (needs ma_pcm_rb_uninit)
  int use_buffered_capture;// 1 = data callback fills the ring, not the Dart cb
};

// Helper: Convert miniaudio device info to MiniAVDeviceInfo
// Uses the actual miniaudio device ID, converting it to a hex string for
// uniqueness.
static void fill_device_info(const ma_device_info *src, MiniAVDeviceInfo *dst) {
  memset(dst, 0, sizeof(MiniAVDeviceInfo));
  // Use the device name as the primary identifier string for MiniAV
  miniav_strlcpy(dst->device_id, src->name, sizeof(dst->device_id));
  miniav_strlcpy(dst->name, src->name,
                 sizeof(dst->name)); // Also copy to name field
  dst->is_default = src->isDefault;
}

// --- Public API Implementation ---

MiniAVResultCode MiniAV_Audio_EnumerateDevices(MiniAVDeviceInfo **devices,
                                               uint32_t *count) {
  if (!devices || !count) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Invalid arguments for enumeration.");
    return MINIAV_ERROR_INVALID_ARG;
  }
  *devices = NULL;
  *count = 0;

  ma_context ma_ctx;
  ma_result res = ma_context_init(NULL, 0, NULL, &ma_ctx);
  if (res != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to initialize miniaudio context: %s",
               ma_result_description(res));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ma_device_info *playbackInfos;
  ma_uint32 playbackCount;
  ma_device_info *captureInfos;
  ma_uint32 captureCount;
  res = ma_context_get_devices(&ma_ctx, &playbackInfos, &playbackCount,
                               &captureInfos, &captureCount);
  if (res != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to get miniaudio devices: %s",
               ma_result_description(res));
    ma_context_uninit(&ma_ctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (captureCount == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "No audio capture devices found.");
    ma_context_uninit(&ma_ctx);
    return MINIAV_SUCCESS;
  }

  *devices =
      (MiniAVDeviceInfo *)miniav_calloc(captureCount, sizeof(MiniAVDeviceInfo));
  if (!*devices) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Out of memory allocating device list.");
    ma_context_uninit(&ma_ctx); // Use the temporary context
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  for (ma_uint32 i = 0; i < captureCount; ++i) {
    fill_device_info(&captureInfos[i],
                     &(*devices)[i]); // Use updated fill_device_info
  }
  *count = captureCount;

  ma_context_uninit(&ma_ctx); // Use the temporary context
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "Enumerated %u audio capture devices.",
             *count);
  return MINIAV_SUCCESS;
}

// Finds the capture device matching device_id_str (this module uses the
// device NAME as its ID — see fill_device_info); NULL/empty selects the
// system default (falling back to the first device). On success copies the
// device's basic info (including its ma_device_id) into out_info.
static int audio_find_capture_device(ma_context *ma_ctx,
                                     const char *device_id_str,
                                     ma_device_info *out_info) {
  ma_device_info *playback_infos, *capture_infos;
  ma_uint32 playback_count, capture_count;
  if (ma_context_get_devices(ma_ctx, &playback_infos, &playback_count,
                             &capture_infos, &capture_count) != MA_SUCCESS ||
      capture_count == 0) {
    return 0;
  }
  const ma_device_info *chosen = NULL;
  if (device_id_str == NULL || device_id_str[0] == '\0') {
    for (ma_uint32 i = 0; i < capture_count; ++i) {
      if (capture_infos[i].isDefault) {
        chosen = &capture_infos[i];
        break;
      }
    }
    if (!chosen)
      chosen = &capture_infos[0];
  } else {
    for (ma_uint32 i = 0; i < capture_count; ++i) {
      if (strcmp(capture_infos[i].name, device_id_str) == 0) {
        chosen = &capture_infos[i];
        break;
      }
    }
  }
  if (!chosen)
    return 0;
  *out_info = *chosen;
  return 1;
}

MiniAVResultCode MiniAV_Audio_GetSupportedFormats(const char *device_id_str,
                                                  MiniAVAudioInfo **formats,
                                                  uint32_t *count) {
  if (!device_id_str || !formats || !count)
    return MINIAV_ERROR_INVALID_ARG;
  *formats = NULL;
  *count = 0;

  // Query the ACTUAL device (this used to return a hardcoded 4-combo table
  // regardless of device_id_str).
  ma_context ma_ctx;
  if (ma_context_init(NULL, 0, NULL, &ma_ctx) == MA_SUCCESS) {
    ma_device_info basic;
    if (audio_find_capture_device(&ma_ctx, device_id_str, &basic)) {
      ma_device_info full;
      if (ma_context_get_device_info(&ma_ctx, ma_device_type_capture,
                                     &basic.id, &full) == MA_SUCCESS &&
          full.nativeDataFormatCount > 0) {
        MiniAVAudioInfo *out = (MiniAVAudioInfo *)miniav_calloc(
            full.nativeDataFormatCount, sizeof(MiniAVAudioInfo));
        if (!out) {
          ma_context_uninit(&ma_ctx);
          return MINIAV_ERROR_OUT_OF_MEMORY;
        }
        uint32_t n = 0;
        for (ma_uint32 i = 0; i < full.nativeDataFormatCount; ++i) {
          // Zero/unknown fields mean "any" in miniaudio — substitute the
          // common defaults so callers get a concrete, usable entry. The
          // substitution checks the CONVERTED value: miniaudio formats with
          // no MiniAV equivalent (e.g. s24) also need the fallback, not just
          // ma_format_unknown.
          MiniAVAudioFormat mf =
              ma_format_to_miniav_format(full.nativeDataFormats[i].format);
          out[n].format =
              (mf != MINIAV_AUDIO_FORMAT_UNKNOWN) ? mf : MINIAV_AUDIO_FORMAT_F32;
          out[n].channels = full.nativeDataFormats[i].channels
                                ? full.nativeDataFormats[i].channels
                                : 2;
          out[n].sample_rate = full.nativeDataFormats[i].sampleRate
                                   ? full.nativeDataFormats[i].sampleRate
                                   : 48000;
          n++;
        }
        ma_context_uninit(&ma_ctx);
        *formats = out;
        *count = n;
        return MINIAV_SUCCESS;
      }
    }
    ma_context_uninit(&ma_ctx);
  }

  // Fallback (device not found / backend reports no native formats): the
  // common combos, clearly logged as such.
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Audio GetSupportedFormats: could not query device '%s' — "
             "returning common fallback formats.",
             device_id_str);
  *count = 4;
  *formats = (MiniAVAudioInfo *)miniav_calloc(*count, sizeof(MiniAVAudioInfo));
  if (!*formats) {
    *count = 0;
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  (*formats)[0] = (MiniAVAudioInfo){
      .format = MINIAV_AUDIO_FORMAT_F32, .sample_rate = 48000, .channels = 2};
  (*formats)[1] = (MiniAVAudioInfo){
      .format = MINIAV_AUDIO_FORMAT_S16, .sample_rate = 48000, .channels = 2};
  (*formats)[2] = (MiniAVAudioInfo){
      .format = MINIAV_AUDIO_FORMAT_F32, .sample_rate = 44100, .channels = 2};
  (*formats)[3] = (MiniAVAudioInfo){
      .format = MINIAV_AUDIO_FORMAT_S16, .sample_rate = 44100, .channels = 2};
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Audio_CreateContext(MiniAVAudioContextHandle *context) {
  if (!context)
    return MINIAV_ERROR_INVALID_ARG;

  MiniAVAudioContext *ctx =
      (MiniAVAudioContext *)miniav_calloc(1, sizeof(MiniAVAudioContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to allocate audio context.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ctx->base =
      miniav_context_base_create(NULL); // User data can be set later if needed
  if (!ctx->base) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to allocate base context.");
    miniav_free(ctx);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ma_result res = ma_context_init(NULL, 0, NULL, &ctx->ma_ctx);
  if (res != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to initialize miniaudio context: %s",
               ma_result_description(res));
    miniav_context_base_destroy(ctx->base);
    miniav_free(ctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  ctx->has_ma_context = 1;

  *context = (MiniAVAudioContextHandle)ctx;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "Audio context created.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Audio_DestroyContext(MiniAVAudioContextHandle context) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG; // Or SUCCESS?

  if (ctx->device_inited) {
    // Covers both a normal running device AND a device-lost one (is_running
    // already 0 but the ma_device still initialized). Previously a skipped/
    // failed Stop here silently leaked the device before freeing ctx.
    MiniAVResultCode stop_res = MiniAV_Audio_StopCapture(context);
    if (stop_res != MINIAV_SUCCESS && ctx->device_inited) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "Audio Destroy: StopCapture failed (%d) — forcing "
                 "ma_device_uninit.",
                 (int)stop_res);
      ma_device_uninit(&ctx->ma_device);
      ctx->device_inited = 0;
    }
  }

  if (ctx->has_ma_context) {
    ma_context_uninit(&ctx->ma_ctx);
    ctx->has_ma_context = 0;
  }

  // Free the buffered-capture ring last. The device was stopped+joined by the
  // StopCapture above, so the audio thread is gone and cannot touch it. Kept
  // out of StopCapture so a stop→start restart can reuse the ring.
  if (ctx->rb_inited) {
    ma_pcm_rb_uninit(&ctx->pcm_rb);
    ctx->rb_inited = 0;
  }

  if (ctx->base) {
    miniav_context_base_destroy(ctx->base);
  }
  miniav_free(ctx);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "Audio context destroyed.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Audio_Configure(
    MiniAVAudioContextHandle context,
    const char *device_name_str, // Parameter renamed for clarity
    const MiniAVAudioInfo *format) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx || !format || !ctx->has_ma_context)
    return MINIAV_ERROR_INVALID_ARG;
  if (ctx->is_running)
    return MINIAV_ERROR_ALREADY_RUNNING;

  ma_device_id *p_capture_device_id_to_use = NULL; // Use pointer for config
  ma_device_id default_device_id; // Temporary storage if default is found

  // Enumerate devices within the context to find the matching ID
  ma_device_info *playbackInfos, *captureInfos;
  ma_uint32 playbackCount, captureCount;
  ma_result res =
      ma_context_get_devices(&ctx->ma_ctx, &playbackInfos, &playbackCount,
                             &captureInfos, &captureCount);
  if (res != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to get devices during configuration: %s",
               ma_result_description(res));

    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (captureCount == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "No capture devices found during configuration.");
    return MINIAV_ERROR_DEVICE_NOT_FOUND; // No devices available at all
  }

  int found_device = 0;
  if (device_name_str == NULL || strlen(device_name_str) == 0) {
    // --- Find Default Device ---
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to use default audio capture device.");
    for (ma_uint32 i = 0; i < captureCount; ++i) {
      if (captureInfos[i].isDefault) {
        default_device_id = captureInfos[i].id; // Store the ID
        p_capture_device_id_to_use = &default_device_id;
        found_device = 1;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Found default audio capture device: %s",
                   captureInfos[i].name);
        break;
      }
    }
    // Fallback if no default marked: use the first capture device
    if (!found_device) {
      default_device_id = captureInfos[0].id;
      p_capture_device_id_to_use = &default_device_id;
      found_device = 1; // Treat the first one as found
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "No default capture device marked, using first device: %s",
                 captureInfos[0].name);
    }
  } else {
    // --- Find Device By Name ---
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Attempting to find audio capture device by name: %s",
               device_name_str);
    for (ma_uint32 i = 0; i < captureCount; ++i) {
      // Compare the provided name with the enumerated device name
      if (strcmp(device_name_str, captureInfos[i].name) == 0) {
        default_device_id = captureInfos[i].id; // Store the ID
        p_capture_device_id_to_use = &default_device_id;
        found_device = 1;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Found specified audio capture device: %s",
                   captureInfos[i].name);
        break;
      }
    }
  }

  if (!found_device) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Failed to find specified audio device: %s",
               device_name_str ? device_name_str : "(Default)");
    return MINIAV_ERROR_DEVICE_NOT_FOUND;
  }

  ctx->ma_capture_device_id = *p_capture_device_id_to_use; // Copy the ID value

  ctx->format_info = *format; // Copy format info
  ctx->is_configured = 1;

  // A re-Configure changes format/channels, so any previously-enabled buffered
  // ring is now sized for the OLD layout. Invalidate it: the caller must
  // re-invoke EnableBufferedCapture (which rebuilds the ring against the new
  // channel count and re-forces f32), keeping the ring / device callback /
  // ReadFrames all in agreement on f32 + channel count. The web driver already
  // calls EnableBufferedCapture after every configure(), so this is a no-op
  // there and a safety net for any other caller.
  if (ctx->rb_inited) {
    ma_pcm_rb_uninit(&ctx->pcm_rb);
    ctx->rb_inited = 0;
  }
  ctx->use_buffered_capture = 0;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Audio context configured: Format=%d, Rate=%u, Channels=%u",
             format->format, format->sample_rate, format->channels);
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Audio_GetDefaultFormat(const char *device_id_str,
                                               MiniAVAudioInfo *format_out) {
  if (!format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(format_out, 0, sizeof(MiniAVAudioInfo));

  // Query the target device's actual native format (this used to return a
  // hardcoded F32/48k/2ch while running a dead enumeration loop purely to
  // populate a log line).
  ma_context ma_ctx_temp;
  if (ma_context_init(NULL, 0, NULL, &ma_ctx_temp) == MA_SUCCESS) {
    ma_device_info basic;
    if (audio_find_capture_device(&ma_ctx_temp, device_id_str, &basic)) {
      ma_device_info full;
      if (ma_context_get_device_info(&ma_ctx_temp, ma_device_type_capture,
                                     &basic.id, &full) == MA_SUCCESS &&
          full.nativeDataFormatCount > 0) {
        // Check the CONVERTED value: formats with no MiniAV equivalent
        // (e.g. s24) need the fallback too, not just ma_format_unknown.
        MiniAVAudioFormat mf =
            ma_format_to_miniav_format(full.nativeDataFormats[0].format);
        format_out->format =
            (mf != MINIAV_AUDIO_FORMAT_UNKNOWN) ? mf : MINIAV_AUDIO_FORMAT_F32;
        format_out->channels = full.nativeDataFormats[0].channels
                                   ? full.nativeDataFormats[0].channels
                                   : 2;
        format_out->sample_rate = full.nativeDataFormats[0].sampleRate
                                      ? full.nativeDataFormats[0].sampleRate
                                      : 48000;
        ma_context_uninit(&ma_ctx_temp);
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "Audio GetDefaultFormat: '%s' native format=%d %uHz %uch.",
                   basic.name, format_out->format, format_out->sample_rate,
                   format_out->channels);
        return MINIAV_SUCCESS;
      }
    }
    ma_context_uninit(&ma_ctx_temp);
  }

  // Fallback when the device/query is unavailable.
  format_out->format = MINIAV_AUDIO_FORMAT_F32;
  format_out->sample_rate = 48000;
  format_out->channels = 2;
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "Audio GetDefaultFormat: could not query device '%s' — "
             "returning fallback F32/48kHz/2ch.",
             device_id_str ? device_id_str : "(Default)");
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_Audio_GetConfiguredFormat(MiniAVAudioContextHandle context,
                                 MiniAVAudioInfo *format_out) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx || !format_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Audio context is not configured. Cannot get format.");
    memset(format_out, 0, sizeof(MiniAVAudioInfo));
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  *format_out = ctx->format_info;
  miniav_log(
      MINIAV_LOG_LEVEL_DEBUG,
      "Retrieved configured audio format: Format=%d, Rate=%u, Channels=%u",
      format_out->format, format_out->sample_rate, format_out->channels);
  return MINIAV_SUCCESS;
}

// Miniaudio data callback (called on high-priority thread)
static void ma_data_callback(ma_device *pDevice, void *pOutput,
                             const void *pInput, ma_uint32 frameCount) {
  MINIAV_UNUSED(pOutput); // We are only capturing

  MiniAVAudioContext *ctx = (MiniAVAudioContext *)pDevice->pUserData;
  if (!ctx || !pInput || frameCount == 0) {
    return; // Nothing to do
  }

  // Pull (buffered) path: write captured PCM straight into the ring; no
  // per-buffer heap alloc, no Dart callback. Runs on the audio thread (a
  // native worker, or the ScriptProcessor onaudioprocess on web). The ring is
  // f32 and the device is configured f32 in EnableBufferedCapture, so bpf here
  // matches. Must precede the !ctx->callback check below because buffered mode
  // intentionally has a NULL callback.
  if (ctx->use_buffered_capture && ctx->rb_inited) {
    const ma_uint32 channels = pDevice->capture.channels;
    const ma_uint8 *src = (const ma_uint8 *)pInput;
    ma_uint32 remaining = frameCount;
    const ma_uint32 bpf =
        ma_get_bytes_per_frame(pDevice->capture.format, channels);
    // Defense-in-depth: the ring is f32 with a fixed channel count. If the
    // device's frame stride ever disagrees with the ring's (e.g. a desync from
    // a re-Configure that wasn't followed by EnableBufferedCapture), dropping
    // the block is far better than over-copying past the acquired region.
    if (bpf !=
        ma_get_bytes_per_frame(ma_format_f32,
                               ma_pcm_rb_get_channels(&ctx->pcm_rb))) {
      return;
    }
    while (remaining > 0) {
      ma_uint32 n = remaining;
      void *dst = NULL;
      if (ma_pcm_rb_acquire_write(&ctx->pcm_rb, &n, &dst) != MA_SUCCESS ||
          n == 0) {
        break; // ring full: overrun, drop the rest of this block
      }
      memcpy(dst, src, (size_t)n * bpf);
      ma_pcm_rb_commit_write(&ctx->pcm_rb, n);
      src += (size_t)n * bpf;
      remaining -= n;
    }
    return;
  }

  // Push path (Dart NativeCallable): requires a registered callback.
  if (!ctx->callback) {
    return; // Nothing to do
  }

  // IMPORTANT: ctx->callback is a Dart NativeCallable.listener — it posts to
  // the Dart event queue and returns immediately.  By the time the Dart isolate
  // processes the event, miniaudio will have reused pInput for new audio data.
  // Heap-allocate both the MiniAVBuffer and a copy of the PCM data so they
  // remain valid until Dart calls MiniAV_ReleaseBuffer.
  //
  // Only allocate + dispatch if callbacks are currently enabled, otherwise we
  // would leak the heap allocations (MiniAV_Dispose / Flutter hot restart
  // disables callbacks).  Hold the dispatch guard across alloc + post so the
  // Dart NativeCallable can't be torn down in between.
  if (!miniav_dispatch_guard_acquire_if_enabled()) {
    return;
  }

  const size_t audio_bytes =
      (size_t)frameCount *
      ma_get_bytes_per_frame(pDevice->capture.format, pDevice->capture.channels);

  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  MiniAVBuffer *heap_buf =
      (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  void *audio_copy =
      audio_bytes > 0 ? miniav_calloc(audio_bytes, 1) : NULL;

  if (!payload || !heap_buf || (audio_bytes > 0 && !audio_copy)) {
    miniav_free(payload);
    miniav_free(heap_buf);
    miniav_free(audio_copy);
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Audio: OOM allocating capture buffer — dropping frame.");
    miniav_dispatch_guard_release();
    return;
  }

  if (audio_bytes > 0) {
    memcpy(audio_copy, pInput, audio_bytes);
  }

  heap_buf->type = MINIAV_BUFFER_TYPE_AUDIO;
  heap_buf->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
  heap_buf->timestamp_us = miniav_get_time_us();
  heap_buf->user_data = ctx->callback_user_data;
  heap_buf->data.audio.info.format =
      ma_format_to_miniav_format(pDevice->capture.format);
  heap_buf->data.audio.info.channels = pDevice->capture.channels;
  heap_buf->data.audio.info.sample_rate = pDevice->sampleRate;
  heap_buf->data.audio.frame_count = frameCount;
  heap_buf->data.audio.info.num_frames = frameCount;
  heap_buf->data.audio.data = audio_copy;
  heap_buf->data_size_bytes = audio_bytes;

  // MiniAV_ReleaseBuffer will free audio_copy + heap_buf via the payload.
  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
  payload->native_singular_resource_ptr = audio_copy;
  payload->parent_miniav_buffer_ptr = heap_buf;
  heap_buf->internal_handle = payload;

  ctx->callback(heap_buf, ctx->callback_user_data);
  miniav_dispatch_guard_release();
}

// Miniaudio notification callback. Used to detect device loss (mic unplugged,
// disabled, etc.) so we can notify the application instead of silently going
// quiet.
static void
miniav_audio_ma_notification_callback(const ma_device_notification *pNotification) {
  if (!pNotification || !pNotification->pDevice) return;
  MiniAVAudioContext *ctx =
      (MiniAVAudioContext *)pNotification->pDevice->pUserData;
  if (!ctx) return;
  switch (pNotification->type) {
  case ma_device_notification_type_stopped:
    // miniaudio fires "stopped" when the device is removed or the audio
    // stack invalidates the endpoint. If we haven't been asked to stop,
    // treat this as device-lost. The ma_device stays initialized here — a
    // subsequent MiniAV_Audio_StopCapture/DestroyContext performs the real
    // teardown (keyed on device_inited, not is_running).
    //
    // Runs on miniaudio's internal notification thread — per the
    // MiniAVContextLostCallback contract the app must NOT synchronously call
    // StopCapture from inside the callback (ma_device_uninit would join the
    // thread delivering this notification).
    if (ctx->is_running && !ctx->lost_cb_fired) {
      ctx->lost_cb_fired = 1;
      ctx->is_running = 0;
      if (ctx->lost_cb) {
        ctx->lost_cb((int)MINIAV_ERROR_DEVICE_LOST, ctx->lost_cb_user_data);
      }
    }
    break;
  default:
    break;
  }
}

MiniAVResultCode MiniAV_Audio_StartCapture(MiniAVAudioContextHandle context,
                                           MiniAVBufferCallback callback,
                                           void *user_data) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  // Buffered (pull) capture has no Dart callback — data goes to the ring and
  // the consumer polls MiniAV_Audio_ReadFrames. Only require a callback for
  // the classic push path.
  if (!ctx->use_buffered_capture && !callback)
    return MINIAV_ERROR_INVALID_ARG;
  if (!ctx->is_configured) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Audio context not configured before start.");
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (ctx->is_running)
    return MINIAV_ERROR_ALREADY_RUNNING;

  // Re-enable callback dispatch in case MiniAV_Dispose() was called previously.
  miniav_dispatch_set_enabled(1);

  ctx->callback = callback;
  ctx->callback_user_data = user_data;

  ma_device_config deviceConfig = ma_device_config_init(ma_device_type_capture);
  deviceConfig.capture.pDeviceID = &ctx->ma_capture_device_id;
  deviceConfig.capture.format =
      miniav_format_to_ma_format(ctx->format_info.format);
  deviceConfig.capture.channels = ctx->format_info.channels;
  deviceConfig.sampleRate = ctx->format_info.sample_rate;
  deviceConfig.dataCallback = ma_data_callback;
  deviceConfig.notificationCallback = miniav_audio_ma_notification_callback;
  deviceConfig.pUserData = ctx;
  deviceConfig.playback.format = ma_format_unknown;
  deviceConfig.playback.channels = 0;
  // Honor the caller's requested buffer size (frames per callback). Without
  // this the backend picks its own default — notably miniaudio's Web Audio
  // (ScriptProcessorNode) backend defaults to ~33ms which rounds up to 2048
  // frames (~42.7ms), so callbacks arrive at half the requested rate. Setting
  // periodSizeInFrames makes the device deliver num_frames-sized blocks
  // (miniaudio still clamps to [256, 16384] and a power of 2 on web).
  if (ctx->format_info.num_frames > 0) {
    deviceConfig.periodSizeInFrames = ctx->format_info.num_frames;
  }

  // iOS: activate the record-capable audio session BEFORE device init;
  // failure is logged but non-fatal (miniaudio may still cope, and desktop
  // is a no-op).
  if (MINIAV_AUDIO_SESSION_BEGIN() != 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "Audio: platform audio-session activation failed — capture "
               "may record silence.");
  }

  // Initialize the device
  ma_result res = ma_device_init(&ctx->ma_ctx, &deviceConfig, &ctx->ma_device);
  if (res != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to initialize audio device: %s",
               ma_result_description(res));
    // Balance the session activation — capture never started.
    MINIAV_AUDIO_SESSION_END();
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Start the device
  res = ma_device_start(&ctx->ma_device);
  if (res != MA_SUCCESS) {
    ma_device_uninit(&ctx->ma_device); // Clean up initialized device
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "Failed to start audio device: %s",
               ma_result_description(res));
    MINIAV_AUDIO_SESSION_END();
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ctx->device_inited = 1;
  ctx->lost_cb_fired = 0; // fresh loss-notification guard per run
  ctx->is_running = 1;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "Audio capture started on device %s.",
             ctx->ma_device.capture.name); // Log the actual device name used
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_Audio_StopCapture(MiniAVAudioContextHandle context) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  // Keyed on device_inited, NOT is_running: after a device-lost notification
  // is_running is already 0 but the ma_device still needs teardown — the old
  // is_running gate silently skipped it (leaked device + worker thread).
  if (!ctx->device_inited)
    return MINIAV_ERROR_NOT_RUNNING;

  // Clear is_running BEFORE uninit: ma_device_uninit fires the "stopped"
  // notification on miniaudio's worker thread as part of teardown, and the
  // device-lost handler treats stopped-while-running as device loss — with
  // the old order every NORMAL stop fired a spurious MINIAV_ERROR_DEVICE_LOST
  // callback.
  ctx->is_running = 0;

  // ma_device_uninit stops the device and synchronously joins miniaudio's
  // internal worker thread before returning — the state clears below (and
  // DestroyContext's miniav_free of ctx) DEPEND on that documented contract.
  ma_device_uninit(&ctx->ma_device);             // Stops and uninitializes
  memset(&ctx->ma_device, 0, sizeof(ma_device)); // Clear device struct
  ctx->device_inited = 0;

  // Drain the buffered-capture ring so a stop→start restart does NOT replay
  // stale PCM captured before this stop. ma_device_uninit above already joined
  // the audio (writer) thread, so this single-consumer drain is race-free. The
  // ring stays allocated (only DestroyContext frees it) so restart reuses it.
  if (ctx->rb_inited) {
    for (;;) {
      ma_uint32 n = 0xFFFFFFFF;
      void *p = NULL;
      if (ma_pcm_rb_acquire_read(&ctx->pcm_rb, &n, &p) != MA_SUCCESS || n == 0)
        break;
      ma_pcm_rb_commit_read(&ctx->pcm_rb, n);
    }
  }

  // iOS: release the audio session (no-op elsewhere).
  MINIAV_AUDIO_SESSION_END();

  ctx->callback = NULL; // Clear callback info
  ctx->callback_user_data = NULL;

  miniav_log(MINIAV_LOG_LEVEL_INFO, "Audio capture stopped.");
  return MINIAV_SUCCESS;
}

// --- Flat, web-friendly capture shims (pull path) -------------------------
//
// These keep the WASM/js_interop side 100% scalar (no struct or out-param
// marshaling across the WASM boundary), mirroring the audio-output module.
// They are thin wrappers over the struct-based API used natively.

// Create a context and return the handle directly (NULL on failure), instead
// of the out-param form. Convenient for `Module._MiniAV_Audio_CreateContextRet()`.
MiniAVAudioContextHandle MiniAV_Audio_CreateContextRet(void) {
  MiniAVAudioContextHandle handle = NULL;
  if (MiniAV_Audio_CreateContext(&handle) != MINIAV_SUCCESS) {
    return NULL;
  }
  return handle;
}

// Configure with scalar args and the default capture device (device_id = NULL).
// num_frames = requested buffer size (frames per callback); 0 = backend default.
MiniAVResultCode MiniAV_Audio_ConfigureFlat(MiniAVAudioContextHandle context,
                                            int format, uint32_t sample_rate,
                                            uint32_t channels,
                                            uint32_t num_frames) {
  MiniAVAudioInfo info;
  memset(&info, 0, sizeof(info));
  info.format = (MiniAVAudioFormat)format;
  info.sample_rate = sample_rate;
  info.channels = (uint8_t)channels;
  info.num_frames = num_frames;
  return MiniAV_Audio_Configure(context, NULL, &info);
}

// Switch this context into buffered (pull) mode. Call AFTER Configure and
// BEFORE StartCapture. ring_frames = ring depth; 0 => ~200 ms at the
// configured sample rate. The ring is f32 and the capture device is forced to
// f32 so a poller can read straight into a Float32List.
MiniAVResultCode
MiniAV_Audio_EnableBufferedCapture(MiniAVAudioContextHandle context,
                                   uint32_t ring_frames) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (!ctx->is_configured)
    return MINIAV_ERROR_NOT_INITIALIZED;
  if (ctx->is_running)
    return MINIAV_ERROR_ALREADY_RUNNING;

  if (ctx->rb_inited) {
    ma_pcm_rb_uninit(&ctx->pcm_rb);
    ctx->rb_inited = 0;
  }

  ma_uint32 depth = ring_frames ? ring_frames : (ctx->format_info.sample_rate / 5);
  if (depth < 256)
    depth = 256;

  ma_result r = ma_pcm_rb_init(ma_format_f32, ctx->format_info.channels, depth,
                               NULL, NULL, &ctx->pcm_rb);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Audio EnableBufferedCapture: ma_pcm_rb_init failed: %s",
               ma_result_description(r));
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  // ma_pcm_rb_init leaves sampleRate at 0; keep parity with the source rate.
  ctx->pcm_rb.sampleRate = ctx->format_info.sample_rate;
  ctx->rb_inited = 1;
  ctx->use_buffered_capture = 1;
  // Device must deliver f32 to match the ring (free on web; a conversion
  // elsewhere). Record it so StartCapture configures the device as f32.
  ctx->format_info.format = MINIAV_AUDIO_FORMAT_F32;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "Audio buffered capture enabled: F32 %uHz %uch, ring=%u frames.",
             ctx->format_info.sample_rate, ctx->format_info.channels, depth);
  return MINIAV_SUCCESS;
}

// Non-blocking drain of the capture ring into out_interleaved (which must hold
// >= max_frames * channels floats). Returns frames read (>= 0), or a negative
// MiniAVResultCode on error.
int MiniAV_Audio_ReadFrames(MiniAVAudioContextHandle context,
                            float *out_interleaved, uint32_t max_frames) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx || !out_interleaved)
    return (int)MINIAV_ERROR_INVALID_ARG;
  if (!ctx->rb_inited)
    return (int)MINIAV_ERROR_NOT_CONFIGURED;

  const ma_uint32 channels = ctx->format_info.channels;
  const ma_uint32 bpf = channels * (ma_uint32)sizeof(float); // ring is f32
  ma_uint8 *dst = (ma_uint8 *)out_interleaved;
  ma_uint32 remaining = max_frames;
  ma_uint32 total = 0;

  while (remaining > 0) {
    ma_uint32 n = remaining;
    void *src = NULL;
    if (ma_pcm_rb_acquire_read(&ctx->pcm_rb, &n, &src) != MA_SUCCESS || n == 0)
      break;
    memcpy(dst, src, (size_t)n * bpf);
    ma_pcm_rb_commit_read(&ctx->pcm_rb, n);
    dst += (size_t)n * bpf;
    remaining -= n;
    total += n;
  }
  return (int)total;
}

// Frames currently queued (readable) in the capture ring.
uint32_t MiniAV_Audio_GetAvailableFrames(MiniAVAudioContextHandle context) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context;
  if (!ctx || !ctx->rb_inited)
    return 0;
  return ma_pcm_rb_available_read(&ctx->pcm_rb);
}

// --- Audio device change / context-lost subscriptions ---

static MiniAVDeviceWatcher *g_audio_watcher = NULL;

static MiniAVResultCode audio_enum_adapter(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *ud) {
  (void)ud;
  return MiniAV_Audio_EnumerateDevices(devices_out, count_out);
}

MiniAVResultCode MiniAV_Audio_SetDeviceChangeCallback(
    MiniAVDeviceChangeCallback callback, void *user_data) {
  return miniav_device_watcher_set(&g_audio_watcher, audio_enum_adapter, NULL,
                                   callback, user_data, 1500);
}

MiniAVResultCode MiniAV_Audio_SetContextLostCallback(
    MiniAVAudioContextHandle context_handle, MiniAVContextLostCallback callback,
    void *user_data) {
  MiniAVAudioContext *ctx = (MiniAVAudioContext *)context_handle;
  if (!ctx) return MINIAV_ERROR_INVALID_ARG;
  ctx->lost_cb = callback;
  ctx->lost_cb_user_data = user_data;
  return MINIAV_SUCCESS;
}
