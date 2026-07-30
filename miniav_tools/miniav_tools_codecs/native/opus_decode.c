/* opus_decode.c — first-party libopus DECODE wrapper for miniav_tools_codecs.
 *
 * FFmpeg-free: links only against libopus (static, built by cmake/opus.cmake).
 * Decode-only — the player path only decodes; encode/bitrate control stays in
 * miniaudio_dart. Mirrors miniaudio_dart's codec_opus.c decode path
 * (opus_decoder_create + opus_decode_float → interleaved float32) minus the
 * encoder + the codec-vtable indirection.
 */

#if __has_include(<opus/opus.h>)
#  include <opus/opus.h>
#elif __has_include(<opus.h>)
#  include <opus.h>
#else
#  error "Opus headers not found"
#endif

#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)
#  define MOPUS_API __declspec(dllexport)
#elif defined(__EMSCRIPTEN__)
#  include <emscripten.h>
// Keep + export these through the OBJECT/executable link to the wasm module.
#  define MOPUS_API EMSCRIPTEN_KEEPALIVE
#else
#  define MOPUS_API __attribute__((visibility("default")))
#endif

typedef struct {
  OpusDecoder *dec;
  int channels;
  int sample_rate;
} MiniAvOpusDec;

/* Create a decoder. sample_rate ∈ {8000,12000,16000,24000,48000}, channels ∈
 * {1,2}. Returns an opaque handle or NULL on error. */
MOPUS_API void *miniav_opus_create(int sample_rate, int channels) {
  if (channels < 1 || channels > 2) return NULL;
  int err = 0;
  OpusDecoder *dec = opus_decoder_create(sample_rate, channels, &err);
  if (err != OPUS_OK || !dec) {
    if (dec) opus_decoder_destroy(dec);
    return NULL;
  }
  MiniAvOpusDec *d = (MiniAvOpusDec *)calloc(1, sizeof(MiniAvOpusDec));
  if (!d) {
    opus_decoder_destroy(dec);
    return NULL;
  }
  d->dec = dec;
  d->channels = channels;
  d->sample_rate = sample_rate;
  return d;
}

/* Decode one Opus packet into interleaved float32 [-1,1]. [out] must hold at
 * least max_frames*channels floats. Returns frames-PER-CHANNEL decoded (so
 * total samples = ret*channels), or a negative Opus error code. Passing
 * data=NULL/len=0 requests packet-loss concealment for one frame. */
MOPUS_API int miniav_opus_decode(void *handle, const uint8_t *data, int len,
                                 float *out, int max_frames) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  if (!d || !out) return OPUS_BAD_ARG;
  return opus_decode_float(d->dec, data, len, out, max_frames, 0);
}

MOPUS_API int miniav_opus_channels(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  return d ? d->channels : 0;
}

MOPUS_API int miniav_opus_sample_rate(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  return d ? d->sample_rate : 0;
}

MOPUS_API void miniav_opus_destroy(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  if (!d) return;
  if (d->dec) opus_decoder_destroy(d->dec);
  free(d);
}

/* ---- ENCODE ------------------------------------------------------------- */

typedef struct {
  OpusEncoder *enc;
  int channels;
  int sample_rate;
} MiniAvOpusEnc;

/* Create an encoder. sample_rate ∈ {8000,12000,16000,24000,48000}, channels ∈
 * {1,2}, bitrate_bps target (<=0 → libopus auto). application: 2048=VOIP,
 * 2049=AUDIO (music/general), 2051=RESTRICTED_LOWDELAY; anything else → AUDIO.
 * VBR is enabled (matches miniaudio_dart's codec_opus.c). Returns an opaque
 * handle or NULL on error. */
MOPUS_API void *miniav_opus_enc_create(int sample_rate, int channels,
                                       int bitrate_bps, int application) {
  if (channels < 1 || channels > 2) return NULL;
  int app = OPUS_APPLICATION_AUDIO;
  if (application == OPUS_APPLICATION_VOIP ||
      application == OPUS_APPLICATION_RESTRICTED_LOWDELAY) {
    app = application;
  }
  int err = 0;
  OpusEncoder *enc = opus_encoder_create(sample_rate, channels, app, &err);
  if (err != OPUS_OK || !enc) {
    if (enc) opus_encoder_destroy(enc);
    return NULL;
  }
  if (bitrate_bps > 0) {
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate_bps));
  }
  opus_encoder_ctl(enc, OPUS_SET_VBR(1));
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)calloc(1, sizeof(MiniAvOpusEnc));
  if (!e) {
    opus_encoder_destroy(enc);
    return NULL;
  }
  e->enc = enc;
  e->channels = channels;
  e->sample_rate = sample_rate;
  return e;
}

/* Encode exactly one frame of [frames_per_channel] interleaved-float32 samples
 * (must be a valid Opus frame size: Fs/400,Fs/200,Fs/100,Fs/50,Fs/25,3*Fs/50 —
 * e.g. 120/240/480/960/1920/2880 at 48 kHz) into [out] (capacity out_cap
 * bytes). Returns the compressed byte count (>=1; 1 = DTX/silence) or a negative
 * Opus error code. */
MOPUS_API int miniav_opus_enc_encode(void *handle, const float *pcm,
                                     int frames_per_channel, uint8_t *out,
                                     int out_cap) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  if (!e || !pcm || !out) return OPUS_BAD_ARG;
  return opus_encode_float(e->enc, pcm, frames_per_channel, out, out_cap);
}

MOPUS_API void miniav_opus_enc_destroy(void *handle) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  if (!e) return;
  if (e->enc) opus_encoder_destroy(e->enc);
  free(e);
}
