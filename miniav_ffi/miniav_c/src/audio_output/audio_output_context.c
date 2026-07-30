// Core type definitions first
#include "../../include/miniav_buffer.h"
#include "../../include/miniav_types.h"

// Public API header for this module
#include "../../include/miniav_playback.h"

// Internal / common headers
#include "../common/miniav_context_base.h"
#include "../common/miniav_logging.h"
#include "../common/miniav_utils.h"
#include "audio_output_context.h"

#include <stdlib.h>
#include <string.h>

// iOS: playback also needs a live, playback-capable AVAudioSession category.
// The capture module already ships a PlayAndRecord shim; reuse it so a context
// that only plays back still routes to the speaker. No-ops everywhere else.
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

// --- Internal context ---
struct MiniAVAudioOutputContext {
  MiniAVContextBase *base;

  int engine_inited;
  int rb_inited;
  int sound_inited;
  int is_configured;
  int is_started;
  int session_active; // iOS audio session held (balances BEGIN/END)

  ma_engine engine;   // owns the playback device + mixing graph
  ma_pcm_rb rb;       // f32 SPSC ring; doubles as the sound's ma_data_source
  ma_sound sound;     // pulls from `rb`, applies volume/pan/pitch

  MiniAVAudioInfo format_info; // source stream layout (f32)
  ma_uint32 buffer_frames;     // ring depth

  // Cached controls so Set* before Configure (or across re-Configure) survive.
  float volume;
  float pan;
  float pitch;

  // Stored for API parity with capture; playback device-lost is not yet wired
  // to an engine-level notification (the engine owns its device internally).
  MiniAVContextLostCallback lost_cb;
  void *lost_cb_user_data;
};

// --- Helpers ---

static void fill_device_info(const ma_device_info *src, MiniAVDeviceInfo *dst) {
  memset(dst, 0, sizeof(MiniAVDeviceInfo));
  // Use the device name as the portable identifier (same convention as the
  // capture module).
  miniav_strlcpy(dst->device_id, src->name, sizeof(dst->device_id));
  miniav_strlcpy(dst->name, src->name, sizeof(dst->name));
  dst->is_default = src->isDefault;
}

// Tear down the engine/ring/sound (leaves the context allocated + reusable).
static void audio_output_teardown_stream(MiniAVAudioOutputContext *ctx) {
  // Order matters: stop pulling from the ring (sound) and stop the device
  // (engine) BEFORE freeing the ring the audio thread reads from.
  if (ctx->sound_inited) {
    ma_sound_uninit(&ctx->sound);
    ctx->sound_inited = 0;
  }
  if (ctx->engine_inited) {
    ma_engine_uninit(&ctx->engine); // stops + joins the device thread
    ctx->engine_inited = 0;
  }
  if (ctx->rb_inited) {
    ma_pcm_rb_uninit(&ctx->rb);
    ctx->rb_inited = 0;
  }
  if (ctx->session_active) {
    MINIAV_AUDIO_SESSION_END();
    ctx->session_active = 0;
  }
  ctx->is_started = 0;
  ctx->is_configured = 0;
}

// --- Public API ---

MiniAVResultCode
MiniAV_AudioOutput_EnumerateDevices(MiniAVDeviceInfo **devices,
                                    uint32_t *count) {
  if (!devices || !count)
    return MINIAV_ERROR_INVALID_ARG;
  *devices = NULL;
  *count = 0;

  ma_context ma_ctx;
  if (ma_context_init(NULL, 0, NULL, &ma_ctx) != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AudioOutput: failed to init miniaudio context for enumeration.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ma_device_info *playbackInfos, *captureInfos;
  ma_uint32 playbackCount, captureCount;
  if (ma_context_get_devices(&ma_ctx, &playbackInfos, &playbackCount,
                             &captureInfos, &captureCount) != MA_SUCCESS) {
    ma_context_uninit(&ma_ctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  if (playbackCount == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "AudioOutput: no playback devices found.");
    ma_context_uninit(&ma_ctx);
    return MINIAV_SUCCESS;
  }

  *devices =
      (MiniAVDeviceInfo *)miniav_calloc(playbackCount, sizeof(MiniAVDeviceInfo));
  if (!*devices) {
    ma_context_uninit(&ma_ctx);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  for (ma_uint32 i = 0; i < playbackCount; ++i) {
    fill_device_info(&playbackInfos[i], &(*devices)[i]);
  }
  *count = playbackCount;

  ma_context_uninit(&ma_ctx);
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "AudioOutput: enumerated %u playback devices.",
             *count);
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_AudioOutput_GetDefaultFormat(const char *device_id,
                                    MiniAVAudioInfo *format_out) {
  if (!format_out)
    return MINIAV_ERROR_INVALID_ARG;
  memset(format_out, 0, sizeof(MiniAVAudioInfo));
  MINIAV_UNUSED(device_id);

  // Query the default playback device's native format when possible.
  ma_context ma_ctx;
  if (ma_context_init(NULL, 0, NULL, &ma_ctx) == MA_SUCCESS) {
    ma_device_info info;
    if (ma_context_get_device_info(&ma_ctx, ma_device_type_playback, NULL,
                                   &info) == MA_SUCCESS &&
        info.nativeDataFormatCount > 0) {
      ma_format mf = info.nativeDataFormats[0].format;
      format_out->format = MINIAV_AUDIO_FORMAT_F32; // we always feed f32
      MINIAV_UNUSED(mf);
      format_out->channels = info.nativeDataFormats[0].channels
                                 ? info.nativeDataFormats[0].channels
                                 : 2;
      format_out->sample_rate = info.nativeDataFormats[0].sampleRate
                                    ? info.nativeDataFormats[0].sampleRate
                                    : 48000;
      ma_context_uninit(&ma_ctx);
      return MINIAV_SUCCESS;
    }
    ma_context_uninit(&ma_ctx);
  }

  format_out->format = MINIAV_AUDIO_FORMAT_F32;
  format_out->sample_rate = 48000;
  format_out->channels = 2;
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "AudioOutput: could not query default device — returning "
             "F32/48kHz/2ch fallback.");
  return MINIAV_SUCCESS;
}

MiniAVAudioOutputContextHandle MiniAV_AudioOutput_CreateContext(void) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)miniav_calloc(
      1, sizeof(MiniAVAudioOutputContext));
  if (!ctx) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AudioOutput: failed to allocate context.");
    return NULL;
  }
  ctx->base = miniav_context_base_create(NULL);
  if (!ctx->base) {
    miniav_free(ctx);
    return NULL;
  }
  ctx->volume = 1.0f;
  ctx->pan = 0.0f;
  ctx->pitch = 1.0f;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AudioOutput: context created.");
  return (MiniAVAudioOutputContextHandle)ctx;
}

MiniAVResultCode
MiniAV_AudioOutput_DestroyContext(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;

  audio_output_teardown_stream(ctx);
  if (ctx->base)
    miniav_context_base_destroy(ctx->base);
  miniav_free(ctx);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AudioOutput: context destroyed.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_AudioOutput_Configure(
    MiniAVAudioOutputContextHandle context, const char *device_id, int format,
    uint32_t sample_rate, uint32_t channels, uint32_t buffer_frames) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || sample_rate == 0 || channels == 0)
    return MINIAV_ERROR_INVALID_ARG;
  MINIAV_UNUSED(format); // ring is always f32; writes are float PCM.

  // Resolve the requested device_id — which miniav exposes as the device *name*
  // (see fill_device_info) — to a concrete ma_device_id so the engine opens the
  // chosen playback device instead of always falling back to the system default.
  // Kept on the stack: ma_engine_init copies the id into its device during the
  // synchronous init call below, so this need only outlive that call.
  ma_device_id playback_id;
  ma_bool32 have_playback_id = MA_FALSE;
  if (device_id && device_id[0] != '\0') {
    ma_context tmp_ctx;
    if (ma_context_init(NULL, 0, NULL, &tmp_ctx) == MA_SUCCESS) {
      ma_device_info *playback_infos = NULL;
      ma_uint32 playback_count = 0;
      if (ma_context_get_devices(&tmp_ctx, &playback_infos, &playback_count, NULL,
                                 NULL) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < playback_count; ++i) {
          if (strcmp(playback_infos[i].name, device_id) == 0) {
            playback_id = playback_infos[i].id;
            have_playback_id = MA_TRUE;
            break;
          }
        }
      }
      ma_context_uninit(&tmp_ctx);
    }
    if (have_playback_id) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "AudioOutput: selected playback device '%s'.", device_id);
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "AudioOutput: playback device '%s' not found — using system "
                 "default.",
                 device_id);
    }
  }

  // Re-configuring rebuilds the whole stream.
  audio_output_teardown_stream(ctx);

  // iOS: activate a playback-capable session BEFORE creating the device.
  if (MINIAV_AUDIO_SESSION_BEGIN() != 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "AudioOutput: audio-session activation failed — playback may be "
               "silent.");
  } else {
    ctx->session_active = 1;
  }

  // Engine: leave channels/sampleRate at 0 so it adopts the device-native
  // layout. The sound below resamples/upmixes the source stream to it, which
  // also lets stereo pan work for mono sources.
  ma_engine_config engineConfig = ma_engine_config_init();
  if (have_playback_id) {
    engineConfig.pPlaybackDeviceID = &playback_id;
  }
  ma_result r = ma_engine_init(&engineConfig, &ctx->engine);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "AudioOutput: ma_engine_init failed: %s",
               ma_result_description(r));
    if (ctx->session_active) {
      MINIAV_AUDIO_SESSION_END();
      ctx->session_active = 0;
    }
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  ctx->engine_inited = 1;

  // Ring buffer (f32). Default depth ~100 ms at the source rate.
  ma_uint32 depth = buffer_frames ? buffer_frames : (sample_rate / 10);
  if (depth < 256)
    depth = 256;
  r = ma_pcm_rb_init(ma_format_f32, channels, depth, NULL, NULL, &ctx->rb);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "AudioOutput: ma_pcm_rb_init failed: %s",
               ma_result_description(r));
    audio_output_teardown_stream(ctx);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  // ma_pcm_rb_init leaves sampleRate at 0; the sound's resampler needs it.
  ctx->rb.sampleRate = sample_rate;
  ctx->rb_inited = 1;

  // Sound fed by the ring data source. NO_SPATIALIZATION keeps it a simple 2D
  // stereo source (volume + pan + pitch), no 3D listener math.
  r = ma_sound_init_from_data_source(&ctx->engine, &ctx->rb,
                                     MA_SOUND_FLAG_NO_SPATIALIZATION, NULL,
                                     &ctx->sound);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "AudioOutput: ma_sound_init_from_data_source failed: %s",
               ma_result_description(r));
    audio_output_teardown_stream(ctx);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  ctx->sound_inited = 1;

  // Apply cached controls to the fresh sound.
  ma_sound_set_volume(&ctx->sound, ctx->volume);
  ma_sound_set_pan(&ctx->sound, ctx->pan);
  ma_sound_set_pitch(&ctx->sound, ctx->pitch);

  ctx->format_info.format = MINIAV_AUDIO_FORMAT_F32;
  ctx->format_info.sample_rate = sample_rate;
  ctx->format_info.channels = (uint8_t)channels;
  ctx->format_info.num_frames = depth;
  ctx->buffer_frames = depth;
  ctx->is_configured = 1;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "AudioOutput: configured F32 %uHz %uch, ring=%u frames.",
             sample_rate, channels, depth);
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_AudioOutput_GetConfiguredFormat(MiniAVAudioOutputContextHandle context,
                                       MiniAVAudioInfo *format_out) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || !format_out)
    return MINIAV_ERROR_INVALID_ARG;
  if (!ctx->is_configured) {
    memset(format_out, 0, sizeof(MiniAVAudioInfo));
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  *format_out = ctx->format_info;
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_AudioOutput_Start(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (!ctx->is_configured || !ctx->sound_inited)
    return MINIAV_ERROR_NOT_CONFIGURED;
  if (ctx->is_started)
    return MINIAV_SUCCESS;

  // ma_engine_start resumes the underlying device — on web this resumes the
  // AudioContext, so calling Start from a user-gesture stack satisfies the
  // browser autoplay policy.
  ma_result r = ma_engine_start(&ctx->engine);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "AudioOutput: ma_engine_start: %s",
               ma_result_description(r));
  }
  r = ma_sound_start(&ctx->sound);
  if (r != MA_SUCCESS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "AudioOutput: ma_sound_start failed: %s",
               ma_result_description(r));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  ctx->is_started = 1;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AudioOutput: started.");
  return MINIAV_SUCCESS;
}

MiniAVResultCode MiniAV_AudioOutput_Stop(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (!ctx->sound_inited)
    return MINIAV_ERROR_NOT_RUNNING;
  // Pause the source; keep the engine/device open so Start resumes instantly
  // and queued samples remain in the ring.
  ma_sound_stop(&ctx->sound);
  ctx->is_started = 0;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "AudioOutput: stopped (paused).");
  return MINIAV_SUCCESS;
}

MiniAVResultCode
MiniAV_AudioOutput_Clear(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || !ctx->rb_inited)
    return MINIAV_ERROR_INVALID_ARG;

  // The ring is single-consumer. Pause the sound so the audio thread stops
  // reading, drain the queued frames, then restore playback state. Draining via
  // acquire/commit handles the ring's subbuffer wrap in one pass.
  int was_started = ctx->is_started;
  if (ctx->sound_inited && was_started)
    ma_sound_stop(&ctx->sound);

  for (;;) {
    ma_uint32 n = 0xFFFFFFFF;
    void *p = NULL;
    if (ma_pcm_rb_acquire_read(&ctx->rb, &n, &p) != MA_SUCCESS || n == 0)
      break;
    ma_pcm_rb_commit_read(&ctx->rb, n);
  }

  if (ctx->sound_inited && was_started)
    ma_sound_start(&ctx->sound);
  return MINIAV_SUCCESS;
}

int MiniAV_AudioOutput_WriteFrames(MiniAVAudioOutputContextHandle context,
                                   const float *interleaved,
                                   uint32_t frame_count) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || !interleaved)
    return (int)MINIAV_ERROR_INVALID_ARG;
  if (!ctx->rb_inited)
    return (int)MINIAV_ERROR_NOT_CONFIGURED;
  if (frame_count == 0)
    return 0;

  const ma_uint32 channels = ctx->format_info.channels;
  const float *src = interleaved;
  ma_uint32 remaining = frame_count;
  ma_uint32 total_written = 0;

  while (remaining > 0) {
    ma_uint32 to_write = remaining;
    void *p_write = NULL;
    ma_result r = ma_pcm_rb_acquire_write(&ctx->rb, &to_write, &p_write);
    if (r != MA_SUCCESS || to_write == 0)
      break; // ring full — caller drops or retries the remainder.
    memcpy(p_write, src, (size_t)to_write * channels * sizeof(float));
    ma_pcm_rb_commit_write(&ctx->rb, to_write);
    src += (size_t)to_write * channels;
    remaining -= to_write;
    total_written += to_write;
  }
  return (int)total_written;
}

uint32_t
MiniAV_AudioOutput_GetBufferedFrames(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || !ctx->rb_inited)
    return 0;
  return ma_pcm_rb_available_read(&ctx->rb);
}

uint32_t
MiniAV_AudioOutput_GetWritableFrames(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx || !ctx->rb_inited)
    return 0;
  return ma_pcm_rb_available_write(&ctx->rb);
}

MiniAVResultCode
MiniAV_AudioOutput_SetVolume(MiniAVAudioOutputContextHandle context,
                             float volume) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (volume < 0.0f)
    volume = 0.0f;
  ctx->volume = volume;
  if (ctx->sound_inited)
    ma_sound_set_volume(&ctx->sound, volume);
  return MINIAV_SUCCESS;
}

float MiniAV_AudioOutput_GetVolume(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  return ctx ? ctx->volume : 0.0f;
}

MiniAVResultCode
MiniAV_AudioOutput_SetPan(MiniAVAudioOutputContextHandle context, float pan) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (pan < -1.0f)
    pan = -1.0f;
  if (pan > 1.0f)
    pan = 1.0f;
  ctx->pan = pan;
  if (ctx->sound_inited)
    ma_sound_set_pan(&ctx->sound, pan);
  return MINIAV_SUCCESS;
}

float MiniAV_AudioOutput_GetPan(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  return ctx ? ctx->pan : 0.0f;
}

MiniAVResultCode
MiniAV_AudioOutput_SetPitch(MiniAVAudioOutputContextHandle context,
                            float pitch) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  if (pitch <= 0.0f)
    pitch = 1.0f;
  ctx->pitch = pitch;
  if (ctx->sound_inited)
    ma_sound_set_pitch(&ctx->sound, pitch);
  return MINIAV_SUCCESS;
}

float MiniAV_AudioOutput_GetPitch(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  return ctx ? ctx->pitch : 1.0f;
}

int MiniAV_AudioOutput_IsStarted(MiniAVAudioOutputContextHandle context) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  return (ctx && ctx->is_started) ? 1 : 0;
}

MiniAVResultCode MiniAV_AudioOutput_SetContextLostCallback(
    MiniAVAudioOutputContextHandle context, MiniAVContextLostCallback callback,
    void *user_data) {
  MiniAVAudioOutputContext *ctx = (MiniAVAudioOutputContext *)context;
  if (!ctx)
    return MINIAV_ERROR_INVALID_ARG;
  ctx->lost_cb = callback;
  ctx->lost_cb_user_data = user_data;
  return MINIAV_SUCCESS;
}
