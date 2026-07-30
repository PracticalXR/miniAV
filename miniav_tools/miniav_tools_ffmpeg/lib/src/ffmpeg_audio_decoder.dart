/// Software FFmpeg audio decoder (libavcodec) — AAC / Opus / MP3 / Vorbis /
/// FLAC → interleaved float32 PCM.
///
/// Output is always [DecodedAudio] (interleaved f32 in [-1, 1]); the codec's
/// native sample format (usually planar `fltp`) is interleaved during the
/// mandatory copy-out of the AVFrame, so no extra conversion pass exists.
///
/// The true sample rate / channel count are read off each decoded AVFrame via
/// the shim (`miniav_shim_frame_*` — those fields live beyond the Dart-mapped
/// struct prefix), so streams that self-describe (ADTS AAC) work without any
/// config hints.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_encoder.dart' show address;
import 'ffmpeg_ffi.dart';
import 'ffmpeg_shim.dart';

/// Audio AVCodecIDs (stable libavcodec ABI values).
abstract final class _AvAudioCodecId {
  static const int mp3 = 86017; // AV_CODEC_ID_MP3
  static const int aac = 86018; // AV_CODEC_ID_AAC
  static const int vorbis = 86021; // AV_CODEC_ID_VORBIS
  static const int flac = 86028; // AV_CODEC_ID_FLAC
  static const int opus = 86076; // AV_CODEC_ID_OPUS
}

/// AVSampleFormat enum (libavutil/samplefmt.h).
abstract final class _AvSampleFmt {
  static const int u8 = 0;
  static const int s16 = 1;
  static const int s32 = 2;
  static const int flt = 3;
  static const int dbl = 4;
  static const int u8p = 5;
  static const int s16p = 6;
  static const int s32p = 7;
  static const int fltp = 8;
  static const int dblp = 9;
}

bool _isPlanar(int fmt) => fmt >= _AvSampleFmt.u8p && fmt <= _AvSampleFmt.dblp;

class FfmpegAudioDecoder implements PlatformAudioDecoder {
  FfmpegAudioDecoder._(
    this._ff,
    this._shim,
    this._codecCtx,
    this._frame,
    this._packet,
  );

  final Ffmpeg _ff;
  final FfmpegShim _shim;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVFrame> _frame;
  final Pointer<AVPacket> _packet;

  bool _closed = false;

  /// pts fallback state for AV_NOPTS frames: extrapolate by decoded duration.
  int _nextFallbackPtsUs = 0;

  static FfmpegAudioDecoder open(AudioDecoderConfig cfg) {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg-audio',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      throw const CodecInitException(
        'ffmpeg-audio',
        'miniav_tools_ffmpeg shim not loadable — the audio decoder requires '
            'it for extradata + AVFrame field access. Run `dart pub get` to '
            'rebuild.',
      );
    }
    final codec = ff.avcodecFindDecoder(_audioCodecId(cfg.codec));
    if (codec == address(0)) {
      throw CodecInitException(
        'ffmpeg-audio',
        'No decoder registered for ${cfg.codec}',
      );
    }
    final codecCtx = ff.avcodecAllocContext3(codec);
    if (codecCtx == address(0)) {
      throw const CodecInitException(
        'ffmpeg-audio',
        'avcodec_alloc_context3 returned NULL',
      );
    }
    try {
      final extra = cfg.extraData;
      if (extra != null && extra.isNotEmpty) {
        final r = shim.codecSetExtradata(codecCtx.cast<Void>(), extra);
        if (r < 0) {
          throw CodecInitException(
            'ffmpeg-audio',
            'codec_set_extradata failed: ${ff.strError(r)}',
          );
        }
      } else {
        // No codec-private data. Self-describing streams (ADTS AAC, MP3)
        // need nothing; Opus without an OpusHead needs a channel layout to
        // initialise, so apply the config hints (Opus is always 48 kHz on
        // the wire).
        final needsHints = cfg.codec == AudioCodec.opus;
        final channels = cfg.channels ?? (needsHints ? 2 : 0);
        final sampleRate = cfg.sampleRate ?? (needsHints ? 48000 : 0);
        if (channels > 0 && sampleRate > 0) {
          final r = shim.codecSetAudioParams(
            codecCtx.cast<Void>(),
            sampleFmt: -1, // AV_SAMPLE_FMT_NONE — decoder picks its own
            sampleRate: sampleRate,
            channels: channels,
            bitRate: 0,
          );
          if (r < 0) {
            throw CodecInitException(
              'ffmpeg-audio',
              'codec_set_audio_params failed: ${ff.strError(r)}',
            );
          }
        }
      }
      final ret = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (ret < 0) {
        throw CodecInitException(
          'ffmpeg-audio',
          'avcodec_open2(${cfg.codec.name} decoder): ${ff.strError(ret)}',
        );
      }
      final frame = ff.avFrameAlloc();
      final packet = ff.avPacketAlloc();
      if (frame.address == 0 || packet.address == 0) {
        throw const CodecInitException(
          'ffmpeg-audio',
          'av_frame_alloc / av_packet_alloc returned NULL',
        );
      }
      return FfmpegAudioDecoder._(ff, shim, codecCtx, frame, packet);
    } catch (_) {
      final ptr = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
      ff.avcodecFreeContext(ptr);
      calloc.free(ptr);
      rethrow;
    }
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _checkOpen();
    final size = packet.data.length;
    final buf = calloc<Uint8>(size);
    try {
      buf.asTypedList(size).setRange(0, size, packet.data);
      _packet.ref
        ..data = buf
        ..size = size
        ..pts = packet.ptsUs
        ..dts = packet.dtsUs == 0 ? packet.ptsUs : packet.dtsUs
        ..flags = packet.isKeyframe ? kPktFlagKey : 0;
      final ret = _ff.avcodecSendPacket(_codecCtx, _packet);
      if (ret < 0 && ret != kAvErrorEAgain) {
        throw CodecRuntimeException(
          'ffmpeg-audio',
          'avcodec_send_packet: ${_ff.strError(ret)}',
        );
      }
    } finally {
      calloc.free(buf);
      _packet.ref.data = nullptr;
      _packet.ref.size = 0;
    }
    return _drainAll();
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    _checkOpen();
    final ret = _ff.avcodecSendPacket(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'avcodec_send_packet(NULL): ${_ff.strError(ret)}',
      );
    }
    return _drainAll();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final fp = calloc<Pointer<AVFrame>>()..value = _frame;
    final pp = calloc<Pointer<AVPacket>>()..value = _packet;
    final cp = calloc<Pointer<AVCodecContext>>()..value = _codecCtx;
    try {
      _ff.avFrameFree(fp);
      _ff.avPacketFree(pp);
      _ff.avcodecFreeContext(cp);
    } finally {
      calloc.free(fp);
      calloc.free(pp);
      calloc.free(cp);
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-audio', 'decoder closed');
    }
  }

  List<DecodedAudio> _drainAll() {
    final out = <DecodedAudio>[];
    while (true) {
      final ret = _ff.avcodecReceiveFrame(_codecCtx, _frame);
      if (ret == kAvErrorEAgain || ret == kAvErrorEof) break;
      if (ret < 0) {
        throw CodecRuntimeException(
          'ffmpeg-audio',
          'avcodec_receive_frame: ${_ff.strError(ret)}',
        );
      }
      out.add(_materialize());
    }
    return out;
  }

  DecodedAudio _materialize() {
    final f = _frame.ref;
    final frameCount = f.nbSamples;
    final fmt = f.format;
    final framePtr = _frame.cast<Void>();
    final channels = _shim.frameNbChannels(framePtr);
    final sampleRate = _shim.frameSampleRate(framePtr);
    if (frameCount <= 0 || channels <= 0 || sampleRate <= 0) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'decoded frame has invalid geometry: '
            'samples=$frameCount ch=$channels rate=$sampleRate',
      );
    }
    final samples = _interleaveToF32(f, fmt, frameCount, channels);

    // Packets carry µs pts and no time_base is set, so frame.pts is µs.
    final int ptsUs;
    if (f.pts == _avNoPts) {
      ptsUs = _nextFallbackPtsUs;
    } else {
      ptsUs = f.pts;
    }
    _nextFallbackPtsUs = ptsUs + (frameCount * 1000000) ~/ sampleRate;

    return DecodedAudio(
      samples: samples,
      frameCount: frameCount,
      sampleRate: sampleRate,
      channels: channels,
      ptsUs: ptsUs,
    );
  }

  /// Interleave/convert the AVFrame's PCM into f32 interleaved. Planar
  /// formats read per-channel via `extended_data[c]`; interleaved formats
  /// read `data[0]` directly.
  Float32List _interleaveToF32(AVFrame f, int fmt, int frameCount, int channels) {
    final out = Float32List(frameCount * channels);
    if (_isPlanar(fmt)) {
      for (var c = 0; c < channels; c++) {
        final plane = f.extendedData[c];
        switch (fmt) {
          case _AvSampleFmt.fltp:
            final src = plane.cast<Float>().asTypedList(frameCount);
            for (var i = 0; i < frameCount; i++) {
              out[i * channels + c] = src[i];
            }
          case _AvSampleFmt.s16p:
            final src = plane.cast<Int16>().asTypedList(frameCount);
            for (var i = 0; i < frameCount; i++) {
              out[i * channels + c] = src[i] / 32768.0;
            }
          case _AvSampleFmt.s32p:
            final src = plane.cast<Int32>().asTypedList(frameCount);
            for (var i = 0; i < frameCount; i++) {
              out[i * channels + c] = src[i] / 2147483648.0;
            }
          case _AvSampleFmt.u8p:
            final src = plane.asTypedList(frameCount);
            for (var i = 0; i < frameCount; i++) {
              out[i * channels + c] = (src[i] - 128) / 128.0;
            }
          case _AvSampleFmt.dblp:
            final src = plane.cast<Double>().asTypedList(frameCount);
            for (var i = 0; i < frameCount; i++) {
              out[i * channels + c] = src[i];
            }
          default:
            throw CodecRuntimeException(
              'ffmpeg-audio',
              'unsupported planar sample format $fmt',
            );
        }
      }
      return out;
    }
    final n = frameCount * channels;
    final plane = f.data0;
    switch (fmt) {
      case _AvSampleFmt.flt:
        out.setAll(0, plane.cast<Float>().asTypedList(n));
      case _AvSampleFmt.s16:
        final src = plane.cast<Int16>().asTypedList(n);
        for (var i = 0; i < n; i++) {
          out[i] = src[i] / 32768.0;
        }
      case _AvSampleFmt.s32:
        final src = plane.cast<Int32>().asTypedList(n);
        for (var i = 0; i < n; i++) {
          out[i] = src[i] / 2147483648.0;
        }
      case _AvSampleFmt.u8:
        final src = plane.asTypedList(n);
        for (var i = 0; i < n; i++) {
          out[i] = (src[i] - 128) / 128.0;
        }
      case _AvSampleFmt.dbl:
        final src = plane.cast<Double>().asTypedList(n);
        for (var i = 0; i < n; i++) {
          out[i] = src[i];
        }
      default:
        throw CodecRuntimeException(
          'ffmpeg-audio',
          'unsupported sample format $fmt',
        );
    }
    return out;
  }
}

const int _avNoPts = -0x8000000000000000;

int _audioCodecId(AudioCodec codec) {
  switch (codec) {
    case AudioCodec.aac:
      return _AvAudioCodecId.aac;
    case AudioCodec.opus:
      return _AvAudioCodecId.opus;
    case AudioCodec.mp3:
      return _AvAudioCodecId.mp3;
    case AudioCodec.vorbis:
      return _AvAudioCodecId.vorbis;
    case AudioCodec.flac:
      return _AvAudioCodecId.flac;
    default:
      throw CodecInitException(
        'ffmpeg-audio',
        'unsupported audio decoder codec: $codec',
      );
  }
}
