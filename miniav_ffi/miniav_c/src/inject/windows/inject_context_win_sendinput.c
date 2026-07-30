// Windows input-injection backend (event replay) built on SendInput.
//
// This is the sink twin of the raw-input capture backend: it takes the same
// MiniAVKeyboardEvent / MiniAVMouseEvent structs capture reports and replays
// them onto the local machine via the Win32 SendInput API. Injection is fully
// synchronous — there is no worker thread and no callback — so there is no
// bounded-destroy TIMEOUT path to honor (the op signature keeps the shape).
//
// PERMISSIONS: SendInput needs no special permission to create, but UIPI (User
// Interface Privilege Isolation) silently blocks a medium-integrity process
// from injecting into a higher-integrity window (e.g. an elevated app or the
// secure desktop). When that happens SendInput returns a count short of what we
// asked for; we surface MINIAV_ERROR_SYSTEM_CALL_FAILED and log the UIPI note
// at DEBUG rather than spamming ERROR, since it is an expected policy outcome.

#include "inject_context_win_sendinput.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_utils.h"

#include <windows.h>

#include <string.h>

// --- Platform-specific context data ---
//
// SendInput has no device/session to own, so the platform context only caches
// the configured input-type bitmask (for symmetry with the other backends and
// so a future keyboard/mouse-only gate could consult it).
typedef struct InjectPlatformWin {
  uint32_t input_types; // Bitmask of MiniAVInputType, set by configure.
} InjectPlatformWin;

// The extended-key set: scancodes that require KEYEVENTF_EXTENDEDKEY so the OS
// maps them to the "grey" navigation/right-hand keys rather than their numpad
// twins. These are the low-byte make codes (set 1). We only consult this table
// when injecting BY SCANCODE; virtual-key injection lets the OS resolve the
// extended bit from the VK itself.
static bool inject_win_scancode_is_extended(uint16_t scan_code) {
  switch (scan_code & 0xFF) {
  case 0x1D: // Right Ctrl (E0 1D)
  case 0x35: // Numpad '/' (E0 35)
  case 0x38: // Right Alt / AltGr (E0 38)
  case 0x47: // Home       (E0 47)
  case 0x48: // Up arrow    (E0 48)
  case 0x49: // Page Up     (E0 49)
  case 0x4B: // Left arrow  (E0 4B)
  case 0x4D: // Right arrow (E0 4D)
  case 0x4F: // End         (E0 4F)
  case 0x50: // Down arrow  (E0 50)
  case 0x51: // Page Down   (E0 51)
  case 0x52: // Insert      (E0 52)
  case 0x53: // Delete      (E0 53)
  case 0x1C: // Numpad Enter (E0 1C) — shares its low byte with main Enter, but
             // callers that captured the numpad key report the E0-prefixed
             // scancode; treating 0x1C as extended is correct for numpad Enter
             // and harmless for main Enter (which is not typically injected by
             // scancode with the extended intent).
    return true;
  default:
    return false;
  }
}

// --- Ops: init / destroy / configure ---

static MiniAVResultCode inject_win_init_platform(MiniAVInjectContext *ctx) {
  // The platform context was already allocated in platform_init_for_selection.
  // Nothing to open for SendInput.
  (void)ctx;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode inject_win_destroy_platform(MiniAVInjectContext *ctx) {
  if (ctx && ctx->platform_ctx) {
    miniav_free(ctx->platform_ctx);
    ctx->platform_ctx = NULL;
  }
  // No threads / OS resources → bounded-destroy TIMEOUT protocol is a no-op.
  return MINIAV_SUCCESS;
}

static MiniAVResultCode inject_win_configure(MiniAVInjectContext *ctx,
                                             uint32_t input_types) {
  InjectPlatformWin *plat =
      ctx ? (InjectPlatformWin *)ctx->platform_ctx : NULL;
  if (!plat) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  // No virtual device to create on Windows — just record the accepted mask.
  plat->input_types = input_types;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "Inject(win): configured for input types 0x%x (SendInput needs no "
             "device).",
             input_types);
  return MINIAV_SUCCESS;
}

// --- Ops: keyboard injection ---

static MiniAVResultCode
inject_win_inject_keyboard(MiniAVInjectContext *ctx,
                           const MiniAVKeyboardEvent *event) {
  if (!ctx || !ctx->platform_ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  INPUT input;
  memset(&input, 0, sizeof(input));
  input.type = INPUT_KEYBOARD;

  DWORD flags = 0;
  if (event->scan_code != 0) {
    // Prefer scancode injection: it is layout-independent and lands the
    // physical key even when the target's active layout differs from ours.
    input.ki.wScan = (WORD)event->scan_code;
    input.ki.wVk = 0; // Ignored when KEYEVENTF_SCANCODE is set.
    flags |= KEYEVENTF_SCANCODE;
    if (inject_win_scancode_is_extended((uint16_t)event->scan_code)) {
      flags |= KEYEVENTF_EXTENDEDKEY;
    }
  } else {
    // Fall back to the virtual key; the OS derives the scancode + extended bit.
    input.ki.wVk = (WORD)event->key_code;
    input.ki.wScan = 0;
  }

  if (event->action == MINIAV_KEY_ACTION_UP) {
    flags |= KEYEVENTF_KEYUP;
  }
  input.ki.dwFlags = flags;

  UINT sent = SendInput(1, &input, sizeof(INPUT));
  if (sent != 1) {
    // 0 == blocked (commonly UIPI) or invalid; treat as a system-call failure.
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Inject(win): SendInput(keyboard) injected %u/1 (GetLastError "
               "%lu). If targeting an elevated/secure window this is UIPI "
               "blocking the injection.",
               sent, GetLastError());
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  return MINIAV_SUCCESS;
}

// --- Ops: mouse injection ---

// Map a MiniAV button → the SendInput down/up flag + XBUTTON mouseData. Returns
// false for MINIAV_MOUSE_BUTTON_NONE (nothing to inject).
static bool inject_win_map_button(MiniAVMouseButton button, bool is_down,
                                  DWORD *out_flag, DWORD *out_mouse_data) {
  *out_mouse_data = 0;
  switch (button) {
  case MINIAV_MOUSE_BUTTON_LEFT:
    *out_flag = is_down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
    return true;
  case MINIAV_MOUSE_BUTTON_RIGHT:
    *out_flag = is_down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
    return true;
  case MINIAV_MOUSE_BUTTON_MIDDLE:
    *out_flag = is_down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
    return true;
  case MINIAV_MOUSE_BUTTON_X1:
    *out_flag = is_down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
    *out_mouse_data = XBUTTON1;
    return true;
  case MINIAV_MOUSE_BUTTON_X2:
    *out_flag = is_down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
    *out_mouse_data = XBUTTON2;
    return true;
  case MINIAV_MOUSE_BUTTON_NONE:
  default:
    return false;
  }
}

static MiniAVResultCode
inject_win_inject_mouse(MiniAVInjectContext *ctx,
                        const MiniAVMouseEvent *event) {
  if (!ctx || !ctx->platform_ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  // Up to two INPUT records: WHEEL can emit a vertical + a horizontal event in
  // one call, and that is the only action that ever fills the second slot.
  INPUT inputs[2];
  memset(inputs, 0, sizeof(inputs));
  UINT count = 0;

  switch (event->action) {
  case MINIAV_MOUSE_ACTION_MOVE: {
    inputs[0].type = INPUT_MOUSE;
    if (event->is_absolute) {
      // Normalize the absolute screen point to the 0..65535 grid SendInput
      // expects, spanning the ENTIRE virtual desktop (all monitors) so multi-
      // monitor absolute moves land on the right display. MOUSEEVENTF_VIRTUALDESK
      // makes the normalized coords virtual-desktop-relative.
      int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
      int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
      int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
      int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
      // Guard against the (pathological) zero-size metric before dividing.
      if (vw <= 0)
        vw = GetSystemMetrics(SM_CXSCREEN);
      if (vh <= 0)
        vh = GetSystemMetrics(SM_CYSCREEN);
      if (vw <= 0)
        vw = 1;
      if (vh <= 0)
        vh = 1;

      // Offset into the virtual desktop, then scale. Use 64-bit intermediates
      // and the (dim-1) span so the rightmost/bottommost pixel maps to 65535.
      long long rel_x = (long long)event->x - vx;
      long long rel_y = (long long)event->y - vy;
      long long denom_x = (vw > 1) ? (vw - 1) : 1;
      long long denom_y = (vh > 1) ? (vh - 1) : 1;
      long long nx = (rel_x * 65535 + denom_x / 2) / denom_x;
      long long ny = (rel_y * 65535 + denom_y / 2) / denom_y;
      if (nx < 0)
        nx = 0;
      else if (nx > 65535)
        nx = 65535;
      if (ny < 0)
        ny = 0;
      else if (ny > 65535)
        ny = 65535;

      inputs[0].mi.dx = (LONG)nx;
      inputs[0].mi.dy = (LONG)ny;
      inputs[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                             MOUSEEVENTF_VIRTUALDESK;
    } else {
      // Relative move by the captured deltas.
      inputs[0].mi.dx = (LONG)event->delta_x;
      inputs[0].mi.dy = (LONG)event->delta_y;
      inputs[0].mi.dwFlags = MOUSEEVENTF_MOVE;
    }
    count = 1;
    break;
  }

  case MINIAV_MOUSE_ACTION_BUTTON_DOWN:
  case MINIAV_MOUSE_ACTION_BUTTON_UP: {
    DWORD flag = 0, mdata = 0;
    bool is_down = (event->action == MINIAV_MOUSE_ACTION_BUTTON_DOWN);
    if (!inject_win_map_button(event->button, is_down, &flag, &mdata)) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "Inject(win): mouse button event with no injectable button "
                 "(button=%d) — ignoring.",
                 event->button);
      return MINIAV_ERROR_INVALID_ARG;
    }
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = flag;
    inputs[0].mi.mouseData = mdata; // XBUTTON1/2 for X buttons, else 0.
    count = 1;
    break;
  }

  case MINIAV_MOUSE_ACTION_WHEEL: {
    // Vertical wheel. wheel_delta is int32 (already in WHEEL_DELTA==120 units as
    // captured); mouseData is a DWORD but the wheel field is interpreted as a
    // SIGNED value by the OS, so a negative (scroll-down/left) delta must be
    // carried as its two's-complement bit pattern. Casting int32 → DWORD does
    // exactly that on this platform, so we cast through (DWORD) deliberately.
    if (event->wheel_delta != 0) {
      inputs[count].type = INPUT_MOUSE;
      inputs[count].mi.dwFlags = MOUSEEVENTF_WHEEL;
      inputs[count].mi.mouseData = (DWORD)event->wheel_delta;
      count++;
    }
    // Horizontal wheel, emitted as a second input when present.
    if (event->wheel_delta_x != 0) {
      inputs[count].type = INPUT_MOUSE;
      inputs[count].mi.dwFlags = MOUSEEVENTF_HWHEEL;
      inputs[count].mi.mouseData = (DWORD)event->wheel_delta_x;
      count++;
    }
    if (count == 0) {
      // A WHEEL action carrying neither delta is a no-op, not an error.
      return MINIAV_SUCCESS;
    }
    break;
  }

  default:
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Inject(win): unsupported mouse action %d — ignoring.",
               event->action);
    return MINIAV_ERROR_INVALID_ARG;
  }

  UINT sent = SendInput(count, inputs, sizeof(INPUT));
  if (sent != count) {
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "Inject(win): SendInput(mouse) injected %u/%u (GetLastError "
               "%lu). A short count usually means UIPI blocked injection into a "
               "higher-integrity target.",
               sent, count, GetLastError());
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  return MINIAV_SUCCESS;
}

// --- Ops table and init ---

const InjectContextInternalOps g_inject_ops_win = {
    .init_platform = inject_win_init_platform,
    .destroy_platform = inject_win_destroy_platform,
    .configure = inject_win_configure,
    .inject_keyboard = inject_win_inject_keyboard,
    .inject_mouse = inject_win_inject_mouse,
};

MiniAVResultCode
miniav_inject_context_platform_init_windows(MiniAVInjectContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }

  InjectPlatformWin *plat =
      (InjectPlatformWin *)miniav_calloc(1, sizeof(InjectPlatformWin));
  if (!plat) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "Inject(win): failed to allocate platform context.");
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }

  ctx->platform_ctx = plat;
  ctx->ops = &g_inject_ops_win;
  // SendInput needs no device/permission setup, so selection succeeds outright.
  return MINIAV_SUCCESS;
}
