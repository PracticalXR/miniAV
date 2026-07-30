// Linux input-injection backend — replays keyboard and mouse events onto the
// local machine through the kernel uinput module (/dev/uinput) with NO external
// dependencies. We write raw `struct input_event` records (EV_KEY / EV_REL /
// EV_ABS + EV_SYN) to virtual devices. uinput was chosen over XTest because it
// works under BOTH X11 and Wayland (XTest is X11-only).
//
// TWO DEVICES: mouse injection is split across two virtual uinput devices, each
// with its own control fd, because libinput/Xorg classify any device with
// relative axes as a mouse and then IGNORE its absolute axes — so one device
// advertising both EV_REL and EV_ABS makes absolute positioning silently no-op
// under a real compositor. See the header for the topology. In short:
//   - REL device: EV_KEY (buttons, plus the keyboard keys when a keyboard is
//     requested) + EV_REL (X/Y/WHEEL/HWHEEL). Handles relative MOVE, buttons,
//     wheel and all keyboard events.
//   - ABS device: EV_KEY (BTN_TOUCH + BTN_LEFT) + EV_ABS (X/Y, range 0..65535)
//     + property INPUT_PROP_DIRECT. Handles absolute MOVE only.
// The single system cursor is shared, so an ABS move positions the cursor and a
// following click from the REL device lands there (correct and intended).
//
// PERMISSIONS: /dev/uinput is normally root-only. init_platform returns
// MINIAV_ERROR_PERMISSION_DENIED on EACCES/EPERM (a udev rule or root is
// needed) and MINIAV_ERROR_NOT_SUPPORTED on ENOENT (uinput module not loaded).
// See the header for the exact udev rule.
//
// KEYCODE SPACE: keyboard/button/wheel codes are Linux input-event codes
// (KEY_*, BTN_*, REL_WHEEL/REL_HWHEEL), identical to what the evdev capture
// backend reports. We write EV_KEY with code = event->scan_code (the capture
// backend fills BOTH key_code and scan_code with the raw evdev code).
//
// ABSOLUTE COORDINATES: ABS_X/ABS_Y are declared with range 0..65535 and
// absolute moves are taken as already-normalised 0..65535 device units (see
// header). WHEEL is converted to notches (see header + inject_mouse).
//
// THREADING: injection is fully synchronous — there is no capture thread or
// callback here. The device fds are opened O_NONBLOCK, so a write that the
// kernel cannot immediately accept fails with EAGAIN rather than blocking. On
// EAGAIN we retry the write ONCE; if it still cannot be accepted the axis is
// dropped (non-fatal, logged at DEBUG) and the enclosing multi-axis report
// SKIPS its SYN_REPORT so a half-updated event is never committed.

#include "inject_context_linux_uinput.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_utils.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

// Absolute pointer coordinate range we declare on ABS_X/ABS_Y. Callers pass
// absolute coordinates already normalised into this range (see header).
#define MINIAV_UINPUT_ABS_MAX 65535

// Windows-style wheel delta granularity; a wheel notch is 120 units. Callers
// pass deltas in these units (see inject_mouse / header).
#define MINIAV_WHEEL_DELTA 120

// INPUT_PROP_DIRECT / UI_SET_PROPBIT let us tag the absolute pointer device as a
// direct (tablet/touch-like) pointer so its ABS axes are honored rather than
// interpreted as a mouse. Both arrived in Linux 3.x but may be missing from very
// old <linux/input.h>/<linux/uinput.h>; guard so we still build (and still
// create the abs device, with a reduced classification guarantee) without them.
#if defined(UI_SET_PROPBIT) && defined(INPUT_PROP_DIRECT)
#define MINIAV_UINPUT_HAVE_PROP_DIRECT 1
#else
#define MINIAV_UINPUT_HAVE_PROP_DIRECT 0
#endif

// --- Platform context ---
//
// Two independent virtual devices, each with its own /dev/uinput control fd.
// See the file header for why absolute positioning needs its own device.

typedef struct InjectPlatformLinux {
  int rel_fd;          // control fd for the relative-mouse + keyboard device
  int abs_fd;          // control fd for the absolute-pointer device
  bool rel_created;    // true once UI_DEV_CREATE succeeded on rel_fd
  bool abs_created;    // true once UI_DEV_CREATE succeeded on abs_fd
} InjectPlatformLinux;

// ============================================================================
// Low-level uinput helpers
// ============================================================================

// Write a single input_event record to a device fd. Returns MINIAV_SUCCESS, or
// MINIAV_ERROR_SYSTEM_CALL_FAILED on a hard error. On EAGAIN/EWOULDBLOCK (the
// kernel buffer is momentarily full on the non-blocking fd) we retry the write
// ONCE; if it still cannot be accepted the event is dropped (non-fatal per the
// injection contract) and *dropped is set true so the caller can suppress the
// SYN_REPORT for a partially-written multi-axis report.
static MiniAVResultCode uinput_emit(int fd, uint16_t type, uint16_t code,
                                    int32_t value, bool *dropped) {
  struct input_event ev;
  memset(&ev, 0, sizeof(ev));
  // input_event.time is ignored by uinput on input; leave it zeroed.
  ev.type = type;
  ev.code = code;
  ev.value = value;

  for (int attempt = 0; attempt < 2; ++attempt) {
    ssize_t n = write(fd, &ev, sizeof(ev));
    if (n == (ssize_t)sizeof(ev)) {
      return MINIAV_SUCCESS;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      continue; // retry once, then fall through to the drop path below
    }
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: write failed (type=0x%x code=0x%x value=%d): %s", type,
               code, value, strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Still would-block after the retry. Drop this axis and mark the report
  // partial so the caller skips SYN.
  if (dropped) {
    *dropped = true;
  }
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "uinput: write would block after retry (type=0x%x code=0x%x) — "
             "dropping event.",
             type, code);
  return MINIAV_SUCCESS;
}

// Emit an EV_SYN/SYN_REPORT on a device fd to flush the batch of events just
// written. Only call this for a report in which no axis was dropped.
static MiniAVResultCode uinput_sync(int fd) {
  return uinput_emit(fd, EV_SYN, SYN_REPORT, 0, NULL);
}

// Tear down a single virtual device (UI_DEV_DESTROY) if *created, then close and
// clear its fd. Safe to call when nothing was created / the fd is already -1.
static void uinput_teardown_device(int *fd, bool *created) {
  if (*created) {
    if (ioctl(*fd, UI_DEV_DESTROY) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "uinput: UI_DEV_DESTROY failed: %s (continuing).",
                 strerror(errno));
    }
    *created = false;
  }
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

// Destroy BOTH virtual devices (used on reconfigure and teardown). Bounded and
// leaves every fd at -1 / created=false.
static void uinput_destroy_devices(InjectPlatformLinux *plat) {
  uinput_teardown_device(&plat->rel_fd, &plat->rel_created);
  uinput_teardown_device(&plat->abs_fd, &plat->abs_created);
}

// Map a MiniAVMouseButton to its evdev BTN_* code. Returns 0 if unmapped.
static uint16_t uinput_button_code(MiniAVMouseButton button) {
  switch (button) {
  case MINIAV_MOUSE_BUTTON_LEFT:
    return BTN_LEFT;
  case MINIAV_MOUSE_BUTTON_RIGHT:
    return BTN_RIGHT;
  case MINIAV_MOUSE_BUTTON_MIDDLE:
    return BTN_MIDDLE;
  case MINIAV_MOUSE_BUTTON_X1:
    return BTN_SIDE;
  case MINIAV_MOUSE_BUTTON_X2:
    return BTN_EXTRA;
  default:
    return 0;
  }
}

// Convert a MiniAV wheel delta into uinput notches. uinput expects wheel motion
// in detents (notches); callers pass deltas in Windows WHEEL_DELTA (120-per-
// notch) units, which is what the capture side reports. 120 is authoritative:
// for |delta| >= 120 we divide by 120 (rounded to the nearest notch); for a
// non-zero |delta| < 120 (e.g. a Windows precision-wheel fragment) we emit a
// single notch in the delta's direction. This keeps same-platform ±120 steps
// exact while never turning a sub-notch fragment like 40 into 40 notches — the
// caller owns any finer cross-platform translation (see header).
static int32_t uinput_wheel_notches(int32_t delta) {
  if (delta == 0) {
    return 0;
  }
  if (delta >= MINIAV_WHEEL_DELTA || delta <= -MINIAV_WHEEL_DELTA) {
    // Round to nearest notch (symmetric for negative deltas).
    if (delta > 0) {
      return (delta + MINIAV_WHEEL_DELTA / 2) / MINIAV_WHEEL_DELTA;
    }
    return -((-delta + MINIAV_WHEEL_DELTA / 2) / MINIAV_WHEEL_DELTA);
  }
  // 0 < |delta| < 120: a single notch in the correct direction.
  return (delta > 0) ? 1 : -1;
}

// ============================================================================
// InjectContextInternalOps implementation
// ============================================================================

// Open one /dev/uinput control fd. Maps EACCES/EPERM -> PERMISSION_DENIED and
// ENOENT -> NOT_SUPPORTED (keeping the documented mapping); logs the udev-rule
// hint once via the caller. On success stores the fd in *out_fd.
static MiniAVResultCode uinput_open_control_fd(int *out_fd) {
  int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    int e = errno;
    if (e == EACCES || e == EPERM) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "uinput: permission denied opening /dev/uinput (%s). Install a "
                 "udev rule granting write access (e.g. KERNEL==\"uinput\", "
                 "MODE=\"0660\", GROUP=\"input\") and add the user to the "
                 "'input' group, or run as root.",
                 strerror(e));
      return MINIAV_ERROR_PERMISSION_DENIED;
    }
    if (e == ENOENT) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "uinput: /dev/uinput does not exist — the uinput kernel "
                 "module is not loaded. Load it with `modprobe uinput`.");
      return MINIAV_ERROR_NOT_SUPPORTED;
    }
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: open(/dev/uinput) failed: %s",
               strerror(e));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  *out_fd = fd;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode inject_linux_init_platform(MiniAVInjectContext *ctx) {
  // Platform context was allocated in platform_init_for_selection. We open BOTH
  // control fds here so a permission/module problem surfaces at init; the
  // virtual devices themselves are created on configure (which knows the
  // requested input_types).
  InjectPlatformLinux *plat = (InjectPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  MiniAVResultCode res = uinput_open_control_fd(&plat->rel_fd);
  if (res != MINIAV_SUCCESS) {
    return res;
  }
  res = uinput_open_control_fd(&plat->abs_fd);
  if (res != MINIAV_SUCCESS) {
    close(plat->rel_fd);
    plat->rel_fd = -1;
    return res;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "uinput: opened /dev/uinput control fds (rel=%d abs=%d). Virtual "
             "devices are created on configure.",
             plat->rel_fd, plat->abs_fd);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode inject_linux_destroy_platform(MiniAVInjectContext *ctx) {
  if (!ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  InjectPlatformLinux *plat = (InjectPlatformLinux *)ctx->platform_ctx;

  // Destroy + close BOTH devices (bounded; always succeeds).
  uinput_destroy_devices(plat);

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "uinput: platform context destroyed.");
  return MINIAV_SUCCESS;
}

// Fill a uinput_setup with a synthetic virtual-device identity. `name` is
// copied into usetup.name (bounded). `product` distinguishes our two devices.
static void uinput_fill_setup(struct uinput_setup *usetup, const char *name,
                              uint16_t product) {
  memset(usetup, 0, sizeof(*usetup));
  usetup->id.bustype = BUS_VIRTUAL;
  usetup->id.vendor = 0x1234; // arbitrary synthetic vendor
  usetup->id.product = product;
  usetup->id.version = 1;
  miniav_strlcpy(usetup->name, name, sizeof(usetup->name));
}

// Build the RELATIVE mouse (+ optional keyboard) device on plat->rel_fd:
// EV_KEY mouse buttons (+ the full keyboard key range when want_keyboard) and
// EV_REL X/Y/WHEEL/HWHEEL. Advertising ONLY relative axes here keeps
// libinput/Xorg classifying it as a mouse. On success sets plat->rel_created.
static MiniAVResultCode uinput_build_rel_device(InjectPlatformLinux *plat,
                                                bool want_keyboard) {
  const int fd = plat->rel_fd;

  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
    goto evbit_fail;
  }
  if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) {
    goto evbit_fail;
  }

  static const int mouse_buttons[] = {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE,
                                      BTN_SIDE, BTN_EXTRA};
  for (size_t i = 0; i < sizeof(mouse_buttons) / sizeof(mouse_buttons[0]);
       ++i) {
    if (ioctl(fd, UI_SET_KEYBIT, mouse_buttons[i]) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "uinput: UI_SET_KEYBIT(button %d) failed: %s",
                 mouse_buttons[i], strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }

  static const int rel_axes[] = {REL_X, REL_Y, REL_WHEEL, REL_HWHEEL};
  for (size_t i = 0; i < sizeof(rel_axes) / sizeof(rel_axes[0]); ++i) {
    if (ioctl(fd, UI_SET_RELBIT, rel_axes[i]) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: UI_SET_RELBIT(%d) failed: %s",
                 rel_axes[i], strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }

  if (want_keyboard) {
    // Enable the full ordinary-key range. KEY_ESC (1) .. KEY_MAX covers every
    // KEY_* the evdev capture side can report. The keyboard rides on the
    // relative device (a real mouse+keyboard combo is fine and needs only one
    // node); the absolute pointer stays a pure pointer.
    for (int code = KEY_ESC; code < KEY_MAX; ++code) {
      if (ioctl(fd, UI_SET_KEYBIT, code) < 0) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "uinput: UI_SET_KEYBIT(%d) failed: %s", code,
                   strerror(errno));
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
      }
    }
  }

  struct uinput_setup usetup;
  uinput_fill_setup(&usetup, "miniAV Virtual Pointer", 0x5678);
  if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: UI_DEV_SETUP (rel) failed: %s", strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if (ioctl(fd, UI_DEV_CREATE) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: UI_DEV_CREATE (rel) failed: %s", strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->rel_created = true;
  return MINIAV_SUCCESS;

evbit_fail:
  miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: UI_SET_EVBIT (rel) failed: %s",
             strerror(errno));
  return MINIAV_ERROR_SYSTEM_CALL_FAILED;
}

// Build the ABSOLUTE pointer device on plat->abs_fd: EV_KEY (BTN_TOUCH so it is
// a valid direct pointer, plus BTN_LEFT so it is a usable pointing device) and
// EV_ABS X/Y with range 0..MINIAV_UINPUT_ABS_MAX, tagged INPUT_PROP_DIRECT so
// the compositor honors its absolute axes instead of treating it as a mouse. On
// older headers without UI_SET_PROPBIT/INPUT_PROP_DIRECT the property is skipped
// (the device is still created; classification is best-effort). On success sets
// plat->abs_created.
static MiniAVResultCode uinput_build_abs_device(InjectPlatformLinux *plat) {
  const int fd = plat->abs_fd;

  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
    goto evbit_fail;
  }
  if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) {
    goto evbit_fail;
  }

  static const int abs_keys[] = {BTN_TOUCH, BTN_LEFT};
  for (size_t i = 0; i < sizeof(abs_keys) / sizeof(abs_keys[0]); ++i) {
    if (ioctl(fd, UI_SET_KEYBIT, abs_keys[i]) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "uinput: UI_SET_KEYBIT(abs key %d) failed: %s", abs_keys[i],
                 strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }

  static const int abs_axes[] = {ABS_X, ABS_Y};
  for (size_t i = 0; i < sizeof(abs_axes) / sizeof(abs_axes[0]); ++i) {
    if (ioctl(fd, UI_SET_ABSBIT, abs_axes[i]) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: UI_SET_ABSBIT(%d) failed: %s",
                 abs_axes[i], strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }

#if MINIAV_UINPUT_HAVE_PROP_DIRECT
  // Tag as a direct pointer so libinput/Xorg honor the absolute axes rather
  // than classifying the node as a relative mouse. Non-fatal if the kernel
  // rejects it — the device still functions, just with weaker classification.
  if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "uinput: UI_SET_PROPBIT(INPUT_PROP_DIRECT) failed: %s "
               "(continuing; absolute axes may be less reliably honored).",
               strerror(errno));
  }
#else
  miniav_log(MINIAV_LOG_LEVEL_WARN,
             "uinput: UI_SET_PROPBIT/INPUT_PROP_DIRECT unavailable in these "
             "kernel headers — absolute pointer created without the DIRECT "
             "property (classification is best-effort).");
#endif

  struct uinput_setup usetup;
  uinput_fill_setup(&usetup, "miniAV Virtual Abs Pointer", 0x5679);
  if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: UI_DEV_SETUP (abs) failed: %s", strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Declare the ABS_X / ABS_Y logical range [0, MINIAV_UINPUT_ABS_MAX] so
  // absolute pointer moves land correctly. Requires UI_ABS_SETUP (Linux 4.5+,
  // same era as UI_DEV_SETUP).
  struct uinput_abs_setup abs_setup;
  for (size_t i = 0; i < sizeof(abs_axes) / sizeof(abs_axes[0]); ++i) {
    memset(&abs_setup, 0, sizeof(abs_setup));
    abs_setup.code = (uint16_t)abs_axes[i];
    abs_setup.absinfo.minimum = 0;
    abs_setup.absinfo.maximum = MINIAV_UINPUT_ABS_MAX;
    if (ioctl(fd, UI_ABS_SETUP, &abs_setup) < 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: UI_ABS_SETUP(%d) failed: %s",
                 abs_axes[i], strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
  }

  if (ioctl(fd, UI_DEV_CREATE) < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: UI_DEV_CREATE (abs) failed: %s", strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->abs_created = true;
  return MINIAV_SUCCESS;

evbit_fail:
  miniav_log(MINIAV_LOG_LEVEL_ERROR, "uinput: UI_SET_EVBIT (abs) failed: %s",
             strerror(errno));
  return MINIAV_ERROR_SYSTEM_CALL_FAILED;
}

static MiniAVResultCode inject_linux_configure(MiniAVInjectContext *ctx,
                                               uint32_t input_types) {
  InjectPlatformLinux *plat = (InjectPlatformLinux *)ctx->platform_ctx;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (plat->rel_fd < 0 || plat->abs_fd < 0) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  // Recreating on reconfigure: destroy any existing virtual devices first so we
  // can re-declare capabilities cleanly. This also closes the control fds, so
  // reopen them before rebuilding.
  uinput_destroy_devices(plat);

  const bool want_keyboard = (input_types & MINIAV_INPUT_TYPE_KEYBOARD) != 0;
  const bool want_mouse = (input_types & MINIAV_INPUT_TYPE_MOUSE) != 0;

  if (!want_keyboard && !want_mouse) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "uinput: configure requested neither keyboard nor mouse "
               "(input_types=0x%x). Nothing to create.",
               input_types);
    return MINIAV_ERROR_INVALID_ARG;
  }
  // Gamepad injection is not supported by this backend (no public uinput
  // gamepad contract mirrored here); ignore the bit but note it.
  if (input_types & MINIAV_INPUT_TYPE_GAMEPAD) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "uinput: gamepad injection is not supported by the Linux "
               "backend — ignoring MINIAV_INPUT_TYPE_GAMEPAD.");
  }

  MiniAVResultCode res = uinput_open_control_fd(&plat->rel_fd);
  if (res != MINIAV_SUCCESS) {
    return res;
  }
  res = uinput_open_control_fd(&plat->abs_fd);
  if (res != MINIAV_SUCCESS) {
    close(plat->rel_fd);
    plat->rel_fd = -1;
    return res;
  }

  // Relative + keyboard device. Built whenever a mouse OR keyboard is wanted:
  // it also carries the keyboard keys, and is a valid pointer for buttons/wheel
  // and relative moves.
  res = uinput_build_rel_device(plat, want_keyboard);
  if (res != MINIAV_SUCCESS) {
    uinput_destroy_devices(plat);
    return res;
  }

  // Absolute pointer device — only needed when mouse injection is requested
  // (absolute MOVE routes here). Skipping it for keyboard-only saves a node.
  if (want_mouse) {
    res = uinput_build_abs_device(plat);
    if (res != MINIAV_SUCCESS) {
      uinput_destroy_devices(plat);
      return res;
    }
  } else {
    // Not needed; close the spare control fd so we don't hold it open.
    close(plat->abs_fd);
    plat->abs_fd = -1;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "uinput: created virtual devices (keyboard=%d mouse=%d; rel node "
             "+ %s abs node, abs range 0..%d).",
             want_keyboard, want_mouse, want_mouse ? "an" : "no",
             MINIAV_UINPUT_ABS_MAX);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
inject_linux_inject_keyboard(MiniAVInjectContext *ctx,
                             const MiniAVKeyboardEvent *event) {
  InjectPlatformLinux *plat = (InjectPlatformLinux *)ctx->platform_ctx;
  // Keyboard keys ride on the relative device.
  if (!plat || plat->rel_fd < 0 || !plat->rel_created) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  // The evdev capture backend fills BOTH key_code and scan_code with the raw
  // evdev KEY_* code; we replay it verbatim. scan_code is used per the module
  // contract (either is equivalent for this backend).
  uint16_t code = (uint16_t)event->scan_code;
  int32_t value = (event->action == MINIAV_KEY_ACTION_DOWN) ? 1 : 0;

  bool dropped = false;
  MiniAVResultCode res = uinput_emit(plat->rel_fd, EV_KEY, code, value,
                                     &dropped);
  if (res != MINIAV_SUCCESS) {
    return res;
  }
  // Single-event report: if the key press itself was dropped there is nothing
  // to commit, so skip the SYN.
  if (dropped) {
    return MINIAV_SUCCESS;
  }
  return uinput_sync(plat->rel_fd);
}

static MiniAVResultCode
inject_linux_inject_mouse(MiniAVInjectContext *ctx,
                          const MiniAVMouseEvent *event) {
  InjectPlatformLinux *plat = (InjectPlatformLinux *)ctx->platform_ctx;
  // Mouse injection needs the relative device (buttons/wheel/relative MOVE);
  // absolute MOVE additionally needs the absolute device. Both are created
  // together whenever mouse was configured, so require the relative one here
  // and check abs specifically on the absolute-MOVE path.
  if (!plat || plat->rel_fd < 0 || !plat->rel_created) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }

  // Which device fd this event's report is flushed on. Buttons, wheel and
  // relative moves go to the relative device; an absolute MOVE goes to the
  // absolute pointer device. The two share the ONE system cursor, so an
  // absolute move positions the cursor and a following relative-device click
  // lands there (correct and intended — see header).
  int sync_fd = plat->rel_fd;
  bool dropped = false;
  MiniAVResultCode res = MINIAV_SUCCESS;

  switch (event->action) {
  case MINIAV_MOUSE_ACTION_MOVE:
    if (event->is_absolute) {
      if (plat->abs_fd < 0 || !plat->abs_created) {
        // Mouse was configured but somehow the abs device is absent; without it
        // an absolute move cannot be honored (relative axes would be ignored by
        // the compositor anyway).
        return MINIAV_ERROR_NOT_INITIALIZED;
      }
      sync_fd = plat->abs_fd;
      // Absolute: x/y are already-normalised device units in [0, ABS_MAX]
      // (see header). Clamp defensively.
      int32_t ax = event->x;
      int32_t ay = event->y;
      if (ax < 0) {
        ax = 0;
      } else if (ax > MINIAV_UINPUT_ABS_MAX) {
        ax = MINIAV_UINPUT_ABS_MAX;
      }
      if (ay < 0) {
        ay = 0;
      } else if (ay > MINIAV_UINPUT_ABS_MAX) {
        ay = MINIAV_UINPUT_ABS_MAX;
      }
      res = uinput_emit(plat->abs_fd, EV_ABS, ABS_X, ax, &dropped);
      if (res == MINIAV_SUCCESS) {
        res = uinput_emit(plat->abs_fd, EV_ABS, ABS_Y, ay, &dropped);
      }
    } else {
      // Relative: move by delta_x/delta_y on the relative device. Emit only
      // non-zero axes to avoid a spurious 0-delta report.
      if (event->delta_x != 0) {
        res = uinput_emit(plat->rel_fd, EV_REL, REL_X, event->delta_x,
                          &dropped);
      }
      if (res == MINIAV_SUCCESS && event->delta_y != 0) {
        res = uinput_emit(plat->rel_fd, EV_REL, REL_Y, event->delta_y,
                          &dropped);
      }
    }
    break;

  case MINIAV_MOUSE_ACTION_BUTTON_DOWN:
  case MINIAV_MOUSE_ACTION_BUTTON_UP: {
    uint16_t code = uinput_button_code(event->button);
    if (code == 0) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "uinput: mouse button %d has no evdev mapping — ignoring.",
                 event->button);
      return MINIAV_ERROR_INVALID_ARG;
    }
    int32_t value =
        (event->action == MINIAV_MOUSE_ACTION_BUTTON_DOWN) ? 1 : 0;
    res = uinput_emit(plat->rel_fd, EV_KEY, code, value, &dropped);
    break;
  }

  case MINIAV_MOUSE_ACTION_WHEEL: {
    int32_t v_notches = uinput_wheel_notches(event->wheel_delta);
    int32_t h_notches = uinput_wheel_notches(event->wheel_delta_x);
    if (v_notches != 0) {
      res = uinput_emit(plat->rel_fd, EV_REL, REL_WHEEL, v_notches, &dropped);
    }
    if (res == MINIAV_SUCCESS && h_notches != 0) {
      res = uinput_emit(plat->rel_fd, EV_REL, REL_HWHEEL, h_notches, &dropped);
    }
    break;
  }

  default:
    miniav_log(MINIAV_LOG_LEVEL_WARN, "uinput: unknown mouse action %d.",
               event->action);
    return MINIAV_ERROR_INVALID_ARG;
  }

  if (res != MINIAV_SUCCESS) {
    return res;
  }
  // If ANY axis in this batch was dropped on EAGAIN, do NOT commit a partial
  // event (e.g. ABS_X written but ABS_Y dropped would jump horizontally only).
  // Skip the SYN_REPORT; the next event will resend a coherent report.
  if (dropped) {
    return MINIAV_SUCCESS;
  }
  return uinput_sync(sync_fd);
}

// --- Ops table and selection entrypoint ---

const InjectContextInternalOps g_inject_ops_linux = {
    .init_platform = inject_linux_init_platform,
    .destroy_platform = inject_linux_destroy_platform,
    .configure = inject_linux_configure,
    .inject_keyboard = inject_linux_inject_keyboard,
    .inject_mouse = inject_linux_inject_mouse,
};

MiniAVResultCode
miniav_inject_context_platform_init_linux(MiniAVInjectContext *ctx) {
  InjectPlatformLinux *plat =
      (InjectPlatformLinux *)miniav_calloc(1, sizeof(InjectPlatformLinux));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  plat->rel_fd = -1;
  plat->abs_fd = -1;
  plat->rel_created = false;
  plat->abs_created = false;

  ctx->platform_ctx = plat;
  ctx->ops = &g_inject_ops_linux;
  return MINIAV_SUCCESS;
}
