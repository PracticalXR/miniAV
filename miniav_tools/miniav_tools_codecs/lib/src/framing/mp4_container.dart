/// MP4 / ISO-BMFF demuxer — pure Dart, FFmpeg-free.
///
/// Parses ftyp/moov→trak→mdia→minf→stbl (stsd/stts/stsc/stsz/stco/co64/ctts/
/// stss) into a per-track sample table, then emits [EncodedPacket]s across all
/// tracks in file order (each tagged with `trackIndex`), carrying pts (stts +
/// ctts composition offset), dts (stts decode order — so B-frame streams
/// present correctly), keyframe flags (stss), and per-track codec extra-data
/// (avcC / hvcC / av1C / esds→ASC / dOps). Bytes input only; malformed boxes
/// throw [CodecInitException] (→ the negotiator falls through to FFmpeg).
///
/// The ISO-BMFF *writer* lives in `av1/mp4/av1_mp4_muxer.dart`; this is its
/// inverse and round-trips that muxer's output.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../av1/mp4/iso_box_writer.dart';

class _Box {
  _Box(this.type, this.payloadStart, this.payloadEnd, this.end);
  final String type;
  final int payloadStart;
  final int payloadEnd;
  final int end; // start of the next sibling box
}

/// A single decoded sample position, in file order.
class _Sample {
  _Sample(this.trackIndex, this.offset, this.size, this.dtsUs, this.ptsUs,
      this.keyframe);
  final int trackIndex;
  final int offset;
  final int size;
  final int dtsUs;
  final int ptsUs;
  final bool keyframe;
}

class Mp4Demuxer implements PlatformDemuxer {
  Mp4Demuxer._(this.tracks, this._bytes, this._samples);

  @override
  final List<TrackInfo> tracks;
  final Uint8List _bytes;
  final List<_Sample> _samples;
  int _idx = 0;
  bool _closed = false;

  static Mp4Demuxer open(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);

    // Locate moov (samples are referenced by absolute file offset via stco, so
    // mdat position doesn't matter — moov may come before or after it).
    _Box? moov;
    for (final b in _walk(d, 0, d.lengthInBytes)) {
      if (b.type == 'moov') {
        moov = b;
        break;
      }
    }
    if (moov == null) {
      throw const CodecInitException('mp4', 'no moov box');
    }

    final tracks = <TrackInfo>[];
    final samples = <_Sample>[];
    for (final b in _walk(d, moov.payloadStart, moov.payloadEnd)) {
      if (b.type != 'trak') continue;
      _parseTrack(d, bytes, b, tracks, samples);
    }
    if (tracks.isEmpty) {
      throw const CodecInitException('mp4', 'no tracks in moov');
    }
    if (samples.isEmpty) {
      // A track with no stbl samples means the media lives in movie fragments
      // (moof/traf — fragmented MP4 / CMAF), which this reader doesn't handle.
      // Throw so the negotiator falls through to FFmpeg instead of yielding an
      // empty stream.
      throw const CodecInitException(
          'mp4', 'no stbl samples (fragmented MP4?) — deferring to fallback');
    }

    // Present samples in file order (this is the on-disk interleave).
    samples.sort((a, b) => a.offset - b.offset);
    return Mp4Demuxer._(tracks, bytes, samples);
  }

  static void _parseTrack(
    ByteData d,
    Uint8List bytes,
    _Box trak,
    List<TrackInfo> tracks,
    List<_Sample> samples,
  ) {
    // This track will occupy index `tracks.length` once added; tag its samples
    // with that so `trackIndex` stays in sync even if an earlier track was
    // skipped.
    final trackIndex = tracks.length;
    final rotation = _tkhdRotation(d, _child(d, trak, 'tkhd'));
    final mdia = _child(d, trak, 'mdia');
    if (mdia == null) return;

    // mdhd → timescale.
    final mdhd = _child(d, mdia, 'mdhd');
    var timescale = 1000000;
    if (mdhd != null) {
      final v = d.getUint8(mdhd.payloadStart);
      // version(1)+flags(3); v0: [c4 m4 timescale4 dur4]; v1: [c8 m8 timescale4 dur8]
      final tsOff = mdhd.payloadStart + 4 + (v == 1 ? 16 : 8);
      timescale = d.getUint32(tsOff, Endian.big);
      if (timescale <= 0) timescale = 1000000;
    }

    final hdlr = _child(d, mdia, 'hdlr');
    var isVideo = false;
    if (hdlr != null) {
      // hdlr payload: version+flags(4) + pre_defined(4) + handler_type(4cc).
      final handler = _fourccAt(d, hdlr.payloadStart + 8);
      isVideo = handler == 'vide';
    }

    final minf = _child(d, mdia, 'minf');
    final stbl = minf == null ? null : _child(d, minf, 'stbl');
    if (stbl == null) return;

    final stsd = _child(d, stbl, 'stsd');
    if (stsd == null) return;
    final codecInfo = _parseStsd(d, stsd, isVideo);
    if (codecInfo == null) return;

    // Sample tables.
    final sizes = _parseStsz(d, _child(d, stbl, 'stsz'));
    final durations = _parseStts(d, _child(d, stbl, 'stts'), sizes.length);
    final ctts = _parseCtts(d, _child(d, stbl, 'ctts'), sizes.length);
    final offsets = _sampleOffsets(d, stbl, sizes);
    final keyframes = _parseStss(d, _child(d, stbl, 'stss'), sizes.length);

    // Build per-sample timing (ticks → µs) in decode order.
    int us(int ticks) => (ticks * 1000000) ~/ timescale;
    var dtsTicks = 0;
    for (var i = 0; i < sizes.length; i++) {
      final dts = us(dtsTicks);
      final pts = us(dtsTicks + ctts[i]);
      samples.add(_Sample(
        trackIndex,
        offsets[i],
        sizes[i],
        dts,
        pts,
        keyframes == null ? true : keyframes.contains(i),
      ));
      dtsTicks += durations[i];
    }

    tracks.add(codecInfo.isVideo
        ? VideoTrackInfo(
            codec: codecInfo.videoCodec!,
            width: codecInfo.width,
            height: codecInfo.height,
            frameRateNumerator: 0,
            frameRateDenominator: 1,
            extraData: codecInfo.extraData,
            rotationDegrees: rotation,
          )
        : AudioTrackInfo(
            codec: codecInfo.audioCodec!,
            sampleRate: codecInfo.sampleRate,
            channels: codecInfo.channels,
            extraData: codecInfo.extraData,
          ));
  }

  /// Display rotation (degrees clockwise: 0/90/180/270) from the tkhd
  /// transformation matrix — how phone-shot "sideways" video declares its
  /// orientation. tkhd payload: version(1)+flags(3), then v0: 5×u32 / v1:
  /// 8+8+4+4+8 bytes of times/id/duration, then reserved(8) + layer(2) +
  /// alt_group(2) + volume(2) + reserved(2), then the 3×3 matrix as 9×s32
  /// (16.16 fixed for a,b,c,d). Rotation lives in the (a,b,c,d) 2×2:
  ///   ( 1, 0, 0, 1)=0°  (0, 1,-1, 0)=90°  (-1, 0, 0,-1)=180°  (0,-1, 1, 0)=270°
  /// Anything else (scales, flips, arbitrary transforms) → 0 (unsupported).
  static int _tkhdRotation(ByteData d, _Box? tkhd) {
    if (tkhd == null) return 0;
    final v = d.getUint8(tkhd.payloadStart);
    final matrixOff =
        tkhd.payloadStart + 4 + (v == 1 ? 32 : 20) + 16; // → matrix[0]
    if (matrixOff + 36 > tkhd.payloadEnd) return 0;
    const one = 0x10000; // 1.0 in 16.16
    final a = d.getInt32(matrixOff, Endian.big);
    final b = d.getInt32(matrixOff + 4, Endian.big);
    final c = d.getInt32(matrixOff + 12, Endian.big);
    final e = d.getInt32(matrixOff + 16, Endian.big); // 'd' in the matrix
    if (a == one && b == 0 && c == 0 && e == one) return 0;
    if (a == 0 && b == one && c == -one && e == 0) return 90;
    if (a == -one && b == 0 && c == 0 && e == -one) return 180;
    if (a == 0 && b == -one && c == one && e == 0) return 270;
    return 0;
  }

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();
    if (_idx >= _samples.length) return null;
    final s = _samples[_idx++];
    if (s.offset + s.size > _bytes.length) return null;
    final data = Uint8List.sublistView(_bytes, s.offset, s.offset + s.size);
    return EncodedPacket(
      data: Uint8List.fromList(data),
      ptsUs: s.ptsUs,
      dtsUs: s.dtsUs,
      isKeyframe: s.keyframe,
      trackIndex: s.trackIndex,
    );
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    // Seek to the last keyframe at/before the target (in file order).
    var target = 0;
    for (var i = 0; i < _samples.length; i++) {
      if (_samples[i].ptsUs <= timestampUs && _samples[i].keyframe) target = i;
      if (_samples[i].ptsUs > timestampUs) break;
    }
    _idx = target;
  }

  @override
  int? get durationUs {
    var max = 0;
    for (final s in _samples) {
      if (s.ptsUs > max) max = s.ptsUs;
    }
    return _samples.isEmpty ? null : max;
  }

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async => _closed = true;

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('mp4', 'demuxer closed');
  }
}

// --- box walking -------------------------------------------------------------

Iterable<_Box> _walk(ByteData d, int start, int end) sync* {
  var pos = start;
  while (pos + 8 <= end) {
    var size = d.getUint32(pos, Endian.big);
    final type = _fourccAt(d, pos + 4);
    var headerLen = 8;
    if (size == 1) {
      if (pos + 16 > end) return;
      final hi = d.getUint32(pos + 8, Endian.big);
      final lo = d.getUint32(pos + 12, Endian.big);
      size = (hi << 32) | lo;
      headerLen = 16;
    } else if (size == 0) {
      size = end - pos; // extends to container end
    }
    if (size < headerLen || pos + size > end) return; // malformed / truncated
    yield _Box(type, pos + headerLen, pos + size, pos + size);
    pos += size;
  }
}

_Box? _child(ByteData d, _Box parent, String type) {
  for (final b in _walk(d, parent.payloadStart, parent.payloadEnd)) {
    if (b.type == type) return b;
  }
  return null;
}

String _fourccAt(ByteData d, int off) =>
    String.fromCharCodes([for (var i = 0; i < 4; i++) d.getUint8(off + i)]);

// --- stsd (codec + extra-data) ----------------------------------------------

class _CodecInfo {
  _CodecInfo.video(this.videoCodec, this.width, this.height, this.extraData)
      : isVideo = true,
        audioCodec = null,
        sampleRate = 0,
        channels = 0;
  _CodecInfo.audio(this.audioCodec, this.sampleRate, this.channels, this.extraData)
      : isVideo = false,
        videoCodec = null,
        width = 0,
        height = 0;

  final bool isVideo;
  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;
  final int width, height, sampleRate, channels;
  final CodecExtraData? extraData;
}

_CodecInfo? _parseStsd(ByteData d, _Box stsd, bool isVideo) {
  // fullBox(4) + entry_count(4) + first sample entry (a box).
  final entriesStart = stsd.payloadStart + 8;
  final entry = _walk(d, entriesStart, stsd.payloadEnd).firstOrNull;
  if (entry == null) return null;
  final fmt = entry.type;

  if (isVideo) {
    // VisualSampleEntry: 8 (reserved+dref) + 70 fixed, then child config boxes.
    final w = d.getUint16(entry.payloadStart + 24, Endian.big);
    final h = d.getUint16(entry.payloadStart + 26, Endian.big);
    final childStart = entry.payloadStart + 78;
    Uint8List? cfg;
    for (final cb in _walk(d, childStart, entry.payloadEnd)) {
      if (cb.type == 'avcC' || cb.type == 'hvcC' || cb.type == 'av1C') {
        cfg = _slice(d, cb.payloadStart, cb.payloadEnd);
        break;
      }
    }
    final VideoCodec codec;
    switch (fmt) {
      case 'avc1':
      case 'avc3':
        codec = VideoCodec.h264;
      case 'hev1':
      case 'hvc1':
        codec = VideoCodec.hevc;
      case 'av01':
        codec = VideoCodec.av1;
      default:
        return null; // unsupported video sample entry → fall through
    }
    return _CodecInfo.video(
      codec,
      w,
      h,
      cfg == null ? null : CodecExtraData.video(codec, cfg),
    );
  }

  // AudioSampleEntry: 8 (reserved+dref) + 20 fixed, then esds/dOps.
  final channels = d.getUint16(entry.payloadStart + 16, Endian.big);
  final sampleRate = d.getUint32(entry.payloadStart + 24, Endian.big) >> 16;
  final childStart = entry.payloadStart + 28;
  if (fmt == 'mp4a') {
    Uint8List? asc;
    for (final cb in _walk(d, childStart, entry.payloadEnd)) {
      if (cb.type == 'esds') {
        asc = _ascFromEsds(d, cb);
        break;
      }
    }
    return _CodecInfo.audio(
      AudioCodec.aac,
      sampleRate,
      channels,
      asc == null ? null : CodecExtraData.audio(AudioCodec.aac, asc),
    );
  }
  if (fmt == 'Opus') {
    Uint8List? head;
    for (final cb in _walk(d, childStart, entry.payloadEnd)) {
      if (cb.type == 'dOps') {
        head = _opusHeadFromDops(d, cb, channels, sampleRate);
        break;
      }
    }
    return _CodecInfo.audio(
      AudioCodec.opus,
      sampleRate == 0 ? 48000 : sampleRate,
      channels,
      head == null ? null : CodecExtraData.audio(AudioCodec.opus, head),
    );
  }
  return null;
}

/// Extract the AudioSpecificConfig from an esds box (ES_Descriptor →
/// DecoderConfigDescriptor(0x04) → DecoderSpecificInfo(0x05)).
Uint8List? _ascFromEsds(ByteData d, _Box esds) {
  var p = esds.payloadStart + 4; // skip fullBox version+flags
  final end = esds.payloadEnd;
  // ES_Descriptor (0x03).
  final es = _readDescriptor(d, p, end);
  if (es == null || es.tag != 0x03) return null;
  // ES_Descriptor payload: ES_ID(2) + flags(1) + sub-descriptors.
  var q = es.payloadStart + 3;
  while (q < es.payloadEnd) {
    final desc = _readDescriptor(d, q, es.payloadEnd);
    if (desc == null) break;
    if (desc.tag == 0x04) {
      // DecoderConfigDescriptor: 13 bytes then DecoderSpecificInfo(0x05).
      var r = desc.payloadStart + 13;
      while (r < desc.payloadEnd) {
        final inner = _readDescriptor(d, r, desc.payloadEnd);
        if (inner == null) break;
        if (inner.tag == 0x05) {
          return _slice(d, inner.payloadStart, inner.payloadEnd);
        }
        r = inner.end;
      }
    }
    q = desc.end;
  }
  return null;
}

class _Descriptor {
  _Descriptor(this.tag, this.payloadStart, this.payloadEnd, this.end);
  final int tag;
  final int payloadStart;
  final int payloadEnd;
  final int end;
}

/// Read an MPEG-4 descriptor: tag(1) + expandable size + payload.
_Descriptor? _readDescriptor(ByteData d, int pos, int end) {
  if (pos + 1 > end) return null;
  final tag = d.getUint8(pos);
  var p = pos + 1;
  var size = 0;
  for (var i = 0; i < 4; i++) {
    if (p >= end) return null;
    final b = d.getUint8(p++);
    size = (size << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) break;
  }
  final payloadEnd = p + size;
  if (payloadEnd > end) return null;
  return _Descriptor(tag, p, payloadEnd, payloadEnd);
}

/// Reconstruct an OpusHead from a `dOps` box (channels/pre-skip/rate) so the
/// Opus decoder can honour channels + pre-skip.
Uint8List _opusHeadFromDops(ByteData d, _Box dops, int channels, int rate) {
  // dOps: Version(1) OutputChannelCount(1) PreSkip(2 BE) InputSampleRate(4 BE) ...
  final b = Uint8List(19);
  b.setRange(0, 8, 'OpusHead'.codeUnits);
  b[8] = 1;
  final ch = d.getUint8(dops.payloadStart + 1);
  b[9] = ch == 0 ? channels : ch;
  final preSkip = d.getUint16(dops.payloadStart + 2, Endian.big);
  final bd = ByteData.sublistView(b);
  bd.setUint16(10, preSkip, Endian.little); // OpusHead pre-skip is LE
  bd.setUint32(12, rate == 0 ? 48000 : rate, Endian.little);
  return b;
}

// --- sample tables -----------------------------------------------------------

List<int> _parseStsz(ByteData d, _Box? stsz) {
  if (stsz == null) return const [];
  var p = stsz.payloadStart + 4; // fullBox
  final sampleSize = d.getUint32(p, Endian.big);
  final count = d.getUint32(p + 4, Endian.big);
  p += 8;
  if (sampleSize != 0) {
    return List<int>.filled(count, sampleSize);
  }
  final out = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    out[i] = d.getUint32(p + i * 4, Endian.big);
  }
  return out;
}

List<int> _parseStts(ByteData d, _Box? stts, int sampleCount) {
  final out = List<int>.filled(sampleCount, 0);
  if (stts == null) return out;
  var p = stts.payloadStart + 4;
  final entries = d.getUint32(p, Endian.big);
  p += 4;
  var i = 0;
  for (var e = 0; e < entries && i < sampleCount; e++) {
    final n = d.getUint32(p, Endian.big);
    final delta = d.getUint32(p + 4, Endian.big);
    p += 8;
    for (var k = 0; k < n && i < sampleCount; k++) {
      out[i++] = delta;
    }
  }
  return out;
}

List<int> _parseCtts(ByteData d, _Box? ctts, int sampleCount) {
  final out = List<int>.filled(sampleCount, 0);
  if (ctts == null) return out;
  final version = d.getUint8(ctts.payloadStart);
  var p = ctts.payloadStart + 4;
  final entries = d.getUint32(p, Endian.big);
  p += 4;
  var i = 0;
  for (var e = 0; e < entries && i < sampleCount; e++) {
    final n = d.getUint32(p, Endian.big);
    // version 1 uses signed composition offsets.
    final off = version == 1
        ? d.getInt32(p + 4, Endian.big)
        : d.getUint32(p + 4, Endian.big);
    p += 8;
    for (var k = 0; k < n && i < sampleCount; k++) {
      out[i++] = off;
    }
  }
  return out;
}

Set<int>? _parseStss(ByteData d, _Box? stss, int sampleCount) {
  if (stss == null) return null; // no stss → every sample is a sync sample
  var p = stss.payloadStart + 4;
  final entries = d.getUint32(p, Endian.big);
  p += 4;
  final out = <int>{};
  for (var e = 0; e < entries; e++) {
    out.add(d.getUint32(p, Endian.big) - 1); // 1-based → 0-based
    p += 4;
  }
  return out;
}

/// Compute each sample's absolute file offset from stsc (sample→chunk) + stco/
/// co64 (chunk offsets).
List<int> _sampleOffsets(ByteData d, _Box stbl, List<int> sizes) {
  final chunkOffsets = _parseChunkOffsets(d, stbl);
  final stsc = _child(d, stbl, 'stsc');
  final out = List<int>.filled(sizes.length, 0);
  if (chunkOffsets.isEmpty || stsc == null) return out;

  // stsc entries: [first_chunk, samples_per_chunk, sample_desc_index].
  var p = stsc.payloadStart + 4;
  final entryCount = d.getUint32(p, Endian.big);
  p += 4;
  final firstChunk = <int>[];
  final samplesPerChunk = <int>[];
  for (var e = 0; e < entryCount; e++) {
    firstChunk.add(d.getUint32(p, Endian.big));
    samplesPerChunk.add(d.getUint32(p + 4, Endian.big));
    p += 12;
  }

  var sampleIdx = 0;
  for (var c = 0; c < chunkOffsets.length && sampleIdx < sizes.length; c++) {
    // samples in chunk c (1-based chunk number = c+1).
    var spc = 1;
    for (var e = 0; e < firstChunk.length; e++) {
      if (firstChunk[e] <= c + 1) spc = samplesPerChunk[e];
    }
    var off = chunkOffsets[c];
    for (var s = 0; s < spc && sampleIdx < sizes.length; s++) {
      out[sampleIdx] = off;
      off += sizes[sampleIdx];
      sampleIdx++;
    }
  }
  return out;
}

List<int> _parseChunkOffsets(ByteData d, _Box stbl) {
  final stco = _child(d, stbl, 'stco');
  if (stco != null) {
    var p = stco.payloadStart + 4;
    final n = d.getUint32(p, Endian.big);
    p += 4;
    return [for (var i = 0; i < n; i++) d.getUint32(p + i * 4, Endian.big)];
  }
  final co64 = _child(d, stbl, 'co64');
  if (co64 != null) {
    var p = co64.payloadStart + 4;
    final n = d.getUint32(p, Endian.big);
    p += 4;
    return [
      for (var i = 0; i < n; i++)
        (d.getUint32(p + i * 8, Endian.big) << 32) |
            d.getUint32(p + i * 8 + 4, Endian.big),
    ];
  }
  return const [];
}

Uint8List _slice(ByteData d, int start, int end) =>
    Uint8List.sublistView(d.buffer.asUint8List(d.offsetInBytes), start, end);

// =============================================================================
// Mp4Muxer — general ISO-BMFF writer (H.264/HEVC/AV1 video + AAC/Opus audio).
// =============================================================================

class _MuxT {
  _MuxT(this.info, this.isVideo, this.config);
  final TrackInfo info;
  final bool isVideo;
  final Uint8List config; // avcC/hvcC/av1C, or ASC/OpusHead for audio
  final List<EncodedPacket> packets = [];
}

/// Writes H.264/HEVC/AV1 video + AAC/Opus audio into an ISO-BMFF (`.mp4`) byte
/// stream, `moov` after `mdat` (single chunk per track). The inverse of
/// [Mp4Demuxer]; a superset of the AV1-only muxer. Timescale is microseconds.
class Mp4Muxer implements PlatformMuxer {
  Mp4Muxer._(this._tracks);

  static const int _timescale = 1000000;
  final List<_MuxT> _tracks;
  bool _headerWritten = false;
  bool _finished = false;
  bool _closed = false;
  Uint8List? _out;

  static const _video = {VideoCodec.h264, VideoCodec.hevc, VideoCodec.av1};
  static const _audio = {AudioCodec.aac, AudioCodec.opus};

  static Mp4Muxer open(MuxerConfig config) {
    if (config.tracks.isEmpty) {
      throw const CodecInitException('mp4', 'MP4 needs at least one track');
    }
    final tracks = <_MuxT>[];
    for (final t in config.tracks) {
      if (t is VideoTrackInfo) {
        if (!_video.contains(t.codec)) {
          throw CodecInitException('mp4', 'unsupported video codec ${t.codec}');
        }
        final cfg = t.extraData?.bytes;
        if (cfg == null || cfg.isEmpty) {
          throw CodecInitException(
              'mp4', '${t.codec} track needs its config record in extraData');
        }
        tracks.add(_MuxT(t, true, Uint8List.fromList(cfg)));
      } else if (t is AudioTrackInfo) {
        if (!_audio.contains(t.codec)) {
          throw CodecInitException('mp4', 'unsupported audio codec ${t.codec}');
        }
        final cfg = t.extraData?.bytes ??
            (t.codec == AudioCodec.aac
                ? _buildAsc(t.sampleRate, t.channels)
                : _buildOpusHead(t.channels, t.sampleRate));
        tracks.add(_MuxT(t, false, Uint8List.fromList(cfg)));
      } else {
        throw CodecInitException('mp4', 'unsupported track ${t.runtimeType}');
      }
    }
    return Mp4Muxer._(tracks);
  }

  @override
  Future<void> writeHeader() async {
    _checkOpen();
    _headerWritten = true;
  }

  @override
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) {
      throw const CodecRuntimeException('mp4', 'writePacket before writeHeader');
    }
    final i = packet.trackIndex;
    if (i < 0 || i >= _tracks.length) {
      throw CodecRuntimeException('mp4', 'trackIndex $i out of range');
    }
    _tracks[i].packets.add(packet);
  }

  @override
  Future<void> finish() async {
    _checkOpen();
    if (_finished) return;
    _finished = true;
    _out = _build();
  }

  @override
  List<int>? getBytes() => _out;

  @override
  Future<void> close() async {
    _closed = true;
    for (final t in _tracks) {
      t.packets.clear();
    }
  }

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('mp4', 'muxer closed');
  }

  Uint8List _build() {
    final ftyp = box('ftyp', [
      ...'isom'.codeUnits, 0, 0, 0, 0, //
      ...'isom'.codeUnits, ...'iso2'.codeUnits, ...'mp41'.codeUnits,
    ]);
    const mdatHeader = 8;
    final mdatStart = ftyp.length + mdatHeader;

    // Lay out mdat one track at a time; record each track's chunk offset.
    final mdat = BytesBuilder(copy: false);
    final chunkOffsets = <int>[];
    for (final t in _tracks) {
      chunkOffsets.add(mdatStart + mdat.length);
      for (final p in t.packets) {
        mdat.add(p.data);
      }
    }
    final mdatBody = mdat.toBytes();

    var maxDur = 0;
    final traks = <Uint8List>[];
    for (var i = 0; i < _tracks.length; i++) {
      final dur = _trackDurationUs(_tracks[i]);
      if (dur > maxDur) maxDur = dur;
      traks.add(_trak(_tracks[i], i + 1, chunkOffsets[i]));
    }
    final moov = box('moov', [
      ..._mvhd(maxDur, _tracks.length + 1),
      for (final t in traks) ...t,
    ]);

    final out = BytesBuilder(copy: false);
    out.add(ftyp);
    final mh = BytesBuilder(copy: false);
    _u32(mh, mdatHeader + mdatBody.length);
    mh.add('mdat'.codeUnits);
    out.add(mh.toBytes());
    out.add(mdatBody);
    out.add(moov);
    return out.toBytes();
  }

  int _trackDurationUs(_MuxT t) {
    var d = 0;
    for (final p in t.packets) {
      d += p.durationUs;
    }
    if (d > 0) return d;
    // Fall back to pts span + one frame.
    if (t.packets.length >= 2) {
      final span = t.packets.last.ptsUs - t.packets.first.ptsUs;
      final per = span ~/ (t.packets.length - 1);
      return span + per;
    }
    return t.packets.length * 20000;
  }

  List<int> _durations(_MuxT t) {
    final n = t.packets.length;
    final out = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      if (t.packets[i].durationUs > 0) {
        out[i] = t.packets[i].durationUs;
      } else if (i + 1 < n) {
        out[i] = t.packets[i + 1].ptsUs - t.packets[i].ptsUs;
      } else if (i > 0) {
        out[i] = out[i - 1];
      } else {
        out[i] = 20000;
      }
    }
    return out;
  }

  Uint8List _mvhd(int durationUs, int nextTrackId) {
    final b = BoxBuilder();
    b.u32(0); // creation
    b.u32(0); // modification
    b.u32(_timescale);
    b.u32(durationUs);
    b.u32(0x00010000); // rate 1.0
    b.u16(0x0100); // volume 1.0
    b.u16(0); // reserved
    b.u32(0);
    b.u32(0); // reserved[2]
    for (final m in const [
      0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 //
    ]) {
      b.u32(m); // unity matrix
    }
    b.zero(24); // pre_defined[6]
    b.u32(nextTrackId);
    return fullBox('mvhd', 0, 0, b.toBytes());
  }

  Uint8List _trak(_MuxT t, int trackId, int chunkOffset) {
    final body = <int>[
      ..._tkhd(t, trackId),
      ..._mdia(t, chunkOffset),
    ];
    return box('trak', body);
  }

  Uint8List _tkhd(_MuxT t, int trackId) {
    final b = BoxBuilder();
    b.u32(0); // creation
    b.u32(0); // modification
    b.u32(trackId);
    b.u32(0); // reserved
    b.u32(_trackDurationUs(t));
    b.u32(0);
    b.u32(0); // reserved[2]
    b.u16(0); // layer
    b.u16(0); // alternate_group
    b.u16(t.isVideo ? 0 : 0x0100); // volume
    b.u16(0); // reserved
    for (final m in const [
      0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 //
    ]) {
      b.u32(m);
    }
    if (t.isVideo) {
      final v = t.info as VideoTrackInfo;
      b.u32(v.width << 16);
      b.u32(v.height << 16);
    } else {
      b.u32(0);
      b.u32(0);
    }
    return fullBox('tkhd', 0, 0x000007, b.toBytes()); // enabled|in-movie|preview
  }

  Uint8List _mdia(_MuxT t, int chunkOffset) => box('mdia', [
        ..._mdhd(_trackDurationUs(t)),
        ..._hdlr(t.isVideo),
        ..._minf(t, chunkOffset),
      ]);

  Uint8List _mdhd(int durationUs) {
    final b = BoxBuilder();
    b.u32(0);
    b.u32(0);
    b.u32(_timescale);
    b.u32(durationUs);
    b.u16(0x55c4); // language 'und'
    b.u16(0); // pre_defined
    return fullBox('mdhd', 0, 0, b.toBytes());
  }

  Uint8List _hdlr(bool isVideo) {
    final b = BoxBuilder();
    b.u32(0); // pre_defined
    b.fourCc(isVideo ? 'vide' : 'soun');
    b.zero(12);
    b.bytes((isVideo ? 'VideoHandler' : 'SoundHandler').codeUnits);
    b.u8(0);
    return fullBox('hdlr', 0, 0, b.toBytes());
  }

  Uint8List _minf(_MuxT t, int chunkOffset) => box('minf', [
        ...(t.isVideo ? _vmhd() : _smhd()),
        ..._dinf(),
        ..._stbl(t, chunkOffset),
      ]);

  Uint8List _vmhd() {
    final b = BoxBuilder()..zero(8);
    return fullBox('vmhd', 0, 1, b.toBytes());
  }

  Uint8List _smhd() {
    final b = BoxBuilder()..zero(4);
    return fullBox('smhd', 0, 0, b.toBytes());
  }

  Uint8List _dinf() {
    final url = fullBox('url ', 0, 1, const []);
    final dref = fullBox('dref', 0, 0, [0, 0, 0, 1, ...url]);
    return box('dinf', dref);
  }

  Uint8List _stbl(_MuxT t, int chunkOffset) {
    final sizes = [for (final p in t.packets) p.data.length];
    final body = <int>[
      ..._stsd(t),
      ..._stts(_durations(t)),
      ..._stsc(sizes.length),
      ..._stsz(sizes),
      ..._stco(sizes.isEmpty ? const [] : [chunkOffset]),
      if (t.isVideo) ..._stss(t.packets),
    ];
    return box('stbl', body);
  }

  Uint8List _stsd(_MuxT t) {
    final entry = t.isVideo ? _videoEntry(t) : _audioEntry(t);
    return fullBox('stsd', 0, 0, [0, 0, 0, 1, ...entry]);
  }

  Uint8List _videoEntry(_MuxT t) {
    final v = t.info as VideoTrackInfo;
    final fmt = switch (v.codec) {
      VideoCodec.h264 => 'avc1',
      VideoCodec.hevc => 'hvc1',
      _ => 'av01',
    };
    final cfgType = switch (v.codec) {
      VideoCodec.h264 => 'avcC',
      VideoCodec.hevc => 'hvcC',
      _ => 'av1C',
    };
    final b = BoxBuilder();
    b.zero(6); // reserved
    b.u16(1); // data_reference_index
    b.u16(0); // pre_defined
    b.u16(0); // reserved
    b.u32(0);
    b.u32(0);
    b.u32(0); // pre_defined[3]
    b.u16(v.width);
    b.u16(v.height);
    b.u32(0x00480000); // horizresolution
    b.u32(0x00480000); // vertresolution
    b.u32(0); // reserved
    b.u16(1); // frame_count
    b.zero(32); // compressorname
    b.u16(0x0018); // depth
    b.u16(0xffff); // pre_defined
    b.bytes(box(cfgType, t.config));
    return box(fmt, b.toBytes());
  }

  Uint8List _audioEntry(_MuxT t) {
    final a = t.info as AudioTrackInfo;
    final b = BoxBuilder();
    b.zero(6);
    b.u16(1); // data_reference_index
    b.u32(0);
    b.u32(0); // reserved[2]
    b.u16(a.channels);
    b.u16(16); // samplesize
    b.u16(0); // pre_defined
    b.u16(0); // reserved
    b.u32(a.sampleRate << 16); // samplerate 16.16
    if (a.codec == AudioCodec.opus) {
      b.bytes(_dOps(t.config, a.channels, a.sampleRate));
      return box('Opus', b.toBytes());
    }
    b.bytes(_esds(t.config));
    return box('mp4a', b.toBytes());
  }

  /// dOps box (RFC 7845 §5.1) derived from an OpusHead.
  Uint8List _dOps(Uint8List head, int channels, int rate) {
    final b = BoxBuilder();
    b.u8(0); // version
    final ch = head.length > 9 ? head[9] : channels;
    b.u8(ch);
    final preSkip =
        head.length >= 12 ? (head[10] | (head[11] << 8)) : 0; // OpusHead LE
    b.u16(preSkip); // dOps pre-skip is BE
    b.u32(rate);
    b.u16(0); // output gain
    b.u8(0); // channel mapping family
    return box('dOps', b.toBytes());
  }

  Uint8List _esds(Uint8List asc) {
    final dsi = _descriptor(0x05, asc);
    final dcd = <int>[
      0x40, // AAC
      0x15, // audio stream
      0, 0, 0, // bufferSizeDB
      0, 0, 0, 0, // maxBitrate
      0, 0, 0, 0, // avgBitrate
      ...dsi,
    ];
    final sl = _descriptor(0x06, const [0x02]);
    final es = <int>[0, 0, 0, ..._descriptor(0x04, dcd), ...sl];
    return fullBox('esds', 0, 0, _descriptor(0x03, es));
  }

  List<int> _descriptor(int tag, List<int> payload) {
    final n = payload.length;
    return [
      tag,
      0x80 | ((n >> 21) & 0x7f),
      0x80 | ((n >> 14) & 0x7f),
      0x80 | ((n >> 7) & 0x7f),
      n & 0x7f,
      ...payload,
    ];
  }

  Uint8List _stts(List<int> durs) {
    final runs = <List<int>>[];
    for (final d in durs) {
      if (runs.isNotEmpty && runs.last[1] == d) {
        runs.last[0]++;
      } else {
        runs.add([1, d]);
      }
    }
    final b = BytesBuilder(copy: false);
    _u32(b, runs.length);
    for (final r in runs) {
      _u32(b, r[0]);
      _u32(b, r[1]);
    }
    return fullBox('stts', 0, 0, b.toBytes());
  }

  Uint8List _stsc(int count) {
    final b = BytesBuilder(copy: false);
    if (count == 0) {
      _u32(b, 0);
    } else {
      _u32(b, 1);
      _u32(b, 1); // first_chunk
      _u32(b, count); // samples_per_chunk
      _u32(b, 1); // sample_desc_index
    }
    return fullBox('stsc', 0, 0, b.toBytes());
  }

  Uint8List _stsz(List<int> sizes) {
    final b = BytesBuilder(copy: false);
    _u32(b, 0);
    _u32(b, sizes.length);
    for (final s in sizes) {
      _u32(b, s);
    }
    return fullBox('stsz', 0, 0, b.toBytes());
  }

  Uint8List _stco(List<int> offsets) {
    final b = BytesBuilder(copy: false);
    _u32(b, offsets.length);
    for (final o in offsets) {
      _u32(b, o);
    }
    return fullBox('stco', 0, 0, b.toBytes());
  }

  Uint8List _stss(List<EncodedPacket> packets) {
    final keys = <int>[];
    for (var i = 0; i < packets.length; i++) {
      if (packets[i].isKeyframe) keys.add(i + 1);
    }
    final b = BytesBuilder(copy: false);
    _u32(b, keys.length);
    for (final k in keys) {
      _u32(b, k);
    }
    return fullBox('stss', 0, 0, b.toBytes());
  }

  static Uint8List _buildAsc(int sampleRate, int channels) {
    const freq = [
      96000, 88200, 64000, 48000, 44100, 32000, //
      24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ];
    var idx = freq.indexOf(sampleRate);
    if (idx < 0) idx = 4;
    final ch = channels.clamp(1, 7);
    return Uint8List.fromList([
      (2 << 3) | ((idx >> 1) & 0x07),
      ((idx & 1) << 7) | ((ch & 0x0f) << 3),
    ]);
  }

  static Uint8List _buildOpusHead(int channels, int rate) {
    final b = Uint8List(19);
    b.setRange(0, 8, 'OpusHead'.codeUnits);
    b[8] = 1;
    b[9] = channels;
    final bd = ByteData.sublistView(b);
    bd.setUint32(12, rate, Endian.little);
    return b;
  }
}

void _u32(BytesBuilder b, int v) {
  b.addByte((v >> 24) & 0xff);
  b.addByte((v >> 16) & 0xff);
  b.addByte((v >> 8) & 0xff);
  b.addByte(v & 0xff);
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
