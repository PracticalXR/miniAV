/* flac_decode.c — first-party FLAC decode via dr_flac (public domain).
 * FFmpeg-free. Whole-buffer decode → malloc'd interleaved float32. */
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#include "third_party/dr_flac.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define MSW_API __declspec(dllexport)
#else
#  define MSW_API __attribute__((visibility("default")))
#endif

/* Decode a whole FLAC byte buffer into interleaved float32. See
 * miniav_mp3_decode for the contract (free *out via miniav_sw_free). */
MSW_API int miniav_flac_decode(const uint8_t *data, int len, float **out,
                               int *channels, int *rate) {
  if (!data || len <= 0 || !out) return -1;
  drflac *f = drflac_open_memory(data, (size_t)len, NULL);
  if (!f) return -1;
  drflac_uint64 total = f->totalPCMFrameCount;
  float *buf = (float *)malloc((size_t)total * f->channels * sizeof(float));
  if (!buf) {
    drflac_close(f);
    return -1;
  }
  drflac_uint64 read = drflac_read_pcm_frames_f32(f, total, buf);
  *out = buf;
  if (channels) *channels = (int)f->channels;
  if (rate) *rate = (int)f->sampleRate;
  drflac_close(f);
  return (int)read;
}

/* --- Seekable streaming decode (see mp3_decode.c for the contract) --------- */
typedef struct {
  drflac *f;
  uint8_t *bytes; /* owned copy, kept alive for dr_flac's lifetime */
} miniav_flac_stream;

MSW_API void *miniav_flac_stream_open(const uint8_t *data, int len,
                                      int *channels, int *rate,
                                      int64_t *total_frames) {
  if (!data || len <= 0) return NULL;
  miniav_flac_stream *s = (miniav_flac_stream *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->bytes = (uint8_t *)malloc((size_t)len);
  if (!s->bytes) {
    free(s);
    return NULL;
  }
  memcpy(s->bytes, data, (size_t)len);
  s->f = drflac_open_memory(s->bytes, (size_t)len, NULL);
  if (!s->f) {
    free(s->bytes);
    free(s);
    return NULL;
  }
  if (channels) *channels = (int)s->f->channels;
  if (rate) *rate = (int)s->f->sampleRate;
  if (total_frames) *total_frames = (int64_t)s->f->totalPCMFrameCount;
  return s;
}

MSW_API int miniav_flac_stream_read(void *handle, float *out, int frames) {
  if (!handle || !out || frames <= 0) return 0;
  miniav_flac_stream *s = (miniav_flac_stream *)handle;
  return (int)drflac_read_pcm_frames_f32(s->f, (drflac_uint64)frames, out);
}

MSW_API int miniav_flac_stream_seek(void *handle, int64_t frame) {
  if (!handle || frame < 0) return 0;
  miniav_flac_stream *s = (miniav_flac_stream *)handle;
  return drflac_seek_to_pcm_frame(s->f, (drflac_uint64)frame) ? 1 : 0;
}

MSW_API void miniav_flac_stream_close(void *handle) {
  if (!handle) return;
  miniav_flac_stream *s = (miniav_flac_stream *)handle;
  drflac_close(s->f);
  free(s->bytes);
  free(s);
}
