/// WebCodecs-backed audio encoder.
///
/// Wraps the browser `AudioEncoder` (hand-rolled interop — `package:web` lacks
/// the audio WebCodecs types) and implements [PlatformAudioEncoder]. Consumes
/// interleaved PCM (converted to f32 as needed), wraps it in an `AudioData`,
/// and emits [EncodedPacket]s. Codec-private extra-data (AAC ASC) is captured
/// from the first chunk's metadata for muxers / the decoder `description`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'web_audio_interop.dart' as wc;
import 'web_backend.dart';

String _audioCodecString(AudioCodec codec, Map<String, String> opts) {
  if (opts.containsKey('codecString')) return opts['codecString']!;
  return switch (codec) {
    AudioCodec.aac => 'mp4a.40.2',
    AudioCodec.opus => 'opus',
    AudioCodec.flac => 'flac',
    _ => throw UnsupportedError('WebCodecs audio: no codec string for $codec'),
  };
}

class WebCodecsAudioEncoder implements PlatformAudioEncoder {
  WebCodecsAudioEncoder._(this._codec, this._sampleRate, this._channels);

  final AudioCodec _codec;
  final int _sampleRate;
  final int _channels;
  wc.AudioEncoder? _encoder;
  final List<EncodedPacket> _pending = [];
  CodecExtraData? _extraData;
  Object? _lastError;

  @override
  CodecExtraData? get extraData => _extraData;

  void _handleChunk(JSAny? chunkJs, JSAny? metaJs) {
    if (chunkJs == null || chunkJs.isUndefined) return;
    final chunk = chunkJs as wc.EncodedAudioChunk;
    final bytes = Uint8List(chunk.byteLength);
    chunk.copyTo(bytes.buffer.toJS);

    if (_extraData == null && metaJs != null && !metaJs.isUndefined) {
      try {
        final meta = metaJs as JSObject;
        final dc = meta.getProperty<JSAny?>('decoderConfig'.toJS);
        if (dc != null && !dc.isUndefined) {
          final desc = (dc as JSObject).getProperty<JSAny?>('description'.toJS);
          if (desc != null && !desc.isUndefined) {
            final buf = (desc as JSArrayBuffer).toDart.asUint8List();
            if (buf.isNotEmpty) {
              _extraData = CodecExtraData.audio(
                _codec,
                Uint8List.fromList(buf),
              );
            }
          }
        }
      } catch (_) {
        // No metadata description in this browser — skip extraData.
      }
    }

    _pending.add(
      EncodedPacket(
        data: bytes,
        ptsUs: chunk.timestamp.toInt(),
        dtsUs: chunk.timestamp.toInt(),
        isKeyframe: chunk.type == 'key',
      ),
    );
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
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _throwIfError();
    final enc = _encoder;
    if (enc == null) throw StateError('WebCodecsAudioEncoder: not open');

    final f32 = _toF32(pcm, format, frameCount * _channels);
    final data = wc.AudioData(
      wc.AudioDataInit(
        format: 'f32',
        sampleRate: _sampleRate,
        numberOfFrames: frameCount,
        numberOfChannels: _channels,
        timestamp: ptsUs,
        data: f32.buffer.toJS,
      ),
    );
    enc.encode(data);
    data.close();
    // Do NOT flush per frame: flushing forces the Opus encoder to drain/reset
    // every 20ms, which emits undersized/non-standard packets (and mangles the
    // bitrate). Let the encoder emit on its own cadence via the output callback;
    // drain whatever packets have accumulated. A microtask turn lets the just-
    // queued output callback run. flush() is reserved for flush()/close()
    // (end-of-stream) below.
    await Future<void>.delayed(Duration.zero);
    _throwIfError();
    final out = List<EncodedPacket>.from(_pending);
    _pending.clear();
    return out;
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    final enc = _encoder;
    if (enc == null) return const [];
    await enc.flush().toDart;
    _throwIfError();
    final out = List<EncodedPacket>.from(_pending);
    _pending.clear();
    return out;
  }

  @override
  Future<void> close() async {
    try {
      _encoder?.close();
    } catch (_) {}
    _encoder = null;
    _pending.clear();
  }

  Float32List _toF32(Uint8List pcm, MiniAVAudioFormat format, int nSamples) {
    switch (format) {
      case MiniAVAudioFormat.f32:
        return Float32List.view(pcm.buffer, pcm.offsetInBytes, nSamples);
      case MiniAVAudioFormat.s16:
        final src = Int16List.view(pcm.buffer, pcm.offsetInBytes, nSamples);
        final out = Float32List(nSamples);
        for (var i = 0; i < nSamples; i++) {
          out[i] = src[i] / 32768.0;
        }
        return out;
      case MiniAVAudioFormat.s32:
        final src = Int32List.view(pcm.buffer, pcm.offsetInBytes, nSamples);
        final out = Float32List(nSamples);
        for (var i = 0; i < nSamples; i++) {
          out[i] = src[i] / 2147483648.0;
        }
        return out;
      case MiniAVAudioFormat.u8:
        final out = Float32List(nSamples);
        for (var i = 0; i < nSamples; i++) {
          out[i] = (pcm[i] - 128) / 128.0;
        }
        return out;
      default:
        throw CodecRuntimeException(
          WebCodecsBackend.backendName,
          'unsupported PCM format $format',
        );
    }
  }

  static Future<WebCodecsAudioEncoder> create(AudioEncoderConfig config) async {
    final enc = WebCodecsAudioEncoder._(
      config.codec,
      config.sampleRate,
      config.channels,
    );
    final codecStr = _audioCodecString(config.codec, config.backendOptions);
    enc._encoder = wc.AudioEncoder(
      wc.AudioEncoderInit(
        output: (JSAny? chunk, JSAny? meta) {
          enc._handleChunk(chunk, meta);
        }.toJS,
        error: (JSAny? e) {
          enc._handleError(e);
        }.toJS,
      ),
    );
    enc._encoder!.configure(
      wc.AudioEncoderConfig(
        codec: codecStr,
        sampleRate: config.sampleRate,
        numberOfChannels: config.channels,
        bitrate: config.bitrateBps,
      ),
    );
    enc._throwIfError();
    return enc;
  }
}
