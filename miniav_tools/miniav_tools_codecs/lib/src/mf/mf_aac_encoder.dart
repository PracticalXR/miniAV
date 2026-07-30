/// Media Foundation AAC encoder (Windows) — FFmpeg-free, via the OS AAC
/// encoder MFT. Consumes interleaved PCM, emits raw AAC access units + an
/// AudioSpecificConfig ([extraData]) for MP4/ADTS framing.
///
/// MF requires the MTA; on an STA thread (Flutter UI) `open` returns `null` so
/// the negotiator falls back to FFmpeg (an MTA-isolate host is a follow-up,
/// mirroring the video decoder).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

class MfAacEncoder implements PlatformAudioEncoder {
  MfAacEncoder._(this._handle, this._channels, this._extra);

  final Pointer<Void> _handle;
  final int _channels;
  final CodecExtraData? _extra;
  bool _closed = false;

  static Future<MfAacEncoder?> open(AudioEncoderConfig config) async {
    if (!Platform.isWindows || config.codec != AudioCodec.aac) return null;
    final ch = config.channels;
    if (ch < 1 || ch > 2) return null;
    Pointer<Void> h = nullptr;
    try {
      if (mfaacEncHasMft() == 0) return null;
      h = mfaacEncCreate(
        config.sampleRate,
        ch,
        config.bitrateBps > 0 ? config.bitrateBps : 128000,
      );
    } catch (_) {
      return null;
    }
    if (h == nullptr) return null;

    CodecExtraData? extra;
    final ascBuf = calloc<Uint8>(64);
    try {
      final n = mfaacEncGetAsc(h, ascBuf, 64);
      if (n > 0) {
        extra = CodecExtraData.audio(
          AudioCodec.aac,
          Uint8List.fromList(ascBuf.asTypedList(n)),
        );
      }
    } finally {
      calloc.free(ascBuf);
    }
    return MfAacEncoder._(h, ch, extra);
  }

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _check();
    final n = frameCount * _channels;
    if (n <= 0) return const [];
    final f32 = _toFloat(pcm, format, n);
    final inBuf = calloc<Float>(n);
    inBuf.asTypedList(n).setAll(0, f32);
    try {
      final out = <EncodedPacket>[];
      var r = mfaacEncSend(_handle, inBuf, frameCount, ptsUs);
      if (r == 1) {
        out.addAll(_drain());
        r = mfaacEncSend(_handle, inBuf, frameCount, ptsUs);
      }
      if (r < 0) {
        throw const CodecRuntimeException('mf_aac', 'encode ProcessInput failed');
      }
      out.addAll(_drain());
      return out;
    } finally {
      calloc.free(inBuf);
    }
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _check();
    mfaacEncDrain(_handle);
    return _drain();
  }

  List<EncodedPacket> _drain() {
    final out = <EncodedPacket>[];
    final frame = calloc<MfAacEncFrame>();
    try {
      while (true) {
        final r = mfaacEncReceive(_handle, frame);
        if (r <= 0) break;
        final f = frame.ref;
        if (f.aacSize <= 0 || f.aacData == nullptr) break;
        final data = Uint8List.fromList(f.aacData.asTypedList(f.aacSize));
        mfaacFree(f.aacData.cast());
        out.add(EncodedPacket(data: data, ptsUs: f.ptsUs, dtsUs: f.ptsUs));
      }
    } finally {
      calloc.free(frame);
    }
    return out;
  }

  @override
  CodecExtraData? get extraData => _extra;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    mfaacEncDestroy(_handle);
  }

  void _check() {
    if (_closed) throw StateError('MfAacEncoder has been closed.');
  }

  Float32List _toFloat(Uint8List pcm, MiniAVAudioFormat fmt, int n) {
    final out = Float32List(n);
    final bd = ByteData.sublistView(pcm);
    switch (fmt) {
      case MiniAVAudioFormat.f32:
        final m = (pcm.lengthInBytes ~/ 4).clamp(0, n);
        for (var i = 0; i < m; i++) {
          out[i] = bd.getFloat32(i * 4, Endian.little);
        }
      case MiniAVAudioFormat.s16:
        final m = (pcm.lengthInBytes ~/ 2).clamp(0, n);
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
        }
      case MiniAVAudioFormat.s32:
        final m = (pcm.lengthInBytes ~/ 4).clamp(0, n);
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt32(i * 4, Endian.little) / 2147483648.0;
        }
      case MiniAVAudioFormat.u8:
        final m = pcm.lengthInBytes.clamp(0, n);
        for (var i = 0; i < m; i++) {
          out[i] = (pcm[i] - 128) / 128.0;
        }
      case MiniAVAudioFormat.unknown:
        break;
    }
    return out;
  }
}
