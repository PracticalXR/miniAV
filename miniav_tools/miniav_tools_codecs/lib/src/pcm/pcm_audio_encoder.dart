/// Pure-Dart raw-PCM encoder (pcmS16le / pcmF32le). No native code.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// Converts the delivered interleaved PCM (any [MiniAVAudioFormat]) into the
/// target little-endian raw-PCM byte layout. Stateless: one packet per call
/// (PCM is unframed), no header/extra-data.
class PcmAudioEncoder implements PlatformAudioEncoder {
  PcmAudioEncoder._(this._codec, this._channels);

  final AudioCodec _codec;
  final int _channels;

  /// Open a PCM encoder, or `null` if [config.codec] isn't a PCM codec.
  static Future<PcmAudioEncoder?> open(AudioEncoderConfig config) async {
    if (config.codec != AudioCodec.pcmS16le &&
        config.codec != AudioCodec.pcmF32le) {
      return null;
    }
    if (config.channels < 1) return null;
    return PcmAudioEncoder._(config.codec, config.channels);
  }

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    final n = frameCount * _channels;
    if (n <= 0) return const [];
    final srcF = _toFloat(pcm, format, n);

    final Uint8List out;
    if (_codec == AudioCodec.pcmF32le) {
      out = Uint8List(n * 4);
      final bd = ByteData.sublistView(out);
      for (var i = 0; i < n; i++) {
        bd.setFloat32(i * 4, srcF[i], Endian.little);
      }
    } else {
      out = Uint8List(n * 2);
      final bd = ByteData.sublistView(out);
      for (var i = 0; i < n; i++) {
        var s = (srcF[i] * 32767.0).round();
        if (s > 32767) {
          s = 32767;
        } else if (s < -32768) {
          s = -32768;
        }
        bd.setInt16(i * 2, s, Endian.little);
      }
    }
    return [EncodedPacket(data: out, ptsUs: ptsUs, dtsUs: ptsUs)];
  }

  /// Read [n] interleaved samples from [pcm] (described by [fmt]) as float in
  /// [-1, 1]. Short buffers are zero-extended (trailing silence).
  static Float32List _toFloat(Uint8List pcm, MiniAVAudioFormat fmt, int n) {
    final out = Float32List(n);
    final bd = ByteData.sublistView(pcm);
    switch (fmt) {
      case MiniAVAudioFormat.f32:
        final avail = pcm.lengthInBytes ~/ 4;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getFloat32(i * 4, Endian.little);
        }
      case MiniAVAudioFormat.s16:
        final avail = pcm.lengthInBytes ~/ 2;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
        }
      case MiniAVAudioFormat.s32:
        final avail = pcm.lengthInBytes ~/ 4;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt32(i * 4, Endian.little) / 2147483648.0;
        }
      case MiniAVAudioFormat.u8:
        final m = n < pcm.lengthInBytes ? n : pcm.lengthInBytes;
        for (var i = 0; i < m; i++) {
          out[i] = (pcm[i] - 128) / 128.0;
        }
      case MiniAVAudioFormat.unknown:
        break; // leave silence
    }
    return out;
  }

  @override
  Future<List<EncodedPacket>> flush() async => const [];

  @override
  CodecExtraData? get extraData => null;

  @override
  Future<void> close() async {}
}
