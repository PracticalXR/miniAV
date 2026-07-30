#include "miniav_time.h"

#if defined(_WIN32)
#include <windows.h>

// Static variable to store the frequency so it's queried only once.
static LARGE_INTEGER g_qpc_frequency;
static BOOL g_qpc_frequency_initialized = FALSE;

// Overflow-safe (qpc * 1e6) / freq: the naive form overflows a 64-bit
// intermediate after ~weeks of uptime (~1.8e13 counts at a 10 MHz QPC).
// Split into whole-seconds + remainder so the multiply stays bounded.
static uint64_t miniav_qpc_scale_us(int64_t qpc, int64_t freq) {
  if (freq <= 0)
    return 0;
  int64_t secs = qpc / freq;
  int64_t rem = qpc % freq;
  return (uint64_t)(secs * 1000000 + (rem * 1000000) / freq);
}

uint64_t miniav_get_time_us(void) {
  if (!g_qpc_frequency_initialized) {
    QueryPerformanceFrequency(&g_qpc_frequency);
    g_qpc_frequency_initialized = TRUE;
  }
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return miniav_qpc_scale_us(counter.QuadPart, g_qpc_frequency.QuadPart);
}

LARGE_INTEGER miniav_get_qpc_frequency(void) {
  if (!g_qpc_frequency_initialized) {
    QueryPerformanceFrequency(&g_qpc_frequency);
    g_qpc_frequency_initialized = TRUE;
  }
  return g_qpc_frequency;
}

uint64_t miniav_qpc_to_microseconds(LARGE_INTEGER qpc_value,
                                    LARGE_INTEGER qpc_frequency) {
  // Overflow-safe split (see miniav_qpc_scale_us) — the naive
  // multiply-before-divide wraps on long-running processes.
  return miniav_qpc_scale_us(qpc_value.QuadPart, qpc_frequency.QuadPart);
}

#elif defined(__APPLE__)
#include <mach/mach_time.h>

uint64_t miniav_get_time_us(void) {
  static mach_timebase_info_data_t timebase;
  static int initialized = 0;
  if (!initialized) {
    mach_timebase_info(&timebase);
    initialized = 1;
  }
  uint64_t t = mach_absolute_time();
  // Overflow-safe: on Intel Macs timebase.numer/denom can be a large
  // non-unity ratio (e.g. 125/3), so `t * numer` overflows uint64 on long
  // uptime. Convert to ns via whole/remainder split, then to µs.
  uint64_t whole = t / timebase.denom;
  uint64_t rem = t % timebase.denom;
  uint64_t ns = whole * timebase.numer + (rem * timebase.numer) / timebase.denom;
  return ns / 1000;
}

#else // POSIX
#include <time.h>

uint64_t miniav_get_time_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
#endif

uint64_t miniav_rebase_time_us(MiniAVTimebase *tb, uint64_t device_time_us) {
  uint64_t now_us = miniav_get_time_us();
  if (!tb) {
    return now_us;
  }
  if (tb->initialized) {
    uint64_t rebased = (uint64_t)((int64_t)device_time_us + tb->offset_us);
    int64_t drift = (int64_t)(rebased - now_us);
    if (drift < 0) {
      drift = -drift;
    }
    if (drift <= MINIAV_TIMEBASE_RECALIBRATE_THRESHOLD_US) {
      return rebased;
    }
    // Device clock discontinuity (stream re-arm / graph restart): fall
    // through and re-anchor rather than emitting a wildly-off timestamp.
  }
  tb->offset_us = (int64_t)(now_us - device_time_us);
  tb->initialized = 1;
  return now_us;
}