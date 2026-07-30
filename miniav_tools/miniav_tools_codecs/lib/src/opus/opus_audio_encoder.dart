/// First-party libopus audio encoder — FFmpeg-free.
///
/// Wraps the `miniav_opus_enc_*` native functions (libopus, static-linked into
/// the codecs native asset). Buffers the delivered interleaved PCM into fixed
/// 20 ms Opus frames, encodes each with `opus_encode_float`, and emits bare
/// Opus packets + an `OpusHead` [extraData] — the same shape the FFmpeg libopus
/// path produced, with zero FFmpeg in the process.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

/// Max compressed bytes for one Opus frame (libopus recommends 4000).
const int _kMaxPacketBytes = 4000;

class OpusAudioEncoder implements PlatformAudioEncoder {
  OpusAudioEncoder._(this._handle, this._sampleRate, this._channels)
    : _frameSamplesPerCh = _sampleRate ~/ 50, // 20 ms frames
      _leftover = Float32List((_sampleRate ~/ 50) * _channels),
      _in = calloc<Float>((_sampleRate ~/ 50) * _channels),
      _out = calloc<Uint8>(_kMaxPacketBytes) {
    _frameSamplesTotal = _frameSamplesPerCh * _channels;
    _extraData = CodecExtraData.audio(
      AudioCodec.opus,
      _buildOpusHead(_channels, _sampleRate),
    );
  }

  final Pointer<Void> _handle;
  final int _sampleRate;
  final int _channels;
  final int _frameSamplesPerCh;
  late final int _frameSamplesTotal;

  final Float32List _leftover; // < one full frame of carry-over samples
  int _leftoverLen = 0;
  final Pointer<Float> _in;
  final Pointer<Uint8> _out;
  late final CodecExtraData _extraData;

  int _basePtsUs = 0;
  bool _havePts = false;
  int _framesEmitted = 0; // per-channel frames encoded so far
  bool _closed = false;

  /// Open an Opus encoder, or `null` if the codec isn't Opus / libopus rejects
  /// the rate or channels (→ the facade falls through to the next backend).
  static Future<OpusAudioEncoder?> open(AudioEncoderConfig config) async {
    if (config.codec != AudioCodec.opus) return null;
    final sampleRate = config.sampleRate > 0 ? config.sampleRate : 48000;
    final channels = config.channels >= 1 && config.channels <= 2
        ? config.channels
        : 2;
    // Opus only encodes at 8/12/16/24/48 kHz; libopus accepts these exactly.
    const valid = {8000, 12000, 16000, 24000, 48000};
    if (!valid.contains(sampleRate)) return null;
    final handle = opusEncCreate(
      sampleRate,
      channels,
      config.bitrateBps,
      kOpusApplicationAudio,
    );
    if (handle == nullptr) return null;
    return OpusAudioEncoder._(handle, sampleRate, channels);
  }

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _checkOpen();
    if (!_havePts) {
      _havePts = true;
      _basePtsUs = ptsUs;
    }
    final chunk = _toFloat(pcm, format, frameCount * _channels);
    return _drain(chunk, flushTail: false);
  }

  /// Encode any buffered leftover, zero-padded to a full frame.
  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    if (_leftoverLen == 0) return const [];
    return _drain(Float32List(0), flushTail: true);
  }

  List<EncodedPacket> _drain(Float32List chunk, {required bool flushTail}) {
    final total = _leftoverLen + chunk.length;
    final work = Float32List(
      flushTail && total < _frameSamplesTotal ? _frameSamplesTotal : total,
    );
    work.setRange(0, _leftoverLen, _leftover);
    work.setRange(_leftoverLen, total, chunk);
    // flushTail path: the pad region [total, frameSamplesTotal) stays 0 (silence).

    final end = flushTail ? work.length : total;
    final packets = <EncodedPacket>[];
    var offset = 0;
    while (end - offset >= _frameSamplesTotal) {
      _in
          .asTypedList(_frameSamplesTotal)
          .setRange(0, _frameSamplesTotal, work, offset);
      final bytes = opusEncEncode(
        _handle,
        _in,
        _frameSamplesPerCh,
        _out,
        _kMaxPacketBytes,
      );
      if (bytes < 0) {
        throw CodecRuntimeException('opus', 'opus_encode_float failed: $bytes');
      }
      if (bytes > 0) {
        final data = Uint8List(bytes)..setAll(0, _out.asTypedList(bytes));
        final pts =
            _basePtsUs + (_framesEmitted * 1000000) ~/ _sampleRate;
        packets.add(EncodedPacket(
          data: data,
          ptsUs: pts,
          dtsUs: pts,
          durationUs: (_frameSamplesPerCh * 1000000) ~/ _sampleRate,
        ));
        _framesEmitted += _frameSamplesPerCh;
      }
      offset += _frameSamplesTotal;
    }

    // Carry the remainder (always < one frame) to the next call.
    _leftoverLen = flushTail ? 0 : total - offset;
    if (_leftoverLen > 0) {
      _leftover.setRange(0, _leftoverLen, work, offset);
    }
    return packets;
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    opusEncDestroy(_handle);
    calloc.free(_in);
    calloc.free(_out);
  }

  void _checkOpen() {
    if (_closed) throw StateError('OpusAudioEncoder has been closed.');
  }

  /// Read [n] interleaved samples from [pcm] (format [fmt]) as float in [-1,1].
  Float32List _toFloat(Uint8List pcm, MiniAVAudioFormat fmt, int n) {
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
        break;
    }
    return out;
  }

  /// Build a minimal OpusHead (RFC 7845): magic + version + channels + pre-skip
  /// + input rate + output gain + mapping family 0.
  static Uint8List _buildOpusHead(int channels, int inputSampleRate) {
    final b = Uint8List(19);
    final bd = ByteData.sublistView(b);
    const magic = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]; // 'OpusHead'
    b.setRange(0, 8, magic);
    b[8] = 1; // version
    b[9] = channels;
    bd.setUint16(10, 0, Endian.little); // pre-skip (0 — we don't trim)
    bd.setUint32(12, inputSampleRate, Endian.little);
    bd.setUint16(16, 0, Endian.little); // output gain
    b[18] = 0; // channel mapping family 0 (mono/stereo)
    return b;
  }
}
