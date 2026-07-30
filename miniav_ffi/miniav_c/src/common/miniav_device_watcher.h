#ifndef MINIAV_DEVICE_WATCHER_H
#define MINIAV_DEVICE_WATCHER_H

#include "../../include/miniav_capture.h"
#include "../../include/miniav_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// Generic enumerate function used by the watcher.
// `enum_user_data` is opaque user data passed at registration.
// On success, must allocate `*devices_out` (via miniav_calloc) and set
// `*count_out`. The watcher will free the list with miniav_free when done.
typedef MiniAVResultCode (*MiniAVDeviceWatcherEnumerateFn)(
    MiniAVDeviceInfo **devices_out, uint32_t *count_out, void *enum_user_data);

typedef struct MiniAVDeviceWatcher MiniAVDeviceWatcher;

// Set or replace a polling watcher.
//
// `watcher_slot` is a pointer to a per-module static MiniAVDeviceWatcher* slot.
// If `callback` is NULL, the existing watcher (if any) is torn down and the
// slot is set to NULL. Otherwise, an existing watcher is replaced.
//
// `poll_interval_ms` must be > 0 (recommended: 1000-2000 ms).
//
// Thread-safe with respect to repeated set calls.
MiniAVResultCode miniav_device_watcher_set(
    MiniAVDeviceWatcher **watcher_slot,
    MiniAVDeviceWatcherEnumerateFn enumerate, void *enum_user_data,
    MiniAVDeviceChangeCallback callback, void *callback_user_data,
    uint32_t poll_interval_ms);

// Manually trigger an enumeration pass and emit add/remove events for any
// detected changes. Useful when an out-of-band signal (e.g. WM_DEVICECHANGE,
// IMMNotificationClient) suggests the device list may have changed.
//
// Safe to call from any thread; will be serialized with the watcher's own
// poll thread.
void miniav_device_watcher_trigger_refresh(MiniAVDeviceWatcher *watcher);

// Force-stop and free any watcher behind the slot. Safe to call multiple
// times. Used at shutdown.
void miniav_device_watcher_clear(MiniAVDeviceWatcher **watcher_slot);

#ifdef __cplusplus
}
#endif

#endif // MINIAV_DEVICE_WATCHER_H
