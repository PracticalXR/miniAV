/// WebCodecs (+ MSE fallback) codec backend for miniav_tools — browser only.
///
/// This is the web half of `miniav_tools_codecs`, kept as a separate entry so
/// web apps register the WebCodecs backend WITHOUT pulling in the minigpu
/// GPU-compute codecs (import `package:miniav_tools_codecs/miniav_tools_codecs.dart`
/// for those). Import this only on web (behind a `dart.library.js_interop`
/// conditional import) — it uses `dart:js_interop` / `package:web`.
///
/// Wraps `VideoEncoder` / `VideoDecoder` / `AudioEncoder` / `AudioDecoder` and
/// provides a [MediaRecorderCapture] fallback for browsers lacking WebCodecs.
///
/// Also registers the pure-Dart [ContainerFramingBackend] (WAV/Ogg/ADTS/MP4/M4A
/// demux+mux) — it has NO `dart:ffi`/`dart:io`, so it is web-safe. This is what
/// lets `openSource(MediaSource.bytes(mp4))` demux a container in the browser
/// and feed the WebCodecs decoders; without it, container playback on web had
/// no demuxer to fall through to (there is no FFmpeg on web).
library;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
// Platform-neutral colour conversion (pure Dart — the web pixel path).
export 'convert.dart'
    show
        YuvRgbCoeffs,
        RgbaYuvCoeffs,
        I420Planes,
        dartI420ToRgba,
        dartI420ToRgbaAsync,
        dartI422ToRgba,
        dartRgbaToI420,
        dartRgbaToI420Async;
export 'src/framing/container_backend.dart' show ContainerFramingBackend;
export 'src/web/media_recorder_fallback.dart' show MediaRecorderCapture;
export 'src/web/wasm_opus_backend.dart' show WasmOpusBackend;
export 'src/web/web_backend.dart' show WebCodecsBackend;
export 'src/web/web_capability.dart' show WebCapability;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'src/framing/container_backend.dart';
import 'src/web/wasm_opus_backend.dart';
import 'src/web/web_backend.dart';

// ignore: unused_element
final _registered = _register();

bool _register() {
  final reg = MiniAVToolsPlatform.instance;
  final have = reg.backends.map((b) => b.name).toSet();
  var registered = false;
  // WASM libopus (priority 90) — preferred over WebCodecs for Opus so web ↔
  // native Opus interop is byte-identical (same libopus). Falls back to
  // WebCodecs if the wasm module can't load.
  if (!have.contains(WasmOpusBackend.backendName)) {
    reg.register(WasmOpusBackend());
    registered = true;
  }
  if (!have.contains(WebCodecsBackend.backendName)) {
    reg.register(WebCodecsBackend());
    registered = true;
  }
  // Pure-Dart container demux/mux (web-safe) so web can parse MP4/WAV/Ogg/ADTS
  // bytes into EncodedPackets for the WebCodecs decoders.
  if (!have.contains(ContainerFramingBackend.backendName)) {
    reg.register(ContainerFramingBackend());
    registered = true;
  }
  return registered;
}

/// Forces the WebCodecs backend registration to run. Call once at startup if
/// you need it registered before any other call touches the tools registry.
// ignore: unused_element
void ensureInitialized() => _registered;
