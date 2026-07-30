/// Low-level bindings to the miniav WASM module (miniaudio compiled to
/// WebAssembly via Emscripten).
///
/// The Emscripten glue is a non-MODULARIZE build that installs a global
/// `Module`, so `@JS('Module')` externs reach the exported C functions
/// (`Module._MiniAV_*`) and the heap views (`Module.HEAPF32`). This mirrors the
/// proven minigpu_web pattern. The module is loaded lazily by injecting the
/// generated `miniav_web.js` asset and awaiting `Module.onRuntimeInitialized`
/// — no host `index.html` changes required.
@JS('Module')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// --- Heap + allocator (Module.*) -------------------------------------------
@JS('_malloc')
external int _malloc(int size);
@JS('_free')
external void _free(int ptr);
@JS('HEAPF32')
external JSFloat32Array get _heapf32;

// --- Audio output (playback) exports ---------------------------------------
@JS('_MiniAV_AudioOutput_CreateContext')
external int _aoCreate();
@JS('_MiniAV_AudioOutput_DestroyContext')
external int _aoDestroy(int ctx);
// AudioOutput_Configure + AudioOutput_Start suspend under ASYNCIFY (device /
// worklet init), so they are called via ccall{async:true} — see the class.
@JS('_MiniAV_AudioOutput_Stop')
external int _aoStop(int ctx);
@JS('_MiniAV_AudioOutput_Clear')
external int _aoClear(int ctx);
@JS('_MiniAV_AudioOutput_WriteFrames')
external int _aoWriteFrames(int ctx, int ptr, int frameCount);
@JS('_MiniAV_AudioOutput_GetBufferedFrames')
external int _aoGetBufferedFrames(int ctx);
@JS('_MiniAV_AudioOutput_GetWritableFrames')
external int _aoGetWritableFrames(int ctx);
@JS('_MiniAV_AudioOutput_SetVolume')
external int _aoSetVolume(int ctx, double v);
@JS('_MiniAV_AudioOutput_GetVolume')
external double _aoGetVolume(int ctx);
@JS('_MiniAV_AudioOutput_SetPan')
external int _aoSetPan(int ctx, double v);
@JS('_MiniAV_AudioOutput_GetPan')
external double _aoGetPan(int ctx);
@JS('_MiniAV_AudioOutput_SetPitch')
external int _aoSetPitch(int ctx, double v);
@JS('_MiniAV_AudioOutput_GetPitch')
external double _aoGetPitch(int ctx);
@JS('_MiniAV_AudioOutput_IsStarted')
external int _aoIsStarted(int ctx);

// --- Audio input (buffered / pull capture) exports -------------------------
@JS('_MiniAV_Audio_CreateContextRet')
external int _aiCreate();
@JS('_MiniAV_Audio_DestroyContext')
external int _aiDestroy(int ctx);
@JS('_MiniAV_Audio_ConfigureFlat')
external int _aiConfigure(
  int ctx,
  int format,
  int sampleRate,
  int channels,
  int numFrames,
);
@JS('_MiniAV_Audio_EnableBufferedCapture')
external int _aiEnableBuffered(int ctx, int ringFrames);
// StartCapture suspends under ASYNCIFY (miniaudio device init spins on
// emscripten_sleep until the AudioWorklet thread is up), so it is called via
// ccall{async:true} — see the class.
@JS('_MiniAV_Audio_StopCapture')
external int _aiStop(int ctx);
@JS('_MiniAV_Audio_ReadFrames')
external int _aiReadFrames(int ctx, int outPtr, int maxFrames);
@JS('_MiniAV_Audio_GetAvailableFrames')
external int _aiGetAvailable(int ctx);

const int kSuccess = 0; // MINIAV_SUCCESS

/// Public façade over the raw externs. Instances are cheap; the underlying
/// WASM module is a process-wide singleton loaded once via [ensureLoaded].
class MiniavWasm {
  MiniavWasm._();
  static final MiniavWasm instance = MiniavWasm._();

  static bool _ready = false;
  static Future<void>? _loading;

  /// Path to the emscripten glue asset (bundled by this package).
  static const _glueUrl = 'assets/packages/miniav_web/web/miniav_web.js';

  /// Load the WASM module once. Safe to await repeatedly.
  Future<void> ensureLoaded() {
    if (_ready) return Future<void>.value();
    return _loading ??= _load();
  }

  bool get isReady => _ready;

  Future<void> _load() async {
    final completer = Completer<void>();
    final g = globalContext;

    // Pre-seed a global `Module` with our onRuntimeInitialized before the glue
    // runs (non-MODULARIZE emscripten reuses a pre-existing Module).
    var mod = g.getProperty<JSObject?>('Module'.toJS);
    if (mod == null) {
      mod = JSObject();
      g.setProperty('Module'.toJS, mod);
    }

    // If the runtime already ran (e.g. host page loaded the glue), resolve now.
    final calledRun = mod.getProperty<JSAny?>('calledRun'.toJS);
    if (calledRun != null &&
        calledRun.isA<JSBoolean>() &&
        (calledRun as JSBoolean).toDart) {
      _ready = true;
      return;
    }

    mod.setProperty(
      'onRuntimeInitialized'.toJS,
      (() {
        if (!completer.isCompleted) completer.complete();
      }).toJS,
    );

    // Avoid injecting the glue twice if another caller already did.
    if (g.getProperty<JSAny?>('_miniavGlueInjected'.toJS).isUndefinedOrNull) {
      g.setProperty('_miniavGlueInjected'.toJS, true.toJS);
      final script = web.HTMLScriptElement()
        ..src = _glueUrl
        ..async = true;
      script.onerror = ((JSAny _) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Failed to load $_glueUrl'));
        }
      }).toJS;
      web.document.head!.appendChild(script);
    }

    await completer.future;
    _ready = true;
  }

  // Invoke a C function via ccall in ASYNCIFY-async mode: an ASYNCIFY-suspending
  // export returns a Promise (not the int result) when called directly, so
  // device-init/start calls MUST go through ccall({async:true}) and be awaited.
  Future<int> _ccallAsync(String name, List<String> argTypes, List<int> args) {
    final module = globalContext.getProperty<JSObject>('Module'.toJS);
    final p = module.callMethodVarArgs<JSPromise<JSAny?>>('ccall'.toJS, <JSAny?>[
      name.toJS,
      'number'.toJS,
      argTypes.jsify(),
      args.jsify(),
      <String, Object?>{'async': true}.jsify(),
    ]);
    return p.toDart.then((r) => (r as JSNumber).toDartInt);
  }

  // --- Output context ------------------------------------------------------
  int createOutput() => _aoCreate();
  int destroyOutput(int ctx) => _aoDestroy(ctx);

  /// Configure the default output device. `deviceId` selection is not exposed
  /// on web (browsers route to the default output), so a null id is passed.
  /// ASYNC: ma_engine_init spins up the AudioWorklet thread (suspends).
  Future<int> configureOutput(int ctx, int format, int sampleRate, int channels,
          int bufferFrames) =>
      _ccallAsync(
        'MiniAV_AudioOutput_Configure',
        const ['number', 'number', 'number', 'number', 'number', 'number'],
        [ctx, 0, format, sampleRate, channels, bufferFrames],
      );

  /// ASYNC (defensive): ma_engine_start may resume/suspend the worklet device.
  Future<int> startOutput(int ctx) => _ccallAsync(
        'MiniAV_AudioOutput_Start',
        const ['number'],
        [ctx],
      );

  int stopOutput(int ctx) => _aoStop(ctx);
  int clearOutput(int ctx) => _aoClear(ctx);
  int bufferedFrames(int ctx) => _aoGetBufferedFrames(ctx);
  int writableFrames(int ctx) => _aoGetWritableFrames(ctx);
  void setVolume(int ctx, double v) => _aoSetVolume(ctx, v);
  double getVolume(int ctx) => _aoGetVolume(ctx);
  void setPan(int ctx, double v) => _aoSetPan(ctx, v);
  double getPan(int ctx) => _aoGetPan(ctx);
  void setPitch(int ctx, double v) => _aoSetPitch(ctx, v);
  double getPitch(int ctx) => _aoGetPitch(ctx);
  bool isStarted(int ctx) => _aoIsStarted(ctx) != 0;

  // Reusable heap scratch for PCM writes (grows as needed).
  int _scratchPtr = 0;
  int _scratchFloats = 0;

  /// Copy interleaved f32 PCM into the WASM heap and push it. Returns frames
  /// accepted (may be < [frameCount] when the ring is full).
  int writeFrames(int ctx, Float32List interleaved, int frameCount,
      int channels) {
    final ch = channels <= 0 ? 1 : channels;
    var floats = frameCount * ch;
    if (floats <= 0) return 0;
    if (floats > interleaved.length) floats = interleaved.length;
    final frames = floats ~/ ch;
    if (frames <= 0) return 0;

    if (_scratchFloats < floats) {
      if (_scratchPtr != 0) _free(_scratchPtr);
      _scratchPtr = _malloc(floats * 4);
      _scratchFloats = floats;
    }
    // Re-fetch the heap view each call — memory growth detaches old views.
    final heap = _heapf32.toDart;
    final base = _scratchPtr >> 2;
    heap.setRange(base, base + floats, interleaved);
    return _aoWriteFrames(ctx, _scratchPtr, frames);
  }

  // --- Input context (buffered / pull capture) ----------------------------
  int createInput() => _aiCreate();
  int destroyInput(int ctx) => _aiDestroy(ctx);
  int configureInput(
    int ctx,
    int format,
    int sampleRate,
    int channels,
    int numFrames,
  ) =>
      _aiConfigure(ctx, format, sampleRate, channels, numFrames);
  int enableBufferedCapture(int ctx, int ringFrames) =>
      _aiEnableBuffered(ctx, ringFrames);

  /// Start buffered capture. Passes a NULL Dart callback (0) — captured PCM
  /// lands in the C ring and is drained via [readCaptureFrames].
  /// ASYNC: miniaudio device init suspends until the AudioWorklet thread is up.
  Future<int> startCapture(int ctx) => _ccallAsync(
        'MiniAV_Audio_StartCapture',
        const ['number', 'number', 'number'],
        [ctx, 0, 0],
      );
  int stopCapture(int ctx) => _aiStop(ctx);
  int availableCaptureFrames(int ctx) => _aiGetAvailable(ctx);

  // Reusable heap scratch for capture reads (grows as needed).
  int _readPtr = 0;
  int _readFloats = 0;

  /// Drain up to [maxFrames] interleaved f32 frames from the capture ring.
  /// Returns a fresh Float32List of length framesRead * channels (empty if
  /// nothing was available).
  Float32List readCaptureFrames(int ctx, int maxFrames, int channels) {
    final ch = channels <= 0 ? 1 : channels;
    final floats = maxFrames * ch;
    if (floats <= 0) return Float32List(0);
    if (_readFloats < floats) {
      if (_readPtr != 0) _free(_readPtr);
      _readPtr = _malloc(floats * 4);
      _readFloats = floats;
    }
    final n = _aiReadFrames(ctx, _readPtr, maxFrames); // frames read
    if (n <= 0) return Float32List(0);
    // Re-fetch the heap view — memory growth detaches old views.
    final heap = _heapf32.toDart;
    final base = _readPtr >> 2;
    return Float32List.fromList(heap.sublist(base, base + n * ch));
  }
}
