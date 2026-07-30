/// First-party libopus audio decoder — FFmpeg-free.
///
/// Wraps the `miniav_opus_*` native functions (libopus, static-linked into the
/// codecs native asset). Consumes bare Opus packets (the container demuxer /
/// transport de-frames), honours the config's sample-rate/channel hints (or
/// the OpusHead defaults 48 kHz / 2 ch), and yields interleaved float32 PCM —
/// the canonical [DecodedAudio] layout the miniaudio sink accepts, exactly like
/// the FFmpeg libopus path it replaces.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

/// Opus decodes at most 120 ms per packet → 5760 samples per channel @ 48 kHz.
const int _kMaxFramesPerChannel = 5760;

class OpusAudioDecoder implements PlatformAudioDecoder {
  OpusAudioDecoder._(
    this._handle,
    this._sampleRate,
    this._channels,
    this._skipRemaining,
  ) : _out = calloc<Float>(_kMaxFramesPerChannel * _channels);

  final Pointer<Void> _handle;
  final int _sampleRate;
  final int _channels;
  final Pointer<Float> _out;

  /// Encoder-delay priming to discard from the FRONT of the stream (RFC 7845
  /// OpusHead pre-skip), expressed in output-rate frames-per-channel and
  /// counted down as the first packets are decoded.
  int _skipRemaining;
  bool _closed = false;

  /// Open an Opus decoder. Defaults to 48 kHz / 2 ch when the config leaves
  /// them unset (the OpusHead defaults for a self-describing stream). Returns
  /// `null` if the codec isn't Opus or libopus rejects the rate/channels — the
  /// facade then falls through to the next backend (FFmpeg).
  static Future<OpusAudioDecoder?> open(AudioDecoderConfig config) async {
    if (config.codec != AudioCodec.opus) return null;
    final sampleRate = (config.sampleRate ?? 0) > 0 ? config.sampleRate! : 48000;
    var channels = (config.channels ?? 0) > 0 ? config.channels! : 2;
    var preSkip48k = 0;
    // OpusHead: byte 9 = channels, bytes 10-11 = pre-skip (samples @ 48 kHz).
    final extra = config.extraData;
    if (extra != null && extra.length >= 12 && _isOpusHead(extra)) {
      final ch = extra[9];
      if (ch == 1 || ch == 2) channels = ch;
      preSkip48k = extra[10] | (extra[11] << 8);
    }
    final handle = opusCreate(sampleRate, channels);
    if (handle == nullptr) return null;
    // Pre-skip is defined at 48 kHz; scale to the decoder's output rate.
    final skipFrames = preSkip48k * sampleRate ~/ 48000;
    return OpusAudioDecoder._(handle, sampleRate, channels, skipFrames);
  }

  static bool _isOpusHead(Uint8List d) =>
      d.length >= 8 &&
      d[0] == 0x4F && // 'O'
      d[1] == 0x70 && // 'p'
      d[2] == 0x75 && // 'u'
      d[3] == 0x73 && // 's'
      d[4] == 0x48 && // 'H'
      d[5] == 0x65 && // 'e'
      d[6] == 0x61 && // 'a'
      d[7] == 0x64; //  'd'

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _checkOpen();
    final data = packet.data;
    if (data.isEmpty) return const [];
    final inBuf = calloc<Uint8>(data.length);
    inBuf.asTypedList(data.length).setAll(0, data);
    try {
      final frames = opusDecode(
        _handle,
        inBuf,
        data.length,
        _out,
        _kMaxFramesPerChannel,
      );
      if (frames <= 0) return const []; // <0 = opus error; 0 = no output

      // Discard encoder-delay priming (OpusHead pre-skip) from the stream front.
      var startFrame = 0;
      if (_skipRemaining > 0) {
        startFrame = _skipRemaining < frames ? _skipRemaining : frames;
        _skipRemaining -= startFrame;
        if (startFrame >= frames) return const []; // whole packet was priming
      }

      final outFrames = frames - startFrame;
      final n = outFrames * _channels;
      final samples = Float32List(n);
      samples.setRange(
        0,
        n,
        _out.asTypedList(frames * _channels),
        startFrame * _channels,
      );
      return [
        DecodedAudio(
          samples: samples,
          frameCount: outFrames,
          sampleRate: _sampleRate,
          channels: _channels,
          ptsUs: packet.ptsUs,
        ),
      ];
    } finally {
      calloc.free(inBuf);
    }
  }

  /// Opus is stateless per packet — nothing is buffered across packets.
  @override
  Future<List<DecodedAudio>> flush() async => const [];

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    opusDestroy(_handle);
    calloc.free(_out);
  }

  void _checkOpen() {
    if (_closed) throw StateError('OpusAudioDecoder has been closed.');
  }
}
