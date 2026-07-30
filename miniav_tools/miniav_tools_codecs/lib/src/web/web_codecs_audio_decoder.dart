/// WebCodecs-backed audio decoder.
///
/// Wraps the browser `AudioDecoder` (hand-rolled interop — `package:web` lacks
/// the audio WebCodecs types) and implements [PlatformAudioDecoder]. Each
/// packet decodes to `AudioData`, which is copied out as INTERLEAVED f32 (the
/// [DecodedAudio] layout the player's miniaudio `StreamPlayer` sink wants).
///
/// The browser `AudioDecoder` needs `sampleRate` + `numberOfChannels` at
/// configure time (WebCodecs does not derive them from the bitstream), so
/// [AudioDecoderConfig.sampleRate] / `.channels` are REQUIRED here — the
/// player supplies them from the container's audio-track info (or the app's
/// `AudioStreamSpec`). For AAC, `extraData` (AudioSpecificConfig) is passed as
/// the decoder `description`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'web_audio_interop.dart' as wc;
import 'web_backend.dart';

String _audioCodecString(AudioCodec codec, Map<String, String> opts) {
  if (opts.containsKey('codecString')) return opts['codecString']!;
  return switch (codec) {
    AudioCodec.aac => 'mp4a.40.2', // AAC-LC
    AudioCodec.opus => 'opus',
    AudioCodec.mp3 => 'mp3',
    AudioCodec.flac => 'flac',
    AudioCodec.vorbis => 'vorbis',
    _ => throw UnsupportedError('WebCodecs audio: no codec string for $codec'),
  };
}

class WebCodecsAudioDecoder implements PlatformAudioDecoder {
  WebCodecsAudioDecoder._();

  wc.AudioDecoder? _decoder;
  final List<DecodedAudio> _pending = [];
  Object? _lastError;

  void _handleData(JSAny? dataJs) {
    if (dataJs == null || dataJs.isUndefined) return;
    final data = dataJs as wc.AudioData;
    try {
      final frames = data.numberOfFrames;
      final channels = data.numberOfChannels;
      final sampleRate = data.sampleRate;
      // Copy out as a single INTERLEAVED f32 plane (WebCodecs converts from
      // the decoder's native planar/other format).
      final opts = wc.AudioDataCopyToOptions(planeIndex: 0, format: 'f32');
      final bytes = data.allocationSize(opts);
      final out = Float32List(bytes ~/ 4);
      data.copyTo(out.toJS, opts);
      _pending.add(
        DecodedAudio(
          samples: out,
          frameCount: frames,
          sampleRate: sampleRate,
          channels: channels,
          ptsUs: data.timestamp.toInt(),
        ),
      );
    } finally {
      data.close();
    }
  }

  void _handleError(JSAny? errJs) => _lastError = errJs;

  void _throwIfError() {
    final e = _lastError;
    if (e != null) {
      _lastError = null;
      throw CodecRuntimeException(WebCodecsBackend.backendName, e.toString());
    }
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _throwIfError();
    final dec = _decoder;
    if (dec == null) throw StateError('WebCodecsAudioDecoder: not open');
    final chunk = wc.EncodedAudioChunk(
      wc.EncodedAudioChunkInit(
        type: packet.isKeyframe ? 'key' : 'delta',
        timestamp: packet.ptsUs,
        data: packet.data.buffer.toJS,
      ),
    );
    dec.decode(chunk);
    // Let the output task run; return whatever decoded (0+).
    for (var i = 0; i < 16 && _pending.isEmpty && _lastError == null; i++) {
      if (dec.decodeQueueSize == 0 && i > 0) break;
      await Future<void>.delayed(Duration.zero);
    }
    _throwIfError();
    final out = List<DecodedAudio>.from(_pending);
    _pending.clear();
    return out;
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    final dec = _decoder;
    if (dec == null) return const [];
    await dec.flush().toDart;
    _throwIfError();
    final out = List<DecodedAudio>.from(_pending);
    _pending.clear();
    return out;
  }

  @override
  Future<void> close() async {
    try {
      _decoder?.close();
    } catch (_) {}
    _decoder = null;
    _pending.clear();
  }

  static Future<WebCodecsAudioDecoder> create(AudioDecoderConfig config) async {
    final sampleRate = config.sampleRate;
    final channels = config.channels;
    if (sampleRate == null || channels == null) {
      throw CodecInitException(
        WebCodecsBackend.backendName,
        'WebCodecs audio decode requires sampleRate + channels in '
        'AudioDecoderConfig (WebCodecs does not derive them from the '
        'bitstream). Got sampleRate=$sampleRate channels=$channels.',
      );
    }
    final dec = WebCodecsAudioDecoder._();
    final codecStr = _audioCodecString(config.codec, config.backendOptions);
    dec._decoder = wc.AudioDecoder(
      wc.AudioDecoderInit(
        output: (JSAny? d) {
          dec._handleData(d);
        }.toJS,
        error: (JSAny? e) {
          dec._handleError(e);
        }.toJS,
      ),
    );
    final extra = config.extraData;
    dec._decoder!.configure(
      wc.AudioDecoderConfig(
        codec: codecStr,
        sampleRate: sampleRate,
        numberOfChannels: channels,
        description: (extra != null && extra.isNotEmpty)
            ? Uint8List.fromList(extra).toJS
            : null,
      ),
    );
    dec._throwIfError();
    return dec;
  }
}
