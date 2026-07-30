/// Decoded-PCM playback sink via miniav's first-party audio output module
/// (miniaudio — FFI on native, WASM on web). Replaces the external
/// `miniaudio_dart` dependency with `MiniAudioOutput`, so the player's sink is
/// the same code path on every platform.
///
/// Lazily initialises to the stream format reported by the FIRST decoded
/// chunk (the decoder, not the config, is the source of truth for sample
/// rate / channels). Drift control is queue-depth based: [MiniAudioOutputContext.writeFrames]
/// accepting fewer frames than offered means the ring is full — the tail is
/// dropped and counted, and the caller may re-anchor the clock.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:miniav/miniav.dart';
import 'package:miniav_tools/miniav_tools.dart' show DecodedAudio;

class PlayerAudioOutput {
  PlayerAudioOutput({this.bufferMs = 120});

  /// Target ring depth of the underlying sink, in milliseconds.
  final int bufferMs;

  MiniAudioOutputContext? _ctx;
  bool _disposed = false;

  int _sampleRate = 0;
  int _channels = 0;
  double _pendingVolume = 1.0;

  // --- stats -----------------------------------------------------------------
  int writtenFrames = 0;
  int droppedFrames = 0;
  int formatMismatchChunks = 0;

  /// pts of the sample most recently accepted into the ring, µs (or null
  /// before the first write). `pts + accepted duration`.
  int? lastWrittenEndPtsUs;

  bool get isInitialized => _ctx != null;
  int get sampleRate => _sampleRate;
  int get channels => _channels;

  double get volume => _ctx?.volume ?? _pendingVolume;
  set volume(double v) {
    _pendingVolume = v;
    _ctx?.volume = v;
  }

  /// Lazily init/validate the device stream against [chunk]'s format.
  /// Returns false when the chunk cannot be played (format change).
  Future<bool> _ensureFor(DecodedAudio chunk) async {
    if (_disposed) return false;
    if (_ctx == null) {
      _sampleRate = chunk.sampleRate;
      _channels = chunk.channels;
      final bufferFrames = (bufferMs * _sampleRate / 1000).round();
      final ctx = await MiniAudioOutput.createContext();
      await ctx.configure(
        '', // default output device
        MiniAVAudioInfo(
          format: MiniAVAudioFormat.f32,
          sampleRate: _sampleRate,
          channels: _channels,
          numFrames: 0,
        ),
        bufferFrames: bufferFrames,
      );
      ctx.volume = _pendingVolume;
      await ctx.start();
      // A dispose() may have raced the awaits above.
      if (_disposed) {
        await ctx.destroy();
        return false;
      }
      _ctx = ctx;
      return true;
    }
    if (chunk.sampleRate != _sampleRate || chunk.channels != _channels) {
      // Mid-stream format changes are rare (codec reconfig); resampling is
      // out of scope here — count and skip so a/v keeps running.
      formatMismatchChunks++;
      return false;
    }
    return true;
  }

  /// Feed one decoded chunk (LIVE mode). Returns the number of frames
  /// actually accepted (== chunk.frameCount unless the ring overflowed —
  /// in live mode dropping beats adding latency).
  Future<int> write(DecodedAudio chunk) async {
    if (!await _ensureFor(chunk)) return 0;
    final accepted = _ctx!.writeFrames(chunk.samples, chunk.frameCount);
    writtenFrames += accepted;
    if (accepted < chunk.frameCount) {
      droppedFrames += chunk.frameCount - accepted;
    }
    lastWrittenEndPtsUs =
        chunk.ptsUs + (accepted * 1000000) ~/ chunk.sampleRate;
    return accepted;
  }

  /// Feed one decoded chunk (PACED/VOD mode): never drops — when the ring
  /// is full it WAITS for the device to consume, which is the natural
  /// decode-ahead throttle for source-driven playback. [shouldAbort] breaks
  /// the wait (pause/seek/close).
  Future<void> writePaced(
    DecodedAudio chunk, {
    required bool Function() shouldAbort,
  }) async {
    if (!await _ensureFor(chunk)) return;
    var offsetFrames = 0;
    while (offsetFrames < chunk.frameCount) {
      if (_disposed || shouldAbort()) return;
      final remaining = chunk.frameCount - offsetFrames;
      final view = offsetFrames == 0
          ? chunk.samples
          : Float32List.sublistView(chunk.samples, offsetFrames * _channels);
      final accepted = _ctx!.writeFrames(view, remaining);
      if (accepted > 0) {
        writtenFrames += accepted;
        offsetFrames += accepted;
        lastWrittenEndPtsUs =
            chunk.ptsUs + (offsetFrames * 1000000) ~/ chunk.sampleRate;
      } else {
        // Ring full: ~one device period of patience.
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    }
  }

  /// Convenience for flush(): feed every trailing chunk.
  Future<void> writeAll(List<DecodedAudio> chunks) async {
    for (final c in chunks) {
      await write(c);
    }
  }

  /// Drop queued-but-unplayed samples (flush/seek).
  void clear() {
    final f = _ctx?.clear();
    if (f != null) unawaited(f);
  }

  /// Halt the device stream (queued samples stay buffered).
  void pause() {
    final f = _ctx?.stop();
    if (f != null) unawaited(f);
  }

  /// Restart the device stream after [pause].
  void resume() {
    final f = _ctx?.start();
    if (f != null) unawaited(f);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ctx = _ctx;
    _ctx = null;
    if (ctx != null) unawaited(ctx.destroy());
  }
}
