// Shared FFI plumbing for device-change and context-lost subscriptions.
//
// The C library accepts only a single callback per module (and per context).
// This helper provides Dart-level fan-out so the higher-level public API can
// support multiple listeners cleanly.

import 'dart:ffi' as ffi;

import 'package:miniav_platform_interface/miniav_platform_interface.dart';

import 'miniav_ffi_bindings.dart' as bindings;
import 'miniav_ffi_types.dart';

/// A Dart-side fan-out for module-level device-change events. One instance
/// per module (camera, audio, loopback, screen-displays, screen-windows,
/// gamepads). Lazily registers a single C callback and dispatches to all
/// added Dart listeners.
class FFIDeviceChangeRegistry {
  FFIDeviceChangeRegistry({required this.setCallback});

  /// The native setter, e.g. [bindings.MiniAV_Camera_SetDeviceChangeCallback].
  final bindings.MiniAVResultCode Function(
    bindings.MiniAVDeviceChangeCallback callback,
    ffi.Pointer<ffi.Void> userData,
  )
  setCallback;

  // Note: the use of NativeCallable.listener requires the registered Dart
  // function to be a non-isolate-bound static or top-level function. We
  // dispatch through a global registry keyed by an integer id so multiple
  // FFIDeviceChangeRegistry instances can coexist.
  static int _nextId = 1;
  static final Map<int, FFIDeviceChangeRegistry> _byId =
      <int, FFIDeviceChangeRegistry>{};

  late final int _id = _nextId++;
  final List<MiniAVDeviceChangeListener> _listeners =
      <MiniAVDeviceChangeListener>[];
  ffi.NativeCallable<bindings.MiniAVDeviceChangeCallbackFunction>? _native;

  /// Add a listener. Returns a disposer.
  void Function() add(MiniAVDeviceChangeListener listener) {
    _listeners.add(listener);
    if (_native == null) {
      _byId[_id] = this;
      _native =
          ffi.NativeCallable<
            bindings.MiniAVDeviceChangeCallbackFunction
          >.listener(_trampoline);
      final res = setCallback(
        _native!.nativeFunction,
        ffi.Pointer<ffi.Void>.fromAddress(_id),
      );
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        // Roll back.
        _native!.close();
        _native = null;
        _byId.remove(_id);
        _listeners.remove(listener);
        throw StateError(
          'Failed to register native device-change callback: ${res.name}',
        );
      }
    }
    return () => _remove(listener);
  }

  void _remove(MiniAVDeviceChangeListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty && _native != null) {
      // Unregister native side.
      setCallback(
        ffi.Pointer<
          ffi.NativeFunction<bindings.MiniAVDeviceChangeCallbackFunction>
        >.fromAddress(0),
        ffi.Pointer<ffi.Void>.fromAddress(0),
      );
      _native!.close();
      _native = null;
      _byId.remove(_id);
    }
  }

  static void _trampoline(
    int eventInt,
    ffi.Pointer<bindings.MiniAVDeviceInfo> devicePtr,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final reg = _byId[userData.address];
    if (reg == null || devicePtr == ffi.nullptr) return;
    MiniAVDeviceChangeEvent event;
    switch (eventInt) {
      case 0:
        event = MiniAVDeviceChangeEvent.added;
        break;
      case 1:
        event = MiniAVDeviceChangeEvent.removed;
        break;
      case 2:
        event = MiniAVDeviceChangeEvent.defaultChanged;
        break;
      default:
        return;
    }
    final info = DeviceInfoFFIToPlatform.fromNative(
      devicePtr.ref,
    ).toPlatformType();
    final notification = MiniAVDeviceChangeNotification(event, info);
    // Snapshot listener list to be safe against mutation during dispatch.
    final snapshot = List<MiniAVDeviceChangeListener>.from(reg._listeners);
    for (final l in snapshot) {
      try {
        l(notification);
      } catch (_) {
        // swallow listener exceptions
      }
    }
  }
}

/// Per-context lost-callback fan-out.
class FFIContextLostRegistry<H extends ffi.Pointer> {
  FFIContextLostRegistry({required this.context, required this.setCallback});

  final H context;
  final bindings.MiniAVResultCode Function(
    H context,
    bindings.MiniAVContextLostCallback callback,
    ffi.Pointer<ffi.Void> userData,
  )
  setCallback;

  static int _nextId = 1;
  static final Map<int, FFIContextLostRegistry> _byId =
      <int, FFIContextLostRegistry>{};

  late final int _id = _nextId++;
  final List<MiniAVContextLostListener> _listeners =
      <MiniAVContextLostListener>[];
  ffi.NativeCallable<bindings.MiniAVContextLostCallbackFunction>? _native;

  void Function() add(MiniAVContextLostListener listener) {
    _listeners.add(listener);
    if (_native == null) {
      _byId[_id] = this;
      _native =
          ffi.NativeCallable<
            bindings.MiniAVContextLostCallbackFunction
          >.listener(_trampoline);
      final res = setCallback(
        context,
        _native!.nativeFunction,
        ffi.Pointer<ffi.Void>.fromAddress(_id),
      );
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        _native!.close();
        _native = null;
        _byId.remove(_id);
        _listeners.remove(listener);
        throw StateError(
          'Failed to register native context-lost callback: ${res.name}',
        );
      }
    }
    return () => _remove(listener);
  }

  void _remove(MiniAVContextLostListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty && _native != null) {
      setCallback(
        context,
        ffi.Pointer<
          ffi.NativeFunction<bindings.MiniAVContextLostCallbackFunction>
        >.fromAddress(0),
        ffi.Pointer<ffi.Void>.fromAddress(0),
      );
      _native!.close();
      _native = null;
      _byId.remove(_id);
    }
  }

  /// Tear everything down. Call from the owning context's destroy().
  void dispose() {
    if (_native != null) {
      setCallback(
        context,
        ffi.Pointer<
          ffi.NativeFunction<bindings.MiniAVContextLostCallbackFunction>
        >.fromAddress(0),
        ffi.Pointer<ffi.Void>.fromAddress(0),
      );
      _native!.close();
      _native = null;
      _byId.remove(_id);
    }
    _listeners.clear();
  }

  static void _trampoline(int reason, ffi.Pointer<ffi.Void> userData) {
    final reg = _byId[userData.address];
    if (reg == null) return;
    final snapshot = List<MiniAVContextLostListener>.from(reg._listeners);
    for (final l in snapshot) {
      try {
        l(reason);
      } catch (_) {
        // swallow listener exceptions
      }
    }
  }
}
