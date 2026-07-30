/// Recorder runtime: opens encoders + muxers, wires capture sources to
/// encoders, fans encoded packets out to every sink, and drains cleanly
/// on stop.
library;

import 'dart:async';
import 'dart:ffi' show Pointer, Void;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav/miniav.dart';
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:minigpu/minigpu.dart';

import 'adaptive_gpu_throttle.dart';
import 'bounded_write_queue.dart';
import 'container_utils.dart';
import 'frame_pacer.dart';
import 'gpu_screen_processor.dart';
import 'recorder_log.dart';
import 'recorder_sink.dart';
import 'recorder_source.dart';
import 'track_chunk.dart';

export 'recorder_log.dart' show RecorderLogLevel, RecorderLogSource;

/// Run-time state of an open [Recorder].
enum RecorderState { idle, starting, running, stopping, stopped, errored }

// ---------------------------------------------------------------------------
// Process-global shared GPU singleton.
//
// The shared [Minigpu] + Dawn-allocated `ID3D11Device` are expensive to
// create and the underlying native Dawn context CANNOT be destroyed and
// re-created reliably in a single process — re-init can pick a different
// backend (D3D12 vs D3D11) than the first run, breaking the cross-API
// shared-texture path with errors like:
//
//   [wgpu] The D3D11 device of the texture and the D3D11 device of
//          [Device "MGPU.MainDevice"] must be same.
//   [minigpu_external] create_shared_output_texture: Dawn is not on D3D11
//          backend; cross-API path not implemented in this build.
//
// We therefore keep ONE [Minigpu] alive for the whole isolate. Stopping a
// recorder no longer tears it down. Tests / hot-restart hooks can call
// [Recorder.disposeSharedGpu] to explicitly release it.
// ---------------------------------------------------------------------------
Minigpu? _sharedGpu;
int _sharedD3d11Device = 0;
Future<void>? _sharedGpuInitFuture;
bool _sharedGpuUnsupported = false;

class Recorder {
  Recorder.internal({
    required List<RecorderSource> sources,
    required List<RecorderSink> sinks,
    required this.defaultVideoBitrate,
    required this.defaultAudioBitrate,
    required this.defaultFrameRate,
    required this.backendPreference,
    required this.preferZeroCopy,
  }) : _sourceConfigs = sources,
       _sinkConfigs = sinks;

  final List<RecorderSource> _sourceConfigs;
  final List<RecorderSink> _sinkConfigs;
  final int defaultVideoBitrate;
  final int defaultAudioBitrate;
  final int defaultFrameRate;
  final BackendPreference backendPreference;

  /// When true, the recorder lazily spins up a shared [Minigpu] + Dawn
  /// `ID3D11Device` and passes them to backends via [BackendContext], so
  /// the FFmpeg backend can open a D3D11VA zero-copy encoder when the
  /// host supports it (Windows + NVENC/AMF/QSV/MF). Has no effect on
  /// non-Windows or when no source benefits.
  final bool preferZeroCopy;

  /// Cached shared context handed to every backend factory call.
  /// Borrows the process-global [_sharedGpu] + Dawn `ID3D11Device*` (as int).
  /// Re-used per encoder so backends can opt into a zero-copy path.
  ///
  /// Never owns the GPU device — see the file-level singleton block above.
  BackendContext? _backendContext;

  RecorderState _state = RecorderState.idle;
  RecorderState get state => _state;

  /// Master clock — set when [start] completes; all packet timestamps are
  /// relative to this in microseconds.
  final Stopwatch _masterClock = Stopwatch();

  // Resolved tracks (encoders + capture handles), in source-declaration order.
  final List<_TrackRuntime> _tracks = [];

  // Per-file-sink muxer; stream sinks have no muxer, just a callback.
  final List<_SinkRuntime> _sinks = [];

  Object? _lastError;
  Object? get lastError => _lastError;

  // -----------------------------------------------------------------------
  // Warmup
  // -----------------------------------------------------------------------

  /// Warm up every registered tools backend ahead of the first [start] —
  /// for the FFmpeg backend that means downloading + loading the shared
  /// libraries (a one-time multi-MB download on a fresh machine).
  ///
  /// Registers the FFmpeg backend first, so this works from `main()` /
  /// `initState` with only a `miniav_recorder` import. Calling
  /// `MiniAVTools.warmup()` directly does NOT do that: backend registration
  /// otherwise happens lazily inside [start], so a too-early warmup would
  /// silently skip FFmpeg and the download would still hit the first
  /// recording.
  ///
  /// Same stream contract as [MiniAVTools.warmup]: emits [WarmupProgress]
  /// events (`fraction` is the download progress), never errors — failures
  /// arrive as events with `error` set — and completes when all backends
  /// are warm. Safe to call repeatedly; a no-op when everything is cached.
  ///
  /// ```dart
  /// await Recorder.warmup().last; // block until warm
  /// ```
  static Stream<WarmupProgress> warmup() {
    registerFfmpegBackend();
    return MiniAVTools.warmup();
  }

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  Future<void> start() async {
    await _prepare();
    await _launch();
  }

  /// Phase 1: load FFmpeg, initialise GPU, open encoders + muxers.
  /// After this returns the recorder is in [RecorderState.starting].
  /// Do not do significant async work between [_prepare] and [_launch] if
  /// you want tight clock synchronisation with other recorders.
  Future<void> _prepare() async {
    if (_state != RecorderState.idle) {
      throw StateError('Recorder.start: already $_state');
    }
    _state = RecorderState.starting;
    try {
      // Make sure FFmpeg is loaded (needed for both encoders + muxers).
      // Also ensure the FFmpeg backend is registered with the platform —
      // the auto-register top-level final only fires when something in the
      // library reads it; here we trigger it explicitly so callers don't
      // have to add a stray import-side-effect line.
      registerFfmpegBackend();
      await ensureFFmpegLoaded();

      // Lazily try to bring up the shared GPU device for zero-copy. Only
      // worth doing on Windows when the user opted in. On any failure we
      // silently fall back to the CPU upload path — the rest of the
      // recorder is fully functional without it.
      await _maybeInitSharedGpu();

      // 1. Build each track (open encoder + record capture config).
      for (var i = 0; i < _sourceConfigs.length; i++) {
        final cfg = _sourceConfigs[i];
        final track = await _buildTrack(i, cfg);
        _tracks.add(track);
      }

      // 2. Build each sink runtime (open muxer for file sinks).
      for (final sink in _sinkConfigs) {
        _sinks.add(await _buildSink(sink));
      }
    } catch (e) {
      _lastError = e;
      _state = RecorderState.errored;
      await _shutdown(force: true);
      rethrow;
    }
  }

  /// Phase 2: start the master clock and all capture sources.
  /// Should be called immediately after [_prepare].
  Future<void> _launch() async {
    if (_state != RecorderState.starting) {
      throw StateError('Recorder._launch: expected starting, got $_state');
    }
    try {
      // 3. Start all capture contexts. Master clock starts now.
      _masterClock.start();
      for (final t in _tracks) {
        await t.startCapture(this);
      }

      _state = RecorderState.running;
    } catch (e) {
      _lastError = e;
      _state = RecorderState.errored;
      await _shutdown(force: true);
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_state != RecorderState.running) {
      // Idempotent for repeated stop / stop-after-error.
      return;
    }
    _state = RecorderState.stopping;
    await _shutdown(force: false);
    _state = RecorderState.stopped;
  }

  Future<void> _shutdown({required bool force}) async {
    // 1. Stop captures (so no more frames arrive).
    for (final t in _tracks) {
      try {
        await t.stopCapture();
      } catch (e) {
        _log('stopCapture(${t.label}): $e', RecorderLogLevel.error);
      }
    }
    _masterClock.stop();

    // 2. Wait for any in-flight encode operations.
    for (final t in _tracks) {
      await t.drainInFlight();
    }

    // 3. Flush encoders + push trailing packets to every sink.
    for (final t in _tracks) {
      try {
        await t.flushAndDispatch(this);
      } catch (e) {
        _log('flush(${t.label}): $e', RecorderLogLevel.error);
      }
    }

    // 4. Finish + close every muxer.
    for (final s in _sinks) {
      try {
        await s.finish();
      } catch (e) {
        _log('finish sink: $e', RecorderLogLevel.error);
      }
    }

    // 5. Close encoders + capture contexts.
    for (final t in _tracks) {
      try {
        await t.dispose();
      } catch (_) {}
    }
    for (final s in _sinks) {
      try {
        await s.dispose();
      } catch (_) {}
    }
    if (!force) {
      _tracks.clear();
      _sinks.clear();
    }

    // 6. Drop our reference to the shared backend context. The underlying
    //    [_sharedGpu] + Dawn-owned ID3D11Device are intentionally NOT torn
    //    down here — they live for the lifetime of the isolate so that a
    //    subsequent recorder can reuse them without re-initialising Dawn
    //    (which would risk picking a different backend on the second run).
    //    Use [Recorder.disposeSharedGpu] for explicit teardown.
    _backendContext = null;
  }

  // -----------------------------------------------------------------------
  // Static GPU lifecycle (process-global)
  // -----------------------------------------------------------------------

  /// Bind the process-global GPU context to the adapter driving the PRIMARY
  /// display (Windows), so screen capture → GPU processing → HW encode all
  /// stay on one adapter (same-adapter zero-copy). On hybrid systems where a
  /// discrete GPU is also present this routes the pipeline through the
  /// display GPU — e.g. an AMD/Intel iGPU showing the desktop — which is the
  /// only topology where that iGPU's HW encoder (AMF/QSV) can be fed
  /// zero-copy.
  ///
  /// MUST be called before ANY minigpu use in the process (including
  /// unrelated features such as audio visualizers): the native context is
  /// created once per process and its adapter cannot change afterwards.
  /// Returns `true` when the hint was applied before the context existed;
  /// `false` (with a warning log) when it was too late or the platform has
  /// no adapter selection.
  ///
  /// Trade-off: ALL of this process's minigpu compute then runs on the
  /// display adapter. The `MGPU_ADAPTER_NAME` env var overrides this hint.
  static bool preferCaptureAdapter({bool enable = true}) {
    if (!Platform.isWindows) return false;
    final applied = Minigpu.preferDisplayAdapter(enable);
    if (!applied && enable) {
      _log(
        'preferCaptureAdapter: GPU context already initialized — the hint '
        'must be set before any minigpu use (call this at app startup). '
        'Current adapter kept; capture may take the cross-adapter path.',
        RecorderLogLevel.warning,
      );
    }
    return applied;
  }

  /// Idempotently initialise the process-global shared [Minigpu] + Dawn
  /// `ID3D11Device`. Returns once the singleton is ready (or no-ops on
  /// non-Windows / when zero-copy is unsupported).
  ///
  /// Safe to call multiple times concurrently — overlapping calls share
  /// the same in-flight init future. Idempotent across recorder lifecycles:
  /// `start()` / `stop()` no longer re-create or destroy the GPU device.
  ///
  /// After calling this, use [sharedGpu] to obtain the [Minigpu] instance
  /// (null if GPU is unsupported on this platform).
  static Future<void> ensureSharedGpu() async {
    if (!Platform.isWindows) return;
    if (_sharedGpuUnsupported) return;
    if (_sharedGpu != null && _sharedD3d11Device != 0) return;
    _sharedGpuInitFuture ??= _initSharedGpuOnce();
    await _sharedGpuInitFuture;
  }

  /// The process-global [Minigpu] instance, or `null` when GPU is
  /// unsupported / not yet initialised. Call [ensureSharedGpu] first.
  static Minigpu? get sharedGpu => _sharedGpu;

  static Future<void> _initSharedGpuOnce() async {
    try {
      final gpu = Minigpu();
      await gpu.init();
      if (!gpu.isExternalContentTypeSupported(
        ExternalContentType.d3d11SharedHandle,
      )) {
        _sharedGpuUnsupported = true;
        return;
      }
      final dev = gpu.createD3D11DeviceOnDawnAdapter();
      if (dev == 0) {
        _sharedGpuUnsupported = true;
        _log(
          'zero-copy GPU init: createD3D11DeviceOnDawnAdapter() '
          'returned 0 — Dawn backend may not be D3D11 or adapter not found.',
          RecorderLogLevel.warning,
        );
        return;
      }
      _sharedGpu = gpu;
      _sharedD3d11Device = dev;
      _log(
        'zero-copy GPU device ready '
        '(Dawn D3D11, device=0x${dev.toRadixString(16)}). '
        'Look for matching luid= in [shim] OpenSharedResource1 logs.',
      );
    } catch (e) {
      _log(
        'zero-copy GPU init failed ($e) — using CPU upload path.',
        RecorderLogLevel.warning,
      );
      _sharedGpuUnsupported = true;
    }
  }

  /// Explicitly release the process-global shared GPU resources.
  ///
  /// Call this from a Flutter hot-restart hook (`reassemble`) or app
  /// shutdown to avoid `Callback invoked after it has been deleted`
  /// crashes from native worker threads holding stale Dart callbacks.
  ///
  /// After this returns, the next [start] call (or [ensureSharedGpu]) will
  /// re-initialise the GPU. Callers should ensure no recorder is running.
  static Future<void> disposeSharedGpu() async {
    final gpu = _sharedGpu;
    _sharedGpu = null;
    _sharedD3d11Device = 0;
    _sharedGpuInitFuture = null;
    _sharedGpuUnsupported = false;
    if (gpu != null) {
      try {
        await gpu.destroy();
      } catch (_) {}
    }
  }

  // -----------------------------------------------------------------------
  // Unified log-level configuration
  // -----------------------------------------------------------------------

  /// Install a unified log callback that receives messages from every
  /// subsystem the recorder touches — all from a single import of
  /// `package:miniav_recorder/miniav_recorder.dart`.
  ///
  /// [callback] is invoked on the Dart event loop with:
  /// - `source` — which subsystem produced the message
  ///   ([RecorderLogSource.recorder], [RecorderLogSource.miniav], or
  ///   [RecorderLogSource.ffmpeg])
  /// - `level`   — severity, expressed as the closest [RecorderLogLevel]
  /// - `message` — the formatted, trimmed log line (no trailing newline)
  ///
  /// Pass `null` to remove the callback; all logs will fall back to the
  /// console via `print` (the default behaviour — deliberately not
  /// `dart:io` `stderr`, which throws an uncatchable async error in
  /// console-less Windows GUI apps).
  ///
  /// Call [setLogLevel] first (or after) to control the verbosity threshold
  /// on the native side — the callback receives only messages that pass that
  /// threshold.
  ///
  /// **minigpu / Dawn** logs are routed via [RecorderLogSource.minigpu].
  ///
  /// Example — write everything to a file:
  /// ```dart
  /// final sink = File('recorder.log').openWrite();
  /// Recorder.setLogCallback((source, level, msg) =>
  ///   sink.writeln('[${source.name}] ${level.name}: $msg'));
  /// Recorder.setLogLevel(RecorderLogLevel.verbose);
  /// ```
  static void setLogCallback(
    void Function(
      RecorderLogSource source,
      RecorderLogLevel level,
      String message,
    )?
    callback,
  ) {
    recorderLogCallback = callback;
    _applyLogging();
  }

  /// Configure log verbosity for every native subsystem used by the recorder:
  ///
  /// - **MiniAV** (camera / screen / audio C library) — level + callback routing
  /// - **FFmpeg** (encoder / muxer) — AV_LOG_* level + callback routing via
  ///   shim, plus the miniav_tools_ffmpeg Dart layer (downloader, encoder
  ///   selection, vendor probing)
  /// - **minigpu / Dawn** — level + callback routing via mgpuSetLogCallback
  ///
  /// If [setLogCallback] has been called, that callback receives the messages.
  /// Otherwise, messages are forwarded to the console via `print`.
  ///
  /// Call before [start] (or as early as possible — before FFmpeg is loaded).
  /// Subsequent calls replace any previously installed callbacks.
  static void setLogLevel(RecorderLogLevel level) {
    _currentLevel = level;
    _applyLogging();
  }

  static RecorderLogLevel _currentLevel = RecorderLogLevel.info;

  static void _applyLogging() {
    final level = _currentLevel;

    // Every bridge below funnels into [recorderLog], which forwards to the
    // callback installed via [setLogCallback] or to the safe `print` default.

    // 1. MiniAV capture library.
    MiniAV.setLogLevel(miniavLogLevelFor(level));
    if (level == RecorderLogLevel.quiet) {
      // Install a no-op callback rather than null. Passing null to
      // MiniAV_SetLogCallback removes the Dart bridge and causes the C
      // library to fall back to its own built-in stderr logger
      // ("[MiniAV C - DEBUG]: ..."). A no-op callback absorbs messages
      // on the Dart side so the native default logger is never activated.
      MiniAV.setLogCallback((_, __) {});
    } else {
      MiniAV.setLogCallback(
        (miniavLevel, msg) => recorderLog(
          RecorderLogSource.miniav,
          _fromMiniAVLevel(miniavLevel),
          msg.trimRight(),
        ),
      );
    }

    // 2. FFmpeg encoder / muxer (via shim — no-op if shim is not loaded yet;
    //    call setLogLevel again after ensureFFmpegLoaded() if needed).
    final shim = FfmpegShim.tryLoad();
    if (shim != null) {
      shim.setFfmpegLogLevel(avLogLevelFor(level));
      if (level == RecorderLogLevel.quiet) {
        // No-op callback for the same reason as MiniAV above: passing null
        // may re-enable FFmpeg's own av_log default handler (stderr).
        shim.setFfmpegLogCallback((_, __) {});
      } else {
        shim.setFfmpegLogCallback((int avLevel, String msg) {
          if (msg.isEmpty) return;
          recorderLog(
            RecorderLogSource.ffmpeg,
            _fromAvLevel(avLevel),
            msg.trimRight(),
          );
        });
      }
    }

    // 2b. miniav_tools_ffmpeg Dart layer (downloader, encoder selection,
    //     vendor probing). Unlike the shim bridge above, this is available
    //     before FFmpeg is loaded — auto-download diagnostics are captured.
    setFfmpegToolsLogLevel(miniavLogLevelFor(level));
    if (level == RecorderLogLevel.quiet) {
      setFfmpegToolsLogCallback(null); // level `none` silences everything
    } else {
      setFfmpegToolsLogCallback(
        (l, msg) =>
            recorderLog(RecorderLogSource.ffmpeg, _fromMiniAVLevel(l), msg),
      );
    }

    // 3. minigpu / Dawn native GPU layer.
    final mgpuLevel = minigpuLevelFor(level);
    if (level == RecorderLogLevel.quiet) {
      Minigpu.setLogCallback(null, level: -1);
    } else {
      Minigpu.setLogCallback((mgpuLvl, msg) {
        if (msg.isEmpty) return;
        recorderLog(
          RecorderLogSource.minigpu,
          _fromMgpuLevel(mgpuLvl),
          msg.trimRight(),
        );
      }, level: mgpuLevel);
    }
  }

  /// Route a recorder-internal log line through the callback installed via
  /// [setLogCallback] (if set) or to the console via `print`. All
  /// `[recorder]` messages in this file go through here.
  static void _log(
    String message, [
    RecorderLogLevel level = RecorderLogLevel.info,
  ]) => recorderLog(RecorderLogSource.recorder, level, message);

  // Private level-conversion helpers — intentionally not exposed; callers
  // use [miniavLogLevelFor] / [avLogLevelFor] for the forward direction.
  static RecorderLogLevel _fromMiniAVLevel(MiniAVLogLevel l) => switch (l) {
    MiniAVLogLevel.trace || MiniAVLogLevel.debug => RecorderLogLevel.verbose,
    MiniAVLogLevel.info => RecorderLogLevel.info,
    MiniAVLogLevel.warn => RecorderLogLevel.warning,
    MiniAVLogLevel.error => RecorderLogLevel.error,
    MiniAVLogLevel.none => RecorderLogLevel.quiet,
  };

  static RecorderLogLevel _fromAvLevel(int avLevel) {
    if (avLevel >= 48) return RecorderLogLevel.verbose; // AV_LOG_DEBUG+
    if (avLevel >= 32) return RecorderLogLevel.info; // AV_LOG_INFO/VERBOSE
    if (avLevel >= 24) return RecorderLogLevel.warning; // AV_LOG_WARNING
    if (avLevel >= 0) return RecorderLogLevel.error; // AV_LOG_ERROR/FATAL/PANIC
    return RecorderLogLevel.quiet; // AV_LOG_QUIET
  }

  /// Maps a [RecorderLogLevel] to the corresponding [MiniAVLogLevel].
  ///
  /// Exposed as a static so tests can assert the mapping without side effects.
  static MiniAVLogLevel miniavLogLevelFor(RecorderLogLevel level) =>
      switch (level) {
        RecorderLogLevel.verbose => MiniAVLogLevel.debug,
        RecorderLogLevel.info => MiniAVLogLevel.info,
        RecorderLogLevel.warning => MiniAVLogLevel.warn,
        RecorderLogLevel.error => MiniAVLogLevel.error,
        RecorderLogLevel.quiet => MiniAVLogLevel.none,
      };

  /// Maps a [RecorderLogLevel] to the corresponding FFmpeg `AV_LOG_*` level.
  ///
  /// Constants: `quiet=-8`, `error=16`, `warning=24`, `info=32`, `debug=48`.
  ///
  /// Exposed as a static so tests can assert the mapping without side effects.
  static int avLogLevelFor(RecorderLogLevel level) => switch (level) {
    RecorderLogLevel.verbose => 48, // AV_LOG_DEBUG
    RecorderLogLevel.info => 32, // AV_LOG_INFO
    RecorderLogLevel.warning => 24, // AV_LOG_WARNING
    RecorderLogLevel.error => 16, // AV_LOG_ERROR
    RecorderLogLevel.quiet => -8, // AV_LOG_QUIET
  };

  /// Maps a [RecorderLogLevel] to the corresponding mgpu log level int.
  ///
  /// mgpu levels: -1=none 0=debug 1=info 2=warn 3=error.
  ///
  /// Exposed as a static so tests can assert the mapping without side effects.
  static int minigpuLevelFor(RecorderLogLevel level) => switch (level) {
    RecorderLogLevel.verbose => 0, // LOG_DEBUG
    RecorderLogLevel.info => 1, // LOG_INFO
    RecorderLogLevel.warning => 2, // LOG_WARN
    RecorderLogLevel.error => 3, // LOG_ERROR
    RecorderLogLevel.quiet => -1, // LOG_NONE
  };

  /// Converts a native mgpu level int to [RecorderLogLevel].
  static RecorderLogLevel _fromMgpuLevel(int lvl) {
    if (lvl <= 0) return RecorderLogLevel.verbose; // LOG_DEBUG or below
    if (lvl == 1) return RecorderLogLevel.info; // LOG_INFO
    if (lvl == 2) return RecorderLogLevel.warning; // LOG_WARN
    return RecorderLogLevel.error; // LOG_ERROR
  }

  // -----------------------------------------------------------------------
  // Shared GPU bring-up (for zero-copy encoder paths)
  // -----------------------------------------------------------------------

  Future<void> _maybeInitSharedGpu() async {
    if (!preferZeroCopy) return;
    if (!Platform.isWindows) return;
    // No screen source means no candidate for D3D11 zero-copy today.
    final hasScreen = _sourceConfigs.any((s) => s is ScreenRecorderSource);
    if (!hasScreen) return;
    await ensureSharedGpu();
    final gpu = _sharedGpu;
    if (gpu == null) {
      _backendContext = null;
      return;
    }

    // Re-acquire the D3D11 device handle from Dawn on every recording session.
    //
    // After system sleep/resume (or a GPU TDR reset), Dawn internally
    // recreates its D3D11 device. The process-global [_sharedD3d11Device]
    // would still hold the OLD (stale) handle. The GpuScreenProcessor uses
    // Dawn's NEW device to produce textures, while the encoder is opened
    // with the OLD device — causing a cross-device error that silently drops
    // every video frame while audio continues normally, manifesting as an
    // apparent A/V sync offset on the 2nd+ recording session after a long gap.
    //
    // Calling createD3D11DeviceOnDawnAdapter() on each session gives us the
    // device currently in use by Dawn.  If the pointer changed (device was
    // recreated), we release the old COM AddRef and adopt the new handle so
    // both the GpuScreenProcessor and the encoder always share the same device.
    final freshDev = gpu.createD3D11DeviceOnDawnAdapter();
    if (freshDev == 0) {
      _backendContext = null;
      return;
    }

    // Synchronise the process-global handle with Dawn's current device.
    // FfmpegShim is guaranteed non-null here: ensureFFmpegLoaded() ran before
    // this method in _prepare().
    final shim = FfmpegShim.tryLoad();
    final prevDev = _sharedD3d11Device;
    if (freshDev != prevDev) {
      // Dawn is now on a different device (e.g. after GPU reset / wake-up).
      // Release our AddRef on the old handle and adopt the new one.
      if (shim != null && prevDev != 0) {
        shim.d3d11Release(Pointer<Void>.fromAddress(prevDev));
      }
      _sharedD3d11Device = freshDev;
      _log(
        'zero-copy GPU device refreshed: 0x${freshDev.toRadixString(16)} '
        '(was 0x${prevDev.toRadixString(16)} — Dawn device was recreated, '
        'likely after sleep/resume or GPU reset)',
      );
    } else {
      // Same device — release the extra AddRef from this call to keep the
      // COM refcount balanced.
      shim?.d3d11Release(Pointer<Void>.fromAddress(freshDev));
    }

    final dev = _sharedD3d11Device;
    if (dev == 0) {
      _backendContext = null;
      return;
    }
    _backendContext = BackendContext(
      sharedGpu: gpu,
      d3d11DeviceHandle: dev,
      preferZeroCopy: true,
    );
    // Fire a background warm-up so the Intel MF/QSV (and any other vendor)
    // SDK finishes its one-time driver-side initialisation before the
    // real compatibility probe runs in _buildScreenTrack.  Without this,
    // both pre-check attempts land within ~10 ms of GPU device ready, which
    // is too fast for the driver to finish MFStartup / DXVA session init —
    // both fail and the recorder falls back to CPU for the entire first
    // session.  The warm-up is unawaited; failures are silently ignored.
    ffmpegD3d11WarmUp(dev);
  }

  // -----------------------------------------------------------------------
  // Build helpers
  // -----------------------------------------------------------------------

  Future<_TrackRuntime> _buildTrack(int index, RecorderSource cfg) async {
    switch (cfg) {
      case ScreenRecorderSource():
        return _buildScreenTrack(index, cfg);
      case CameraRecorderSource():
        return _buildCameraTrack(index, cfg);
      case MicRecorderSource():
        return _buildAudioTrack(
          index,
          deviceId: cfg.deviceId,
          codec: cfg.codec,
          bitrate: cfg.bitrateBps,
          sampleRate: cfg.sampleRate,
          channels: cfg.channels,
          factory: () async => MiniAudioInput.createContext(),
          configure: (ctx, fmt) =>
              (ctx as MiniAudioInputContext).configure(cfg.deviceId, fmt),
          getDefault: () => MiniAudioInput.getDefaultFormat(cfg.deviceId),
          start: (ctx, cb) => (ctx as MiniAudioInputContext).startCapture(cb),
          stop: (ctx) => (ctx as MiniAudioInputContext).stopCapture(),
          destroy: (ctx) => (ctx as MiniAudioInputContext).destroy(),
          label: 'mic[${cfg.deviceId}]',
        );
      case LoopbackRecorderSource():
        return _buildAudioTrack(
          index,
          deviceId: cfg.deviceId,
          codec: cfg.codec,
          bitrate: cfg.bitrateBps,
          sampleRate: cfg.sampleRate,
          channels: cfg.channels,
          factory: () async => MiniLoopback.createContext(),
          configure: (ctx, fmt) =>
              (ctx as MiniLoopbackContext).configure(cfg.deviceId, fmt),
          getDefault: () => MiniLoopback.getDefaultFormat(cfg.deviceId),
          start: (ctx, cb) => (ctx as MiniLoopbackContext).startCapture(cb),
          stop: (ctx) => (ctx as MiniLoopbackContext).stopCapture(),
          destroy: (ctx) => (ctx as MiniLoopbackContext).destroy(),
          label: 'loopback[${cfg.deviceId}]',
        );
      case MixedAudioRecorderSource():
        return _buildMixedAudioTrack(index, cfg);
    }
  }

  Future<_TrackRuntime> _buildScreenTrack(
    int index,
    ScreenRecorderSource cfg,
  ) async {
    // Resolve the display ID: accept whatever string enumerateDisplays()
    // returns, or null to mean "use the platform default display".
    String? resolvedDisplayId = cfg.displayId;
    if (resolvedDisplayId == null && cfg.windowId == null) {
      final displays = await MiniScreen.enumerateDisplays();
      if (displays.isEmpty) {
        throw StateError('addScreen: no displays found on this platform');
      }
      resolvedDisplayId = displays
          .firstWhere((d) => d.isDefault, orElse: () => displays.first)
          .deviceId;
    }
    final defaults = await MiniScreen.getDefaultFormats(
      resolvedDisplayId ?? cfg.windowId!,
    );
    var (videoFormat, _) = defaults;
    // Pick output preference: GPU only when:
    //   (a) a BackendContext with a live D3D11 device is present, AND
    //   (b) a D3D11VA-capable encoder exists for the requested codec.
    // Without (b) the GPU processor produces D3D11TextureFrameSource frames that
    // FfmpegHwEncoder (Stage-A CPU path) cannot consume, crashing every frame.
    // Use the effective codec (after resolution-based promotion) to avoid
    // false-positives when H.264 at 4K+ is promoted to HEVC.
    //
    // IMPORTANT: codec promotion + the probe must use the **post-downscale**
    // (encoder) dimensions, not the raw capture dimensions.  Otherwise the
    // precheck asks "does HEVC work?" while the actual encoder later opens at
    // the smaller scaled size as plain h264 — and the false-fail forces CPU
    // capture into a path the encoder/processor were not configured for.
    final wantHwForGpuCheck =
        cfg.hwAccel == HwAccelPreference.preferred ||
        cfg.hwAccel == HwAccelPreference.required;
    final precheckTarget = cfg.scale.targetSize(
      videoFormat.width,
      videoFormat.height,
    );
    final (precheckW, precheckH) =
        precheckTarget ?? (videoFormat.width, videoFormat.height);
    final effectiveCodecForGpuCheck = FfmpegBackend.bestCodecForResolution(
      width: precheckW,
      height: precheckH,
      hwAccel: wantHwForGpuCheck,
      preferred: cfg.codec,
    );
    final hasD3d11Encoder =
        _backendContext != null &&
        Platform.isWindows &&
        await ffmpegD3d11EncoderCompatibleWith(
          effectiveCodecForGpuCheck,
          _backendContext!.d3d11DeviceHandle,
        );
    if (_backendContext != null &&
        Platform.isWindows &&
        !hasD3d11Encoder &&
        ffmpegD3d11EncoderAvailable(effectiveCodecForGpuCheck)) {
      // The symbol check passed but the probe failed — a vendor is registered
      // (e.g. NVENC) but cannot open with the injected Dawn D3D11 device.
      // This happens when Dawn is on an Intel iGPU but only NVENC/AMF encoders
      // are present (wrong adapter). CPU output will be used instead.
      Recorder._log(
        'screen: D3D11 zero-copy pre-check: no vendor opened with '
        'device=0x${_backendContext!.d3d11DeviceHandle.toRadixString(16)} — '
        '${effectiveCodecForGpuCheck.name} vendors are registered but '
        'incompatible with this adapter. Falling back to CPU capture. '
        '(Check the log for per-vendor failure details.)',
        RecorderLogLevel.warning,
      );
    }
    // Also enable GPU output when a minigpu-style encoder that accepts GPU
    // buffer input is registered for this codec (e.g. MinigpuAv1Pipeline).
    // We discover the actual encoder only after _openVideoEncoder below, but
    // we need the flag now to decide outputPreference.  Pre-check: the
    // BackendContext must be present and any registered backend for cfg.codec
    // must accept gpuTexture frames.
    // NOTE: intentionally NOT gated on !hasD3d11Encoder.  The encoder backend
    // priorities (minigpu=60 > ffmpeg=50) already ensure minigpu wins the
    // encoder selection.  Blocking this check on D3D11 availability caused the
    // log to (incorrectly) report "D3D11 zero-copy" even when the actual
    // encode path is the minigpu GPU buffer hot-path.
    final hasMinigpuGpuEncoder =
        _backendContext != null &&
        Platform.isWindows &&
        MiniAVToolsPlatform.instance.backends.any(
          (b) =>
              b.supportsEncode(effectiveCodecForGpuCheck) &&
              b.acceptedFrameSources.contains(FrameSourceKind.gpuTexture),
        );
    final useGpuOutput = hasD3d11Encoder || hasMinigpuGpuEncoder;
    // The GPU processor (bilinear scale + effects chain) imports the capture's
    // D3D11 texture handle. So the capture must produce GPU output whenever a
    // processor will run — INCLUDING the CPU-readback path (useGpuOutput=false
    // but a scale policy or effects are configured). This was previously gated
    // on useGpuOutput alone, so on that path the capture was set to CPU output;
    // window (WGC) capture then hands back plain CPU buffers with no D3D11
    // handle, the processor can't import them, and the entire scale/effects
    // chain (e.g. censor boxes + crop) is silently skipped. Display (DXGI)
    // capture happened to still carry a handle, which is why this only bit
    // window capture.
    final hasGpuWork =
        cfg.scale.targetSize(videoFormat.width, videoFormat.height) != null ||
        cfg.effects.isNotEmpty;
    final captureUsesGpu =
        _backendContext != null && (useGpuOutput || hasGpuWork);
    // For the log label: minigpu GPU buffer path takes precedence over D3D11
    // when both are available (encoder priority already ensures minigpu wins).
    final captureLabel = !captureUsesGpu
        ? 'CPU'
        : useGpuOutput
        ? (hasMinigpuGpuEncoder ? 'GPU (minigpu buffer)' : 'GPU (D3D11 zero-copy)')
        : 'GPU (processor → CPU readback)';
    Recorder._log(
      'screen capture output: $captureLabel '
      '— backendContext=${_backendContext != null}, '
      'd3d11Encoder=$hasD3d11Encoder, '
      'minigpuEncoder=$hasMinigpuGpuEncoder, '
      'gpuWork=$hasGpuWork, '
      'd3d11Device=0x${(_backendContext?.d3d11DeviceHandle ?? 0).toRadixString(16)}',
    );
    final outputPref = captureUsesGpu
        ? MiniAVOutputPreference.gpu
        : MiniAVOutputPreference.cpu;
    if (cfg.width != null &&
        cfg.height != null &&
        (cfg.width != videoFormat.width || cfg.height != videoFormat.height)) {
      videoFormat = MiniAVVideoInfo(
        width: cfg.width!,
        height: cfg.height!,
        pixelFormat: videoFormat.pixelFormat,
        frameRateNumerator: cfg.fps ?? videoFormat.frameRateNumerator,
        frameRateDenominator: videoFormat.frameRateDenominator,
        outputPreference: outputPref,
      );
    } else if (cfg.fps != null) {
      videoFormat = MiniAVVideoInfo(
        width: videoFormat.width,
        height: videoFormat.height,
        pixelFormat: videoFormat.pixelFormat,
        frameRateNumerator: cfg.fps!,
        frameRateDenominator: 1,
        outputPreference: outputPref,
      );
    } else {
      videoFormat = MiniAVVideoInfo(
        width: videoFormat.width,
        height: videoFormat.height,
        pixelFormat: videoFormat.pixelFormat,
        frameRateNumerator: videoFormat.frameRateNumerator,
        frameRateDenominator: videoFormat.frameRateDenominator,
        outputPreference: outputPref,
      );
    }

    final ctx = await MiniScreen.createContext();
    if (resolvedDisplayId != null) {
      await ctx.configureDisplay(resolvedDisplayId, videoFormat);
    } else {
      await ctx.configureWindow(cfg.windowId!, videoFormat);
    }

    // Resolve target (encoder) dimensions and GPU processor mode.
    //
    // There are three cases:
    //
    // (A) GPU zero-copy encode: _backendContext != null && useGpuOutput.
    //     GpuScreenProcessor handles scale + effects entirely on-GPU and
    //     returns a SharedOutputTexture for D3D11 hardware encoding.
    //     processorCpuReadback = false.
    //
    // (B) GPU downscale + CPU encode: _backendContext != null && !useGpuOutput
    //     but a scale policy or effects are active.  We still create a
    //     GpuScreenProcessor to run the expensive bilinear resize on the Intel
    //     iGPU (e.g. 4K→1080p), then read the smaller result back to CPU for
    //     NVENC or software encoding.  This avoids saturating the isolate with
    //     a 3840×2160 Dart bilinear rescale on every frame.
    //     processorCpuReadback = true.
    //
    // (C) No GPU context, or GPU context present but no scale/effects work to
    //     do: processor = null.  The encoder receives full-resolution CPU
    //     frames and uses its own internal rescale if dimensions mismatch.
    //     Warn at 4K without a scale policy so the user can set one.
    final (
      int encW,
      int encH,
      GpuScreenProcessor? processor,
      bool processorCpuReadback,
    ) = () {
      final target = cfg.scale.targetSize(
        videoFormat.width,
        videoFormat.height,
      );
      final (dstW, dstH) = target ?? (videoFormat.width, videoFormat.height);
      final bc = _backendContext;

      if (bc == null) {
        // Case C – no GPU context at all.
        if (cfg.effects.isNotEmpty) {
          Recorder._log(
            'WARNING: ${cfg.effects.length} effect(s) configured but no GPU '
            'context is available — effects will be skipped.',
            RecorderLogLevel.warning,
          );
        }
        final megaPixels = (videoFormat.width * videoFormat.height) / 1e6;
        if (megaPixels >= 4.0 && target == null) {
          Recorder._log(
            'WARNING: capturing ${videoFormat.width}x${videoFormat.height} '
            '(${megaPixels.toStringAsFixed(1)} MP) without GPU context and '
            'without a scale policy. CPU NV12 conversion at this size may '
            'stall the encode loop. Consider setting cfg.scale to e.g. 0.5×.',
            RecorderLogLevel.warning,
          );
        }
        return (dstW, dstH, null, false);
      }

      if (!useGpuOutput) {
        // Case B or C depending on whether there is GPU work to do.
        final hasWork = target != null || cfg.effects.isNotEmpty;
        if (hasWork) {
          // Case B: GPU downscale + CPU readback.
          Recorder._log(
            'screen downscale (GPU→CPU readback): '
            '${videoFormat.width}x${videoFormat.height} → ${dstW}x$dstH '
            '(${cfg.scale}) — GPU bilinear downscale, CPU encode',
          );
          if (cfg.effects.isNotEmpty) {
            Recorder._log(
              'screen effects: ${cfg.effects.length} effect(s) active '
              '(GPU→CPU readback path)',
            );
          }
          final p = GpuScreenProcessor(
            gpu: bc.sharedGpu! as Minigpu,
            srcWidth: videoFormat.width,
            srcHeight: videoFormat.height,
            dstWidth: dstW,
            dstHeight: dstH,
            effects: cfg.effects,
          );
          if (p.outputWidth != dstW || p.outputHeight != dstH) {
            Recorder._log(
              'effects resize: ${dstW}x$dstH → '
              '${p.outputWidth}x${p.outputHeight}',
            );
          }
          return (p.outputWidth, p.outputHeight, p, true);
        }
        // Case C: GPU context present but no scale/effects work.
        final megaPixels = (videoFormat.width * videoFormat.height) / 1e6;
        if (megaPixels >= 4.0) {
          Recorder._log(
            'WARNING: capturing ${videoFormat.width}x${videoFormat.height} '
            '(${megaPixels.toStringAsFixed(1)} MP) without GPU output and '
            'without a scale policy. CPU NV12 conversion at this size may '
            'stall the encode loop and produce very large files with '
            'erratic frame timing. Consider setting cfg.scale to e.g. 0.5×.',
            RecorderLogLevel.warning,
          );
        }
        return (dstW, dstH, null, false);
      }

      // Case A: full GPU zero-copy path.
      if (target != null) {
        Recorder._log(
          'screen downscale: '
          '${videoFormat.width}x${videoFormat.height} → ${dstW}x$dstH '
          '(${cfg.scale})',
        );
      }
      if (cfg.effects.isNotEmpty) {
        Recorder._log('screen effects: ${cfg.effects.length} effect(s) active');
      }
      final p = GpuScreenProcessor(
        gpu: bc.sharedGpu! as Minigpu,
        srcWidth: videoFormat.width,
        srcHeight: videoFormat.height,
        dstWidth: dstW,
        dstHeight: dstH,
        effects: cfg.effects,
        // Depth-2 output ring so the pipelined runtime can run the GPU stage
        // of frame N+1 while the encoder still reads frame N's texture.
        sharedRingDepth: 2,
      );
      if (p.outputWidth != dstW || p.outputHeight != dstH) {
        Recorder._log(
          'effects resize: ${dstW}x$dstH → '
          '${p.outputWidth}x${p.outputHeight}',
        );
      }
      return (p.outputWidth, p.outputHeight, p, false);
    }();

    var encResult = await _openVideoEncoder(
      MiniAVVideoInfo(
        width: encW,
        height: encH,
        pixelFormat: videoFormat.pixelFormat,
        frameRateNumerator: videoFormat.frameRateNumerator,
        frameRateDenominator: videoFormat.frameRateDenominator,
        outputPreference: videoFormat.outputPreference,
      ),
      cfg.codec,
      cfg.bitrateBps,
      cfg.hwAccel,
      quality: cfg.quality,
      encoderOptions: cfg.encoderOptions,
      // Don't pass the D3D11 BackendContext when the pre-check determined that
      // zero-copy is not available (useGpuOutput=false).  Without this,
      // FfmpegBackend.createEncoder sees context.preferZeroCopy=true and tries
      // FfmpegD3d11HwEncoder.open again — which succeeds on session 2+ (warm
      // HW context from session 1), returns a D3D11 encoder, and the safety
      // net below (processor != null && is! FfmpegD3d11HwEncoder) does NOT
      // fire because the encoder IS D3D11.  CPU-only frames then hit the
      // encoder and every frame fails with CodecRuntimeException[ffmpeg-d3d11].
      noContext: !useGpuOutput,
    );

    // Safety net: if a GPU zero-copy processor was created (GPU output configured)
    // but the encoder that was actually selected is NOT a D3D11-capable encoder,
    // the SharedOutputTexture frames it produces will crash the CPU-only encoder.
    // Reconfigure capture for CPU output and discard the processor.
    // NOTE: this does NOT apply to the CPU-readback path (processorCpuReadback=true)
    // because in that case the processor only produces CPU bytes, never D3D11 frames.
    // NOTE: the pre-check now uses ffmpegD3d11EncoderCompatibleWith (a real
    // device probe) so this branch should no longer fire in normal operation.
    var effectiveProcessor = processor;
    var effectiveCpuReadback = processorCpuReadback;
    // Detect which GPU mode the selected encoder supports:
    //  - FfmpegD3d11HwEncoder → D3D11 shared texture (Case A)
    //  - supportsGpuBufferInput → packed RGBA8 GPU buffer (Case C, minigpu)
    //  - neither → safety net fires, fall back to CPU
    final isD3d11Encoder = encResult.encoder.platform is FfmpegD3d11HwEncoder;
    final isGpuBufferEncoder =
        encResult.encoder.platform.supportsGpuBufferInput;
    final effectiveGpuBuffer =
        processor != null && !processorCpuReadback && isGpuBufferEncoder;
    // Zero-copy D3D11 sub-modes (see _VideoTrackRuntime):
    //  - no GPU work (no scale/effects)  → direct BGRA passthrough: the capture
    //    NT handle goes straight to the encoder; zero shader-core work/frame.
    //  - GPU work present                → pipelined two-stage encode: GPU
    //    stage of frame N+1 overlaps the encode of frame N (ring depth 2).
    // (`hasGpuWork` computed above with the capture-output decision.)
    final zeroCopyD3d11 =
        effectiveProcessor != null &&
        !effectiveCpuReadback &&
        !effectiveGpuBuffer &&
        isD3d11Encoder;
    // Log the actual per-frame encode path now that the encoder is known.
    if (processor != null && !processorCpuReadback) {
      final pathLabel = effectiveGpuBuffer
          ? 'GPU buffer → ${encResult.encoder.backendName} encodeFromGpuBuffer (zero CPU round-trip)'
          : zeroCopyD3d11
          ? (hasGpuWork
                ? 'D3D11 shared texture → ffmpeg D3D11 encoder '
                      '(zero-copy, pipelined GPU/encode stages)'
                : 'capture NT handle → ffmpeg D3D11 encoder '
                      '(direct BGRA passthrough, no GPU processing)')
          : 'GPU processor → CPU → encoder (unexpected; safety net may fire)';
      Recorder._log('screen encode path: $pathLabel');
    }
    if (processor != null &&
        !processorCpuReadback &&
        !isD3d11Encoder &&
        !isGpuBufferEncoder) {
      // The pre-check expected a GPU-capable encoder (D3D11 zero-copy or a
      // minigpu GPU-buffer encoder), so capture was configured for GPU output
      // and the processor for the zero-copy path. The encoder that actually
      // opened is a CPU-input encoder — e.g. the isolate-hosted software /
      // CPU-fed HW encoder, because zero-copy and the minigpu GPU encoder were
      // both unavailable on this adapter.
      //
      // Keep the GPU processor and switch it to the CPU-readback path — do NOT
      // drop it. The processor still imports the capture's D3D11 handle, runs
      // the bilinear downscale + the effects chain on the GPU, and reads the
      // result back to feed the CPU encoder. Nulling `effectiveProcessor` here
      // (the old behaviour) silently dropped the entire scale/effects pipeline.
      // Capture stays on GPU output (the processor needs the D3D11 handle), and
      // the already-selected encoder accepts CPU frames as-is, so there is no
      // need to reconfigure capture or reopen the encoder.
      Recorder._log(
        'screen: selected encoder is CPU-input (no D3D11 shared-texture / '
        'GPU-buffer support); keeping the GPU processor on the CPU-readback '
        'path so downscale + effects still apply.',
        RecorderLogLevel.warning,
      );
      effectiveCpuReadback = true;
    }

    return _VideoTrackRuntime(
      index: index,
      label: 'screen[${resolvedDisplayId ?? cfg.windowId}]',
      encoder: encResult.encoder,
      videoCodec: encResult.codec,
      width: encW,
      height: encH,
      frameRateNum: videoFormat.frameRateNumerator,
      frameRateDen: videoFormat.frameRateDenominator,
      captureCtx: ctx,
      processor: effectiveProcessor,
      processorCpuReadback: effectiveCpuReadback,
      processorGpuBuffer: effectiveGpuBuffer,
      idleFramePolicy: cfg.idleFramePolicy,
      adaptiveGpuThrottle: cfg.adaptiveGpuThrottle,
      cfrOutput: cfg.cfrOutput,
      directD3d11Passthrough: zeroCopyD3d11 && !hasGpuWork,
      pipelinedZeroCopy: zeroCopyD3d11 && hasGpuWork,
      startFn: (cb) => ctx.startCapture(cb),
      stopFn: () => ctx.stopCapture(),
      destroyFn: () => ctx.destroy(),
    );
  }

  Future<_TrackRuntime> _buildCameraTrack(
    int index,
    CameraRecorderSource cfg,
  ) async {
    var format = await MiniCamera.getDefaultFormat(cfg.deviceId);
    if (cfg.width != null && cfg.height != null) {
      // Pick the closest supported format if user requested specific dims.
      final supported = await MiniCamera.getSupportedFormats(cfg.deviceId);
      MiniAVVideoInfo? best;
      var bestScore = double.infinity;
      for (final f in supported) {
        final dw = (f.width - cfg.width!).abs();
        final dh = (f.height - cfg.height!).abs();
        final df = cfg.fps != null
            ? (f.frameRateNumerator / f.frameRateDenominator -
                      cfg.fps!.toDouble())
                  .abs()
            : 0.0;
        final score = dw + dh + df * 100;
        if (score < bestScore) {
          bestScore = score;
          best = f;
        }
      }
      if (best != null) format = best;
    } else if (cfg.fps != null) {
      format = MiniAVVideoInfo(
        width: format.width,
        height: format.height,
        pixelFormat: format.pixelFormat,
        frameRateNumerator: cfg.fps!,
        frameRateDenominator: 1,
        outputPreference: format.outputPreference,
      );
    }

    final ctx = await MiniCamera.createContext();
    await ctx.configure(cfg.deviceId, format);

    // Only pass the BackendContext (D3D11 zero-copy device) if the camera
    // was configured for GPU output.  The camera MF backend only delivers
    // gpuD3D11Handle buffers when outputPreference=gpu; for CPU output the
    // BackendContext must be suppressed or FfmpegD3d11HwEncoder will be
    // opened but receive CPU frames, throwing on every encode.
    final cameraUsesGpu = format.outputPreference == MiniAVOutputPreference.gpu;
    final encResult = await _openVideoEncoder(
      format,
      cfg.codec,
      cfg.bitrateBps,
      cfg.hwAccel,
      quality: cfg.quality,
      encoderOptions: cfg.encoderOptions,
      noContext: !cameraUsesGpu,
    );

    return _VideoTrackRuntime(
      index: index,
      label: 'camera[${cfg.deviceId}]',
      encoder: encResult.encoder,
      videoCodec: encResult.codec,
      width: format.width,
      height: format.height,
      frameRateNum: format.frameRateNumerator,
      frameRateDen: format.frameRateDenominator,
      captureCtx: ctx,
      idleFramePolicy: cfg.idleFramePolicy,
      startFn: (cb) => ctx.startCapture(cb),
      stopFn: () => ctx.stopCapture(),
      destroyFn: () => ctx.destroy(),
    );
  }

  Future<({Encoder encoder, VideoCodec codec})> _openVideoEncoder(
    MiniAVVideoInfo format,
    VideoCodec codec,
    int? bitrate,
    HwAccelPreference hwAccel, {
    double? quality,
    Map<String, String> encoderOptions = const {},
    // When true the BackendContext (D3D11 zero-copy device) is NOT passed to
    // the encoder.  Used when retrying with CPU frames after a D3D11 fallback.
    bool noContext = false,
  }) async {
    // HW H.264 encoders cap at 4096px on every shipping vendor (NVENC/QSV/
    // AMF/VT). Auto-promote to HEVC for ultrawide / 4K+ when HW is desired
    // — matches the screenshare_mp4 example's behaviour.
    final wantHw =
        hwAccel == HwAccelPreference.preferred ||
        hwAccel == HwAccelPreference.required;
    final effectiveCodec = FfmpegBackend.bestCodecForResolution(
      width: format.width,
      height: format.height,
      hwAccel: wantHw,
      preferred: codec,
    );
    if (effectiveCodec != codec) {
      Recorder._log(
        '${format.width}x${format.height} exceeds H.264 HW cap; '
        'promoting ${codec.name} → ${effectiveCodec.name}',
        RecorderLogLevel.warning,
      );
    }

    // Map the normalized 0.0–1.0 quality knob to codec-specific CRF/ICQ.
    // The mapping inverts the scale (1.0 = best = lowest CRF number).
    RateControl effectiveRc = RateControl.vbr;
    int? effectiveCrf;
    if (quality != null) {
      final q = quality.clamp(0.0, 1.0);
      effectiveRc = wantHw ? RateControl.icq : RateControl.crf;
      if (wantHw) {
        // NVENC/QSV ICQ: 1 (best) – 51 (worst). Map 1.0→1, 0.0→51.
        effectiveCrf = 1 + ((1.0 - q) * 50).round();
      } else {
        // libx264/libx265 CRF: 0 (lossless) – 51 (worst). Map 1.0→10, 0.0→48.
        effectiveCrf = 10 + ((1.0 - q) * 38).round();
      }
    }

    // Base backend options, overridden by caller-supplied encoderOptions.
    final baseOptions = wantHw
        ? const {'preset': 'p4', 'tune': 'll', 'global_header': '1'}
        : const {
            'preset': 'ultrafast',
            'tune': 'zerolatency',
            'global_header': '1',
          };
    final mergedOptions = {...baseOptions, ...encoderOptions};

    final enc = await MiniAVTools.createEncoder(
      EncoderConfig(
        codec: effectiveCodec,
        width: format.width,
        height: format.height,
        bitrateBps: bitrate ?? defaultVideoBitrate,
        frameRateNumerator: format.frameRateNumerator,
        frameRateDenominator: format.frameRateDenominator,
        // Force a keyframe every ~2 seconds so a clip-buffer save can
        // always find an IDR within its window. Without this NVENC's
        // default GOP can be 250+ frames, which means a saveClip(N seconds)
        // call may begin mid-GOP and produce an MP4 with no decodable
        // video frames at the start (audio plays, video is missing).
        gopLength:
            (2 * format.frameRateNumerator) ~/
            (format.frameRateDenominator > 0 ? format.frameRateDenominator : 1),
        hwAccel: hwAccel,
        rateControl: effectiveRc,
        crfQuality: effectiveCrf,
        backendOptions: mergedOptions,
      ),
      preference: backendPreference,
      context: noContext ? null : _backendContext,
    );
    final platform = enc.platform;
    String? vendorTag;
    try {
      // FfmpegD3d11HwEncoder exposes vendor + encoderName; surface them in
      // logs so users can tell which underlying vendor (nvenc / amf / qsv /
      // h264_mf) was actually selected. Done via dynamic to avoid a hard
      // dependency on the ffmpeg package from the recorder.
      final dyn = platform as dynamic;
      final vendor = dyn.vendor?.toString();
      final encoderName = dyn.encoderName?.toString();
      if (vendor != null && encoderName != null) {
        vendorTag = ' vendor=$encoderName';
      }
    } catch (_) {
      /* not a ffmpeg-d3d11 encoder */
    }
    Recorder._log(
      'video encoder = ${enc.backendName} '
      '(${platform.runtimeType})${vendorTag ?? ''} for ${effectiveCodec.name} '
      '${format.width}x${format.height}'
      '${quality != null ? ' quality=$quality (${effectiveRc.name} $effectiveCrf)' : ''}',
    );
    return (encoder: enc, codec: effectiveCodec);
  }

  Future<_AudioTrackRuntime> _buildAudioTrack(
    int index, {
    required String deviceId,
    required AudioCodec codec,
    required int? bitrate,
    required int? sampleRate,
    required int? channels,
    required Future<Object> Function() factory,
    required Future<void> Function(Object ctx, MiniAVAudioInfo fmt) configure,
    required Future<MiniAVAudioInfo> Function() getDefault,
    required Future<void> Function(
      Object ctx,
      void Function(MiniAVBuffer, Object?) cb,
    )
    start,
    required Future<void> Function(Object ctx) stop,
    required Future<void> Function(Object ctx) destroy,
    required String label,
  }) async {
    var format = await getDefault();
    if (sampleRate != null || channels != null) {
      format = MiniAVAudioInfo(
        format: format.format,
        sampleRate: sampleRate ?? format.sampleRate,
        channels: channels ?? format.channels,
        numFrames: format.numFrames,
      );
    }

    final ctx = await factory();
    await configure(ctx, format);

    final encoder = await MiniAVTools.createAudioEncoder(
      AudioEncoderConfig(
        codec: codec,
        sampleRate: format.sampleRate,
        channels: format.channels,
        bitrateBps: bitrate ?? defaultAudioBitrate,
        backendOptions: const {'global_header': '1'},
      ),
      preference: backendPreference,
      context: _backendContext,
    );
    Recorder._log(
      'audio encoder = ${encoder.backendName} '
      '(${encoder.platform.runtimeType}) for ${codec.name} '
      '${format.sampleRate}Hz/${format.channels}ch ($label)',
    );

    return _AudioTrackRuntime(
      index: index,
      label: label,
      encoder: encoder,
      audioCodec: codec,
      sampleRate: format.sampleRate,
      channels: format.channels,
      audioFormat: format.format,
      captureCtx: ctx,
      startFn: (cb) => start(ctx, cb),
      stopFn: () => stop(ctx),
      destroyFn: () => destroy(ctx),
    );
  }

  Future<_TrackRuntime> _buildMixedAudioTrack(
    int index,
    MixedAudioRecorderSource cfg,
  ) async {
    // Fixed common format. Most Windows endpoints already deliver this
    // natively (WASAPI default for shared mode is 48 kHz f32 stereo), so
    // for the typical case the per-callback conversion is a no-op.
    const targetSampleRate = 48000;
    const targetChannels = 2;
    final targetFormat = MiniAVAudioInfo(
      format: MiniAVAudioFormat.f32,
      sampleRate: targetSampleRate,
      channels: targetChannels,
      numFrames: 1024,
    );

    // 1. Mic context.
    final micFmt = await MiniAudioInput.getDefaultFormat(cfg.micDeviceId);
    final micCtx = await MiniAudioInput.createContext();
    await micCtx.configure(cfg.micDeviceId, targetFormat);

    // 2. Loopback context.
    final loopFmt = await MiniLoopback.getDefaultFormat(cfg.loopbackDeviceId);
    final loopCtx = await MiniLoopback.createContext();
    await loopCtx.configure(cfg.loopbackDeviceId, targetFormat);

    // 3. Single audio encoder.
    final encoder = await MiniAVTools.createAudioEncoder(
      AudioEncoderConfig(
        codec: cfg.codec,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        bitrateBps: cfg.bitrateBps ?? defaultAudioBitrate,
        backendOptions: const {'global_header': '1'},
      ),
      preference: backendPreference,
      context: _backendContext,
    );

    Recorder._log(
      'mixed audio: mic[${cfg.micDeviceId}] '
      '(native ${micFmt.sampleRate}Hz/${micFmt.channels}ch/${micFmt.format.name}) '
      '+ loopback[${cfg.loopbackDeviceId}] '
      '(native ${loopFmt.sampleRate}Hz/${loopFmt.channels}ch/${loopFmt.format.name}) '
      '→ ${targetSampleRate}Hz/${targetChannels}ch f32 → ${cfg.codec.name}',
    );

    AudioEffectChain? chain(List<AudioEffect> fx) => fx.isEmpty
        ? null
        : AudioEffectChain(
            fx,
            sampleRate: targetSampleRate,
            channels: targetChannels,
          );

    return _MixedAudioTrackRuntime(
      index: index,
      label: 'mixed[mic=${cfg.micDeviceId},loop=${cfg.loopbackDeviceId}]',
      encoder: encoder,
      audioCodec: cfg.codec,
      micCtx: micCtx,
      loopCtx: loopCtx,
      micGain: _dbToLinear(cfg.micGainDb),
      loopGain: _dbToLinear(cfg.loopbackGainDb),
      micChain: chain(cfg.micEffects),
      loopChain: chain(cfg.loopbackEffects),
      masterChain: chain(cfg.masterEffects),
    );
  }

  /// Infer a [Container] from a file-path extension.
  ///
  /// Returns `null` for unrecognised extensions so callers can fall back to
  /// [_autoContainer].
  static Container? _sniffContainer(String path) => containerForExtension(path);

  /// Infer the best container for [tracks] when the caller did not specify one
  /// and the file extension offers no hint.
  ///
  /// Rules:
  /// - video + audio → MKV (handles any codec mix)
  /// - video only    → MP4
  /// - audio only    → M4A for AAC, MP3 for MP3, OGG for Opus, else MKV
  static Container _autoContainer(List<_TrackRuntime> tracks) {
    final hasVideo = tracks.any((t) => t is _VideoTrackRuntime);
    final hasAudio = tracks.any((t) => t is _AudioTrackRuntime);
    final audioCodecs = tracks
        .whereType<_AudioTrackRuntime>()
        .map((t) => t.audioCodec)
        .toSet();
    return containerForTrackMix(
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      audioCodecs: audioCodecs,
    );
  }

  Future<_SinkRuntime> _buildSink(RecorderSink sink) async {
    switch (sink) {
      case FileRecorderSink():
        // Pick container: explicit override → extension sniff → track-mix heuristic.
        final container =
            sink.container ??
            _sniffContainer(sink.path) ??
            _autoContainer(_tracks);

        // Build TrackInfo list + encoder bridge map.
        final tracks = <TrackInfo>[];
        final encoderForTrack = <int, FfmpegEncoderBridge>{};
        for (final t in _tracks) {
          tracks.add(t.toTrackInfo());
          final bridge = t.encoderBridge;
          if (bridge != null) encoderForTrack[t.index] = bridge;
        }

        final muxer = FfmpegMuxer.open(
          MuxerConfig(
            container: container,
            output: FileMuxerOutput(sink.path),
            tracks: tracks,
          ),
          encoderForTrack: encoderForTrack,
        );
        await muxer.writeHeader();
        return _FileSinkRuntime(muxer: muxer, path: sink.path);

      case StreamRecorderSink():
        return _StreamSinkRuntime(onChunk: sink.onChunk);
    }
  }

  // -----------------------------------------------------------------------
  // Packet dispatch (called from track runtimes)
  // -----------------------------------------------------------------------

  // ignore: library_private_types_in_public_api
  Future<void> dispatchPacket(_TrackRuntime track, EncodedPacket packet) async {
    final routed = packet.copyWith(trackIndex: track.index);
    for (final s in _sinks) {
      switch (s) {
        case _FileSinkRuntime():
          // Enqueue for asynchronous muxing; this returns immediately unless
          // the queue is full (back-pressure), so the libav write no longer
          // runs inline on the encode path.
          await s.enqueuePacket(routed);
        case _StreamSinkRuntime():
          try {
            s.onChunk(track.toChunk(routed));
          } catch (e) {
            Recorder._log('stream callback: $e', RecorderLogLevel.error);
          }
      }
    }
  }

  /// Master-clock pts, in microseconds, at the moment this is called.
  int now() => _masterClock.elapsedMicroseconds;
}

// =========================================================================
// Track runtime (one per source).
// =========================================================================

abstract class _TrackRuntime {
  _TrackRuntime({required this.index, required this.label});
  final int index;
  final String label;

  /// Outstanding encode futures so [Recorder.stop] can wait before flush.
  final List<Future<void>> _inFlight = [];

  Future<void> startCapture(Recorder rec);
  Future<void> stopCapture();
  Future<void> drainInFlight() async {
    while (_inFlight.isNotEmpty) {
      final batch = List<Future<void>>.from(_inFlight);
      _inFlight.clear();
      await Future.wait(batch);
    }
  }

  Future<void> flushAndDispatch(Recorder rec);
  Future<void> dispose();

  TrackInfo toTrackInfo();
  FfmpegEncoderBridge? get encoderBridge;
  TrackChunk toChunk(EncodedPacket pkt);
}

/// A captured video frame waiting in [_VideoTrackRuntime]'s bounded encode
/// queue. [captureUs] is the wall-clock acceptance time, captured at enqueue so
/// the emitted PTS reflects when the frame was *captured* (evenly spaced by the
/// throttle) rather than when the serialized encoder happened to reach it —
/// otherwise a brief encode stall would bunch several frames at near-identical
/// timestamps.
class _PendingVideoFrame {
  _PendingVideoFrame(this.buffer, this.captureUs);
  final MiniAVBuffer buffer;
  final int captureUs;
}

class _VideoTrackRuntime extends _TrackRuntime {
  _VideoTrackRuntime({
    required super.index,
    required super.label,
    required this.encoder,
    required this.videoCodec,
    required this.width,
    required this.height,
    required this.frameRateNum,
    required this.frameRateDen,
    required this.captureCtx,
    required this.startFn,
    required this.stopFn,
    required this.destroyFn,
    this.processor,
    this.processorCpuReadback = false,
    this.processorGpuBuffer = false,
    this.idleFramePolicy = VideoIdleFramePolicy.duplicate,
    this.adaptiveGpuThrottle = true,
    this.directD3d11Passthrough = false,
    this.pipelinedZeroCopy = false,
    this.cfrOutput = false,
  });

  final Encoder encoder;
  final VideoCodec videoCodec;
  final int width;
  final int height;
  final int frameRateNum;
  final int frameRateDen;
  final Object captureCtx;
  final Future<void> Function(void Function(MiniAVBuffer, Object?)) startFn;
  final Future<void> Function() stopFn;
  final Future<void> Function() destroyFn;

  /// Optional GPU screen processor (downscale + effects chain). Non-null when:
  /// (a) the zero-copy GPU path is live — [processorCpuReadback] is false, and
  ///     [process] returns a [SharedOutputTexture] for D3D11 hardware encoding;
  /// (b) GPU context is available but hardware encoding is not —
  ///     [processorCpuReadback] is true, and [processToBytes] is used to run
  ///     GPU downscale and read the result back to CPU for software/CPU-HW encode.
  final GpuScreenProcessor? processor;

  /// When true, [processor] runs GPU downscale + effects and returns CPU bytes
  /// via [processToBytes] rather than a D3D11 shared texture. This lets the GPU
  /// handle the expensive bilinear resize (e.g. 4K→1080p) even when the
  /// hardware D3D11 encoder is unavailable.
  final bool processorCpuReadback;

  /// When true, [processor] stays on-GPU and the result is passed directly to
  /// the encoder as a GPU [Buffer] via [encodeFromGpuBuffer] (zero CPU
  /// round-trip).  Takes priority over [processorCpuReadback].
  final bool processorGpuBuffer;

  /// Controls how the encoder fills gaps when the capture source delivers
  /// fewer frames than the configured fps. See [VideoIdleFramePolicy].
  final VideoIdleFramePolicy idleFramePolicy;

  /// When true (default), sustained GPU-stage overrun (the GPU is saturated by
  /// another workload and our downscale/effects/copy passes queue behind it)
  /// steps the LIVE capture rate down by a power-of-two divisor instead of
  /// letting frames pile into the encode queue and drop unevenly (`busy_drop`
  /// stutter). Throttle drops are evenly spaced and the frame duplicator keeps
  /// the encoded output at the target fps, so playback degrades smoothly.
  /// Restores automatically when GPU pressure clears. See [AdaptiveGpuThrottle].
  final bool adaptiveGpuThrottle;

  /// Pressure detector fed by [_gpuStage]; drives the live-rate divisor.
  final AdaptiveGpuThrottle _gpuAdapt = AdaptiveGpuThrottle();

  /// When true, the zero-copy D3D11 path has NO GPU work to do (no scale, no
  /// effects) and encoder-sized frames are fed to the D3D11 encoder as their
  /// capture NT handle directly ([FrameSource.miniavBuffer]). The encoder
  /// opens the handle on its own device and copies via the COPY engine — zero
  /// shader-core work per frame, so a saturated GPU has nothing to starve.
  /// Frames whose size mismatches the encoder (mid-stream mode change) fall
  /// back to the GPU processor, which rescales.
  final bool directD3d11Passthrough;

  /// When true (zero-copy D3D11 path WITH GPU work), the per-frame GPU stage
  /// and the encode stage run as a two-stage pipeline: the GPU processing of
  /// frame N+1 overlaps the encode of frame N, each stage internally
  /// serialized. Requires the processor's shared-texture ring (depth ≥ 2) so
  /// the stage-1 write never touches the texture stage 2 is reading.
  final bool pipelinedZeroCopy;

  /// When true, output PTS are quantized to the exact fps grid and every grid
  /// slot is filled exactly once — live frames claim their nearest slot,
  /// missed slots are backfilled with duplicates of the previous frame, and
  /// surplus frames are dropped. See [FramePacer] for the full semantics.
  /// Default false = VFR (frames keep capture timestamps; near-target source
  /// cadence passes through untouched).
  final bool cfrOutput;

  /// Pacing policy: near-target VFR tolerance + CFR grid slotting.
  late final FramePacer _pacer = FramePacer(
    frameRateNum: frameRateNum,
    frameRateDen: frameRateDen,
    cfr: cfrOutput,
  );

  /// Last live frame retained for the duplicator on the direct-passthrough
  /// path (swap-released when the next live frame lands; released on stop).
  MiniAVBuffer? _lastDirectBuffer;

  /// Pipelined mode: stage-1 (GPU) in-flight flag, and the handoff slot from
  /// stage 1 to stage 2 (at most one frame waits here; stage 1 stalls while
  /// it is occupied so the texture ring never wraps onto a texture the
  /// encoder is still reading).
  bool _gpuBusy = false;
  ({SharedOutputTexture tex, int captureUs})? _readyFrame;

  // Bounded encode queue (replaces the former depth-1 `_busy` single-flight
  // gate). A brief encode overrun no longer drops the next frame: frame N+1
  // waits here while frame N is in flight. The encode stage itself stays
  // strictly serialized — the encoder/muxer FFI is single-threaded, so exactly
  // one [_encodeOne] runs at a time, guarded by [_encoding]. On a SUSTAINED
  // overrun (queue full) the OLDEST pending frame is dropped (counted as
  // [_statsBusyDropped]) so we always favour the freshest frames.
  static const int _maxQueueDepth = 3;
  final List<_PendingVideoFrame> _frameQueue = [];
  bool _encoding = false;
  bool _stopping = false;
  bool _firstChunkSent = false;
  int _lastVideoPtsUs = -1;

  // -------- Frame duplicator (zero-copy GPU path only) ------------------
  //
  // DXGI / WGC / WASAPI's screen-capture callbacks deliver a frame only when
  // the source surface changes.  On a mostly-static screen (e.g. user is
  // reading text) the capture cadence collapses to a few fps, which we then
  // honour 1:1 — the encoded stream genuinely contains that few-fps cadence
  // and the muxer writes correspondingly long frame durations.  On playback
  // that segment shows up as a freeze-then-jump and is universally reported
  // as "laggy video".
  //
  // The duplicator fixes this by re-encoding the last shared-output texture
  // at the target frame interval when the capture pipeline goes idle.  Cost
  // is negligible: the GPU pre-process step is skipped (the texture already
  // holds the last computed pixels), and NVENC / FFmpeg encoders produce
  // tiny P/skip frames (often <100 bytes) for a static input.
  //
  // Only active for the zero-copy GPU path because that's the only path
  // where we own a long-lived, reusable GPU texture by the time the encode
  // returns.  CPU-readback and fallback paths drop their source buffer
  // immediately so there is nothing to duplicate from.
  Timer? _dupTimer;
  SharedOutputTexture? _lastSharedTex;
  Recorder? _recForDup;

  // Encode-error rate limiting: log the first error immediately, then at
  // most once every [_errorLogIntervalMs] ms, to avoid 30-per-second spam
  // drowning out other useful diagnostics.
  static const int _errorLogIntervalMs = 5000;
  int _lastErrorLogMs = 0;
  Object? _lastEncodeError;

  /// Minimum microseconds between encoded frames to enforce the configured fps.
  /// 0 means no throttle (device-controlled).
  int get _minFrameIntervalUs => frameRateDen > 0 && frameRateNum > 0
      ? (1000000 * frameRateDen) ~/ frameRateNum
      : 0;

  // Frame-rate diagnostics. Every ~2 seconds we log how many frames came in
  // from the capture callback, how many we dropped due to back-pressure, and
  // how many actually produced an encoded packet. This is invaluable when a
  // saved clip ends up with far fewer video frames than expected.
  int _statsFramesIn = 0;
  // Drop counters are split by cause. Throttle drops are BY DESIGN (capture
  // delivers faster than the target fps and we intentionally pace down) and are
  // benign. Busy drops mean the bounded encode queue overflowed — i.e. real
  // back-pressure, the symptom this pipeline work targets. A config that is
  // genuinely _busy-bound shows a non-zero busy-drop count; throttle drops
  // alone are expected. Logged separately by [_maybeLogStats].
  int _statsThrottleDropped = 0;
  int _statsBusyDropped = 0;
  // Duplicate frames emitted (idle fill + CFR backfill). Counted inside
  // _statsPacketsOut as well; shown separately as dup= when non-zero.
  int _statsDupFrames = 0;
  int _statsPacketsOut = 0;
  int _statsEncodeErrors = 0;
  int _statsMinPktBytes = 0x7fffffff;
  int _statsMaxPktBytes = 0;
  int _statsTotalPktBytes = 0;
  // Per-stage wall-clock timing (µs). The GPU stage is the processor call
  // (downscale/effects/YUV/shared-texture copy) — under GPU saturation by
  // another workload its duration balloons because our submissions queue
  // behind that workload, which is exactly the pressure signal the adaptive
  // throttle keys off. The encode stage is the encoder.encode() call.
  int _statsGpuUsSum = 0;
  int _statsGpuUsMax = 0;
  int _statsGpuSamples = 0;
  int _statsEncUsSum = 0;
  int _statsEncUsMax = 0;
  int _statsEncSamples = 0;
  Stopwatch? _statsSw;

  /// Times the GPU-processor stage of one frame, records it in the stats
  /// counters, and feeds the adaptive throttle (logging divisor transitions).
  Future<T> _gpuStage<T>(Future<T> Function() stage) async {
    final sw = Stopwatch()..start();
    try {
      return await stage();
    } finally {
      sw.stop();
      final us = sw.elapsedMicroseconds;
      _statsGpuUsSum += us;
      _statsGpuSamples++;
      if (us > _statsGpuUsMax) _statsGpuUsMax = us;
      if (adaptiveGpuThrottle) {
        final prev = _gpuAdapt.divisor;
        final d = _gpuAdapt.addSample(us, _minFrameIntervalUs);
        if (d != prev) {
          Recorder._log(
            d > prev
                ? '$label GPU stage avg '
                      '${(_gpuAdapt.emaUs / 1000).toStringAsFixed(1)}ms exceeds '
                      'the frame budget (GPU saturated) — live capture reduced '
                      'to 1/$d of target fps; the frame duplicator keeps the '
                      'output cadence.'
                : '$label GPU pressure cleared — live capture restored to '
                      '1/$d of target fps.',
            RecorderLogLevel.warning,
          );
        }
      }
    }
  }

  /// Times the encoder stage of one frame and records it in the stats counters.
  Future<T> _encStage<T>(Future<T> Function() stage) async {
    final sw = Stopwatch()..start();
    try {
      return await stage();
    } finally {
      sw.stop();
      final us = sw.elapsedMicroseconds;
      _statsEncUsSum += us;
      _statsEncSamples++;
      if (us > _statsEncUsMax) _statsEncUsMax = us;
    }
  }

  @override
  Future<void> startCapture(Recorder rec) async {
    _statsSw = Stopwatch()..start();
    _startDupTimer(rec);
    await startFn((MiniAVBuffer buffer, Object? _) {
      if (_stopping) {
        // Drop and release.
        MiniAV.releaseBufferSync(buffer);
        return;
      }
      _statsFramesIn++;
      _maybeLogStats();
      // Wall-clock acceptance time. Used both for the pacer and, when the
      // frame is accepted, as its capture timestamp (see [_PendingVideoFrame]).
      final nowUs = rec.now();
      // Frame pacing (see [FramePacer]): in VFR mode the fps throttle engages
      // only when the source meaningfully outruns the target rate — a source
      // within ~15% of target (e.g. DXGI delivering ~31.4 fps against 30)
      // passes through untouched, because deleting frames from a near-target
      // cadence turns one frame per ~20 into a double-length presentation
      // hole: a metronomic visible stutter. In CFR mode this drops frames
      // whose output grid slot is already spoken for. Under sustained GPU
      // saturation the adaptive divisor (2, 4) thins live frames evenly
      // either way, and the duplicator/backfill keeps the output cadence.
      // Audio sync is unaffected: both tracks use master-clock µs timestamps.
      final divisor = adaptiveGpuThrottle ? _gpuAdapt.divisor : 1;
      final wasThrottling = _pacer.throttleActive;
      final drop = _pacer.shouldDropOnArrival(nowUs, divisor: divisor);
      if (_pacer.throttleActive != wasThrottling) {
        Recorder._log(
          _pacer.throttleActive
              ? '$label fps throttle engaged — source cadence '
                    '${_pacer.arrivalEmaMs.toStringAsFixed(1)}ms outruns the '
                    '${(_minFrameIntervalUs / 1000).toStringAsFixed(1)}ms '
                    'target; thinning evenly to the target rate.'
              : '$label fps throttle released — source cadence '
                    '${_pacer.arrivalEmaMs.toStringAsFixed(1)}ms ≈ target; '
                    'passing all frames through (VFR).',
          RecorderLogLevel.info,
        );
      }
      if (drop) {
        _statsThrottleDropped++; // surplus vs target rate (or slot taken)
        MiniAV.releaseBufferSync(buffer);
        return;
      }
      // Bounded-queue back-pressure (replaces the depth-1 `_busy` gate). Enqueue
      // and let the serialized pump drain it. Only a SUSTAINED overrun (queue
      // already full) drops a frame, and then the OLDEST so the freshest frames
      // survive.
      _frameQueue.add(_PendingVideoFrame(buffer, nowUs));
      if (_frameQueue.length > _maxQueueDepth) {
        final dropped = _frameQueue.removeAt(0);
        _statsBusyDropped++; // real back-pressure — encode can't keep up
        MiniAV.releaseBufferSync(dropped.buffer);
      }
      _pumpQueue(rec);
    });
  }

  /// Starts encoding the next queued frame iff the (strictly serialized) encode
  /// stage is idle. Re-invoked from each encode's completion so the queue
  /// drains in order without ever running two encodes concurrently.
  ///
  /// In [pipelinedZeroCopy] mode this instead drives the two-stage pipeline:
  /// [_pumpGpu] (stage 1) runs the GPU processor for frame N+1 while
  /// [_pumpEnc] (stage 2) encodes frame N — each stage internally serialized,
  /// handing off through the single [_readyFrame] slot.
  void _pumpQueue(Recorder rec) {
    if (pipelinedZeroCopy) {
      _pumpGpu(rec);
      _pumpEnc(rec);
      return;
    }
    if (_encoding || _stopping) return;
    if (_frameQueue.isEmpty) return;
    _encoding = true;
    final pending = _frameQueue.removeAt(0);
    final fut = _encodeOne(rec, pending.buffer, pending.captureUs);
    _inFlight.add(fut);
    fut.whenComplete(() {
      _inFlight.remove(fut);
      _encoding = false;
      _pumpQueue(rec);
    });
  }

  // ---- Pipelined zero-copy pumps (stage 1: GPU, stage 2: encode) --------
  //
  // Under GPU saturation the GPU stage balloons (our passes queue behind the
  // other workload); pipelining hides it behind the encode stage instead of
  // serializing the two. Stage 1 only starts when the handoff slot is empty,
  // so with the processor's shared-texture ring (depth 2) the texture being
  // written is never the one the encoder is reading:
  //   slot A: encoding (stage 2)   slot B: being written (stage 1)

  void _pumpGpu(Recorder rec) {
    if (_gpuBusy || _stopping) return;
    if (_readyFrame != null) return; // handoff occupied — stall stage 1
    if (_frameQueue.isEmpty) return;
    _gpuBusy = true;
    final pending = _frameQueue.removeAt(0);
    final fut = _gpuOne(rec, pending);
    _inFlight.add(fut);
    fut.whenComplete(() {
      _inFlight.remove(fut);
      _gpuBusy = false;
      _pumpEnc(rec);
      _pumpGpu(rec);
    });
  }

  Future<void> _gpuOne(Recorder rec, _PendingVideoFrame pending) async {
    final buffer = pending.buffer;
    try {
      final proc = processor;
      if (proc == null ||
          buffer.contentType != MiniAVBufferContentType.gpuD3D11Handle) {
        // Should not happen on the pipelined (GPU-output) path — e.g. a rare
        // per-frame CPU fallback from the capture layer. Surface it via the
        // rate-limited error counter rather than feeding a mismatched frame
        // to the D3D11 encoder.
        _statsEncodeErrors++;
        _lastEncodeError = 'non-D3D11 buffer on pipelined zero-copy path';
        return;
      }
      final tex = await _gpuStage(() => proc.process(buffer));
      if (tex == null) return; // processor logged the reason; drop frame
      assert(_readyFrame == null, 'handoff slot must be empty (pump gate)');
      _readyFrame = (tex: tex, captureUs: pending.captureUs);
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log(
          '$label GPU stage error: $e\n$st',
          RecorderLogLevel.error,
        );
      }
    } finally {
      // The pixels now live in the processor's shared texture (or the frame
      // was dropped) — the capture buffer is no longer needed either way.
      MiniAV.releaseBufferSync(buffer);
    }
  }

  void _pumpEnc(Recorder rec) {
    if (_encoding || _stopping) return;
    final ready = _readyFrame;
    if (ready == null) return;
    _readyFrame = null;
    _encoding = true;
    final fut = _encOne(rec, ready);
    _inFlight.add(fut);
    fut.whenComplete(() {
      _inFlight.remove(fut);
      _encoding = false;
      _pumpGpu(rec); // the freed handoff slot may unblock stage 1
      _pumpEnc(rec);
    });
  }

  Future<void> _encOne(
    Recorder rec,
    ({SharedOutputTexture tex, int captureUs}) ready,
  ) async {
    try {
      final claim = _pacer.claimPts(ready.captureUs);
      if (claim == null) {
        // CFR: the frame's grid slot was filled while it waited in the
        // pipeline (idle filler race) — drop it.
        _statsThrottleDropped++;
        return;
      }
      // CFR: fill grid slots the capture missed with duplicates of the
      // PREVIOUS frame — must run before _lastSharedTex is updated below.
      await _emitBackfill(rec, claim.backfillPtsUs);
      var ptsUs = claim.ptsUs;
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;
      final proc = processor!;
      _lastSharedTex = ready.tex; // duplicator source (see _maybeDuplicateLast)
      final src = D3D11TextureFrameSource(
        texturePtr: ready.tex.d3d11TexturePtr,
        width: proc.outputWidth,
        height: proc.outputHeight,
        pixelFormat: MiniAVPixelFormat.rgba32,
      );
      final pkt = await _encStage(() => encoder.encode(src));
      if (pkt != null) {
        _statsPacketsOut++;
        _statsTotalPktBytes += pkt.data.length;
        if (pkt.data.length < _statsMinPktBytes)
          _statsMinPktBytes = pkt.data.length;
        if (pkt.data.length > _statsMaxPktBytes)
          _statsMaxPktBytes = pkt.data.length;
        await rec.dispatchPacket(
          this,
          pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
        );
      }
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log(
          '$label encode stage error: $e\n$st',
          RecorderLogLevel.error,
        );
      }
    }
  }

  void _maybeLogStats() {
    final sw = _statsSw;
    if (sw == null) return;
    if (sw.elapsedMilliseconds < 2000) return;
    final secs = sw.elapsedMilliseconds / 1000.0;
    final avgPkt = _statsPacketsOut > 0
        ? (_statsTotalPktBytes / _statsPacketsOut).round()
        : 0;
    final pktRange = _statsPacketsOut > 0
        ? '${_statsMinPktBytes}..${_statsMaxPktBytes}B avg=${avgPkt}B'
        : 'none';
    final errStr = _statsEncodeErrors > 0
        ? ' ERRORS=${_statsEncodeErrors} (last: $_lastEncodeError)'
        : '';
    // Per-stage timing: avg/max ms for the GPU-processor stage and the encoder
    // stage. A gpu= figure well above the frame interval while encoded fps sags
    // means the GPU is saturated (the adaptive throttle logs when it engages —
    // shown here as adapt=÷N while a reduced live rate is active).
    final gpuStr = _statsGpuSamples > 0
        ? ' gpu=${(_statsGpuUsSum / _statsGpuSamples / 1000).toStringAsFixed(1)}'
              '/${(_statsGpuUsMax / 1000).toStringAsFixed(1)}ms'
        : '';
    final encStr = _statsEncSamples > 0
        ? ' enc=${(_statsEncUsSum / _statsEncSamples / 1000).toStringAsFixed(1)}'
              '/${(_statsEncUsMax / 1000).toStringAsFixed(1)}ms'
        : '';
    final adaptStr = _gpuAdapt.divisor > 1 ? ' adapt=÷${_gpuAdapt.divisor}' : '';
    final dupStr = _statsDupFrames > 0 ? ' dup=${_statsDupFrames}' : '';
    Recorder._log(
      '$label video stats over ${secs.toStringAsFixed(1)}s: '
      'in=${_statsFramesIn} (${(_statsFramesIn / secs).toStringAsFixed(1)} fps) '
      'thr_drop=${_statsThrottleDropped} busy_drop=${_statsBusyDropped} '
      'encoded=${_statsPacketsOut} '
      '(${(_statsPacketsOut / secs).toStringAsFixed(1)} fps) '
      'pkt=$pktRange$gpuStr$encStr$adaptStr$dupStr$errStr',
    );
    _statsFramesIn = 0;
    _statsThrottleDropped = 0;
    _statsBusyDropped = 0;
    _statsDupFrames = 0;
    _statsPacketsOut = 0;
    _statsEncodeErrors = 0;
    _statsMinPktBytes = 0x7fffffff;
    _statsMaxPktBytes = 0;
    _statsTotalPktBytes = 0;
    _statsGpuUsSum = 0;
    _statsGpuUsMax = 0;
    _statsGpuSamples = 0;
    _statsEncUsSum = 0;
    _statsEncUsMax = 0;
    _statsEncSamples = 0;
    sw.reset();
  }

  Future<void> _encodeOne(
    Recorder rec,
    MiniAVBuffer buffer, [
    int? captureUs,
  ]) async {
    // Set by the direct-passthrough branch: the buffer is retained as the
    // duplicator's source instead of being released in the finally below.
    var retainBuffer = false;
    try {
      // PTS from the pacer: the capture-time timestamp recorded at enqueue in
      // VFR mode (falling back to now() if the frame was encoded outside the
      // queue), the claimed grid-slot time in CFR mode. This keeps PTS spacing
      // stable even when the serialized encoder briefly stalls and then
      // drains several queued frames back-to-back.
      final claim = _pacer.claimPts(captureUs ?? rec.now());
      if (claim == null) {
        // CFR: the frame's grid slot was filled while it waited in the
        // pipeline (idle filler race) — drop it (finally releases the buffer).
        _statsThrottleDropped++;
        return;
      }
      // CFR: fill grid slots the capture missed with duplicates of the
      // PREVIOUS frame — must run before the branches below update the
      // retained duplicator sources (_lastDirectBuffer / _lastSharedTex).
      await _emitBackfill(rec, claim.backfillPtsUs);
      var ptsUs = claim.ptsUs;
      // Guarantee strict monotonic increase even on sub-µs frame deltas.
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;

      // --- GPU-backed paths ---------------------------------------------
      // All cases require a GpuScreenProcessor and a D3D11-handle buffer.
      final proc = processor;
      if (proc != null &&
          buffer.contentType == MiniAVBufferContentType.gpuD3D11Handle) {
        if (processorGpuBuffer) {
          // (C) GPU buffer hot path: processor returns a packed RGBA8 GPU
          // Buffer that the minigpu encoder (e.g. MinigpuAv1Pipeline) consumes
          // directly without any CPU round-trip.
          final gpuBuf = await _gpuStage(() => proc.processToGpuBuffer(buffer));
          if (gpuBuf != null) {
            // encoder.platform is GpuCodecEncoder (from miniav_tools_codecs)
            // which we cannot import here (would create a circular dep).
            // Use dynamic dispatch — safe because processorGpuBuffer is only
            // ever set to true when encoder.platform.supportsGpuBufferInput=true.
            final pkt = await _encStage(
              // ignore: avoid_dynamic_calls
              () async =>
                  await (encoder.platform as dynamic).encodeFromGpuBuffer(
                        gpuBuf,
                        proc.outputWidth,
                        proc.outputHeight,
                        timestampUs: ptsUs,
                      )
                      as EncodedPacket?,
            );
            if (pkt != null) {
              _statsPacketsOut++;
              _statsTotalPktBytes += pkt.data.length;
              if (pkt.data.length < _statsMinPktBytes)
                _statsMinPktBytes = pkt.data.length;
              if (pkt.data.length > _statsMaxPktBytes)
                _statsMaxPktBytes = pkt.data.length;
              await rec.dispatchPacket(
                this,
                pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
              );
            }
            return;
          }
          // processToGpuBuffer returned null — fall through to CPU path.
          final vb = buffer.data is MiniAVVideoBuffer
              ? buffer.data as MiniAVVideoBuffer
              : null;
          Recorder._log(
            '$label GPU processToGpuBuffer() returned null — dropping frame '
            '(${vb?.width}x${vb?.height} cannot be '
            'fed to ${width}x$height encoder).',
            RecorderLogLevel.warning,
          );
          return;
        } else if (!processorCpuReadback) {
          // (A0) Direct BGRA passthrough: no scale/effects configured and the
          // frame is already encoder-sized — hand the capture's shared NT
          // handle straight to the D3D11 encoder, which opens it on its own
          // device and copies it with the COPY engine. Zero shader-core work
          // per frame, so a GPU saturated by another workload has nothing of
          // ours to starve. Size-mismatched frames (mid-stream display mode
          // change) fall through to the GPU processor below, which rescales.
          if (directD3d11Passthrough) {
            final vb = buffer.data;
            if (vb is MiniAVVideoBuffer &&
                vb.width == width &&
                vb.height == height) {
              final src = FrameSource.miniavBuffer(buffer);
              final pkt = await _encStage(() => encoder.encode(src));
              // Retain this frame as the duplicator's source and release the
              // previously retained one. The NT handle + capture-side texture
              // stay valid until the buffer is released.
              final prev = _lastDirectBuffer;
              _lastDirectBuffer = buffer;
              retainBuffer = true;
              _lastSharedTex = null; // direct frame supersedes any old texture
              if (prev != null) MiniAV.releaseBufferSync(prev);
              if (pkt != null) {
                _statsPacketsOut++;
                _statsTotalPktBytes += pkt.data.length;
                if (pkt.data.length < _statsMinPktBytes)
                  _statsMinPktBytes = pkt.data.length;
                if (pkt.data.length > _statsMaxPktBytes)
                  _statsMaxPktBytes = pkt.data.length;
                await rec.dispatchPacket(
                  this,
                  pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
                );
              }
              return;
            }
          }
          // (A) Zero-copy GPU encode: processor returns a SharedOutputTexture
          // that the D3D11 hardware encoder reads directly — no PCIe round-trip.
          final sharedTex = await _gpuStage(() => proc.process(buffer));
          if (sharedTex != null) {
            // Remember for the frame duplicator: when capture goes idle on a
            // static screen, the duplicator re-encodes this same texture at
            // the target frame rate so playback stays smooth.  The processor
            // owns the texture; we just hold a reference and check isValid
            // before using it from the timer.
            _lastSharedTex = sharedTex;
            // A processor-produced texture supersedes any frame retained by
            // the direct-passthrough path (e.g. after a mode-change fallback).
            final staleDirect = _lastDirectBuffer;
            if (staleDirect != null) {
              _lastDirectBuffer = null;
              MiniAV.releaseBufferSync(staleDirect);
            }
            final src = D3D11TextureFrameSource(
              texturePtr: sharedTex.d3d11TexturePtr,
              width: proc.outputWidth,
              height: proc.outputHeight,
              pixelFormat: MiniAVPixelFormat.rgba32,
            );
            final pkt = await _encStage(() => encoder.encode(src));
            if (pkt != null) {
              _statsPacketsOut++;
              _statsTotalPktBytes += pkt.data.length;
              if (pkt.data.length < _statsMinPktBytes)
                _statsMinPktBytes = pkt.data.length;
              if (pkt.data.length > _statsMaxPktBytes)
                _statsMaxPktBytes = pkt.data.length;
              await rec.dispatchPacket(
                this,
                pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
              );
            }
            return;
          }
          // GPU processor returned null (resource init failed, handle invalid,
          // or importVideoFrame threw — e.g. after a game full-screen resolution
          // change while DXGI re-acquires).  The encoder is sized for the
          // processor's output, so the raw D3D11 buffer cannot be fed directly.
          // Drop this frame.
          final vb = buffer.data is MiniAVVideoBuffer
              ? buffer.data as MiniAVVideoBuffer
              : null;
          Recorder._log(
            '$label GPU process() returned null — dropping frame '
            '(${vb?.width}x${vb?.height} cannot be '
            'fed to ${width}x$height encoder).',
            RecorderLogLevel.warning,
          );
          return;
        } else {
          // (B) GPU downscale + CPU readback: processor runs the expensive
          // bilinear resize on the GPU (e.g. 4K→1080p on the Intel iGPU),
          // then reads the smaller result back to CPU for NVENC or software
          // encoding. Avoids saturating the isolate with a full-resolution
          // Dart bilinear rescale on every frame.
          //
          // (B1) When the encoder consumes YUV420P natively (software path),
          // convert RGBA→YUV420P on the GPU and read back the ~2.7× smaller
          // planes — no RGBA read-back, no per-pixel CPU conversion.
          if (encoder.platform.acceptsYuv420pPlanes) {
            final yuv = await _gpuStage(() => proc.processToYuv420(buffer));
            if (yuv != null) {
              final src = FrameSource.yuv420p(
                yPlane: yuv.y,
                uPlane: yuv.u,
                vPlane: yuv.v,
                width: yuv.width,
                height: yuv.height,
              );
              final pkt = await _encStage(() => encoder.encode(src));
              if (pkt != null) {
                _statsPacketsOut++;
                _statsTotalPktBytes += pkt.data.length;
                if (pkt.data.length < _statsMinPktBytes)
                  _statsMinPktBytes = pkt.data.length;
                if (pkt.data.length > _statsMaxPktBytes)
                  _statsMaxPktBytes = pkt.data.length;
                await rec.dispatchPacket(
                  this,
                  pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
                );
              }
              return;
            }
            // GPU YUV conversion failed — fall through to the RGBA read-back.
          }
          // (B2) RGBA read-back (CPU-fed HW encoders that want NV12/RGBA, or
          // the YUV fast-path fell through).
          final pixels = await _gpuStage(() => proc.processToBytes(buffer));
          if (pixels != null) {
            final src = FrameSource.cpu(
              bytes: pixels,
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: proc.outputWidth,
              height: proc.outputHeight,
            );
            final pkt = await _encStage(() => encoder.encode(src));
            if (pkt != null) {
              _statsPacketsOut++;
              _statsTotalPktBytes += pkt.data.length;
              if (pkt.data.length < _statsMinPktBytes)
                _statsMinPktBytes = pkt.data.length;
              if (pkt.data.length > _statsMaxPktBytes)
                _statsMaxPktBytes = pkt.data.length;
              await rec.dispatchPacket(
                this,
                pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
              );
            }
            return;
          }
          // processToBytes returned null — GPU import/dispatch failed (e.g.
          // device lost or handle revoked after a display mode change). Fall
          // through to the normal CPU path, which will receive the raw D3D11
          // handle — it will fail too, but the error will be rate-limited and
          // logged, and we avoid a silent frame drop here.
        }
      }

      // --- Normal / fallback path ----------------------------------------
      // Handles CPU buffers, D3D11 buffers when no GPU processor is
      // configured (processor == null), and the processToBytes() failure
      // fall-through above.
      final src = FrameSource.miniavBuffer(buffer);
      final pkt = await _encStage(() => encoder.encode(src));
      if (pkt != null) {
        _statsPacketsOut++;
        _statsTotalPktBytes += pkt.data.length;
        if (pkt.data.length < _statsMinPktBytes)
          _statsMinPktBytes = pkt.data.length;
        if (pkt.data.length > _statsMaxPktBytes)
          _statsMaxPktBytes = pkt.data.length;
        await rec.dispatchPacket(
          this,
          pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
        );
      }
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      // Rate-limit: log on first occurrence and at most every 5 seconds after.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log('$label encode error: $e\n$st', RecorderLogLevel.error);
      }
    } finally {
      if (!retainBuffer) MiniAV.releaseBufferSync(buffer);
    }
  }

  @override
  Future<void> stopCapture() async {
    _stopping = true;
    _dupTimer?.cancel();
    _dupTimer = null;
    _lastSharedTex = null;
    _readyFrame = null; // pipelined handoff slot (texture is processor-owned)
    // NOTE: _lastDirectBuffer is NOT released here — a duplicate encode may
    // still be in flight using it (Recorder._shutdown drains in-flight work
    // only AFTER stopCapture). It is released in [dispose].
    await stopFn();
    // The pump stops accepting work once _stopping is set, so any frames still
    // waiting in the queue would otherwise leak their native buffers. Release
    // them now (stopFn() has halted the source, so no new frames will enqueue).
    for (final pending in _frameQueue) {
      MiniAV.releaseBufferSync(pending.buffer);
    }
    _frameQueue.clear();
  }

  @override
  Future<void> flushAndDispatch(Recorder rec) async {
    final pkts = await encoder.flush();
    for (final p in pkts) {
      var ptsUs = rec.now();
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;
      await rec.dispatchPacket(this, p.copyWith(ptsUs: ptsUs, dtsUs: ptsUs));
    }
  }

  // ---- Frame duplicator implementation --------------------------------

  /// CFR backfill: emit a duplicate of the previous frame at each missed grid
  /// slot PTS (oldest first) so the output timeline has no presentation
  /// holes. Uses whichever duplicator source the active path retains; on
  /// paths that retain nothing (CPU readback / GPU-buffer encode) the slots
  /// are left unfilled — same scope as the idle duplicator, which is
  /// zero-copy-path only. Runs inside the already-serialized encode stage.
  Future<void> _emitBackfill(Recorder rec, List<int> ptsList) async {
    for (final pts in ptsList) {
      final directBuf = _lastDirectBuffer;
      if (directBuf != null) {
        await _encodeDuplicateDirect(rec, directBuf, pts);
        continue;
      }
      final tex = _lastSharedTex;
      if (tex != null && tex.isValid) {
        await _encodeDuplicate(rec, tex, pts);
        continue;
      }
      break; // nothing retained yet (first frames) — leave the hole
    }
  }

  void _startDupTimer(Recorder rec) {
    if (idleFramePolicy == VideoIdleFramePolicy.none) return;
    _recForDup = rec;
    final intervalUs = _minFrameIntervalUs;
    if (intervalUs <= 0) return;
    // Timer.periodic granularity is milliseconds.  Fire at ~the target
    // rate; the actual emit decision is gated on _lastVideoPtsUs so a
    // slightly faster timer just produces more no-op ticks.
    final intervalMs = math.max(1, intervalUs ~/ 1000);
    _dupTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _maybeDuplicateLast(),
    );
  }

  void _maybeDuplicateLast() {
    // Only duplicate when the live pipeline is genuinely idle: nothing is
    // encoding (either stage, in pipelined mode), no live frames are waiting
    // in the queue, and no processed frame is awaiting encode. Otherwise a
    // duplicate would compete with (and delay) real frames.
    if (_stopping ||
        _encoding ||
        _gpuBusy ||
        _readyFrame != null ||
        _frameQueue.isNotEmpty) {
      return;
    }
    final rec = _recForDup;
    if (rec == null) return;
    final intervalUs = _minFrameIntervalUs;
    if (intervalUs <= 0) return;
    final nowUs = rec.now();
    int fillPtsUs;
    if (cfrOutput) {
      // CFR: fill the next unfilled grid slot once its claim window has
      // passed (see FramePacer.claimIdleSlot). Check that a fill source
      // exists BEFORE claiming — a claimed slot we cannot fill would become
      // a permanent timeline hole.
      final hasSource =
          idleFramePolicy == VideoIdleFramePolicy.black ||
          _lastDirectBuffer != null ||
          (_lastSharedTex?.isValid ?? false);
      if (!hasSource) return;
      final slotPts = _pacer.claimIdleSlot(nowUs);
      if (slotPts == null) return;
      fillPtsUs = slotPts;
    } else {
      // VFR: only fill if a frame hasn't been emitted within ~1.5 intervals —
      // i.e. the live capture path is currently keeping up.
      if (_lastVideoPtsUs < 0 ||
          nowUs - _lastVideoPtsUs < (intervalUs * 3) ~/ 2) {
        return;
      }
      fillPtsUs = nowUs;
    }
    if (idleFramePolicy == VideoIdleFramePolicy.duplicate) {
      // Direct-passthrough mode retains the last live capture buffer instead
      // of a processor texture — re-encode it via its NT handle.
      final directBuf = _lastDirectBuffer;
      if (directBuf != null) {
        _encoding = true;
        final fut = _encodeDuplicateDirect(rec, directBuf, fillPtsUs);
        _inFlight.add(fut);
        fut.whenComplete(() {
          _inFlight.remove(fut);
          _encoding = false;
          _pumpQueue(rec);
        });
        return;
      }
      final tex = _lastSharedTex;
      if (tex == null) return;
      // If the processor disposed the texture (e.g. resolution change), drop
      // our reference so we don't dereference freed memory next tick.
      if (!tex.isValid) {
        _lastSharedTex = null;
        return;
      }
      _encoding = true;
      final fut = _encodeDuplicate(rec, tex, fillPtsUs);
      _inFlight.add(fut);
      fut.whenComplete(() {
        _inFlight.remove(fut);
        _encoding = false;
        // A live frame may have raced in while we were duplicating.
        _pumpQueue(rec);
      });
    } else if (idleFramePolicy == VideoIdleFramePolicy.black) {
      _encoding = true;
      final fut = _encodeBlack(rec, fillPtsUs);
      _inFlight.add(fut);
      fut.whenComplete(() {
        _inFlight.remove(fut);
        _encoding = false;
        _pumpQueue(rec);
      });
    }
  }

  // Pre-allocated all-zeros RGBA buffer for black frame fill.
  Uint8List? _blackFrameCache;
  Uint8List get _blackFrameData =>
      _blackFrameCache ??= Uint8List(width * height * 4);

  Future<void> _encodeDuplicate(
    Recorder rec,
    SharedOutputTexture tex,
    int nowUs,
  ) async {
    try {
      var ptsUs = nowUs;
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;
      final src = D3D11TextureFrameSource(
        texturePtr: tex.d3d11TexturePtr,
        width: tex.width,
        height: tex.height,
        pixelFormat: MiniAVPixelFormat.rgba32,
      );
      final pkt = await encoder.encode(src);
      if (pkt != null) {
        _statsPacketsOut++;
        _statsDupFrames++;
        _statsTotalPktBytes += pkt.data.length;
        if (pkt.data.length < _statsMinPktBytes)
          _statsMinPktBytes = pkt.data.length;
        if (pkt.data.length > _statsMaxPktBytes)
          _statsMaxPktBytes = pkt.data.length;
        await rec.dispatchPacket(
          this,
          pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
        );
      }
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log(
          '$label duplicate encode error: $e\n$st',
          RecorderLogLevel.error,
        );
      }
    }
  }

  /// Duplicate-encode for the direct-passthrough path: re-encodes the retained
  /// last live capture buffer via its NT handle (see [_lastDirectBuffer]).
  Future<void> _encodeDuplicateDirect(
    Recorder rec,
    MiniAVBuffer buf,
    int nowUs,
  ) async {
    try {
      var ptsUs = nowUs;
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;
      final src = FrameSource.miniavBuffer(buf);
      final pkt = await encoder.encode(src);
      if (pkt != null) {
        _statsPacketsOut++;
        _statsDupFrames++;
        _statsTotalPktBytes += pkt.data.length;
        if (pkt.data.length < _statsMinPktBytes)
          _statsMinPktBytes = pkt.data.length;
        if (pkt.data.length > _statsMaxPktBytes)
          _statsMaxPktBytes = pkt.data.length;
        await rec.dispatchPacket(
          this,
          pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
        );
      }
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log(
          '$label direct duplicate encode error: $e\n$st',
          RecorderLogLevel.error,
        );
      }
    }
  }

  Future<void> _encodeBlack(Recorder rec, int nowUs) async {
    try {
      var ptsUs = nowUs;
      if (ptsUs <= _lastVideoPtsUs) ptsUs = _lastVideoPtsUs + 1;
      _lastVideoPtsUs = ptsUs;
      final src = FrameSource.cpu(
        bytes: _blackFrameData,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: width,
        height: height,
      );
      final pkt = await encoder.encode(src);
      if (pkt != null) {
        _statsPacketsOut++;
        _statsDupFrames++;
        _statsTotalPktBytes += pkt.data.length;
        if (pkt.data.length < _statsMinPktBytes)
          _statsMinPktBytes = pkt.data.length;
        if (pkt.data.length > _statsMaxPktBytes)
          _statsMaxPktBytes = pkt.data.length;
        await rec.dispatchPacket(
          this,
          pkt.copyWith(ptsUs: ptsUs, dtsUs: ptsUs),
        );
      }
    } catch (e, st) {
      _statsEncodeErrors++;
      _lastEncodeError = e;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastErrorLogMs == 0 ||
          nowMs - _lastErrorLogMs > _errorLogIntervalMs) {
        _lastErrorLogMs = nowMs;
        Recorder._log(
          '$label black frame encode error: $e\n$st',
          RecorderLogLevel.error,
        );
      }
    }
  }

  @override
  Future<void> dispose() async {
    // Release the duplicator's retained direct-passthrough frame. Safe here:
    // Recorder._shutdown has already drained in-flight encodes (step 2), so
    // nothing can still be reading the buffer.
    final retained = _lastDirectBuffer;
    _lastDirectBuffer = null;
    if (retained != null) MiniAV.releaseBufferSync(retained);
    try {
      await destroyFn();
    } catch (_) {}
    try {
      await encoder.close();
    } catch (_) {}
    try {
      processor?.dispose();
    } catch (_) {}
  }

  @override
  TrackInfo toTrackInfo() => VideoTrackInfo(
    codec: videoCodec,
    width: width,
    height: height,
    frameRateNumerator: frameRateNum,
    frameRateDenominator: frameRateDen,
    // Codec-private data (SPS/PPS) when the encoder exposes it at open time
    // (software encoders with global_header do). Lets FfmpegMuxer write the
    // track header without a live encoder bridge — required for the
    // isolate-hosted software encoder, whose AVCodecContext lives on a worker
    // isolate. Bridge-capable encoders (D3D11/HW) still provide their bridge
    // via [encoderBridge], which the muxer prefers.
    extraData: encoder.platform.extraData,
  );

  @override
  FfmpegEncoderBridge? get encoderBridge {
    final p = encoder.platform;
    return p is FfmpegEncoderBridge ? p as FfmpegEncoderBridge : null;
  }

  @override
  TrackChunk toChunk(EncodedPacket pkt) {
    final isFirst = !_firstChunkSent;
    final extra = isFirst ? encoder.extraData?.bytes : null;
    _firstChunkSent = true;
    return TrackChunk(
      trackIndex: index,
      kind: TrackKind.video,
      videoCodec: videoCodec,
      ptsUs: pkt.ptsUs,
      dtsUs: pkt.dtsUs,
      durationUs: pkt.durationUs,
      bytes: pkt.data,
      isKeyframe: pkt.isKeyframe,
      extraData: extra,
      videoWidth: isFirst ? width : null,
      videoHeight: isFirst ? height : null,
      videoFrameRateNum: isFirst ? frameRateNum : null,
      videoFrameRateDen: isFirst ? frameRateDen : null,
    );
  }
}

class _AudioTrackRuntime extends _TrackRuntime {
  _AudioTrackRuntime({
    required super.index,
    required super.label,
    required this.encoder,
    required this.audioCodec,
    required this.sampleRate,
    required this.channels,
    required this.audioFormat,
    required this.captureCtx,
    required this.startFn,
    required this.stopFn,
    required this.destroyFn,
  });

  final AudioEncoder encoder;
  final AudioCodec audioCodec;
  final int sampleRate;
  final int channels;
  final MiniAVAudioFormat audioFormat;
  final Object captureCtx;
  final Future<void> Function(void Function(MiniAVBuffer, Object?)) startFn;
  final Future<void> Function() stopFn;
  final Future<void> Function() destroyFn;

  bool _stopping = false;
  bool _firstChunkSent = false;

  // Audio PTS is computed from cumulative sample count anchored to a single
  // epoch (captured on the first callback), NOT from rec.now() on every
  // callback.  Wall-clock PTSs jitter with the capture-callback delivery
  // time — when the Dart isolate is briefly blocked, several audio buffers
  // back up and then fire bunched within a few hundred microseconds, all
  // stamped with near-identical now() values.  The AAC muxer then either
  // collapses the timeline or inserts edit-list gaps, which is heard as
  // clicks / crackle.  Sample-count PTSs are monotonic, perfectly uniform,
  // and unaffected by isolate scheduling.
  int _samplesEmitted = 0;
  int _audioEpochUs = 0;
  bool _audioEpochSet = false;

  // Crystal-drift correction. The audio hardware oscillator and the CPU QPC
  // oscillator (Stopwatch) diverge at up to 100 ppm, causing the sample-count
  // PTS to drift away from the wall-clock PTS used by the video track. Over a
  // 30-minute recording at 100 ppm that is 180 ms — clearly audible.
  //
  // Two-tier correction:
  //   |drift| > [_driftSnapThresholdUs] → snap epoch to wall clock.
  //   |drift| > [_driftThresholdUs]     → nudge epoch by ±[_driftCorrectionUs].
  //
  // **Snap** handles the case where audio simply stops for a while (audio
  // device sleep, WASAPI exclusive-mode preemption, very long isolate stall,
  // app minimised long enough that loopback never fires).  When playback
  // resumes hundreds of ms / seconds later, the sample-count PTS is far
  // behind wall clock and slow ppm correction cannot catch up in finite time.
  // Snapping aligns the next PTS exactly to wall clock.
  //
  // **Nudge** handles steady-state ppm drift.  At ~100 callbacks/s the nudge
  // rate is 100 × 20 µs = 2 ms/s, two orders of magnitude above the worst
  // observed crystal drift (~10 µs/s = 100 ppm) and well below the 5 ms/s
  // (≈0.5%) audible pitch threshold.
  //
  // Snap threshold = 5 s: the snap is now a catastrophic-only fallback.
  // Genuine capture gaps are detected via capture timestamps and filled with
  // silence (see the capture-gap fields below), which keeps the encoder's
  // sample-count timeline correct — something an epoch snap cannot do. The
  // snap must be far above any plausible isolate stall, because a stall
  // delivers its backlog in a capture-contiguous burst whose arrival drift
  // looks like a gap; snapping on it would mislabel the whole burst.
  static const int _driftThresholdUs = 10000; // 10 ms — nudge boundary
  static const int _driftSnapThresholdUs = 5000000; // 5 s — catastrophic only
  static const int _driftCorrectionUs = 20; // 20 µs nudge cap per callback

  // ── Capture-gap silence fill (capture-timestamp based) ───────────────────
  // WASAPI loopback delivers NO buffers at all while the render endpoint is
  // idle (nothing playing) — not even SILENT-flagged ones. Because the AAC
  // encoder derives every output packet's PTS from the cumulative sample
  // COUNT fed to it (the wall-clock ptsUs we pass only slews its epoch at
  // ±50 µs/call), an unfilled gap makes ALL audio after it play early — a
  // growing A/V desync. When capture resumes we inject silence covering the
  // missing span.
  //
  // Detection uses buffer.timestampUs — the packet's CAPTURE time stamped on
  // the native thread (QPC for loopback, monotonic µs for mic). Only deltas
  // are used; the absolute value is boot-relative and never enters the PTS.
  // Wall-clock drift at ARRIVAL cannot be used to detect gaps: when the Dart
  // isolate stalls (GC / heavy GPU work), the native capture thread keeps
  // queueing packets, which then arrive late in a burst. Arrival drift looks
  // identical to an idle gap, but no samples are missing — filling (or
  // snapping) there inserts phantom silence AND pushes the sample count past
  // wall clock, desyncing everything after the stall. Capture timestamps
  // distinguish the two cases exactly: bursts are capture-contiguous, idle
  // gaps jump.
  static const int _captureGapThresholdUs = 30000; // 3 lost 10 ms packets
  // Cap one gap fill so a very long idle stretch (AFK for minutes) can't
  // encode an unbounded amount of silence in one callback; any remainder
  // beyond the cap is absorbed by the (catastrophic-only) epoch snap.
  static const int _maxGapFillUs = 60000000; // 60 s
  // Chunk size for the silence-fill loop — bounds transient PCM allocation.
  static const int _gapFillChunkUs = 1000000; // 1 s
  // Fallback when the platform doesn't stamp capture times (timestampUs == 0):
  // wall-clock-deficit fill. Cannot tell bursts from gaps, so it keeps the
  // conservative 100 ms threshold.
  static const int _wallGapFillThresholdUs = 100000; // 100 ms

  // Projected capture timestamp of the next buffer's first sample
  // (= last buffer's capture time + its duration).
  int _expectedCaptureUs = 0;
  bool _captureTsValid = false;

  @override
  Future<void> startCapture(Recorder rec) async {
    await startFn((MiniAVBuffer buffer, Object? _) {
      if (_stopping) {
        unawaited(MiniAV.releaseBuffer(buffer));
        return;
      }
      final audio = buffer.data;
      if (audio is! MiniAVAudioBuffer) {
        unawaited(MiniAV.releaseBuffer(buffer));
        return;
      }
      if (!_audioEpochSet) {
        // Always anchor to the master clock (rec.now() = elapsed µs since
        // _launch()).  buffer.timestampUs is an absolute QPC value measured
        // from system boot — on a machine that has been on for 59 hours it
        // would be ~212 billion µs, making the container report a 59-hour
        // duration instead of the real 12-minute recording.
        _audioEpochUs = rec.now();
        _audioEpochSet = true;
      }
      // WASAPI delivers AUDCLNT_BUFFERFLAGS_SILENT buffers during quiet
      // stretches (game muted, menus, nothing playing) with data=NULL /
      // size 0 but a non-zero frame count, surfaced here as an empty
      // `audio.data`.  Encode explicit zero-filled silence for these rather
      // than dropping them: a dropped buffer leaves a HOLE in the AAC stream,
      // so any clip whose window overlaps the quiet stretch plays back with
      // broken audio — or no audio at all when the whole window is silent and
      // the clip ends up with zero audio packets.  The mixed mic+loopback
      // path already synthesises silence this way (see _onLoopbackChunk); this
      // keeps the loopback-only / mic-only path consistent.
      final frameCount = audio.frameCount;
      if (frameCount <= 0) {
        unawaited(MiniAV.releaseBuffer(buffer));
        return;
      }
      final Uint8List pcm;
      final MiniAVAudioFormat fmt;
      if (audio.data.isEmpty) {
        pcm = _silentPcm(frameCount);
        fmt = audioFormat;
      } else {
        pcm = audio.data;
        fmt = audio.info.format;
      }
      // Apply drift correction (or snap) BEFORE computing the PTS that we
      // emit, so this chunk goes out with the corrected epoch — not the next
      // one.  This matters most for snaps: after a gap we want THIS chunk
      // aligned to wall clock so the muxer sees the discontinuity correctly.
      //
      // Snap fires ONLY for negative drift (audio behind wall clock = gap
      // recovery). Snapping on positive drift would emit a PTS smaller than
      // the previous chunk's, violating muxer monotonicity. Sustained
      // positive drift is impossible with the 20 µs/cb nudge (corrects at
      // 2 ms/s, far above the worst ppm drift).
      final wallUs = rec.now();

      // Capture-gap fill (see field docs): detect missing capture spans via
      // the native capture timestamp, NOT arrival-time drift — bursts after
      // an isolate stall are capture-contiguous and must not be filled.
      final captureUs = buffer.timestampUs;
      if (captureUs > 0) {
        if (_captureTsValid) {
          final gapUs = captureUs - _expectedCaptureUs;
          if (gapUs > _captureGapThresholdUs) {
            final fillUs = gapUs > _maxGapFillUs ? _maxGapFillUs : gapUs;
            final gapFrames = fillUs * sampleRate ~/ 1000000;
            if (gapFrames > 0) {
              Recorder._log(
                '$label capture gap ${gapUs ~/ 1000} ms — '
                'filling ${fillUs ~/ 1000} ms with silence',
                RecorderLogLevel.info,
              );
              _emitSilenceFrames(rec, gapFrames);
            }
          }
        }
        _expectedCaptureUs = captureUs + frameCount * 1000000 ~/ sampleRate;
        _captureTsValid = true;
      } else {
        // No capture timestamps on this platform — fall back to wall-clock
        // deficit fill (cannot distinguish bursts; conservative threshold).
        final deficit =
            wallUs - (_audioEpochUs + _samplesEmitted * 1000000 ~/ sampleRate);
        if (deficit > _wallGapFillThresholdUs) {
          final fillUs = deficit > _maxGapFillUs ? _maxGapFillUs : deficit;
          final gapFrames = fillUs * sampleRate ~/ 1000000;
          if (gapFrames > 0) _emitSilenceFrames(rec, gapFrames);
        }
      }

      final preliminaryPts =
          _audioEpochUs + _samplesEmitted * 1000000 ~/ sampleRate;
      final drift = preliminaryPts - wallUs;
      if (drift < -_driftSnapThresholdUs) {
        // Catastrophic snap: only reached when a gap exceeded _maxGapFillUs
        // (the fill covered the cap; the epoch absorbs the remainder) or
        // capture timestamps went bogus.
        _audioEpochUs = wallUs - _samplesEmitted * 1000000 ~/ sampleRate;
      } else if (drift > _driftThresholdUs) {
        _audioEpochUs -= _driftCorrectionUs;
      } else if (drift < -_driftThresholdUs) {
        _audioEpochUs += _driftCorrectionUs;
      }
      final ptsUs = _audioEpochUs + _samplesEmitted * 1000000 ~/ sampleRate;
      _samplesEmitted += frameCount;
      final fut = _encodeAudio(rec, pcm, fmt, frameCount, ptsUs).whenComplete(
        () {
          unawaited(MiniAV.releaseBuffer(buffer));
        },
      );
      _inFlight.add(fut);
      fut.whenComplete(() => _inFlight.remove(fut));
    });
  }

  Future<void> _encodeAudio(
    Recorder rec,
    Uint8List pcm,
    MiniAVAudioFormat format,
    int frameCount,
    int ptsUs,
  ) async {
    try {
      final pkts = await encoder.encode(
        pcm: pcm,
        format: format,
        frameCount: frameCount,
        ptsUs: ptsUs,
      );
      for (final p in pkts) {
        await rec.dispatchPacket(this, p);
      }
    } catch (e, st) {
      Recorder._log('$label encode: $e\n$st', RecorderLogLevel.error);
    }
  }

  // Reusable neutral-PCM buffer used to synthesise silence (WASAPI SILENT
  // buffers and idle-gap fill). Grown on demand and only ever filled with the
  // format's silence value, never overwritten with other content — so it is
  // safe for concurrent in-flight encodes to read (they always see identical,
  // stable bytes) and a smaller request just returns an exact-length view of
  // the front. encode() consumes the PCM synchronously before its future
  // settles, so a later grow (new allocation) never disturbs a running read.
  Uint8List _silence = Uint8List(0);

  Uint8List _silentPcm(int frameCount) {
    final bytes = frameCount * channels * _bytesPerSample(audioFormat);
    if (_silence.length < bytes) {
      _silence = Uint8List(bytes);
      // u8 PCM is unsigned — its silence value is 0x80, not 0x00.  Every other
      // supported format is signed/float where zeroed bytes already encode
      // silence.
      if (audioFormat == MiniAVAudioFormat.u8) {
        _silence.fillRange(0, bytes, 128);
      }
    }
    return bytes == _silence.length
        ? _silence
        : Uint8List.view(_silence.buffer, 0, bytes);
  }

  /// Feed [totalFrames] of silence to the encoder, advancing the PTS timeline,
  /// so the encoder's cumulative sample count tracks wall clock across an idle
  /// gap. Fed in bounded chunks so a multi-second gap doesn't allocate one huge
  /// PCM buffer. encode() buffers + drains each chunk before its future
  /// settles, so these silent frames stay ordered ahead of the resuming real
  /// audio.
  void _emitSilenceFrames(Recorder rec, int totalFrames) {
    final chunkFrames = _gapFillChunkUs * sampleRate ~/ 1000000;
    var remaining = totalFrames;
    while (remaining > 0) {
      final n = remaining < chunkFrames ? remaining : chunkFrames;
      final ptsUs = _audioEpochUs + _samplesEmitted * 1000000 ~/ sampleRate;
      final fut = _encodeAudio(rec, _silentPcm(n), audioFormat, n, ptsUs);
      _inFlight.add(fut);
      fut.whenComplete(() => _inFlight.remove(fut));
      _samplesEmitted += n;
      remaining -= n;
    }
  }

  static int _bytesPerSample(MiniAVAudioFormat fmt) => switch (fmt) {
    MiniAVAudioFormat.f32 => 4,
    MiniAVAudioFormat.s32 => 4,
    MiniAVAudioFormat.s16 => 2,
    MiniAVAudioFormat.u8 => 1,
    MiniAVAudioFormat.unknown => 4,
  };

  @override
  Future<void> stopCapture() async {
    _stopping = true;
    await stopFn();
  }

  @override
  Future<void> flushAndDispatch(Recorder rec) async {
    final pkts = await encoder.flush();
    for (final p in pkts) {
      await rec.dispatchPacket(this, p);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await destroyFn();
    } catch (_) {}
    try {
      await encoder.close();
    } catch (_) {}
  }

  @override
  TrackInfo toTrackInfo() => AudioTrackInfo(
    codec: audioCodec,
    sampleRate: sampleRate,
    channels: channels,
  );

  @override
  FfmpegEncoderBridge? get encoderBridge {
    final p = encoder.platform;
    return p is FfmpegEncoderBridge ? p as FfmpegEncoderBridge : null;
  }

  @override
  TrackChunk toChunk(EncodedPacket pkt) {
    final isFirst = !_firstChunkSent;
    final extra = isFirst ? encoder.extraData?.bytes : null;
    _firstChunkSent = true;
    return TrackChunk(
      trackIndex: index,
      kind: TrackKind.audio,
      audioCodec: audioCodec,
      ptsUs: pkt.ptsUs,
      dtsUs: pkt.dtsUs,
      durationUs: pkt.durationUs,
      bytes: pkt.data,
      isKeyframe: true,
      extraData: extra,
      sampleRate: isFirst ? sampleRate : null,
      channels: isFirst ? channels : null,
    );
  }
}

double _dbToLinear(double db) =>
    db == 0.0 ? 1.0 : math.pow(10.0, db / 20.0).toDouble();

class _MixedAudioTrackRuntime extends _TrackRuntime {
  _MixedAudioTrackRuntime({
    required super.index,
    required super.label,
    required this.encoder,
    required this.audioCodec,
    required this.micCtx,
    required this.loopCtx,
    required this.micGain,
    required this.loopGain,
    this.micChain,
    this.loopChain,
    this.masterChain,
  });

  final AudioEncoder encoder;
  final AudioCodec audioCodec;
  final MiniAudioInputContext micCtx;
  final MiniLoopbackContext loopCtx;
  final double micGain;
  final double loopGain;

  /// Optional DSP chains: [micChain]/[loopChain] run per source before the
  /// sum, [masterChain] on the summed mix before the safety clip. State
  /// (filter history, gain envelopes) lives for the whole recording.
  final AudioEffectChain? micChain;
  final AudioEffectChain? loopChain;
  final AudioEffectChain? masterChain;

  // Common output format. WASAPI shared-mode default on Windows is exactly
  // 48 kHz / stereo / f32, so for the typical case the per-callback work
  // is just a sum + soft-clip.
  static const int _outSampleRate = 48000;
  static const int _outChannels = 2;

  // Mic FIFO. The loopback callback drives encoding; mic samples wait here
  // until the loopback drains them.
  final _MixerRing _micRing = _MixerRing();

  // Watchdog: if mic stops producing we still want loopback to flow. Tracked
  // per drain tick so we don't pile up unbounded mic data on the ring.
  int _lastMicSamplesMs = 0;
  static const int _silenceTimeoutMs = 250;
  // Hard cap on mic backlog (~1 s of stereo f32 = ~384 KB). Stops the ring
  // from growing unboundedly if loopback is silent (e.g. nothing playing).
  static const int _maxMicBacklogFrames = _outSampleRate; // 1 s

  Recorder? _rec;
  Stopwatch? _wallClock;

  // Running count of output frames — also serves as the cumulative sample
  // count from which audio PTS is derived (see _onLoopbackChunk).  The
  // mixer's output rate is hardware-constant 48 kHz so sample-count → µs
  // is exact and immune to isolate-scheduling jitter.
  int _framesOut = 0;

  // Audio PTS epoch in master-clock µs, anchored on the first chunk.
  // _audioEpochSet guards first-callback initialization; using a bool rather
  // than an _audioEpochUs < 0 sentinel prevents the crystal-drift correction
  // from accidentally re-initializing the epoch if corrections drive it to a
  // slightly negative value.
  int _audioEpochUs = 0;
  bool _audioEpochSet = false;

  // Crystal-drift correction — same semantics as
  // _AudioTrackRuntime._driftThresholdUs / _driftSnapThresholdUs /
  // _driftCorrectionUs.  See that field's comment for full rationale
  // (snap is a catastrophic-only fallback; capture gaps are silence-filled).
  static const int _driftThresholdUs = 10000; // 10 ms — nudge boundary
  static const int _driftSnapThresholdUs = 5000000; // 5 s — catastrophic only
  static const int _driftCorrectionUs = 20; // 20 µs nudge cap per callback

  // Capture-gap silence fill — same rationale as _AudioTrackRuntime's fields
  // of the same name. This mixer is driven solely by the loopback callback,
  // so when the render endpoint goes idle (WASAPI delivers nothing) the fed
  // sample count falls behind and everything after plays early. Gaps are
  // detected on the loopback buffers' native capture timestamps — NEVER on
  // arrival drift, which cannot tell an idle gap from a delivery burst after
  // an isolate stall (bursts are capture-contiguous; filling them corrupts
  // the timeline).
  static const int _captureGapThresholdUs = 30000; // 3 lost 10 ms packets
  static const int _maxGapFillUs = 60000000; // 60 s
  static const int _gapFillChunkUs = 1000000; // 1 s
  static const int _wallGapFillThresholdUs = 100000; // no-timestamp fallback

  // Projected capture timestamp of the next loopback buffer's first sample.
  int _expectedCaptureUs = 0;
  bool _captureTsValid = false;

  bool _stopping = false;
  bool _firstChunkSent = false;

  // Sequential encode chain — chunks are always processed in arrival order.
  // Using a chain of futures guarantees that no 10 ms window is ever
  // silently discarded.
  Future<void> _encodeChain = Future<void>.value();

  // Counters for silent-drop diagnostics, logged at most every 5 s.
  int _micBacklogDrops = 0;
  int _lastMicBacklogLogMs = 0;
  static const int _mixDropLogIntervalMs = 5000;

  // Reusable scratch buffer — sized to the largest loopback chunk we've
  // seen so we don't allocate a Float32List per callback.
  Float32List _scratch = Float32List(0);

  // Pool of PCM byte buffers recycled across loopback chunks (~100/s). A buffer
  // is checked out at enqueue (see [_acquirePcm]) and returned by [_encodeMix]
  // once the encoder has consumed it. Capped so a stalled encode chain can't
  // grow it unbounded; over the cap, extra buffers are simply left to the GC.
  final List<Uint8List> _pcmPool = [];
  static const int _pcmPoolMax = 8;

  Uint8List _acquirePcm(int bytes) {
    for (var i = _pcmPool.length - 1; i >= 0; i--) {
      if (_pcmPool[i].length == bytes) return _pcmPool.removeAt(i);
    }
    return Uint8List(bytes);
  }

  void _releasePcm(Uint8List pcm) {
    if (_pcmPool.length < _pcmPoolMax) _pcmPool.add(pcm);
  }

  @override
  Future<void> startCapture(Recorder rec) async {
    _rec = rec;
    _wallClock = Stopwatch()..start();
    _lastMicSamplesMs = _wallClock!.elapsedMilliseconds;

    // Mic: convert to target f32 stereo, apply gain + effects, push to ring.
    // Gain and effects run here (not at mix time) so the per-source DSP
    // chain sees a contiguous post-gain mic stream.
    await micCtx.startCapture((MiniAVBuffer buffer, Object? _) {
      try {
        if (_stopping) return;
        final audio = buffer.data;
        if (audio is! MiniAVAudioBuffer) return;
        final f32 = _toTargetF32(audio);
        if (micGain != 1.0) {
          for (var i = 0; i < f32.length; i++) {
            f32[i] *= micGain;
          }
        }
        micChain?.process(f32, f32.length);
        _micRing.add(f32);
        _lastMicSamplesMs = _wallClock!.elapsedMilliseconds;
        // Drop oldest mic frames if loopback isn't draining (silent system).
        if (_micRing.frames > _maxMicBacklogFrames) {
          int dropped = 0;
          while (_micRing.frames > _maxMicBacklogFrames) {
            _micRing.take(_outSampleRate ~/ 10); // drop 100 ms
            dropped += _outSampleRate ~/ 10;
          }
          _micBacklogDrops += dropped;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (_lastMicBacklogLogMs == 0 ||
              nowMs - _lastMicBacklogLogMs > _mixDropLogIntervalMs) {
            _lastMicBacklogLogMs = nowMs;
            Recorder._log(
              '$label mic ring overflow — dropped '
              '${_micBacklogDrops ~/ _outSampleRate * 1000}ms of mic audio '
              '(loopback silent or stalled)',
              RecorderLogLevel.warning,
            );
            _micBacklogDrops = 0;
          }
        }
      } finally {
        unawaited(MiniAV.releaseBuffer(buffer));
      }
    });

    // Loopback: drives encoding. Each callback delivers ~10 ms of audio at
    // 48 kHz f32 stereo (the WASAPI default). We mix mic in-place and feed
    // the encoder once. No timers, no extra allocations.
    await loopCtx.startCapture((MiniAVBuffer buffer, Object? _) {
      try {
        if (_stopping) return;
        final audio = buffer.data;
        if (audio is! MiniAVAudioBuffer) return;
        _onLoopbackChunk(audio, buffer.timestampUs);
      } finally {
        unawaited(MiniAV.releaseBuffer(buffer));
      }
    });
  }

  /// Convert mic capture buffer to interleaved f32 stereo at 48 kHz. This
  /// is the only allocation/conversion path for mic; loopback uses a
  /// reusable scratch buffer in `_onLoopbackChunk`.
  Float32List _toTargetF32(MiniAVAudioBuffer audio) {
    final inFmt = audio.info.format;
    final inCh = audio.info.channels;
    final inSr = audio.info.sampleRate;
    final inFrames = audio.frameCount;

    // 1. Decode interleaved input → float per-channel temp.
    final inSamples = inFrames * inCh;
    final flt = Float32List(inSamples);
    final src = audio.data;
    switch (inFmt) {
      case MiniAVAudioFormat.f32:
        final view = src.buffer.asFloat32List(src.offsetInBytes, inSamples);
        for (var i = 0; i < inSamples; i++) flt[i] = view[i];
      case MiniAVAudioFormat.s16:
        final view = src.buffer.asInt16List(src.offsetInBytes, inSamples);
        for (var i = 0; i < inSamples; i++) flt[i] = view[i] / 32768.0;
      case MiniAVAudioFormat.s32:
        final view = src.buffer.asInt32List(src.offsetInBytes, inSamples);
        for (var i = 0; i < inSamples; i++) flt[i] = view[i] / 2147483648.0;
      case MiniAVAudioFormat.u8:
        for (var i = 0; i < inSamples; i++) flt[i] = (src[i] - 128) / 128.0;
      case MiniAVAudioFormat.unknown:
        return Float32List(inFrames * _outChannels);
    }

    // 2. Channel mix → stereo.
    Float32List stereo;
    if (inCh == _outChannels) {
      stereo = flt;
    } else if (inCh == 1) {
      stereo = Float32List(inFrames * 2);
      for (var i = 0; i < inFrames; i++) {
        final s = flt[i];
        stereo[i * 2] = s;
        stereo[i * 2 + 1] = s;
      }
    } else {
      stereo = Float32List(inFrames * 2);
      for (var i = 0; i < inFrames; i++) {
        stereo[i * 2] = flt[i * inCh];
        stereo[i * 2 + 1] = flt[i * inCh + 1];
      }
    }

    // 3. Sample-rate convert (linear interpolation) → 48 kHz.
    if (inSr == _outSampleRate) return stereo;
    final ratio = _outSampleRate / inSr;
    final outFrames = (inFrames * ratio).floor();
    final out = Float32List(outFrames * 2);
    for (var i = 0; i < outFrames; i++) {
      final srcPos = i / ratio;
      final i0 = srcPos.floor();
      final i1 = (i0 + 1) < inFrames ? i0 + 1 : i0;
      final t = srcPos - i0;
      out[i * 2] = stereo[i0 * 2] * (1 - t) + stereo[i1 * 2] * t;
      out[i * 2 + 1] = stereo[i0 * 2 + 1] * (1 - t) + stereo[i1 * 2 + 1] * t;
    }
    return out;
  }

  /// Hot path. Called from the loopback capture thread for every chunk
  /// (~10 ms at 48 kHz f32 stereo on Windows). MUST be cheap.
  ///
  /// [captureUs] is the buffer's native capture timestamp (QPC-derived µs,
  /// boot-relative — deltas only) used for capture-gap detection; 0 when the
  /// platform doesn't stamp capture times.
  void _onLoopbackChunk(MiniAVAudioBuffer audio, int captureUs) {
    final loopFrames = audio.frameCount;
    final loopCh = audio.info.channels;
    final loopSr = audio.info.sampleRate;
    final loopFmt = audio.info.format;

    // WASAPI sends AUDCLNT_BUFFERFLAGS_SILENT packets with data=NULL and
    // data_size_bytes=0 but a non-zero frame count.  The Dart FFI layer
    // exposes these as audio.data being an empty Uint8List.  Calling
    // asFloat32List() on an empty buffer with a positive length throws a
    // RangeError, which propagates out of the FFI callback and kills the
    // loopback capture — exactly why game audio disappears.
    // Synthesise silence: advance the PTS counter and encode a
    // zero-filled block so the timeline stays continuous.
    Float32List loopStereo;
    if (audio.data.isEmpty) {
      loopStereo = Float32List(loopFrames * _outChannels); // all zeros
    } else if (loopFmt == MiniAVAudioFormat.f32 &&
        loopCh == _outChannels &&
        loopSr == _outSampleRate) {
      // Fast path: native 48 kHz / 2ch / f32 (the Windows default).
      // Reinterpret the bytes directly — no copy, no resample.
      loopStereo = audio.data.buffer.asFloat32List(
        audio.data.offsetInBytes,
        loopFrames * _outChannels,
      );
    } else {
      // Slow path: same conversion as mic.
      loopStereo = _toTargetF32(audio);
    }

    final outFrames = loopStereo.length ~/ _outChannels;
    final outSamples = outFrames * _outChannels;

    // Reuse scratch buffer when possible.
    if (_scratch.length < outSamples) {
      _scratch = Float32List(outSamples);
    }
    final mix = _scratch;

    // Apply loopback gain into scratch, then the loopback DSP chain.
    if (loopGain == 1.0) {
      mix.setRange(0, outSamples, loopStereo);
      // Zero the tail if scratch is bigger than this chunk.
      for (var i = outSamples; i < mix.length; i++) mix[i] = 0;
    } else {
      for (var i = 0; i < outSamples; i++) mix[i] = loopStereo[i] * loopGain;
    }
    loopChain?.process(mix, outSamples);

    // Mix mic on top — only if recent samples have been received and the
    // ring has at least this many frames; otherwise pad with silence.
    // Mic gain + effects were already applied in the mic capture callback.
    final nowMs = _wallClock?.elapsedMilliseconds ?? 0;
    final micAlive = (nowMs - _lastMicSamplesMs) <= _silenceTimeoutMs;
    if (micAlive && _micRing.frames >= outFrames) {
      final mic = _micRing.take(outFrames);
      for (var i = 0; i < outSamples; i++) {
        mix[i] += mic[i];
      }
    } else if (micAlive) {
      // Mic is alive but ring is short (e.g. capture just started or mic
      // is running slightly slower than loopback). Take what we can.
      final avail = _micRing.frames;
      if (avail > 0) {
        final mic = _micRing.take(avail);
        final n = avail * _outChannels;
        for (var i = 0; i < n; i++) {
          mix[i] += mic[i];
        }
      }
    }

    // Master chain on the summed mix (e.g. a limiter), then the hard clip
    // below stays as a last-resort safety net.
    masterChain?.process(mix, outSamples);

    // Soft-clip in-place.
    for (var i = 0; i < outSamples; i++) {
      final s = mix[i];
      if (s > 1.0) {
        mix[i] = 1.0;
      } else if (s < -1.0) {
        mix[i] = -1.0;
      }
    }

    // Hand the (still-scratch-backed) PCM to the encoder. We must copy here
    // because the encode is async and we will overwrite scratch on the next
    // callback. Copy is `outSamples * 4` bytes — ~4 KB for 10 ms. The byte
    // buffer is drawn from a small pool and returned by [_encodeMix], and the
    // copy uses setRange (no intermediate sublist allocation).
    final pcm = _acquirePcm(outSamples * 4);
    pcm.buffer.asFloat32List(0, outSamples).setRange(0, outSamples, mix);

    // PTS is anchored to the master clock on the first chunk and then
    // advanced by cumulative output sample count.  See _AudioTrackRuntime
    // for why wall-clock PTS per callback produces crackly playback when
    // the isolate is briefly blocked.  The mixer's output rate is a
    // hardware-constant 48 kHz so the sample-count → µs conversion is
    // exact.
    if (!_audioEpochSet) {
      _audioEpochUs = _rec?.now() ?? 0;
      _audioEpochSet = true;
    }
    // Apply drift correction BEFORE computing the PTS so this chunk goes out
    // with the corrected epoch.  Snap fires ONLY for negative drift (audio
    // behind wall clock) — the gap-recovery case (loopback silent with no
    // callbacks, app minimised, audio device sleep, isolate stall ≥ 100 ms).
    // Snapping on positive drift would emit a PTS smaller than the previous
    // chunk's and the muxer would reject it.
    final wallUs = _rec?.now() ?? 0;

    // Capture-gap fill (see field docs): detect missing capture spans via the
    // loopback buffer's native capture timestamp, NOT arrival drift — bursts
    // after an isolate stall are capture-contiguous and must not be filled.
    if (captureUs > 0) {
      if (_captureTsValid) {
        final gapUs = captureUs - _expectedCaptureUs;
        if (gapUs > _captureGapThresholdUs) {
          final fillUs = gapUs > _maxGapFillUs ? _maxGapFillUs : gapUs;
          final gapFrames = fillUs * _outSampleRate ~/ 1000000;
          if (gapFrames > 0) {
            Recorder._log(
              '$label capture gap ${gapUs ~/ 1000} ms — '
              'filling ${fillUs ~/ 1000} ms with silence',
              RecorderLogLevel.info,
            );
            _emitSilenceFrames(gapFrames);
          }
        }
      }
      // Project the next buffer's capture time from THIS buffer's own frame
      // count at its SOURCE rate (the mixer may resample to 48 kHz).
      final srcRate = loopSr > 0 ? loopSr : _outSampleRate;
      _expectedCaptureUs = captureUs + loopFrames * 1000000 ~/ srcRate;
      _captureTsValid = true;
    } else {
      // No capture timestamps on this platform — fall back to wall-clock
      // deficit fill (cannot distinguish bursts; conservative threshold).
      final deficit =
          wallUs - (_audioEpochUs + _framesOut * 1000000 ~/ _outSampleRate);
      if (deficit > _wallGapFillThresholdUs) {
        final fillUs = deficit > _maxGapFillUs ? _maxGapFillUs : deficit;
        final gapFrames = fillUs * _outSampleRate ~/ 1000000;
        if (gapFrames > 0) _emitSilenceFrames(gapFrames);
      }
    }

    final preliminaryPts =
        _audioEpochUs + _framesOut * 1000000 ~/ _outSampleRate;
    final drift = preliminaryPts - wallUs;
    if (drift < -_driftSnapThresholdUs) {
      _audioEpochUs = wallUs - _framesOut * 1000000 ~/ _outSampleRate;
    } else if (drift > _driftThresholdUs) {
      _audioEpochUs -= _driftCorrectionUs;
    } else if (drift < -_driftThresholdUs) {
      _audioEpochUs += _driftCorrectionUs;
    }
    final ptsUs = _audioEpochUs + _framesOut * 1000000 ~/ _outSampleRate;
    _framesOut += outFrames;

    // Chain this chunk onto the sequential encode queue so it is processed
    // in order and never dropped. If a previous encode+mux write is still
    // pending (e.g. the muxer's async future hasn't settled yet), this chunk
    // waits behind it rather than being discarded.
    _encodeChain = _encodeChain.then<void>(
      (_) => _encodeMix(pcm, outFrames, ptsUs),
    );
  }

  @override
  Future<void> drainInFlight() => _encodeChain;

  Future<void> _encodeMix(
    Uint8List pcm,
    int frameCount,
    int ptsUs, {
    bool recycle = true,
  }) async {
    try {
      final pkts = await encoder.encode(
        pcm: pcm,
        format: MiniAVAudioFormat.f32,
        frameCount: frameCount,
        ptsUs: ptsUs,
      );
      final rec = _rec;
      if (rec == null) return;
      for (final p in pkts) {
        await rec.dispatchPacket(this, p);
      }
    } catch (e, st) {
      Recorder._log('$label mix encode: $e\n$st', RecorderLogLevel.error);
    } finally {
      // The encoder has consumed `pcm` by the time encode() returned; recycle
      // pool-drawn hot-path buffers. Idle-gap silence buffers are allocated
      // fresh (recycle: false) so their large 1 s size never evicts the small
      // per-callback buffers the pool exists to recycle.
      if (recycle) _releasePcm(pcm);
    }
  }

  /// Append [totalFrames] of gap fill to the encode chain, advancing
  /// _framesOut, so the encoder's cumulative sample count tracks capture time
  /// across a span where the loopback callback stopped firing. Fed in bounded
  /// chunks with freshly-allocated PCM (kept out of the recycling pool — see
  /// [_encodeMix]) so a multi-second gap can't grow one huge buffer.
  ///
  /// The mic kept capturing during the gap, so its audio for that span is
  /// sitting in [_micRing] (bounded to the most recent ~1 s by the backlog
  /// cap). Mix it into the TAIL of the fill — that is where it belongs on the
  /// timeline — instead of leaving it queued, which would delay every
  /// post-gap mic sample by the backlog length for the rest of the session.
  void _emitSilenceFrames(int totalFrames) {
    final ringFrames = _micRing.frames < totalFrames
        ? _micRing.frames
        : totalFrames;
    final leadZeros = totalFrames - ringFrames;
    final chunkFrames = _gapFillChunkUs * _outSampleRate ~/ 1000000;
    var pos = 0;
    while (pos < totalFrames) {
      final remaining = totalFrames - pos;
      final n = remaining < chunkFrames ? remaining : chunkFrames;
      final pcm = Uint8List(n * _outChannels * 4); // f32 zeros = silence
      // Portion of this chunk overlapping the mic-backed tail region
      // [leadZeros, totalFrames).
      final overlapStart = pos > leadZeros ? pos : leadZeros;
      final overlapEnd = pos + n;
      if (overlapStart < overlapEnd) {
        final mic = _micRing.take(overlapEnd - overlapStart);
        final f32 = pcm.buffer.asFloat32List(0, n * _outChannels);
        final base = (overlapStart - pos) * _outChannels;
        for (var i = 0; i < mic.length; i++) {
          var s = mic[i];
          if (s > 1.0) s = 1.0;
          if (s < -1.0) s = -1.0;
          f32[base + i] = s;
        }
      }
      final ptsUs = _audioEpochUs + _framesOut * 1000000 ~/ _outSampleRate;
      _encodeChain = _encodeChain.then<void>(
        (_) => _encodeMix(pcm, n, ptsUs, recycle: false),
      );
      _framesOut += n;
      pos += n;
    }
  }

  @override
  Future<void> stopCapture() async {
    _stopping = true;
    try {
      await micCtx.stopCapture();
    } catch (_) {}
    try {
      await loopCtx.stopCapture();
    } catch (_) {}
  }

  @override
  Future<void> flushAndDispatch(Recorder rec) async {
    final pkts = await encoder.flush();
    for (final p in pkts) {
      await rec.dispatchPacket(this, p);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await micCtx.destroy();
    } catch (_) {}
    try {
      await loopCtx.destroy();
    } catch (_) {}
    try {
      await encoder.close();
    } catch (_) {}
  }

  @override
  TrackInfo toTrackInfo() => AudioTrackInfo(
    codec: audioCodec,
    sampleRate: _outSampleRate,
    channels: _outChannels,
  );

  @override
  FfmpegEncoderBridge? get encoderBridge {
    final p = encoder.platform;
    return p is FfmpegEncoderBridge ? p as FfmpegEncoderBridge : null;
  }

  @override
  TrackChunk toChunk(EncodedPacket pkt) {
    final isFirst = !_firstChunkSent;
    final extra = isFirst ? encoder.extraData?.bytes : null;
    _firstChunkSent = true;
    return TrackChunk(
      trackIndex: index,
      kind: TrackKind.audio,
      audioCodec: audioCodec,
      ptsUs: pkt.ptsUs,
      dtsUs: pkt.dtsUs,
      durationUs: pkt.durationUs,
      bytes: pkt.data,
      isKeyframe: true,
      extraData: extra,
      sampleRate: isFirst ? _outSampleRate : null,
      channels: isFirst ? _outChannels : null,
    );
  }
}

/// Minimal FIFO of interleaved stereo float32 samples, in **frames**
/// (1 frame = `_outChannels` samples).
class _MixerRing {
  final List<Float32List> _chunks = [];
  int _headOffset = 0; // sample offset into _chunks[0]
  int _totalSamples = 0;

  /// Frames currently buffered.
  int get frames => _totalSamples ~/ _MixedAudioTrackRuntime._outChannels;

  void add(Float32List samples) {
    if (samples.isEmpty) return;
    _chunks.add(samples);
    _totalSamples += samples.length;
  }

  /// Remove [frames] frames and return them as interleaved stereo f32.
  Float32List take(int frames) {
    final wanted = frames * _MixedAudioTrackRuntime._outChannels;
    final out = Float32List(wanted);
    var written = 0;
    while (written < wanted) {
      final head = _chunks[0];
      final available = head.length - _headOffset;
      final take = (wanted - written) < available
          ? (wanted - written)
          : available;
      out.setRange(written, written + take, head, _headOffset);
      written += take;
      _headOffset += take;
      _totalSamples -= take;
      if (_headOffset >= head.length) {
        _chunks.removeAt(0);
        _headOffset = 0;
      }
    }
    return out;
  }
}

// =========================================================================
// Sink runtime.
// =========================================================================

abstract class _SinkRuntime {
  Future<void> finish();
  Future<void> dispose();
}

class _FileSinkRuntime implements _SinkRuntime {
  _FileSinkRuntime({required this.muxer, required this.path})
    : _muxQueue = BoundedWriteQueue<EncodedPacket>(
        muxer.writePacket,
        maxDepth: 64,
        onError: (e, _, pkt) => Recorder._log(
          'mux write track=${pkt.trackIndex}: $e',
          RecorderLogLevel.error,
        ),
      );
  final FfmpegMuxer muxer;
  final String path;

  // Decoupled mux-write queue: [enqueuePacket] chains each encoded packet onto
  // a serial future and (in the common case) returns WITHOUT awaiting the libav
  // write, so the per-frame encode gate is no longer inflated by muxing —
  // video+audio muxing now overlaps the next encode instead of blocking it.
  // FIFO preserves per-track packet order (libav's interleaved writer handles
  // cross-track ordering by DTS); a sustained backlog applies back-pressure
  // rather than dropping already-encoded data.
  final BoundedWriteQueue<EncodedPacket> _muxQueue;

  /// Chains [packet] onto the async mux-write queue. Returns immediately unless
  /// the queue is full, in which case it awaits until a write frees space.
  Future<void> enqueuePacket(EncodedPacket packet) => _muxQueue.add(packet);

  @override
  Future<void> finish() async {
    // Drain every queued packet to the muxer BEFORE writing the trailer.
    await _muxQueue.drain();
    await muxer.finish();
  }

  @override
  Future<void> dispose() => muxer.close();
}

class _StreamSinkRuntime implements _SinkRuntime {
  _StreamSinkRuntime({required this.onChunk});
  final void Function(Object) onChunk;

  @override
  Future<void> finish() async {}

  @override
  Future<void> dispose() async {}
}

// =========================================================================
// RecorderGroup — synchronised multi-recorder controller.
// =========================================================================

/// Holds multiple [Recorder] instances and starts/stops them with a
/// synchronised master clock.
///
/// The [start] implementation runs the slow prepare phase of every recorder
/// concurrently (opens encoders, muxers, GPU devices), then starts all master
/// clocks and capture sources in a tight sequential loop to minimise clock
/// skew between recorders.
///
/// Build your [Recorder] instances via [RecorderBuilder], then pass them in:
///
/// ```dart
/// final avRec  = (RecorderBuilder()
///       ..addScreen()                   // platform default display
///       ..addLoopback(deviceId: loopDev)
///       ..addFileOutput('av.mp4'))
///     .build();
/// final micRec = (RecorderBuilder()
///       ..addMic(deviceId: micDev, codec: AudioCodec.aac)
///       ..addFileOutput('mic.m4a'))     // auto-picks Container.m4a
///     .build();
///
/// final group = RecorderGroup([avRec, micRec]);
/// await group.start();
/// await Future.delayed(const Duration(seconds: 10));
/// await group.stop();
/// ```
class RecorderGroup {
  /// The individual [Recorder] instances managed by this group.
  final List<Recorder> recorders;

  /// Create a group from already-built [Recorder] instances.
  const RecorderGroup(this.recorders);

  /// Prepare all recorders concurrently (opens encoders, muxers, GPU), then
  /// launch all master clocks + capture sources in quick succession.
  Future<void> start() async {
    await Future.wait(recorders.map((r) => r._prepare()));
    for (final r in recorders) {
      await r._launch();
    }
  }

  /// Stop all recorders concurrently.
  Future<void> stop() => Future.wait(recorders.map((r) => r.stop()));
}
