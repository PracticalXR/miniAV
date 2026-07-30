#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // for pthread_timedjoin_np
#endif

#include "miniav_utils.h"
#include "miniav_logging.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

void *miniav_malloc(size_t size) { return malloc(size); }

void *miniav_calloc(size_t count, size_t size) { return calloc(count, size); }

void *miniav_realloc(void *ptr, size_t size) { return realloc(ptr, size); }

void miniav_free(void *ptr) {
  if (!ptr) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "miniav_free: NULL pointer detected.");
    return;
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "miniav_free: Freeing pointer: %p", ptr);
  free(ptr);
  // NOTE: this cannot null the caller's pointer (pass-by-value) — call sites
  // must null their own copies if they can be reached again.
}

char *miniav_strdup(const char *src) {
  if (!src)
    return NULL;
  size_t len = strlen(src) + 1;
  char *dst = (char *)malloc(len);
  if (dst)
    memcpy(dst, src, len);
  return dst;
}

int miniav_stricmp(const char *a, const char *b) {
  if (!a || !b)
    return (a == b) ? 0 : (a ? 1 : -1);
  while (*a && *b) {
    int ca = tolower((unsigned char)*a);
    int cb = tolower((unsigned char)*b);
    if (ca != cb)
      return ca - cb;
    ++a;
    ++b;
  }
  return (unsigned char)*a - (unsigned char)*b;
}

size_t miniav_strlcpy(char *dst, const char *src, size_t dst_size) {
  size_t src_len = strlen(src);
  if (dst_size) {
    size_t copy_len = (src_len >= dst_size) ? dst_size - 1 : src_len;
    memcpy(dst, src, copy_len);
    dst[copy_len] = '\0';
  }
  return src_len;
}

// ---- Callback-dispatch guard ---------------------------------------------------
#ifdef _WIN32
#include <windows.h>

static SRWLOCK      g_miniav_dispatch_srw     = SRWLOCK_INIT;
static volatile int g_miniav_dispatch_enabled = 1;

int miniav_dispatch_guard_acquire_if_enabled(void) {
  AcquireSRWLockShared(&g_miniav_dispatch_srw);
  if (!g_miniav_dispatch_enabled) {
    ReleaseSRWLockShared(&g_miniav_dispatch_srw);
    return 0;
  }
  return 1;
}

void miniav_dispatch_guard_release(void) {
  ReleaseSRWLockShared(&g_miniav_dispatch_srw);
}

void miniav_dispatch_set_enabled(int enabled) {
  AcquireSRWLockExclusive(&g_miniav_dispatch_srw);
  g_miniav_dispatch_enabled = enabled;
  ReleaseSRWLockExclusive(&g_miniav_dispatch_srw);
}

#else /* !_WIN32 */
#include <pthread.h>

// pthread_rwlock mirror of the Windows SRWLOCK guard above: readers are
// in-flight callback dispatches, the writer is MiniAV_Dispose flipping the
// enabled flag. Previously these were no-op stubs, so the documented
// "block until all in-flight callbacks have drained" guarantee (relied on by
// the Dart layer during hot restart) simply did not exist on Linux/macOS.
static pthread_rwlock_t g_miniav_dispatch_rwlock = PTHREAD_RWLOCK_INITIALIZER;
static volatile int     g_miniav_dispatch_enabled = 1;

int miniav_dispatch_guard_acquire_if_enabled(void) {
  pthread_rwlock_rdlock(&g_miniav_dispatch_rwlock);
  if (!g_miniav_dispatch_enabled) {
    pthread_rwlock_unlock(&g_miniav_dispatch_rwlock);
    return 0;
  }
  return 1;
}

void miniav_dispatch_guard_release(void) {
  pthread_rwlock_unlock(&g_miniav_dispatch_rwlock);
}

void miniav_dispatch_set_enabled(int enabled) {
  pthread_rwlock_wrlock(&g_miniav_dispatch_rwlock);
  g_miniav_dispatch_enabled = enabled;
  pthread_rwlock_unlock(&g_miniav_dispatch_rwlock);
}

#if defined(__linux__) && !defined(__ANDROID__)
// glibc-only: pthread_timedjoin_np does not exist on Bionic (Android) —
// the gate must exclude Android even though it defines __linux__.
#include <time.h>

int miniav_timed_join(pthread_t thread, unsigned timeout_ms) {
  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }
  return pthread_timedjoin_np(thread, NULL, &deadline);
}
#endif /* __linux__ */

#endif /* _WIN32 */