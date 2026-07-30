#ifndef INJECT_CONTEXT_LINUX_UINPUT_H
#define INJECT_CONTEXT_LINUX_UINPUT_H

#include "../inject_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// Linux input-injection backend built on /dev/uinput (kernel uinput module).
// Selected by the injection dispatcher via the "LinuxUinput" backend-table
// entry. Chosen over XTest because uinput works under BOTH X11 and Wayland
// (XTest is X11-only and dead on Wayland).
//
// The backend replays MiniAVKeyboardEvent / MiniAVMouseEvent onto virtual
// uinput devices. Injection is synchronous (no thread/callback).
//
// DEVICE TOPOLOGY: mouse injection is split across TWO virtual uinput devices
// (plus the keyboard capability folded onto the relative device when a keyboard
// is requested). libinput/Xorg classify any device exposing relative axes as a
// mouse and then IGNORE its absolute axes, so a single device advertising both
// EV_REL and EV_ABS silently no-ops absolute positioning under a real
// compositor. To make BOTH work we create:
//   - a RELATIVE mouse device (EV_KEY buttons + EV_REL X/Y/WHEEL/HWHEEL, and
//     the keyboard keys if a keyboard was requested) — handles relative MOVE,
//     buttons, wheel and all keyboard events; and
//   - an ABSOLUTE pointer device (EV_KEY BTN_TOUCH + BTN_LEFT, EV_ABS X/Y with
//     range 0..65535, property INPUT_PROP_DIRECT) — classified as an
//     absolute/tablet-like pointer whose ABS axes ARE honored; handles
//     absolute MOVE only.
// Both drive the ONE shared system cursor, so an absolute MOVE positions the
// cursor and a following button click (emitted on the relative device) lands at
// that position — correct and intended.
//
// PERMISSIONS: /dev/uinput is normally writable only by root. To let an
// unprivileged process create virtual devices, install a udev rule granting
// access, e.g.:
//     KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
// and add the user to the 'input' group (or otherwise widen the mode). Without
// this, init returns MINIAV_ERROR_PERMISSION_DENIED. If the uinput kernel
// module is not loaded (/dev/uinput missing) init returns
// MINIAV_ERROR_NOT_SUPPORTED (load it with `modprobe uinput`).
//
// KEYCODE SPACE: keyboard/button/wheel codes are Linux input-event codes
// (KEY_*, BTN_*, REL_WHEEL/REL_HWHEEL) — the SAME space the evdev capture
// backend reports. inject_keyboard writes EV_KEY with code =
// event->scan_code (the evdev capture backend fills BOTH key_code and scan_code
// with the raw evdev code, so either would work; scan_code is used here).
//
// ABSOLUTE COORDINATES: the absolute pointer device declares ABS_X/ABS_Y with
// range 0..65535. Absolute mouse MOVE (is_absolute == true) treats event->x /
// event->y as ALREADY-NORMALISED device units in [0, 65535] (0 = left/top,
// 65535 = right/bottom of the target display), NOT raw pixels. A pure
// /dev/uinput backend has no display connection and cannot know the screen
// size, so the caller must normalise pixel coordinates to 0..65535 before
// injecting an absolute move. Out-of-range values are clamped to [0, 65535].
//
// WHEEL NOTCHES: uinput REL_WHEEL / REL_HWHEEL are expressed in wheel NOTCHES
// (detents). Callers MUST pass wheel deltas in 120-per-notch units (Windows
// WHEEL_DELTA), which is exactly what the capture side reports; cross-platform
// magnitude translation is the caller's job (per the injection contract).
// inject_mouse converts to notches: |delta| >= 120 is divided by 120 (rounded);
// a non-zero |delta| < 120 (e.g. a Windows precision-wheel fragment) emits a
// single notch in the delta's direction so small scrolls are neither swallowed
// nor amplified (a raw 40 becomes 1 notch, never 40). Same rule for
// wheel_delta_x -> REL_HWHEEL.
extern const InjectContextInternalOps g_inject_ops_linux;

// Selects the uinput backend for a freshly-created injection context:
// allocates the platform context and wires ctx->ops. Mirrors
// miniav_input_context_platform_init_linux().
MiniAVResultCode
miniav_inject_context_platform_init_linux(MiniAVInjectContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // INJECT_CONTEXT_LINUX_UINPUT_H
