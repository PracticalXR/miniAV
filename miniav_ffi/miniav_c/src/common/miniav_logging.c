#include "miniav_logging.h"

#include <stdarg.h>
#include <stdio.h>  // For fprintf, stderr, vsnprintf
#include <stdlib.h> // Not strictly needed if not allocating for callback
#include <string.h> // Not strictly needed if not allocating for callback

static MiniAVLogCallback g_log_callback = NULL;
static void *g_log_user_data = NULL;
static MiniAVLogLevel g_log_level = MINIAV_LOG_LEVEL_INFO; // Default log level

// Helper to get string representation of log level
static const char* get_log_level_string(MiniAVLogLevel level) {
    switch (level) {
        case MINIAV_LOG_LEVEL_TRACE: return "TRACE";
        case MINIAV_LOG_LEVEL_DEBUG: return "DEBUG";
        case MINIAV_LOG_LEVEL_INFO:  return "INFO";
        case MINIAV_LOG_LEVEL_WARN:  return "WARN";
        case MINIAV_LOG_LEVEL_ERROR: return "ERROR";
        case MINIAV_LOG_LEVEL_NONE:  return "NONE"; // No logging
        default: return "UNKNOWN";
    }
}

void miniav_log(MiniAVLogLevel level, const char *fmt, ...) {
  // Check if the message's level is sufficient to be logged
  if (level < g_log_level) { // Adjust this condition based on your enum's ordering and desired behavior
    return;                  // Example: if higher enum value means higher severity
  }


  char temp_buffer[1024]; // Temporary buffer for formatting
  va_list args;

  va_start(args, fmt);
  vsnprintf(temp_buffer, sizeof(temp_buffer), fmt, args);
  va_end(args);

  temp_buffer[sizeof(temp_buffer) - 1] = '\0'; // Ensure null termination

  // Snapshot the callback pair so a concurrent re-registration can't tear the
  // (callback, user_data) association mid-call.
  MiniAVLogCallback cb = g_log_callback;
  void *cb_user_data = g_log_user_data;
  if (cb) {
    // An embedder-installed callback is the single delivery path: GUI hosts
    // (e.g. Flutter apps) have no visible stderr, which previously made every
    // native log line disappear in the field.
    //
    // OWNERSHIP: the message is a heap copy the RECEIVER frees with
    // MiniAV_Free once consumed. The callback may be dispatched
    // asynchronously onto another thread (the Dart FFI shim uses
    // NativeCallable.listener, which runs the handler on the event loop
    // after this call returns), so a stack/static buffer would be dangling
    // by the time it is read.
    size_t msg_len = strlen(temp_buffer) + 1;
    char *heap_msg = (char *)malloc(msg_len);
    if (heap_msg) {
      memcpy(heap_msg, temp_buffer, msg_len);
      cb(level, heap_msg, cb_user_data);
      return;
    }
    // OOM: fall through to stderr so the message isn't lost entirely.
  }
  fprintf(stderr, "[MiniAV C - %s]: %s\n", get_log_level_string(level), temp_buffer);
  fflush(stderr); // Ensure it's flushed
}

void miniav_set_log_level(MiniAVLogLevel level) {
  g_log_level = level;
}

void miniav_set_log_callback(MiniAVLogCallback callback, void *user_data) {
  // Best-effort ordering for the unsynchronized snapshot in miniav_log:
  // publish user_data before the callback that consumes it. This is NOT a
  // formal happens-before (no fences) — register the callback before starting
  // any capture, and treat re-registration during active capture as a benign
  // race that may pair one message with the previous user_data.
  g_log_user_data = user_data;
  g_log_callback = callback;
}
