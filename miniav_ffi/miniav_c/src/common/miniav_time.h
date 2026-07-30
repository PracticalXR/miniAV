#ifndef MINIAV_TIME_H
#define MINIAV_TIME_H

#include <stdint.h>

#if defined(_WIN32)
#include <windows.h> // For LARGE_INTEGER
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Gets the current high-resolution time in microseconds.
 * This time is suitable for general-purpose timestamping.
 * @return Current time in microseconds.
 */
uint64_t miniav_get_time_us(void);

/**
 * @brief Calibrated rebase of a device/driver clock onto the
 * miniav_get_time_us() epoch.
 *
 * Capture APIs stamp frames with their own clocks (Media Foundation
 * REFERENCE_TIME, PipeWire graph time, CMSampleBuffer presentation time) whose
 * epochs are unrelated to miniav_get_time_us(). Cross-track A/V sync requires
 * every MiniAVBuffer.timestamp_us to share ONE monotonic microsecond timeline,
 * so each backend converts its device timestamp to microseconds and rebases it
 * through one of these: the first sample anchors the offset
 * (miniav_get_time_us() - device_time_us) and subsequent samples apply it,
 * preserving the device clock's inter-frame spacing (usually the hardware
 * capture instant) while landing on the shared epoch.
 *
 * If the rebased result ever drifts more than
 * MINIAV_TIMEBASE_RECALIBRATE_THRESHOLD_US from miniav_get_time_us() (device
 * clock reset — e.g. a camera re-arm or graph restart), the offset is
 * re-anchored automatically.
 *
 * Zero-initialize the struct (calloc'd context memory is already correct).
 * Not thread-safe: call from the single capture/delivery thread that owns it.
 */
typedef struct MiniAVTimebase {
  int64_t offset_us;
  int initialized;
} MiniAVTimebase;

#define MINIAV_TIMEBASE_RECALIBRATE_THRESHOLD_US 5000000 /* 5 s */

/**
 * @brief Rebases a device-clock timestamp (already converted to microseconds)
 * onto the miniav_get_time_us() epoch. See MiniAVTimebase.
 * @param tb Per-stream calibration state (zero-initialized at stream start).
 * @param device_time_us Device/driver timestamp in microseconds (any epoch).
 * @return The timestamp on the miniav_get_time_us() timeline.
 */
uint64_t miniav_rebase_time_us(MiniAVTimebase *tb, uint64_t device_time_us);

#if defined(_WIN32)
/**
 * @brief Gets the Query Performance Counter (QPC) frequency.
 * Only available on Windows.
 * @return The QPC frequency as a LARGE_INTEGER.
 */
LARGE_INTEGER miniav_get_qpc_frequency(void);

/**
 * @brief Converts a Query Performance Counter (QPC) value to microseconds.
 * Only available on Windows.
 * @param qpc_value The QPC value to convert.
 * @param qpc_frequency The QPC frequency (obtained from miniav_get_qpc_frequency).
 * @return The time in microseconds.
 */
uint64_t miniav_qpc_to_microseconds(LARGE_INTEGER qpc_value, LARGE_INTEGER qpc_frequency);
#endif // _WIN32


#ifdef __cplusplus
}
#endif

#endif // MINIAV_TIME_H