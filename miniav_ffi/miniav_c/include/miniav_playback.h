#ifndef MINIAV_PLAYBACK_H
#define MINIAV_PLAYBACK_H

// --- Audio Output (Playback) API ---
//
// First-party PCM playback sink built on miniaudio's high-level engine
// (ma_engine + a ring-buffer data source). The SAME C is used by the native
// FFI bindings AND the Emscripten/WASM web build, so the miniav audio sink
// behaves identically on desktop, mobile and web.
//
// This module is intentionally a *device* layer: it accepts interleaved
// float32 PCM and plays it. Compressed-audio decode/encode lives in
// miniav_tools (WebCodecs on web, FFmpeg on native), which already emits the
// canonical interleaved-f32 `DecodedAudio` layout consumed here — so a player
// decodes with miniav_tools and feeds the raw PCM straight into this sink.
//
// The API is deliberately "flat" (scalar args, values returned directly rather
// than via out-params on the hot path) so it is trivially callable both from
// dart:ffi (native) and from hand-written js_interop `ccall`/`_export` glue
// (web) without marshalling structs across the WASM boundary.
//
// Threading: writes come from the caller's thread; reads happen on
// miniaudio's audio thread (native) or the Web Audio ScriptProcessor callback
// (web, single-threaded). The ring is single-producer/single-consumer.

#include "export.h" // For MINIAV_API
#include "miniav_capture.h" // For MiniAVContextLostCallback
#include "miniav_types.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Enumerate audio OUTPUT (playback) devices. On success `*devices` is a
// heap array of `*count` entries owned by the caller — release it with
// MiniAV_FreeDeviceList. `device_id` for Configure is the device NAME
// (matching MiniAVDeviceInfo.device_id here).
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_EnumerateDevices(MiniAVDeviceInfo **devices, uint32_t *count);

// Native default output format for a device (`device_id` NULL/"" = system
// default). Handy as a sink target when the source format is flexible.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_GetDefaultFormat(const char *device_id,
                                    MiniAVAudioInfo *format_out);

// Create a playback context. Returns NULL on allocation/engine failure.
MINIAV_API MiniAVAudioOutputContextHandle MiniAV_AudioOutput_CreateContext(void);

// Destroy a context created by MiniAV_AudioOutput_CreateContext. Stops
// playback and releases the engine/device/ring. Safe to call once.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_DestroyContext(MiniAVAudioOutputContextHandle context);

// Configure (or re-configure) the output stream. Must be called before Start.
//   device_id     : NULL/"" selects the default output device.
//   format        : MiniAVAudioFormat — F32 is the canonical/only ring format;
//                   other values are coerced to F32 (writes are float PCM).
//   sample_rate   : source stream rate; miniaudio resamples to the device.
//   channels      : source channel count (mono/stereo/…); the engine mixes to
//                   the device layout and applies pan.
//   buffer_frames : ring depth in frames (0 = ~100 ms at `sample_rate`).
// Re-configuring tears down any previous stream first.
MINIAV_API MiniAVResultCode MiniAV_AudioOutput_Configure(
    MiniAVAudioOutputContextHandle context, const char *device_id, int format,
    uint32_t sample_rate, uint32_t channels, uint32_t buffer_frames);

// Retrieve the configured stream format (the source layout given to Configure).
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_GetConfiguredFormat(MiniAVAudioOutputContextHandle context,
                                       MiniAVAudioInfo *format_out);

// Begin pulling audio. On web this resumes the AudioContext, so call it from a
// user-gesture stack (e.g. a Play button handler) to satisfy autoplay policy.
// Idempotent while already started.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_Start(MiniAVAudioOutputContextHandle context);

// Stop pulling audio (pause). Queued samples remain buffered; the device stays
// open so Start resumes instantly.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_Stop(MiniAVAudioOutputContextHandle context);

// Drop all queued samples (flush / seek). Playback state is preserved.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_Clear(MiniAVAudioOutputContextHandle context);

// Push interleaved float32 PCM. Writes as many frames as fit in the ring and
// returns the number of frames accepted (may be < frame_count when the ring is
// full — the caller drops or retries). Returns a negative MiniAVResultCode on
// error. `interleaved` holds frame_count * channels floats.
MINIAV_API int
MiniAV_AudioOutput_WriteFrames(MiniAVAudioOutputContextHandle context,
                               const float *interleaved, uint32_t frame_count);

// Frames currently queued (readable) / free space (writable) in the ring.
MINIAV_API uint32_t
MiniAV_AudioOutput_GetBufferedFrames(MiniAVAudioOutputContextHandle context);
MINIAV_API uint32_t
MiniAV_AudioOutput_GetWritableFrames(MiniAVAudioOutputContextHandle context);

// Master gain for this stream. 0.0 = silence, 1.0 = unity (may exceed 1).
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_SetVolume(MiniAVAudioOutputContextHandle context,
                             float volume);
MINIAV_API float
MiniAV_AudioOutput_GetVolume(MiniAVAudioOutputContextHandle context);

// Stereo pan: -1.0 = full left, 0.0 = center, +1.0 = full right.
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_SetPan(MiniAVAudioOutputContextHandle context, float pan);
MINIAV_API float
MiniAV_AudioOutput_GetPan(MiniAVAudioOutputContextHandle context);

// Playback rate / pitch multiplier: 1.0 = normal, 2.0 = one octave up. Alters
// both speed and pitch (no time-stretch).
MINIAV_API MiniAVResultCode
MiniAV_AudioOutput_SetPitch(MiniAVAudioOutputContextHandle context, float pitch);
MINIAV_API float
MiniAV_AudioOutput_GetPitch(MiniAVAudioOutputContextHandle context);

// Non-zero while playback is running (Start called and not Stopped).
MINIAV_API int
MiniAV_AudioOutput_IsStarted(MiniAVAudioOutputContextHandle context);

// Device-lost notification (output endpoint removed mid-stream). Stored for
// parity with the capture API; see the .c for current firing support.
MINIAV_API MiniAVResultCode MiniAV_AudioOutput_SetContextLostCallback(
    MiniAVAudioOutputContextHandle context, MiniAVContextLostCallback callback,
    void *user_data);

#ifdef __cplusplus
}
#endif

#endif // MINIAV_PLAYBACK_H
