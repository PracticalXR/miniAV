// Bind these hand-written @ffi.Native externs to the SAME native asset as the
// ffigen-generated bindings (the built miniav_c library). Without this, their
// asset id defaults to this file's own URI and symbol resolution fails.
@ffi.DefaultAsset('package:miniav_ffi/miniav_ffi_bindings.dart')
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'package:miniav_platform_interface/modules/miniav_audio_output_interface.dart';
import 'package:miniav_platform_interface/miniav_platform_types.dart';

import '../miniav_ffi_bindings.dart' as bindings;
import '../miniav_ffi_types.dart';

// --- Hand-written bindings for the audio-output (playback) C API ---------
//
// These mirror the ffigen `@ffi.Native` style but are declared here so the
// generated `miniav_ffi_bindings.dart` (which ffigen owns/overwrites) doesn't
// need regenerating. The handle is an opaque `Pointer<Void>`; result codes are
// raw ints (0 == MINIAV_SUCCESS). The trivial pure-C calls are `isLeaf` for a
// cheaper, safepoint-free hot path.

@ffi.Native<ffi.Pointer<ffi.Void> Function()>(
  symbol: 'MiniAV_AudioOutput_CreateContext',
)
external ffi.Pointer<ffi.Void> _aoCreate();

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_DestroyContext',
)
external int _aoDestroy(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<ffi.Pointer<bindings.MiniAVDeviceInfo>>,
    ffi.Pointer<ffi.Uint32>,
  )
>(symbol: 'MiniAV_AudioOutput_EnumerateDevices')
external int _aoEnumerate(
  ffi.Pointer<ffi.Pointer<bindings.MiniAVDeviceInfo>> devices,
  ffi.Pointer<ffi.Uint32> count,
);

@ffi.Native<
  ffi.Int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<bindings.MiniAVAudioInfo>)
>(symbol: 'MiniAV_AudioOutput_GetDefaultFormat')
external int _aoGetDefaultFormat(
  ffi.Pointer<ffi.Char> deviceId,
  ffi.Pointer<bindings.MiniAVAudioInfo> out,
);

@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Char>,
    ffi.Int,
    ffi.Uint32,
    ffi.Uint32,
    ffi.Uint32,
  )
>(symbol: 'MiniAV_AudioOutput_Configure')
external int _aoConfigure(
  ffi.Pointer<ffi.Void> ctx,
  ffi.Pointer<ffi.Char> deviceId,
  int format,
  int sampleRate,
  int channels,
  int bufferFrames,
);

@ffi.Native<
  ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<bindings.MiniAVAudioInfo>)
>(symbol: 'MiniAV_AudioOutput_GetConfiguredFormat')
external int _aoGetConfiguredFormat(
  ffi.Pointer<ffi.Void> ctx,
  ffi.Pointer<bindings.MiniAVAudioInfo> out,
);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_Start',
)
external int _aoStart(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_Stop',
)
external int _aoStop(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_Clear',
)
external int _aoClear(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<
  ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Uint32)
>(symbol: 'MiniAV_AudioOutput_WriteFrames', isLeaf: true)
external int _aoWriteFrames(
  ffi.Pointer<ffi.Void> ctx,
  ffi.Pointer<ffi.Float> interleaved,
  int frameCount,
);

@ffi.Native<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_GetBufferedFrames',
  isLeaf: true,
)
external int _aoGetBufferedFrames(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_GetWritableFrames',
  isLeaf: true,
)
external int _aoGetWritableFrames(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Float)>(
  symbol: 'MiniAV_AudioOutput_SetVolume',
  isLeaf: true,
)
external int _aoSetVolume(ffi.Pointer<ffi.Void> ctx, double volume);

@ffi.Native<ffi.Float Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_GetVolume',
  isLeaf: true,
)
external double _aoGetVolume(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Float)>(
  symbol: 'MiniAV_AudioOutput_SetPan',
  isLeaf: true,
)
external int _aoSetPan(ffi.Pointer<ffi.Void> ctx, double pan);

@ffi.Native<ffi.Float Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_GetPan',
  isLeaf: true,
)
external double _aoGetPan(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Float)>(
  symbol: 'MiniAV_AudioOutput_SetPitch',
  isLeaf: true,
)
external int _aoSetPitch(ffi.Pointer<ffi.Void> ctx, double pitch);

@ffi.Native<ffi.Float Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_GetPitch',
  isLeaf: true,
)
external double _aoGetPitch(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_AudioOutput_IsStarted',
  isLeaf: true,
)
external int _aoIsStarted(ffi.Pointer<ffi.Void> ctx);

const int _kSuccess = 0; // MINIAV_SUCCESS

/// FFI implementation of [MiniAudioOutputPlatformInterface].
class MiniAVFFIAudioOutputPlatform extends MiniAudioOutputPlatformInterface {
  MiniAVFFIAudioOutputPlatform();

  @override
  Future<List<MiniAVDeviceInfo>> enumerateDevices() async {
    final devicesPtrPtr = calloc<ffi.Pointer<bindings.MiniAVDeviceInfo>>();
    final countPtr = calloc<ffi.Uint32>();
    try {
      final res = _aoEnumerate(devicesPtrPtr, countPtr);
      if (res != _kSuccess) {
        throw Exception('Failed to enumerate audio output devices: $res');
      }
      final count = countPtr.value;
      if (count == 0) return [];
      final devicesPtr = devicesPtrPtr.value;
      final devices = <MiniAVDeviceInfo>[];
      for (int i = 0; i < count; i++) {
        devices.add(
          DeviceInfoFFIToPlatform.fromNative(
            (devicesPtr + i).ref,
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
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId) async {
    final deviceIdPtr = deviceId.toNativeUtf8();
    final formatOutPtr = calloc<bindings.MiniAVAudioInfo>();
    try {
      final res = _aoGetDefaultFormat(
        deviceIdPtr.cast<ffi.Char>(),
        formatOutPtr,
      );
      if (res != _kSuccess) {
        throw Exception('Failed to get default audio output format: $res');
      }
      return AudioInfoFFIToPlatform.fromNative(formatOutPtr.ref).toPlatformType();
    } finally {
      calloc.free(deviceIdPtr);
      calloc.free(formatOutPtr);
    }
  }

  @override
  Future<MiniAudioOutputContextPlatformInterface> createContext() async {
    final handle = _aoCreate();
    if (handle == ffi.nullptr) {
      throw Exception('Failed to create audio output context');
    }
    return MiniAVFFIAudioOutputContextPlatform(handle);
  }
}

/// FFI implementation of [MiniAudioOutputContextPlatformInterface].
class MiniAVFFIAudioOutputContextPlatform
    extends MiniAudioOutputContextPlatformInterface {
  MiniAVFFIAudioOutputContextPlatform(ffi.Pointer<ffi.Void> handle)
    : _handle = handle {
    _finalizer = Finalizer<ffi.Pointer<ffi.Void>>((h) {
      _aoDestroy(h);
    });
    _finalizer.attach(this, handle, detach: this);
  }

  ffi.Pointer<ffi.Void>? _handle;
  late final Finalizer<ffi.Pointer<ffi.Void>> _finalizer;
  bool _destroyed = false;
  int _channels = 0;

  // Reusable native scratch buffer for writeFrames (grows as needed) so the
  // per-chunk hot path allocates no native memory after warm-up.
  ffi.Pointer<ffi.Float> _scratch = ffi.nullptr;
  int _scratchFloats = 0;

  void _ensureNotDestroyed() {
    if (_destroyed || _handle == null) {
      throw StateError('AudioOutputContext has been destroyed.');
    }
  }

  @override
  Future<void> configure(
    String deviceId,
    MiniAVAudioInfo format, {
    int bufferFrames = 0,
  }) async {
    _ensureNotDestroyed();
    _channels = format.channels;
    final deviceIdPtr = deviceId.toNativeUtf8();
    try {
      final res = _aoConfigure(
        _handle!,
        deviceIdPtr.cast<ffi.Char>(),
        format.format.index, // platform enum index == C MiniAVAudioFormat value
        format.sampleRate,
        format.channels,
        bufferFrames,
      );
      if (res != _kSuccess) {
        throw Exception('Failed to configure audio output: $res');
      }
    } finally {
      calloc.free(deviceIdPtr);
    }
  }

  @override
  Future<MiniAVAudioInfo> getConfiguredFormat() async {
    _ensureNotDestroyed();
    final out = calloc<bindings.MiniAVAudioInfo>();
    try {
      final res = _aoGetConfiguredFormat(_handle!, out);
      if (res != _kSuccess) {
        throw Exception('Failed to get configured audio output format: $res');
      }
      return AudioInfoFFIToPlatform.fromNative(out.ref).toPlatformType();
    } finally {
      calloc.free(out);
    }
  }

  @override
  Future<void> start() async {
    _ensureNotDestroyed();
    final res = _aoStart(_handle!);
    if (res != _kSuccess) throw Exception('Failed to start audio output: $res');
  }

  @override
  Future<void> stop() async {
    if (_destroyed || _handle == null) return;
    _aoStop(_handle!);
  }

  @override
  Future<void> clear() async {
    if (_destroyed || _handle == null) return;
    _aoClear(_handle!);
  }

  @override
  int writeFrames(Float32List interleaved, int frameCount) {
    if (_destroyed || _handle == null) return 0;
    final channels = _channels <= 0 ? 1 : _channels;
    var floats = frameCount * channels;
    if (floats <= 0) return 0;
    if (floats > interleaved.length) floats = interleaved.length;
    final frames = floats ~/ channels;
    if (frames <= 0) return 0;

    if (_scratchFloats < floats) {
      if (_scratch != ffi.nullptr) calloc.free(_scratch);
      _scratch = calloc<ffi.Float>(floats);
      _scratchFloats = floats;
    }
    _scratch.asTypedList(floats).setRange(0, floats, interleaved);
    return _aoWriteFrames(_handle!, _scratch, frames);
  }

  @override
  int get bufferedFrames =>
      (_destroyed || _handle == null) ? 0 : _aoGetBufferedFrames(_handle!);

  @override
  int get writableFrames =>
      (_destroyed || _handle == null) ? 0 : _aoGetWritableFrames(_handle!);

  @override
  double get volume =>
      (_destroyed || _handle == null) ? 0.0 : _aoGetVolume(_handle!);

  @override
  set volume(double value) {
    if (_destroyed || _handle == null) return;
    _aoSetVolume(_handle!, value);
  }

  @override
  double get pan => (_destroyed || _handle == null) ? 0.0 : _aoGetPan(_handle!);

  @override
  set pan(double value) {
    if (_destroyed || _handle == null) return;
    _aoSetPan(_handle!, value);
  }

  @override
  double get pitch =>
      (_destroyed || _handle == null) ? 1.0 : _aoGetPitch(_handle!);

  @override
  set pitch(double value) {
    if (_destroyed || _handle == null) return;
    _aoSetPitch(_handle!, value);
  }

  @override
  bool get isStarted =>
      (_destroyed || _handle == null) ? false : _aoIsStarted(_handle!) != 0;

  @override
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    final h = _handle;
    _handle = null;
    if (h != null) {
      _finalizer.detach(this);
      _aoDestroy(h);
    }
    if (_scratch != ffi.nullptr) {
      calloc.free(_scratch);
      _scratch = ffi.nullptr;
      _scratchFloats = 0;
    }
  }
}
