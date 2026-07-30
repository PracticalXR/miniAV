import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import 'package:miniav_platform_interface/modules/miniav_input_interface.dart';
import 'package:miniav_platform_interface/miniav_platform_types.dart';

import '../miniav_ffi_bindings.dart' as bindings;
import '../miniav_ffi_subscriptions.dart';
import '../miniav_ffi_types.dart';

/// FFI implementation of [MiniInputPlatformInterface].
class MiniAVFFIInputPlatform extends MiniInputPlatformInterface {
  MiniAVFFIInputPlatform();

  static final FFIDeviceChangeRegistry _gamepadChangeRegistry =
      FFIDeviceChangeRegistry(
        setCallback: bindings.MiniAV_Input_SetGamepadChangeCallback,
      );

  @override
  void Function() addGamepadChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _gamepadChangeRegistry.add(listener);

  @override
  Future<List<MiniAVDeviceInfo>> enumerateGamepads() async {
    final devicesPtrPtr = calloc<ffi.Pointer<bindings.MiniAVDeviceInfo>>();
    final countPtr = calloc<ffi.Uint32>();

    try {
      final res = bindings.MiniAV_Input_EnumerateGamepads(
        devicesPtrPtr,
        countPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to enumerate gamepads: ${res.name}');
      }

      final count = countPtr.value;
      if (count == 0) return [];

      final devicesPtr = devicesPtrPtr.value;
      final devices = <MiniAVDeviceInfo>[];
      for (int i = 0; i < count; i++) {
        devices.add(
          DeviceInfoFFIToPlatform.fromNative(
            devicesPtr.elementAt(i).ref,
          ).toPlatformType(),
        );
      }

      bindings.MiniAV_FreeDeviceList(devicesPtr, count);
      return devices;
    } finally {
      calloc.free(devicesPtrPtr);
      calloc.free(countPtr);
    }
  }

  @override
  Future<MiniInputContextPlatformInterface> createContext() async {
    final handlePtr = calloc<bindings.MiniAVInputContextHandle>();
    try {
      final res = bindings.MiniAV_Input_CreateContext(handlePtr);
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to create input context: ${res.name}');
      }
      return MiniAVFFIInputContextPlatform(handlePtr.value);
    } finally {
      calloc.free(handlePtr);
    }
  }
}

/// FFI implementation of [MiniInputContextPlatformInterface].
class MiniAVFFIInputContextPlatform extends MiniInputContextPlatformInterface {
  bindings.MiniAVInputContextHandle? _contextHandle;
  bool _isDestroyed = false;

  // Stored config from configure(), applied with callbacks at startCapture()
  MiniAVInputConfig? _pendingConfig;

  // Native callback handles — kept alive while capturing
  ffi.NativeCallable<bindings.MiniAVKeyboardCallbackFunction>?
  _keyboardCallbackHandle;
  ffi.NativeCallable<bindings.MiniAVMouseCallbackFunction>?
  _mouseCallbackHandle;
  ffi.NativeCallable<bindings.MiniAVGamepadCallbackFunction>?
  _gamepadCallbackHandle;

  late final Finalizer<bindings.MiniAVInputContextHandle> _finalizer;

  MiniAVFFIInputContextPlatform(bindings.MiniAVInputContextHandle handle)
    : _contextHandle = handle {
    _finalizer = Finalizer<bindings.MiniAVInputContextHandle>((handle) {
      print(
        'Warning: InputContext was garbage collected without calling destroy()',
      );
      bindings.MiniAV_Input_DestroyContext(handle);
    });
    _finalizer.attach(this, handle, detach: this);
  }

  void _ensureNotDestroyed() {
    if (_isDestroyed || _contextHandle == null) {
      throw StateError(
        'InputContext has been destroyed. Create a new context to continue.',
      );
    }
  }

  @override
  Future<void> configure(MiniAVInputConfig config) async {
    _ensureNotDestroyed();
    _pendingConfig = config;
  }

  @override
  Future<void> startCapture({
    void Function(MiniAVKeyboardEvent event, Object? userData)? onKeyboard,
    void Function(MiniAVMouseEvent event, Object? userData)? onMouse,
    void Function(MiniAVGamepadEvent event, Object? userData)? onGamepad,
    void Function(MiniAVMotionEvent event, Object? userData)? onMotion,
    Object? userData,
  }) async {
    // TODO(input-p0): wire onMotion to MiniAV_Input_SetMotionCallback once the
    // native MiniAVMotionEvent struct + ffigen bindings land (the C struct +
    // iOS/Android backends are the parallel P0 work). Accepted + ignored today
    // so the shared interface signature holds; web fully implements motion.
    _ensureNotDestroyed();

    if (_pendingConfig == null) {
      throw StateError('configure() must be called before startCapture()');
    }

    await stopCapture(); // Clean up any previous capture

    // Create NativeCallable listeners for each provided callback
    void ffiKeyboardCallback(
      ffi.Pointer<bindings.MiniAVKeyboardEvent> eventPtr,
      ffi.Pointer<ffi.Void> cbUserData,
    ) {
      if (_isDestroyed || onKeyboard == null) return;
      try {
        onKeyboard(keyboardEventFromNative(eventPtr.ref), userData);
      } catch (e, s) {
        print('Error in keyboard callback: $e\n$s');
      }
    }

    void ffiMouseCallback(
      ffi.Pointer<bindings.MiniAVMouseEvent> eventPtr,
      ffi.Pointer<ffi.Void> cbUserData,
    ) {
      if (_isDestroyed || onMouse == null) return;
      try {
        onMouse(mouseEventFromNative(eventPtr.ref), userData);
      } catch (e, s) {
        print('Error in mouse callback: $e\n$s');
      }
    }

    void ffiGamepadCallback(
      ffi.Pointer<bindings.MiniAVGamepadEvent> eventPtr,
      ffi.Pointer<ffi.Void> cbUserData,
    ) {
      if (_isDestroyed || onGamepad == null) return;
      try {
        onGamepad(gamepadEventFromNative(eventPtr.ref), userData);
      } catch (e, s) {
        print('Error in gamepad callback: $e\n$s');
      }
    }

    _keyboardCallbackHandle =
        ffi.NativeCallable<bindings.MiniAVKeyboardCallbackFunction>.listener(
          ffiKeyboardCallback,
        );
    _mouseCallbackHandle =
        ffi.NativeCallable<bindings.MiniAVMouseCallbackFunction>.listener(
          ffiMouseCallback,
        );
    _gamepadCallbackHandle =
        ffi.NativeCallable<bindings.MiniAVGamepadCallbackFunction>.listener(
          ffiGamepadCallback,
        );

    // Build the native config struct with callbacks
    final configPtr = calloc<bindings.MiniAVInputConfig>();
    try {
      copyInputConfigToNative(
        _pendingConfig!,
        configPtr.ref,
        keyboardCb: _keyboardCallbackHandle!.nativeFunction,
        mouseCb: _mouseCallbackHandle!.nativeFunction,
        gamepadCb: _gamepadCallbackHandle!.nativeFunction,
      );

      final configRes = bindings.MiniAV_Input_Configure(
        _contextHandle!,
        configPtr,
      );
      if (configRes != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        await _cleanupCallbacks();
        throw Exception('Failed to configure input context: ${configRes.name}');
      }
    } finally {
      calloc.free(configPtr);
    }

    final startRes = bindings.MiniAV_Input_StartCapture(_contextHandle!);
    if (startRes != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      await _cleanupCallbacks();
      throw Exception('Failed to start input capture: ${startRes.name}');
    }
  }

  Future<void> _cleanupCallbacks() async {
    _keyboardCallbackHandle?.close();
    _keyboardCallbackHandle = null;
    _mouseCallbackHandle?.close();
    _mouseCallbackHandle = null;
    _gamepadCallbackHandle?.close();
    _gamepadCallbackHandle = null;
  }

  @override
  Future<void> stopCapture() async {
    if (_isDestroyed || _contextHandle == null) {
      await _cleanupCallbacks();
      return;
    }

    if (_keyboardCallbackHandle == null &&
        _mouseCallbackHandle == null &&
        _gamepadCallbackHandle == null) {
      return; // Already stopped
    }

    final res = bindings.MiniAV_Input_StopCapture(_contextHandle!);

    await _cleanupCallbacks();

    if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS &&
        res != bindings.MiniAVResultCode.MINIAV_ERROR_NOT_RUNNING) {
      print('Warning: MiniAV_Input_StopCapture failed: ${res.name}');
    }
  }

  @override
  Future<void> destroy() async {
    if (_isDestroyed) return;

    _isDestroyed = true;
    await stopCapture();

    if (_contextHandle != null) {
      _finalizer.detach(this);
      final res = bindings.MiniAV_Input_DestroyContext(_contextHandle!);
      _contextHandle = null;

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        print('Warning: MiniAV_Input_DestroyContext failed: ${res.name}');
      }
    }
  }
}
