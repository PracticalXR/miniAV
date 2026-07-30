#ifndef MINIAV_UTILS_H
#define MINIAV_UTILS_H

#include <stddef.h>
#include <stdint.h>

#if defined(__linux__) && !defined(__ANDROID__) // glibc-only (pthread_timedjoin_np); Bionic lacks it
#include <pthread.h> // for miniav_timed_join (kept OUTSIDE the extern "C")
#endif

#ifdef __cplusplus
extern "C" {
#endif

void* miniav_malloc(size_t size);
void* miniav_calloc(size_t count, size_t size);
void* miniav_realloc(void* ptr, size_t size);
void  miniav_free(void* ptr);

char* miniav_strdup(const char* src);
int   miniav_stricmp(const char* a, const char* b);

size_t miniav_strlcpy(char* dst, const char* src, size_t dst_size);

#ifndef MINIAV_UNUSED
#define MINIAV_UNUSED(x) (void)(x)
#endif

// ---- Callback-dispatch guard ---------------------------------------------------
// Use MINIAV_SAFE_DISPATCH() instead of calling a Dart/user callback directly.
// This allows MiniAV_Dispose() to atomically quiesce all in-flight callback
// invocations before the caller tears down its NativeCallable handles (e.g.
// during Flutter hot restart).
//
// miniav_dispatch_guard_acquire_if_enabled():
//   Acquires a shared read lock if callbacks are currently enabled.
//   Returns 1 (lock held — caller MUST call miniav_dispatch_guard_release()).
//   Returns 0 (callbacks disabled — caller must NOT call release).
//
// miniav_dispatch_guard_release(): releases the shared read lock.
//
// miniav_dispatch_set_enabled(): called by MiniAV_Dispose (0) and
//   MiniAV_EnableCallbacks (1).  Acquires an exclusive write lock — blocks
//   until every in-flight callback finishes, then updates the flag.
int  miniav_dispatch_guard_acquire_if_enabled(void);
void miniav_dispatch_guard_release(void);
void miniav_dispatch_set_enabled(int enabled); /* 0 = off, 1 = on */

#define MINIAV_SAFE_DISPATCH(call_expr)                     \
  do {                                                      \
    if (miniav_dispatch_guard_acquire_if_enabled()) {       \
      (call_expr);                                          \
      miniav_dispatch_guard_release();                      \
    }                                                       \
  } while (0)

#if defined(__linux__) && !defined(__ANDROID__)
// Bounded pthread_join (pthread_timedjoin_np): returns 0 when joined,
// nonzero when the thread did not exit within timeout_ms. On timeout the
// thread is left JOINABLE so a later Stop/Destroy can retry — callers must
// NOT free state the thread references until a join succeeds.
int miniav_timed_join(pthread_t thread, unsigned timeout_ms);
#endif

#ifdef __cplusplus
}
#endif

#endif // MINIAV_UTILS_H