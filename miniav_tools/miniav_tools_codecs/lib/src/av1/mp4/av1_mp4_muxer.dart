/// Pure-Dart MP4 muxer for AV1.
///
/// Phase 0 scope:
///   * Single video track only.
///   * Buffers all packets in memory; writes the whole file at `finish()`.
///     (Streaming / fragmented MP4 is a follow-up.)
///   * Writes `moov` *after* `mdat` so we don't need to know sample count
///     up front; populates `stco` with the post-fact `mdat` offset.
///   * 32-bit chunk offsets (`stco`). Adding `co64` for >4GiB outputs is
///     trivial when needed.
///
/// Produces a stream that:
///   * `ffprobe` reports as `Stream #0:0: Video: av1 (Main)`
///   * `dav1d` can ingest (whether it *decodes* frames depends on the
///     pipeline phase emitting real coded data).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../av1_constants.dart';
import 'iso_box_writer.dart';

/// Per-track state collected while muxing. One [_MuxTrack] is created for each
/// entry in [MuxerConfig.tracks]; the position in the config list is the
/// 0-based `trackIndex` carried by incoming [EncodedPacket]s, and `trackId`
/// is the 1-based MP4 `track_ID`.
class _MuxTrack {
  _MuxTrack({
    required this.trackId,
    required this.video,
    required this.audio,
    required this.av1C,
    required this.asc,
  });

  final int trackId;
  final VideoTrackInfo? video;
  final AudioTrackInfo? audio;

  /// Raw `av1C` config-record bytes (video tracks only).
  final Uint8List? av1C;

  /// Raw AAC `AudioSpecificConfig` bytes (audio tracks only).
  final Uint8List? asc;

  bool get isVideo => video != null;

  /// Packets received for this track, in arrival order. The caller is
  /// expected to feed them in non-decreasing PTS order (clip_buffer sorts by
  /// PTS before writing).
  final List<EncodedPacket> packets = [];
}

/// Computed per-track sample layout produced by [Av1Mp4Muxer._buildFile] and
/// consumed by the moov/trak box builders.
class _TrackLayout {
  _TrackLayout({
    required this.track,
    required this.sampleSizes,
    required this.sampleDurations,
    required this.keyframeFlags,
    required this.chunkOffset,
    required this.mediaDurationUs,
    required this.startOffsetUs,
  });

  final _MuxTrack track;
  final List<int> sampleSizes;
  final List<int> sampleDurations;
  final List<bool> keyframeFlags;

  /// Absolute file offset of this track's (single) chunk in the mdat payload.
  final int chunkOffset;

  /// Sum of sample durations (media timescale == movie timescale).
  final int mediaDurationUs;

  /// Offset of this track's first sample relative to the global timeline
  /// origin. When > 0 an empty edit is written so the track stays in sync.
  final int startOffsetUs;
}

///
/// Each [MuxerConfig.tracks] entry becomes one `trak`. Exactly one video
/// track is required and it must be AV1 (carrying its `av1C` record in
/// [VideoTrackInfo.extraData]). Any number of AAC audio tracks (mic, loopback,
/// or a mixed stream) may follow; the AAC `AudioSpecificConfig` is taken from
/// [AudioTrackInfo.extraData] when present, otherwise synthesised from the
/// track's sample-rate / channel-count.
class Av1Mp4Muxer implements PlatformMuxer {
  Av1Mp4Muxer(this._config) {
    final tracks = _config.tracks;
    if (tracks.isEmpty) {
      throw const CodecInitException(
        'minigpu',
        'Av1Mp4Muxer: at least one track is required',
      );
    }

    var videoCount = 0;
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      final trackId = i + 1; // MP4 track_ID is 1-based.
      if (t is VideoTrackInfo) {
        if (t.codec != VideoCodec.av1) {
          throw const CodecInitException(
            'minigpu',
            'Av1Mp4Muxer: video track must be VideoCodec.av1',
          );
        }
        final extra = t.extraData?.bytes;
        if (extra == null || extra.isEmpty) {
          throw const CodecInitException(
            'minigpu',
            'Av1Mp4Muxer: video track.extraData must carry the av1C record',
          );
        }
        videoCount++;
        _tracks.add(
          _MuxTrack(
            trackId: trackId,
            video: t,
            audio: null,
            av1C: Uint8List.fromList(extra),
            asc: null,
          ),
        );
      } else if (t is AudioTrackInfo) {
        if (t.codec != AudioCodec.aac) {
          throw CodecInitException(
            'minigpu',
            'Av1Mp4Muxer: audio track must be AudioCodec.aac (got ${t.codec})',
          );
        }
        final provided = t.extraData?.bytes;
        final asc = (provided != null && provided.isNotEmpty)
            ? Uint8List.fromList(provided)
            : _buildAacAsc(sampleRate: t.sampleRate, channels: t.channels);
        _tracks.add(
          _MuxTrack(
            trackId: trackId,
            video: null,
            audio: t,
            av1C: null,
            asc: asc,
          ),
        );
      } else {
        throw CodecInitException(
          'minigpu',
          'Av1Mp4Muxer: unsupported track type ${t.runtimeType}',
        );
      }
    }

    if (videoCount != 1) {
      throw CodecInitException(
        'minigpu',
        'Av1Mp4Muxer: exactly one AV1 video track is required '
            '(got $videoCount)',
      );
    }
  }

  final MuxerConfig _config;

  /// Tracks in config (declaration) order. Index == incoming `trackIndex`.
  final List<_MuxTrack> _tracks = [];

  bool _headerWritten = false;
  bool _finished = false;
  bool _closed = false;
  Uint8List? _bytesOut;

  // -- timing ---------------------------------------------------------------
  // Uniform movie/media timescale: microseconds → 1 000 000. Using one
  // timescale for every track keeps edit-list / duration maths simple.
  static const int _timescale = 1000000;

  // -- API ------------------------------------------------------------------

  @override
  Future<void> writeHeader() async {
    _checkOpen();
    _headerWritten = true; // Nothing to do up-front; layout decided at finish.
  }

  @override
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) {
      throw const CodecRuntimeException(
        'minigpu',
        'Av1Mp4Muxer.writePacket: call writeHeader() first',
      );
    }
    final idx = packet.trackIndex;
    if (idx < 0 || idx >= _tracks.length) {
      throw CodecRuntimeException(
        'minigpu',
        'Av1Mp4Muxer.writePacket: trackIndex $idx out of range '
            '(0..${_tracks.length - 1})',
      );
    }
    _tracks[idx].packets.add(packet);
  }

  @override
  Future<void> finish() async {
    _checkOpen();
    if (_finished) return;
    _finished = true;
    final mp4 = _buildFile();
    final out = _config.output;
    switch (out) {
      case FileMuxerOutput(:final path):
        await File(path).writeAsBytes(mp4, flush: true);
      case BytesMuxerOutput():
        _bytesOut = mp4;
      case CallbackMuxerOutput(:final onChunk):
        onChunk(mp4);
    }
  }

  @override
  List<int>? getBytes() => _bytesOut;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final t in _tracks) {
      t.packets.clear();
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('minigpu', 'muxer closed');
    }
  }

  // -- build ----------------------------------------------------------------

  Uint8List _buildFile() {
    final ftyp = _ftyp();
    const mdatHeaderSize = 8; // [size:u32][type:'mdat']
    final mdatPayloadStart = ftyp.length + mdatHeaderSize;

    // Global timeline origin: the earliest PTS across every track. Tracks that
    // start later than this get an empty edit (edts/elst) so that audio and
    // video stay in sync.
    var globalOrigin = 0;
    var haveOrigin = false;
    for (final t in _tracks) {
      for (final p in t.packets) {
        if (!haveOrigin || p.ptsUs < globalOrigin) {
          globalOrigin = p.ptsUs;
          haveOrigin = true;
        }
      }
    }

    // Lay out the mdat payload one track at a time: each track becomes a
    // single chunk, so we only need to remember the absolute file offset of
    // its first sample.
    final mdatBody = BytesBuilder(copy: false);
    final layouts = <_TrackLayout>[];
    var movieDurationUs = 0;

    for (final t in _tracks) {
      final pkts = [...t.packets]..sort((a, b) => a.ptsUs.compareTo(b.ptsUs));
      final sizes = <int>[];
      final durations = <int>[];
      final keyframes = <bool>[];

      final defaultDur = t.isVideo
          ? (_timescale * t.video!.frameRateDenominator) ~/
                t.video!.frameRateNumerator
          : (1024 * _timescale) ~/ t.audio!.sampleRate;

      final chunkOffset = mdatPayloadStart + mdatBody.length;
      for (var i = 0; i < pkts.length; i++) {
        final p = pkts[i];
        mdatBody.add(p.data);
        sizes.add(p.data.length);
        // Prefer the real inter-sample PTS delta over the encoder's nominal
        // per-sample durationUs. Capture sources rarely deliver frames at
        // exactly the configured frame rate (screen capture is variable-rate
        // and often slower than the nominal fps), so trusting the nominal
        // duration makes the video play too fast/slow relative to the audio,
        // which is laid out on the real PTS timeline. Using PTS deltas keeps
        // the track duration aligned with wall-clock time. The final sample
        // has no successor, so it reuses the previous real delta (falling back
        // to the nominal duration only when no real timing is available).
        int dur;
        if (i + 1 < pkts.length) {
          final delta = pkts[i + 1].ptsUs - p.ptsUs;
          dur = delta > 0
              ? delta
              : (p.durationUs > 0 ? p.durationUs : defaultDur);
        } else {
          dur = durations.isNotEmpty
              ? durations.last
              : (p.durationUs > 0 ? p.durationUs : defaultDur);
        }
        durations.add(dur);
        // Every AAC frame is a sync sample; for video honour the keyframe flag.
        keyframes.add(t.isVideo ? p.isKeyframe : true);
      }

      final mediaDuration = durations.fold<int>(0, (a, b) => a + b);
      final startOffset = pkts.isEmpty ? 0 : (pkts.first.ptsUs - globalOrigin);
      final clampedStart = startOffset < 0 ? 0 : startOffset;
      final trackTotal = clampedStart + mediaDuration;
      if (trackTotal > movieDurationUs) movieDurationUs = trackTotal;

      layouts.add(
        _TrackLayout(
          track: t,
          sampleSizes: sizes,
          sampleDurations: durations,
          keyframeFlags: keyframes,
          chunkOffset: chunkOffset,
          mediaDurationUs: mediaDuration,
          startOffsetUs: clampedStart,
        ),
      );
    }

    final mdatPayload = mdatBody.toBytes();
    final moov = _moov(layouts, movieDurationUs);

    final out = BytesBuilder(copy: false);
    out.add(ftyp);
    final mdatHeader = BytesBuilder(copy: false);
    _writeU32(mdatHeader, mdatHeaderSize + mdatPayload.length);
    _writeFourCc(mdatHeader, 'mdat');
    out.add(mdatHeader.toBytes());
    out.add(mdatPayload);
    out.add(moov);
    return out.toBytes();
  }

  Uint8List _ftyp() {
    final b = BoxBuilder();
    b.fourCc('isom'); // major_brand
    b.u32(512); // minor_version (matches libavformat default)
    b.fourCc('isom');
    b.fourCc('iso6');
    b.fourCc('mp41');
    b.fourCc('av01');
    return box('ftyp', b.toBytes());
  }

  Uint8List _moov(List<_TrackLayout> layouts, int movieDurationUs) {
    final body = BytesBuilder(copy: false);
    body.add(_mvhd(movieDurationUs, nextTrackId: _tracks.length + 1));
    for (final l in layouts) {
      body.add(_trak(l));
    }
    return box('moov', body.toBytes());
  }

  Uint8List _mvhd(int durationUs, {required int nextTrackId}) {
    final b = BoxBuilder();
    b.u32(0); // creation_time
    b.u32(0); // modification_time
    b.u32(_timescale);
    b.u32(durationUs);
    b.u32(0x00010000); // rate 1.0
    b.u16(0x0100); // volume 1.0
    b.u16(0); // reserved
    b.zero(8); // reserved
    // unity matrix
    const matrix = [
      0x00010000, 0, 0, //
      0, 0x00010000, 0, //
      0, 0, 0x40000000,
    ];
    for (final v in matrix) {
      b.u32(v);
    }
    b.zero(24); // pre_defined
    b.u32(nextTrackId); // next_track_ID
    return fullBox('mvhd', 0, 0, b.toBytes());
  }

  Uint8List _trak(_TrackLayout l) {
    final body = BytesBuilder(copy: false);
    body.add(_tkhd(l));
    if (l.startOffsetUs > 0) body.add(_edts(l));
    body.add(_mdia(l));
    return box('trak', body.toBytes());
  }

  Uint8List _tkhd(_TrackLayout l) {
    final t = l.track;
    final b = BoxBuilder();
    b.u32(0); // creation_time
    b.u32(0); // modification_time
    b.u32(t.trackId); // track_ID
    b.u32(0); // reserved
    b.u32(l.startOffsetUs + l.mediaDurationUs); // duration (movie timescale)
    b.zero(8); // reserved
    b.u16(0); // layer
    b.u16(0); // alternate_group
    b.u16(t.isVideo ? 0 : 0x0100); // volume: 1.0 for audio, 0 for video
    b.u16(0); // reserved
    const matrix = [
      0x00010000, 0, 0, //
      0, 0x00010000, 0, //
      0, 0, 0x40000000,
    ];
    for (final v in matrix) {
      b.u32(v);
    }
    if (t.isVideo) {
      b.u32(t.video!.width << 16);
      b.u32(t.video!.height << 16);
    } else {
      b.u32(0); // width
      b.u32(0); // height
    }
    // version=0, flags = 0x000007 (enabled, in_movie, in_preview)
    return fullBox('tkhd', 0, 0x000007, b.toBytes());
  }

  Uint8List _edts(_TrackLayout l) {
    // One empty edit to skip the initial gap, then one normal edit covering
    // the media. Keeps later-starting tracks (e.g. audio) aligned to video.
    final body = BytesBuilder(copy: false);
    _writeU32(body, 2); // entry_count
    // empty edit: media_time = -1
    _writeU32(body, l.startOffsetUs); // segment_duration (movie timescale)
    _writeS32(body, -1); // media_time
    _writeU32(body, 0x00010000); // media_rate 1.0 (integer<<16 | fraction)
    // normal edit
    _writeU32(body, l.mediaDurationUs);
    _writeS32(body, 0);
    _writeU32(body, 0x00010000);
    final elst = fullBox('elst', 0, 0, body.toBytes());
    return box('edts', elst);
  }

  Uint8List _mdia(_TrackLayout l) {
    final body = BytesBuilder(copy: false);
    body.add(_mdhd(l.mediaDurationUs));
    body.add(_hdlr(l.track.isVideo));
    body.add(_minf(l));
    return box('mdia', body.toBytes());
  }

  Uint8List _mdhd(int durationUs) {
    final b = BoxBuilder();
    b.u32(0);
    b.u32(0);
    b.u32(_timescale);
    b.u32(durationUs);
    // language: 'und' packed as 5+5+5 bits
    b.u16(0x55c4);
    b.u16(0); // pre_defined
    return fullBox('mdhd', 0, 0, b.toBytes());
  }

  Uint8List _hdlr(bool isVideo) {
    final b = BoxBuilder();
    b.u32(0); // pre_defined
    b.fourCc(isVideo ? 'vide' : 'soun');
    b.zero(12); // reserved[3]
    final name = isVideo ? 'VideoHandler' : 'SoundHandler';
    b.bytes(name.codeUnits);
    b.u8(0);
    return fullBox('hdlr', 0, 0, b.toBytes());
  }

  Uint8List _minf(_TrackLayout l) {
    final body = BytesBuilder(copy: false);
    body.add(l.track.isVideo ? _vmhd() : _smhd());
    body.add(_dinf());
    body.add(_stbl(l));
    return box('minf', body.toBytes());
  }

  Uint8List _vmhd() {
    final b = BoxBuilder();
    b.u16(0); // graphicsmode
    b.u16(0); // opcolor R
    b.u16(0);
    b.u16(0);
    return fullBox('vmhd', 0, 1, b.toBytes());
  }

  Uint8List _smhd() {
    final b = BoxBuilder();
    b.u16(0); // balance
    b.u16(0); // reserved
    return fullBox('smhd', 0, 0, b.toBytes());
  }

  Uint8List _dinf() {
    // dref with one self-reference url entry
    final url = fullBox('url ', 0, 1, const []);
    final drefBody = BytesBuilder(copy: false);
    _writeU32(drefBody, 1); // entry_count
    drefBody.add(url);
    final dref = fullBox('dref', 0, 0, drefBody.toBytes());
    return box('dinf', dref);
  }

  Uint8List _stbl(_TrackLayout l) {
    final body = BytesBuilder(copy: false);
    body.add(_stsd(l.track));
    body.add(_stts(l.sampleDurations));
    body.add(_stsc(l.sampleSizes.length));
    body.add(_stsz(l.sampleSizes));
    body.add(_stco(l.sampleSizes.isEmpty ? const [] : [l.chunkOffset]));
    if (l.track.isVideo) body.add(_stss(l.keyframeFlags));
    return box('stbl', body.toBytes());
  }

  Uint8List _stsd(_MuxTrack t) {
    final entry = t.isVideo ? _av01SampleEntry(t) : _mp4aSampleEntry(t);
    final body = BytesBuilder(copy: false);
    _writeU32(body, 1); // entry_count
    body.add(entry);
    return fullBox('stsd', 0, 0, body.toBytes());
  }

  Uint8List _av01SampleEntry(_MuxTrack t) {
    // VisualSampleEntry (per ISO 14496-12) + av1C
    final b = BoxBuilder();
    b.zero(6); // reserved
    b.u16(1); // data_reference_index
    // VisualSampleEntry pre_defined + reserved
    b.u16(0); // pre_defined
    b.u16(0); // reserved
    b.u32(0); // pre_defined
    b.u32(0);
    b.u32(0);
    b.u16(t.video!.width);
    b.u16(t.video!.height);
    b.u32(0x00480000); // horizresolution 72 dpi
    b.u32(0x00480000); // vertresolution 72 dpi
    b.u32(0); // reserved
    b.u16(1); // frame_count
    // compressorname: 32 bytes, first byte is length
    final name = 'minigpu-av1';
    b.u8(name.length);
    b.bytes(name.codeUnits);
    b.zero(31 - name.length);
    b.u16(0x0018); // depth = 24
    b.u16(0xffff); // pre_defined = -1
    // child boxes
    final av1c = _av1cBox(t);
    b.bytes(av1c);
    return box('av01', b.toBytes());
  }

  Uint8List _av1cBox(_MuxTrack t) {
    // The av1C record IS the box payload — no fullbox header.
    return box('av1C', t.av1C!);
  }

  Uint8List _mp4aSampleEntry(_MuxTrack t) {
    final a = t.audio!;
    final b = BoxBuilder();
    b.zero(6); // reserved
    b.u16(1); // data_reference_index
    // AudioSampleEntry
    b.u32(0); // reserved[0]
    b.u32(0); // reserved[1]
    b.u16(a.channels); // channelcount
    b.u16(16); // samplesize
    b.u16(0); // pre_defined
    b.u16(0); // reserved
    b.u32(a.sampleRate << 16); // samplerate (16.16)
    b.bytes(_esds(t.asc!));
    return box('mp4a', b.toBytes());
  }

  Uint8List _esds(Uint8List asc) {
    // DecoderSpecificInfo (tag 0x05) carrying the AudioSpecificConfig.
    final dsi = _descriptor(0x05, asc);
    // DecoderConfigDescriptor (tag 0x04).
    final dcd = BytesBuilder(copy: false);
    dcd.addByte(0x40); // objectTypeIndication: Audio ISO/IEC 14496-3 (AAC)
    dcd.addByte(0x15); // streamType=5(audio)<<2 | upStream=0 | reserved=1
    dcd
      ..addByte(0)
      ..addByte(0)
      ..addByte(0); // bufferSizeDB (24-bit)
    _writeU32(dcd, 0); // maxBitrate
    _writeU32(dcd, 0); // avgBitrate
    dcd.add(dsi);
    final dcdDesc = _descriptor(0x04, dcd.toBytes());
    // SLConfigDescriptor (tag 0x06): predefined = 2 (MP4).
    final sl = _descriptor(0x06, const [0x02]);
    // ES_Descriptor (tag 0x03).
    final es = BytesBuilder(copy: false);
    es
      ..addByte(0)
      ..addByte(0); // ES_ID (u16)
    es.addByte(0); // flags
    es.add(dcdDesc);
    es.add(sl);
    final esDesc = _descriptor(0x03, es.toBytes());
    return fullBox('esds', 0, 0, esDesc);
  }

  Uint8List _descriptor(int tag, List<int> payload) {
    final b = BytesBuilder(copy: false);
    b.addByte(tag);
    final size = payload.length;
    // 4-byte expanded size field (continuation form), accepted everywhere.
    b.addByte(0x80 | ((size >> 21) & 0x7f));
    b.addByte(0x80 | ((size >> 14) & 0x7f));
    b.addByte(0x80 | ((size >> 7) & 0x7f));
    b.addByte(size & 0x7f);
    b.add(payload);
    return b.toBytes();
  }

  static Uint8List _buildAacAsc({
    required int sampleRate,
    required int channels,
  }) {
    const freqTable = [
      96000, 88200, 64000, 48000, 44100, 32000, //
      24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ];
    var idx = freqTable.indexOf(sampleRate);
    if (idx < 0) idx = 4; // fall back to 44100 if unusual
    const aot = 2; // AAC-LC
    final ch = channels.clamp(1, 7);
    final byte0 = (aot << 3) | ((idx >> 1) & 0x07);
    final byte1 = ((idx & 1) << 7) | ((ch & 0x0f) << 3);
    return Uint8List.fromList([byte0, byte1]);
  }

  Uint8List _stts(List<int> durationsUs) {
    // Run-length encode equal durations to keep the box small.
    final runs = <List<int>>[]; // [count, duration]
    for (final d in durationsUs) {
      if (runs.isNotEmpty && runs.last[1] == d) {
        runs.last[0]++;
      } else {
        runs.add([1, d]);
      }
    }
    final body = BytesBuilder(copy: false);
    _writeU32(body, runs.length);
    for (final run in runs) {
      _writeU32(body, run[0]);
      _writeU32(body, run[1]);
    }
    return fullBox('stts', 0, 0, body.toBytes());
  }

  Uint8List _stsc(int sampleCount) {
    // One chunk per track holding every sample.
    final body = BytesBuilder(copy: false);
    if (sampleCount == 0) {
      _writeU32(body, 0); // entry_count
    } else {
      _writeU32(body, 1); // entry_count
      _writeU32(body, 1); // first_chunk
      _writeU32(body, sampleCount); // samples_per_chunk
      _writeU32(body, 1); // sample_description_index
    }
    return fullBox('stsc', 0, 0, body.toBytes());
  }

  Uint8List _stsz(List<int> sizes) {
    final body = BytesBuilder(copy: false);
    _writeU32(body, 0); // sample_size = 0 → per-sample table follows
    _writeU32(body, sizes.length);
    for (final s in sizes) {
      _writeU32(body, s);
    }
    return fullBox('stsz', 0, 0, body.toBytes());
  }

  Uint8List _stco(List<int> offsets) {
    final body = BytesBuilder(copy: false);
    _writeU32(body, offsets.length);
    for (final o in offsets) {
      _writeU32(body, o);
    }
    return fullBox('stco', 0, 0, body.toBytes());
  }

  Uint8List _stss(List<bool> keyframeFlags) {
    // Sync-sample table: list of 1-based sample indices that are keyframes.
    final body = BytesBuilder(copy: false);
    final keys = <int>[];
    for (var i = 0; i < keyframeFlags.length; i++) {
      if (keyframeFlags[i]) keys.add(i + 1);
    }
    _writeU32(body, keys.length);
    for (final k in keys) {
      _writeU32(body, k);
    }
    return fullBox('stss', 0, 0, body.toBytes());
  }
}

void _writeU32(BytesBuilder out, int v) {
  out.addByte((v >> 24) & 0xff);
  out.addByte((v >> 16) & 0xff);
  out.addByte((v >> 8) & 0xff);
  out.addByte(v & 0xff);
}

void _writeS32(BytesBuilder out, int v) => _writeU32(out, v & 0xffffffff);

void _writeFourCc(BytesBuilder out, String s) {
  for (var i = 0; i < 4; i++) {
    out.addByte(s.codeUnitAt(i));
  }
}

/// Build the `av1C` configuration record body (the payload of the `av1C`
/// box, not including the box header).
///
/// Per ISO/IEC 14496-15 §12.2.1.2:
/// ```
/// marker(1)=1, version(7)=1
/// seq_profile(3), seq_level_idx_0(5)
/// seq_tier_0(1), high_bitdepth(1), twelve_bit(1), monochrome(1),
///   chroma_subsampling_x(1), chroma_subsampling_y(1), chroma_sample_position(2)
/// reserved(3)=0, initial_presentation_delay_present(1)
/// initial_presentation_delay_minus_one(4) | reserved(4)
/// configOBUs (Sequence Header OBU bytes — including its OBU header)
/// ```
Uint8List buildAv1ConfigRecord({
  required int seqProfile,
  required int seqLevelIdx0,
  required int seqTier0,
  required bool highBitDepth,
  required bool twelveBit,
  required bool monochrome,
  required int chromaSubsamplingX,
  required int chromaSubsamplingY,
  required int chromaSamplePosition,
  required Uint8List sequenceHeaderObu,
}) {
  final b = BoxBuilder();
  // byte 0: marker=1, version=1 → 0b1000_0001
  b.u8(0x81);
  // byte 1: seq_profile(3) | seq_level_idx_0(5)
  b.u8(((seqProfile & 0x7) << 5) | (seqLevelIdx0 & 0x1f));
  // byte 2: tier(1)|hbd(1)|12bit(1)|mono(1)|ssX(1)|ssY(1)|csp(2)
  b.u8(
    ((seqTier0 & 1) << 7) |
        ((highBitDepth ? 1 : 0) << 6) |
        ((twelveBit ? 1 : 0) << 5) |
        ((monochrome ? 1 : 0) << 4) |
        ((chromaSubsamplingX & 1) << 3) |
        ((chromaSubsamplingY & 1) << 2) |
        (chromaSamplePosition & 0x3),
  );
  // byte 3: reserved(3)=0 | ipd_present(1)=0 | ipd_minus_one(4)|reserved(4)=0
  b.u8(0);
  b.bytes(sequenceHeaderObu);
  return b.toBytes();
}

// Make _writeU32/_writeFourCc available to iso_box_writer.dart users if
// needed; they're top-level here to keep the muxer self-contained.

// ignore: unused_element
const _unusedSentinel = ObuType.sequenceHeader;
