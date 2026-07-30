/// Software FFmpeg audio encoder (libavcodec) for AAC and Opus.
///
/// Accepts interleaved PCM (u8/s16/s32/f32) per [encode] call. Internally
/// chunks the input into the codec's required frame size, deinterleaves
/// to planar float when needed, and emits one or more [EncodedPacket]s.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_ffi.dart';
import 'ffmpeg_muxer.dart' show FfmpegEncoderBridge;
import 'ffmpeg_shim.dart' show FfmpegShim;

/// AVCodecID values for the audio codecs we expose. Matches FFmpeg 7/8.
abstract final class _AvAudioCodecId {
  static const int aac = 86018; // AV_CODEC_ID_AAC
  static const int opus = 86076; // AV_CODEC_ID_OPUS
}

/// AVSampleFormat enum (libavutil/samplefmt.h).
abstract final class _AvSampleFmt {
  static const int u8 = 0;
  static const int s16 = 1;
  static const int s32 = 2;
  static const int flt = 3;
  // ignore: unused_field
  static const int dbl = 4;
  static const int u8p = 5;
  static const int s16p = 6;
  static const int s32p = 7;
  static const int fltp = 8;
}

bool _isPlanar(int fmt) => fmt >= _AvSampleFmt.u8p && fmt <= _AvSampleFmt.fltp;

/// `AV_NOPTS_VALUE` from libavutil/avutil.h — INT64_MIN. FFmpeg sets this on
/// output packet pts/dts fields when no timestamp is available (common for
/// audio DTS on codecs that have no B-frames).
const int _avNoPtsValue = -9223372036854775808;

int _bytesPerSample(int fmt) {
  switch (fmt) {
    case _AvSampleFmt.u8:
    case _AvSampleFmt.u8p:
      return 1;
    case _AvSampleFmt.s16:
    case _AvSampleFmt.s16p:
      return 2;
    case _AvSampleFmt.s32:
    case _AvSampleFmt.s32p:
    case _AvSampleFmt.flt:
    case _AvSampleFmt.fltp:
      return 4;
    default:
      return 4;
  }
}

class FfmpegAudioEncoder implements PlatformAudioEncoder, FfmpegEncoderBridge {
  FfmpegAudioEncoder._(
    this._ff,
    this._shim,
    this._cfg,
    this._codecCtx,
    this._frame,
    this._packet,
    this._sampleFmt,
    this._frameSize,
  );

  final Ffmpeg _ff;
  final FfmpegShim _shim;
  final AudioEncoderConfig _cfg;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVFrame> _frame;
  final Pointer<AVPacket> _packet;

  /// AVSampleFormat the encoder wants on its AVFrames.
  final int _sampleFmt;

  /// Samples-per-channel per AVFrame required by the encoder.
  final int _frameSize;

  /// Buffered interleaved PCM samples (in encoder's destination format
  /// width × channels) waiting for full frames.
  final List<Uint8List> _pendingChunks = [];
  int _pendingFrames = 0;

  /// Sample index of the very next sample we will hand to FFmpeg. Used to
  /// derive monotonically-correct AVFrame.pts values.
  int _nextSampleIndex = 0;

  /// Microsecond timestamp corresponding to sample index 0. Set on first
  /// [encode] call so encoder pts maps back to wall-clock pts.
  int? _epochUs;

  bool _closed = false;
  CodecExtraData? _extraData;

  static FfmpegAudioEncoder open(AudioEncoderConfig cfg) {
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
        'miniav_tools_ffmpeg shim not loadable — audio encoder requires '
            'the shim for AVChannelLayout setup. Run `dart pub get` to '
            'rebuild.',
      );
    }

    final encoderName = _preferredEncoderName(cfg.codec);
    final codecId = _audioCodecId(cfg.codec);
    final codec = _findEncoder(ff, encoderName, codecId);
    final codecCtx = ff.avcodecAllocContext3(codec);
    if (codecCtx.address == 0) {
      throw const CodecInitException(
        'ffmpeg-audio',
        'avcodec_alloc_context3 returned NULL',
      );
    }

    Pointer<AVFrame> frame = nullptr;
    Pointer<AVPacket> packet = nullptr;
    try {
      // Pick the encoder's preferred sample format; fall back to fltp.
      var sampleFmt = shim.codecPickSampleFmt(codec.cast<Void>());
      if (sampleFmt < 0) sampleFmt = _AvSampleFmt.fltp;

      final r = shim.codecSetAudioParams(
        codecCtx.cast<Void>(),
        sampleFmt: sampleFmt,
        sampleRate: cfg.sampleRate,
        channels: cfg.channels,
        bitRate: cfg.bitrateBps,
      );
      if (r < 0) {
        throw CodecInitException(
          'ffmpeg-audio',
          'codec_set_audio_params failed: ${ff.strError(r)} ($r)',
        );
      }

      // Global header (needed for MP4 / MKV muxing — extradata must be
      // out-of-band).
      if (cfg.backendOptions['global_header'] == '1') {
        _setStr(ff, codecCtx, 'flags', '+global_header');
      }
      // Pass-through backend-specific options (e.g. opus 'application=audio',
      // 'frame_duration=20').
      cfg.backendOptions.forEach((k, v) {
        if (k == 'global_header') return;
        _setStr(ff, codecCtx, k, v);
      });

      final ret = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (ret < 0) {
        throw CodecInitException(
          'ffmpeg-audio',
          'avcodec_open2(${cfg.codec.name}) failed: '
              '${ff.strError(ret)} ($ret)',
        );
      }

      var frameSize = shim.codecGetFrameSize(codecCtx.cast<Void>());
      if (frameSize <= 0) {
        // No fixed frame size — pick a sensible default (20 ms @ sampleRate).
        frameSize = (cfg.sampleRate ~/ 50);
      }

      frame = ff.avFrameAlloc();
      packet = ff.avPacketAlloc();
      if (frame.address == 0 || packet.address == 0) {
        throw const CodecInitException(
          'ffmpeg-audio',
          'av_frame_alloc / av_packet_alloc returned NULL',
        );
      }

      final fr = shim.audioFrameSetup(
        frame.cast<Void>(),
        sampleFmt: sampleFmt,
        sampleRate: cfg.sampleRate,
        channels: cfg.channels,
        nbSamples: frameSize,
      );
      if (fr < 0) {
        throw CodecInitException(
          'ffmpeg-audio',
          'audio_frame_setup failed: ${ff.strError(fr)} ($fr)',
        );
      }

      return FfmpegAudioEncoder._(
        ff,
        shim,
        cfg,
        codecCtx,
        frame,
        packet,
        sampleFmt,
        frameSize,
      ).._loadExtraData();
    } catch (_) {
      if (frame.address != 0) {
        final fp = calloc<Pointer<AVFrame>>()..value = frame;
        ff.avFrameFree(fp);
        calloc.free(fp);
      }
      if (packet.address != 0) {
        final pp = calloc<Pointer<AVPacket>>()..value = packet;
        ff.avPacketFree(pp);
        calloc.free(pp);
      }
      final cp = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
      ff.avcodecFreeContext(cp);
      calloc.free(cp);
      rethrow;
    }
  }

  static String? _preferredEncoderName(AudioCodec codec) {
    switch (codec) {
      case AudioCodec.aac:
        return 'aac'; // FFmpeg native AAC-LC; no longer experimental in 5+.
      case AudioCodec.opus:
        return 'libopus';
      default:
        return null;
    }
  }

  static int _audioCodecId(AudioCodec codec) {
    switch (codec) {
      case AudioCodec.aac:
        return _AvAudioCodecId.aac;
      case AudioCodec.opus:
        return _AvAudioCodecId.opus;
      default:
        throw CodecInitException(
          'ffmpeg-audio',
          'unsupported AudioCodec.$codec',
        );
    }
  }

  static Pointer<AVCodec> _findEncoder(Ffmpeg ff, String? name, int id) {
    if (name != null) {
      final p = name.toNativeUtf8();
      try {
        final c = ff.avcodecFindEncoderByName(p);
        if (c.address != 0) return c;
      } finally {
        calloc.free(p);
      }
    }
    final byId = ff.avcodecFindEncoder(id);
    if (byId.address == 0) {
      throw CodecInitException(
        'ffmpeg-audio',
        'No encoder found (tried "$name" and id $id). For Opus install an '
            'FFmpeg build with libopus enabled.',
      );
    }
    return byId;
  }

  static void _setStr(
    Ffmpeg ff,
    Pointer<AVCodecContext> ctx,
    String key,
    String val,
  ) {
    final k = key.toNativeUtf8();
    final v = val.toNativeUtf8();
    try {
      ff.avOptSet(ctx.cast<Void>(), k, v, 0);
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }

  void _loadExtraData() {
    final params = _ff.avcodecParametersAlloc();
    if (params.address == 0) return;
    final pp = calloc<Pointer<AVCodecParameters>>()..value = params;
    try {
      final r = _ff.avcodecParametersFromContext(params, _codecCtx);
      if (r < 0) return;
      final ref = params.ref;
      if (ref.extradataSize > 0 && ref.extradata.address != 0) {
        final bytes = Uint8List(ref.extradataSize);
        bytes.setAll(0, ref.extradata.asTypedList(ref.extradataSize));
        _extraData = CodecExtraData.audio(_cfg.codec, bytes);
      }
    } finally {
      _ff.avcodecParametersFree(pp);
      calloc.free(pp);
    }
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Pointer<AVCodecContext> get nativeCodecContext => _codecCtx;

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _checkOpen();
    if (frameCount <= 0) return const [];

    // Establish or drift-correct the epoch.
    //
    // On the first call we anchor the epoch so that all output PTSs share the
    // same wall-clock reference as video (which uses rec.now()).  On every
    // subsequent call we slew the epoch toward the value implied by the
    // incoming wall-clock ptsUs.  This cancels the divergence between the
    // audio-device oscillator and the CPU clock (typically 10–100 ppm),
    // which would otherwise accumulate to 36–360 ms of A/V desync per hour.
    //
    // Slew rate: _kEpochSlewUs µs per encode() call (one call ≈ 10 ms of
    // audio), giving a correction speed of ≈5 ms/s — 50× faster than
    // 100-ppm USB-audio drift (≈0.1 ms/s) while the per-frame PTS step
    // change is < 0.3 %, well below the threshold of audible artefacts.
    {
      const kSlewUs = 50; // max µs applied per encode() call
      final impliedEpoch = ptsUs - _samplesToUs(_nextSampleIndex);
      if (_epochUs == null) {
        _epochUs = impliedEpoch;
      } else {
        final delta = impliedEpoch - _epochUs!;
        if (delta.abs() <= kSlewUs) {
          _epochUs = impliedEpoch; // small residual → snap
        } else {
          _epochUs = _epochUs! + (delta > 0 ? kSlewUs : -kSlewUs);
        }
      }
    }

    // Convert input PCM to encoder's destination format width as
    // INTERLEAVED bytes (we deinterleave into planar buffers per-frame
    // when filling the AVFrame). This keeps the buffering math simple.
    final bytesPerDstSample = _bytesPerSample(_sampleFmt);
    final dst = _convertToInterleavedDestFormat(
      pcm: pcm,
      srcFormat: format,
      frameCount: frameCount,
      channels: _cfg.channels,
      dstSampleFmt: _sampleFmt,
    );
    if (dst.length != frameCount * _cfg.channels * bytesPerDstSample) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'PCM size mismatch: got ${dst.length}, expected '
            '${frameCount * _cfg.channels * bytesPerDstSample}',
      );
    }

    _pendingChunks.add(dst);
    _pendingFrames += frameCount;

    return _drainPendingFrames(flushPartial: false);
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final out = <EncodedPacket>[];
    // Drain any whole frames first.
    out.addAll(await _drainPendingFrames(flushPartial: false));
    // Pad and emit any partial trailing frame so flush is lossless.
    if (_pendingFrames > 0) {
      out.addAll(await _drainPendingFrames(flushPartial: true));
    }
    // Tell the encoder there are no more frames.
    final ret = _ff.avcodecSendFrame(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'avcodec_send_frame(NULL): ${_ff.strError(ret)} ($ret)',
      );
    }
    while (true) {
      final pkt = _drainOne();
      if (pkt == null) break;
      out.add(pkt);
    }
    return out;
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

  // --- helpers --------------------------------------------------------------

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-audio', 'encoder closed');
    }
  }

  int _samplesToUs(int samples) => (samples * 1000000) ~/ _cfg.sampleRate;

  Future<List<EncodedPacket>> _drainPendingFrames({
    required bool flushPartial,
  }) async {
    final out = <EncodedPacket>[];
    final bytesPerInterleavedFrame =
        _cfg.channels * _bytesPerSample(_sampleFmt);
    final bytesPerCodecFrame = _frameSize * bytesPerInterleavedFrame;

    while (_pendingFrames >= _frameSize ||
        (flushPartial && _pendingFrames > 0)) {
      // Coalesce up to bytesPerCodecFrame interleaved bytes from pending
      // chunks (zero-pad if flushing a partial frame).
      final chunkBytes = Uint8List(bytesPerCodecFrame);
      var written = 0;
      var samplesTaken = 0;
      while (written < bytesPerCodecFrame && _pendingChunks.isNotEmpty) {
        final head = _pendingChunks.first;
        final remaining = bytesPerCodecFrame - written;
        if (head.length <= remaining) {
          chunkBytes.setRange(written, written + head.length, head);
          written += head.length;
          samplesTaken += head.length ~/ bytesPerInterleavedFrame;
          _pendingChunks.removeAt(0);
        } else {
          chunkBytes.setRange(written, written + remaining, head, 0);
          _pendingChunks[0] = Uint8List.sublistView(head, remaining);
          written += remaining;
          samplesTaken += remaining ~/ bytesPerInterleavedFrame;
        }
      }
      _pendingFrames -= samplesTaken;
      // (zero-padded bytes for the partial-flush case stay 0x00)

      final pkts = _sendOneFrame(chunkBytes, samplesTaken);
      out.addAll(pkts);
    }
    return out;
  }

  /// Copy `interleavedBytes` into the AVFrame buffers (planar or interleaved
  /// depending on `_sampleFmt`), set pts, send to encoder, drain ready
  /// packets.
  List<EncodedPacket> _sendOneFrame(
    Uint8List interleavedBytes,
    int realSamples,
  ) {
    final mw = _ff.avFrameMakeWritable(_frame);
    if (mw < 0) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'av_frame_make_writable: ${_ff.strError(mw)}',
      );
    }
    final f = _frame.ref;
    final bps = _bytesPerSample(_sampleFmt);
    final ch = _cfg.channels;
    if (_isPlanar(_sampleFmt)) {
      // Deinterleave one channel at a time into f.data[c].
      final channelBytes = _frameSize * bps;
      final planes = <Pointer<Uint8>>[
        f.data0,
        f.data1,
        f.data2,
        f.data3,
        f.data4,
        f.data5,
        f.data6,
        f.data7,
      ];
      for (var c = 0; c < ch; c++) {
        final dst = planes[c].asTypedList(channelBytes);
        for (var s = 0; s < _frameSize; s++) {
          final srcOff = (s * ch + c) * bps;
          final dstOff = s * bps;
          for (var b = 0; b < bps; b++) {
            dst[dstOff + b] = interleavedBytes[srcOff + b];
          }
        }
      }
    } else {
      // Packed: just copy bytes into data0.
      f.data0.asTypedList(_frameSize * ch * bps).setAll(0, interleavedBytes);
    }

    final pts = _nextSampleIndex;
    _shim.audioFrameSetPts(_frame.cast<Void>(), pts);
    _nextSampleIndex += _frameSize;

    final sent = _ff.avcodecSendFrame(_codecCtx, _frame);
    if (sent < 0 && sent != kAvErrorEAgain) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'avcodec_send_frame: ${_ff.strError(sent)} ($sent)',
      );
    }

    final out = <EncodedPacket>[];
    while (true) {
      final pkt = _drainOne();
      if (pkt == null) break;
      out.add(pkt);
    }
    // Suppress unused warning for realSamples; we keep it in the API in
    // case future audit logic needs it (e.g. last-frame partial accounting).
    assert(realSamples >= 0);
    return out;
  }

  EncodedPacket? _drainOne() {
    final ret = _ff.avcodecReceivePacket(_codecCtx, _packet);
    if (ret == kAvErrorEAgain || ret == kAvErrorEof) return null;
    if (ret < 0) {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'avcodec_receive_packet: ${_ff.strError(ret)} ($ret)',
      );
    }
    final p = _packet.ref;
    final bytes = Uint8List(p.size);
    bytes.setRange(0, p.size, p.data.asTypedList(p.size));

    // The encoder time_base is 1/sample_rate (FFmpeg sets this for
    // audio encoders automatically). Convert pts (in samples) → us and
    // shift by the wall-clock epoch we captured on the first encode().
    //
    // FFmpeg leaves p.dts = AV_NOPTS_VALUE (INT64_MIN) for audio codecs
    // that have no B-frames (AAC, Opus, …). Passing INT64_MIN through
    // _samplesToUs() overflows Dart 64-bit arithmetic and produces garbage
    // that causes av_interleaved_write_frame to silently drop the packet.
    // Fall back to pts for those cases.
    final epoch = _epochUs ?? 0;
    final rawDts = (p.dts == _avNoPtsValue) ? p.pts : p.dts;
    final ptsUs = epoch + _samplesToUs(p.pts);
    final dtsUs = epoch + _samplesToUs(rawDts);
    final durationUs = _samplesToUs(p.duration);

    final pktOut = EncodedPacket(
      data: bytes,
      ptsUs: ptsUs,
      dtsUs: dtsUs,
      durationUs: durationUs,
      isKeyframe: true, // every audio packet is independently decodable
    );
    _ff.avPacketUnref(_packet);
    return pktOut;
  }

  /// Convert any input PCM layout to interleaved bytes in the encoder's
  /// destination sample format width. Output is interleaved (channel
  /// deinterleaving for planar codec formats happens later in
  /// [_sendOneFrame]).
  static Uint8List _convertToInterleavedDestFormat({
    required Uint8List pcm,
    required MiniAVAudioFormat srcFormat,
    required int frameCount,
    required int channels,
    required int dstSampleFmt,
  }) {
    final n = frameCount * channels;
    // Decide effective destination scalar type.
    final dstBps = _bytesPerSample(dstSampleFmt);
    final isFloatDst =
        dstSampleFmt == _AvSampleFmt.flt || dstSampleFmt == _AvSampleFmt.fltp;
    final isS16Dst =
        dstSampleFmt == _AvSampleFmt.s16 || dstSampleFmt == _AvSampleFmt.s16p;
    final isS32Dst =
        dstSampleFmt == _AvSampleFmt.s32 || dstSampleFmt == _AvSampleFmt.s32p;
    final isU8Dst =
        dstSampleFmt == _AvSampleFmt.u8 || dstSampleFmt == _AvSampleFmt.u8p;

    // Read source samples as float in [-1, 1].
    Float32List srcF;
    switch (srcFormat) {
      case MiniAVAudioFormat.f32:
        // Guard against a channel-count mismatch between the encoder config
        // and the delivered PCM (e.g. device falls back to mono despite a
        // stereo configure request, or vice-versa).  We derive the available
        // float-32 count from pcm.lengthInBytes — which is always within the
        // backing buffer's valid region — rather than from n, which is based
        // on _cfg.channels and may exceed the actual data.
        {
          final available = pcm.lengthInBytes ~/ Float32List.bytesPerElement;
          if (available >= n) {
            // Normal path: buffer holds at least n samples (may have more if
            // input has more channels than the encoder — take exactly n).
            srcF = Float32List.view(pcm.buffer, pcm.offsetInBytes, n);
          } else {
            // Fewer samples than expected: allocate a correctly-sized buffer
            // and zero-extend (extra channels are silent).
            srcF = Float32List(n);
            srcF.setAll(
              0,
              Float32List.view(pcm.buffer, pcm.offsetInBytes, available),
            );
          }
        }
        break;
      case MiniAVAudioFormat.s16:
        final s16 = Int16List.view(pcm.buffer, pcm.offsetInBytes, n);
        srcF = Float32List(n);
        for (var i = 0; i < n; i++) {
          srcF[i] = s16[i] / 32768.0;
        }
        break;
      case MiniAVAudioFormat.s32:
        final s32 = Int32List.view(pcm.buffer, pcm.offsetInBytes, n);
        srcF = Float32List(n);
        for (var i = 0; i < n; i++) {
          srcF[i] = s32[i] / 2147483648.0;
        }
        break;
      case MiniAVAudioFormat.u8:
        srcF = Float32List(n);
        for (var i = 0; i < n; i++) {
          srcF[i] = (pcm[i] - 128) / 128.0;
        }
        break;
      default:
        // Unknown format (e.g. WASAPI delivering a buffer during audio-engine
        // format renegotiation). Return silence so the encoder stream keeps
        // correct timing rather than throwing and breaking the session.
        srcF = Float32List(n); // zero-filled = silence
        break;
    }

    // Write destination interleaved bytes.
    final out = Uint8List(n * dstBps);
    if (isFloatDst) {
      final view = Float32List.view(out.buffer, 0, n);
      view.setAll(0, srcF);
    } else if (isS16Dst) {
      final view = Int16List.view(out.buffer, 0, n);
      for (var i = 0; i < n; i++) {
        var v = (srcF[i] * 32767.0).round();
        if (v < -32768) v = -32768;
        if (v > 32767) v = 32767;
        view[i] = v;
      }
    } else if (isS32Dst) {
      final view = Int32List.view(out.buffer, 0, n);
      for (var i = 0; i < n; i++) {
        var v = (srcF[i] * 2147483647.0).round();
        if (v < -2147483648) v = -2147483648;
        if (v > 2147483647) v = 2147483647;
        view[i] = v;
      }
    } else if (isU8Dst) {
      for (var i = 0; i < n; i++) {
        var v = (srcF[i] * 128.0 + 128.0).round();
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[i] = v;
      }
    } else {
      throw CodecRuntimeException(
        'ffmpeg-audio',
        'unhandled dst sample fmt: $dstSampleFmt',
      );
    }
    return out;
  }
}
