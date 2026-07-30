// Smoke test for the audio-output (playback) module: configures a stereo f32
// sink, pushes a 440 Hz sine for ~2 seconds, exercises volume/pan, then tears
// down. Also verifies the ring back-pressure contract (writes may be partial).
//
// Build target: test_audio_output (see CMakeLists.txt). Run on a machine with
// an audio output device; exits 0 on success.

#include "../../../include/miniav_playback.h"
#include "../../../include/miniav_types.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static void sleep_ms(unsigned ms) { Sleep(ms); }
#else
#include <time.h>
static void sleep_ms(unsigned ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}
#endif

#define SAMPLE_RATE 48000u
#define CHANNELS 2u
#define TONE_HZ 440.0
#define DURATION_MS 2000u
#define CHUNK_FRAMES 480u // 10 ms

int main(void) {
  printf("[test_audio_output] enumerating playback devices...\n");
  MiniAVDeviceInfo *devices = NULL;
  uint32_t device_count = 0;
  if (MiniAV_AudioOutput_EnumerateDevices(&devices, &device_count) ==
      MINIAV_SUCCESS) {
    printf("[test_audio_output] %u playback device(s):\n", device_count);
    for (uint32_t i = 0; i < device_count; ++i) {
      printf("  [%u] %s%s\n", i, devices[i].name,
             devices[i].is_default ? " (default)" : "");
    }
  }

  MiniAVAudioOutputContextHandle ctx = MiniAV_AudioOutput_CreateContext();
  if (!ctx) {
    fprintf(stderr, "[test_audio_output] CreateContext failed\n");
    return 1;
  }

  MiniAVResultCode r = MiniAV_AudioOutput_Configure(
      ctx, NULL, MINIAV_AUDIO_FORMAT_F32, SAMPLE_RATE, CHANNELS, 0);
  if (r != MINIAV_SUCCESS) {
    fprintf(stderr, "[test_audio_output] Configure failed: %d\n", (int)r);
    MiniAV_AudioOutput_DestroyContext(ctx);
    return 1;
  }

  MiniAV_AudioOutput_SetVolume(ctx, 0.3f);

  if (MiniAV_AudioOutput_Start(ctx) != MINIAV_SUCCESS) {
    fprintf(stderr, "[test_audio_output] Start failed\n");
    MiniAV_AudioOutput_DestroyContext(ctx);
    return 1;
  }

  printf("[test_audio_output] playing %.0f Hz tone for %u ms...\n", TONE_HZ,
         DURATION_MS);

  float chunk[CHUNK_FRAMES * CHANNELS];
  double phase = 0.0;
  const double phase_inc = 2.0 * 3.14159265358979323846 * TONE_HZ / SAMPLE_RATE;
  uint32_t chunks = (DURATION_MS * SAMPLE_RATE / 1000u) / CHUNK_FRAMES;
  uint32_t total_written = 0;

  for (uint32_t c = 0; c < chunks; ++c) {
    for (uint32_t f = 0; f < CHUNK_FRAMES; ++f) {
      float s = (float)sin(phase);
      phase += phase_inc;
      if (phase > 2.0 * 3.14159265358979323846)
        phase -= 2.0 * 3.14159265358979323846;
      chunk[f * CHANNELS + 0] = s;
      chunk[f * CHANNELS + 1] = s;
    }
    // Slow, gentle pan sweep to exercise the control.
    MiniAV_AudioOutput_SetPan(ctx, (float)sin(c * 0.05) * 0.8f);

    uint32_t offset = 0;
    while (offset < CHUNK_FRAMES) {
      int wrote = MiniAV_AudioOutput_WriteFrames(
          ctx, &chunk[offset * CHANNELS], CHUNK_FRAMES - offset);
      if (wrote < 0) {
        fprintf(stderr, "[test_audio_output] WriteFrames error: %d\n", wrote);
        MiniAV_AudioOutput_DestroyContext(ctx);
        return 1;
      }
      offset += (uint32_t)wrote;
      total_written += (uint32_t)wrote;
      if (wrote == 0)
        sleep_ms(5); // ring full — let the device drain (back-pressure).
    }
    sleep_ms(10);
  }

  printf("[test_audio_output] wrote %u frames; buffered=%u\n", total_written,
         MiniAV_AudioOutput_GetBufferedFrames(ctx));

  // Let the tail drain.
  sleep_ms(200);

  MiniAV_AudioOutput_Stop(ctx);
  MiniAV_AudioOutput_DestroyContext(ctx);
  if (devices)
    MiniAV_FreeDeviceList(devices, device_count);

  printf("[test_audio_output] OK\n");
  return 0;
}
