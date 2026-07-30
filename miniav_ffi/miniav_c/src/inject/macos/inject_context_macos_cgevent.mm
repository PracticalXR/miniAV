// macOS input-injection backend.
//
// The sink twin of the CGEventTap capture backend: it REPLAYS synthetic
// keyboard/mouse events onto the local machine via CGEventPost, so a captured
// MiniAVKeyboardEvent / MiniAVMouseEvent can be injected verbatim. Injection is
// SYNCHRONOUS — every Inject_* call builds a CGEvent, posts it, and releases it
// before returning; there is no worker thread or callback.
//
// Manual retain/release (NO ARC). The only long-lived Core Foundation object is
// a single CGEventSourceRef created in init_platform and released in
// destroy_platform. Every per-event CGEvent created here (CGEventCreate*
// returns a +1 reference) is balanced with exactly one CFRelease on every path.
//
// Permissions: posting synthetic events requires the process to be trusted for
// Accessibility (System Settings > Privacy & Security > Accessibility). miniAV
// never PROMPTS — configure checks AXIsProcessTrusted() WITHOUT prompting and
// returns MINIAV_ERROR_PERMISSION_DENIED (with an actionable log) when the
// process is not trusted.
//
// Coordinate space: capture reports absolute pointer coordinates with a
// top-left origin (CGEventGetLocation), which is exactly CG's global display
// coordinate space, so injected absolute MOVE/BUTTON coordinates are used
// as-is (no y-flip).

#include "inject_context_macos_cgevent.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_utils.h" // miniav_calloc / miniav_free

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

// --- Platform-specific context ----------------------------------------------
typedef struct InjectPlatformMac {
  MiniAVInjectContext *parent_ctx;
  // Single shared HID event source, created once in init_platform. Posting
  // through one source keeps modifier/click state coherent across events (the
  // same reason the capture side uses one tap). Released in destroy_platform.
  CGEventSourceRef event_source;
  // Shadow cursor position for RELATIVE moves. CGEventPost is asynchronous, so
  // reading mac_current_pointer() for every relative delta reads a location the
  // window server has not yet advanced — a burst of deltas posted faster than
  // the hardware pointer updates all anchor on the SAME stale base and collapse
  // into one small move. We instead accumulate the intended position here: a
  // relative move seeds this from the real pointer once (when !shadow_valid),
  // then advances it by each delta; an absolute move overwrites it so a
  // following relative move continues from the correct place. Plain C state —
  // no Core Foundation object, so no retain/release is involved.
  CGPoint shadow_pos;
  bool shadow_valid;
} InjectPlatformMac;

// --- Helpers ----------------------------------------------------------------

// Query the current global pointer location (top-left origin). Used to anchor
// button/wheel events and to resolve relative (delta) moves. Returns a
// CGEventGetLocation on a throwaway null event, which reports the current
// hardware pointer position.
static CGPoint mac_current_pointer(void) {
  CGPoint p = CGPointZero;
  CGEventRef snapshot = CGEventCreate(NULL); // +1
  if (snapshot) {
    p = CGEventGetLocation(snapshot);
    CFRelease(snapshot);
  }
  return p;
}

// Map a MiniAVMouseButton to the CG button-down/up event pair + CGMouseButton
// number. Returns false for buttons that have no CG mapping. `is_down`
// selects the down (true) or up (false) event type.
static bool mac_map_mouse_button(MiniAVMouseButton button, bool is_down,
                                 CGEventType *type_out,
                                 CGMouseButton *cg_button_out) {
  switch (button) {
  case MINIAV_MOUSE_BUTTON_LEFT:
    *type_out = is_down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
    *cg_button_out = kCGMouseButtonLeft;
    return true;
  case MINIAV_MOUSE_BUTTON_RIGHT:
    *type_out = is_down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
    *cg_button_out = kCGMouseButtonRight;
    return true;
  case MINIAV_MOUSE_BUTTON_MIDDLE:
    *type_out = is_down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
    *cg_button_out = kCGMouseButtonCenter; // button number 2
    return true;
  case MINIAV_MOUSE_BUTTON_X1:
    // Other buttons use the OtherMouse event pair with the raw button number.
    // 3 = X1, 4 = X2 (matches the capture side's kCGMouseEventButtonNumber
    // mapping in input_context_macos_cgtap.mm).
    *type_out = is_down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
    *cg_button_out = (CGMouseButton)3;
    return true;
  case MINIAV_MOUSE_BUTTON_X2:
    *type_out = is_down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
    *cg_button_out = (CGMouseButton)4;
    return true;
  case MINIAV_MOUSE_BUTTON_NONE:
  default:
    return false;
  }
}

// --- Ops implementation -----------------------------------------------------

static MiniAVResultCode mac_init_platform(MiniAVInjectContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  InjectPlatformMac *plat =
      (InjectPlatformMac *)miniav_calloc(1, sizeof(InjectPlatformMac));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  plat->parent_ctx = ctx;

  // One HID-system event source for the lifetime of the context. This does not
  // itself require Accessibility (creating the source succeeds regardless); the
  // permission gate is on POSTING, which we surface in configure via
  // AXIsProcessTrusted so the caller learns about it before injecting.
  plat->event_source =
      CGEventSourceCreate(kCGEventSourceStateHIDSystemState); // +1
  if (!plat->event_source) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGEvent: Failed to create HID event source for injection.");
    miniav_free(plat);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  ctx->platform_ctx = plat;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "CGEvent: Injection platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_destroy_platform(MiniAVInjectContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  InjectPlatformMac *plat = (InjectPlatformMac *)ctx->platform_ctx;

  if (plat->event_source) {
    CFRelease(plat->event_source); // balance CGEventSourceCreate
    plat->event_source = NULL;
  }

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG,
             "CGEvent: Injection platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_configure(MiniAVInjectContext *ctx,
                                      uint32_t input_types) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  (void)input_types; // macOS posts to the shared HID source regardless of the
                     // requested keyboard/mouse mix; nothing to pre-allocate
                     // per type (unlike Linux uinput). Kept for API symmetry.

  // Permission gate — WITHOUT prompting. AXIsProcessTrustedWithOptions with
  // kAXTrustedCheckOptionPrompt=false is the non-prompting form; passing a NULL
  // options dictionary also does not prompt, and is equivalent to the
  // deprecated AXIsProcessTrusted(). miniAV never triggers the system prompt —
  // the app must request Accessibility approval itself, then configure.
  Boolean trusted = AXIsProcessTrustedWithOptions(NULL);
  if (!trusted) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGEvent: Injection requires Accessibility permission. Grant it "
               "in System Settings > Privacy & Security > Accessibility for "
               "this application, then retry. (miniAV does not prompt.)");
    return MINIAV_ERROR_PERMISSION_DENIED;
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "CGEvent: Injection configured (Accessibility granted).");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_inject_keyboard(MiniAVInjectContext *ctx,
                                            const MiniAVKeyboardEvent *event) {
  if (!ctx || !ctx->platform_ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  InjectPlatformMac *plat = (InjectPlatformMac *)ctx->platform_ctx;

  bool key_down = (event->action == MINIAV_KEY_ACTION_DOWN);
  // key_code is the macOS virtual keycode (same space the capture side reports
  // via kCGKeyboardEventKeycode).
  CGEventRef e = CGEventCreateKeyboardEvent(
      plat->event_source, (CGKeyCode)event->key_code, key_down); // +1
  if (!e) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGEvent: Failed to create keyboard event (keycode=%u).",
               event->key_code);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  CGEventPost(kCGHIDEventTap, e);
  CFRelease(e);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_inject_mouse(MiniAVInjectContext *ctx,
                                         const MiniAVMouseEvent *event) {
  if (!ctx || !ctx->platform_ctx || !event) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  InjectPlatformMac *plat = (InjectPlatformMac *)ctx->platform_ctx;

  switch (event->action) {
  case MINIAV_MOUSE_ACTION_MOVE: {
    CGPoint pt;
    if (event->is_absolute) {
      // Absolute coords in CG global display space (top-left origin) — used
      // as-is (see coordinate-space note at the top of the file).
      pt = CGPointMake((CGFloat)event->x, (CGFloat)event->y);
      // Anchor the shadow to this known-good position so a following relative
      // move continues from the correct place.
      plat->shadow_pos = pt;
      plat->shadow_valid = true;
    } else {
      // Relative move: accumulate against the shadow cursor, NOT a fresh
      // mac_current_pointer() read. CGEventPost is asynchronous, so re-reading
      // the hardware pointer for every delta in a burst returns the same stale
      // base and the deltas collapse into one small move. Seed the shadow from
      // the real pointer only when it is not yet valid, then advance it by the
      // delta and keep the result as the new base.
      if (!plat->shadow_valid) {
        plat->shadow_pos = mac_current_pointer();
        plat->shadow_valid = true;
      }
      pt = CGPointMake(plat->shadow_pos.x + (CGFloat)event->delta_x,
                       plat->shadow_pos.y + (CGFloat)event->delta_y);
      plat->shadow_pos = pt;
    }
    CGEventRef e = CGEventCreateMouseEvent(plat->event_source,
                                           kCGEventMouseMoved, pt,
                                           kCGMouseButtonLeft); // +1
    if (!e) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "CGEvent: Failed to create mouse-move event.");
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return MINIAV_SUCCESS;
  }

  case MINIAV_MOUSE_ACTION_BUTTON_DOWN:
  case MINIAV_MOUSE_ACTION_BUTTON_UP: {
    bool is_down = (event->action == MINIAV_MOUSE_ACTION_BUTTON_DOWN);
    CGEventType type;
    CGMouseButton cg_button;
    if (!mac_map_mouse_button(event->button, is_down, &type, &cg_button)) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "CGEvent: Unsupported mouse button %d for injection; "
                 "ignoring.",
                 (int)event->button);
      return MINIAV_ERROR_INVALID_ARG;
    }
    // Anchor the button event at the current pointer location. (v1 posts a
    // plain down/up; a drag is just a down, moves, up sequence from the
    // caller — no separate drag event type is emitted.)
    CGPoint pt = mac_current_pointer();
    CGEventRef e =
        CGEventCreateMouseEvent(plat->event_source, type, pt, cg_button); // +1
    if (!e) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "CGEvent: Failed to create mouse-button event.");
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return MINIAV_SUCCESS;
  }

  case MINIAV_MOUSE_ACTION_WHEEL: {
    // CGEventCreateScrollWheelEvent(source, unit, wheelCount, w1, w2, w3):
    //   w1 = vertical axis (Axis1): CG positive = scroll content UP/away.
    //   w2 = horizontal axis (Axis2): CG positive = scroll content LEFT.
    //
    // Sign convention (see MiniAVMouseEvent doc + capture backend):
    //   * wheel_delta   is documented "+ = up/away" and the capture side stores
    //     kCGScrollWheelEventDeltaAxis1 into it UNCHANGED, so it already matches
    //     CG Axis1 — passed straight through, NO flip.
    //   * wheel_delta_x is documented "+ = right", but CG Axis2 positive = LEFT.
    //     The capture side NEGATES Axis2 into wheel_delta_x so that "+ = right"
    //     holds; we negate again here so a captured horizontal scroll injects in
    //     the same physical direction it was captured (round-trip lossless).
    int32_t w1 = event->wheel_delta;      // vertical, no flip
    int32_t w2 = -(event->wheel_delta_x); // horizontal: "+ = right" -> CG left-positive
    CGEventRef e = CGEventCreateScrollWheelEvent(
        plat->event_source, kCGScrollEventUnitLine, 2 /*wheelCount*/,
        (int32_t)w1, (int32_t)w2); // +1
    if (!e) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "CGEvent: Failed to create scroll-wheel event.");
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return MINIAV_SUCCESS;
  }

  default:
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "CGEvent: Unknown mouse action %d for injection.",
               (int)event->action);
    return MINIAV_ERROR_INVALID_ARG;
  }
}

// --- Ops table + init -------------------------------------------------------

const InjectContextInternalOps g_inject_ops_macos = {
    .init_platform = mac_init_platform,
    .destroy_platform = mac_destroy_platform,
    .configure = mac_configure,
    .inject_keyboard = mac_inject_keyboard,
    .inject_mouse = mac_inject_mouse,
};

MiniAVResultCode
miniav_inject_context_platform_init_macos(MiniAVInjectContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  // Selection phase: just publish the ops. Allocation + the event source happen
  // in init_platform (called by inject_api.c right after selection succeeds),
  // mirroring the input-capture backend.
  ctx->ops = &g_inject_ops_macos;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CGEvent: macOS injection backend selected.");
  return MINIAV_SUCCESS;
}
