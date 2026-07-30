// Linux input capture backend — keyboard, mouse and gamepad captured directly
// from the raw evdev protocol on /dev/input/event* with NO external
// dependencies (no libinput, no libudev, no libevdev). We read
// `struct input_event` records straight out of <linux/input.h> and translate
// them into MiniAV events.
//
// PERMISSIONS: /dev/input/event* is normally readable only by root and members
// of the 'input' group (udev rule 50-udev-default). If the process is not in
// that group we get EACCES opening the device nodes. We log a clear message
// and continue with whatever devices DID open — an unprivileged process can
// still capture nothing rather than crashing. To grant access, add the user to
// the 'input' group (`sudo usermod -aG input $USER`) and re-login, or run as
// root.
//
// THREADING: a single capture pthread poll()s every relevant device fd plus a
// stop eventfd. Stop is signalled by writing the eventfd (self-wake) — no
// thread cancellation. Gamepads are fully EVENT-DRIVEN (evdev delivers
// EV_ABS/EV_KEY, accumulated and flushed on EV_SYN), so unlike the Windows
// XInput backend there is NO gamepad poll cadence — config.gamepad_poll_hz is
// accepted for API symmetry but not used to rate-limit pad events. The poll()
// timeout only bounds stop responsiveness and the low-frequency hot-plug
// rescan (paced with an ABSOLUTE CLOCK_MONOTONIC deadline).

#include "input_context_linux_evdev.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

// --- Constants ---

#define MINIAV_EVDEV_DIR "/dev/input"
#define MINIAV_EVDEV_MAX_DEVICES 64
#define MINIAV_EVDEV_MAX_GAMEPADS 8

// Bit-array helpers for the EVIOCGBIT / EVIOCGKEY results.
#define MINIAV_BITS_PER_LONG (8 * (int)sizeof(long))
#define MINIAV_NBITS(x) ((((x)-1) / MINIAV_BITS_PER_LONG) + 1)
#define MINIAV_TEST_BIT(bit, array)                                            \
  (((array)[(bit) / MINIAV_BITS_PER_LONG] >>                                   \
    ((bit) % MINIAV_BITS_PER_LONG)) &                                          \
   1UL)

// --- Per-device tracking (owned by the capture thread) ---

typedef enum {
  MINIAV_EVDEV_ROLE_NONE = 0,
  MINIAV_EVDEV_ROLE_KEYBOARD = 0x01,
  MINIAV_EVDEV_ROLE_MOUSE = 0x02,
  MINIAV_EVDEV_ROLE_GAMEPAD = 0x04,
} MiniAVEvdevRole;

typedef struct EvdevDevice {
  int fd;
  char path[64];      // "/dev/input/eventN"
  uint32_t roles;     // bitmask of MiniAVEvdevRole
  int gamepad_index;  // slot in gamepad_state[], or -1

  // ABS axis calibration (min/max) for the six stick/trigger axes we map, so
  // we can normalise them to the XInput-style ranges MiniAVGamepadEvent uses.
  struct input_absinfo abs_x, abs_y;    // left stick
  struct input_absinfo abs_rx, abs_ry;  // right stick
  struct input_absinfo abs_z, abs_rz;   // triggers
} EvdevDevice;

// Accumulated gamepad state, flushed to the callback on each EV_SYN report.
typedef struct EvdevGamepadState {
  bool in_use;
  bool dirty;
  uint16_t buttons;
  int16_t left_stick_x, left_stick_y;
  int16_t right_stick_x, right_stick_y;
  uint8_t left_trigger, right_trigger;
} EvdevGamepadState;

// --- Platform context ---

typedef struct InputPlatformLinux {
  // Capture thread
  pthread_t thread;
  bool thread_started;
  int stop_efd; // eventfd; write to wake+stop the capture thread

  // Configuration snapshot (set in configure, read by the thread)
  uint32_t input_types;
  uint32_t mouse_throttle_hz;
  uint32_t gamepad_poll_hz;
  MiniAVKeyboardCallback keyboard_cb;
  MiniAVMouseCallback mouse_cb;
  MiniAVGamepadCallback gamepad_cb;
  void *user_data;

  // Open devices (thread-owned once the thread is running)
  EvdevDevice devices[MINIAV_EVDEV_MAX_DEVICES];
  int device_count;

  // Gamepad slots
  EvdevGamepadState gamepad_state[MINIAV_EVDEV_MAX_GAMEPADS];

  // Mouse throttle (absolute-time, drop-oldest) state
  uint64_t mouse_throttle_interval_us; // 0 = no throttle
  uint64_t next_mouse_emit_us;         // earliest µs a MOVE may be emitted
} InputPlatformLinux;

// ============================================================================
// Device probing helpers
// ============================================================================

// Classify an open device fd into a MiniAVEvdevRole bitmask by inspecting its
// declared capability bits. A single physical device can serve several roles
// (e.g. many gaming mice expose keyboard keys too), so this is a bitmask.
static uint32_t evdev_probe_roles(int fd) {
  unsigned long ev_bits[MINIAV_NBITS(EV_MAX)];
  unsigned long key_bits[MINIAV_NBITS(KEY_MAX)];
  unsigned long rel_bits[MINIAV_NBITS(REL_MAX)];
  unsigned long abs_bits[MINIAV_NBITS(ABS_MAX)];

  memset(ev_bits, 0, sizeof(ev_bits));
  memset(key_bits, 0, sizeof(key_bits));
  memset(rel_bits, 0, sizeof(rel_bits));
  memset(abs_bits, 0, sizeof(abs_bits));

  if (ioctl(fd, EVIOCGBIT(0, sizeof(ev_bits)), ev_bits) < 0) {
    return MINIAV_EVDEV_ROLE_NONE;
  }

  uint32_t roles = MINIAV_EVDEV_ROLE_NONE;

  bool has_key = MINIAV_TEST_BIT(EV_KEY, ev_bits);
  bool has_rel = MINIAV_TEST_BIT(EV_REL, ev_bits);
  bool has_abs = MINIAV_TEST_BIT(EV_ABS, ev_bits);

  if (has_key) {
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits);
  }
  if (has_rel) {
    ioctl(fd, EVIOCGBIT(EV_REL, sizeof(rel_bits)), rel_bits);
  }
  if (has_abs) {
    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits);
  }

  // Gamepad: EV_ABS axes plus a gamepad-style button. BTN_GAMEPAD is an alias
  // for BTN_SOUTH; joysticks use BTN_JOYSTICK/BTN_TRIGGER.
  if (has_abs && has_key) {
    if (MINIAV_TEST_BIT(BTN_GAMEPAD, key_bits) ||
        MINIAV_TEST_BIT(BTN_SOUTH, key_bits) ||
        MINIAV_TEST_BIT(BTN_JOYSTICK, key_bits) ||
        MINIAV_TEST_BIT(BTN_TRIGGER, key_bits)) {
      roles |= MINIAV_EVDEV_ROLE_GAMEPAD;
    }
  }

  // Mouse: relative X/Y motion plus a mouse button.
  if (has_rel && has_key && MINIAV_TEST_BIT(REL_X, rel_bits) &&
      MINIAV_TEST_BIT(REL_Y, rel_bits) &&
      MINIAV_TEST_BIT(BTN_LEFT, key_bits)) {
    roles |= MINIAV_EVDEV_ROLE_MOUSE;
  }

  // Keyboard: has ordinary alphabetic keys (KEY_A) but is not primarily a
  // gamepad/mouse. Checking a spread of common keys avoids tagging devices
  // that merely expose a few BTN_* keys (power buttons, lids).
  if (has_key && !(roles & MINIAV_EVDEV_ROLE_GAMEPAD)) {
    if (MINIAV_TEST_BIT(KEY_A, key_bits) &&
        MINIAV_TEST_BIT(KEY_Z, key_bits) &&
        MINIAV_TEST_BIT(KEY_SPACE, key_bits)) {
      roles |= MINIAV_EVDEV_ROLE_KEYBOARD;
    }
  }

  return roles;
}

// Read a device's human-readable name via EVIOCGNAME. Always NUL-terminates.
static void evdev_read_name(int fd, char *out, size_t out_len) {
  if (out_len == 0) {
    return;
  }
  out[0] = '\0';
  if (ioctl(fd, EVIOCGNAME(out_len - 1), out) < 0) {
    miniav_strlcpy(out, "Unknown evdev device", out_len);
  }
  out[out_len - 1] = '\0';
}

// Cache the ABS calibration for the axes we translate to gamepad sticks/
// triggers. Failures leave the absinfo zeroed (range collapses -> centre).
static void evdev_cache_abs(EvdevDevice *dev) {
  ioctl(dev->fd, EVIOCGABS(ABS_X), &dev->abs_x);
  ioctl(dev->fd, EVIOCGABS(ABS_Y), &dev->abs_y);
  ioctl(dev->fd, EVIOCGABS(ABS_RX), &dev->abs_rx);
  ioctl(dev->fd, EVIOCGABS(ABS_RY), &dev->abs_ry);
  ioctl(dev->fd, EVIOCGABS(ABS_Z), &dev->abs_z);
  ioctl(dev->fd, EVIOCGABS(ABS_RZ), &dev->abs_rz);
}

// Normalise a raw ABS stick value into the signed 16-bit XInput-style range
// [-32768, 32767] using the axis min/max. Y axes are inverted so "up" is
// positive, matching the XInput convention MiniAVGamepadEvent mirrors.
static int16_t evdev_norm_stick(const struct input_absinfo *info, int value,
                                bool invert) {
  int range = info->maximum - info->minimum;
  if (range <= 0) {
    return 0;
  }
  // Map to 0..65535 then shift to -32768..32767. int64_t intermediate: on
  // LP32 (i686/armhf) `long` is 32-bit and (value-min)*65535 overflows for a
  // 16-bit axis range (65535*65535 > INT32_MAX).
  int64_t scaled = (int64_t)(value - info->minimum) * 65535 / range;
  int64_t centred = scaled - 32768;
  if (invert) {
    centred = -centred - 1;
  }
  if (centred > 32767) {
    centred = 32767;
  }
  if (centred < -32768) {
    centred = -32768;
  }
  return (int16_t)centred;
}

// Normalise a raw ABS trigger value into the unsigned 8-bit range [0, 255].
static uint8_t evdev_norm_trigger(const struct input_absinfo *info, int value) {
  int range = info->maximum - info->minimum;
  if (range <= 0) {
    return 0;
  }
  int64_t scaled = (int64_t)(value - info->minimum) * 255 / range;
  if (scaled > 255) {
    scaled = 255;
  }
  if (scaled < 0) {
    scaled = 0;
  }
  return (uint8_t)scaled;
}

// ============================================================================
// Device open / scan
// ============================================================================

// Returns true if `path` is already present in plat->devices.
static bool evdev_already_open(const InputPlatformLinux *plat,
                               const char *path) {
  for (int i = 0; i < plat->device_count; ++i) {
    if (strcmp(plat->devices[i].path, path) == 0) {
      return true;
    }
  }
  return false;
}

// Allocate the next free gamepad slot, or -1 if all are taken.
static int evdev_alloc_gamepad_slot(InputPlatformLinux *plat) {
  for (int i = 0; i < MINIAV_EVDEV_MAX_GAMEPADS; ++i) {
    if (!plat->gamepad_state[i].in_use) {
      return i;
    }
  }
  return -1;
}

// Open a single /dev/input/eventN, classify it, and (if it matches a requested
// input type) add it to plat->devices. Emits a "connected" gamepad event when a
// new pad is registered. Returns true if a device was added.
static bool evdev_try_open(InputPlatformLinux *plat, const char *path) {
  if (plat->device_count >= MINIAV_EVDEV_MAX_DEVICES) {
    return false;
  }
  if (evdev_already_open(plat, path)) {
    return false;
  }

  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    if (errno == EACCES) {
      // Permission problem — surface it once per device path, then move on.
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "evdev: permission denied opening %s (add the user to the "
                 "'input' group or run as root). Continuing.",
                 path);
    }
    return false;
  }

  uint32_t roles = evdev_probe_roles(fd);

  // Filter roles down to what the caller asked to capture.
  uint32_t wanted = 0;
  if (plat->input_types & MINIAV_INPUT_TYPE_KEYBOARD) {
    wanted |= MINIAV_EVDEV_ROLE_KEYBOARD;
  }
  if (plat->input_types & MINIAV_INPUT_TYPE_MOUSE) {
    wanted |= MINIAV_EVDEV_ROLE_MOUSE;
  }
  if (plat->input_types & MINIAV_INPUT_TYPE_GAMEPAD) {
    wanted |= MINIAV_EVDEV_ROLE_GAMEPAD;
  }
  roles &= wanted;

  if (roles == MINIAV_EVDEV_ROLE_NONE) {
    close(fd);
    return false;
  }

  EvdevDevice *dev = &plat->devices[plat->device_count];
  memset(dev, 0, sizeof(*dev));
  dev->fd = fd;
  dev->roles = roles;
  dev->gamepad_index = -1;
  miniav_strlcpy(dev->path, path, sizeof(dev->path));

  if (roles & MINIAV_EVDEV_ROLE_GAMEPAD) {
    evdev_cache_abs(dev);
    int slot = evdev_alloc_gamepad_slot(plat);
    if (slot >= 0) {
      dev->gamepad_index = slot;
      memset(&plat->gamepad_state[slot], 0, sizeof(plat->gamepad_state[slot]));
      plat->gamepad_state[slot].in_use = true;

      // Announce the connection.
      if (plat->gamepad_cb) {
        MiniAVGamepadEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.timestamp_us = miniav_get_time_us();
        ev.gamepad_index = (uint32_t)slot;
        ev.connected = true;
        MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
      }
    }
  }

  char name[MINIAV_DEVICE_NAME_MAX_LEN];
  evdev_read_name(fd, name, sizeof(name));
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "evdev: opened %s ('%s') roles=0x%x%s", path, name, roles,
             (dev->gamepad_index >= 0) ? " [gamepad]" : "");

  plat->device_count++;
  return true;
}

// Close a device by array index, emitting a gamepad "disconnected" event if it
// held a gamepad slot, and compact the array.
static void evdev_close_device(InputPlatformLinux *plat, int index) {
  if (index < 0 || index >= plat->device_count) {
    return;
  }
  EvdevDevice *dev = &plat->devices[index];

  if (dev->gamepad_index >= 0 &&
      dev->gamepad_index < MINIAV_EVDEV_MAX_GAMEPADS) {
    int slot = dev->gamepad_index;
    if (plat->gamepad_cb) {
      MiniAVGamepadEvent ev;
      memset(&ev, 0, sizeof(ev));
      ev.timestamp_us = miniav_get_time_us();
      ev.gamepad_index = (uint32_t)slot;
      ev.connected = false;
      MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
    }
    memset(&plat->gamepad_state[slot], 0, sizeof(plat->gamepad_state[slot]));
  }

  if (dev->fd >= 0) {
    close(dev->fd);
  }
  miniav_log(MINIAV_LOG_LEVEL_INFO, "evdev: closed %s", dev->path);

  // Compact: move the last entry into this slot.
  int last = plat->device_count - 1;
  if (index != last) {
    plat->devices[index] = plat->devices[last];
  }
  memset(&plat->devices[last], 0, sizeof(plat->devices[last]));
  plat->device_count--;
}

// Scan /dev/input for event* nodes and open any that are newly present and
// match a requested input type. Used both at startup and, at low frequency,
// for hot-plug detection.
static void evdev_scan_devices(InputPlatformLinux *plat) {
  DIR *dir = opendir(MINIAV_EVDEV_DIR);
  if (!dir) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "evdev: cannot open %s: %s",
               MINIAV_EVDEV_DIR, strerror(errno));
    return;
  }

  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL) {
    if (strncmp(ent->d_name, "event", 5) != 0) {
      continue;
    }
    char path[64];
    snprintf(path, sizeof(path), "%s/%s", MINIAV_EVDEV_DIR, ent->d_name);
    evdev_try_open(plat, path);
  }
  closedir(dir);
}

// Poll every open device fd with a zero-length read to detect removal
// (read/ioctl returns ENODEV once the node is gone). Closes any that vanished.
static void evdev_prune_dead_devices(InputPlatformLinux *plat) {
  for (int i = 0; i < plat->device_count;) {
    unsigned long ev_bits[MINIAV_NBITS(EV_MAX)];
    if (ioctl(plat->devices[i].fd, EVIOCGBIT(0, sizeof(ev_bits)), ev_bits) <
        0) {
      if (errno == ENODEV || errno == EBADF) {
        evdev_close_device(plat, i);
        continue; // do not advance — a compacted entry now sits at i
      }
    }
    ++i;
  }
}

// ============================================================================
// Event translation + dispatch
// ============================================================================

static void evdev_dispatch_key(InputPlatformLinux *plat,
                               const struct input_event *ie, uint64_t ts) {
  if (!plat->keyboard_cb) {
    return;
  }
  // value: 0 = up, 1 = down, 2 = autorepeat. Treat autorepeat as DOWN.
  MiniAVKeyboardEvent ev;
  memset(&ev, 0, sizeof(ev));
  ev.timestamp_us = ts;
  ev.key_code = ie->code;  // raw evdev KEY_* code
  ev.scan_code = ie->code; // evdev has no separate scancode here; mirror it
  ev.action = (ie->value == 0) ? MINIAV_KEY_ACTION_UP : MINIAV_KEY_ACTION_DOWN;
  MINIAV_SAFE_DISPATCH(plat->keyboard_cb(&ev, plat->user_data));
}

// Handle an EV_KEY event coming from a mouse device (button press/release).
static void evdev_dispatch_mouse_button(InputPlatformLinux *plat,
                                        const struct input_event *ie,
                                        uint64_t ts) {
  if (!plat->mouse_cb) {
    return;
  }
  MiniAVMouseButton button;
  switch (ie->code) {
  case BTN_LEFT:
    button = MINIAV_MOUSE_BUTTON_LEFT;
    break;
  case BTN_RIGHT:
    button = MINIAV_MOUSE_BUTTON_RIGHT;
    break;
  case BTN_MIDDLE:
    button = MINIAV_MOUSE_BUTTON_MIDDLE;
    break;
  case BTN_SIDE:
    button = MINIAV_MOUSE_BUTTON_X1;
    break;
  case BTN_EXTRA:
    button = MINIAV_MOUSE_BUTTON_X2;
    break;
  default:
    return; // ignore other mouse buttons (BTN_FORWARD/BACK/TASK, etc.)
  }

  MiniAVMouseEvent ev;
  memset(&ev, 0, sizeof(ev));
  ev.timestamp_us = ts;
  ev.button = button;
  ev.action = (ie->value == 0) ? MINIAV_MOUSE_ACTION_BUTTON_UP
                               : MINIAV_MOUSE_ACTION_BUTTON_DOWN;
  MINIAV_SAFE_DISPATCH(plat->mouse_cb(&ev, plat->user_data));
}

// Per-report mouse accumulator. evdev delivers each axis as its own EV_REL
// event (REL_X, then REL_Y, ...) terminated by EV_SYN, so a diagonal move is
// several events. We accumulate them and emit ONE combined MOVE (and one
// WHEEL) at EV_SYN — otherwise the throttle gate, applied per event, would
// drop REL_Y on every report that also moved REL_X (the axes share a
// microsecond-identical timestamp), and consumers would see single-axis
// moves instead of a coalesced dx/dy.
typedef struct {
  bool has_move;
  bool has_wheel;
  int32_t dx, dy;
  int32_t wheel;   // REL_WHEEL  -> MiniAVMouseEvent.wheel_delta   (vertical)
  int32_t hwheel;  // REL_HWHEEL -> MiniAVMouseEvent.wheel_delta_x (horizontal)
} EvdevMouseAccum;

// Accumulate one EV_REL event into the per-report accumulator.
static void evdev_accum_mouse_rel(EvdevMouseAccum *acc,
                                  const struct input_event *ie) {
  switch (ie->code) {
  case REL_X:
    acc->has_move = true;
    acc->dx += ie->value;
    break;
  case REL_Y:
    acc->has_move = true;
    acc->dy += ie->value;
    break;
  case REL_WHEEL:
    acc->has_wheel = true;
    acc->wheel += ie->value;
    break;
  case REL_HWHEEL:
    // Horizontal wheel: kept SEPARATE so it reports as wheel_delta_x. evdev's
    // sign convention (+ = right) matches MiniAVMouseEvent.wheel_delta_x.
    acc->has_wheel = true;
    acc->hwheel += ie->value;
    break;
  default:
    break;
  }
}

// Flush the accumulated mouse report at EV_SYN: one coalesced MOVE (throttled
// once) and one WHEEL (never throttled). Clears the accumulator.
static void evdev_flush_mouse(InputPlatformLinux *plat, EvdevMouseAccum *acc,
                              uint64_t ts) {
  if (plat->mouse_cb) {
    if (acc->has_move) {
      bool emit = true;
      if (plat->mouse_throttle_interval_us > 0) {
        // Absolute-time drop-oldest gate applied ONCE to the whole move.
        if (ts < plat->next_mouse_emit_us) {
          emit = false;
        } else {
          plat->next_mouse_emit_us = ts + plat->mouse_throttle_interval_us;
        }
      }
      if (emit) {
        MiniAVMouseEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.timestamp_us = ts;
        ev.action = MINIAV_MOUSE_ACTION_MOVE;
        ev.delta_x = acc->dx;
        ev.delta_y = acc->dy;
        // evdev mice report RELATIVE motion only; there is no absolute x/y to
        // report, so is_absolute stays false and x/y are left unset (0).
        ev.is_absolute = false;
        MINIAV_SAFE_DISPATCH(plat->mouse_cb(&ev, plat->user_data));
      }
    }
    if (acc->has_wheel) {
      // One WHEEL event carries both axes: wheel_delta (vertical, REL_WHEEL)
      // and wheel_delta_x (horizontal, REL_HWHEEL). Either may be zero.
      MiniAVMouseEvent ev;
      memset(&ev, 0, sizeof(ev));
      ev.timestamp_us = ts;
      ev.action = MINIAV_MOUSE_ACTION_WHEEL;
      ev.wheel_delta = acc->wheel;
      ev.wheel_delta_x = acc->hwheel;
      MINIAV_SAFE_DISPATCH(plat->mouse_cb(&ev, plat->user_data));
    }
  }
  memset(acc, 0, sizeof(*acc));
}

// Accumulate an EV_KEY (gamepad button) into the pad's button bitmask. The
// evdev BTN_* codes are not contiguous, so we map the common gamepad buttons
// onto sequential bits. This bitmask layout is MiniAV-defined (not XInput's).
static void evdev_accum_gamepad_button(EvdevGamepadState *st, uint16_t code,
                                       int value) {
  int bit = -1;
  switch (code) {
  case BTN_SOUTH:   bit = 0;  break; // A / Cross
  case BTN_EAST:    bit = 1;  break; // B / Circle
  case BTN_WEST:    bit = 2;  break; // X / Square  (BTN_NORTH swapped on some)
  case BTN_NORTH:   bit = 3;  break; // Y / Triangle
  case BTN_TL:      bit = 4;  break; // Left shoulder
  case BTN_TR:      bit = 5;  break; // Right shoulder
  case BTN_TL2:     bit = 6;  break; // Left trigger button (digital)
  case BTN_TR2:     bit = 7;  break; // Right trigger button (digital)
  case BTN_SELECT:  bit = 8;  break; // Back / Share
  case BTN_START:   bit = 9;  break; // Start / Options
  case BTN_MODE:    bit = 10; break; // Guide / Home
  case BTN_THUMBL:  bit = 11; break; // Left stick click
  case BTN_THUMBR:  bit = 12; break; // Right stick click
  case BTN_DPAD_UP:    bit = 13; break;
  case BTN_DPAD_DOWN:  bit = 14; break;
  case BTN_DPAD_LEFT:  bit = 15; break;
  // BTN_DPAD_RIGHT would need a 17th bit; buttons is uint16_t so it is dropped.
  default:
    return;
  }
  if (bit < 0) {
    return;
  }
  uint16_t mask = (uint16_t)(1u << bit);
  if (value) {
    st->buttons |= mask;
  } else {
    st->buttons = (uint16_t)(st->buttons & ~mask);
  }
  st->dirty = true;
}

// Accumulate an EV_ABS (gamepad axis / D-pad hat) into the pad state.
static void evdev_accum_gamepad_abs(EvdevDevice *dev, EvdevGamepadState *st,
                                    uint16_t code, int value) {
  switch (code) {
  case ABS_X:
    st->left_stick_x = evdev_norm_stick(&dev->abs_x, value, false);
    break;
  case ABS_Y:
    st->left_stick_y = evdev_norm_stick(&dev->abs_y, value, true);
    break;
  case ABS_RX:
    st->right_stick_x = evdev_norm_stick(&dev->abs_rx, value, false);
    break;
  case ABS_RY:
    st->right_stick_y = evdev_norm_stick(&dev->abs_ry, value, true);
    break;
  case ABS_Z:
    st->left_trigger = evdev_norm_trigger(&dev->abs_z, value);
    break;
  case ABS_RZ:
    st->right_trigger = evdev_norm_trigger(&dev->abs_rz, value);
    break;
  case ABS_HAT0X:
    // D-pad reported as a hat: -1 left, +1 right, 0 centre. Shares bit 15 with
    // BTN_DPAD_LEFT (a device reports the D-pad as buttons OR as this hat, not
    // both). Right has no free bit in the uint16_t mask, so it is dropped.
    st->buttons = (uint16_t)(st->buttons & ~(1u << 15));
    if (value < 0) {
      st->buttons |= (uint16_t)(1u << 15); // left
    }
    break;
  case ABS_HAT0Y:
    st->buttons = (uint16_t)(st->buttons & ~((1u << 13) | (1u << 14)));
    if (value < 0) {
      st->buttons |= (uint16_t)(1u << 13); // up
    } else if (value > 0) {
      st->buttons |= (uint16_t)(1u << 14); // down
    }
    break;
  default:
    return;
  }
  st->dirty = true;
}

// Flush a dirty gamepad slot to the callback (called on EV_SYN).
static void evdev_flush_gamepad(InputPlatformLinux *plat, int slot,
                                uint64_t ts) {
  if (slot < 0 || slot >= MINIAV_EVDEV_MAX_GAMEPADS) {
    return;
  }
  EvdevGamepadState *st = &plat->gamepad_state[slot];
  if (!st->in_use || !st->dirty || !plat->gamepad_cb) {
    st->dirty = false;
    return;
  }
  MiniAVGamepadEvent ev;
  memset(&ev, 0, sizeof(ev));
  ev.timestamp_us = ts;
  ev.gamepad_index = (uint32_t)slot;
  ev.connected = true;
  ev.buttons = st->buttons;
  ev.left_stick_x = st->left_stick_x;
  ev.left_stick_y = st->left_stick_y;
  ev.right_stick_x = st->right_stick_x;
  ev.right_stick_y = st->right_stick_y;
  ev.left_trigger = st->left_trigger;
  ev.right_trigger = st->right_trigger;
  MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
  st->dirty = false;
}

// Drain all pending records from one device fd and translate/dispatch them.
static void evdev_service_device(InputPlatformLinux *plat, EvdevDevice *dev) {
  struct input_event events[64];
  EvdevMouseAccum mouse_acc;
  memset(&mouse_acc, 0, sizeof(mouse_acc));
  for (;;) {
    ssize_t n = read(dev->fd, events, sizeof(events));
    if (n < 0) {
      // EAGAIN/EWOULDBLOCK: no more data right now. ENODEV: pruned next pass.
      break;
    }
    if (n == 0) {
      break;
    }
    int count = (int)(n / (ssize_t)sizeof(struct input_event));
    for (int i = 0; i < count; ++i) {
      const struct input_event *ie = &events[i];
      // Always stamp with the shared MiniAV clock rather than ie->time (which
      // is CLOCK_REALTIME/MONOTONIC per the device's clockid and does not
      // share the miniav_get_time_us() epoch).
      uint64_t ts = miniav_get_time_us();

      switch (ie->type) {
      case EV_KEY:
        if ((dev->roles & MINIAV_EVDEV_ROLE_GAMEPAD) &&
            dev->gamepad_index >= 0) {
          evdev_accum_gamepad_button(&plat->gamepad_state[dev->gamepad_index],
                                     ie->code, ie->value);
        }
        if (dev->roles & MINIAV_EVDEV_ROLE_MOUSE &&
            ie->code >= BTN_MOUSE && ie->code <= BTN_TASK) {
          evdev_dispatch_mouse_button(plat, ie, ts);
        } else if (dev->roles & MINIAV_EVDEV_ROLE_KEYBOARD &&
                   ie->code < BTN_MISC) {
          // Ordinary keyboard keys live below the BTN_* range.
          evdev_dispatch_key(plat, ie, ts);
        }
        break;

      case EV_REL:
        if (dev->roles & MINIAV_EVDEV_ROLE_MOUSE) {
          evdev_accum_mouse_rel(&mouse_acc, ie);
        }
        break;

      case EV_ABS:
        if ((dev->roles & MINIAV_EVDEV_ROLE_GAMEPAD) &&
            dev->gamepad_index >= 0) {
          evdev_accum_gamepad_abs(dev,
                                  &plat->gamepad_state[dev->gamepad_index],
                                  ie->code, ie->value);
        }
        break;

      case EV_SYN:
        // Flush accumulated per-report state (coalesced mouse move/wheel and
        // gamepad state) on the report boundary.
        if (dev->roles & MINIAV_EVDEV_ROLE_MOUSE) {
          evdev_flush_mouse(plat, &mouse_acc, ts);
        }
        if ((dev->roles & MINIAV_EVDEV_ROLE_GAMEPAD) &&
            dev->gamepad_index >= 0) {
          evdev_flush_gamepad(plat, dev->gamepad_index, ts);
        }
        break;

      default:
        break;
      }
    }
    if (n < (ssize_t)sizeof(struct input_event)) {
      break; // partial/short read — done
    }
  }
}

// ============================================================================
// Capture thread
// ============================================================================

// Monotonic microseconds for absolute-deadline pacing (independent of the
// event timestamp clock; both share CLOCK_MONOTONIC in practice).
static uint64_t evdev_monotonic_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static void *evdev_capture_thread(void *arg) {
  InputPlatformLinux *plat = (InputPlatformLinux *)arg;

  // Rescan cadence for hot-plug detection.
  const uint64_t rescan_interval_us = 1000000ULL; // 1 s
  uint64_t next_rescan_us = evdev_monotonic_us() + rescan_interval_us;

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "evdev: capture thread started (%d device(s) open).",
             plat->device_count);

  struct pollfd fds[MINIAV_EVDEV_MAX_DEVICES + 1];

  for (;;) {
    // Build the pollfd set: stop eventfd first, then every device fd.
    int nfds = 0;
    fds[nfds].fd = plat->stop_efd;
    fds[nfds].events = POLLIN;
    fds[nfds].revents = 0;
    nfds++;

    // Remember which device each pollfd maps to.
    int dev_of_fd[MINIAV_EVDEV_MAX_DEVICES + 1];
    dev_of_fd[0] = -1;
    for (int i = 0; i < plat->device_count; ++i) {
      fds[nfds].fd = plat->devices[i].fd;
      fds[nfds].events = POLLIN;
      fds[nfds].revents = 0;
      dev_of_fd[nfds] = i;
      nfds++;
    }

    // Poll timeout: whatever comes first, a rescan deadline (bounded to 250ms
    // so hot-plug/stop stay responsive even when idle).
    uint64_t now = evdev_monotonic_us();
    uint64_t until_rescan =
        (next_rescan_us > now) ? (next_rescan_us - now) : 0;
    int timeout_ms = (int)(until_rescan / 1000ULL);
    if (timeout_ms > 250) {
      timeout_ms = 250;
    }

    int pr = poll(fds, (nfds_t)nfds, timeout_ms);
    if (pr < 0) {
      if (errno == EINTR) {
        continue;
      }
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "evdev: poll failed: %s",
                 strerror(errno));
      break;
    }

    // Stop request?
    if (fds[0].revents & POLLIN) {
      uint64_t val;
      ssize_t r = read(plat->stop_efd, &val, sizeof(val));
      (void)r;
      miniav_log(MINIAV_LOG_LEVEL_INFO, "evdev: stop signalled.");
      break;
    }

    // Service ready device fds. Note POLLERR/POLLHUP flags a removed device.
    for (int i = 1; i < nfds; ++i) {
      int di = dev_of_fd[i];
      if (di < 0 || di >= plat->device_count) {
        continue;
      }
      if (fds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
        evdev_close_device(plat, di);
        // The array was compacted; the safest response is to rebuild the
        // pollfd set on the next loop iteration, so break out now.
        break;
      }
      if (fds[i].revents & POLLIN) {
        evdev_service_device(plat, &plat->devices[di]);
      }
    }

    // Periodic hot-plug maintenance on the rescan deadline (absolute).
    now = evdev_monotonic_us();
    if (now >= next_rescan_us) {
      evdev_prune_dead_devices(plat);
      evdev_scan_devices(plat);
      // Absolute-deadline pacing: advance by exactly one interval; if we fell
      // far behind, resync to avoid a burst of catch-up rescans.
      next_rescan_us += rescan_interval_us;
      if (next_rescan_us <= now) {
        next_rescan_us = now + rescan_interval_us;
      }
    }
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "evdev: capture thread exiting.");
  return NULL;
}

// ============================================================================
// InputContextInternalOps implementation
// ============================================================================

static MiniAVResultCode input_linux_init_platform(MiniAVInputContext *ctx) {
  // Platform context was allocated in platform_init_for_selection; here we
  // create the stop eventfd (devices are NOT opened until start_capture).
  InputPlatformLinux *plat = (InputPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  plat->stop_efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (plat->stop_efd < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "evdev: eventfd() failed: %s",
               strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_linux_destroy_platform(MiniAVInputContext *ctx) {
  if (!ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  InputPlatformLinux *plat = (InputPlatformLinux *)ctx->platform_ctx;

  // Ensure the capture thread is stopped and joined. stop_capture returns
  // MINIAV_ERROR_TIMEOUT if the thread could not be reaped; in that case we
  // must LEAK the platform context (the still-live thread dereferences it) —
  // mirroring the PipeWire "leaking the context" protocol.
  if (plat->thread_started) {
    MiniAVResultCode stop_res = ctx->ops->stop_capture(ctx);
    if (stop_res == MINIAV_ERROR_TIMEOUT) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "evdev: capture thread still alive at destroy — leaking the "
                 "context to avoid a use-after-free.");
      ctx->platform_ctx = NULL;
      return MINIAV_ERROR_TIMEOUT;
    }
  }

  if (plat->stop_efd >= 0) {
    close(plat->stop_efd);
    plat->stop_efd = -1;
  }

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "evdev: platform context destroyed.");
  return MINIAV_SUCCESS;
}

// Enumerate connected gamepads by scanning /dev/input for evdev nodes that
// advertise EV_ABS + a gamepad button. Independent of any context/config so it
// can be called before a context exists (matches the Windows contract).
static MiniAVResultCode
input_linux_enumerate_gamepads(MiniAVDeviceInfo **devices_out,
                               uint32_t *count_out) {
  *devices_out = NULL;
  *count_out = 0;

  DIR *dir = opendir(MINIAV_EVDEV_DIR);
  if (!dir) {
    if (errno == EACCES) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "evdev: permission denied listing %s (add user to 'input' "
                 "group). No gamepads enumerated.",
                 MINIAV_EVDEV_DIR);
    }
    // No devices is a valid (empty) result, not an error.
    return MINIAV_SUCCESS;
  }

  MiniAVDeviceInfo *devices = (MiniAVDeviceInfo *)miniav_calloc(
      MINIAV_EVDEV_MAX_GAMEPADS, sizeof(MiniAVDeviceInfo));
  if (!devices) {
    closedir(dir);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  uint32_t found = 0;
  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL && found < MINIAV_EVDEV_MAX_GAMEPADS) {
    if (strncmp(ent->d_name, "event", 5) != 0) {
      continue;
    }
    char path[64];
    snprintf(path, sizeof(path), "%s/%s", MINIAV_EVDEV_DIR, ent->d_name);

    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
      if (errno == EACCES) {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "evdev: permission denied opening %s (add user to 'input' "
                   "group).",
                   path);
      }
      continue;
    }

    uint32_t roles = evdev_probe_roles(fd);
    if (roles & MINIAV_EVDEV_ROLE_GAMEPAD) {
      char name[MINIAV_DEVICE_NAME_MAX_LEN];
      evdev_read_name(fd, name, sizeof(name));
      miniav_strlcpy(devices[found].device_id, path,
                     MINIAV_DEVICE_ID_MAX_LEN);
      miniav_strlcpy(devices[found].name, name, MINIAV_DEVICE_NAME_MAX_LEN);
      devices[found].is_default = (found == 0);
      found++;
    }
    close(fd);
  }
  closedir(dir);

  if (found == 0) {
    miniav_free(devices);
    *devices_out = NULL;
    *count_out = 0;
    return MINIAV_SUCCESS;
  }

  *devices_out = devices;
  *count_out = found;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
input_linux_configure(MiniAVInputContext *ctx,
                      const MiniAVInputConfig *config) {
  InputPlatformLinux *plat = (InputPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  plat->input_types = config->input_types;
  plat->keyboard_cb = config->keyboard_callback;
  plat->mouse_cb = config->mouse_callback;
  plat->gamepad_cb = config->gamepad_callback;
  plat->user_data = config->user_data;

  plat->mouse_throttle_hz = config->mouse_throttle_hz;
  if (plat->mouse_throttle_hz > 0) {
    plat->mouse_throttle_interval_us = 1000000ULL / plat->mouse_throttle_hz;
  } else {
    plat->mouse_throttle_interval_us = 0;
  }

  plat->gamepad_poll_hz =
      (config->gamepad_poll_hz > 0) ? config->gamepad_poll_hz : 60;

  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_linux_start_capture(MiniAVInputContext *ctx) {
  InputPlatformLinux *plat = (InputPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (plat->thread_started) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  // Drain any stale stop token so a previous stop cannot immediately wake the
  // new thread.
  uint64_t drain;
  while (read(plat->stop_efd, &drain, sizeof(drain)) > 0) {
    // loop until EAGAIN
  }

  // Open the initial device set on the caller's thread so an EACCES/no-device
  // situation is visible before we report success. The thread then owns them.
  plat->device_count = 0;
  memset(plat->devices, 0, sizeof(plat->devices));
  memset(plat->gamepad_state, 0, sizeof(plat->gamepad_state));
  plat->next_mouse_emit_us = 0;
  evdev_scan_devices(plat);

  if (plat->device_count == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "evdev: no matching input devices opened (check the 'input' "
               "group membership / requested input_types). Capture thread "
               "will still run and pick up hot-plugged devices.");
  }

  int rc = pthread_create(&plat->thread, NULL, evdev_capture_thread, plat);
  if (rc != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "evdev: pthread_create failed: %d", rc);
    for (int i = plat->device_count - 1; i >= 0; --i) {
      evdev_close_device(plat, i);
    }
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->thread_started = true;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode input_linux_stop_capture(MiniAVInputContext *ctx) {
  InputPlatformLinux *plat = (InputPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (!plat->thread_started) {
    return MINIAV_SUCCESS;
  }

  // Wake the poll() via the stop eventfd (self-pipe/eventfd wake — never a
  // thread cancellation).
  uint64_t one = 1;
  if (write(plat->stop_efd, &one, sizeof(one)) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "evdev: failed to write stop eventfd: %s", strerror(errno));
  }

  // Bounded join. On timeout the thread is left JOINABLE and thread_started
  // stays true so a later Stop/Destroy retries — we do NOT cancel it and we do
  // NOT free anything it touches.
  if (miniav_timed_join(plat->thread, 5000) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "evdev: capture thread did not exit within 5s — deferring (a "
               "later Stop/Destroy will retry the join).");
    return MINIAV_ERROR_TIMEOUT;
  }

  plat->thread_started = false;

  // Thread has exited; it owned the device fds, so close them now.
  for (int i = plat->device_count - 1; i >= 0; --i) {
    evdev_close_device(plat, i);
  }
  plat->device_count = 0;

  return MINIAV_SUCCESS;
}

// --- Ops table and selection entrypoint ---

const InputContextInternalOps g_input_ops_linux = {
    .init_platform = input_linux_init_platform,
    .destroy_platform = input_linux_destroy_platform,
    .enumerate_gamepads = input_linux_enumerate_gamepads,
    .configure = input_linux_configure,
    .start_capture = input_linux_start_capture,
    .stop_capture = input_linux_stop_capture,
};

MiniAVResultCode
miniav_input_context_platform_init_linux(MiniAVInputContext *ctx) {
  InputPlatformLinux *plat =
      (InputPlatformLinux *)miniav_calloc(1, sizeof(InputPlatformLinux));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  plat->stop_efd = -1;

  ctx->platform_ctx = plat;
  ctx->ops = &g_input_ops_linux;
  return MINIAV_SUCCESS;
}
