/* vorbis_decode.c — first-party Ogg Vorbis decode via stb_vorbis (public
 * domain). FFmpeg-free. Whole-buffer decode → malloc'd interleaved float32. */
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "third_party/stb_vorbis.c"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define MSW_API __declspec(dllexport)
#else
#  define MSW_API __attribute__((visibility("default")))
#endif

/* Decode a whole Ogg-Vorbis byte buffer into interleaved float32. See
 * miniav_mp3_decode for the contract (free *out via miniav_sw_free). */
MSW_API int miniav_vorbis_decode(const uint8_t *data, int len, float **out,
                                 int *channels, int *rate) {
  if (!data || len <= 0 || !out) return -1;
  int err = 0;
  stb_vorbis *v = stb_vorbis_open_memory(data, len, &err, NULL);
  if (!v) return -1;
  stb_vorbis_info info = stb_vorbis_get_info(v);
  unsigned int total = stb_vorbis_stream_length_in_samples(v); /* frames/ch */
  float *buf =
      (float *)malloc((size_t)total * info.channels * sizeof(float));
  if (!buf) {
    stb_vorbis_close(v);
    return -1;
  }
  int read = stb_vorbis_get_samples_float_interleaved(
      v, info.channels, buf, (int)(total * info.channels));
  *out = buf;
  if (channels) *channels = info.channels;
  if (rate) *rate = (int)info.sample_rate;
  stb_vorbis_close(v);
  return read; /* frames per channel */
}

/* --- Seekable streaming decode (see mp3_decode.c for the contract) --------- */
typedef struct {
  stb_vorbis *v;
  uint8_t *bytes; /* owned copy, kept alive for stb_vorbis's lifetime */
  int channels;   /* cached for the interleaved read */
} miniav_vorbis_stream;

MSW_API void *miniav_vorbis_stream_open(const uint8_t *data, int len,
                                        int *channels, int *rate,
                                        int64_t *total_frames) {
  if (!data || len <= 0) return NULL;
  miniav_vorbis_stream *s = (miniav_vorbis_stream *)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->bytes = (uint8_t *)malloc((size_t)len);
  if (!s->bytes) {
    free(s);
    return NULL;
  }
  memcpy(s->bytes, data, (size_t)len);
  int err = 0;
  s->v = stb_vorbis_open_memory(s->bytes, len, &err, NULL);
  if (!s->v) {
    free(s->bytes);
    free(s);
    return NULL;
  }
  stb_vorbis_info info = stb_vorbis_get_info(s->v);
  s->channels = info.channels;
  if (channels) *channels = info.channels;
  if (rate) *rate = (int)info.sample_rate;
  if (total_frames)
    *total_frames = (int64_t)stb_vorbis_stream_length_in_samples(s->v);
  return s;
}

MSW_API int miniav_vorbis_stream_read(void *handle, float *out, int frames) {
  if (!handle || !out || frames <= 0) return 0;
  miniav_vorbis_stream *s = (miniav_vorbis_stream *)handle;
  /* Returns frames (per channel) actually written; fills interleaved. */
  return stb_vorbis_get_samples_float_interleaved(s->v, s->channels, out,
                                                  frames * s->channels);
}

MSW_API int miniav_vorbis_stream_seek(void *handle, int64_t frame) {
  if (!handle || frame < 0) return 0;
  miniav_vorbis_stream *s = (miniav_vorbis_stream *)handle;
  return stb_vorbis_seek_frame(s->v, (unsigned int)frame) ? 1 : 0;
}

MSW_API void miniav_vorbis_stream_close(void *handle) {
  if (!handle) return;
  miniav_vorbis_stream *s = (miniav_vorbis_stream *)handle;
  stb_vorbis_close(s->v);
  free(s->bytes);
  free(s);
}
