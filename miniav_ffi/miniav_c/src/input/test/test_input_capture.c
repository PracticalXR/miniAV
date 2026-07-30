#include "../../../include/miniav.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

volatile int g_keyboard_count = 0;
volatile int g_mouse_count = 0;
volatile int g_gamepad_count = 0;
const int CAPTURE_DURATION_SECONDS = 15;

void test_log_callback(MiniAVLogLevel level, const char *message,
                       void *user_data) {
  (void)user_data;
  const char *level_str = "UNKNOWN";
  switch (level) {
  case MINIAV_LOG_LEVEL_DEBUG:
    level_str = "DEBUG";
    break;
  case MINIAV_LOG_LEVEL_INFO:
    level_str = "INFO";
    break;
  case MINIAV_LOG_LEVEL_WARN:
    level_str = "WARN";
    break;
  case MINIAV_LOG_LEVEL_ERROR:
    level_str = "ERROR";
    break;
  default:
    break;
  }
  fprintf(stderr, "[MiniAV Input Test - %s] %s\n", level_str, message);
}

void test_keyboard_callback(const MiniAVKeyboardEvent *event,
                            void *user_data) {
  (void)user_data;
  g_keyboard_count++;
  printf("Keyboard: ts=%" PRIu64 "us, vk=0x%04X, scan=0x%04X, action=%s, "
         "count=%d\n",
         event->timestamp_us, event->key_code, event->scan_code,
         event->action == MINIAV_KEY_ACTION_DOWN ? "DOWN" : "UP",
         g_keyboard_count);
}

void test_mouse_callback(const MiniAVMouseEvent *event, void *user_data) {
  (void)user_data;
  g_mouse_count++;
  const char *action_str = "UNKNOWN";
  switch (event->action) {
  case MINIAV_MOUSE_ACTION_MOVE:
    action_str = "MOVE";
    break;
  case MINIAV_MOUSE_ACTION_BUTTON_DOWN:
    action_str = "BTN_DOWN";
    break;
  case MINIAV_MOUSE_ACTION_BUTTON_UP:
    action_str = "BTN_UP";
    break;
  case MINIAV_MOUSE_ACTION_WHEEL:
    action_str = "WHEEL";
    break;
  }
  printf("Mouse: ts=%" PRIu64 "us, x=%d, y=%d, action=%s, btn=%d, "
         "wheel=%d, count=%d\n",
         event->timestamp_us, event->x, event->y, action_str, event->button,
         event->wheel_delta, g_mouse_count);
}

void test_gamepad_callback(const MiniAVGamepadEvent *event, void *user_data) {
  (void)user_data;
  g_gamepad_count++;
  printf("Gamepad[%u]: ts=%" PRIu64 "us, connected=%s, buttons=0x%04X, "
         "LX=%d LY=%d RX=%d RY=%d LT=%u RT=%u, count=%d\n",
         event->gamepad_index, event->timestamp_us,
         event->connected ? "Yes" : "No", event->buttons,
         event->left_stick_x, event->left_stick_y, event->right_stick_x,
         event->right_stick_y, event->left_trigger, event->right_trigger,
         g_gamepad_count);
}

void sleep_ms(int milliseconds) {
#ifdef _WIN32
  Sleep(milliseconds);
#else
  usleep(milliseconds * 1000);
#endif
}

int main() {
  MiniAVResultCode res;
  uint32_t major, minor, patch;

  MiniAV_GetVersion(&major, &minor, &patch);
  printf("MiniAV Version: %u.%u.%u\n", major, minor, patch);
  printf("MiniAV Version String: %s\n", MiniAV_GetVersionString());

  MiniAV_SetLogCallback(test_log_callback, NULL);
  MiniAV_SetLogLevel(MINIAV_LOG_LEVEL_DEBUG);

  // Enumerate gamepads
  MiniAVDeviceInfo *gamepads = NULL;
  uint32_t gamepad_count = 0;

  printf("\nEnumerating gamepads...\n");
  res = MiniAV_Input_EnumerateGamepads(&gamepads, &gamepad_count);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to enumerate gamepads: %s\n",
            MiniAV_GetErrorString(res));
  } else {
    printf("Found %u gamepad(s):\n", gamepad_count);
    for (uint32_t i = 0; i < gamepad_count; i++) {
      printf("  Gamepad %u: ID='%s', Name='%s'\n", i, gamepads[i].device_id,
             gamepads[i].name);
    }
    if (gamepads) {
      MiniAV_FreeDeviceList(gamepads, gamepad_count);
    }
  }

  // Create input context
  MiniAVInputContextHandle input_ctx = NULL;
  printf("\nCreating input context...\n");
  res = MiniAV_Input_CreateContext(&input_ctx);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to create input context: %s\n",
            MiniAV_GetErrorString(res));
    return 1;
  }
  printf("Input context created.\n");

  // Configure
  MiniAVInputConfig config;
  memset(&config, 0, sizeof(config));
  config.input_types = MINIAV_INPUT_TYPE_KEYBOARD | MINIAV_INPUT_TYPE_MOUSE |
                       MINIAV_INPUT_TYPE_GAMEPAD;
  config.mouse_throttle_hz = 60;
  config.gamepad_poll_hz = 60;
  config.keyboard_callback = test_keyboard_callback;
  config.mouse_callback = test_mouse_callback;
  config.gamepad_callback = test_gamepad_callback;
  config.user_data = NULL;

  printf("\nConfiguring input capture...\n");
  res = MiniAV_Input_Configure(input_ctx, &config);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to configure input: %s\n",
            MiniAV_GetErrorString(res));
    MiniAV_Input_DestroyContext(input_ctx);
    return 1;
  }
  printf("Input configured.\n");

  // Start capture
  printf("\nStarting input capture for %d seconds...\n",
         CAPTURE_DURATION_SECONDS);
  printf("Press keys, move mouse, and use gamepad to test.\n\n");

  res = MiniAV_Input_StartCapture(input_ctx);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to start input capture: %s\n",
            MiniAV_GetErrorString(res));
    MiniAV_Input_DestroyContext(input_ctx);
    return 1;
  }

  for (int i = 0; i < CAPTURE_DURATION_SECONDS; i++) {
    printf("--- %d/%d s, keyboard=%d, mouse=%d, gamepad=%d ---\n", i + 1,
           CAPTURE_DURATION_SECONDS, g_keyboard_count, g_mouse_count,
           g_gamepad_count);
    sleep_ms(1000);
  }

  // Stop capture
  printf("\nStopping input capture...\n");
  res = MiniAV_Input_StopCapture(input_ctx);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to stop input capture: %s\n",
            MiniAV_GetErrorString(res));
  }

  printf("Input capture stopped. Total: keyboard=%d, mouse=%d, gamepad=%d\n",
         g_keyboard_count, g_mouse_count, g_gamepad_count);

  // Destroy
  printf("\nDestroying input context...\n");
  res = MiniAV_Input_DestroyContext(input_ctx);
  if (res != MINIAV_SUCCESS) {
    fprintf(stderr, "Failed to destroy input context: %s\n",
            MiniAV_GetErrorString(res));
  }
  printf("Input context destroyed.\n");

  printf("\nInput test finished.\n");
  return 0;
}
