import 'dart:typed_data';

/// Platform-agnostic types for MiniAV platform interface.
/// These are pure Dart types, not FFI structs.

enum MiniAVPixelFormat {
  unknown,
  rgb24,
  bgr24,
  rgba32,
  bgra32,
  argb32,
  abgr32,
  rgbx32,
  bgrx32,
  xrgb32,
  xbgr32,
  i420,
  yv12,
  nv12,
  nv21,
  yuy2,
  uyvy,
  rgb30,
  rgb48,
  rgba64,
  rgba64Half,
  rgba128Float,
  yuv420_10bit,
  yuv422_10bit,
  yuv444_10bit,
  gray8,
  gray16,
  bayerGrbg8,
  bayerRggb8,
  bayerBggr8,
  bayerGbrg8,
  bayerGrbg16,
  bayerRggb16,
  bayerBggr16,
  bayerGbrg16,
  mjpeg,
}

enum MiniAVAudioFormat { unknown, u8, s16, s32, f32 }

enum MiniAVOutputPreference { cpu, gpu }

enum MiniAVBufferType { unknown, video, audio }

/// How a [MiniAVBuffer]'s payload is stored.
///
/// This is **the** discriminator between the CPU and GPU layouts. Never probe
/// `MiniAVVideoBuffer.planes[0] != null` to decide: on the GPU paths
/// `planes[0]` is a non-null, zero-length `Uint8List`.
enum MiniAVBufferContentType {
  /// `MiniAVVideoBuffer.planes[n]` hold CPU pixel data.
  cpu,

  /// Windows zero-copy: `MiniAVVideoBuffer.nativeHandles[0]` is a shared NT
  /// HANDLE (as an `int`) for a D3D11 texture; `planes[0]` is empty and
  /// `strideBytes[0]` is 0. miniav closes the handle in `MiniAV.releaseBuffer`.
  gpuD3D11Handle,

  /// macOS/iOS: `nativeHandles[0]` is an `id<MTLTexture>` address.
  gpuMetalTexture,

  /// Linux: `MiniAVVideoBuffer.dmabufFds[n]` carry the DMA-BUF fds.
  gpuDmabufFd,

  /// Android: `nativeHandles[0]` is an `AHardwareBuffer*`.
  gpuAHardwareBuffer,
}

enum MiniAVLogLevel { none, trace, debug, info, warn, error }

class MiniAVDeviceInfo {
  final String deviceId;
  final String name;
  final bool isDefault;

  MiniAVDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.isDefault,
  });
}

/// Type of device-change event reported via device-change listeners.
enum MiniAVDeviceChangeEvent { added, removed, defaultChanged }

/// A single device-change notification.
class MiniAVDeviceChangeNotification {
  final MiniAVDeviceChangeEvent event;
  final MiniAVDeviceInfo device;

  const MiniAVDeviceChangeNotification(this.event, this.device);

  @override
  String toString() =>
      'MiniAVDeviceChangeNotification($event, ${device.deviceId})';
}

/// Listener type for device-change events. Always invoked on the platform's
/// background watcher thread on native; on web, on the main isolate.
typedef MiniAVDeviceChangeListener =
    void Function(MiniAVDeviceChangeNotification notification);

/// Listener type for per-context device-lost events. The integer is a
/// `MiniAVResultCode`-compatible reason code.
typedef MiniAVContextLostListener = void Function(int reason);

class MiniAVVideoInfo {
  final int width;
  final int height;
  final MiniAVPixelFormat pixelFormat;
  final int frameRateNumerator;
  final int frameRateDenominator;
  final MiniAVOutputPreference outputPreference;

  MiniAVVideoInfo({
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.frameRateNumerator,
    required this.frameRateDenominator,
    required this.outputPreference,
  });
}

class MiniAVAudioInfo {
  final MiniAVAudioFormat format;
  final int sampleRate;
  final int channels;
  final int numFrames;

  MiniAVAudioInfo({
    required this.format,
    required this.sampleRate,
    required this.channels,
    required this.numFrames,
  });
}

/// GPU sync fence information for zero-copy buffer handoff.
///
/// **NOT IMPLEMENTED (as of 0.6.0) — every field is always the sentinel.**
/// No miniav backend creates a fence, so [syncFd] is always `-1`,
/// [d3d11FencePtr] / [metalSharedEventPtr] / [metalFenceValue] are always `0`.
/// The type exists so the handoff contract can be extended without a breaking
/// change; do not write code that depends on receiving a real fence, and do
/// **not** read "no fence" as "the producer GPU work is complete".
///
/// What the Windows backends do instead: before exposing the shared NT handle
/// they insert a `D3D11_QUERY_EVENT`, `Flush()`, and CPU busy-poll it for at
/// most ~16 ms. **On timeout they log a rate-limited warning and hand the
/// frame over anyway** — under GPU contention a consumer can therefore receive
/// a texture whose producer-side copy has not finished (torn or black frame).
/// A consumer needing a hard guarantee must synchronise on its own device.
class MiniAVNativeFence {
  /// Linux/Android: sync_file fd, or -1 if none.
  ///
  /// Always -1 today — see the class doc.
  final int syncFd;

  /// Windows: `ID3D11Fence*` as integer address, or 0 if none.
  ///
  /// **Always 0 today** — miniav never creates an `ID3D11Fence`. See the class
  /// doc for the busy-poll behaviour that replaces it.
  final int d3d11FencePtr;

  /// macOS/iOS: `id<MTLSharedEvent>` as integer address, or 0 if none.
  ///
  /// Always 0 today — see the class doc.
  final int metalSharedEventPtr;

  /// macOS/iOS: signaled fence value.
  ///
  /// Always 0 today — see the class doc.
  final int metalFenceValue;

  const MiniAVNativeFence({
    this.syncFd = -1,
    this.d3d11FencePtr = 0,
    this.metalSharedEventPtr = 0,
    this.metalFenceValue = 0,
  });
}

class MiniAVBuffer {
  final MiniAVBufferType type;
  final MiniAVBufferContentType contentType;
  final int timestampUs;
  final Object? data; // MiniAVVideoBuffer or MiniAVAudioBuffer
  final int dataSizeBytes;
  final Object? _nativeHandle;
  final MiniAVNativeFence nativeFence;

  const MiniAVBuffer({
    required this.type,
    required this.contentType,
    required this.timestampUs,
    required this.data,
    required this.dataSizeBytes,
    Object? nativeHandle,
    this.nativeFence = const MiniAVNativeFence(),
  }) : _nativeHandle = nativeHandle;

  // Add getter for native handle
  Object? get nativeHandle => _nativeHandle;
}

/// Video payload of a [MiniAVBuffer].
///
/// **Use [MiniAVBuffer.contentType] — not [planes] — to tell the CPU and GPU
/// layouts apart.** On the GPU paths `planes[0]` is a non-null but *empty*
/// `Uint8List` (its `strideBytes[0]` is 0, so the FFI wrapper materialises a
/// zero-length view), so `planes[0] != null` takes the wrong branch.
class MiniAVVideoBuffer {
  final int width;
  final int height;
  final MiniAVPixelFormat pixelFormat;

  /// Row stride in bytes per plane. **0 on the GPU paths** (no CPU rows).
  final List<int> strideBytes;

  /// CPU pixel data per plane — only meaningful when
  /// `MiniAVBuffer.contentType == MiniAVBufferContentType.cpu`.
  ///
  /// On the GPU paths these entries are non-null but EMPTY (length 0); read
  /// [nativeHandles] instead.
  final List<Uint8List?> planes;

  /// Platform GPU handle per plane, valid when
  /// `MiniAVBuffer.contentType != MiniAVBufferContentType.cpu`.
  ///
  /// * Windows (`gpuD3D11Handle`): `nativeHandles[0]` is a **shared NT HANDLE**
  ///   for a D3D11 texture, delivered as a plain Dart `int` (the handle value).
  ///   Pass it to `OpenSharedResource1` / minigpu's `importVideoFrame`.
  /// * Other platforms: Metal texture pointer, `AHardwareBuffer*`, etc.
  ///
  /// **Ownership: miniav owns the handle.** It is closed for you by
  /// `MiniAV.releaseBuffer` / `MiniAV.releaseBufferSync`. Do **not** close it
  /// yourself (double-close), and finish importing it *before* releasing the
  /// buffer — it is invalid the moment release returns.
  final List<Object?> nativeHandles;

  /// Per-plane DMA-BUF file descriptors (-1 if not applicable).
  final List<int> dmabufFds;

  /// Per-plane DRM format modifiers (0 = LINEAR).
  final List<int> drmFormatModifiers;

  MiniAVVideoBuffer({
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.strideBytes,
    required this.planes,
    this.nativeHandles = const [],
    this.dmabufFds = const [],
    this.drmFormatModifiers = const [],
  });
}

class MiniAVAudioBuffer {
  final int frameCount;
  final MiniAVAudioInfo info;
  final Uint8List data;

  MiniAVAudioBuffer({
    required this.frameCount,
    required this.info,
    required this.data,
  });
}

typedef ScreenFormatDefaults = (
  MiniAVVideoInfo videoFormat,
  MiniAVAudioInfo? audioFormat,
);

// --- Input Capture Types ---

enum MiniAVInputType {
  keyboard(0x01),
  mouse(0x02),
  gamepad(0x04),

  /// IMU / motion sensors (gyro + accel + fused orientation). NEW; capture
  /// only (no injection). See [MiniAVMotionEvent].
  motion(0x08);

  final int value;
  const MiniAVInputType(this.value);
}

/// Which motion frame the capture backend delivers.
enum MiniAVMotionMode {
  /// Attitude in the raw device sensor frame (XR / advanced callers).
  rawDeviceFrame(0),

  /// Attitude remapped into the current DISPLAY frame — the default; the only
  /// thing the parallax path should consume (kills "gyro wrong in landscape").
  fusedScreenStable(1);

  final int value;
  const MiniAVMotionMode(this.value);
}

/// Reference of the fused [MiniAVMotionEvent.orientation] quaternion.
enum MiniAVAttitudeRef {
  /// Drift-corrected but NOT compass-referenced (relative yaw).
  relativeDriftFree(0),

  /// Yaw referenced to magnetic/true north (magnetometer-fused).
  absoluteMagNorth(1);

  final int value;
  const MiniAVAttitudeRef(this.value);

  static MiniAVAttitudeRef fromValue(int v) =>
      v == 1 ? absoluteMagNorth : relativeDriftFree;
}

/// Display rotation the [MiniAVMotionEvent.screenOrientation] was remapped for.
enum MiniAVDisplayRotation {
  rot0(0),
  rot90(1),
  rot180(2),
  rot270(3);

  final int value;
  const MiniAVDisplayRotation(this.value);

  static MiniAVDisplayRotation fromValue(int v) => switch (v) {
    1 => rot90,
    2 => rot180,
    3 => rot270,
    _ => rot0,
  };
}

/// A 3-vector (sensor axis triple). Plain doubles; no external dep.
class MiniAVVec3 {
  final double x, y, z;
  const MiniAVVec3(this.x, this.y, this.z);
  static const zero = MiniAVVec3(0, 0, 0);
  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// A unit quaternion, scalar-LAST `[x, y, z, w]`, right-handed, gravity-down —
/// the ONE canonical layout every backend converts to at its native boundary.
class MiniAVQuat {
  final double x, y, z, w;
  const MiniAVQuat(this.x, this.y, this.z, this.w);
  static const identity = MiniAVQuat(0, 0, 0, 1);
  @override
  String toString() => 'Quat($x, $y, $z, $w)';
}

/// A decoded IMU / motion sample. All signals share ONE canonical convention
/// (converted at each backend's native boundary — see INPUT_LAYER_PLAN.md §1.5):
/// gyro rad/s right-handed, accel m/s² (gravity-included, reaction-force sign),
/// quaternions scalar-last `[x,y,z,w]`. [screenOrientation] is [orientation]
/// remapped into the current display frame — the field the parallax path uses.
class MiniAVMotionEvent {
  final int timestampUs;

  /// Angular velocity, rad/s, right-handed.
  final MiniAVVec3 gyro;

  /// Acceleration, m/s², INCLUDES gravity (face-up z ≈ +9.81).
  final MiniAVVec3 accel;

  /// Acceleration with gravity removed (m/s²); zero when the backend can't fuse.
  final MiniAVVec3 linearAccel;

  /// Gravity vector estimate, m/s².
  final MiniAVVec3 gravity;

  /// Magnetic field, µT, or null when absent / permission denied.
  final MiniAVVec3? magnetometer;

  /// Fused attitude in the device frame.
  final MiniAVQuat orientation;
  final MiniAVAttitudeRef ref;

  /// Heading 0..360 (true/mag north) or null when unreferenced.
  final double? headingDeg;

  /// Attitude REMAPPED into the current display frame — parallax consumes this.
  final MiniAVQuat screenOrientation;
  final MiniAVDisplayRotation display;

  const MiniAVMotionEvent({
    required this.timestampUs,
    required this.gyro,
    required this.accel,
    this.linearAccel = MiniAVVec3.zero,
    this.gravity = MiniAVVec3.zero,
    this.magnetometer,
    this.orientation = MiniAVQuat.identity,
    this.ref = MiniAVAttitudeRef.relativeDriftFree,
    this.headingDeg,
    this.screenOrientation = MiniAVQuat.identity,
    this.display = MiniAVDisplayRotation.rot0,
  });
}

enum MiniAVKeyAction {
  down(0),
  up(1);

  final int value;
  const MiniAVKeyAction(this.value);

  static MiniAVKeyAction fromValue(int value) => switch (value) {
    0 => down,
    1 => up,
    _ => throw ArgumentError('Unknown MiniAVKeyAction value: $value'),
  };
}

enum MiniAVMouseAction {
  move(0),
  buttonDown(1),
  buttonUp(2),
  wheel(3);

  final int value;
  const MiniAVMouseAction(this.value);

  static MiniAVMouseAction fromValue(int value) => switch (value) {
    0 => move,
    1 => buttonDown,
    2 => buttonUp,
    3 => wheel,
    _ => throw ArgumentError('Unknown MiniAVMouseAction value: $value'),
  };
}

enum MiniAVMouseButton {
  none(0),
  left(1),
  right(2),
  middle(3),
  x1(4),
  x2(5);

  final int value;
  const MiniAVMouseButton(this.value);

  static MiniAVMouseButton fromValue(int value) => switch (value) {
    0 => none,
    1 => left,
    2 => right,
    3 => middle,
    4 => x1,
    5 => x2,
    _ => throw ArgumentError('Unknown MiniAVMouseButton value: $value'),
  };
}

class MiniAVKeyboardEvent {
  final int timestampUs;
  final int keyCode;
  final int scanCode;
  final MiniAVKeyAction action;

  MiniAVKeyboardEvent({
    required this.timestampUs,
    required this.keyCode,
    required this.scanCode,
    required this.action,
  });
}

class MiniAVMouseEvent {
  final int timestampUs;
  final int x;
  final int y;
  final int deltaX;
  final int deltaY;

  /// Vertical scroll wheel delta (+ = up/away).
  final int wheelDelta;

  /// Horizontal scroll wheel delta (+ = right).
  final int wheelDeltaX;
  final MiniAVMouseAction action;
  final MiniAVMouseButton button;

  /// Capture always reports absolute coords (true). For injection: true = move
  /// to absolute (x, y); false = move by (deltaX, deltaY). Ignored for
  /// button/wheel actions.
  final bool isAbsolute;

  MiniAVMouseEvent({
    required this.timestampUs,
    required this.x,
    required this.y,
    required this.deltaX,
    required this.deltaY,
    required this.wheelDelta,
    required this.action,
    required this.button,
    this.wheelDeltaX = 0,
    this.isAbsolute = true,
  });
}

class MiniAVGamepadEvent {
  final int timestampUs;
  final int gamepadIndex;
  final int buttons;
  final int leftStickX;
  final int leftStickY;
  final int rightStickX;
  final int rightStickY;
  final int leftTrigger;
  final int rightTrigger;
  final bool connected;

  MiniAVGamepadEvent({
    required this.timestampUs,
    required this.gamepadIndex,
    required this.buttons,
    required this.leftStickX,
    required this.leftStickY,
    required this.rightStickX,
    required this.rightStickY,
    required this.leftTrigger,
    required this.rightTrigger,
    required this.connected,
  });
}

class MiniAVInputConfig {
  final int inputTypes;
  final int mouseThrottleHz;
  final int gamepadPollHz;

  /// Requested motion sample/emit rate; clamped to the device min-interval
  /// (and to ≤60 on web — browsers hard-cap sensors). NEW.
  final int motionRateHz;

  /// Which motion frame to deliver. NEW.
  final MiniAVMotionMode motionMode;

  MiniAVInputConfig({
    required this.inputTypes,
    this.mouseThrottleHz = 60,
    this.gamepadPollHz = 60,
    this.motionRateHz = 60,
    this.motionMode = MiniAVMotionMode.fusedScreenStable,
  });
}
