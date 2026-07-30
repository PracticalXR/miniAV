/// First-party software audio decoders — MP3 (dr_mp3), FLAC (dr_flac), Vorbis
/// (stb_vorbis). All FFmpeg-free (public-domain single-header libs in the
/// codecs native asset).
///
/// These libraries own their own container/framing (a raw `.mp3`, a native
/// `.flac`, or an Ogg-wrapped Vorbis stream), so this decoder is a WHOLE-STREAM
/// decoder: it accumulates the compressed bytes across [decode] calls and
/// decodes them all on [flush]. Feed it the raw file bytes, then flush at EOF.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

class SwAudioDecoder implements PlatformAudioDecoder {
  SwAudioDecoder._(this._lib, this._codec);

  final SwAudioLib _lib;
  final AudioCodec _codec;
  final BytesBuilder _buf = BytesBuilder();
  bool _closed = false;

  static SwAudioLib? libFor(AudioCodec c) => switch (c) {
        AudioCodec.mp3 => SwAudioLib.mp3,
        AudioCodec.flac => SwAudioLib.flac,
        AudioCodec.vorbis => SwAudioLib.vorbis,
        _ => null,
      };

  static Future<SwAudioDecoder?> open(AudioDecoderConfig config) async {
    final lib = libFor(config.codec);
    if (lib == null) return null;
    return SwAudioDecoder._(lib, config.codec);
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _check();
    _buf.add(packet.data);
    return const [];
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    _check();
    final data = _buf.toBytes();
    _buf.clear();
    if (data.isEmpty) return const [];
    return _decodeAll(data);
  }

  List<DecodedAudio> _decodeAll(Uint8List data) {
    final inBuf = calloc<Uint8>(data.length);
    inBuf.asTypedList(data.length).setAll(0, data);
    final outPtr = calloc<Pointer<Float>>();
    final chPtr = calloc<Int32>();
    final ratePtr = calloc<Int32>();
    try {
      final frames = swDecode(_lib, inBuf, data.length, outPtr, chPtr, ratePtr);
      if (frames < 0) {
        throw CodecRuntimeException(_codec.name, 'SW decode failed');
      }
      final channels = chPtr.value;
      final rate = ratePtr.value;
      final buf = outPtr.value;
      final n = frames * channels;
      final samples = Float32List(n);
      if (n > 0 && buf != nullptr) {
        samples.setAll(0, buf.asTypedList(n));
      }
      if (buf != nullptr) swFree(buf.cast());
      if (frames == 0) return const [];
      return [
        DecodedAudio(
          samples: samples,
          frameCount: frames,
          sampleRate: rate,
          channels: channels,
          ptsUs: 0,
        ),
      ];
    } finally {
      calloc.free(inBuf);
      calloc.free(outPtr);
      calloc.free(chPtr);
      calloc.free(ratePtr);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _buf.clear();
  }

  void _check() {
    if (_closed) throw StateError('SwAudioDecoder has been closed.');
  }
}
