/// FFmpeg demuxer (libavformat) — container file / bytes / live byte pipe →
/// [EncodedPacket]s.
///
/// Three input flavours:
///   - [openUrl]   — file path (or any protocol the FFmpeg build enables).
///     Seekable.
///   - [openBytes] — a fully-buffered container in memory (written into a
///     byte pipe up-front, then closed → the AVIO reader never blocks).
///   - [openPipe]  — a live/progressive stream via the shim's blocking byte
///     pipe (`miniav_shim_bytepipe_*`). `av_read_frame` BLOCKS inside FFI
///     when the pipe is starved, so this flavour must run on a worker
///     isolate (see `IsolateDemuxer`); closing the pipe unblocks the reader
///     with EOF. Non-seekable.
///
/// Timestamps: packets are rescaled from the stream time_base to
/// MICROSECONDS (the inverse of `FfmpegMuxer.writePacket`'s µs → time_base
/// rescale), so a mux→demux round trip preserves pts exactly.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc;
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_ffi.dart';
import 'ffmpeg_shim.dart';

/// AVMediaType (libavutil/avutil.h).
const int _kMediaTypeVideo = 0;
const int _kMediaTypeAudio = 1;

/// AVSEEK_FLAG_BACKWARD — land on the keyframe at/before the target.
const int _kSeekFlagBackward = 1;

const int _avNoPts = -0x8000000000000000;

/// Stable libavcodec AVCodecID values ↔ tools enums.
VideoCodec? _videoCodecFromId(int id) => switch (id) {
  27 => VideoCodec.h264,
  173 => VideoCodec.hevc,
  7 => VideoCodec.mjpeg,
  139 => VideoCodec.vp8,
  167 => VideoCodec.vp9,
  226 => VideoCodec.av1,
  _ => null,
};

AudioCodec? _audioCodecFromId(int id) => switch (id) {
  86017 => AudioCodec.mp3,
  86018 => AudioCodec.aac,
  86021 => AudioCodec.vorbis,
  86028 => AudioCodec.flac,
  86076 => AudioCodec.opus,
  65536 => AudioCodec.pcmS16le,
  65557 => AudioCodec.pcmF32le,
  _ => null,
};

class _StreamMap {
  _StreamMap({
    required this.trackIndex,
    required this.tbNum,
    required this.tbDen,
  });

  final int trackIndex;
  final int tbNum;
  final int tbDen;

  /// pts fallback for AV_NOPTS packets: end of the last returned packet.
  int nextFallbackPtsUs = 0;
}

class FfmpegDemuxer implements PlatformDemuxer {
  FfmpegDemuxer._(
    this._ff,
    this._shim,
    this._fmt,
    this._packet,
    this._tracks,
    this._streamMaps,
    this._durationUs,
    this._isSeekable,
    this._ownedPipe,
    this._bytesInput,
  );

  final Ffmpeg _ff;
  final FfmpegShim _shim;
  Pointer<Void> _fmt;
  final Pointer<AVPacket> _packet;
  final List<TrackInfo> _tracks;

  /// AVStream index → mapping (null for skipped/unsupported streams).
  final List<_StreamMap?> _streamMaps;
  final int? _durationUs;
  final bool _isSeekable;

  /// Byte pipe owned by this demuxer — destroyed on [close].
  final Pointer<Void>? _ownedPipe;

  /// True for [openBytes] inputs (close must free the C data copy).
  final bool _bytesInput;

  bool _closed = false;

  /// Open a file path (or URL scheme supported by the FFmpeg build).
  static FfmpegDemuxer openUrl(String path) {
    final (ff, shim) = _requireLoaded();
    final (fmt, err) = shim.openInputUrl(path);
    if (fmt == nullptr) {
      throw CodecInitException(
        'ffmpeg',
        'avformat_open_input("$path"): ${ff.strError(err)}',
      );
    }
    return _fromFormat(ff, shim, fmt, ownedPipe: null);
  }

  /// Open a fully-buffered container from memory. SEEKABLE (the shim keeps
  /// a C-owned copy behind a read+seek AVIO), so moov-at-end MP4s, duration
  /// and [seek] all work — unlike a forward-only pipe. Safe on any isolate
  /// (reads never block).
  static FfmpegDemuxer openBytes(Uint8List bytes) {
    final (ff, shim) = _requireLoaded();
    final (fmt, err) = shim.openInputBytes(bytes);
    if (fmt == nullptr) {
      throw CodecInitException(
        'ffmpeg',
        'avformat_open_input(bytes[${bytes.length}]): ${ff.strError(err)}',
      );
    }
    return _fromFormat(ff, shim, fmt, ownedPipe: null, bytesInput: true);
  }

  /// Open over an existing shim byte pipe. With [ownsPipe] the pipe is
  /// destroyed on [close]; otherwise the caller keeps ownership (and MUST
  /// `bytepipeClose` it before closing a possibly-starved demuxer, then
  /// `bytepipeDestroy` it after).
  static FfmpegDemuxer openPipe(Pointer<Void> pipe, {bool ownsPipe = false}) {
    final (ff, shim) = _requireLoaded();
    final (fmt, err) = shim.openInputPipe(pipe);
    if (fmt == nullptr) {
      // Open failed before we could hand the pipe to a demuxer — with
      // ownsPipe the caller ceded ownership, so free it here rather than leak.
      if (ownsPipe) shim.bytepipeDestroy(pipe);
      throw CodecInitException(
        'ffmpeg',
        'avformat_open_input(pipe): ${ff.strError(err)}',
      );
    }
    return _fromFormat(ff, shim, fmt, ownedPipe: ownsPipe ? pipe : null);
  }

  static (Ffmpeg, FfmpegShim) _requireLoaded() {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      throw const CodecInitException(
        'ffmpeg',
        'miniav_tools_ffmpeg shim not loadable — the demuxer requires it. '
            'Run `dart pub get` to rebuild.',
      );
    }
    return (ff, shim);
  }

  static FfmpegDemuxer _fromFormat(
    Ffmpeg ff,
    FfmpegShim shim,
    Pointer<Void> fmt, {
    required Pointer<Void>? ownedPipe,
    bool bytesInput = false,
  }) {
    final tracks = <TrackInfo>[];
    final nb = shim.fmtNbStreams(fmt);
    final maps = List<_StreamMap?>.filled(nb, null);
    for (var i = 0; i < nb; i++) {
      final stPtr = shim.fmtStream(fmt, i);
      if (stPtr == nullptr) continue;
      final st = stPtr.cast<AVStream>().ref;
      final par = st.codecpar.ref;
      TrackInfo? info;
      switch (par.codecType) {
        case _kMediaTypeVideo:
          final codec = _videoCodecFromId(par.codecId);
          if (codec == null) break;
          info = VideoTrackInfo(
            codec: codec,
            width: par.width,
            height: par.height,
            frameRateNumerator: par.frNum > 0 ? par.frNum : 0,
            frameRateDenominator: par.frDen > 0 ? par.frDen : 1,
            extraData: _extra(par, video: codec),
          );
        case _kMediaTypeAudio:
          final codec = _audioCodecFromId(par.codecId);
          if (codec == null) break;
          info = AudioTrackInfo(
            codec: codec,
            sampleRate: shim.parSampleRate(st.codecpar.cast<Void>()),
            channels: shim.parNbChannels(st.codecpar.cast<Void>()),
            extraData: _extra(par, audio: codec),
          );
        default:
          break; // subtitles/data streams: skipped
      }
      if (info == null) continue;
      maps[i] = _StreamMap(
        trackIndex: tracks.length,
        tbNum: st.timeBaseNum,
        tbDen: st.timeBaseDen > 0 ? st.timeBaseDen : 1000000,
      );
      tracks.add(info);
    }
    // Fail-cleanup before the demuxer object exists: free the AVFormatContext
    // AND the caller-ceded byte pipe (else it leaks — `close()` never runs
    // because no object is constructed).
    void failClose() {
      bytesInput ? shim.closeInputBytes(fmt) : shim.closeInput(fmt);
      if (ownedPipe != null) shim.bytepipeDestroy(ownedPipe);
    }

    if (tracks.isEmpty) {
      failClose();
      throw const CodecInitException(
        'ffmpeg',
        'no supported audio/video tracks found in input',
      );
    }
    final packet = ff.avPacketAlloc();
    if (packet.address == 0) {
      failClose();
      throw const CodecInitException('ffmpeg', 'av_packet_alloc NULL');
    }
    final dur = shim.fmtDurationUs(fmt);
    return FfmpegDemuxer._(
      ff,
      shim,
      fmt,
      packet,
      tracks,
      maps,
      dur > 0 ? dur : null,
      shim.fmtIsSeekable(fmt),
      ownedPipe,
      bytesInput,
    );
  }

  static CodecExtraData? _extra(
    AVCodecParameters par, {
    VideoCodec? video,
    AudioCodec? audio,
  }) {
    if (par.extradata == nullptr || par.extradataSize <= 0) return null;
    final bytes = Uint8List.fromList(
      par.extradata.asTypedList(par.extradataSize),
    );
    return video != null
        ? CodecExtraData.video(video, bytes)
        : CodecExtraData.audio(audio, bytes);
  }

  @override
  List<TrackInfo> get tracks => _tracks;

  @override
  int? get durationUs => _durationUs;

  @override
  bool get isSeekable => _isSeekable;

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();
    while (true) {
      final ret = _ff.avReadFrame(_fmt.cast(), _packet);
      if (ret == kAvErrorEof) return null;
      if (ret == kAvErrorEAgain) continue;
      if (ret < 0) {
        throw CodecRuntimeException(
          'ffmpeg',
          'av_read_frame: ${_ff.strError(ret)}',
        );
      }
      final p = _packet.ref;
      final map = (p.streamIndex >= 0 && p.streamIndex < _streamMaps.length)
          ? _streamMaps[p.streamIndex]
          : null;
      if (map == null || p.size <= 0 || p.data == nullptr) {
        _ff.avPacketUnref(_packet);
        continue; // unsupported/skipped stream
      }
      // Overflow-safe stream-time-base → µs rescale. `v * 1000000 * tbNum`
      // done directly overflows int64 for fine-grained time_bases (e.g.
      // Matroska/WebM 1/1_000_000_000: v exceeds ~9.2e12 ticks ≈ 2.5 h) since
      // Dart native ints wrap. Split into whole + fractional parts so no
      // intermediate exceeds ~tbDen·1e6.
      int toUs(int v) {
        final tbNum = map.tbNum;
        final tbDen = map.tbDen;
        if (v == 0) return 0;
        final neg = v < 0;
        final av = neg ? -v : v;
        final whole = av ~/ tbDen;
        final frac = av % tbDen;
        final us = whole * 1000000 * tbNum + (frac * 1000000 * tbNum) ~/ tbDen;
        return neg ? -us : us;
      }

      final durationUs = p.duration > 0 ? toUs(p.duration) : 0;
      final int ptsUs;
      if (p.pts != _avNoPts) {
        ptsUs = toUs(p.pts);
      } else if (p.dts != _avNoPts) {
        ptsUs = toUs(p.dts);
      } else {
        ptsUs = map.nextFallbackPtsUs;
      }
      final dtsUs = p.dts != _avNoPts ? toUs(p.dts) : ptsUs;
      map.nextFallbackPtsUs = ptsUs + durationUs;
      final data = Uint8List.fromList(p.data.asTypedList(p.size));
      final isKey = (p.flags & kPktFlagKey) != 0;
      _ff.avPacketUnref(_packet);
      return EncodedPacket(
        data: data,
        ptsUs: ptsUs,
        dtsUs: dtsUs,
        durationUs: durationUs,
        isKeyframe: isKey,
        trackIndex: map.trackIndex,
      );
    }
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    if (!_isSeekable) {
      throw const CodecRuntimeException(
        'ffmpeg',
        'seek unsupported on a non-seekable (live byte stream) input',
      );
    }
    // stream_index -1 → timestamp in AV_TIME_BASE units, which is µs.
    final ret = _ff.avSeekFrame(
      _fmt.cast(),
      -1,
      timestampUs,
      _kSeekFlagBackward,
    );
    if (ret < 0) {
      throw CodecRuntimeException(
        'ffmpeg',
        'av_seek_frame(${timestampUs}us): ${_ff.strError(ret)}',
      );
    }
    for (final m in _streamMaps) {
      m?.nextFallbackPtsUs = 0;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_bytesInput) {
      _shim.closeInputBytes(_fmt);
    } else {
      _shim.closeInput(_fmt);
    }
    _fmt = nullptr;
    final pp = calloc<Pointer<AVPacket>>()..value = _packet;
    try {
      _ff.avPacketFree(pp);
    } finally {
      calloc.free(pp);
    }
    final pipe = _ownedPipe;
    if (pipe != null) {
      _shim.bytepipeDestroy(pipe);
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg', 'demuxer closed');
    }
  }
}
