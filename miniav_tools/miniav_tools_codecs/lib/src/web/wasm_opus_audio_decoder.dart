/// WASM libopus audio decoder (web) — the web twin of
/// `opus/opus_audio_decoder.dart`. Consumes bare Opus packets, honours the
/// config's rate/channel hints (or the OpusHead defaults 48 kHz / 2 ch), applies
/// the OpusHead pre-skip, and yields interleaved float32 PCM — decoding via
/// libopus compiled to WebAssembly ([CodecsWasm]) instead of dart:ffi. Opus
/// decode is deterministic per spec, so this is bit-exact with the native path.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'codecs_wasm.dart';

/// Opus decodes at most 120 ms per packet → 5760 samples per channel @ 48 kHz.
const int _kMaxFramesPerChannel = 5760;

class WasmOpusAudioDecoder implements PlatformAudioDecoder {
  WasmOpusAudioDecoder._(
    this._handle,
    this._sampleRate,
    this._channels,
    this._skipRemaining,
  );

  final int _handle;
  final int _sampleRate;
  final int _channels;
  int _skipRemaining;
  bool _closed = false;

  static Future<WasmOpusAudioDecoder?> open(AudioDecoderConfig config) async {
    if (config.codec != AudioCodec.opus) return null;
    final sampleRate = (config.sampleRate ?? 0) > 0 ? config.sampleRate! : 48000;
    var channels = (config.channels ?? 0) > 0 ? config.channels! : 2;
    var preSkip48k = 0;
    final extra = config.extraData;
    if (extra != null && extra.length >= 12 && _isOpusHead(extra)) {
      final ch = extra[9];
      if (ch == 1 || ch == 2) channels = ch;
      preSkip48k = extra[10] | (extra[11] << 8);
    }
    try {
      await CodecsWasm.instance.ensureLoaded();
    } catch (_) {
      return null; // wasm unavailable → facade falls through to WebCodecs
    }
    final handle = CodecsWasm.instance.createDecoder(sampleRate, channels);
    if (handle == 0) return null;
    final skipFrames = preSkip48k * sampleRate ~/ 48000;
    return WasmOpusAudioDecoder._(handle, sampleRate, channels, skipFrames);
  }

  static bool _isOpusHead(Uint8List d) =>
      d.length >= 8 &&
      d[0] == 0x4F &&
      d[1] == 0x70 &&
      d[2] == 0x75 &&
      d[3] == 0x73 &&
      d[4] == 0x48 &&
      d[5] == 0x65 &&
      d[6] == 0x61 &&
      d[7] == 0x64;

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _checkOpen();
    final data = packet.data;
    if (data.isEmpty) return const [];
    final pcm = CodecsWasm.instance
        .decode(_handle, data, _kMaxFramesPerChannel, _channels);
    final frames = pcm.length ~/ _channels;
    if (frames <= 0) return const [];

    var startFrame = 0;
    if (_skipRemaining > 0) {
      startFrame = _skipRemaining < frames ? _skipRemaining : frames;
      _skipRemaining -= startFrame;
      if (startFrame >= frames) return const []; // whole packet was priming
    }

    final outFrames = frames - startFrame;
    final n = outFrames * _channels;
    final samples = Float32List(n);
    samples.setRange(0, n, pcm, startFrame * _channels);
    return [
      DecodedAudio(
        samples: samples,
        frameCount: outFrames,
        sampleRate: _sampleRate,
        channels: _channels,
        ptsUs: packet.ptsUs,
      ),
    ];
  }

  @override
  Future<List<DecodedAudio>> flush() async => const [];

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    CodecsWasm.instance.destroyDecoder(_handle);
  }

  void _checkOpen() {
    if (_closed) throw StateError('WasmOpusAudioDecoder has been closed.');
  }
}
