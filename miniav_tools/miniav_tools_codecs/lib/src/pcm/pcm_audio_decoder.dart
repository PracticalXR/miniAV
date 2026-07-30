/// Pure-Dart raw-PCM decoder (pcmS16le / pcmF32le). No native code.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// Decodes raw interleaved little-endian PCM into the canonical interleaved
/// float32 [DecodedAudio] layout every consumer here accepts.
///
/// Raw PCM carries no header, so sample rate + channel count come from the
/// [AudioDecoderConfig] — a container demuxer (WAV, …) supplies them via its
/// `TrackInfo`. Reads via [ByteData] with an explicit [Endian.little] so the
/// result is correct regardless of host endianness or byte alignment.
class PcmAudioDecoder implements PlatformAudioDecoder {
  PcmAudioDecoder._(this._codec, this._sampleRate, this._channels);

  final AudioCodec _codec;
  final int _sampleRate;
  final int _channels;

  /// Open a PCM decoder, or `null` if [config.codec] isn't a PCM codec.
  static Future<PcmAudioDecoder?> open(AudioDecoderConfig config) async {
    if (config.codec != AudioCodec.pcmS16le &&
        config.codec != AudioCodec.pcmF32le) {
      return null;
    }
    final channels = config.channels ?? 2;
    final sampleRate = config.sampleRate ?? 48000;
    if (channels < 1) return null;
    return PcmAudioDecoder._(config.codec, sampleRate, channels);
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    final bytes = packet.data;
    if (bytes.isEmpty) return const [];
    final bd = ByteData.sublistView(bytes);

    final Float32List samples;
    if (_codec == AudioCodec.pcmF32le) {
      final n = bytes.lengthInBytes ~/ 4;
      samples = Float32List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = bd.getFloat32(i * 4, Endian.little);
      }
    } else {
      final n = bytes.lengthInBytes ~/ 2;
      samples = Float32List(n);
      for (var i = 0; i < n; i++) {
        samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
    }

    final frameCount = samples.length ~/ _channels;
    if (frameCount == 0) return const [];
    return [
      DecodedAudio(
        samples: samples,
        frameCount: frameCount,
        sampleRate: _sampleRate,
        channels: _channels,
        ptsUs: packet.ptsUs,
      ),
    ];
  }

  @override
  Future<List<DecodedAudio>> flush() async => const []; // stateless

  @override
  Future<void> close() async {}
}
