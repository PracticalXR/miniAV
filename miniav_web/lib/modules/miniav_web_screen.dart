part of '../miniav_web.dart';

/// Web implementation of [MiniScreenPlatformInterface]
class MiniAVWebScreenPlatform implements MiniScreenPlatformInterface {
  @override
  Future<List<MiniAVDeviceInfo>> enumerateDisplays() async {
    // Single logical screen option
    return [
      MiniAVDeviceInfo(deviceId: 'screen', name: 'Screen', isDefault: true),
    ];
  }

  @override
  Future<List<MiniAVDeviceInfo>> enumerateWindows() async {
    // Not supported on web
    return [];
  }

  @override
  Future<ScreenFormatDefaults> getDefaultFormats(String displayId) async {
    final videoFormat = MiniAVVideoInfo(
      width: 1920,
      height: 1080,
      pixelFormat: MiniAVPixelFormat.rgba32,
      frameRateNumerator: 30,
      frameRateDenominator: 1,
      outputPreference: MiniAVOutputPreference.cpu,
    );
    return (videoFormat, null); // no system audio
  }

  @override
  Future<MiniScreenContextPlatformInterface> createContext() async {
    return MiniAVWebScreenContext();
  }

  @override
  void Function() addDisplayChangeListener(
    MiniAVDeviceChangeListener listener,
  ) {
    // Web has no display hot-plug API; the single 'screen' device is fixed.
    return () {};
  }

  @override
  void Function() addWindowChangeListener(MiniAVDeviceChangeListener listener) {
    // Web does not enumerate windows.
    return () {};
  }

  @override
  Future<void> setIOSAppGroup(String appGroupId) =>
      throw UnsupportedError('setIOSAppGroup is only available on iOS.');
}

/// Web implementation of [MiniScreenContextPlatformInterface]
class MiniAVWebScreenContext implements MiniScreenContextPlatformInterface {
  @override
  void Function() addLostListener(MiniAVContextLostListener listener) {
    // Web getDisplayMedia tracks ending is not currently propagated.
    return () {};
  }

  @override
  Future<void> setCaptureCursor(bool enabled) async {
    // getDisplayMedia includes the cursor by default and does not expose a
    // reliable post-hoc toggle here; accept the call so cross-platform code
    // works, but it is a no-op on web.
  }

  // Media
  web.MediaStream? _mediaStream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _ctx;

  MiniAVVideoInfo? _format;

  // Capture
  bool _capturing = false;
  int? _rafId;
  bool _firstRealFrame = false;
  int _blackStreak = 0;
  DateTime? _captureStart;

  // Debug
  static const bool _debug = false;
  int _frameIndex = 0;

  // ---------------- Configuration ----------------
  @override
  Future<void> configureDisplay(
    String screenId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  }) async {
    await destroy();

    if (_debug) {
      print(
        '[MiniAV][screen][configure] request ${format.width}x${format.height} '
        'fps=${format.frameRateNumerator / format.frameRateDenominator} audio=$captureAudio',
      );
    }

    // Build constraints (DisplayMediaStreamOptions via package:web)
    final videoConstraints = <String, dynamic>{
      'width': {'ideal': format.width},
      'height': {'ideal': format.height},
      'frameRate': {
        'ideal': format.frameRateNumerator / format.frameRateDenominator,
      },
    }.jsify()!;
    final options = web.DisplayMediaStreamOptions(
      video: videoConstraints,
      audio: (captureAudio ? true : false).toJS,
    );

    try {
      final t0 = DateTime.now();
      _mediaStream = await web.window.navigator.mediaDevices
          .getDisplayMedia(options)
          .toDart;
      if (_debug) {
        print(
          '[MiniAV][screen][configure] getDisplayMedia in '
          '${DateTime.now().difference(t0).inMilliseconds}ms',
        );
      }

      _video = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true
        ..playsInline = true
        ..setAttribute('playsinline', 'true')
        // Keep a tiny visible footprint to avoid compositor discard.
        ..style.position = 'absolute'
        ..style.left = '0'
        ..style.top = '0'
        ..style.width = '1px'
        ..style.height = '1px'
        ..style.opacity = '0'
        ..style.pointerEvents = 'none';

      if (_video!.parentNode == null) {
        web.document.body?.append(_video!);
      }
      _video!.srcObject = _mediaStream;

      _attachDebugVideoListeners();

      // Explicit play (helps some autoplay edge cases)
      try {
        final p = _video!.play();
        if (p is JSPromise) await p.toDart;
      } catch (e) {
        if (_debug) print('[MiniAV][screen][configure] play() error: $e');
      }

      // Wait for workable dimensions
      await _waitFor(
        () {
          if (_video == null) return true;
          return _video!.videoWidth > 0 &&
              _video!.videoHeight > 0 &&
              _video!.readyState >= 2;
        },
        timeoutMs: 4000,
        pollMs: 40,
      );

      // Post-ready small delay to allow first real frame to render (Chrome often needs this)
      await Future.delayed(const Duration(milliseconds: 60));

      final vw = _video!.videoWidth > 0 ? _video!.videoWidth : format.width;
      final vh = _video!.videoHeight > 0 ? _video!.videoHeight : format.height;

      _canvas = web.HTMLCanvasElement()
        ..width = vw
        ..height = vh;
      _ctx = _canvas!.getContext('2d') as web.CanvasRenderingContext2D?;

      _format = MiniAVVideoInfo(
        width: vw,
        height: vh,
        pixelFormat: MiniAVPixelFormat.rgba32,
        frameRateNumerator: format.frameRateNumerator,
        frameRateDenominator: format.frameRateDenominator,
        outputPreference: MiniAVOutputPreference.cpu,
      );

      _firstRealFrame = false;
      _blackStreak = 0;

      if (_debug) {
        print(
          '[MiniAV][screen][configure] final format ${vw}x$vh '
          'readyState=${_video!.readyState}',
        );
      }

      await _primeFirstFrame();
    } catch (e) {
      if (_debug) {
        print('[MiniAV][screen][configure] ERROR: $e');
      }
      throw Exception('Failed to configure display capture: $e');
    }
  }

  @override
  Future<void> configureWindow(
    String windowId,
    MiniAVVideoInfo format, {
    bool captureAudio = false,
  }) async {
    throw UnsupportedError('Window capture not supported on web');
  }

  // ---------------- Prime / Warm-up ----------------
  Future<void> _primeFirstFrame() async {
    if (_video == null || _ctx == null) return;
    // Try a handful of draws until non-black or limit
    for (int i = 0; i < 12 && !_firstRealFrame; i++) {
      if (_video!.readyState >= 2) {
        _ctx!.drawImage(_video!, 0, 0);
        if (_nonBlackSample(6, 6)) {
          _firstRealFrame = true;
          if (_debug) {
            print('[MiniAV][screen][prime] first non-black at attempt $i');
          }
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 45));
    }
    if (!_firstRealFrame && _debug) {
      print('[MiniAV][screen][prime] still black after prime attempts');
    }
  }

  bool _nonBlackSample(int w, int h) {
    if (_ctx == null) return false;
    final data = _ctx!.getImageData(0, 0, w, h).data.toDart;
    for (int i = 0; i < data.length; i += 4) {
      if (data[i] != 0 || data[i + 1] != 0 || data[i + 2] != 0) return true;
    }
    return false;
  }

  // ---------------- Capture Control ----------------
  @override
  Future<ScreenFormatDefaults> getConfiguredFormats() async {
    final f = _format;
    if (f == null) throw StateError('Screen context not configured');
    return (f, null);
  }

  @override
  Future<void> startCapture(
    void Function(MiniAVBuffer buffer, Object? userData) onFrame, {
    Object? userData,
  }) async {
    if (_mediaStream == null ||
        _video == null ||
        _canvas == null ||
        _ctx == null ||
        _format == null) {
      throw StateError('Screen capture not configured');
    }

    await stopCapture();

    _capturing = true;
    _frameIndex = 0;
    _captureStart = DateTime.now();
    if (_debug) {
      print(
        '[MiniAV][screen][startCapture] begin rs=${_video!.readyState} '
        'firstReal=$_firstRealFrame',
      );
    }

    // If still black, give another quick warm loop before continuous capture.
    if (!_firstRealFrame) {
      await _primeFirstFrame();
    }

    void raf(num _) {
      if (!_capturing) return;
      _captureFrame(onFrame, userData);
      _rafId = web.window.requestAnimationFrame(raf.toJS);
    }

    _rafId = web.window.requestAnimationFrame(raf.toJS);
  }

  @override
  Future<void> stopCapture() async {
    _capturing = false;
    if (_rafId != null) {
      web.window.cancelAnimationFrame(_rafId!);
      _rafId = null;
    }
  }

  // ---------------- Frame Processing ----------------
  void _captureFrame(
    void Function(MiniAVBuffer buffer, Object? userData) emit,
    Object? userData,
  ) {
    if (!_capturing ||
        _video == null ||
        _canvas == null ||
        _ctx == null ||
        _format == null)
      return;

    // Ensure video has data
    if (_video!.readyState < 2 ||
        _video!.videoWidth == 0 ||
        _video!.videoHeight == 0)
      return;

    // Adjust canvas if display size changes
    final vw = _video!.videoWidth;
    final vh = _video!.videoHeight;
    if ((vw != _canvas!.width || vh != _canvas!.height) && vw > 0 && vh > 0) {
      if (_debug) {
        print(
          '[MiniAV][screen][capture] resize ${_canvas!.width}x${_canvas!.height} -> ${vw}x$vh',
        );
      }
      _canvas!
        ..width = vw
        ..height = vh;
      _format = MiniAVVideoInfo(
        width: vw,
        height: vh,
        pixelFormat: _format!.pixelFormat,
        frameRateNumerator: _format!.frameRateNumerator,
        frameRateDenominator: _format!.frameRateDenominator,
        outputPreference: _format!.outputPreference,
      );
    }

    try {
      _ctx!.drawImage(_video!, 0, 0);

      if (!_firstRealFrame) {
        if (_video!.currentTime <= 0) {
          // wait until some playback progress
          return;
        }
        if (!_nonBlackSample(8, 8)) {
          _blackStreak++;
          if (_debug && (_blackStreak <= 8 || _blackStreak % 30 == 0)) {
            print(
              '[MiniAV][screen][capture] black streak=$_blackStreak '
              'rs=${_video!.readyState} ct=${_video!.currentTime.toStringAsFixed(2)}',
            );
          }
          return;
        }
        _firstRealFrame = true;
        if (_debug) {
          final ms = DateTime.now().difference(_captureStart!).inMilliseconds;
          print('[MiniAV][screen][capture] FIRST NON-BLACK after ${ms}ms');
        }
      }

      final img = _ctx!.getImageData(0, 0, _canvas!.width, _canvas!.height);
      final bytes = _imageDataToBytes(img);

      final videoBuffer = MiniAVVideoBuffer(
        width: _format!.width,
        height: _format!.height,
        pixelFormat: MiniAVPixelFormat.rgba32,
        planes: [bytes],
        strideBytes: [_format!.width * 4],
      );

      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.cpu,
        timestampUs: DateTime.now().microsecondsSinceEpoch,
        data: videoBuffer,
        dataSizeBytes: bytes.length,
      );

      _frameIndex++;
      if (_debug) {
        if (_frameIndex <= 5 ||
            (_frameIndex <= 120 && _frameIndex % 30 == 0) ||
            _frameIndex % 300 == 0) {
          final lum = _avgLum(bytes, sampleLimit: 4000).toStringAsFixed(1);
          print(
            '[MiniAV][screen][capture] frame=$_frameIndex '
            'size=${_format!.width}x${_format!.height} avgLum=$lum',
          );
        }
      }

      emit(buf, userData);
    } catch (e) {
      if (_debug) {
        print('[MiniAV][screen][capture] ERROR: $e');
      }
    }
  }

  Uint8List _imageDataToBytes(web.ImageData img) {
    final dynamic raw = img.data.toDart;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return Uint8List.fromList(List<int>.from(raw as Iterable));
  }

  double _avgLum(Uint8List rgba, {int sampleLimit = 4000}) {
    if (rgba.isEmpty) return 0;
    final totalPixels = rgba.length ~/ 4;
    final step = (totalPixels / sampleLimit).ceil().clamp(1, 1000);
    int count = 0;
    double sum = 0;
    for (int i = 0; i < rgba.length; i += 4 * step) {
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
      count++;
    }
    return count == 0 ? 0 : sum / count;
  }

  Future<void> _waitFor(
    bool Function() ready, {
    required int timeoutMs,
    required int pollMs,
  }) async {
    final start = DateTime.now().millisecondsSinceEpoch;
    while (true) {
      if (ready()) return;
      if (DateTime.now().millisecondsSinceEpoch - start > timeoutMs) return;
      await Future.delayed(Duration(milliseconds: pollMs));
    }
  }

  void _attachDebugVideoListeners() {
    if (!_debug || _video == null) return;
    _video!.onLoadedMetadata.listen((_) {
      print(
        '[MiniAV][screen][video] onLoadedMetadata '
        'rs=${_video!.readyState} vw=${_video!.videoWidth} vh=${_video!.videoHeight}',
      );
    });
    _video!.onCanPlay.listen((_) {
      print('[MiniAV][screen][video] onCanPlay rs=${_video!.readyState}');
    });
    _video!.onPlaying.listen((_) {
      print(
        '[MiniAV][screen][video] onPlaying ct=${_video!.currentTime.toStringAsFixed(2)}',
      );
    });
    _video!.onLoadedData.listen((_) {
      print('[MiniAV][screen][video] onLoadedData rs=${_video!.readyState}');
    });
    _video!.onError.listen((_) {
      print('[MiniAV][screen][video] ERROR ${_video!.error?.message}');
    });
  }

  // ---------------- Destroy ----------------
  @override
  Future<void> destroy() async {
    await stopCapture();
    _mediaStream?.getTracks().toDart.forEach((t) => t.stop());
    _mediaStream = null;
    _video
      ?..pause()
      ..srcObject = null
      ..remove();
    _video = null;
    _canvas = null;
    _ctx = null;
    _format = null;
    _firstRealFrame = false;
    if (_debug) print('[MiniAV][screen][destroy]');
  }
}
