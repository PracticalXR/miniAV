part of '../miniav_web.dart';

/// Web implementation of [MiniInputPlatformInterface].
///
/// Keyboard/mouse capture on the web is intentionally not implemented here —
/// apps listen through Flutter/DOM directly (see `INPUT_LAYER_PLAN.md` §3). The
/// web platform contributes two things through this seam:
///   * gamepad enumeration + hotplug (Gamepad API), and
///   * **motion / IMU** via [MiniAVWebInputContext], emitting the same canonical
///     [MiniAVMotionEvent] the native backends produce so the client parallax
///     path is byte-shape-identical across native and web.
class MiniAVWebInputPlatform implements MiniInputPlatformInterface {
  @override
  Future<List<MiniAVDeviceInfo>> enumerateGamepads() async {
    final out = <MiniAVDeviceInfo>[];
    try {
      final pads = web.window.navigator.getGamepads().toDart;
      for (var i = 0; i < pads.length; i++) {
        final p = pads[i];
        if (p == null) continue;
        out.add(
          MiniAVDeviceInfo(deviceId: p.id, name: p.id, isDefault: out.isEmpty),
        );
      }
    } catch (_) {}
    return out;
  }

  @override
  Future<MiniInputContextPlatformInterface> createContext() async =>
      MiniAVWebInputContext();

  @override
  Future<bool> requestMotionPermission() => _requestWebMotionPermission();

  @override
  void Function() addGamepadChangeListener(
    MiniAVDeviceChangeListener listener,
  ) {
    void connHandler(JSAny? event) {
      try {
        final ge = event as web.GamepadEvent;
        final pad = ge.gamepad;
        listener(
          MiniAVDeviceChangeNotification(
            MiniAVDeviceChangeEvent.added,
            MiniAVDeviceInfo(deviceId: pad.id, name: pad.id, isDefault: false),
          ),
        );
      } catch (_) {}
    }

    void disconnHandler(JSAny? event) {
      try {
        final ge = event as web.GamepadEvent;
        final pad = ge.gamepad;
        listener(
          MiniAVDeviceChangeNotification(
            MiniAVDeviceChangeEvent.removed,
            MiniAVDeviceInfo(deviceId: pad.id, name: pad.id, isDefault: false),
          ),
        );
      } catch (_) {}
    }

    final connJs = connHandler.toJS;
    final disconnJs = disconnHandler.toJS;
    web.window.addEventListener('gamepadconnected', connJs);
    web.window.addEventListener('gamepaddisconnected', disconnJs);
    return () {
      web.window.removeEventListener('gamepadconnected', connJs);
      web.window.removeEventListener('gamepaddisconnected', disconnJs);
    };
  }
}

/// Degrees → radians.
const double _degToRad = math.pi / 180.0;

/// Request web motion-sensor permission. On iOS 13+ Safari, DeviceMotion /
/// DeviceOrientation are gated behind a static `requestPermission()` that MUST
/// be called from a user gesture over HTTPS. Everywhere else the constructor
/// has no such method → already permitted. Shared by the platform-level
/// (gesture) entry point and the context so the iOS gate logic lives once.
Future<bool> _requestWebMotionPermission() async {
  final motionOk = await _requestPermissionOnCtor('DeviceMotionEvent');
  // Orientation shares the same grant on iOS; best-effort, don't gate on it.
  await _requestPermissionOnCtor('DeviceOrientationEvent');
  return motionOk;
}

Future<bool> _requestPermissionOnCtor(String ctorName) async {
  try {
    final ctor = globalContext[ctorName];
    if (ctor == null) return true; // constructor absent → no sensor at all
    final obj = ctor as JSObject;
    if (!obj.has('requestPermission')) return true; // non-iOS: no gate
    final promise =
        obj.callMethod<JSPromise<JSString>>('requestPermission'.toJS);
    final state = (await promise.toDart).toDart;
    return state == 'granted';
  } catch (_) {
    // Throws if not from a user gesture, or on an insecure origin.
    return false;
  }
}

/// Web input context. P0 scope = **motion (IMU) via Path-B** (DeviceOrientation
/// + DeviceMotion), which is the first-class path on iOS Safari — all iOS
/// browsers are WebKit and will never ship the Generic Sensor API, so Path-B is
/// not a fallback there. (P1 layers the Generic Sensor "Path-A" upgrade for
/// Chromium/Android and gamepad-state polling onto the same context.)
///
/// Emits the canonical [MiniAVMotionEvent]: gyro in rad/s, accel in m/s²
/// (gravity-included, reaction-force sign as the browser reports), a fused
/// [MiniAVMotionEvent.orientation] built from the Euler angles via the W3C
/// formula, and a display-stable [MiniAVMotionEvent.screenOrientation] that
/// folds in `screen.orientation.angle` so tilt-parallax does not invert in
/// landscape.
class MiniAVWebInputContext implements MiniInputContextPlatformInterface {
  MiniAVInputConfig? _config;

  void Function(MiniAVMotionEvent event, Object? userData)? _onMotion;
  Object? _userData;

  // Latest raw fields, merged across the two DOM events.
  MiniAVVec3 _gyro = MiniAVVec3.zero;
  MiniAVVec3 _accel = MiniAVVec3.zero;
  MiniAVVec3 _linearAccel = MiniAVVec3.zero;
  MiniAVVec3 _gravity = MiniAVVec3.zero;
  MiniAVQuat _orientation = MiniAVQuat.identity;
  bool _haveLinear = false;

  MiniAVMotionEvent? _latest;

  JSFunction? _orientJs;
  JSFunction? _motionJs;
  bool _capturing = false;

  int _intervalUs = 1000000 ~/ 60;
  int _lastEmitUs = 0;

  @override
  Future<void> configure(MiniAVInputConfig config) async {
    _config = config;
    // Web sensors are hard-capped at ~60 Hz; never spin faster.
    final hz = config.motionRateHz <= 0 ? 60 : math.min(config.motionRateHz, 60);
    _intervalUs = 1000000 ~/ hz;
  }

  @override
  Future<void> startCapture({
    void Function(MiniAVKeyboardEvent event, Object? userData)? onKeyboard,
    void Function(MiniAVMouseEvent event, Object? userData)? onMouse,
    void Function(MiniAVGamepadEvent event, Object? userData)? onGamepad,
    void Function(MiniAVMotionEvent event, Object? userData)? onMotion,
    Object? userData,
  }) async {
    // Keyboard/mouse/gamepad on web are handled elsewhere (Flutter/DOM for
    // pointer+key; Gamepad API polling is P1). This context owns motion.
    _onMotion = onMotion;
    _userData = userData;

    final types = _config?.inputTypes ?? MiniAVInputType.motion.value;
    final wantsMotion = (types & MiniAVInputType.motion.value) != 0;
    if (wantsMotion) _startMotion();
  }

  void _startMotion() {
    if (_capturing) return;
    _capturing = true;

    void onOrientation(JSAny? e) {
      try {
        final ev = e as web.DeviceOrientationEvent;
        _orientation = _eulerToQuat(ev.alpha, ev.beta, ev.gamma);
        _maybeEmit();
      } catch (_) {}
    }

    void onMotion(JSAny? e) {
      try {
        final ev = e as web.DeviceMotionEvent;
        final rr = ev.rotationRate;
        if (rr != null) {
          // rotationRate: alpha=Z, beta=X, gamma=Y (deg/s) → gyro (rad/s).
          _gyro = MiniAVVec3(
            (rr.beta ?? 0) * _degToRad,
            (rr.gamma ?? 0) * _degToRad,
            (rr.alpha ?? 0) * _degToRad,
          );
        }
        final ag = ev.accelerationIncludingGravity;
        if (ag != null) {
          _accel = MiniAVVec3(ag.x ?? 0, ag.y ?? 0, ag.z ?? 0);
        }
        final a = ev.acceleration;
        if (a != null && (a.x != null || a.y != null || a.z != null)) {
          _linearAccel = MiniAVVec3(a.x ?? 0, a.y ?? 0, a.z ?? 0);
          _haveLinear = true;
        }
        // gravity = accel - linearAccel when the browser gives us both.
        if (_haveLinear) {
          _gravity = MiniAVVec3(
            _accel.x - _linearAccel.x,
            _accel.y - _linearAccel.y,
            _accel.z - _linearAccel.z,
          );
        }
        _maybeEmit();
      } catch (_) {}
    }

    _orientJs = onOrientation.toJS;
    _motionJs = onMotion.toJS;
    web.window.addEventListener('deviceorientation', _orientJs!);
    web.window.addEventListener('devicemotion', _motionJs!);
  }

  void _maybeEmit() {
    final now = _WebUtils._getCurrentTimestampUs();
    final display = _displayRotation();
    final screenQuat = (_config?.motionMode ?? MiniAVMotionMode.fusedScreenStable)
            == MiniAVMotionMode.rawDeviceFrame
        ? _orientation
        : _remapToScreen(_orientation, _screenAngleDeg());

    final ev = MiniAVMotionEvent(
      timestampUs: now,
      gyro: _gyro,
      accel: _accel,
      linearAccel: _linearAccel,
      gravity: _gravity,
      orientation: _orientation,
      // Web DeviceOrientation is drift-free relative to start unless `absolute`;
      // report relative — the parallax path only wants deltas.
      ref: MiniAVAttitudeRef.relativeDriftFree,
      screenOrientation: screenQuat,
      display: display,
    );
    _latest = ev; // always freshest for the pull API

    final cb = _onMotion;
    if (cb != null && now - _lastEmitUs >= _intervalUs) {
      _lastEmitUs = now;
      cb(ev, _userData);
    }
  }

  /// W3C deviceorientation Euler (Z-X'-Y'' intrinsic, degrees) → quaternion
  /// (scalar-last, right-handed). Angles may be null before the first reading.
  MiniAVQuat _eulerToQuat(double? alphaDeg, double? betaDeg, double? gammaDeg) {
    final z = (alphaDeg ?? 0) * _degToRad; // alpha → Z
    final x = (betaDeg ?? 0) * _degToRad; // beta  → X
    final y = (gammaDeg ?? 0) * _degToRad; // gamma → Y

    final cX = math.cos(x / 2), sX = math.sin(x / 2);
    final cY = math.cos(y / 2), sY = math.sin(y / 2);
    final cZ = math.cos(z / 2), sZ = math.sin(z / 2);

    final qw = cX * cY * cZ - sX * sY * sZ;
    final qx = sX * cY * cZ - cX * sY * sZ;
    final qy = cX * sY * cZ + sX * cY * sZ;
    final qz = cX * cY * sZ + sX * sY * cZ;
    return MiniAVQuat(qx, qy, qz, qw);
  }

  /// Fold the display rotation into the attitude so a given screen-space tilt
  /// yields the same parallax offset in portrait and landscape. Post-multiplies
  /// by a rotation of −angle about the device screen-normal (Z) axis.
  MiniAVQuat _remapToScreen(MiniAVQuat q, int screenAngleDeg) {
    if (screenAngleDeg == 0) return q;
    final half = -screenAngleDeg * _degToRad / 2.0;
    final sz = math.sin(half), cz = math.cos(half);
    // qz = (0, 0, sz, cz); result = q ⊗ qz (Hamilton, scalar-last).
    return MiniAVQuat(
      q.w * 0 + q.x * cz + q.y * sz - q.z * 0,
      q.w * 0 - q.x * sz + q.y * cz + q.z * 0,
      q.w * sz + q.x * 0 - q.y * 0 + q.z * cz,
      q.w * cz - q.x * 0 - q.y * 0 - q.z * sz,
    );
  }

  int _screenAngleDeg() {
    try {
      return web.window.screen.orientation.angle;
    } catch (_) {
      return 0;
    }
  }

  MiniAVDisplayRotation _displayRotation() {
    switch (_screenAngleDeg()) {
      case 90:
        return MiniAVDisplayRotation.rot90;
      case 180:
        return MiniAVDisplayRotation.rot180;
      case 270:
        return MiniAVDisplayRotation.rot270;
      default:
        return MiniAVDisplayRotation.rot0;
    }
  }

  @override
  MiniAVMotionEvent? latestMotion() => _latest;

  @override
  MiniAVGamepadEvent? snapshotGamepad(int index) => null; // P1

  @override
  Future<bool> requestMotionPermission() => _requestWebMotionPermission();

  @override
  Future<void> stopCapture() async {
    if (!_capturing) return;
    _capturing = false;
    if (_orientJs != null) {
      web.window.removeEventListener('deviceorientation', _orientJs!);
      _orientJs = null;
    }
    if (_motionJs != null) {
      web.window.removeEventListener('devicemotion', _motionJs!);
      _motionJs = null;
    }
  }

  @override
  Future<void> destroy() async {
    await stopCapture();
    _onMotion = null;
    _userData = null;
    _latest = null;
  }
}
