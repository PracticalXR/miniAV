import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:miniav_ffi/modules/miniav_ffi_audio_input.dart';
import 'package:miniav_ffi/modules/miniav_ffi_audio_output.dart';
import 'package:miniav_ffi/modules/miniav_ffi_loopback.dart';
import 'package:miniav_ffi/modules/miniav_ffi_input.dart';
import 'package:miniav_ffi/modules/miniav_ffi_inject.dart';
import 'miniav_ffi_bindings.dart' as bindings;
import 'modules/miniav_ffi_camera.dart';
import 'modules/miniav_ffi_screen.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart';

// Export camera FFI implementation for external use
export 'modules/miniav_ffi_camera.dart';
export 'modules/miniav_ffi_screen.dart';
export 'modules/miniav_ffi_audio_input.dart';
export 'modules/miniav_ffi_audio_output.dart';
export 'modules/miniav_ffi_loopback.dart';
export 'modules/miniav_ffi_input.dart';
export 'modules/miniav_ffi_inject.dart';

// --- Platform Implementation ---

class MiniAVFFIPlatform extends MiniAVPlatformInterface {
  MiniAVFFIPlatform();

  final MiniFFICameraPlatform _camera = MiniFFICameraPlatform();
  final MiniFFIScreenPlatform _screen = MiniFFIScreenPlatform();
  final MiniAVFFILoopbackPlatform _loopback = MiniAVFFILoopbackPlatform();
  final MiniAVFFIAudioInputPlatform _audioInput = MiniAVFFIAudioInputPlatform();
  final MiniAVFFIAudioOutputPlatform _audioOutput =
      MiniAVFFIAudioOutputPlatform();
  final MiniAVFFIInputPlatform _input = MiniAVFFIInputPlatform();
  final MiniAVFFIInjectPlatform _inject = MiniAVFFIInjectPlatform();

  @override
  MiniCameraPlatformInterface get camera => _camera;

  @override
  MiniScreenPlatformInterface get screen => _screen;

  @override
  MiniAudioInputPlatformInterface get audioInput => _audioInput;

  @override
  MiniAudioOutputPlatformInterface get audioOutput => _audioOutput;

  @override
  MiniLoopbackPlatformInterface get loopback => _loopback;

  @override
  MiniInputPlatformInterface get input => _input;

  @override
  MiniInjectPlatformInterface get inject => _inject;

  @override
  String getVersionString() {
    final ptr = bindings.MiniAV_GetVersionString();
    if (ptr == ffi.nullptr) return "Unknown Version";
    return ptr.cast<Utf8>().toDartString();
  }

  @override
  void setLogLevel(int level) {
    // The platform interface enum index order is: none=0, trace=1, debug=2,
    // info=3, warn=4, error=5.  The C enum order is: TRACE=0, DEBUG=1,
    // INFO=2, WARN=3, ERROR=4, NONE=5.  They differ: none is first in Dart
    // but last in C.  Map by semantic meaning, not by index.
    //   platform none(0) → C NONE(5), trace(1)→TRACE(0), debug(2)→DEBUG(1),
    //   info(3)→INFO(2), warn(4)→WARN(3), error(5)→ERROR(4).
    final cValue = level == 0 ? 5 : level - 1;
    final result = bindings.MiniAV_SetLogLevel(
      bindings.MiniAVLogLevel.fromValue(cValue),
    );
    if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
      throw Exception('Failed to set log level');
    }
  }

  // ---- Log callback --------------------------------------------------------
  // A single NativeCallable that forwards MiniAV C-library log messages to a
  // Dart closure. The callable is kept alive for the lifetime of the
  // registration; it is closed and replaced on each new setLogCallback call.

  ffi.NativeCallable<bindings.MiniAVLogCallbackFunction>? _logCallable;

  /// Decodes a null-terminated C string using [Utf8Decoder] with
  /// [allowMalformed] so that log messages containing non-UTF-8 bytes
  /// (e.g. device names with Latin-1 characters) never throw.
  static String _decodeCString(ffi.Pointer<ffi.Char> ptr) {
    if (ptr.address == 0) return '';
    final bytes = ptr.cast<ffi.Uint8>();
    var len = 0;
    while (bytes[len] != 0) len++;
    return const Utf8Decoder(
      allowMalformed: true,
    ).convert(Uint8List.view(bytes.asTypedList(len).buffer, 0, len));
  }

  @override
  void setLogCallback(void Function(int level, String message)? callback) {
    // Install the new native callback first, then close the old NativeCallable
    // to guarantee we never invoke a closed callable.
    final old = _logCallable;
    _logCallable = null;

    if (callback == null) {
      bindings.MiniAV_SetLogCallback(ffi.nullptr, ffi.nullptr);
      old?.close();
      return;
    }

    // NativeCallable.listener dispatches on the Dart event loop, so the Dart
    // closure can freely use Dart objects (including stderr). The native side
    // hands over a HEAP-ALLOCATED message (it must outlive the asynchronous
    // dispatch) which we own and must release via MiniAV_Free after decoding.
    final nc = ffi.NativeCallable<bindings.MiniAVLogCallbackFunction>.listener((
      int levelInt,
      ffi.Pointer<ffi.Char> message,
      ffi.Pointer<ffi.Void> _,
    ) {
      final text = _decodeCString(message);
      if (message.address != 0) {
        bindings.MiniAV_Free(message.cast());
      }
      callback(levelInt, text);
    });
    bindings.MiniAV_SetLogCallback(nc.nativeFunction, ffi.nullptr);
    _logCallable = nc;
    old?.close();
  }

  @override
  void dispose() {
    // Atomically disable callback dispatch and wait for any in-flight
    // callback invocations to finish.  Safe to call from Flutter's
    // reassemble() before the Dart isolate closes its NativeCallable handles.
    bindings.MiniAV_Dispose();
  }

  @override
  Future<void> releaseBuffer(MiniAVBuffer buffer) async {
    releaseBufferSync(buffer);
  }

  /// Synchronous buffer release. The underlying C call `MiniAV_ReleaseBuffer`
  /// is itself synchronous, so this does the work inline with no [Future] /
  /// microtask allocation — the recorder's per-frame capture callback uses this
  /// rather than the async [releaseBuffer] to keep the hot path allocation-free.
  @override
  void releaseBufferSync(MiniAVBuffer buffer) {
    final nativeHandle = buffer.nativeHandle;
    try {
      if (nativeHandle != null && nativeHandle is ffi.Pointer) {
        final result = bindings.MiniAV_ReleaseBuffer(
          nativeHandle.cast<ffi.Void>(),
        );
        if (result != bindings.MiniAVResultCode.MINIAV_SUCCESS) {
          throw Exception('Failed to release buffer: $result');
        }
      }
    } catch (e) {
      print('Error releasing buffer: $e');
    }
  }
}

MiniAVPlatformInterface registeredInstance() => MiniAVFFIPlatform();
