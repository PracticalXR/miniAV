import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miniav/miniav.dart';
import 'package:minigpu_view/minigpu_view.dart';

void main() {
  runApp(const MiniAVBenchmarkApp());
}

class MiniAVBenchmarkApp extends StatelessWidget {
  const MiniAVBenchmarkApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MiniAV Benchmark Dashboard',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const BenchmarkDashboard(),
    );
  }
}

class BenchmarkDashboard extends StatefulWidget {
  const BenchmarkDashboard({super.key});
  @override
  State<BenchmarkDashboard> createState() => _BenchmarkDashboardState();
}

class StreamConfiguration {
  String? selectedDeviceId;
  MiniAVDeviceInfo? selectedDevice;
  List<MiniAVDeviceInfo> availableDevices = [];
  dynamic selectedFormat; // MiniAVVideoInfo or MiniAVAudioInfo
  List<dynamic> availableFormats = [];
  bool isLoadingDevices = false;
  bool isLoadingFormats = false;
  String? error;
  void reset() {
    selectedDeviceId = null;
    selectedDevice = null;
    availableDevices.clear();
    selectedFormat = null;
    availableFormats.clear();
    error = null;
  }
}

class InputStats {
  int keyboardEvents = 0;
  int mouseEvents = 0;
  int gamepadEvents = 0;
  bool isActive = false;
  bool isStarting = false;
  bool isStopping = false;
  MiniAVKeyboardEvent? lastKeyboard;
  MiniAVMouseEvent? lastMouse;
  MiniAVGamepadEvent? lastGamepad;
  MiniAVGamepadEvent? prevGamepad; // for diffing
  final List<String> eventLog = [];
  DateTime startTime = DateTime.now();
  int get totalEvents => keyboardEvents + mouseEvents + gamepadEvents;
  double get eventsPerSecond {
    final elapsed = DateTime.now().difference(startTime).inMicroseconds / 1e6;
    return elapsed > 0 ? totalEvents / elapsed : 0;
  }

  void reset() {
    keyboardEvents = 0;
    mouseEvents = 0;
    gamepadEvents = 0;
    lastKeyboard = null;
    lastMouse = null;
    lastGamepad = null;
    prevGamepad = null;
    eventLog.clear();
    startTime = DateTime.now();
  }

  void addLog(String msg) {
    eventLog.add(msg);
    if (eventLog.length > 50) eventLog.removeAt(0);
  }
}

class StreamStats {
  String name;
  String icon;
  int frameCount = 0;
  int totalBytes = 0;
  double avgLatency = 0.0;
  double currentFps = 0.0;
  double targetFps = 0.0;
  List<double> latencyHistory = [];
  List<double> fpsHistory = [];
  List<int> frameSizes = [];
  DateTime? lastFrameTime;
  DateTime startTime = DateTime.now();
  bool isActive = false;
  bool isStarting = false;
  bool isStopping = false;
  String deviceName = '';
  String resolution = '';
  double bandwidth = 0.0;
  String? lastPreviewError;
  StreamStats(this.name, this.icon);
  void reset() {
    frameCount = 0;
    totalBytes = 0;
    avgLatency = 0.0;
    currentFps = 0.0;
    latencyHistory.clear();
    fpsHistory.clear();
    frameSizes.clear();
    lastFrameTime = null;
    startTime = DateTime.now();
    bandwidth = 0.0;
    lastPreviewError = null;
  }

  void addFrame(int bytes, int timestampUs) {
    final now = DateTime.now();
    frameCount++;
    totalBytes += bytes;
    frameSizes.add(bytes);
    double latency = 0.0;
    if (lastFrameTime != null) {
      latency = now.difference(lastFrameTime!).inMicroseconds / 1000.0;
    }
    if (latency > 0 && latency < 1000) latencyHistory.add(latency);
    if (lastFrameTime != null) {
      final dt = now.difference(lastFrameTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        final inst = 1.0 / dt;
        fpsHistory.add(inst);
        if (fpsHistory.length > 30) fpsHistory.removeAt(0);
        currentFps = fpsHistory.reduce((a, b) => a + b) / fpsHistory.length;
      }
    }
    if (latencyHistory.length > 100) latencyHistory.removeAt(0);
    if (latencyHistory.isNotEmpty) {
      avgLatency =
          latencyHistory.reduce((a, b) => a + b) / latencyHistory.length;
    }
    if (frameSizes.length > 1000) frameSizes.removeAt(0);
    final elapsed = now.difference(startTime).inMicroseconds / 1e6;
    if (elapsed > 0) bandwidth = (totalBytes / (1024 * 1024)) / elapsed;
    lastFrameTime = now;
  }

  double get avgFrameSize => frameSizes.isEmpty
      ? 0
      : frameSizes.reduce((a, b) => a + b) / frameSizes.length;
  double get fpsEfficiency =>
      targetFps > 0 ? (currentFps / targetFps) * 100 : 0;
  double get minLatency =>
      latencyHistory.isEmpty ? 0 : latencyHistory.reduce(min);
  double get maxLatency =>
      latencyHistory.isEmpty ? 0 : latencyHistory.reduce(max);
}

class _FramePixels {
  final Uint8List bytes;
  final bool isBGRA;
  _FramePixels(this.bytes, this.isBGRA);
}

class _BenchmarkDashboardState extends State<BenchmarkDashboard> {
  final Map<String, StreamStats> _stats = {};
  final Map<String, dynamic> _contexts = {};
  final Map<String, StreamConfiguration> _configs = {};
  Timer? _uiUpdateTimer;
  bool _showConfig = false;

  // Input capture state
  final InputStats _inputStats = InputStats();
  MiniInputContext? _inputContext;
  bool _inputKeyboard = true;
  bool _inputMouse = true;
  bool _inputGamepad = true;
  int _mouseThrottleHz = 60;

  // Preview state
  final ValueNotifier<ui.Image?> _cameraPreview = ValueNotifier(null);
  final ValueNotifier<ui.Image?> _screenPreview = ValueNotifier(null);
  // GPU zero-copy preview controllers (Windows D3D11 / Web GPUCanvasContext).
  final MinigpuPreviewController _cameraPreviewCtrl =
      MinigpuPreviewController();
  final MinigpuPreviewController _screenPreviewCtrl =
      MinigpuPreviewController();
  bool _buildingCameraImage = false;
  bool _buildingScreenImage = false;
  int _cameraFrameSkip = 0;
  int _screenFrameSkip = 0;
  bool _loggedPreviewInfo = false;
  bool _debugLoggedChrome = false;

  @override
  void initState() {
    super.initState();
    MiniAV.setLogLevel(MiniAVLogLevel.warn);
    _stats['camera'] = StreamStats('Camera', '📹');
    _stats['screen'] = StreamStats('Screen', '🖥️');
    _stats['audioInput'] = StreamStats('Audio Input', '🎤');
    _stats['loopback'] = StreamStats('Loopback', '🔄');
    _configs['camera'] = StreamConfiguration();
    _configs['screen'] = StreamConfiguration();
    _configs['audioInput'] = StreamConfiguration();
    _configs['loopback'] = StreamConfiguration();
    _loadAllDevices();
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel();
    _stopAllStreams();
    _stopInputCapture();
    _cameraPreview.value?.dispose();
    _screenPreview.value?.dispose();
    _cameraPreview.dispose();
    _screenPreview.dispose();
    _cameraPreviewCtrl.dispose();
    _screenPreviewCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAllDevices() async {
    await Future.wait([
      _loadDevices('camera'),
      _loadDevices('screen'),
      _loadDevices('audioInput'),
      _loadDevices('loopback'),
    ]);
  }

  Future<void> _loadDevices(String streamKey) async {
    final config = _configs[streamKey]!;
    setState(() {
      config.isLoadingDevices = true;
      config.error = null;
    });
    try {
      List<MiniAVDeviceInfo> devices;
      switch (streamKey) {
        case 'camera':
          devices = await MiniCamera.enumerateDevices();
          break;
        case 'screen':
          devices = await MiniScreen.enumerateDisplays();
          break;
        case 'audioInput':
          devices = await MiniAudioInput.enumerateDevices();
          break;
        case 'loopback':
          devices = await MiniLoopback.enumerateDevices();
          break;
        default:
          devices = [];
      }
      setState(() {
        config.availableDevices = devices;
        if (devices.isNotEmpty) {
          if (streamKey == 'camera' && devices.length > 1) {
            config.selectedDevice = devices[1];
          } else if (streamKey == 'loopback' && devices.length > 4) {
            config.selectedDevice = devices[4];
          } else {
            config.selectedDevice = devices.first;
          }
          config.selectedDeviceId = config.selectedDevice!.deviceId;
          _loadFormats(streamKey);
        }
      });
    } catch (e) {
      setState(() {
        config.error = 'Failed to load devices: $e';
      });
    } finally {
      setState(() {
        config.isLoadingDevices = false;
      });
    }
  }

  Future<void> _loadFormats(String streamKey) async {
    final config = _configs[streamKey]!;
    if (config.selectedDeviceId == null) return;
    setState(() {
      config.isLoadingFormats = true;
    });
    try {
      List<dynamic> formats;
      switch (streamKey) {
        case 'camera':
          formats = await MiniCamera.getSupportedFormats(
            config.selectedDeviceId!,
          );
          break;
        case 'screen':
          final result = await MiniScreen.getDefaultFormats(
            config.selectedDeviceId!,
          );
          formats = [result.$1];
          break;
        case 'audioInput':
          final defaultFormat = await MiniAudioInput.getDefaultFormat(
            config.selectedDeviceId!,
          );
          formats = [defaultFormat];
          break;
        case 'loopback':
          final defaultFormat = await MiniLoopback.getDefaultFormat(
            config.selectedDeviceId!,
          );
          formats = [defaultFormat];
          break;
        default:
          formats = [];
      }
      setState(() {
        config.availableFormats = formats;
        if (formats.isNotEmpty) config.selectedFormat = formats.first;
      });
    } catch (e) {
      setState(() {
        config.error = 'Failed to load formats: $e';
      });
    } finally {
      setState(() {
        config.isLoadingFormats = false;
      });
    }
  }

  Future<void> _startAllStreams() async {
    await Future.wait([
      _toggleStream('camera'),
      _toggleStream('screen'),
      _toggleStream('audioInput'),
      _toggleStream('loopback'),
      _startInputCapture(),
    ]);
  }

  Future<void> _stopAllStreams() async {
    final futures = <Future>[];
    for (final k in _stats.keys) {
      if (_stats[k]!.isActive) futures.add(_toggleStream(k));
    }
    if (_inputStats.isActive) futures.add(_stopInputCapture());
    await Future.wait(futures);
  }

  Future<void> _toggleStream(String key) async {
    final s = _stats[key]!;
    if (s.isActive) {
      await _stopStream(key);
    } else {
      await _startStream(key);
    }
  }

  Future<void> _startStream(String key) async {
    final stats = _stats[key]!;
    final cfg = _configs[key]!;
    if (cfg.selectedDevice == null || cfg.selectedFormat == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Select device/format for $key'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() {
      stats.isStarting = true;
    });
    try {
      switch (key) {
        case 'camera':
          await _setupCamera();
          break;
        case 'screen':
          await _setupScreen();
          break;
        case 'audioInput':
          await _setupAudioInput();
          break;
        case 'loopback':
          await _setupLoopback();
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start $key: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        stats.isStarting = false;
      });
    }
  }

  Future<void> _stopStream(String key) async {
    final stats = _stats[key]!;
    final ctx = _contexts[key];
    if (ctx == null) return;
    setState(() {
      stats.isStopping = true;
    });
    try {
      if (ctx is MiniCameraContext ||
          ctx is MiniScreenContext ||
          ctx is MiniAudioInputContext ||
          ctx is MiniLoopbackContext) {
        await ctx.stopCapture();
        await ctx.destroy();
      }
      _contexts.remove(key);
      stats.isActive = false;
    } catch (_) {
      // ignore
    } finally {
      setState(() {
        stats.isStopping = false;
      });
    }
  }

  Future<void> _setupCamera() async {
    final cfg = _configs['camera']!;
    final format = cfg.selectedFormat as MiniAVVideoInfo;
    final ctx = await MiniCamera.createContext();
    await ctx.configure(cfg.selectedDeviceId!, format);
    _contexts['camera'] = ctx;
    final stats = _stats['camera']!;
    stats.reset();
    stats.deviceName = cfg.selectedDevice!.name;
    stats.resolution = '${format.width}x${format.height}';
    stats.targetFps = format.frameRateNumerator / format.frameRateDenominator;
    stats.isActive = true;
    stats.startTime = DateTime.now();

    await ctx.startCapture((buffer, userData) {
      if (buffer.type == MiniAVBufferType.video) {
        stats.addFrame(buffer.dataSizeBytes, buffer.timestampUs);
        _trySchedulePreview(
          streamKey: 'camera',
          buffer: buffer,
          preview: _cameraPreview,
          previewController: _cameraPreviewCtrl,
          buildingFlag: () => _buildingCameraImage,
          setBuildingFlag: (v) => _buildingCameraImage = v,
          frameSkipCounter: () => _cameraFrameSkip++,
        );
      }
      MiniAV.releaseBuffer(buffer);
    });
  }

  Future<void> _setupScreen() async {
    final cfg = _configs['screen']!;
    final format = cfg.selectedFormat as MiniAVVideoInfo;
    final ctx = await MiniScreen.createContext();
    await ctx.configureDisplay(
      cfg.selectedDeviceId!,
      format,
      captureAudio: false,
    );
    _contexts['screen'] = ctx;
    final stats = _stats['screen']!;
    stats.reset();
    stats.deviceName = cfg.selectedDevice!.name;
    stats.resolution = '${format.width}x${format.height}';
    stats.targetFps = format.frameRateNumerator / format.frameRateDenominator;
    stats.isActive = true;
    stats.startTime = DateTime.now();

    await ctx.startCapture((buffer, userData) {
      if (buffer.type == MiniAVBufferType.video) {
        stats.addFrame(buffer.dataSizeBytes, buffer.timestampUs);
        _trySchedulePreview(
          streamKey: 'screen',
          buffer: buffer,
          preview: _screenPreview,
          previewController: _screenPreviewCtrl,
          buildingFlag: () => _buildingScreenImage,
          setBuildingFlag: (v) => _buildingScreenImage = v,
          frameSkipCounter: () => _screenFrameSkip++,
        );
      }
      MiniAV.releaseBuffer(buffer);
    });
  }

  Future<void> _setupAudioInput() async {
    final cfg = _configs['audioInput']!;
    final format = cfg.selectedFormat as MiniAVAudioInfo;
    final ctx = await MiniAudioInput.createContext();
    await ctx.configure(cfg.selectedDeviceId!, format);
    _contexts['audioInput'] = ctx;
    final stats = _stats['audioInput']!;
    stats.reset();
    stats.deviceName = cfg.selectedDevice!.name;
    stats.resolution = '${format.channels}ch ${format.sampleRate}Hz';
    stats.targetFps = format.sampleRate / format.numFrames;
    stats.isActive = true;
    stats.startTime = DateTime.now();
    await ctx.startCapture((buffer, userData) {
      if (buffer.type == MiniAVBufferType.audio) {
        stats.addFrame(buffer.dataSizeBytes, buffer.timestampUs);
      }
      MiniAV.releaseBuffer(buffer);
    });
  }

  Future<void> _setupLoopback() async {
    final cfg = _configs['loopback']!;
    final format = cfg.selectedFormat as MiniAVAudioInfo;
    final ctx = await MiniLoopback.createContext();
    await ctx.configure(cfg.selectedDeviceId!, format);
    _contexts['loopback'] = ctx;
    final stats = _stats['loopback']!;
    stats.reset();
    stats.deviceName = cfg.selectedDevice!.name;
    stats.resolution = '${format.channels}ch ${format.sampleRate}Hz';
    stats.targetFps = format.sampleRate / format.numFrames;
    stats.isActive = true;
    stats.startTime = DateTime.now();
    await ctx.startCapture((buffer, userData) {
      if (buffer.type == MiniAVBufferType.audio) {
        stats.addFrame(buffer.dataSizeBytes, buffer.timestampUs);
      }
      // (Loopback not released previously; but release to avoid leaks)
      MiniAV.releaseBuffer(buffer);
    });
  }

  // --- Input Capture ---

  Future<void> _startInputCapture() async {
    if (_inputStats.isActive) return;
    setState(() => _inputStats.isStarting = true);
    try {
      final ctx = await MiniInput.createContext();
      int inputTypes = 0;
      if (_inputKeyboard) inputTypes |= MiniAVInputType.keyboard.value;
      if (_inputMouse) inputTypes |= MiniAVInputType.mouse.value;
      if (_inputGamepad) inputTypes |= MiniAVInputType.gamepad.value;
      await ctx.configure(
        MiniAVInputConfig(
          inputTypes: inputTypes,
          mouseThrottleHz: _mouseThrottleHz,
          gamepadPollHz: 60,
        ),
      );
      await ctx.startCapture(
        onKeyboard: (event, _) {
          _inputStats.keyboardEvents++;
          _inputStats.lastKeyboard = event;
          final action = event.action == MiniAVKeyAction.down ? 'DN' : 'UP';
          _inputStats.addLog(
            'KEY $action vk=${event.keyCode} sc=${event.scanCode}',
          );
        },
        onMouse: (event, _) {
          _inputStats.mouseEvents++;
          _inputStats.lastMouse = event;
          final action = event.action.name;
          _inputStats.addLog(
            'MOUSE $action (${event.x},${event.y}) btn=${event.button.name}',
          );
        },
        onGamepad: (event, _) {
          _inputStats.gamepadEvents++;
          final prev = _inputStats.prevGamepad;
          final logs = _describeGamepadChanges(prev, event);
          for (final log in logs) {
            _inputStats.addLog(log);
          }
          _inputStats.prevGamepad = _inputStats.lastGamepad;
          _inputStats.lastGamepad = event;
        },
      );
      _inputContext = ctx;
      _inputStats.reset();
      _inputStats.isActive = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start input capture: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _inputStats.isStarting = false);
    }
  }

  Future<void> _stopInputCapture() async {
    if (!_inputStats.isActive && _inputContext == null) return;
    setState(() => _inputStats.isStopping = true);
    try {
      await _inputContext?.stopCapture();
      await _inputContext?.destroy();
    } catch (_) {}
    _inputContext = null;
    _inputStats.isActive = false;
    setState(() => _inputStats.isStopping = false);
  }

  Future<void> _toggleInputCapture() async {
    if (_inputStats.isActive) {
      await _stopInputCapture();
    } else {
      await _startInputCapture();
    }
  }

  // --- XInput button name map ---
  static const Map<int, String> _xinputButtons = {
    0x0001: 'DPad-Up',
    0x0002: 'DPad-Down',
    0x0004: 'DPad-Left',
    0x0008: 'DPad-Right',
    0x0010: 'Start',
    0x0020: 'Back',
    0x0040: 'L-Stick',
    0x0080: 'R-Stick',
    0x0100: 'LB',
    0x0200: 'RB',
    0x1000: 'A',
    0x2000: 'B',
    0x4000: 'X',
    0x8000: 'Y',
  };

  static const int _stickDeadzone = 5000;
  static const int _triggerDeadzone = 10;

  String _buttonNames(int bitmask) {
    if (bitmask == 0) return 'none';
    final names = <String>[];
    for (final entry in _xinputButtons.entries) {
      if (bitmask & entry.key != 0) names.add(entry.value);
    }
    return names.isEmpty ? '0x${bitmask.toRadixString(16)}' : names.join('+');
  }

  List<String> _describeGamepadChanges(
    MiniAVGamepadEvent? prev,
    MiniAVGamepadEvent cur,
  ) {
    final logs = <String>[];
    final pad = 'PAD[${cur.gamepadIndex}]';

    if (prev == null) {
      // First event — show full state
      if (cur.connected) {
        logs.add('$pad connected');
      }
      if (cur.buttons != 0) {
        logs.add('$pad BTN ${_buttonNames(cur.buttons)}');
      }
      return logs;
    }

    // Connection change
    if (cur.connected != prev.connected) {
      logs.add('$pad ${cur.connected ? "connected" : "disconnected"}');
      if (!cur.connected) return logs;
    }

    // Button press/release diff
    final pressed = cur.buttons & ~prev.buttons;
    final released = ~cur.buttons & prev.buttons;
    if (pressed != 0) logs.add('$pad PRESS ${_buttonNames(pressed)}');
    if (released != 0) logs.add('$pad RELEASE ${_buttonNames(released)}');

    // Trigger changes (analog 0-255)
    if ((cur.leftTrigger - prev.leftTrigger).abs() > _triggerDeadzone) {
      logs.add('$pad LT=${cur.leftTrigger}');
    }
    if ((cur.rightTrigger - prev.rightTrigger).abs() > _triggerDeadzone) {
      logs.add('$pad RT=${cur.rightTrigger}');
    }

    // Stick changes (only when exceeding deadzone)
    if (_stickChanged(
      prev.leftStickX,
      prev.leftStickY,
      cur.leftStickX,
      cur.leftStickY,
    )) {
      logs.add('$pad L-Stick(${cur.leftStickX},${cur.leftStickY})');
    }
    if (_stickChanged(
      prev.rightStickX,
      prev.rightStickY,
      cur.rightStickX,
      cur.rightStickY,
    )) {
      logs.add('$pad R-Stick(${cur.rightStickX},${cur.rightStickY})');
    }

    return logs;
  }

  bool _stickChanged(int prevX, int prevY, int curX, int curY) {
    // Only log if the stick crossed the deadzone threshold or moved significantly
    final prevMag = sqrt(prevX * prevX + prevY * prevY);
    final curMag = sqrt(curX * curX + curY * curY);
    // Report if crossing deadzone boundary or if already past deadzone and changed significantly
    if (prevMag < _stickDeadzone && curMag < _stickDeadzone) return false;
    final dx = (curX - prevX).abs();
    final dy = (curY - prevY).abs();
    return dx > 2000 || dy > 2000;
  }

  void _trySchedulePreview({
    required String streamKey,
    required MiniAVBuffer buffer,
    required ValueNotifier<ui.Image?> preview,
    MinigpuPreviewController? previewController,
    required bool Function() buildingFlag,
    required void Function(bool) setBuildingFlag,
    required int Function() frameSkipCounter,
  }) {
    if (buildingFlag()) return;
    final skipIndex = frameSkipCounter();
    if ((skipIndex & 1) == 1) return;

    // GPU zero-copy path (Windows D3D11 / other native GPU handles).
    if (buffer.contentType != MiniAVBufferContentType.cpu &&
        previewController != null) {
      final source = buffer.asPreviewSource();
      if (source != null) {
        previewController.present(source).catchError((e) {
          _stats[streamKey]!.lastPreviewError = 'GPU preview error: $e';
        });
        return;
      }
      // Unknown GPU handle type — fall through to CPU path.
    }

    if (buffer.contentType != MiniAVBufferContentType.cpu) {
      _stats[streamKey]!.lastPreviewError ??=
          'Preview skipped: non-CPU buffer (${buffer.contentType})';
      return;
    }

    MiniAVVideoBuffer video;
    try {
      video = buffer.data as MiniAVVideoBuffer;
    } catch (_) {
      _stats[streamKey]!.lastPreviewError = 'Data cast failed';
      return;
    }

    final framePixels = _convertVideoToRgba(video);
    if (framePixels == null) {
      _stats[streamKey]!.lastPreviewError ??=
          'Unsupported pixel format: ${video.pixelFormat}';
      return;
    }

    // Prepare RGBA NOW (synchronous) before releasing native buffer.
    final Uint8List rgba = framePixels.isBGRA
        ? _bgraToRgbaInPlaceCopy(framePixels.bytes)
        : framePixels.bytes;

    // Optional: simple luminance / first-bytes debug once per stream
    if (!_debugLoggedChrome) {
      _debugLoggedChrome = true;
      double sum = 0;
      int samples = 0;
      for (int i = 0; i < min(rgba.length, 64 * 4); i += 4) {
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
        samples++;
      }
      final avgLum = samples == 0 ? 0 : sum / samples;
      debugPrint(
        '[MiniAV][$streamKey] first-frame pixelFormat=${video.pixelFormat} '
        'size=${video.width}x${video.height} avgLum=${avgLum.toStringAsFixed(1)} '
        'first16=${_firstBytesHex(rgba, 16)}',
      );
    }

    setBuildingFlag(true);
    // Build image immediately (no microtask) to avoid web HTML renderer races.
    _decodeRgbaToImage(rgba, video.width, video.height)
        .then((img) {
          // Detect black frame despite non-zero luminance bytes
          if (preview.value == null && _looksAllBlack(rgba)) {
            _stats[streamKey]!.lastPreviewError ??=
                'Chrome black frame (renderer) – try: flutter run -d chrome --web-renderer canvaskit';
          }
          final old = preview.value;
          preview.value = img;
          old?.dispose();
        })
        .catchError((e) {
          _stats[streamKey]!.lastPreviewError = 'Image build error: $e';
        })
        .whenComplete(() => setBuildingFlag(false));
  }

  String _firstBytesHex(Uint8List data, int count) {
    final b = <String>[];
    final n = min(count, data.length);
    for (int i = 0; i < n; i++) {
      b.add(data[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.join(' ');
  }

  bool _looksAllBlack(Uint8List rgba) {
    final n = min(rgba.length, 2000);
    for (int i = 0; i < n; i += 4) {
      if (rgba[i] != 0 || rgba[i + 1] != 0 || rgba[i + 2] != 0) return false;
    }
    return true;
  }

  Future<ui.Image> _decodeRgbaToImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    try {
      ui.decodeImageFromPixels(
        rgba,
        w,
        h,
        ui.PixelFormat.rgba8888,
        (img) => c.complete(img),
      );
    } catch (e) {
      // Fallback
      ui.ImmutableBuffer.fromUint8List(rgba)
          .then((imm) async {
            final desc = ui.ImageDescriptor.raw(
              imm,
              width: w,
              height: h,
              pixelFormat: ui.PixelFormat.rgba8888,
            );
            final codec = await desc.instantiateCodec();
            final frame = await codec.getNextFrame();
            c.complete(frame.image);
          })
          .catchError(c.completeError);
    }
    return c.future;
  }

  Uint8List _bgraToRgbaCopy(Uint8List bgra) => _bgraToRgbaInPlaceCopy(bgra);

  _FramePixels? _convertVideoToRgba(MiniAVVideoBuffer video) {
    final planes = video.planes;
    if (planes.isEmpty || planes[0] == null) return null;
    final pf = video.pixelFormat;
    try {
      switch (pf) {
        case MiniAVPixelFormat.rgba32:
          return _FramePixels(
            _copyPacked(
              planes[0]!,
              video.width,
              video.height,
              4,
              _stride(video, 0, 4, video.width),
            ),
            false,
          );
        case MiniAVPixelFormat.bgra32:
          return _FramePixels(
            _copyPacked(
              planes[0]!,
              video.width,
              video.height,
              4,
              _stride(video, 0, 4, video.width),
            ),
            true,
          );
        case MiniAVPixelFormat.rgb24:
          return _FramePixels(
            _expandRgbToRgba(
              _copyPacked(
                planes[0]!,
                video.width,
                video.height,
                3,
                _stride(video, 0, 3, video.width),
              ),
            ),
            false,
          );
        case MiniAVPixelFormat.bgr24:
          return _FramePixels(
            _bgr24ToRgba(
              _copyPacked(
                planes[0]!,
                video.width,
                video.height,
                3,
                _stride(video, 0, 3, video.width),
              ),
            ),
            false,
          );
        case MiniAVPixelFormat.nv12:
          if (planes.length < 2 || planes[1] == null) return null;
          return _FramePixels(
            _nv12ToRgba(
              y: planes[0]!,
              uv: planes[1]!,
              width: video.width,
              height: video.height,
              yStride: _stride(video, 0, 1, video.width),
              uvStride: _stride(video, 1, 2, video.width),
            ),
            false,
          );
        case MiniAVPixelFormat.i420:
          if (planes.length < 3 || planes[1] == null || planes[2] == null)
            return null;
          return _FramePixels(
            _i420ToRgba(
              y: planes[0]!,
              u: planes[1]!,
              v: planes[2]!,
              width: video.width,
              height: video.height,
              yStride: _stride(video, 0, 1, video.width),
              uStride: _stride(video, 1, 1, video.width ~/ 2),
              vStride: _stride(video, 2, 1, video.width ~/ 2),
            ),
            false,
          );
        case MiniAVPixelFormat.yuy2:
          // YUY2 = Y0 U Y1 V (4 bytes for 2 pixels) => 2 bytes per pixel
          return _FramePixels(
            _yuy2ToRgba(
              planes[0]!,
              video.width,
              video.height,
              _stride(video, 0, 2, video.width), // stride in bytes
            ),
            false,
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  int _stride(MiniAVVideoBuffer v, int i, int bpp, int logicalWidth) {
    if (i < v.strideBytes.length && v.strideBytes[i] > 0) {
      return v.strideBytes[i];
    }
    return logicalWidth * bpp;
  }

  Future<ui.Image> _rgbaBytesToImage(
    Uint8List data,
    int w,
    int h,
    bool isBGRA,
  ) async {
    // Always feed RGBA to avoid bgra8888 issues on Chrome.
    final Uint8List rgba = isBGRA
        ? _bgraToRgbaInPlaceCopy(data)
        : data; // copy only if needed
    final immutable = await ui.ImmutableBuffer.fromUint8List(rgba);
    ui.ImageDescriptor desc = ui.ImageDescriptor.raw(
      immutable,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Uint8List _bgraToRgbaInPlaceCopy(Uint8List bgra) {
    final out = Uint8List(bgra.length);
    for (int i = 0; i < bgra.length; i += 4) {
      out[i] = bgra[i + 2]; // R
      out[i + 1] = bgra[i + 1]; // G
      out[i + 2] = bgra[i]; // B
      out[i + 3] = bgra[i + 3]; // A
    }
    return out;
  }

  Uint8List _copyPacked(Uint8List src, int w, int h, int bpp, int strideBytes) {
    final rowBytes = w * bpp;
    final out = Uint8List(rowBytes * h);
    if (strideBytes == rowBytes) {
      out.setRange(0, out.length, src);
      return out;
    }
    int si = 0, di = 0;
    for (int y = 0; y < h; y++) {
      out.setRange(di, di + rowBytes, src, si);
      si += strideBytes;
      di += rowBytes;
    }
    return out;
  }

  Uint8List _expandRgbToRgba(Uint8List rgb) {
    final n = rgb.length ~/ 3;
    final out = Uint8List(n * 4);
    int ri = 0, oi = 0;
    while (ri < rgb.length) {
      out[oi++] = rgb[ri++];
      out[oi++] = rgb[ri++];
      out[oi++] = rgb[ri++];
      out[oi++] = 0xFF;
    }
    return out;
  }

  Uint8List _bgr24ToRgba(Uint8List bgr) {
    final n = bgr.length ~/ 3;
    final out = Uint8List(n * 4);
    int bi = 0, oi = 0;
    while (bi < bgr.length) {
      final b = bgr[bi++];
      final g = bgr[bi++];
      final r = bgr[bi++];
      out[oi++] = r;
      out[oi++] = g;
      out[oi++] = b;
      out[oi++] = 0xFF;
    }
    return out;
  }

  Uint8List _nv12ToRgba({
    required Uint8List y,
    required Uint8List uv,
    required int width,
    required int height,
    required int yStride,
    required int uvStride,
  }) {
    final out = Uint8List(width * height * 4);
    int o = 0;
    for (int row = 0; row < height; row++) {
      final yRow = row * yStride;
      final uvRow = (row >> 1) * uvStride;
      for (int col = 0; col < width; col++) {
        final Y = y[yRow + col];
        final uvIndex = uvRow + (col & ~1);
        final U = uv[uvIndex];
        final V = uv[uvIndex + 1];
        _yuvToRgba(Y, U, V, out, o);
        o += 4;
      }
    }
    return out;
  }

  Uint8List _i420ToRgba({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int width,
    required int height,
    required int yStride,
    required int uStride,
    required int vStride,
  }) {
    final out = Uint8List(width * height * 4);
    int o = 0;
    for (int row = 0; row < height; row++) {
      final yRow = row * yStride;
      final uvRow = row >> 1;
      for (int col = 0; col < width; col++) {
        final Y = y[yRow + col];
        final uIdx = uvRow * uStride + (col >> 1);
        final vIdx = uvRow * vStride + (col >> 1);
        final U = u[uIdx];
        final V = v[vIdx];
        _yuvToRgba(Y, U, V, out, o);
        o += 4;
      }
    }
    return out;
  }

  void _yuvToRgba(int Y, int U, int V, Uint8List out, int o) {
    // Auto-handle potential full-range YUV: if Y < 16 treat as full-range.
    final bool fullRange = Y < 16;
    final yv = fullRange ? Y : (Y - 16).clamp(0, 255);
    final u = U - 128;
    final v = V - 128;
    int r = (1.164 * yv + 1.596 * v).round();
    int g = (1.164 * yv - 0.392 * u - 0.813 * v).round();
    int b = (1.164 * yv + 2.017 * u).round();
    if (r < 0) r = 0;
    if (r > 255) r = 255;
    if (g < 0) g = 0;
    if (g > 255) g = 255;
    if (b < 0) b = 0;
    if (b > 255) b = 255;
    out[o] = r;
    out[o + 1] = g;
    out[o + 2] = b;
    out[o + 3] = 0xFF;
  }

  Uint8List _yuy2ToRgba(Uint8List yuy2, int width, int height, int stride) {
    final out = Uint8List(width * height * 4);
    int o = 0;
    for (int row = 0; row < height; row++) {
      final rowStart = row * stride;
      for (int col = 0; col < width; col += 2) {
        final idx = rowStart + col * 2;
        if (idx + 3 >= yuy2.length) break;
        final y0 = yuy2[idx];
        final u = yuy2[idx + 1];
        final y1 = (col + 1 < width) ? yuy2[idx + 2] : y0;
        final v = yuy2[idx + 3];
        _yuvToRgba(y0, u, v, out, o);
        o += 4;
        if (col + 1 < width) {
          _yuvToRgba(y1, u, v, out, o);
          o += 4;
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final activeStreams =
        _stats.values.where((s) => s.isActive).length +
        (_inputStats.isActive ? 1 : 0);
    final hasActiveStreams = activeStreams > 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎥 MiniAV Benchmark Dashboard'),
        elevation: 0,
        actions: [
          IconButton(
            onPressed: () => setState(() => _showConfig = !_showConfig),
            icon: Icon(_showConfig ? Icons.settings_outlined : Icons.settings),
            tooltip: _showConfig ? 'Hide Configuration' : 'Show Configuration',
          ),
          if (hasActiveStreams)
            IconButton(
              onPressed: _stopAllStreams,
              icon: const Icon(Icons.stop),
              tooltip: 'Stop All Streams',
            ),
          if (!hasActiveStreams)
            IconButton(
              onPressed: _startAllStreams,
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Start All Streams',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_showConfig) ...[
              _buildConfigurationPanel(),
              const SizedBox(height: 16),
            ],
            _buildSystemStatsCard(),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.78,
                ),
                itemCount: _stats.length + 1, // +1 for input card
                itemBuilder: (context, index) {
                  if (index < _stats.length) {
                    final entry = _stats.entries.elementAt(index);
                    return _buildStreamStatsCard(entry.key, entry.value);
                  }
                  return _buildInputCard();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurationPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.settings, size: 20),
                SizedBox(width: 8),
                Text(
                  'Stream Configuration',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _configs.length,
                itemBuilder: (context, i) {
                  final e = _configs.entries.elementAt(i);
                  final stats = _stats[e.key]!;
                  return Container(
                    width: 280,
                    margin: const EdgeInsets.only(right: 16),
                    child: _buildStreamConfigCard(e.key, stats, e.value),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamConfigCard(
    String key,
    StreamStats stats,
    StreamConfiguration cfg,
  ) {
    return Card(
      color: Theme.of(context).colorScheme.surface.withOpacity(0.7),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(stats.icon, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                Text(
                  stats.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Device:',
              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
            ),
            if (cfg.isLoadingDevices)
              const LinearProgressIndicator(minHeight: 2)
            else if (cfg.availableDevices.isEmpty)
              Text(
                'No devices',
                style: TextStyle(fontSize: 10, color: Colors.red[300]),
              )
            else
              DropdownButton<String>(
                isExpanded: true,
                value: cfg.selectedDeviceId,
                style: const TextStyle(fontSize: 10),
                items: cfg.availableDevices
                    .map(
                      (d) => DropdownMenuItem(
                        value: d.deviceId,
                        child: Text(
                          d.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: stats.isActive
                    ? null
                    : (v) {
                        setState(() {
                          cfg.selectedDeviceId = v;
                          cfg.selectedDevice = cfg.availableDevices.firstWhere(
                            (d) => d.deviceId == v,
                          );
                        });
                        print(
                          'Selected $key device: ${cfg.selectedDevice!.name}',
                        );
                        print(v);
                        print(cfg.availableDevices);
                        _loadFormats(key);
                      },
              ),
            const SizedBox(height: 8),
            Text(
              'Format:',
              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
            ),
            if (cfg.isLoadingFormats)
              const LinearProgressIndicator(minHeight: 2)
            else if (cfg.availableFormats.isEmpty)
              Text(
                'No formats',
                style: TextStyle(fontSize: 10, color: Colors.red[300]),
              )
            else
              DropdownButton<dynamic>(
                isExpanded: true,
                value: cfg.selectedFormat,
                style: const TextStyle(fontSize: 10),
                items: cfg.availableFormats.map((f) {
                  String label;
                  if (f is MiniAVVideoInfo) {
                    final fps = f.frameRateNumerator / f.frameRateDenominator;
                    label =
                        '${f.width}x${f.height} @${fps.toStringAsFixed(0)}fps';
                  } else if (f is MiniAVAudioInfo) {
                    label = '${f.channels}ch ${f.sampleRate}Hz';
                  } else {
                    label = f.toString();
                  }
                  return DropdownMenuItem(
                    value: f,
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                }).toList(),
                onChanged: stats.isActive
                    ? null
                    : (v) {
                        setState(() {
                          cfg.selectedFormat = v;
                        });
                      },
              ),
            if (cfg.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  cfg.error!,
                  style: TextStyle(fontSize: 9, color: Colors.red[300]),
                ),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: stats.isActive ? null : () => _loadDevices(key),
              icon: const Icon(Icons.refresh, size: 12),
              label: const Text('Refresh', style: TextStyle(fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemStatsCard() {
    final totalFrames = _stats.values.fold(0, (sum, s) => sum + s.frameCount);
    final totalBandwidth = _stats.values.fold(
      0.0,
      (sum, s) => sum + s.bandwidth,
    );
    final active =
        _stats.values.where((s) => s.isActive).length +
        (_inputStats.isActive ? 1 : 0);
    final avgLatency =
        _stats.values
            .where((s) => s.isActive && s.latencyHistory.isNotEmpty)
            .fold(0.0, (sum, s) => sum + s.avgLatency) /
        max(1, active);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics, size: 24),
                const SizedBox(width: 8),
                const Text(
                  'System Overview',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: active > 0 ? Colors.green : Colors.grey,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    active > 0 ? 'LIVE ($active)' : 'STOPPED',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('Active Streams', '$active/5', Icons.stream),
                _buildStatItem(
                  'Total Frames',
                  _formatNumber(totalFrames),
                  Icons.video_library,
                ),
                _buildStatItem(
                  'Total Bandwidth',
                  '${totalBandwidth.toStringAsFixed(1)} MB/s',
                  Icons.speed,
                ),
                _buildStatItem(
                  'Avg Latency',
                  '${avgLatency.toStringAsFixed(1)} ms',
                  Icons.timer,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamStatsCard(String key, StreamStats stats) {
    final cfg = _configs[key]!;
    final efficiency = stats.fpsEfficiency;
    final efficiencyColor = efficiency > 90
        ? Colors.green
        : efficiency > 70
        ? Colors.orange
        : Colors.red;
    final isLoading = stats.isStarting || stats.isStopping;
    final canStart = cfg.selectedDevice != null && cfg.selectedFormat != null;
    final preview = (key == 'camera' || key == 'screen')
        ? _buildPreviewWidget(key, stats)
        : const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(stats.icon, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stats.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      if (stats.deviceName.isNotEmpty)
                        Text(
                          stats.deviceName,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.grey,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          padding: EdgeInsets.zero,
                          onPressed: canStart ? () => _toggleStream(key) : null,
                          icon: Icon(
                            stats.isActive ? Icons.stop : Icons.play_arrow,
                            size: 16,
                            color: stats.isActive
                                ? Colors.red
                                : canStart
                                ? Colors.green
                                : Colors.grey,
                          ),
                          tooltip: stats.isActive
                              ? 'Stop ${stats.name}'
                              : canStart
                              ? 'Start ${stats.name}'
                              : 'Configure device/format first',
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(
                color: stats.isActive
                    ? Colors.green.withOpacity(0.2)
                    : isLoading
                    ? Colors.orange.withOpacity(0.2)
                    : canStart
                    ? Colors.grey.withOpacity(0.2)
                    : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: stats.isActive
                      ? Colors.green
                      : isLoading
                      ? Colors.orange
                      : canStart
                      ? Colors.grey
                      : Colors.red,
                  width: 1,
                ),
              ),
              child: Text(
                stats.isActive
                    ? 'ACTIVE'
                    : stats.isStarting
                    ? 'STARTING...'
                    : stats.isStopping
                    ? 'STOPPING...'
                    : canStart
                    ? 'READY'
                    : 'NOT CONFIGURED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: stats.isActive
                      ? Colors.green
                      : isLoading
                      ? Colors.orange
                      : canStart
                      ? Colors.grey
                      : Colors.red,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 6),
            preview,
            const SizedBox(height: 6),
            Expanded(
              child: Column(
                children: [
                  _buildMetricRow(
                    'FPS',
                    '${stats.currentFps.toStringAsFixed(1)}/${stats.targetFps.toStringAsFixed(0)}',
                  ),
                  _buildMetricRow(
                    'Efficiency',
                    '${efficiency.toStringAsFixed(0)}%',
                    color: efficiencyColor,
                  ),
                  _buildMetricRow(
                    'Latency',
                    '${stats.avgLatency.toStringAsFixed(1)} ms',
                  ),
                  _buildMetricRow('Frames', _formatNumber(stats.frameCount)),
                  _buildMetricRow(
                    'Bandwidth',
                    '${stats.bandwidth.toStringAsFixed(1)} MB/s',
                  ),
                  _buildMetricRow(
                    'Avg Size',
                    _formatBytes(stats.avgFrameSize.round()),
                  ),
                  if (stats.resolution.isNotEmpty)
                    _buildMetricRow('Resolution', stats.resolution),
                  if (stats.lastPreviewError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        stats.lastPreviewError!,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.orangeAccent,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (stats.latencyHistory.isNotEmpty) ...[
              const Divider(height: 8),
              Text(
                'Range: ${stats.minLatency.toStringAsFixed(1)}-${stats.maxLatency.toStringAsFixed(1)} ms',
                style: const TextStyle(fontSize: 9, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewContainer({required Widget child}) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(color: Colors.black, child: child),
      ),
    );
  }

  /// Builds the preview widget for camera/screen streams.
  ///
  /// Shows [MiniavGpuPreview] when a GPU frame has been presented (Windows
  /// D3D11 zero-copy path); otherwise falls back to the CPU [RawImage] path.
  Widget _buildPreviewWidget(String key, StreamStats stats) {
    final ctrl = key == 'camera' ? _cameraPreviewCtrl : _screenPreviewCtrl;
    final cpuPreview = key == 'camera' ? _cameraPreview : _screenPreview;

    if (!stats.isActive) {
      return _previewContainer(
        child: Text(
          'Idle',
          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
        ),
      );
    }

    // GPU path: controller has a registered textureId.
    if (ctrl.textureId != null) {
      return _previewContainer(
        child: AnimatedBuilder(
          animation: ctrl,
          builder: (_, __) => MiniavGpuPreview(controller: ctrl),
        ),
      );
    }

    // CPU fallback path.
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: cpuPreview,
      builder: (_, img, __) {
        if (img == null) {
          return _previewContainer(
            child: Text(
              stats.lastPreviewError ?? 'Waiting frame...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 9, color: Colors.grey[500]),
            ),
          );
        }
        return _previewContainer(
          child: RawImage(image: img, fit: BoxFit.cover),
        );
      },
    );
  }

  Widget _buildInputCard() {
    final s = _inputStats;
    final isLoading = s.isStarting || s.isStopping;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('🎮', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Input Capture',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        'Keyboard / Mouse / Gamepad',
                        style: TextStyle(fontSize: 9, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          padding: EdgeInsets.zero,
                          onPressed: _toggleInputCapture,
                          icon: Icon(
                            s.isActive ? Icons.stop : Icons.play_arrow,
                            size: 16,
                            color: s.isActive ? Colors.red : Colors.green,
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Config toggles (only when stopped)
            if (!s.isActive) ...[
              Row(
                children: [
                  _inputToggle(
                    'KB',
                    _inputKeyboard,
                    (v) => setState(() => _inputKeyboard = v),
                  ),
                  const SizedBox(width: 6),
                  _inputToggle(
                    'Mouse',
                    _inputMouse,
                    (v) => setState(() => _inputMouse = v),
                  ),
                  const SizedBox(width: 6),
                  _inputToggle(
                    'Pad',
                    _inputGamepad,
                    (v) => setState(() => _inputGamepad = v),
                  ),
                  const Spacer(),
                  Text(
                    '${_mouseThrottleHz}Hz',
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                  SizedBox(
                    width: 80,
                    child: Slider(
                      value: _mouseThrottleHz.toDouble(),
                      min: 0,
                      max: 240,
                      divisions: 8,
                      onChanged: (v) =>
                          setState(() => _mouseThrottleHz = v.round()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              decoration: BoxDecoration(
                color: s.isActive
                    ? Colors.green.withOpacity(0.2)
                    : isLoading
                    ? Colors.orange.withOpacity(0.2)
                    : Colors.grey.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: s.isActive
                      ? Colors.green
                      : isLoading
                      ? Colors.orange
                      : Colors.grey,
                  width: 1,
                ),
              ),
              child: Text(
                s.isActive
                    ? 'CAPTURING'
                    : s.isStarting
                    ? 'STARTING...'
                    : s.isStopping
                    ? 'STOPPING...'
                    : 'READY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: s.isActive
                      ? Colors.green
                      : isLoading
                      ? Colors.orange
                      : Colors.grey,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 6),
            // Stats
            _buildMetricRow('Total Events', '${s.totalEvents}'),
            _buildMetricRow('Events/sec', s.eventsPerSecond.toStringAsFixed(1)),
            _buildMetricRow('Keyboard', '${s.keyboardEvents}'),
            _buildMetricRow('Mouse', '${s.mouseEvents}'),
            _buildMetricRow('Gamepad', '${s.gamepadEvents}'),
            if (s.lastKeyboard != null)
              _buildMetricRow(
                'Last Key',
                'vk=${s.lastKeyboard!.keyCode} ${s.lastKeyboard!.action.name}',
              ),
            if (s.lastMouse != null)
              _buildMetricRow(
                'Last Mouse',
                '(${s.lastMouse!.x},${s.lastMouse!.y}) ${s.lastMouse!.action.name}',
              ),
            if (s.lastGamepad != null) ...[
              _buildMetricRow('Buttons', _buttonNames(s.lastGamepad!.buttons)),
              _buildMetricRow(
                'Triggers',
                'LT=${s.lastGamepad!.leftTrigger} RT=${s.lastGamepad!.rightTrigger}',
              ),
              _buildMetricRow(
                'L-Stick',
                '${s.lastGamepad!.leftStickX},${s.lastGamepad!.leftStickY}',
              ),
              _buildMetricRow(
                'R-Stick',
                '${s.lastGamepad!.rightStickX},${s.lastGamepad!.rightStickY}',
              ),
            ],
            const SizedBox(height: 4),
            // Event log
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  reverse: true,
                  itemCount: s.eventLog.length,
                  itemBuilder: (_, i) {
                    final line = s.eventLog[s.eventLog.length - 1 - i];
                    return Text(
                      line,
                      style: const TextStyle(
                        fontSize: 8,
                        fontFamily: 'monospace',
                        color: Colors.grey,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 2),
        Text(label, style: const TextStyle(fontSize: 9)),
      ],
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 20, color: Colors.cyan),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Widget _buildMetricRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int number) {
    if (number < 1000) return number.toString();
    if (number < 1000000) return '${(number / 1000).toStringAsFixed(1)}K';
    return '${(number / 1000000).toStringAsFixed(1)}M';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
