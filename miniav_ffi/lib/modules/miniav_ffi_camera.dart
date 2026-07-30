import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import '../miniav_ffi_subscriptions.dart';
import '../miniav_ffi_types.dart';
import '../miniav_ffi_bindings.dart' as bindings;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

class MiniFFICameraPlatform implements MiniCameraPlatformInterface {
  static final FFIDeviceChangeRegistry _deviceChangeRegistry =
      FFIDeviceChangeRegistry(
        setCallback: bindings.MiniAV_Camera_SetDeviceChangeCallback,
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
      final result = bindings.MiniAV_Camera_EnumerateDevices(
        devicesPtrPtr,
        countPtr,
      );
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to enumerate camera devices');
      }
      final devicesArrayPtr = devicesPtrPtr.value;
      final count = countPtr.value;
      if (devicesArrayPtr == ffi.nullptr || count == 0) {
        return <MiniAVDeviceInfo>[];
      }
      final deviceList = <MiniAVDeviceInfo>[];
      for (int i = 0; i < count; i++) {
        final ffiDevice = (devicesArrayPtr + i).ref;
        deviceList.add(
          DeviceInfoFFIToPlatform.fromNative(ffiDevice).toPlatformType(),
        );
      }
      bindings.MiniAV_FreeDeviceList(devicesArrayPtr, count);
      return deviceList;
    } finally {
      calloc.free(devicesPtrPtr);
      calloc.free(countPtr);
    }
  }

  @override
  Future<List<MiniAVVideoInfo>> getSupportedFormats(String deviceId) async {
    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatsPtrPtr = calloc<ffi.Pointer<bindings.MiniAVVideoInfo>>();
    final countPtr = calloc<ffi.Uint32>();
    try {
      final result = bindings.MiniAV_Camera_GetSupportedFormats(
        deviceIdPtr.cast(),
        formatsPtrPtr,
        countPtr,
      );
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to get supported formats');
      }
      final formatsArrayPtr = formatsPtrPtr.value;
      final count = countPtr.value;
      if (formatsArrayPtr == ffi.nullptr || count == 0) {
        return <MiniAVVideoInfo>[];
      }
      final formatList = <MiniAVVideoInfo>[];
      for (int i = 0; i < count; i++) {
        final ffiFormat = (formatsArrayPtr + i).ref;
        formatList.add(
          VideoFormatInfoFFIToPlatform.fromNative(ffiFormat).toPlatformType(),
        );
      }
      bindings.MiniAV_FreeFormatList(formatsArrayPtr.cast<ffi.Void>(), count);
      return formatList;
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatsPtrPtr);
      calloc.free(countPtr);
    }
  }

  @override
  Future<MiniAVVideoInfo> getDefaultFormat(String deviceId) async {
    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatOutPtr = calloc<bindings.MiniAVVideoInfo>();
    try {
      final result = bindings.MiniAV_Camera_GetDefaultFormat(
        deviceIdPtr.cast(),
        formatOutPtr,
      );
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get default format for device $deviceId: ${result.name}',
        );
      }
      return VideoFormatInfoFFIToPlatform.fromNative(
        formatOutPtr.ref,
      ).toPlatformType();
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatOutPtr);
    }
  }

  @override
  Future<MiniCameraContextPlatformInterface> createContext() async {
    final contextPtr = calloc<bindings.MiniAVCameraContextHandle>();
    try {
      final result = bindings.MiniAV_Camera_CreateContext(contextPtr);
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to create camera context');
      }
      return MiniFFICameraContext(contextPtr.value);
    } finally {
      calloc.free(contextPtr);
    }
  }
}

class MiniFFICameraContext implements MiniCameraContextPlatformInterface {
  bindings.MiniAVCameraContextHandle? _context;
  ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>? _callbackHandle;
  FFIContextLostRegistry<bindings.MiniAVCameraContextHandle>? _lostRegistry;
  bool _isDestroyed = false;

  /// Set for the window between "native capture has been told to stop" and
  /// "the NativeCallable is closed". Buffers that arrive in that window are
  /// released natively instead of being handed to the user callback — see
  /// [_drainPendingCallbacks].
  bool _stopping = false;
  late final Finalizer<bindings.MiniAVCameraContextHandle> _finalizer;

  MiniFFICameraContext(bindings.MiniAVCameraContextHandle context)
    : _context = context {
    // Auto-cleanup if destroy() is never called
    _finalizer = Finalizer<bindings.MiniAVCameraContextHandle>((handle) {
      print(
        'Warning: CameraContext was garbage collected without calling destroy()',
      );
      bindings.MiniAV_Camera_DestroyContext(handle);
    });
    _finalizer.attach(this, context, detach: this);
  }

  /// Throws if the context has been destroyed
  void _ensureNotDestroyed() {
    if (_isDestroyed || _context == null) {
      throw StateError(
        'CameraContext has been destroyed. Create a new context to continue using camera.',
      );
    }
  }

  /// Whether this context has been destroyed
  bool get isDestroyed => _isDestroyed;

  @override
  Future<void> configure(String deviceId, MiniAVVideoInfo format) async {
    _ensureNotDestroyed();

    final deviceIdPtr = deviceId.toNativeUtf8();
    final nativeFormatPtr = calloc<bindings.MiniAVVideoInfo>();
    try {
      VideoFormatInfoFFIToPlatform.copyToNative(format, nativeFormatPtr.ref);
      final result = bindings.MiniAV_Camera_Configure(
        _context!,
        deviceIdPtr.cast(),
        nativeFormatPtr.cast(),
      );
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to configure camera: ${result.name}');
      }
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(nativeFormatPtr);
    }
  }

  @override
  Future<MiniAVVideoInfo> getConfiguredFormat() async {
    _ensureNotDestroyed();

    final formatOutPtr = calloc<bindings.MiniAVVideoInfo>();
    try {
      final result = bindings.MiniAV_Camera_GetConfiguredFormat(
        _context!,
        formatOutPtr,
      );
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception(
          'Failed to get configured camera format: ${result.name}',
        );
      }
      return VideoFormatInfoFFIToPlatform.fromNative(
        formatOutPtr.ref,
      ).toPlatformType();
    } finally {
      calloc.free(formatOutPtr);
    }
  }

  @override
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  }) async {
    _ensureNotDestroyed();

    await stopCapture(); // Clean up any previous callback

    void ffiCallback(
      ffi.Pointer<bindings.MiniAVBuffer> buffer,
      ffi.Pointer<ffi.Void> cbUserData,
    ) {
      // Check if context was destroyed (or is stopping) during callback.
      // Still release the buffer to avoid leaking native resources — on the
      // GPU path the payload owns a D3D11 texture ref AND a shared NT handle.
      if (_isDestroyed || _stopping) {
        final handle = buffer.ref.internal_handle;
        if (handle != ffi.nullptr) {
          bindings.MiniAV_ReleaseBuffer(handle);
        }
        return;
      }

      final platformBuffer = MiniAVBufferFFI.fromPointer(buffer);
      try {
        onFrame(platformBuffer, userData);
      } catch (e, s) {
        print('Error in camera user callback: $e\n$s');
      }
    }

    _callbackHandle =
        ffi.NativeCallable<bindings.MiniAVBufferCallbackFunction>.listener(
          ffiCallback,
        );

    final result = bindings.MiniAV_Camera_StartCapture(
      _context!,
      _callbackHandle!.nativeFunction,
      ffi.nullptr,
    );

    if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      await _cleanupCallback();
      throw Exception('Failed to start camera capture: ${result.name}');
    }
  }

  /// Lets buffers already posted to the NativeCallable's port — but not yet
  /// delivered to this isolate — run before the callable is closed.
  ///
  /// `NativeCallable.listener.close()` DROPS undelivered messages, and a
  /// dropped buffer is never passed to `MiniAV_ReleaseBuffer`: on the GPU path
  /// that leaks a D3D11 texture reference *and* a shared NT handle per dropped
  /// frame. The native StopCapture has already quiesced the capture thread by
  /// the time this runs, so no new buffers can be queued; yielding a few
  /// event-loop turns drains whatever is in flight into the `_stopping`
  /// fast-release branch of `ffiCallback`.
  Future<void> _drainPendingCallbacks() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _cleanupCallback() async {
    _callbackHandle?.close();
    _callbackHandle = null;
    _stopping = false;
  }

  @override
  Future<void> stopCapture() async {
    // Don't throw if already stopped (or never started) - this is idempotent.
    // Also covers "already destroyed": destroy() nulls _callbackHandle.
    if (_callbackHandle == null) {
      _stopping = false;
      return;
    }

    // Route any in-flight buffer straight to MiniAV_ReleaseBuffer from here on.
    _stopping = true;

    // Stop the native capture thread first so nothing new can be queued. This
    // also runs on the destroy() path (_isDestroyed is already true but
    // _context is still live) — previously destroy() skipped it and closed the
    // callable immediately, dropping (and leaking) any in-flight buffer.
    bindings.MiniAVResultCode? result;
    if (_context != null) {
      result = bindings.MiniAV_Camera_StopCapture(_context!);
    }

    await _drainPendingCallbacks();
    await _cleanupCallback();

    // Only warn on unexpected errors, not "already stopped" errors
    if (result != null &&
        result != bindings.MiniAVResultCode.MINIAV_SUCCESS &&
        result != bindings.MiniAVResultCode.MINIAV_ERROR_NOT_RUNNING) {
      print('Warning: MiniAV_Camera_StopCapture failed: ${result.name}');
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

    if (_context != null) {
      _finalizer.detach(this); // Prevent finalizer from running
      final result = bindings.MiniAV_Camera_DestroyContext(_context!);
      _context = null; // Clear the handle

      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to destroy camera context: ${result.name}');
      }
    }
  }

  @override
  void Function() addLostListener(MiniAVContextLostListener listener) {
    if (_isDestroyed || _context == null) {
      throw StateError('Cannot add lost listener on a destroyed context.');
    }
    _lostRegistry ??=
        FFIContextLostRegistry<bindings.MiniAVCameraContextHandle>(
          context: _context!,
          setCallback: bindings.MiniAV_Camera_SetContextLostCallback,
        );
    return _lostRegistry!.add(listener);
  }
}
