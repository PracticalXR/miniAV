import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import '../miniav_ffi_bindings.dart' as bindings;

/// FFI implementation of [MiniInjectPlatformInterface] (input injection).
class MiniAVFFIInjectPlatform implements MiniInjectPlatformInterface {
  @override
  Future<MiniInjectContextPlatformInterface> createContext() async {
    final ctxPtr = calloc<bindings.MiniAVInjectContextHandle>();
    try {
      final result = bindings.MiniAV_Inject_CreateContext(ctxPtr);
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to create injection context: ${result.name}');
      }
      return MiniAVFFIInjectContext(ctxPtr.value);
    } finally {
      calloc.free(ctxPtr);
    }
  }
}

class MiniAVFFIInjectContext implements MiniInjectContextPlatformInterface {
  bindings.MiniAVInjectContextHandle? _context;
  bool _isDestroyed = false;

  MiniAVFFIInjectContext(bindings.MiniAVInjectContextHandle context)
    : _context = context;

  void _ensureNotDestroyed() {
    if (_isDestroyed || _context == null) {
      throw StateError(
        'InjectContext has been destroyed. Create a new context to continue.',
      );
    }
  }

  @override
  Future<void> configure(int inputTypes) async {
    _ensureNotDestroyed();
    final result = bindings.MiniAV_Inject_Configure(_context!, inputTypes);
    if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      throw Exception('Failed to configure injection: ${result.name}');
    }
  }

  @override
  Future<void> injectKeyboard(MiniAVKeyboardEvent event) async {
    _ensureNotDestroyed();
    final ptr = calloc<bindings.MiniAVKeyboardEvent>();
    try {
      final n = ptr.ref;
      n.timestamp_us = event.timestampUs;
      n.key_code = event.keyCode;
      n.scan_code = event.scanCode;
      n.actionAsInt = event.action.value;
      final result = bindings.MiniAV_Inject_Keyboard(_context!, ptr);
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to inject keyboard event: ${result.name}');
      }
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> injectMouse(MiniAVMouseEvent event) async {
    _ensureNotDestroyed();
    final ptr = calloc<bindings.MiniAVMouseEvent>();
    try {
      final n = ptr.ref;
      n.timestamp_us = event.timestampUs;
      n.x = event.x;
      n.y = event.y;
      n.delta_x = event.deltaX;
      n.delta_y = event.deltaY;
      n.wheel_delta = event.wheelDelta;
      n.wheel_delta_x = event.wheelDeltaX;
      n.actionAsInt = event.action.value;
      n.buttonAsInt = event.button.value;
      n.is_absolute = event.isAbsolute;
      final result = bindings.MiniAV_Inject_Mouse(_context!, ptr);
      if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
        throw Exception('Failed to inject mouse event: ${result.name}');
      }
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> destroy() async {
    if (_isDestroyed || _context == null) return;
    _isDestroyed = true;
    final handle = _context!;
    _context = null;
    final result = bindings.MiniAV_Inject_DestroyContext(handle);
    if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      throw Exception('Failed to destroy injection context: ${result.name}');
    }
  }
}
