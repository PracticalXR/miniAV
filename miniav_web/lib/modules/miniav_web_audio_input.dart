part of '../miniav_web.dart';

/// Web implementation of [MiniAudioInputPlatformInterface] backed by the miniav
/// WASM module (miniaudio compiled to WebAssembly). Capture goes through
/// miniaudio's Web Audio (ScriptProcessorNode) backend into an internal f32
/// ring; Dart drains it on a poll timer — the same first-party miniaudio path
/// used natively, replacing the previous hand-rolled Web-Audio-API capture.
///
/// Device enumeration still uses the browser (getUserMedia + enumerateDevices)
/// so apps can list microphones, but note miniaudio's web backend always
/// captures the system DEFAULT input — per-device selection is not routable on
/// web, so [MiniAVWebAudioInputContext.configure]'s deviceId is advisory.
class MiniAVWebAudioInputPlatform implements MiniAudioInputPlatformInterface {
  @override
  Future<List<MiniAVDeviceInfo>> enumerateDevices() async {
    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);
      // Prompt for permission so device labels are populated.
      await web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;

      final devices =
          await web.window.navigator.mediaDevices.enumerateDevices().toDart;
      final audioDevices = <MiniAVDeviceInfo>[];
      for (final device in devices.toDart) {
        if (device.kind == 'audioinput') {
          audioDevices.add(
            MiniAVDeviceInfo(
              deviceId: device.deviceId,
              name: device.label.isNotEmpty
                  ? device.label
                  : 'Microphone ${audioDevices.length + 1}',
              isDefault: audioDevices.isEmpty,
            ),
          );
        }
      }
      return audioDevices;
    } catch (e) {
      return [];
    }
  }

  @override
  Future<List<MiniAVAudioInfo>> getSupportedFormats(String deviceId) async {
    // miniaudio's web backend delivers f32; report the common rates.
    return [
      MiniAVAudioInfo(
        format: MiniAVAudioFormat.f32,
        sampleRate: 48000,
        channels: 1,
        numFrames: 256,
      ),
      MiniAVAudioInfo(
        format: MiniAVAudioFormat.f32,
        sampleRate: 48000,
        channels: 2,
        numFrames: 256,
      ),
      MiniAVAudioInfo(
        format: MiniAVAudioFormat.f32,
        sampleRate: 44100,
        channels: 1,
        numFrames: 256,
      ),
      MiniAVAudioInfo(
        format: MiniAVAudioFormat.f32,
        sampleRate: 44100,
        channels: 2,
        numFrames: 256,
      ),
    ];
  }

  @override
  Future<MiniAVAudioInfo> getDefaultFormat(String deviceId) async {
    return MiniAVAudioInfo(
      format: MiniAVAudioFormat.f32,
      sampleRate: 48000,
      channels: 1,
      // Low-latency default: on the worklet the device runs at the 128-frame
      // quantum regardless; on the ScriptProcessor fallback this is the period.
      numFrames: 256,
    );
  }

  @override
  Future<MiniAudioInputContextPlatformInterface> createContext() async {
    await wasm.MiniavWasm.instance.ensureLoaded();
    final handle = wasm.MiniavWasm.instance.createInput();
    if (handle == 0) {
      throw Exception('Failed to create audio input context (wasm).');
    }
    return MiniAVWebAudioInputContext._(handle);
  }

  static final _WebDeviceChangeWatcher _watcher = _WebDeviceChangeWatcher(
    kind: 'audioinput',
    deviceFactory: (info, isDefault) => MiniAVDeviceInfo(
      deviceId: info.deviceId,
      name: info.label.isNotEmpty ? info.label : 'Microphone',
      isDefault: isDefault,
    ),
  );

  @override
  void Function() addDeviceChangeListener(
    MiniAVDeviceChangeListener listener,
  ) => _watcher.add(listener);
}

/// Web implementation of [MiniAudioInputContextPlatformInterface].
class MiniAVWebAudioInputContext
    implements MiniAudioInputContextPlatformInterface {
  MiniAVWebAudioInputContext._(this._handle);

  int _handle;
  bool _destroyed = false;

  int _sampleRate = 48000;
  int _channels = 1;
  int _numFrames = 256; // requested buffer size (frames per callback)
  MiniAVAudioInfo? _format;

  Timer? _pollTimer;
  void Function(MiniAVBuffer buffer, Object? userData)? _onData;
  Object? _userData;

  wasm.MiniavWasm get _w => wasm.MiniavWasm.instance;

  @override
  void Function() addLostListener(MiniAVContextLostListener listener) => () {};

  @override
  Future<void> configure(String deviceId, MiniAVAudioInfo format) async {
    if (_destroyed) throw StateError('Audio input context destroyed.');
    _sampleRate = format.sampleRate;
    _channels = format.channels;
    // Requested buffer size (frames per callback). This becomes the device
    // period so callbacks arrive at the requested rate — otherwise miniaudio's
    // Web Audio backend defaults to ~2048 frames (~42.7 ms), halving the
    // callback rate. 0 => a sane default.
    _numFrames = format.numFrames > 0 ? format.numFrames : 256;

    // miniaudio's web backend captures the default device; deviceId is
    // advisory (not routable on web). Force f32 to match the ring ABI.
    final cfg = _w.configureInput(
      _handle,
      MiniAVAudioFormat.f32.index,
      _sampleRate,
      _channels,
      _numFrames,
    );
    if (cfg != wasm.kSuccess) {
      throw Exception('Failed to configure audio input (wasm): $cfg');
    }
    final en = _w.enableBufferedCapture(_handle, 0); // 0 => ~200 ms ring
    if (en != wasm.kSuccess) {
      throw Exception('Failed to enable buffered capture (wasm): $en');
    }
    _format = MiniAVAudioInfo(
      format: MiniAVAudioFormat.f32,
      sampleRate: _sampleRate,
      channels: _channels,
      numFrames: _numFrames,
    );
  }

  @override
  Future<MiniAVAudioInfo> getConfiguredFormat() async {
    final f = _format;
    if (f == null) throw StateError('Audio input not configured.');
    return f;
  }

  @override
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onData, {
    Object? userData,
  }) async {
    if (_destroyed) throw StateError('Audio input context destroyed.');
    await stopCapture(); // idempotent restart

    // Gesture-critical: prime the mic permission from THIS call stack (which
    // should be a user gesture) BEFORE the C StartCapture. This grants the
    // origin permission; miniaudio's own internal getUserMedia then succeeds
    // without a second prompt. We immediately release our priming stream so we
    // don't hold a redundant capture.
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
    } catch (e) {
      throw Exception('Microphone permission denied or unavailable: $e');
    }

    _onData = onData;
    _userData = userData;

    // Under the AudioWorklet build this suspends until the worklet thread is up
    // (ASYNCIFY), so it is awaited. The mic then warms up asynchronously.
    final res = await _w.startCapture(_handle);
    if (res != wasm.kSuccess) {
      _onData = null;
      _userData = null;
      throw Exception('Failed to start audio capture (wasm): $res');
    }

    // Poll the ring ~every 5 ms and deliver whatever has accumulated, in
    // buffers of the configured size. With the AudioWorklet build a small
    // period (~256 frames ≈ 5.3 ms) is glitch-free (it's off the main thread),
    // so this poll is the delivery-cadence floor (~browser 4-5 ms timer). The
    // ring is empty for the first few ms (mic warm-up) — we deliver nothing
    // until frames appear, no silence synthesis.
    final chunk = _numFrames > 0 ? _numFrames : 256;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (_destroyed || _onData == null) return;
      // Drain to empty each tick so a slow tick can't leave a backlog.
      while (true) {
        final avail = _w.availableCaptureFrames(_handle);
        if (avail == 0) break;
        final want = avail < chunk ? avail : chunk;
        final f32 = _w.readCaptureFrames(_handle, want, _channels);
        final frames = f32.isEmpty ? 0 : f32.length ~/ _channels;
        if (frames == 0) break;
        try {
          _onData!(_buildBuffer(f32, frames), _userData);
        } catch (e, s) {
          print('Error in audio input user callback: $e\n$s');
        }
        if (frames < want) break; // fully drained
      }
    });
  }

  MiniAVBuffer _buildBuffer(Float32List f32, int frames) {
    final info = MiniAVAudioInfo(
      format: MiniAVAudioFormat.f32,
      sampleRate: _sampleRate,
      channels: _channels,
      numFrames: frames,
    );
    final audio = MiniAVAudioBuffer(
      frameCount: frames,
      info: info,
      data: Uint8List.view(
        f32.buffer,
        f32.offsetInBytes,
        frames * _channels * 4,
      ),
    );
    return MiniAVBuffer(
      type: MiniAVBufferType.audio,
      contentType: MiniAVBufferContentType.cpu,
      timestampUs: _WebUtils._getCurrentTimestampUs(),
      data: audio,
      dataSizeBytes: frames * _channels * 4,
    );
  }

  @override
  Future<void> stopCapture() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _onData = null;
    _userData = null;
    if (!_destroyed) _w.stopCapture(_handle);
  }

  @override
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _onData = null;
    _userData = null;
    _w.destroyInput(_handle);
    _handle = 0;
  }
}
