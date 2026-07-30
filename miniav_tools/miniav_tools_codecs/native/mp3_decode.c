/* mp3_decode.c — first-party MP3 decode via dr_mp3 (public domain).
 * FFmpeg-free. Whole-buffer decode → malloc'd interleaved float32. */
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#include "third_party/dr_mp3.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define MSW_API __declspec(dllexport)
#else
#  define MSW_API __attribute__((visibility("default")))
#endif

/* Decode a whole MP3 byte buffer into interleaved float32.
 * On success returns frames-per-channel (>=0) and sets *out to a malloc'd
 * buffer of (frames*channels) floats (free via miniav_sw_free), plus the
 * channel count and sample rate. Returns -1 on error. */
MSW_API int miniav_mp3_decode(const uint8_t *data, int len, float **out,
                              int *channels, int *rate) {
  if (!data || len <= 0 || !out) return -1;
  drmp3 mp3;
  if (!drmp3_init_memory(&mp3, data, (size_t)len, NULL)) return -1;
  drmp3_uint64 total = drmp3_get_pcm_frame_count(&mp3);
  float *buf = (float *)malloc((size_t)total * mp3.channels * sizeof(float));
  if (!buf) {
    drmp3_uninit(&mp3);
    return -1;
  }
  drmp3_uint64 read = drmp3_read_pcm_frames_f32(&mp3, total, buf);
  *out = buf;
  if (channels) *channels = (int)mp3.channels;
  if (rate) *rate = (int)mp3.sampleRate;
  drmp3_uninit(&mp3);
  return (int)read;
}

/* Free a buffer returned by any miniav_*_decode function. */
MSW_API void miniav_sw_free(void *p) { free(p); }

/* --- Seekable streaming decode ---------------------------------------------
 * A handle owns a COPY of the compressed bytes (dr_mp3 references, not copies,
 * the input) and decodes PCM on demand with random seek — no whole-file PCM in
 * RAM, no disk cache. Synchronous: read/seek are direct dr_mp3 calls. */
typedef struct {
  drmp3 d;
  uint8_t *bytes; /* owned copy, kept alive for dr_mp3's lifetime */
} miniav_mp3_stream;

/* Open a streaming decoder over [data]/[len]. On success returns a handle and
 * reports channels, sample rate, and total PCM frames (per channel); NULL on
 * error. Position starts at frame 0. */
MSW_API void *miniav_mp3_stream_open(const uint8_t *data, int len,
                                     int *channels, int *rate,
                                     int64_t *total_frames) {
  if (!data || len <= 0) return NULL;
  miniav_mp3_stream *s = (miniav_mp3_stream *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->bytes = (uint8_t *)malloc((size_t)len);
  if (!s->bytes) {
    free(s);
    return NULL;
  }
  memcpy(s->bytes, data, (size_t)len);
  if (!drmp3_init_memory(&s->d, s->bytes, (size_t)len, NULL)) {
    free(s->bytes);
    free(s);
    return NULL;
  }
  if (channels) *channels = (int)s->d.channels;
  if (rate) *rate = (int)s->d.sampleRate;
  if (total_frames) *total_frames = (int64_t)drmp3_get_pcm_frame_count(&s->d);
  /* get_pcm_frame_count restores position, but be explicit. */
  drmp3_seek_to_pcm_frame(&s->d, 0);
  return s;
}

/* Read up to [frames] frames of interleaved f32 into [out] (capacity
 * frames*channels). Returns frames actually read (0 at EOF). */
MSW_API int miniav_mp3_stream_read(void *handle, float *out, int frames) {
  if (!handle || !out || frames <= 0) return 0;
  miniav_mp3_stream *s = (miniav_mp3_stream *)handle;
  return (int)drmp3_read_pcm_frames_f32(&s->d, (drmp3_uint64)frames, out);
}

/* Seek so the next read starts at PCM [frame]. Returns 1 on success, 0 on
 * failure. */
MSW_API int miniav_mp3_stream_seek(void *handle, int64_t frame) {
  if (!handle || frame < 0) return 0;
  miniav_mp3_stream *s = (miniav_mp3_stream *)handle;
  return drmp3_seek_to_pcm_frame(&s->d, (drmp3_uint64)frame) ? 1 : 0;
}

MSW_API void miniav_mp3_stream_close(void *handle) {
  if (!handle) return;
  miniav_mp3_stream *s = (miniav_mp3_stream *)handle;
  drmp3_uninit(&s->d);
  free(s->bytes);
  free(s);
}
