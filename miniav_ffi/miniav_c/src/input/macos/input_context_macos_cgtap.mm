// macOS input-capture backend.
//
//  * Keyboard + mouse: a passive (listen-only) CGEventTap installed on a
//    dedicated pthread that runs its own CFRunLoop. The tap only OBSERVES
//    events; it never modifies or swallows them (kCGEventTapOptionListenOnly).
//  * Gamepad: the GameController framework (GCController). We poll each
//    connected controller's extendedGamepad snapshot at gamepad_poll_hz on the
//    same worker thread using absolute-deadline pacing (matching the Windows
//    XInput polling model), and listen for connect/disconnect notifications.
//
// Manual retain/release (NO ARC). Every CFMachPort / CFRunLoopSource / NS
// observer created here is released or invalidated exactly once.
//
// Threading model (mirrors the good parts of the Windows backend, avoids its
// anti-patterns — no global-context hijack for routing beyond the tap refcon,
// no TerminateThread-equivalent, no relative-sleep pacing):
//   start_capture spawns one worker pthread. That thread:
//     1. Creates the CGEventTap + CFRunLoopSource and adds them to ITS runloop.
//     2. Registers GC connect/disconnect observers.
//     3. Schedules a repeating CFRunLoopTimer at gamepad_poll_hz for polling.
//     4. Runs CFRunLoopRun() until stop_capture calls CFRunLoopStop().
//   On exit it tears everything down and signals a dispatch_semaphore so
//   stop_capture can join with a BOUNDED wait.

#include "input_context_macos_cgtap.h"
#include "../../../include/miniav_types.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <GameController/GameController.h>

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h> // clock_gettime / CLOCK_REALTIME for the runloop cond wait

#define MINIAV_INPUT_MAX_GAMEPADS 8

// --- Gamepad button bitmask layout ------------------------------------------
// The MiniAVGamepadEvent.buttons field is a 16-bit bitmask. The Windows
// backend forwards the raw XInput wButtons layout; there is no cross-platform
// canonical layout defined by the API, so we adopt the XInput bit positions
// here for parity (a consumer that already understands the Windows event sees
// the same bits). Documented so the mapping is auditable.
enum {
  MINIAV_GP_DPAD_UP        = 0x0001,
  MINIAV_GP_DPAD_DOWN      = 0x0002,
  MINIAV_GP_DPAD_LEFT      = 0x0004,
  MINIAV_GP_DPAD_RIGHT     = 0x0008,
  MINIAV_GP_START          = 0x0010, // menu / "+"
  MINIAV_GP_BACK           = 0x0020, // options / "-"
  MINIAV_GP_LEFT_THUMB     = 0x0040, // left thumbstick click
  MINIAV_GP_RIGHT_THUMB    = 0x0080, // right thumbstick click
  MINIAV_GP_LEFT_SHOULDER  = 0x0100,
  MINIAV_GP_RIGHT_SHOULDER = 0x0200,
  MINIAV_GP_BUTTON_A       = 0x1000,
  MINIAV_GP_BUTTON_B       = 0x2000,
  MINIAV_GP_BUTTON_X       = 0x4000,
  MINIAV_GP_BUTTON_Y       = 0x8000,
};

// --- Platform-specific context ----------------------------------------------
typedef struct InputPlatformMac {
  MiniAVInputContext *parent_ctx;

  // Worker thread + lifecycle.
  pthread_t worker_thread;
  bool worker_started;
  atomic_bool stop_requested;
  // Signalled by the worker exactly once when it returns. stop_capture waits
  // on it with a bounded timeout (there is no pthread_timedjoin_np on macOS).
  dispatch_semaphore_t worker_exited_sem;
  // Set true when start_capture requested stop but the bounded join TIMED OUT.
  // In that case the worker (and everything it owns) is deliberately leaked
  // rather than force-cancelled.
  bool worker_leaked;

  // The worker thread's runloop, published once the worker is up so stop can
  // CFRunLoopStop it. Guarded by runloop_mutex + runloop_ready.
  CFRunLoopRef worker_runloop;
  pthread_mutex_t runloop_mutex;
  pthread_cond_t runloop_ready_cond;
  bool runloop_published;

  // Event tap (owned by worker thread).
  CFMachPortRef event_tap;
  CFRunLoopSourceRef event_tap_source;
  CFRunLoopTimerRef gamepad_timer;

  // GC connect/disconnect observers (owned by worker thread).
  id gc_connect_observer;
  id gc_disconnect_observer;

  // Configuration snapshot (written by configure, read by worker).
  uint32_t input_types;       // the CONFIGURED set — never mutated by start
  uint32_t active_input_types; // effective set for THIS run (KM may be dropped
                               // on a permission failure); the worker reads this
  uint32_t mouse_throttle_hz;
  uint32_t gamepad_poll_hz;

  MiniAVKeyboardCallback keyboard_cb;
  MiniAVMouseCallback mouse_cb;
  MiniAVGamepadCallback gamepad_cb;
  void *user_data;

  // Mouse-move throttle state (absolute-time drop gate). Both in microseconds
  // on the miniav_get_time_us() epoch. throttle_interval_us == 0 => no gate.
  uint64_t throttle_interval_us;
  uint64_t last_mouse_move_us;

  // Gamepad change-detection state, keyed by array slot (playerIndex is often
  // unset/-1, so we use the slot index as the stable gamepad_index).
  uint16_t prev_buttons[MINIAV_INPUT_MAX_GAMEPADS];
  int16_t prev_lx[MINIAV_INPUT_MAX_GAMEPADS];
  int16_t prev_ly[MINIAV_INPUT_MAX_GAMEPADS];
  int16_t prev_rx[MINIAV_INPUT_MAX_GAMEPADS];
  int16_t prev_ry[MINIAV_INPUT_MAX_GAMEPADS];
  uint8_t prev_lt[MINIAV_INPUT_MAX_GAMEPADS];
  uint8_t prev_rt[MINIAV_INPUT_MAX_GAMEPADS];
  bool slot_was_connected[MINIAV_INPUT_MAX_GAMEPADS];
} InputPlatformMac;

// --- Helpers ----------------------------------------------------------------

static inline int16_t mac_axis_to_i16(float v) {
  // GameController axes are in [-1, 1]. Scale to the int16 range used by the
  // event struct, clamping to avoid overflow at the endpoints.
  if (v > 1.0f) v = 1.0f;
  if (v < -1.0f) v = -1.0f;
  float scaled = v * 32767.0f;
  if (scaled > 32767.0f) scaled = 32767.0f;
  if (scaled < -32768.0f) scaled = -32768.0f;
  return (int16_t)scaled;
}

static inline uint8_t mac_trigger_to_u8(float v) {
  // Triggers are in [0, 1].
  if (v > 1.0f) v = 1.0f;
  if (v < 0.0f) v = 0.0f;
  return (uint8_t)(v * 255.0f);
}

// Look up (or lazily assign) a stable slot index for a GCController. We key on
// the array position because GCController.playerIndex is frequently
// GCControllerPlayerIndexUnset (-1). controllers_snapshot must be the current
// [GCController controllers] array.
static NSInteger mac_slot_for_controller(NSArray<GCController *> *controllers,
                                         GCController *ctrl) {
  NSUInteger idx = [controllers indexOfObjectIdenticalTo:ctrl];
  if (idx == NSNotFound) return -1;
  if (idx >= MINIAV_INPUT_MAX_GAMEPADS) return -1;
  return (NSInteger)idx;
}

// --- CGEventTap callback ----------------------------------------------------

static CGEventRef mac_event_tap_callback(CGEventTapProxy proxy,
                                         CGEventType type, CGEventRef event,
                                         void *refcon) {
  MINIAV_UNUSED(proxy);
  InputPlatformMac *plat = (InputPlatformMac *)refcon;
  if (!plat) {
    return event;
  }

  // The system can disable a tap that is too slow or when input monitoring is
  // toggled. Re-enable it and pass the event through untouched.
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    if (plat->event_tap) {
      CGEventTapEnable(plat->event_tap, true);
    }
    return event;
  }

  uint64_t ts = miniav_get_time_us();

  switch (type) {
  case kCGEventKeyDown:
  case kCGEventKeyUp:
  case kCGEventFlagsChanged: {
    if (!plat->keyboard_cb) {
      break;
    }
    MiniAVKeyboardEvent kev;
    memset(&kev, 0, sizeof(kev));
    kev.timestamp_us = ts;
    int64_t keycode =
        CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    kev.key_code = (uint32_t)keycode; // macOS virtual keycode
    kev.scan_code = (uint32_t)keycode; // no separate HW scancode exposed here
    if (type == kCGEventKeyDown) {
      kev.action = MINIAV_KEY_ACTION_DOWN;
    } else if (type == kCGEventKeyUp) {
      kev.action = MINIAV_KEY_ACTION_UP;
    } else {
      // FlagsChanged = a modifier key transition. CGEventTap does not tell us
      // directly whether the modifier went down or up; we report it as DOWN.
      // (Consumers wanting precise modifier up/down must diff the flag mask.)
      kev.action = MINIAV_KEY_ACTION_DOWN;
    }
    MINIAV_SAFE_DISPATCH(plat->keyboard_cb(&kev, plat->user_data));
    break;
  }

  case kCGEventMouseMoved:
  case kCGEventLeftMouseDragged:
  case kCGEventRightMouseDragged:
  case kCGEventOtherMouseDragged: {
    if (!plat->mouse_cb) {
      break;
    }
    // Absolute-time drop gate for high-rate move/drag events.
    if (plat->throttle_interval_us > 0) {
      if (ts - plat->last_mouse_move_us < plat->throttle_interval_us) {
        break;
      }
      plat->last_mouse_move_us = ts;
    }
    MiniAVMouseEvent mev;
    memset(&mev, 0, sizeof(mev));
    mev.timestamp_us = ts;
    CGPoint loc = CGEventGetLocation(event);
    mev.x = (int32_t)loc.x;
    mev.y = (int32_t)loc.y;
    mev.delta_x = (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
    mev.delta_y = (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
    mev.action = MINIAV_MOUSE_ACTION_MOVE;
    mev.button = MINIAV_MOUSE_BUTTON_NONE;
    mev.is_absolute = true; // x/y are absolute (CGEventGetLocation)
    MINIAV_SAFE_DISPATCH(plat->mouse_cb(&mev, plat->user_data));
    break;
  }

  case kCGEventLeftMouseDown:
  case kCGEventLeftMouseUp:
  case kCGEventRightMouseDown:
  case kCGEventRightMouseUp:
  case kCGEventOtherMouseDown:
  case kCGEventOtherMouseUp: {
    if (!plat->mouse_cb) {
      break;
    }
    MiniAVMouseEvent mev;
    memset(&mev, 0, sizeof(mev));
    mev.timestamp_us = ts;
    CGPoint loc = CGEventGetLocation(event);
    mev.x = (int32_t)loc.x;
    mev.y = (int32_t)loc.y;
    mev.is_absolute = true; // x/y are absolute (CGEventGetLocation)

    switch (type) {
    case kCGEventLeftMouseDown:
      mev.action = MINIAV_MOUSE_ACTION_BUTTON_DOWN;
      mev.button = MINIAV_MOUSE_BUTTON_LEFT;
      break;
    case kCGEventLeftMouseUp:
      mev.action = MINIAV_MOUSE_ACTION_BUTTON_UP;
      mev.button = MINIAV_MOUSE_BUTTON_LEFT;
      break;
    case kCGEventRightMouseDown:
      mev.action = MINIAV_MOUSE_ACTION_BUTTON_DOWN;
      mev.button = MINIAV_MOUSE_BUTTON_RIGHT;
      break;
    case kCGEventRightMouseUp:
      mev.action = MINIAV_MOUSE_ACTION_BUTTON_UP;
      mev.button = MINIAV_MOUSE_BUTTON_RIGHT;
      break;
    default: {
      // Other buttons: kCGMouseEventButtonNumber 2 = middle, 3 = X1, 4 = X2.
      int64_t btn =
          CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
      MiniAVMouseButton mb = MINIAV_MOUSE_BUTTON_MIDDLE;
      if (btn == 2) mb = MINIAV_MOUSE_BUTTON_MIDDLE;
      else if (btn == 3) mb = MINIAV_MOUSE_BUTTON_X1;
      else if (btn == 4) mb = MINIAV_MOUSE_BUTTON_X2;
      else mb = MINIAV_MOUSE_BUTTON_MIDDLE;
      mev.button = mb;
      mev.action = (type == kCGEventOtherMouseDown)
                       ? MINIAV_MOUSE_ACTION_BUTTON_DOWN
                       : MINIAV_MOUSE_ACTION_BUTTON_UP;
      break;
    }
    }
    MINIAV_SAFE_DISPATCH(plat->mouse_cb(&mev, plat->user_data));
    break;
  }

  case kCGEventScrollWheel: {
    if (!plat->mouse_cb) {
      break;
    }
    MiniAVMouseEvent mev;
    memset(&mev, 0, sizeof(mev));
    mev.timestamp_us = ts;
    CGPoint loc = CGEventGetLocation(event);
    mev.x = (int32_t)loc.x;
    mev.y = (int32_t)loc.y;
    mev.action = MINIAV_MOUSE_ACTION_WHEEL;
    mev.button = MINIAV_MOUSE_BUTTON_NONE;
    // Vertical: Axis1. CG positive = up/away, which matches the documented
    // MiniAVMouseEvent.wheel_delta "+ = up/away" — stored UNCHANGED.
    mev.wheel_delta = (int32_t)CGEventGetIntegerValueField(
        event, kCGScrollWheelEventDeltaAxis1);
    // Horizontal: Axis2. CG positive = scroll LEFT, but wheel_delta_x is
    // documented "+ = right", so NEGATE. (The injection backend negates again,
    // making a capture -> inject round-trip preserve physical direction.)
    mev.wheel_delta_x = -(int32_t)CGEventGetIntegerValueField(
        event, kCGScrollWheelEventDeltaAxis2);
    mev.is_absolute = true; // capture reports absolute x/y
    MINIAV_SAFE_DISPATCH(plat->mouse_cb(&mev, plat->user_data));
    break;
  }

  default:
    break;
  }

  // Passive tap: always pass the event through unmodified.
  return event;
}

// --- Gamepad polling (CFRunLoopTimer on the worker thread) ------------------

static void mac_emit_gamepad_slot(InputPlatformMac *plat, NSInteger slot,
                                  GCController *ctrl, uint64_t ts) {
  if (slot < 0 || slot >= MINIAV_INPUT_MAX_GAMEPADS) {
    return;
  }
  GCExtendedGamepad *gp = ctrl.extendedGamepad;
  if (!gp) {
    // No extended profile (e.g. a plain remote). Treat as connected but with
    // no usable state; emit a connected event once.
    if (!plat->slot_was_connected[(NSUInteger)slot]) {
      MiniAVGamepadEvent ev;
      memset(&ev, 0, sizeof(ev));
      ev.timestamp_us = ts;
      ev.gamepad_index = (uint32_t)slot;
      ev.connected = true;
      plat->slot_was_connected[(NSUInteger)slot] = true;
      if (plat->gamepad_cb) {
        MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
      }
    }
    return;
  }

  uint16_t buttons = 0;
  if (gp.buttonA.pressed) buttons |= MINIAV_GP_BUTTON_A;
  if (gp.buttonB.pressed) buttons |= MINIAV_GP_BUTTON_B;
  if (gp.buttonX.pressed) buttons |= MINIAV_GP_BUTTON_X;
  if (gp.buttonY.pressed) buttons |= MINIAV_GP_BUTTON_Y;
  if (gp.leftShoulder.pressed) buttons |= MINIAV_GP_LEFT_SHOULDER;
  if (gp.rightShoulder.pressed) buttons |= MINIAV_GP_RIGHT_SHOULDER;
  if (gp.dpad.up.pressed) buttons |= MINIAV_GP_DPAD_UP;
  if (gp.dpad.down.pressed) buttons |= MINIAV_GP_DPAD_DOWN;
  if (gp.dpad.left.pressed) buttons |= MINIAV_GP_DPAD_LEFT;
  if (gp.dpad.right.pressed) buttons |= MINIAV_GP_DPAD_RIGHT;
  // buttonMenu (Start/"+"), buttonOptions (Back/"-") and the thumbstick-click
  // buttons were added to GCExtendedGamepad in macOS 10.14.1/10.15. Guard by
  // availability so a low deployment target still compiles; buttonOptions and
  // the thumbstick buttons are also nullable at runtime on controllers that
  // lack them.
  if (@available(macOS 10.15, *)) {
    if (gp.buttonMenu.pressed) buttons |= MINIAV_GP_START;
    if (gp.buttonOptions && gp.buttonOptions.pressed) buttons |= MINIAV_GP_BACK;
    if (gp.leftThumbstickButton && gp.leftThumbstickButton.pressed)
      buttons |= MINIAV_GP_LEFT_THUMB;
    if (gp.rightThumbstickButton && gp.rightThumbstickButton.pressed)
      buttons |= MINIAV_GP_RIGHT_THUMB;
  }

  int16_t lx = mac_axis_to_i16(gp.leftThumbstick.xAxis.value);
  int16_t ly = mac_axis_to_i16(gp.leftThumbstick.yAxis.value);
  int16_t rx = mac_axis_to_i16(gp.rightThumbstick.xAxis.value);
  int16_t ry = mac_axis_to_i16(gp.rightThumbstick.yAxis.value);
  uint8_t lt = mac_trigger_to_u8(gp.leftTrigger.value);
  uint8_t rt = mac_trigger_to_u8(gp.rightTrigger.value);

  NSUInteger s = (NSUInteger)slot;
  bool was_connected = plat->slot_was_connected[s];
  bool changed = (!was_connected) || buttons != plat->prev_buttons[s] ||
                 lx != plat->prev_lx[s] || ly != plat->prev_ly[s] ||
                 rx != plat->prev_rx[s] || ry != plat->prev_ry[s] ||
                 lt != plat->prev_lt[s] || rt != plat->prev_rt[s];

  if (!changed) {
    return;
  }

  MiniAVGamepadEvent ev;
  memset(&ev, 0, sizeof(ev));
  ev.timestamp_us = ts;
  ev.gamepad_index = (uint32_t)slot;
  ev.connected = true;
  ev.buttons = buttons;
  ev.left_stick_x = lx;
  ev.left_stick_y = ly;
  ev.right_stick_x = rx;
  ev.right_stick_y = ry;
  ev.left_trigger = lt;
  ev.right_trigger = rt;

  plat->prev_buttons[s] = buttons;
  plat->prev_lx[s] = lx;
  plat->prev_ly[s] = ly;
  plat->prev_rx[s] = rx;
  plat->prev_ry[s] = ry;
  plat->prev_lt[s] = lt;
  plat->prev_rt[s] = rt;
  plat->slot_was_connected[s] = true;

  if (plat->gamepad_cb) {
    MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
  }
}

static void mac_gamepad_timer_callback(CFRunLoopTimerRef timer, void *info) {
  MINIAV_UNUSED(timer);
  InputPlatformMac *plat = (InputPlatformMac *)info;
  if (!plat || atomic_load(&plat->stop_requested)) {
    return;
  }

  @autoreleasepool {
    uint64_t ts = miniav_get_time_us();
    NSArray<GCController *> *controllers = [GCController controllers];

    // Track which slots are currently occupied so we can emit disconnect
    // events for slots that were connected last tick but are now empty. (The
    // disconnect notification also handles this, but a lost controller that
    // never fires the notification is still caught here.)
    bool present[MINIAV_INPUT_MAX_GAMEPADS] = {false};

    NSUInteger count = controllers.count;
    for (NSUInteger i = 0; i < count && i < MINIAV_INPUT_MAX_GAMEPADS; i++) {
      present[i] = true;
      mac_emit_gamepad_slot(plat, (NSInteger)i, controllers[i], ts);
    }

    for (NSUInteger s = 0; s < MINIAV_INPUT_MAX_GAMEPADS; s++) {
      if (plat->slot_was_connected[s] && !present[s]) {
        MiniAVGamepadEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.timestamp_us = ts;
        ev.gamepad_index = (uint32_t)s;
        ev.connected = false;
        plat->slot_was_connected[s] = false;
        plat->prev_buttons[s] = 0;
        plat->prev_lx[s] = plat->prev_ly[s] = 0;
        plat->prev_rx[s] = plat->prev_ry[s] = 0;
        plat->prev_lt[s] = plat->prev_rt[s] = 0;
        if (plat->gamepad_cb) {
          MINIAV_SAFE_DISPATCH(plat->gamepad_cb(&ev, plat->user_data));
        }
      }
    }
  }
}

// --- Worker thread ----------------------------------------------------------

static bool mac_worker_setup_event_tap(InputPlatformMac *plat) {
  CGEventMask mask =
      CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
      CGEventMaskBit(kCGEventFlagsChanged) |
      CGEventMaskBit(kCGEventMouseMoved) |
      CGEventMaskBit(kCGEventLeftMouseDown) |
      CGEventMaskBit(kCGEventLeftMouseUp) |
      CGEventMaskBit(kCGEventRightMouseDown) |
      CGEventMaskBit(kCGEventRightMouseUp) |
      CGEventMaskBit(kCGEventOtherMouseDown) |
      CGEventMaskBit(kCGEventOtherMouseUp) |
      CGEventMaskBit(kCGEventScrollWheel) |
      CGEventMaskBit(kCGEventLeftMouseDragged) |
      CGEventMaskBit(kCGEventRightMouseDragged) |
      CGEventMaskBit(kCGEventOtherMouseDragged);

  // Passive session-level tap: observe, never modify (ListenOnly).
  plat->event_tap = CGEventTapCreate(
      kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
      mask, mac_event_tap_callback, plat);

  if (!plat->event_tap) {
    // The only common cause is missing Accessibility / Input Monitoring
    // permission. There is no dedicated permission error code in
    // MiniAVResultCode, so callers get NOT_SUPPORTED; make the log actionable.
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: CGEventTapCreate returned NULL. Keyboard/mouse capture "
               "requires Accessibility (Input Monitoring) permission. Grant it "
               "in System Settings > Privacy & Security > Accessibility (and "
               "Input Monitoring) for this application, then restart it.");
    return false;
  }

  plat->event_tap_source =
      CFMachPortCreateRunLoopSource(kCFAllocatorDefault, plat->event_tap, 0);
  if (!plat->event_tap_source) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: Failed to create run-loop source for event tap.");
    CFMachPortInvalidate(plat->event_tap);
    CFRelease(plat->event_tap);
    plat->event_tap = NULL;
    return false;
  }

  CFRunLoopAddSource(CFRunLoopGetCurrent(), plat->event_tap_source,
                     kCFRunLoopCommonModes);
  CGEventTapEnable(plat->event_tap, true);
  miniav_log(MINIAV_LOG_LEVEL_INFO, "CGTap: Event tap installed (passive).");
  return true;
}

static void mac_worker_setup_gamepad(InputPlatformMac *plat) {
  // Register connect/disconnect observers. The connect handler resets the
  // per-slot state so a fresh controller re-emits its baseline; the disconnect
  // handler emits a connected=false event. Actual state polling is driven by
  // the CFRunLoopTimer below. Observers fire on the runloop of the thread that
  // registered them (this worker), because we pass its main queue equivalent.
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  // Deliver notifications on the current thread's runloop by using nil queue
  // (posts synchronously on the posting thread) — GameController posts on the
  // main thread, but our observers just log/reset small state and the timer
  // does the real work, so cross-thread posting is acceptable here. To keep
  // all mutation on the worker we do the reset inside the timer instead; the
  // observer blocks only log.
  plat->gc_connect_observer =
      [nc addObserverForName:GCControllerDidConnectNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    MINIAV_UNUSED(note);
                    miniav_log(MINIAV_LOG_LEVEL_INFO,
                               "CGTap: Gamepad connected.");
                  }];
  plat->gc_disconnect_observer =
      [nc addObserverForName:GCControllerDidDisconnectNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    MINIAV_UNUSED(note);
                    miniav_log(MINIAV_LOG_LEVEL_INFO,
                               "CGTap: Gamepad disconnected.");
                  }];
  // Retain the observer tokens (addObserverForName returns an autoreleased
  // object we must keep alive until removeObserver).
  [plat->gc_connect_observer retain];
  [plat->gc_disconnect_observer retain];

  uint32_t hz = plat->gamepad_poll_hz > 0 ? plat->gamepad_poll_hz : 60;
  if (hz > 250)
    hz = 250; // clamp: an unbounded rate would peg the worker on a ~0s timer
              // (mirrors the sane XInput poll cadence)
  CFTimeInterval interval = 1.0 / (double)hz;

  CFRunLoopTimerContext tctx;
  memset(&tctx, 0, sizeof(tctx));
  tctx.info = plat;
  // Absolute-deadline pacing: schedule the first fire one interval out and
  // repeat every `interval`. CFRunLoopTimer fires on an absolute schedule, so
  // it does not accumulate drift from callback duration the way a relative
  // Sleep(interval) loop does.
  plat->gamepad_timer = CFRunLoopTimerCreate(
      kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0,
      0, mac_gamepad_timer_callback, &tctx);
  if (plat->gamepad_timer) {
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), plat->gamepad_timer,
                      kCFRunLoopCommonModes);
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "CGTap: Gamepad polling started at ~%u Hz.", hz);
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: Failed to create gamepad poll timer.");
  }
}

static void mac_worker_teardown(InputPlatformMac *plat) {
  CFRunLoopRef rl = CFRunLoopGetCurrent();

  if (plat->gamepad_timer) {
    CFRunLoopRemoveTimer(rl, plat->gamepad_timer, kCFRunLoopCommonModes);
    CFRunLoopTimerInvalidate(plat->gamepad_timer);
    CFRelease(plat->gamepad_timer);
    plat->gamepad_timer = NULL;
  }

  if (plat->event_tap) {
    CGEventTapEnable(plat->event_tap, false);
  }
  if (plat->event_tap_source) {
    CFRunLoopRemoveSource(rl, plat->event_tap_source, kCFRunLoopCommonModes);
    CFRelease(plat->event_tap_source);
    plat->event_tap_source = NULL;
  }
  if (plat->event_tap) {
    CFMachPortInvalidate(plat->event_tap);
    CFRelease(plat->event_tap);
    plat->event_tap = NULL;
  }

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  if (plat->gc_connect_observer) {
    [nc removeObserver:plat->gc_connect_observer];
    [plat->gc_connect_observer release];
    plat->gc_connect_observer = nil;
  }
  if (plat->gc_disconnect_observer) {
    [nc removeObserver:plat->gc_disconnect_observer];
    [plat->gc_disconnect_observer release];
    plat->gc_disconnect_observer = nil;
  }
}

static void *mac_worker_thread(void *arg) {
  InputPlatformMac *plat = (InputPlatformMac *)arg;

  @autoreleasepool {
    // Publish our runloop so stop_capture can CFRunLoopStop it.
    pthread_mutex_lock(&plat->runloop_mutex);
    plat->worker_runloop = CFRunLoopGetCurrent();
    plat->runloop_published = true;
    pthread_cond_signal(&plat->runloop_ready_cond);
    pthread_mutex_unlock(&plat->runloop_mutex);

    // Read the EFFECTIVE set for this run (start_capture may have dropped KM
    // after a permission probe failure) — never the configured snapshot.
    bool want_km =
        (plat->active_input_types & (MINIAV_INPUT_TYPE_KEYBOARD | MINIAV_INPUT_TYPE_MOUSE)) != 0;
    bool want_gp = (plat->active_input_types & MINIAV_INPUT_TYPE_GAMEPAD) != 0;

    bool tap_ok = true;
    if (want_km) {
      tap_ok = mac_worker_setup_event_tap(plat);
      // If the tap could not be created (permission), we keep the thread alive
      // only if gamepad capture was also requested; otherwise there is nothing
      // to run and we exit immediately. start_capture already reported the
      // failure to the caller.
      if (!tap_ok && !want_gp) {
        mac_worker_teardown(plat);
        dispatch_semaphore_signal(plat->worker_exited_sem);
        return NULL;
      }
    }

    if (want_gp) {
      mac_worker_setup_gamepad(plat);
    }

    // Add an empty timer far in the future is unnecessary: the tap source
    // and/or gamepad timer keep the runloop alive. If NEITHER was installed
    // (e.g. gamepad-only but timer create failed) CFRunLoopRun would return
    // immediately; guard by only running when we have a source or timer.
    bool have_input_source =
        (plat->event_tap_source != NULL) || (plat->gamepad_timer != NULL);

    if (have_input_source) {
      // Run until stop_capture calls CFRunLoopStop on plat->worker_runloop.
      while (!atomic_load(&plat->stop_requested)) {
        CFRunLoopRunResult r =
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, false);
        // kCFRunLoopRunFinished means the mode has NO sources/timers left
        // (e.g. the tap source was torn down out from under us on a permission
        // revocation). Re-entering immediately would spin a full CPU core, so
        // break instead of busy-looping when stop wasn't requested.
        if (r == kCFRunLoopRunFinished) {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "CGTap: run loop finished (no input sources left) — "
                     "exiting worker.");
          break;
        }
        // kCFRunLoopRunStopped (our CFRunLoopStop) or Handled/TimedOut: the
        // while-condition re-checks stop_requested.
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "CGTap: Worker has no active input source; exiting.");
    }

    mac_worker_teardown(plat);
  }

  dispatch_semaphore_signal(plat->worker_exited_sem);
  return NULL;
}

// --- Ops implementation -----------------------------------------------------

static MiniAVResultCode mac_init_platform(MiniAVInputContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  InputPlatformMac *plat =
      (InputPlatformMac *)miniav_calloc(1, sizeof(InputPlatformMac));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  plat->parent_ctx = ctx;
  atomic_store(&plat->stop_requested, false);
  plat->worker_exited_sem = dispatch_semaphore_create(0);
  if (!plat->worker_exited_sem) {
    miniav_free(plat);
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  pthread_mutex_init(&plat->runloop_mutex, NULL);
  pthread_cond_init(&plat->runloop_ready_cond, NULL);

  ctx->platform_ctx = plat;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CGTap: Platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_destroy_platform(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  InputPlatformMac *plat = (InputPlatformMac *)ctx->platform_ctx;

  // Stop if still running.
  if (plat->worker_started && !plat->worker_leaked) {
    MiniAVResultCode stop_res = g_input_ops_macos.stop_capture(ctx);
    if (stop_res == MINIAV_ERROR_TIMEOUT) {
      // The worker could not be joined. Mirror the screen backend's
      // leak-instead-of-free protocol: the worker thread still dereferences
      // `plat`, so freeing it now would be a use-after-free. Detach the
      // context and leak the platform state; report TIMEOUT so the API layer
      // is aware. (worker_leaked was set by stop_capture.)
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "CGTap: worker thread did not exit — leaking platform context "
                 "to avoid a use-after-free.");
      ctx->platform_ctx = NULL;
      return MINIAV_ERROR_TIMEOUT;
    }
  }

  if (plat->worker_leaked) {
    // A prior stop already leaked the worker; do not free.
    ctx->platform_ctx = NULL;
    return MINIAV_ERROR_TIMEOUT;
  }

  if (plat->worker_exited_sem) {
    dispatch_release(plat->worker_exited_sem);
    plat->worker_exited_sem = NULL;
  }
  pthread_mutex_destroy(&plat->runloop_mutex);
  pthread_cond_destroy(&plat->runloop_ready_cond);

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CGTap: Platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode
mac_enumerate_gamepads(MiniAVDeviceInfo **devices_out, uint32_t *count_out) {
  if (!devices_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *devices_out = NULL;
  *count_out = 0;

  @autoreleasepool {
    NSArray<GCController *> *controllers = [GCController controllers];
    NSUInteger count = controllers.count;
    if (count > MINIAV_INPUT_MAX_GAMEPADS) {
      count = MINIAV_INPUT_MAX_GAMEPADS;
    }
    if (count == 0) {
      return MINIAV_SUCCESS;
    }

    MiniAVDeviceInfo *devices =
        (MiniAVDeviceInfo *)miniav_calloc(count, sizeof(MiniAVDeviceInfo));
    if (!devices) {
      return MINIAV_ERROR_OUT_OF_MEMORY;
    }

    for (NSUInteger i = 0; i < count; i++) {
      GCController *ctrl = controllers[i];
      // Stable-ish device id keyed by slot. playerIndex is often unset, so the
      // slot index is the most reliable stable handle within a session.
      snprintf(devices[i].device_id, MINIAV_DEVICE_ID_MAX_LEN, "gccontroller_%u",
               (unsigned)i);
      const char *name = "Game Controller";
      NSString *vendor = ctrl.vendorName;
      if (vendor) {
        const char *c = [vendor UTF8String];
        if (c) name = c;
      }
      snprintf(devices[i].name, MINIAV_DEVICE_NAME_MAX_LEN, "%s", name);
      devices[i].is_default = (i == 0);
    }

    *devices_out = devices;
    *count_out = (uint32_t)count;
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_configure(MiniAVInputContext *ctx,
                                      const MiniAVInputConfig *config) {
  if (!ctx || !ctx->platform_ctx || !config) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  InputPlatformMac *plat = (InputPlatformMac *)ctx->platform_ctx;

  plat->input_types = config->input_types;
  plat->keyboard_cb = config->keyboard_callback;
  plat->mouse_cb = config->mouse_callback;
  plat->gamepad_cb = config->gamepad_callback;
  plat->user_data = config->user_data;

  plat->mouse_throttle_hz = config->mouse_throttle_hz;
  if (plat->mouse_throttle_hz > 0) {
    plat->throttle_interval_us = 1000000ull / plat->mouse_throttle_hz;
  } else {
    plat->throttle_interval_us = 0;
  }
  plat->last_mouse_move_us = 0;

  plat->gamepad_poll_hz =
      (config->gamepad_poll_hz > 0) ? config->gamepad_poll_hz : 60;

  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_start_capture(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  InputPlatformMac *plat = (InputPlatformMac *)ctx->platform_ctx;

  if (plat->worker_started) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  // Effective set for this run starts as the configured set; a failed tap
  // probe below drops KM from active_input_types only, leaving input_types
  // (the configured snapshot) intact so a later restart re-attempts the tap.
  plat->active_input_types = plat->input_types;
  bool want_km =
      (plat->input_types & (MINIAV_INPUT_TYPE_KEYBOARD | MINIAV_INPUT_TYPE_MOUSE)) != 0;
  bool want_gp = (plat->input_types & MINIAV_INPUT_TYPE_GAMEPAD) != 0;
  if (!want_km && !want_gp) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: No input types selected for capture.");
    return MINIAV_ERROR_INVALID_ARG;
  }

  // Pre-flight the event tap permission check on the CALLING thread so we can
  // return a real error synchronously (the worker's tap creation happens after
  // the thread spawns). If keyboard/mouse was requested and the tap cannot be
  // created, fail fast with an actionable error unless gamepad capture can
  // still proceed on its own.
  if (want_km) {
    CGEventMask probeMask = CGEventMaskBit(kCGEventKeyDown);
    CFMachPortRef probe = CGEventTapCreate(
        kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        probeMask, mac_event_tap_callback, plat);
    if (!probe) {
      if (!want_gp) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "CGTap: Cannot create event tap — Accessibility (Input "
                   "Monitoring) permission is required. Grant it in System "
                   "Settings > Privacy & Security > Accessibility and Input "
                   "Monitoring, then restart the app.");
        return MINIAV_ERROR_NOT_SUPPORTED;
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "CGTap: Event tap unavailable (permission); continuing with "
                 "gamepad capture only. Grant Accessibility/Input Monitoring "
                 "for keyboard/mouse.");
      // Drop keyboard/mouse from THIS RUN's effective set (not the configured
      // snapshot) so the worker skips the tap but a later restart re-attempts.
      plat->active_input_types &= ~(MINIAV_INPUT_TYPE_KEYBOARD | MINIAV_INPUT_TYPE_MOUSE);
    } else {
      // Probe succeeded — release it; the worker creates the real one.
      CFMachPortInvalidate(probe);
      CFRelease(probe);
    }
  }

  atomic_store(&plat->stop_requested, false);
  plat->runloop_published = false;
  plat->worker_runloop = NULL;
  plat->worker_leaked = false;

  // Reset gamepad change-detection state.
  memset(plat->prev_buttons, 0, sizeof(plat->prev_buttons));
  memset(plat->prev_lx, 0, sizeof(plat->prev_lx));
  memset(plat->prev_ly, 0, sizeof(plat->prev_ly));
  memset(plat->prev_rx, 0, sizeof(plat->prev_rx));
  memset(plat->prev_ry, 0, sizeof(plat->prev_ry));
  memset(plat->prev_lt, 0, sizeof(plat->prev_lt));
  memset(plat->prev_rt, 0, sizeof(plat->prev_rt));
  memset(plat->slot_was_connected, 0, sizeof(plat->slot_was_connected));

  int rc = pthread_create(&plat->worker_thread, NULL, mac_worker_thread, plat);
  if (rc != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: Failed to spawn worker thread (pthread_create=%d).", rc);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->worker_started = true;

  // Wait until the worker publishes its runloop so a very fast stop_capture
  // cannot race a NULL worker_runloop. Bounded wait via the cond variable.
  pthread_mutex_lock(&plat->runloop_mutex);
  while (!plat->runloop_published) {
    // Timed wait (2s) to avoid hanging forever if the worker never starts.
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 2;
    int wrc = pthread_cond_timedwait(&plat->runloop_ready_cond,
                                     &plat->runloop_mutex, &ts);
    if (wrc != 0) {
      break; // timeout or error; proceed — stop handles a NULL runloop.
    }
  }
  pthread_mutex_unlock(&plat->runloop_mutex);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "CGTap: Input capture started.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode mac_stop_capture(MiniAVInputContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  InputPlatformMac *plat = (InputPlatformMac *)ctx->platform_ctx;

  if (!plat->worker_started) {
    return MINIAV_SUCCESS;
  }
  if (plat->worker_leaked) {
    // Already leaked by a prior failed stop; nothing safe to do.
    return MINIAV_ERROR_TIMEOUT;
  }

  // Signal stop and wake the worker's runloop.
  atomic_store(&plat->stop_requested, true);

  pthread_mutex_lock(&plat->runloop_mutex);
  CFRunLoopRef rl = plat->worker_runloop;
  pthread_mutex_unlock(&plat->runloop_mutex);
  if (rl) {
    CFRunLoopStop(rl);
    // Nudge the runloop in case it is between iterations.
    CFRunLoopWakeUp(rl);
  }

  // Bounded join via the exit semaphore (no pthread_timedjoin_np on macOS).
  // Wait up to 4 seconds; on timeout, LEAK rather than force-cancel — a
  // detached/hung worker still dereferences `plat`, so cancelling it would be
  // more dangerous than a bounded leak.
  long waited =
      dispatch_semaphore_wait(plat->worker_exited_sem,
                              dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
  if (waited != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CGTap: Worker thread did not exit within 4s — leaking it and "
               "its resources (event tap / observers) rather than force-"
               "cancelling.");
    plat->worker_leaked = true;
    return MINIAV_ERROR_TIMEOUT;
  }

  // Worker has signalled exit; join to reclaim the pthread resources.
  pthread_join(plat->worker_thread, NULL);
  plat->worker_started = false;
  pthread_mutex_lock(&plat->runloop_mutex);
  plat->worker_runloop = NULL;
  plat->runloop_published = false;
  pthread_mutex_unlock(&plat->runloop_mutex);

  miniav_log(MINIAV_LOG_LEVEL_INFO, "CGTap: Input capture stopped.");
  return MINIAV_SUCCESS;
}

// --- Ops table + init -------------------------------------------------------

const InputContextInternalOps g_input_ops_macos = {
    .init_platform = mac_init_platform,
    .destroy_platform = mac_destroy_platform,
    .enumerate_gamepads = mac_enumerate_gamepads,
    .configure = mac_configure,
    .start_capture = mac_start_capture,
    .stop_capture = mac_stop_capture,
};

MiniAVResultCode
miniav_input_context_platform_init_macos(MiniAVInputContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  // Selection phase: just publish the ops. Allocation happens in
  // init_platform (called by input_api.c right after selection succeeds).
  ctx->ops = &g_input_ops_macos;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CGTap: macOS input backend selected.");
  return MINIAV_SUCCESS;
}
