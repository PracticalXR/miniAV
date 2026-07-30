/// Media Foundation AAC decoder (Windows) — FFmpeg-free, via the OS AAC decoder
/// MFT. Consumes raw AAC access units (ADTS headers stripped by the demuxer) +
/// an AudioSpecificConfig (from the container's esds / the ADTS demuxer), emits
/// interleaved float32 PCM.
///
/// Needs the MTA (like the encoder) — `open` returns `null` on an STA thread so
/// the negotiator falls back to FFmpeg.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

class MfAacDecoder implements PlatformAudioDecoder {
  MfAacDecoder._(this._handle);

  final Pointer<Void> _handle;
  bool _closed = false;

  static Future<MfAacDecoder?> open(AudioDecoderConfig config) async {
    if (!Platform.isWindows || config.codec != AudioCodec.aac) return null;
    final asc = config.extraData;
    if (asc == null || asc.length < 2) return null; // MF needs the ASC
    final sampleRate = (config.sampleRate ?? 0) > 0 ? config.sampleRate! : 48000;
    final channels = (config.channels ?? 0) > 0 ? config.channels! : 2;

    final ascBuf = calloc<Uint8>(asc.length);
    ascBuf.asTypedList(asc.length).setAll(0, asc);
    Pointer<Void> h = nullptr;
    try {
      if (mfaacDecHasMft() == 0) return null;
      h = mfaacDecCreate(ascBuf, asc.length, sampleRate, channels);
    } catch (_) {
      return null;
    } finally {
      calloc.free(ascBuf);
    }
    if (h == nullptr) return null;
    return MfAacDecoder._(h);
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _check();
    final data = packet.data;
    if (data.isEmpty) return const [];
    final inBuf = calloc<Uint8>(data.length);
    inBuf.asTypedList(data.length).setAll(0, data);
    try {
      final out = <DecodedAudio>[];
      var r = mfaacDecSend(_handle, inBuf, data.length, packet.ptsUs);
      if (r == 1) {
        // MFT is full — drain, then retry the input once.
        out.addAll(_drain());
        r = mfaacDecSend(_handle, inBuf, data.length, packet.ptsUs);
      }
      if (r < 0) {
        throw const CodecRuntimeException('mf_aac', 'decode ProcessInput failed');
      }
      out.addAll(_drain());
      return out;
    } finally {
      calloc.free(inBuf);
    }
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    _check();
    mfaacDecDrain(_handle);
    return _drain();
  }

  List<DecodedAudio> _drain() {
    final out = <DecodedAudio>[];
    final frame = calloc<MfAacDecFrame>();
    try {
      while (true) {
        final r = mfaacDecReceive(_handle, frame);
        if (r == 2) continue; // stream change — reconfigured, keep draining
        if (r != 1) break; // 0 = need more input, <0 = error
        final f = frame.ref;
        if (f.pcmSize <= 0 || f.pcmData == nullptr) break;
        final floats = f.pcmData.cast<Float>().asTypedList(f.pcmSize ~/ 4);
        final samples = Float32List(floats.length)..setAll(0, floats);
        mfaacFree(f.pcmData.cast());
        out.add(DecodedAudio(
          samples: samples,
          frameCount: f.sampleCount,
          sampleRate: f.sampleRate,
          channels: f.channels,
          ptsUs: f.ptsUs,
        ));
      }
    } finally {
      calloc.free(frame);
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    mfaacDecDestroy(_handle);
  }

  void _check() {
    if (_closed) throw StateError('MfAacDecoder has been closed.');
  }
}
