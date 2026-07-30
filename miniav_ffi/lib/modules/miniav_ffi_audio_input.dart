import 'dart:async';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import 'package:miniav_platform_interface/modules/miniav_audio_input_interface.dart';
import 'package:miniav_platform_interface/miniav_platform_types.dart';

import '../miniav_ffi_bindings.dart' as bindings;
import '../miniav_ffi_subscriptions.dart';
import '../miniav_ffi_types.dart';

/// FFI implementation of [MiniAudioInputPlatformInterface].
class MiniAVFFIAudioInputPlatform extends MiniAudioInputPlatformInterface {
  MiniAVFFIAudioInputPlatform();

  static final FFIDeviceChangeRegistry _deviceChangeRegistry =
      FFIDeviceChangeRegistry(
        setCallback: bindings.MiniAV_Audio_SetDeviceChangeCallback,
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
      final res = bindings.MiniAV_Audio_EnumerateDevices(
        devicesPtrPtr,
        countPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to enumerate audio input devices: ${res.name}');
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
      final res = bindings.MiniAV_Audio_GetDefaultFormat(
        deviceIdPtr.cast<ffi.Char>(),
        formatOutPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get default audio input format for $deviceId: ${res.name}',
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
  Future<List<MiniAVAudioInfo>> getSupportedFormats(String deviceId) async {
    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatsOutPtrPtr = calloc<ffi.Pointer<bindings.MiniAVAudioInfo>>();
    final countOutPtr = calloc<ffi.Uint32>();

    try {
      final res = bindings.MiniAV_Audio_GetSupportedFormats(
        deviceIdPtr.cast<ffi.Char>(),
        formatsOutPtrPtr,
        countOutPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get supported audio input formats for $deviceId: ${res.name}',
        );
      }

      final count = countOutPtr.value;
      if (count == 0) {
        return [];
      }

      final formatsPtr = formatsOutPtrPtr.value;
      final formats = <MiniAVAudioInfo>[];
      for (int i = 0; i < count; i++) {
        final formatInfoC = (formatsPtr + i).ref;
        formats.add(
          AudioInfoFFIToPlatform.fromNative(formatInfoC).toPlatformType(),
        );
      }
      if (count > 0 && formatsPtr != ffi.nullptr) {
        bindings.MiniAV_FreeDeviceList(
          formatsPtr.cast<bindings.MiniAVDeviceInfo>(),
          count,
        );
      }

      return formats;
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatsOutPtrPtr);
      calloc.free(countOutPtr);
    }
  }

  @override
  Future<MiniAudioInputContextPlatformInterface> createContext() async {
    final contextHandlePtr = calloc<bindings.MiniAVAudioContextHandle>();
    try {
      final res = bindings.MiniAV_Audio_CreateContext(contextHandlePtr);
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to create audio input context: ${res.name}');
      }
      return MiniAVFFIAudioInputContextPlatform(contextHandlePtr.value);
    } finally {
      calloc.free(contextHandlePtr);
    }
  }
}

/// FFI implementation of [MiniAudioInputContextPlatformInterface].
class MiniAVFFIAudioInputContextPlatform
    extends MiniAudioInputContextPlatformInterface {
  bindings.MiniAVAudioContextHandle? _contextHandle;
  ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>? _callbackHandle;
  FFIContextLostRegistry<bindings.MiniAVAudioContextHandle>? _lostRegistry;
  bool _isDestroyed = false;
  late final Finalizer<bindings.MiniAVAudioContextHandle> _finalizer;

  MiniAVFFIAudioInputContextPlatform(bindings.MiniAVAudioContextHandle handle)
    : _contextHandle = handle {
    // Auto-cleanup if destroy() is never called
    _finalizer = Finalizer<bindings.MiniAVAudioContextHandle>((handle) {
      print(
        'Warning: AudioInputContext was garbage collected without calling destroy()',
      );
      bindings.MiniAV_Audio_DestroyContext(handle);
    });
    _finalizer.attach(this, handle, detach: this);
  }

  /// Throws if the context has been destroyed
  void _ensureNotDestroyed() {
    if (_isDestroyed || _contextHandle == null) {
      throw StateError(
        'AudioInputContext has been destroyed. Create a new context to continue using audio input.',
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

      final res = bindings.MiniAV_Audio_Configure(
        _contextHandle!,
        deviceIdPtr.cast<ffi.Char>(),
        formatCPtr,
      );

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to configure audio input for $deviceId: ${res.name}',
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
      final res = bindings.MiniAV_Audio_GetConfiguredFormat(
        _contextHandle!,
        formatOutPtr,
      );
      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get configured audio input format: ${res.name}',
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
        print('Error in audio input user callback: $e\n$s');
      }
    }

    _callbackHandle =
        ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>.listener(
          ffiCallback,
        );

    final res = bindings.MiniAV_Audio_StartCapture(
      _contextHandle!,
      _callbackHandle!.nativeFunction,
      ffi.nullptr,
    );

    if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      await _cleanupCallback();
      throw Exception('Failed to start audio input capture: ${res.name}');
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

    final res = bindings.MiniAV_Audio_StopCapture(_contextHandle!);

    await _cleanupCallback();

    // Only warn on unexpected errors, not "already stopped" errors
    if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS &&
        res != bindings.MiniAVResultCode.MINIAV_ERROR_NOT_RUNNING) {
      print('Warning: MiniAV_Audio_StopCapture failed: ${res.name}');
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
      final res = bindings.MiniAV_Audio_DestroyContext(_contextHandle!);
      _contextHandle = null; // Clear the handle

      if (res != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to destroy audio input context: ${res.name}');
      }
    }
  }

  @override
  void Function() addLostListener(MiniAVContextLostListener listener) {
    if (_isDestroyed || _contextHandle == null) {
      throw StateError('Cannot add lost listener on a destroyed context.');
    }
    _lostRegistry ??= FFIContextLostRegistry<bindings.MiniAVAudioContextHandle>(
      context: _contextHandle!,
      setCallback: bindings.MiniAV_Audio_SetContextLostCallback,
    );
    return _lostRegistry!.add(listener);
  }
}
