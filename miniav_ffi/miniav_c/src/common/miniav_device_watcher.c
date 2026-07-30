// Generic polling-based device watcher.
//
// Provides a portable implementation of "subscribe for device add/remove
// notifications" by spawning a background thread that periodically calls a
// supplied enumerate function and diffs the results against the previous
// snapshot. This avoids needing a separate platform-specific notification
// implementation per backend (IMMNotificationClient, IOKit, udev, ...) while
// still giving applications timely add/remove callbacks.

#include "miniav_device_watcher.h"
#include "../../include/miniav_capture.h"
#include "../../include/miniav_types.h"
#include "miniav_logging.h"
#include "miniav_utils.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
typedef CRITICAL_SECTION miniav_dw_mutex_t;
typedef HANDLE miniav_dw_event_t;
typedef HANDLE miniav_dw_thread_t;
#define DW_MUTEX_INIT(m) InitializeCriticalSection(m)
#define DW_MUTEX_DEINIT(m) DeleteCriticalSection(m)
#define DW_MUTEX_LOCK(m) EnterCriticalSection(m)
#define DW_MUTEX_UNLOCK(m) LeaveCriticalSection(m)
#else
#include <pthread.h>
#include <time.h>
typedef pthread_mutex_t miniav_dw_mutex_t;
typedef struct {
  pthread_mutex_t mtx;
  pthread_cond_t cond;
  int signaled;
} miniav_dw_event_t;
typedef pthread_t miniav_dw_thread_t;
#define DW_MUTEX_INIT(m) pthread_mutex_init(m, NULL)
#define DW_MUTEX_DEINIT(m) pthread_mutex_destroy(m)
#define DW_MUTEX_LOCK(m) pthread_mutex_lock(m)
#define DW_MUTEX_UNLOCK(m) pthread_mutex_unlock(m)
#endif

struct MiniAVDeviceWatcher {
  MiniAVDeviceWatcherEnumerateFn enumerate;
  void *enum_user_data;
  MiniAVDeviceChangeCallback callback;
  void *callback_user_data;
  uint32_t poll_interval_ms;

  MiniAVDeviceInfo *prev_devices;
  uint32_t prev_count;
  // Track previous default device id to emit DEFAULT_CHANGED.
  char prev_default_id[MINIAV_DEVICE_ID_MAX_LEN];

  volatile int stop_requested;
  // Set by the poll thread as its very last action so dw_stop_and_join can
  // bound its wait (a platform enumerate() callback can wedge indefinitely).
  volatile int thread_exited;
  miniav_dw_mutex_t mutex; // protects prev_devices snapshot + callback ptr
  miniav_dw_event_t wakeup; // signaled to wake the poll thread early

  miniav_dw_thread_t thread;
  int thread_started;
};

// --- Cross-platform event helpers ---

static void dw_event_init(miniav_dw_event_t *ev) {
#if defined(_WIN32)
  *ev = CreateEventA(NULL, FALSE /*auto-reset*/, FALSE, NULL);
#else
  pthread_mutex_init(&ev->mtx, NULL);
  pthread_cond_init(&ev->cond, NULL);
  ev->signaled = 0;
#endif
}

static void dw_event_deinit(miniav_dw_event_t *ev) {
#if defined(_WIN32)
  if (*ev) {
    CloseHandle(*ev);
    *ev = NULL;
  }
#else
  pthread_mutex_destroy(&ev->mtx);
  pthread_cond_destroy(&ev->cond);
#endif
}

static void dw_event_signal(miniav_dw_event_t *ev) {
#if defined(_WIN32)
  if (*ev)
    SetEvent(*ev);
#else
  pthread_mutex_lock(&ev->mtx);
  ev->signaled = 1;
  pthread_cond_signal(&ev->cond);
  pthread_mutex_unlock(&ev->mtx);
#endif
}

// Wait up to timeout_ms; returns 1 if signaled, 0 if timeout.
static int dw_event_wait(miniav_dw_event_t *ev, uint32_t timeout_ms) {
#if defined(_WIN32)
  DWORD r = WaitForSingleObject(*ev, timeout_ms);
  return (r == WAIT_OBJECT_0) ? 1 : 0;
#else
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  ts.tv_sec += timeout_ms / 1000;
  ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (ts.tv_nsec >= 1000000000L) {
    ts.tv_sec += 1;
    ts.tv_nsec -= 1000000000L;
  }
  int signaled = 0;
  pthread_mutex_lock(&ev->mtx);
  while (!ev->signaled) {
    int r = pthread_cond_timedwait(&ev->cond, &ev->mtx, &ts);
    if (r != 0)
      break;
  }
  if (ev->signaled) {
    ev->signaled = 0;
    signaled = 1;
  }
  pthread_mutex_unlock(&ev->mtx);
  return signaled;
#endif
}

// --- Diff helpers ---

static int find_device_by_id(const MiniAVDeviceInfo *list, uint32_t count,
                             const char *id) {
  for (uint32_t i = 0; i < count; ++i) {
    if (strncmp(list[i].device_id, id, MINIAV_DEVICE_ID_MAX_LEN) == 0)
      return (int)i;
  }
  return -1;
}

// Compute the diff between previous and current snapshots, firing the
// supplied callback for each changed device. Caller must hold the watcher
// mutex.
static void
dw_diff_and_emit(MiniAVDeviceWatcher *watcher, const MiniAVDeviceInfo *current,
                 uint32_t current_count) {
  if (!watcher->callback)
    return;

  // Removed devices
  for (uint32_t i = 0; i < watcher->prev_count; ++i) {
    if (find_device_by_id(current, current_count,
                          watcher->prev_devices[i].device_id) < 0) {
      watcher->callback(MINIAV_DEVICE_CHANGE_REMOVED, &watcher->prev_devices[i],
                        watcher->callback_user_data);
    }
  }
  // Added devices
  for (uint32_t i = 0; i < current_count; ++i) {
    if (find_device_by_id(watcher->prev_devices, watcher->prev_count,
                          current[i].device_id) < 0) {
      watcher->callback(MINIAV_DEVICE_CHANGE_ADDED, &current[i],
                        watcher->callback_user_data);
    }
  }

  // Default-changed detection
  const char *new_default = "";
  for (uint32_t i = 0; i < current_count; ++i) {
    if (current[i].is_default) {
      new_default = current[i].device_id;
      break;
    }
  }
  if (strncmp(new_default, watcher->prev_default_id,
              MINIAV_DEVICE_ID_MAX_LEN) != 0) {
    if (new_default[0] != '\0') {
      // Find the new default device info in the current list
      for (uint32_t i = 0; i < current_count; ++i) {
        if (current[i].is_default) {
          watcher->callback(MINIAV_DEVICE_CHANGE_DEFAULT_CHANGED, &current[i],
                            watcher->callback_user_data);
          break;
        }
      }
    }
    miniav_strlcpy(watcher->prev_default_id, new_default,
                   sizeof(watcher->prev_default_id));
  }
}

// Performs a single enumerate + diff cycle. Mutex must NOT be held on entry;
// this function takes it internally.
static void dw_poll_once(MiniAVDeviceWatcher *watcher) {
  MiniAVDeviceInfo *cur = NULL;
  uint32_t cur_count = 0;
  MiniAVResultCode res =
      watcher->enumerate(&cur, &cur_count, watcher->enum_user_data);
  if (res != MINIAV_SUCCESS) {
    // Failed to enumerate this cycle; do not touch previous snapshot.
    if (cur)
      miniav_free(cur);
    return;
  }

  DW_MUTEX_LOCK(&watcher->mutex);
  dw_diff_and_emit(watcher, cur, cur_count);
  // Replace snapshot.
  if (watcher->prev_devices)
    miniav_free(watcher->prev_devices);
  watcher->prev_devices = cur;
  watcher->prev_count = cur_count;
  DW_MUTEX_UNLOCK(&watcher->mutex);
}

// --- Thread proc ---

#if defined(_WIN32)
static DWORD WINAPI dw_thread_proc(LPVOID param)
#else
static void *dw_thread_proc(void *param)
#endif
{
  MiniAVDeviceWatcher *watcher = (MiniAVDeviceWatcher *)param;

  // Initial snapshot (no diffing — just record).
  {
    MiniAVDeviceInfo *cur = NULL;
    uint32_t cur_count = 0;
    if (watcher->enumerate(&cur, &cur_count, watcher->enum_user_data) ==
        MINIAV_SUCCESS) {
      DW_MUTEX_LOCK(&watcher->mutex);
      watcher->prev_devices = cur;
      watcher->prev_count = cur_count;
      for (uint32_t i = 0; i < cur_count; ++i) {
        if (cur[i].is_default) {
          miniav_strlcpy(watcher->prev_default_id, cur[i].device_id,
                         sizeof(watcher->prev_default_id));
          break;
        }
      }
      DW_MUTEX_UNLOCK(&watcher->mutex);
    }
  }

  while (!watcher->stop_requested) {
    if (dw_event_wait(&watcher->wakeup, watcher->poll_interval_ms)) {
      // Either explicit refresh request or stop signal; check stop again.
      if (watcher->stop_requested)
        break;
    }
    dw_poll_once(watcher);
  }

  watcher->thread_exited = 1; // last action — see dw_stop_and_join
#if defined(_WIN32)
  return 0;
#else
  return NULL;
#endif
}

static void dw_start_thread(MiniAVDeviceWatcher *watcher) {
  watcher->thread_exited = 0;
#if defined(_WIN32)
  watcher->thread = CreateThread(NULL, 0, dw_thread_proc, watcher, 0, NULL);
  watcher->thread_started = (watcher->thread != NULL) ? 1 : 0;
#else
  watcher->thread_started =
      (pthread_create(&watcher->thread, NULL, dw_thread_proc, watcher) == 0)
          ? 1
          : 0;
#endif
}

// Returns 0 when the thread was joined; nonzero when it did not exit within
// the bound (wedged inside a platform enumerate() call) — in that case the
// thread is still live and still dereferences the watcher.
static int dw_stop_and_join(MiniAVDeviceWatcher *watcher) {
  if (!watcher->thread_started)
    return 0;
  watcher->stop_requested = 1;
  dw_event_signal(&watcher->wakeup);
#if defined(_WIN32)
  if (WaitForSingleObject(watcher->thread, 5000) != WAIT_OBJECT_0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "DeviceWatcher: poll thread did not exit within 5s "
               "(enumerate() wedged?).");
    return 1;
  }
  CloseHandle(watcher->thread);
  watcher->thread = NULL;
#else
  // Portable bounded join (macOS has no pthread_timedjoin_np): poll the
  // thread's own exit flag, then join — which returns immediately once set.
  {
    int waited_ms = 0;
    while (!watcher->thread_exited && waited_ms < 5000) {
      struct timespec ts = {0, 20 * 1000000L}; // 20 ms
      nanosleep(&ts, NULL);
      waited_ms += 20;
    }
    if (!watcher->thread_exited) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "DeviceWatcher: poll thread did not exit within 5s "
                 "(enumerate() wedged?).");
      return 1;
    }
    pthread_join(watcher->thread, NULL);
  }
#endif
  watcher->thread_started = 0;
  return 0;
}

static void dw_destroy(MiniAVDeviceWatcher *watcher) {
  if (!watcher)
    return;
  if (dw_stop_and_join(watcher) != 0) {
    // The poll thread is still alive and dereferences the watcher —
    // deliberately LEAK it rather than free memory a live thread uses.
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "DeviceWatcher: leaking watcher (poll thread still alive).");
    return;
  }
  if (watcher->prev_devices) {
    miniav_free(watcher->prev_devices);
    watcher->prev_devices = NULL;
  }
  dw_event_deinit(&watcher->wakeup);
  DW_MUTEX_DEINIT(&watcher->mutex);
  miniav_free(watcher);
}

// --- Public API ---

MiniAVResultCode miniav_device_watcher_set(
    MiniAVDeviceWatcher **watcher_slot,
    MiniAVDeviceWatcherEnumerateFn enumerate, void *enum_user_data,
    MiniAVDeviceChangeCallback callback, void *callback_user_data,
    uint32_t poll_interval_ms) {
  if (!watcher_slot)
    return MINIAV_ERROR_INVALID_ARG;

  // Tear down existing watcher (always).
  if (*watcher_slot) {
    dw_destroy(*watcher_slot);
    *watcher_slot = NULL;
  }

  if (!callback) {
    return MINIAV_SUCCESS; // unsubscribe
  }
  if (!enumerate) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  if (poll_interval_ms == 0)
    poll_interval_ms = 1500;

  MiniAVDeviceWatcher *w =
      (MiniAVDeviceWatcher *)miniav_calloc(1, sizeof(MiniAVDeviceWatcher));
  if (!w)
    return MINIAV_ERROR_OUT_OF_MEMORY;

  w->enumerate = enumerate;
  w->enum_user_data = enum_user_data;
  w->callback = callback;
  w->callback_user_data = callback_user_data;
  w->poll_interval_ms = poll_interval_ms;

  DW_MUTEX_INIT(&w->mutex);
  dw_event_init(&w->wakeup);

  dw_start_thread(w);
  if (!w->thread_started) {
    dw_event_deinit(&w->wakeup);
    DW_MUTEX_DEINIT(&w->mutex);
    miniav_free(w);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  *watcher_slot = w;
  return MINIAV_SUCCESS;
}

void miniav_device_watcher_trigger_refresh(MiniAVDeviceWatcher *watcher) {
  if (!watcher)
    return;
  dw_event_signal(&watcher->wakeup);
}

void miniav_device_watcher_clear(MiniAVDeviceWatcher **watcher_slot) {
  if (!watcher_slot || !*watcher_slot)
    return;
  dw_destroy(*watcher_slot);
  *watcher_slot = NULL;
}
