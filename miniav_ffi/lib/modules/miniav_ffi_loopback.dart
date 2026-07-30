import 'dart:async';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import 'package:miniav_platform_interface/modules/miniav_loopback_interface.dart';
import 'package:miniav_platform_interface/miniav_platform_types.dart';

import '../miniav_ffi_bindings.dart' as bindings;
import '../miniav_ffi_subscriptions.dart';
import '../miniav_ffi_types.dart'; // For ...FFIToPlatform and MiniAVBufferFFI

/// FFI implementation of [MiniLoopbackPlatformInterface].
class MiniAVFFILoopbackPlatform extends MiniLoopbackPlatformInterface {
  MiniAVFFILoopbackPlatform();

  static final FFIDeviceChangeRegistry _deviceChangeRegistry =
      FFIDeviceChangeRegistry(
        setCallback: bindings.MiniAV_Loopback_SetDeviceChangeCallback,
      );

  @override
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _deviceChangeRegistry.add(listener);

  @override
  Future<List<MiniAVDeviceInfo>> enumerateDevices() async {
    final devicesPtrPtr = calloc<ffi.Pointer<bindings.MiniAVDeviceInfo>>();
    final countPtr = calloc<ffi.Uint32>();

    try {
      final res = bindings.MiniAV_Loopback_EnumerateTargets(
        bindings.MiniAVLoopbackTargetType.MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO,
        devicesPtrPtr,
        countPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to enumerate loopback devices: ${res.name}');
      }

      final count = countPtr.value;
      if (count == 0) {
        return [];
      }

      final devicesPtr = devicesPtrPtr.value;
      final devices = <MiniAVDeviceInfo>[];
      for (int i = 0; i < count; i++) {
        final deviceInfoC = devicesPtr.elementAt(i).ref;
        devices.add(
          DeviceInfoFFIToPlatform.fromNative(deviceInfoC).toPlatformType(),
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
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId) async {
    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatOutPtr = calloc<bindings.MiniAVAudioInfo>();

    try {
      final res = bindings.MiniAV_Loopback_GetDefaultFormat(
        deviceIdPtr.cast<ffi.Char>(),
        formatOutPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get default loopback format for $deviceId: ${res.name}',
        );
      }
      return AudioInfoFFIToPlatform.fromNative(
        formatOutPtr.ref,
      ).toPlatformType();
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatOutPtr);
    }
  }

  @override
  Future<MiniLoopbackContextPlatformInterface> createContext() async {
    final contextHandlePtr = calloc<bindings.MiniAVLoopbackContextHandle>();
    try {
      final res = bindings.MiniAV_Loopback_CreateContext(contextHandlePtr);
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to create loopback context: ${res.name}');
      }
      return MiniAVFFILoopbackContextPlatform(contextHandlePtr.value);
    } finally {
      calloc.free(contextHandlePtr);
    }
  }
}

/// FFI implementation of [MiniLoopbackContextPlatformInterface].
class MiniAVFFILoopbackContextPlatform
    extends MiniLoopbackContextPlatformInterface {
  bindings.MiniAVLoopbackContextHandle? _contextHandle;
  ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>? _callbackHandle;
  FFIContextLostRegistry<bindings.MiniAVLoopbackContextHandle>? _lostRegistry;
  bool _isDestroyed = false;
  late final Finalizer<bindings.MiniAVLoopbackContextHandle> _finalizer;

  MiniAVFFILoopbackContextPlatform(bindings.MiniAVLoopbackContextHandle handle)
    : _contextHandle = handle {
    // Auto-cleanup if destroy() is never called
    _finalizer = Finalizer<bindings.MiniAVLoopbackContextHandle>((handle) {
      print(
        'Warning: LoopbackContext was garbage collected without calling destroy()',
      );
      bindings.MiniAV_Loopback_DestroyContext(handle);
    });
    _finalizer.attach(this, handle, detach: this);
  }

  /// Throws if the context has been destroyed
  void _ensureNotDestroyed() {
    if (_isDestroyed || _contextHandle == null) {
      throw StateError(
        'LoopbackContext has been destroyed. Create a new context to continue using loopback.',
      );
    }
  }

  /// Whether this context has been destroyed
  bool get isDestroyed => _isDestroyed;

  @override
  Future<void> configure(String deviceId, MiniAVAudioInfo format) async {
    _ensureNotDestroyed();

    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatCPtr = calloc<bindings.MiniAVAudioInfo>();

    try {
      AudioInfoFFIToPlatform.copyToNative(format, formatCPtr.ref);

      final res = bindings.MiniAV_Loopback_Configure(
        _contextHandle!,
        deviceIdPtr.cast<ffi.Char>(),
        formatCPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to configure loopback for $deviceId: ${res.name}',
        );
      }
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatCPtr);
    }
  }

  @override
  Future<MiniAVAudioInfo> getConfiguredFormat() async {
    _ensureNotDestroyed();

    final formatOutPtr = calloc<bindings.MiniAVAudioInfo>();
    try {
      final res = bindings.MiniAV_Loopback_GetConfiguredFormat(
        _contextHandle!,
        formatOutPtr,
      );
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get configured loopback format: ${res.name}',
        );
      }
      return AudioInfoFFIToPlatform.fromNative(
        formatOutPtr.ref,
      ).toPlatformType();
    } finally {
      calloc.free(formatOutPtr);
    }
  }

  @override
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onData, {
    Object? userData,
  }) async {
    _ensureNotDestroyed();

    await stopCapture(); // Clean up any previous callback

    void ffiCallback(
      ffi.Pointer<bindings.MiniAVBuffer> buffer,
      ffi.Pointer<ffi.Void> cbUserData,
    ) {
      // Check if context was destroyed during callback.
      // Still release the heap-allocated buffer to avoid a memory leak — the
      // C capture thread may have allocated heap_buf/audio_copy before the
      // dispatch guard was disabled, then queued this event while Dart was
      // processing destroy().
      if (_isDestroyed) {
        final handle = buffer.ref.internal_handle;
        if (handle != ffi.nullptr) {
          bindings.MiniAV_ReleaseBuffer(handle);
        }
        return;
      }

      final platformBuffer = MiniAVBufferFFI.fromPointer(buffer);
      try {
        onData(platformBuffer, userData);
      } catch (e, s) {
        print('Error in loopback user callback: $e\n$s');
      }
    }

    _callbackHandle =
        ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>.listener(
          ffiCallback,
        );

    final res = bindings.MiniAV_Loopback_StartCapture(
      _contextHandle!,
      _callbackHandle!.nativeFunction,
      ffi.nullptr,
    );

    if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      await _cleanupCallback();
      throw Exception('Failed to start loopback capture: ${res.name}');
    }
  }

  Future<void> _cleanupCallback() async {
    _callbackHandle?.close();
    _callbackHandle = null;
  }

  @override
  Future<void> stopCapture() async {
    // Don't throw if context is destroyed - just clean up Dart resources
    if (_isDestroyed || _contextHandle == null) {
      await _cleanupCallback();
      return;
    }

    // Don't throw if already stopped - this is idempotent
    if (_callbackHandle == null) {
      return; // Already stopped
    }

    final res = bindings.MiniAV_Loopback_StopCapture(_contextHandle!);

    await _cleanupCallback();

    // Only warn on unexpected errors, not "already stopped" errors
    if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS &&
        res != bindings.MiniAVResultCode.MINIAV_ERROR_NOT_RUNNING) {
      print('Warning: MiniAV_Loopback_StopCapture failed: ${res.name}');
    }
  }

  @override
  Future<void> destroy() async {
    // Idempotent - can be called multiple times safely
    if (_isDestroyed) {
      return; // Already destroyed
    }

    _isDestroyed = true; // Mark as destroyed first to prevent new operations

    await stopCapture(); // Stop capture if running

    _lostRegistry?.dispose();
    _lostRegistry = null;

    if (_contextHandle != null) {
      _finalizer.detach(this); // Prevent finalizer from running
      final res = bindings.MiniAV_Loopback_DestroyContext(_contextHandle!);
      _contextHandle = null; // Clear the handle

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to destroy loopback context: ${res.name}');
      }
    }
  }

  @override
  void Function() addLostListener(MiniAVContextLostListener listener) {
    if (_isDestroyed || _contextHandle == null) {
      throw StateError('Cannot add lost listener on a destroyed context.');
    }
    _lostRegistry ??=
        FFIContextLostRegistry<bindings.MiniAVLoopbackContextHandle>(
          context: _contextHandle!,
          setCallback: bindings.MiniAV_Loopback_SetContextLostCallback,
        );
    return _lostRegistry!.add(listener);
  }
}
