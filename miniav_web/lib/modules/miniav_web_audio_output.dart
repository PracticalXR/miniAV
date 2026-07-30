part of '../miniav_web.dart';

/// Web implementation of [MiniAudioOutputPlatformInterface] backed by the
/// miniav WASM module (miniaudio compiled to WebAssembly). Playback goes
/// through miniaudio's Web Audio backend, so the sink behaves identically to
/// native.
class MiniAVWebAudioOutputPlatform implements MiniAudioOutputPlatformInterface {
  @override
  Future<List<MiniAVDeviceInfo>> enumerateDevices() async {
    // Browsers do not expose output device lists to miniaudio; the WASM build
    // routes to the system default sink. Report a single default entry.
    return [
      MiniAVDeviceInfo(
        deviceId: 'default',
        name: 'Default Output',
        isDefault: true,
      ),
    ];
  }

  @override
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId) async {
    return MiniAVAudioInfo(
      format: MiniAVAudioFormat.f32,
      sampleRate: 48000,
      channels: 2,
      numFrames: 0,
    );
  }

  @override
  Future<MiniAudioOutputContextPlatformInterface> createContext() async {
    await wasm.MiniavWasm.instance.ensureLoaded();
    final handle = wasm.MiniavWasm.instance.createOutput();
    if (handle == 0) {
      throw Exception('Failed to create audio output context (wasm).');
    }
    return MiniAVWebAudioOutputContext._(handle);
  }

  @override
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => () {};
}

/// Web implementation of [MiniAudioOutputContextPlatformInterface].
class MiniAVWebAudioOutputContext
    implements MiniAudioOutputContextPlatformInterface {
  MiniAVWebAudioOutputContext._(this._handle);

  int _handle;
  MiniAVAudioInfo? _format;
  bool _destroyed = false;

  wasm.MiniavWasm get _w => wasm.MiniavWasm.instance;

  @override
  Future<void> configure(
    String deviceId,
    MiniAVAudioInfo format, {
    int bufferFrames = 0,
  }) async {
    _format = format;
    // Under the AudioWorklet build ma_engine_init spins up the worklet thread
    // and suspends (ASYNCIFY), so this is awaited.
    final res = await _w.configureOutput(
      _handle,
      format.format.index, // platform enum index == C MiniAVAudioFormat value
      format.sampleRate,
      format.channels,
      bufferFrames,
    );
    if (res != wasm.kSuccess) {
      throw Exception('Failed to configure audio output (wasm): $res');
    }
  }

  @override
  Future<MiniAVAudioInfo> getConfiguredFormat() async {
    final f = _format;
    if (f == null) throw StateError('Audio output not configured.');
    return f;
  }

  @override
  Future<void> start() async {
    final res = await _w.startOutput(_handle);
    if (res != wasm.kSuccess) {
      throw Exception('Failed to start audio output (wasm): $res');
    }
  }

  @override
  Future<void> stop() async {
    if (!_destroyed) _w.stopOutput(_handle);
  }

  @override
  Future<void> clear() async {
    if (!_destroyed) _w.clearOutput(_handle);
  }

  @override
  int writeFrames(Float32List interleaved, int frameCount) {
    if (_destroyed) return 0;
    final channels = _format?.channels ?? 1;
    return _w.writeFrames(_handle, interleaved, frameCount, channels);
  }

  @override
  int get bufferedFrames => _destroyed ? 0 : _w.bufferedFrames(_handle);

  @override
  int get writableFrames => _destroyed ? 0 : _w.writableFrames(_handle);

  @override
  double get volume => _destroyed ? 0.0 : _w.getVolume(_handle);
  @override
  set volume(double value) {
    if (!_destroyed) _w.setVolume(_handle, value);
  }

  @override
  double get pan => _destroyed ? 0.0 : _w.getPan(_handle);
  @override
  set pan(double value) {
    if (!_destroyed) _w.setPan(_handle, value);
  }

  @override
  double get pitch => _destroyed ? 1.0 : _w.getPitch(_handle);
  @override
  set pitch(double value) {
    if (!_destroyed) _w.setPitch(_handle, value);
  }

  @override
  bool get isStarted => _destroyed ? false : _w.isStarted(_handle);

  @override
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    _w.destroyOutput(_handle);
    _handle = 0;
  }

  @override
  void Function() addLostListener(MiniAVContextLostListener listener) => () {};
}
