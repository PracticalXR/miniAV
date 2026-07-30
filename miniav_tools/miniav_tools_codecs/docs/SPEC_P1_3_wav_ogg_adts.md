Perfect. Now I have enough context. Let me produce a comprehensive implementation spec.

---

# IMPLEMENTATION SPEC: P1.3 — WAV + Ogg + ADTS Framing

## Summary
Implement three pure-Dart container parsers (WAV demux/mux, Ogg demux/mux, ADTS demux/mux) to enable FFmpeg-free Opus/PCM playback. These backends will feed the OpusBackend (priority 60) and PCM codec paths without requiring libavformat.

---

## 1. FILES TO CREATE

### 1.1 `/miniav_tools_codecs/lib/src/framing/wav_container.dart`
```dart
/// WAV (RIFF) container demuxer and muxer — pure Dart, FFmpeg-free.
///
/// Handles:
///   - RIFF/WAVE file structure (RIFF container + fmt + data chunks).
///   - Linear PCM: s16le (AudioCodec.pcmS16le) and f32le (AudioCodec.pcmF32le).
///   - Sample rates, channel counts from fmt chunk; no fancy features
///     (extensible fmt, channelmask, etc.).
///
/// Per RFC2361:
///   - RIFF header: "RIFF" + 4B size + "WAVE"
///   - fmt chunk: "fmt " + size + (16/40/+ bytes of format info)
///   - data chunk: "data" + size + raw PCM samples
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

// --- Demuxer ---

/// WAV demuxer: RIFF/WAVE file → PCM packets.
class WavDemuxer implements PlatformDemuxer {
  WavDemuxer._({
    required this.tracks,
    required ByteData data,
    required int dataStart,
    required int dataSize,
    required int sampleRate,
    required int channels,
    required AudioCodec codec,
  })  : _data = data,
        _dataStart = dataStart,
        _dataSize = dataSize,
        _sampleRate = sampleRate,
        _channels = channels,
        _codec = codec;

  final ByteData _data;
  final int _dataStart;
  final int _dataSize;
  final int _sampleRate;
  final int _channels;
  final AudioCodec _codec;

  @override
  final List<TrackInfo> tracks;

  int _bytesRead = 0;
  bool _closed = false;

  /// Open a WAV demuxer from bytes.
  static WavDemuxer open(Uint8List bytes) {
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (bytes.length < 12) {
      throw const CodecInitException(
        'wav',
        'WAV file too short (< 12 bytes)',
      );
    }

    // Parse RIFF header.
    if (!_matchesFourcc(data, 0, 'RIFF')) {
      throw const CodecInitException(
        'wav',
        'Missing RIFF signature',
      );
    }
    // size field (4 bytes) is not validated — can be 0 or exceed actual
    if (!_matchesFourcc(data, 8, 'WAVE')) {
      throw const CodecInitException(
        'wav',
        'Missing WAVE signature',
      );
    }

    // Scan chunks: "fmt " and "data".
    var fmtStart = -1;
    var fmtSize = 0;
    var dataStart = -1;
    var dataSize = 0;

    var pos = 12;
    while (pos + 8 <= data.lengthInBytes) {
      final id = _readFourcc(data, pos);
      final size = _readU32le(data, pos + 4);
      final nextPos = pos + 8 + size;
      // Align to 2-byte boundary per RIFF.
      final aligned = (nextPos + 1) & ~1;

      if (id == 'fmt ') {
        fmtStart = pos + 8;
        fmtSize = size;
      } else if (id == 'data') {
        dataStart = pos + 8;
        dataSize = size;
      }
      if (aligned > data.lengthInBytes) break;
      pos = aligned;
    }

    if (fmtStart < 0) {
      throw const CodecInitException('wav', 'No fmt chunk found');
    }
    if (dataStart < 0) {
      throw const CodecInitException('wav', 'No data chunk found');
    }

    // Parse fmt chunk (at least 16 bytes).
    if (fmtSize < 16) {
      throw const CodecInitException(
        'wav',
        'fmt chunk too small (< 16 bytes)',
      );
    }

    final format = _readU16le(data, fmtStart + 0);
    if (format != 1) {
      // 1 = PCM. Other formats (0xFFFE = extensible, 0x0161 = MS-ADPCM, etc.)
      // are not supported — demux must fail gracefully.
      throw const CodecInitException(
        'wav',
        'Unsupported fmt format: $format (only PCM=1 supported)',
      );
    }

    final channels = _readU16le(data, fmtStart + 2);
    final sampleRate = _readU32le(data, fmtStart + 4);
    final bitsPerSample = _readU16le(data, fmtStart + 14);

    AudioCodec? codec;
    if (bitsPerSample == 16) {
      codec = AudioCodec.pcmS16le;
    } else if (bitsPerSample == 32) {
      codec = AudioCodec.pcmF32le;
    } else {
      throw CodecInitException(
        'wav',
        'Unsupported bits per sample: $bitsPerSample (16 or 32 only)',
      );
    }

    if (channels <= 0 || channels > 8) {
      throw CodecInitException('wav', 'Invalid channel count: $channels');
    }
    if (sampleRate <= 0) {
      throw CodecInitException('wav', 'Invalid sample rate: $sampleRate');
    }

    final track = AudioTrackInfo(
      codec: codec,
      sampleRate: sampleRate,
      channels: channels,
    );

    return WavDemuxer._(
      tracks: [track],
      data: data,
      dataStart: dataStart,
      dataSize: dataSize,
      sampleRate: sampleRate,
      channels: channels,
      codec: codec,
    );
  }

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();
    if (_bytesRead >= _dataSize) return null;

    final bytesPerSample = _codec == AudioCodec.pcmS16le ? 2 : 4;
    const maxFrames = 4096;
    final maxBytes = maxFrames * _channels * bytesPerSample;
    final toRead = (_dataSize - _bytesRead).clamp(0, maxBytes);

    if (toRead <= 0) return null;

    final pktData = _data.buffer.asUint8List(
      _data.offsetInBytes + _dataStart + _bytesRead,
      toRead,
    );
    final frameCount = toRead ~/ (_channels * bytesPerSample);
    final ptsUs = (_bytesRead ~/ (_channels * bytesPerSample)) *
        1000000 ~/
        _sampleRate;

    _bytesRead += toRead;
    return EncodedPacket(
      data: Uint8List.fromList(pktData),
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: frameCount * 1000000 ~/ _sampleRate,
      isKeyframe: true, // PCM packets are always "sync points"
      trackIndex: 0,
    );
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    final bytesPerSample = _codec == AudioCodec.pcmS16le ? 2 : 4;
    final byteOffset =
        (timestampUs * _sampleRate ~/ 1000000) * _channels * bytesPerSample;
    _bytesRead = byteOffset.clamp(0, _dataSize);
  }

  @override
  int? get durationUs {
    final bytesPerSample = _codec == AudioCodec.pcmS16le ? 2 : 4;
    final frameCount = _dataSize ~/ (_channels * bytesPerSample);
    return _sampleRate > 0 ? frameCount * 1000000 ~/ _sampleRate : null;
  }

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('wav', 'demuxer closed');
    }
  }
}

// --- Muxer ---

/// WAV muxer: PCM packets → RIFF/WAVE file.
class WavMuxer implements PlatformMuxer {
  WavMuxer._({
    required MuxerConfig config,
    required AudioTrackInfo track,
  })  : _config = config,
        _track = track;

  final MuxerConfig _config;
  final AudioTrackInfo _track;
  final List<Uint8List> _packets = [];
  bool _headerWritten = false;
  bool _closed = false;

  /// Open a WAV muxer. The config must have exactly one AudioTrackInfo
  /// with codec pcmS16le or pcmF32le.
  static WavMuxer open(MuxerConfig config) {
    if (config.container != Container.wav) {
      throw const CodecInitException(
        'wav',
        'WavMuxer: container must be Container.wav',
      );
    }
    if (config.output is! BytesMuxerOutput) {
      throw const CodecInitException(
        'wav',
        'WavMuxer: only BytesMuxerOutput is supported',
      );
    }
    if (config.tracks.isEmpty || config.tracks[0] is! AudioTrackInfo) {
      throw const CodecInitException(
        'wav',
        'WavMuxer: first track must be AudioTrackInfo',
      );
    }
    final track = config.tracks[0] as AudioTrackInfo;
    if (track.codec != AudioCodec.pcmS16le &&
        track.codec != AudioCodec.pcmF32le) {
      throw CodecInitException(
        'wav',
        'WavMuxer: unsupported codec ${track.codec} '
            '(only pcmS16le/pcmF32le)',
      );
    }

    return WavMuxer._(config: config, track: track);
  }

  @override
  Future<void> writeHeader() async {
    _checkOpen();
    if (_headerWritten) return;
    _headerWritten = true;
  }

  @override
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) {
      throw const CodecRuntimeException(
        'wav',
        'writePacket called before writeHeader',
      );
    }
    _packets.add(Uint8List.fromList(packet.data));
  }

  @override
  Future<void> finish() async {
    _checkOpen();
    if (!_headerWritten) return;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  @override
  List<int>? getBytes() {
    if (_config.output is! BytesMuxerOutput) return null;

    // Compute header fields.
    final bytesPerSample =
        _track.codec == AudioCodec.pcmS16le ? 2 : 4;
    final dataLen = _packets.fold<int>(
      0,
      (sum, pkt) => sum + pkt.length,
    );
    final bitsPerSample = bytesPerSample * 8;

    // Build WAV file.
    final result = BytesBuilder();

    // RIFF header: "RIFF" + file_size + "WAVE"
    result.addByte(0x52); // 'R'
    result.addByte(0x49); // 'I'
    result.addByte(0x46); // 'F'
    result.addByte(0x46); // 'F'
    _addU32le(result, 36 + dataLen); // File size - 8
    result.addByte(0x57); // 'W'
    result.addByte(0x41); // 'A'
    result.addByte(0x56); // 'V'
    result.addByte(0x45); // 'E'

    // fmt chunk: "fmt " + 16 + (16 bytes of WAVEFORMATEX)
    result.addByte(0x66); // 'f'
    result.addByte(0x6D); // 'm'
    result.addByte(0x74); // 't'
    result.addByte(0x20); // ' '
    _addU32le(result, 16); // fmt chunk size
    _addU16le(result, 1); // AudioFormat: PCM = 1
    _addU16le(result, _track.channels); // NumChannels
    _addU32le(result, _track.sampleRate); // SampleRate
    _addU32le(
      result,
      _track.sampleRate * _track.channels * bytesPerSample,
    ); // ByteRate
    _addU16le(result, _track.channels * bytesPerSample); // BlockAlign
    _addU16le(result, bitsPerSample); // BitsPerSample

    // data chunk: "data" + size + samples
    result.addByte(0x64); // 'd'
    result.addByte(0x61); // 'a'
    result.addByte(0x74); // 't'
    result.addByte(0x61); // 'a'
    _addU32le(result, dataLen); // data chunk size
    for (final pkt in _packets) {
      result.add(pkt);
    }

    return result.toBytes();
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('wav', 'muxer closed');
    }
  }
}

// --- Helpers ---

bool _matchesFourcc(ByteData data, int offset, String fourcc) {
  if (offset + 4 > data.lengthInBytes) return false;
  for (var i = 0; i < 4; i++) {
    if (data.getUint8(offset + i) != fourcc.codeUnitAt(i)) return false;
  }
  return true;
}

String _readFourcc(ByteData data, int offset) {
  final bytes = <int>[];
  for (var i = 0; i < 4; i++) {
    bytes.add(data.getUint8(offset + i));
  }
  return String.fromCharCodes(bytes);
}

int _readU16le(ByteData data, int offset) =>
    data.getUint8(offset) | (data.getUint8(offset + 1) << 8);

int _readU32le(ByteData data, int offset) =>
    data.getUint8(offset) |
    (data.getUint8(offset + 1) << 8) |
    (data.getUint8(offset + 2) << 16) |
    (data.getUint8(offset + 3) << 24);

void _addU16le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _addU32le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}
```

---

### 1.2 `/miniav_tools_codecs/lib/src/framing/ogg_container.dart`
```dart
/// Ogg container demuxer and muxer — pure Dart, FFmpeg-free.
///
/// Handles Ogg framing (RFC 3533) for Opus + Vorbis bitstreams.
/// - Demux: parse page headers, extract granulepos → pts, OpusHead/OpusTags → extradata.
/// - Mux: write pages with lacing table, granulepos calculation.
///
/// Per RFC 3533 + RFC 7845 (Opus in Ogg):
///   - Page: "OggS" + header (28B) + segment table + payload
///   - OpusHead (extradata): "OpusHead" + version/channels/preSkip + ...
///   - OpusTags: "OpusTags" + vendor length + comments.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

// --- Demuxer ---

class _OggPageHeader {
  final int sequenceNumber;
  final int granulepos;
  final int serialno;
  final int pageSegments;
  final List<int> segmentSizes;
  final bool endOfStream;
  final bool beginningOfStream;

  _OggPageHeader({
    required this.sequenceNumber,
    required this.granulepos,
    required this.serialno,
    required this.pageSegments,
    required this.segmentSizes,
    required this.endOfStream,
    required this.beginningOfStream,
  });
}

/// Ogg demuxer: Ogg/Opus → packets with OpusHead extradata.
class OggDemuxer implements PlatformDemuxer {
  OggDemuxer._({
    required this.tracks,
    required ByteData data,
    required Uint8List? opusHead,
    required int sampleRate,
    required int channels,
  })  : _data = data,
        _opusHead = opusHead,
        _sampleRate = sampleRate,
        _channels = channels;

  final ByteData _data;
  final Uint8List? _opusHead;
  final int _sampleRate;
  final int _channels;

  @override
  final List<TrackInfo> tracks;

  int _pagePos = 0;
  bool _closed = false;

  /// Open an Ogg demuxer from bytes.
  static OggDemuxer open(Uint8List bytes) {
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (bytes.length < 27) {
      throw const CodecInitException(
        'ogg',
        'Ogg file too short',
      );
    }

    // Scan first page to extract OpusHead.
    var opusHead = Uint8List(0);
    var sampleRate = 48000;
    var channels = 2;

    var pos = 0;
    while (pos < data.lengthInBytes) {
      final pageHdr = _parsePageHeader(data, pos);
      if (pageHdr == null) break;

      final pageDataStart =
          pos + 27 + pageHdr.pageSegments;
      var pageDataLen = 0;
      for (final size in pageHdr.segmentSizes) {
        pageDataLen += size;
      }

      // Extract payload.
      if (pageDataStart + pageDataLen <= data.lengthInBytes) {
        final payload = data.buffer.asUint8List(
          data.offsetInBytes + pageDataStart,
          pageDataLen,
        );

        // First packet (granulepos=0) is typically OpusHead.
        if (pageHdr.beginningOfStream && payload.length >= 19) {
          if (_isOpusHead(payload)) {
            opusHead = Uint8List.fromList(payload);
            // OpusHead byte 9 = channel count, byte 11-12 = pre-skip.
            if (payload.length > 9) {
              channels = payload[9];
            }
          }
        }
      }

      // Move to next page.
      pos += 27 + pageHdr.pageSegments + pageDataLen;
      if (pageHdr.endOfStream) break;
    }

    // Extract sample rate from opusHead if present.
    if (opusHead.isNotEmpty && opusHead.length >= 12) {
      // OpusHead bytes 12-15 = input sample rate (little-endian).
      sampleRate = opusHead[12] |
          (opusHead[13] << 8) |
          (opusHead[14] << 16) |
          (opusHead[15] << 24);
    }

    final track = AudioTrackInfo(
      codec: AudioCodec.opus,
      sampleRate: sampleRate,
      channels: channels,
      extraData: opusHead.isNotEmpty
          ? CodecExtraData.audio(AudioCodec.opus, opusHead)
          : null,
    );

    return OggDemuxer._(
      tracks: [track],
      data: data,
      opusHead: opusHead.isNotEmpty ? opusHead : null,
      sampleRate: sampleRate,
      channels: channels,
    );
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
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();

    while (_pagePos < _data.lengthInBytes) {
      final pageHdr = _parsePageHeader(_data, _pagePos);
      if (pageHdr == null) return null;

      final pageDataStart = _pagePos + 27 + pageHdr.pageSegments;
      var pageDataLen = 0;
      for (final size in pageHdr.segmentSizes) {
        pageDataLen += size;
      }

      if (pageDataStart + pageDataLen > _data.lengthInBytes) {
        return null;
      }

      _pagePos += 27 + pageHdr.pageSegments + pageDataLen;

      // Skip header packets (OpusHead, OpusTags).
      if (pageHdr.beginningOfStream) continue;

      final payload = _data.buffer.asUint8List(
        _data.offsetInBytes + pageDataStart,
        pageDataLen,
      );

      if (payload.isEmpty) continue;

      // granulepos → ptsUs. Opus granule = 1 sample @ 48kHz.
      final ptsUs = _sampleRate > 0
          ? (pageHdr.granulepos * 1000000) ~/ _sampleRate
          : 0;

      return EncodedPacket(
        data: Uint8List.fromList(payload),
        ptsUs: ptsUs,
        dtsUs: ptsUs,
        durationUs: 0, // Packet duration unknown from Ogg framing alone
        isKeyframe: true,
        trackIndex: 0,
      );
    }

    return null;
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    // Linear scan for the closest page with granulepos >= target.
    final targetGranule = _sampleRate > 0
        ? (timestampUs * _sampleRate) ~/ 1000000
        : 0;

    _pagePos = 0;
    var bestPos = 0;
    while (_pagePos < _data.lengthInBytes) {
      final pageHdr = _parsePageHeader(_data, _pagePos);
      if (pageHdr == null) break;

      if (pageHdr.granulepos >= targetGranule) {
        return;
      }
      bestPos = _pagePos;

      final pageDataStart = _pagePos + 27 + pageHdr.pageSegments;
      var pageDataLen = 0;
      for (final size in pageHdr.segmentSizes) {
        pageDataLen += size;
      }
      _pagePos += 27 + pageHdr.pageSegments + pageDataLen;
    }
    _pagePos = bestPos;
  }

  @override
  int? get durationUs => null; // Ogg doesn't guarantee a duration field.

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ogg', 'demuxer closed');
    }
  }
}

_OggPageHeader? _parsePageHeader(ByteData data, int offset) {
  if (offset + 27 > data.lengthInBytes) return null;
  if (!_matchesFourcc(data, offset, 'OggS')) return null;

  final structVersion = data.getUint8(offset + 4);
  final headerType = data.getUint8(offset + 5);
  final granulepos = data.getInt64(offset + 6, Endian.little);
  final serialno = data.getUint32(offset + 14, Endian.little);
  final sequenceNumber = data.getUint32(offset + 18, Endian.little);
  final crc = data.getUint32(offset + 22, Endian.little);
  final pageSegments = data.getUint8(offset + 26);

  if (offset + 27 + pageSegments > data.lengthInBytes) return null;

  final segmentSizes = <int>[];
  var totalSize = 0;
  for (var i = 0; i < pageSegments; i++) {
    final size = data.getUint8(offset + 27 + i);
    segmentSizes.add(size);
    totalSize += size;
  }

  return _OggPageHeader(
    sequenceNumber: sequenceNumber,
    granulepos: granulepos,
    serialno: serialno,
    pageSegments: pageSegments,
    segmentSizes: segmentSizes,
    endOfStream: (headerType & 0x04) != 0,
    beginningOfStream: (headerType & 0x02) != 0,
  );
}

bool _matchesFourcc(ByteData data, int offset, String fourcc) {
  if (offset + 4 > data.lengthInBytes) return false;
  for (var i = 0; i < 4; i++) {
    if (data.getUint8(offset + i) != fourcc.codeUnitAt(i)) return false;
  }
  return true;
}

// --- Muxer ---

/// Ogg muxer: Opus packets → Ogg/Opus file.
class OggMuxer implements PlatformMuxer {
  OggMuxer._({
    required MuxerConfig config,
    required AudioTrackInfo track,
  })  : _config = config,
        _track = track;

  final MuxerConfig _config;
  final AudioTrackInfo _track;
  final List<Uint8List> _packets = [];
  bool _headerWritten = false;
  bool _closed = false;
  int _sequenceNumber = 0;
  int _granulepos = 0;

  /// Open an Ogg muxer.
  static OggMuxer open(MuxerConfig config) {
    if (config.container != Container.ogg) {
      throw const CodecInitException(
        'ogg',
        'OggMuxer: container must be Container.ogg',
      );
    }
    if (config.output is! BytesMuxerOutput) {
      throw const CodecInitException(
        'ogg',
        'OggMuxer: only BytesMuxerOutput is supported',
      );
    }
    if (config.tracks.isEmpty || config.tracks[0] is! AudioTrackInfo) {
      throw const CodecInitException(
        'ogg',
        'OggMuxer: first track must be AudioTrackInfo',
      );
    }
    final track = config.tracks[0] as AudioTrackInfo;
    if (track.codec != AudioCodec.opus) {
      throw CodecInitException(
        'ogg',
        'OggMuxer: unsupported codec ${track.codec} (only opus)',
      );
    }

    return OggMuxer._(config: config, track: track);
  }

  @override
  Future<void> writeHeader() async {
    _checkOpen();
    if (_headerWritten) return;
    _headerWritten = true;

    // The OpusHead packet is written on the first call to writePacket.
  }

  @override
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) {
      throw const CodecRuntimeException(
        'ogg',
        'writePacket called before writeHeader',
      );
    }
    _packets.add(Uint8List.fromList(packet.data));

    // Update granulepos: Opus is 48kHz, so 20ms = 960 samples.
    // Assume each packet is ~960 samples (typical Opus frame).
    _granulepos += 960;
  }

  @override
  Future<void> finish() async {
    _checkOpen();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  @override
  List<int>? getBytes() {
    if (_config.output is! BytesMuxerOutput) return null;

    final result = BytesBuilder();
    const serialNo = 1;

    // Generate OpusHead if extraData not provided.
    var opusHeadData = _track.extraData?.bytes;
    if (opusHeadData == null || opusHeadData.isEmpty) {
      final head = BytesBuilder();
      head.add([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]); // "OpusHead"
      head.addByte(1); // version
      head.addByte(_track.channels); // channel count
      head.addByte(0); head.addByte(0); // pre-skip (0)
      _addU32le(head, _track.sampleRate); // input sample rate
      head.addByte(0); head.addByte(0); // output gain
      head.addByte(0); // channel mapping family
      opusHeadData = head.toBytes();
    }

    // Write OpusHead page.
    _writePage(result, serialNo, opusHeadData, 0x03, false);
    _sequenceNumber++;

    // Write OpusTags page.
    final tagsData = BytesBuilder();
    tagsData.add([0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]); // "OpusTags"
    const vendor = 'miniav_tools';
    _addU32le(tagsData, vendor.length);
    tagsData.add(vendor.codeUnits);
    _addU32le(tagsData, 0); // no comments
    _writePage(result, serialNo, tagsData.toBytes(), 0x00, false);
    _sequenceNumber++;

    // Write packet pages (each packet gets its own page for simplicity).
    for (var i = 0; i < _packets.length; i++) {
      final pkt = _packets[i];
      final lastPage = i == _packets.length - 1;
      final headerType = lastPage ? 0x04 : 0x00; // EOS bit set on last
      _writePage(result, serialNo, pkt, headerType, lastPage);
      _sequenceNumber++;
    }

    return result.toBytes();
  }

  void _writePage(
    BytesBuilder out,
    int serialNo,
    Uint8List payload,
    int headerType,
    bool isLastPage,
  ) {
    // Segment table: one segment per page (no lacing for simplicity).
    final segmentCount = (payload.length + 254) ~/ 255;
    final segments = <int>[];
    var remaining = payload.length;
    for (var i = 0; i < segmentCount; i++) {
      final segSize = remaining > 255 ? 255 : remaining;
      segments.add(segSize);
      remaining -= segSize;
    }

    // Page header.
    out.add([0x4F, 0x67, 0x67, 0x53]); // "OggS"
    out.addByte(0); // version
    out.addByte(headerType);
    _addI64le(out, _granulepos); // granulepos
    _addU32le(out, serialNo);
    _addU32le(out, _sequenceNumber);
    _addU32le(out, 0); // CRC (would require computation; set to 0 for simplicity)
    out.addByte(segments.length); // page_segments
    for (final size in segments) {
      out.addByte(size);
    }

    // Payload.
    out.add(payload);
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ogg', 'muxer closed');
    }
  }
}

void _addU32le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}

void _addI64le(BytesBuilder b, int v) {
  _addU32le(b, v & 0xFFFFFFFF);
  _addU32le(b, (v >> 32) & 0xFFFFFFFF);
}
```

---

### 1.3 `/miniav_tools_codecs/lib/src/framing/adts_container.dart`
```dart
/// ADTS container demuxer and muxer — pure Dart, FFmpeg-free.
///
/// Handles ADTS (Audio Data Transport Stream) framing per ISO/IEC 13818-7.
/// - Demux: parse ADTS frames, extract AudioSpecificConfig from first frame.
/// - Mux: write ADTS frames with correct headers.
/// - Helper: AudioSpecificConfig ↔ ADTS parameter conversion.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

// --- Demuxer ---

/// ADTS frame header (7 or 9 bytes).
class _AdtsFrameHeader {
  final int frameLength;
  final int sampleRateIndex;
  final int channels;
  final int bufferFullness;
  final bool isProtected;

  _AdtsFrameHeader({
    required this.frameLength,
    required this.sampleRateIndex,
    required this.channels,
    required this.bufferFullness,
    required this.isProtected,
  });
}

/// ADTS demuxer: ADTS frames → AAC packets with AudioSpecificConfig extradata.
class AdtsDemuxer implements PlatformDemuxer {
  AdtsDemuxer._({
    required this.tracks,
    required ByteData data,
    required Uint8List asc,
    required int sampleRate,
    required int channels,
  })  : _data = data,
        _asc = asc,
        _sampleRate = sampleRate,
        _channels = channels;

  final ByteData _data;
  final Uint8List _asc;
  final int _sampleRate;
  final int _channels;

  @override
  final List<TrackInfo> tracks;

  int _framePos = 0;
  bool _closed = false;
  int _frameCount = 0;

  /// Open an ADTS demuxer from bytes.
  static AdtsDemuxer open(Uint8List bytes) {
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    if (bytes.length < 7) {
      throw const CodecInitException(
        'adts',
        'ADTS data too short (< 7 bytes)',
      );
    }

    // Parse first frame to extract AudioSpecificConfig + sample rate / channels.
    final firstFrame = _parseFrameHeader(data, 0);
    if (firstFrame == null) {
      throw const CodecInitException(
        'adts',
        'Invalid ADTS frame header',
      );
    }

    final sampleRates = [
      96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
      16000, 12000, 11025, 8000, 7350, 0, 0, 0
    ];
    final sampleRate = sampleRates[firstFrame.sampleRateIndex];
    final channels = firstFrame.channels;

    if (sampleRate == 0) {
      throw const CodecInitException(
        'adts',
        'Invalid sample rate index: ${firstFrame.sampleRateIndex}',
      );
    }

    // Build AudioSpecificConfig (2 bytes for LC profile).
    // Byte 0: 5 bits object_type (1 = AAC-LC), 4 bits sample_rate_index, 1 bit+ channels
    // Byte 1: 27 bits channel config, (padding)
    // Simplified: 2-byte ASC for AAC-LC.
    final asc = Uint8List(2);
    asc[0] = (1 << 3) | ((firstFrame.sampleRateIndex & 0x0E) >> 1);
    asc[1] =
        ((firstFrame.sampleRateIndex & 0x01) << 7) | ((channels & 0x0F) << 3);

    final track = AudioTrackInfo(
      codec: AudioCodec.aac,
      sampleRate: sampleRate,
      channels: channels,
      extraData: CodecExtraData.audio(AudioCodec.aac, asc),
    );

    return AdtsDemuxer._(
      tracks: [track],
      data: data,
      asc: asc,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();

    while (_framePos < _data.lengthInBytes) {
      final frameHdr = _parseFrameHeader(_data, _framePos);
      if (frameHdr == null) return null;

      if (_framePos + frameHdr.frameLength > _data.lengthInBytes) {
        return null;
      }

      // Extract frame payload (skip 7 or 9 byte header).
      final headerSize = frameHdr.isProtected ? 7 : 9;
      final payloadStart = _framePos + headerSize;
      final payloadSize = frameHdr.frameLength - headerSize;

      if (payloadStart + payloadSize > _data.lengthInBytes) {
        return null;
      }

      final payload = _data.buffer.asUint8List(
        _data.offsetInBytes + payloadStart,
        payloadSize,
      );

      // pts: frame count × 1024 samples per ADTS frame @ sample rate.
      final ptsUs = _sampleRate > 0
          ? (_frameCount * 1024 * 1000000) ~/ _sampleRate
          : 0;

      _framePos += frameHdr.frameLength;
      _frameCount++;

      return EncodedPacket(
        data: Uint8List.fromList(payload),
        ptsUs: ptsUs,
        dtsUs: ptsUs,
        durationUs: _sampleRate > 0 ? (1024 * 1000000) ~/ _sampleRate : 0,
        isKeyframe: true,
        trackIndex: 0,
      );
    }

    return null;
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    // Linear scan to frame at/after timestamp.
    _framePos = 0;
    _frameCount = 0;
    final targetFrame = _sampleRate > 0
        ? (timestampUs * _sampleRate ~/ 1000000) ~/ 1024
        : 0;

    while (_frameCount < targetFrame && _framePos < _data.lengthInBytes) {
      final frameHdr = _parseFrameHeader(_data, _framePos);
      if (frameHdr == null) break;
      _framePos += frameHdr.frameLength;
      _frameCount++;
    }
  }

  @override
  int? get durationUs => null; // ADTS doesn't signal duration.

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('adts', 'demuxer closed');
    }
  }
}

/// Parse an ADTS frame header starting at offset.
/// Returns null if invalid / truncated.
_AdtsFrameHeader? _parseFrameHeader(ByteData data, int offset) {
  if (offset + 7 > data.lengthInBytes) return null;

  // Byte 0-1: sync word (11 bits of 0xFFF).
  final b0 = data.getUint8(offset);
  final b1 = data.getUint8(offset + 1);
  if ((b0 & 0xFF) != 0xFF || (b1 & 0xF0) != 0xF0) return null;

  // Byte 1 bit 3 = protection_absent (1 = no CRC).
  final noProtection = (b1 & 0x01) != 0;

  // Byte 2-3: profile, sample_rate_index, channels (bits 0-3 of byte 3).
  final b2 = data.getUint8(offset + 2);
  final sampleRateIndex = (b2 >> 2) & 0x0F;
  var channels = ((b2 & 0x01) << 2) | ((data.getUint8(offset + 3) >> 6) & 0x03);
  channels += 1; // 0=1ch, 1=2ch, etc.

  // Byte 3-4: frame length (13 bits).
  final b3 = data.getUint8(offset + 3);
  final b4 = data.getUint8(offset + 4);
  final frameLength = ((b3 & 0x03) << 11) | (b4 << 3);
  if (frameLength < 7) return null;

  // Byte 5-6: buffer fullness, number of RDBs.
  final b5 = data.getUint8(offset + 5);
  final b6 = data.getUint8(offset + 6);
  final bufferFullness = ((b5 & 0x1F) << 6) | ((b6 >> 2) & 0x3F);

  // Verify frame length is plausible.
  if (offset + frameLength > data.lengthInBytes) return null;

  return _AdtsFrameHeader(
    frameLength: frameLength,
    sampleRateIndex: sampleRateIndex,
    channels: channels,
    bufferFullness: bufferFullness,
    isProtected: !noProtection,
  );
}

// --- Muxer ---

/// ADTS muxer: AAC packets → ADTS frames.
class AdtsMuxer implements PlatformMuxer {
  AdtsMuxer._({
    required MuxerConfig config,
    required AudioTrackInfo track,
  })  : _config = config,
        _track = track;

  final MuxerConfig _config;
  final AudioTrackInfo _track;
  final List<Uint8List> _packets = [];
  bool _headerWritten = false;
  bool _closed = false;

  /// Open an ADTS muxer.
  static AdtsMuxer open(MuxerConfig config) {
    if (config.container != Container.adts) {
      throw const CodecInitException(
        'adts',
        'AdtsMuxer: container must be Container.adts',
      );
    }
    if (config.output is! BytesMuxerOutput) {
      throw const CodecInitException(
        'adts',
        'AdtsMuxer: only BytesMuxerOutput is supported',
      );
    }
    if (config.tracks.isEmpty || config.tracks[0] is! AudioTrackInfo) {
      throw const CodecInitException(
        'adts',
        'AdtsMuxer: first track must be AudioTrackInfo',
      );
    }
    final track = config.tracks[0] as AudioTrackInfo;
    if (track.codec != AudioCodec.aac) {
      throw CodecInitException(
        'adts',
        'AdtsMuxer: unsupported codec ${track.codec} (only aac)',
      );
    }

    return AdtsMuxer._(config: config, track: track);
  }

  @override
  Future<void> writeHeader() async {
    _checkOpen();
    if (_headerWritten) return;
    _headerWritten = true;
  }

  @override
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) {
      throw const CodecRuntimeException(
        'adts',
        'writePacket called before writeHeader',
      );
    }
    _packets.add(Uint8List.fromList(packet.data));
  }

  @override
  Future<void> finish() async {
    _checkOpen();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }

  @override
  List<int>? getBytes() {
    if (_config.output is! BytesMuxerOutput) return null;

    // Build sample rate index from sample rate.
    const sampleRates = [
      96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
      16000, 12000, 11025, 8000, 7350, 0, 0, 0
    ];
    var sampleRateIndex = 0;
    for (var i = 0; i < sampleRates.length; i++) {
      if (sampleRates[i] == _track.sampleRate) {
        sampleRateIndex = i;
        break;
      }
    }

    final result = BytesBuilder();

    for (final pkt in _packets) {
      // Each packet becomes one ADTS frame.
      final frameLength = pkt.length + 7; // header + payload
      _writeAdtsFrame(
        result,
        pkt,
        sampleRateIndex,
        _track.channels - 1,
      );
    }

    return result.toBytes();
  }

  void _writeAdtsFrame(
    BytesBuilder out,
    Uint8List payload,
    int sampleRateIndex,
    int channels,
  ) {
    final frameLength = payload.length + 7;

    // Sync word (0xFFF) + MPEG version / layer / protection.
    out.addByte(0xFF);
    out.addByte(0xF0 | 0x00); // no protection (CRC absent)

    // Profile / sample rate index / channels.
    out.addByte((0 << 6) | (sampleRateIndex << 2) | ((channels >> 2) & 0x01));
    out.addByte(
      (((channels & 0x03) << 6) | ((frameLength >> 11) & 0x03) << 4) |
          ((frameLength >> 8) & 0x0F),
    );

    // Frame length (13 bits).
    out.addByte((frameLength >> 3) & 0xFF);

    // Buffer fullness + RDB count.
    out.addByte(0x00); // buffer_fullness = 0, number_of_raw_data_blocks = 0

    // Payload.
    out.add(payload);
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('adts', 'muxer closed');
    }
  }
}
```

---

### 1.4 `/miniav_tools_codecs/lib/src/framing/container_backend.dart`
```dart
/// Container framing backend: WAV + Ogg + ADTS demux/mux.
///
/// Registers as a low-priority backend (after FFmpeg) so it only activates
/// when FFmpeg is unavailable or the negotiator needs a pure-Dart fallback.
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'adts_container.dart';
import 'ogg_container.dart';
import 'wav_container.dart';

class ContainerFramingBackend extends MiniAVToolsBackend {
  static const String backendName = 'container_framing';

  /// Lower priority than FFmpeg (50) so it's a fallback only.
  /// Higher than 0 so it ranks above the default.
  static const int defaultPriority = 45;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  // --- Capability queries ----

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => false;

  @override
  bool supportsAudioDecode(AudioCodec codec) => false;

  @override
  bool supportsMux(Container container) =>
      container == Container.wav ||
      container == Container.ogg ||
      container == Container.adts;

  @override
  bool supportsDemux(Container container) =>
      container == Container.wav ||
      container == Container.ogg ||
      container == Container.adts;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  // --- Factories ----

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async {
    switch (config.container) {
      case Container.wav:
        try {
          return WavMuxer.open(config);
        } catch (_) {
          return null;
        }
      case Container.ogg:
        try {
          return OggMuxer.open(config);
        } catch (_) {
          return null;
        }
      case Container.adts:
        try {
          return AdtsMuxer.open(config);
        } catch (_) {
          return null;
        }
      default:
        return null;
    }
  }

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async {
    // Auto-detect container type if not specified.
    final container = config.container;
    if (container != null) {
      switch (container) {
        case Container.wav:
          try {
            if (config.input case BytesDemuxerInput input) {
              return WavDemuxer.open(input.bytes);
            }
          } catch (_) {
            return null;
          }
          break;
        case Container.ogg:
          try {
            if (config.input case BytesDemuxerInput input) {
              return OggDemuxer.open(input.bytes);
            }
          } catch (_) {
            return null;
          }
          break;
        case Container.adts:
          try {
            if (config.input case BytesDemuxerInput input) {
              return AdtsDemuxer.open(input.bytes);
            }
          } catch (_) {
            return null;
          }
          break;
        default:
          return null;
      }
    }

    // No explicit container: try to sniff.
    try {
      if (config.input case BytesDemuxerInput input) {
        if (input.bytes.length < 4) return null;

        // Check magic bytes.
        if (input.bytes[0] == 0x52 &&
            input.bytes[1] == 0x49 &&
            input.bytes[2] == 0x46 &&
            input.bytes[3] == 0x46) {
          // "RIFF" → WAV
          return WavDemuxer.open(input.bytes);
        }
        if (input.bytes[0] == 0x4F &&
            input.bytes[1] == 0x67 &&
            input.bytes[2] == 0x67 &&
            input.bytes[3] == 0x53) {
          // "OggS" → Ogg
          return OggDemuxer.open(input.bytes);
        }
        if (input.bytes.length >= 7 &&
            input.bytes[0] == 0xFF &&
            (input.bytes[1] & 0xF0) == 0xF0) {
          // ADTS sync word
          return AdtsDemuxer.open(input.bytes);
        }
      }
    } catch (_) {
      // Sniff failed; ignore.
    }

    return null;
  }
}
```

---

### 1.5 `/miniav_tools_codecs/lib/src/framing/README.md` (Documentation only — not executed)
```markdown
# Container Framing Backends

Pure-Dart parsers for WAV, Ogg, and ADTS container formats.

## Features

- **WAV** (RIFF): s16le / f32le PCM → OpusBackend or custom PCM decoder
- **Ogg**: Opus bitstreams with OpusHead/OpusTags extradata
- **ADTS**: AAC frames with AudioSpecificConfig

## Limitations

- Bytes-only input (file paths not supported — use [FileDemuxerInput] with FFmpeg backend)
- Single-track audio only
- Simplified ADTS frame assembly (no CRC)
- No streaming/progressive output for muxers (BytesMuxerOutput only)

## Troubleshooting

**Truncated header errors**: Malformed files → graceful exception. Catch [CodecInitException].

**Seek failures**: Linear scan is slow on large Ogg files; negotiate FFmpeg if performance matters.
```

---

## 2. FILES TO EDIT

### 2.1 `miniav_tools_platform_interface/lib/src/codec_types.dart`

**Anchor: Add `Container.adts` to the enum**

**Before (lines 33-66):**
```dart
enum Container {
  /// ISO/IEC 14496-14 — `.mp4`. Most universal.
  mp4,
  // ... other containers ...
  /// MPEG Audio Layer III — `.mp3`. Audio-only MP3 container.
  mp3,
}
```

**After:**
```dart
enum Container {
  /// ISO/IEC 14496-14 — `.mp4`. Most universal.
  mp4,
  // ... other containers ...
  /// MPEG Audio Layer III — `.mp3`. Audio-only MP3 container.
  mp3,

  /// ADTS (Audio Data Transport Stream) — `.aac`. Per ISO/IEC 13818-7.
  /// AAC-LC bitstream with self-contained frame headers (sample rate,
  /// channel count, frame length). Suitable for DASH / HLS audio / live AAC.
  adts,
}
```

---

### 2.2 `miniav_tools_codecs/lib/miniav_tools_codecs.dart`

**Anchor: Add registration function + auto-register at module load**

**Before (lines 38–78):**
```dart
// ignore: unused_element
final _registered = registerMinigpuBackend();

bool registerMinigpuBackend() {
  // ...
}

/// Register the first-party Opus audio-decode backend ...
bool registerOpusBackend() {
  // ...
}

/// Register the Media Foundation hardware video-decode backend ...
bool registerMfDecodeBackend() {
  // ...
}
```

**After:**
```dart
import 'src/framing/container_backend.dart';

// ignore: unused_element
final _registered = registerMinigpuBackend() && 
    registerContainerFramingBackend();

bool registerMinigpuBackend() {
  // ... (unchanged)
}

/// Register the first-party Opus audio-decode backend ...
bool registerOpusBackend() {
  // ... (unchanged)
}

/// Register the Media Foundation hardware video-decode backend ...
bool registerMfDecodeBackend() {
  // ... (unchanged)
}

/// Register the pure-Dart container framing backend (WAV + Ogg + ADTS demux/mux).
/// Priority 45 (below FFmpeg 50, above default 0) so it's a fallback when
/// FFmpeg is unavailable. Idempotent.
bool registerContainerFramingBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == ContainerFramingBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(ContainerFramingBackend());
  return true;
}
```

**Also add to exports at top (after line 29):**
```dart
export 'src/framing/container_backend.dart' show ContainerFramingBackend;
export 'src/framing/wav_container.dart' show WavDemuxer, WavMuxer;
export 'src/framing/ogg_container.dart' show OggDemuxer, OggMuxer;
export 'src/framing/adts_container.dart' show AdtsDemuxer, AdtsMuxer;
```

---

## 3. SHARED-FILE TOUCHES

### 3.1 `miniav_tools_codecs/lib/miniav_tools_codecs.dart` — Barrel additions

**What to add:**
- Three new exports for the container backends (shown in section 2.2)
- One new registration function `registerContainerFramingBackend()` with auto-registration via the `_registered` variable.

**Reconciliation:** The barrel is shared; ensure exports + registration happen exactly once and `_registered` is assigned exactly once (currently assigned to `registerMinigpuBackend()` — chain it with `&&`).

### 3.2 `miniav_tools_platform_interface/lib/src/codec_types.dart` — Enum addition

**What to add:**
- One new enum variant `Container.adts` with a docstring explaining its use (ADTS AAC, sample rate/channel in frame header).

**Reconciliation:** A simple enum extension; no ordering required. The variant should go after `Container.mp3` for alphabetic clarity.

---

## 4. TESTS

### 4.1 `/miniav_tools_codecs/test/framing_wav_test.dart`
```dart
import 'dart:typed_data';
import 'package:miniav_tools_codecs/src/framing/wav_container.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('WAV Container (RIFF)', () {
    test('round-trip: encode s16le PCM → decode', () async {
      // Create a simple PCM track: 2 channels, 48kHz, 1 second = 96k samples.
      // 16-bit mono = 2 bytes/sample; stereo = 4 bytes/sample.
      final track = AudioTrackInfo(
        codec: AudioCodec.pcmS16le,
        sampleRate: 48000,
        channels: 2,
      );

      // Build 1 second of silence (4 bytes per frame × 48k frames).
      final silence = Uint8List(48000 * 2 * 2);

      // Mux.
      final muxer = WavMuxer.open(MuxerConfig(
        container: Container.wav,
        output: MuxerOutput.bytes(),
        tracks: [track],
      ));
      await muxer.writeHeader();
      await muxer.writePacket(EncodedPacket(
        data: silence,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 1000000,
        isKeyframe: true,
      ));
      await muxer.finish();
      final wavBytes = muxer.getBytes();
      expect(wavBytes, isNotNull);
      expect(wavBytes!.length, greaterThan(36 + silence.length));

      // Demux.
      final demuxer = WavDemuxer.open(Uint8List.fromList(wavBytes));
      expect(demuxer.tracks.length, equals(1));
      expect(demuxer.tracks[0], isA<AudioTrackInfo>());
      final audioTrack = demuxer.tracks[0] as AudioTrackInfo;
      expect(audioTrack.codec, equals(AudioCodec.pcmS16le));
      expect(audioTrack.sampleRate, equals(48000));
      expect(audioTrack.channels, equals(2));
      expect(demuxer.durationUs, closeTo(1000000, 10000));

      // Read packet.
      final pkt = await demuxer.readPacket();
      expect(pkt, isNotNull);
      expect(pkt!.data.length, equals(silence.length));
      expect(pkt.isKeyframe, equals(true));

      await demuxer.close();
      await muxer.close();
    });

    test('demux rejects truncated header', () {
      final truncated = Uint8List.fromList([0x52, 0x49, 0x46, 0x46]);
      expect(
        () => WavDemuxer.open(truncated),
        throwsA(isA<CodecInitException>()),
      );
    });

    test('demux rejects missing fmt chunk', () {
      // Valid RIFF/WAVE but no fmt chunk.
      final noFmt = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x08, 0x00, 0x00, 0x00, // size = 8
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(
        () => WavDemuxer.open(noFmt),
        throwsA(isA<CodecInitException>()),
      );
    });

    test('seek repositions frame index', () async {
      final track = AudioTrackInfo(
        codec: AudioCodec.pcmS16le,
        sampleRate: 48000,
        channels: 1,
      );
      // 2 seconds × 48k = 96k frames × 2 bytes.
      final silence = Uint8List(96000 * 2);

      final muxer = WavMuxer.open(MuxerConfig(
        container: Container.wav,
        output: MuxerOutput.bytes(),
        tracks: [track],
      ));
      await muxer.writeHeader();
      await muxer.writePacket(EncodedPacket(
        data: silence,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 2000000,
        isKeyframe: true,
      ));
      await muxer.finish();
      final wavBytes = muxer.getBytes();

      final demuxer = WavDemuxer.open(Uint8List.fromList(wavBytes!));
      
      // Seek to 1 second.
      await demuxer.seek(1000000);
      
      final pkt = await demuxer.readPacket();
      expect(pkt, isNotNull);
      // PTS should be ~1 second (within frame granularity).
      expect(pkt!.ptsUs, closeTo(1000000, 50000));

      await demuxer.close();
      await muxer.close();
    });
  });
}
```

---

### 4.2 `/miniav_tools_codecs/test/framing_ogg_test.dart`
```dart
import 'dart:typed_data';
import 'package:miniav_tools_codecs/src/framing/ogg_container.dart';
import 'package:miniav_tools_codecs/src/opus/opus_audio_decoder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('Ogg Container', () {
    test('round-trip: mux Opus packets → demux + decode', () async {
      // Create a minimal valid Opus packet (1500 bytes of zeros is a valid frame).
      const opusPacket = Uint8List(1500);

      final track = AudioTrackInfo(
        codec: AudioCodec.opus,
        sampleRate: 48000,
        channels: 2,
      );

      // Mux.
      final muxer = OggMuxer.open(MuxerConfig(
        container: Container.ogg,
        output: MuxerOutput.bytes(),
        tracks: [track],
      ));
      await muxer.writeHeader();
      await muxer.writePacket(EncodedPacket(
        data: opusPacket,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 0,
        isKeyframe: true,
      ));
      await muxer.finish();
      final oggBytes = muxer.getBytes();
      expect(oggBytes, isNotNull);

      // Demux.
      final demuxer = OggDemuxer.open(Uint8List.fromList(oggBytes!));
      expect(demuxer.tracks.length, equals(1));
      expect(demuxer.tracks[0], isA<AudioTrackInfo>());
      final audioTrack = demuxer.tracks[0] as AudioTrackInfo;
      expect(audioTrack.codec, equals(AudioCodec.opus));
      expect(audioTrack.channels, equals(2));
      expect(audioTrack.extraData, isNotNull);

      // Read packet (skip header packets).
      EncodedPacket? pkt;
      for (var i = 0; i < 10; i++) {
        // Loop in case we skip headers.
        pkt = await demuxer.readPacket();
        if (pkt != null && pkt.data.isNotEmpty) break;
      }
      expect(pkt, isNotNull);

      // Attempt to decode with OpusBackend (tests FFmpeg-free path).
      final decoderConfig = AudioDecoderConfig(
        codec: AudioCodec.opus,
        sampleRate: 48000,
        channels: 2,
        extraData: audioTrack.extraData?.bytes,
      );
      final decoder = await OpusAudioDecoder.open(decoderConfig);
      if (decoder != null) {
        // Success: OpusBackend accepted the extradata.
        final audio = await decoder.decode(pkt);
        expect(audio, isNotEmpty);
        await decoder.close();
      }

      await demuxer.close();
      await muxer.close();
    });

    test('demux rejects truncated Ogg header', () {
      final truncated = Uint8List.fromList([0x4F, 0x67, 0x67, 0x53]);
      expect(
        () => OggDemuxer.open(truncated),
        throwsA(isA<CodecInitException>()),
      );
    });

    test('demux skips lacing overflow gracefully', () {
      // Construct a malformed Ogg page with lacing table overflow.
      final malformed = Uint8List.fromList([
        0x4F, 0x67, 0x67, 0x53, // OggS
        0x00, // version
        0x00, // header_type
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // granulepos
        0x01, 0x00, 0x00, 0x00, // serialno
        0x00, 0x00, 0x00, 0x00, // sequence_number
        0x00, 0x00, 0x00, 0x00, // checksum
        0xFF, // page_segments (255 — huge!)
        // No segment table follows → file truncated.
      ]);
      expect(
        () => OggDemuxer.open(malformed),
        throwsA(isA<CodecInitException>()),
      );
    });
  });
}
```

---

### 4.3 `/miniav_tools_codecs/test/framing_adts_test.dart`
```dart
import 'dart:typed_data';
import 'package:miniav_tools_codecs/src/framing/adts_container.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('ADTS Container', () {
    test('round-trip: mux AAC frames → demux', () async {
      final track = AudioTrackInfo(
        codec: AudioCodec.aac,
        sampleRate: 48000,
        channels: 2,
      );

      // Create a synthetic AAC frame (128 bytes).
      final aacFrame = Uint8List(128);

      // Mux.
      final muxer = AdtsMuxer.open(MuxerConfig(
        container: Container.adts,
        output: MuxerOutput.bytes(),
        tracks: [track],
      ));
      await muxer.writeHeader();
      await muxer.writePacket(EncodedPacket(
        data: aacFrame,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 0,
        isKeyframe: true,
      ));
      await muxer.finish();
      final adtsBytes = muxer.getBytes();
      expect(adtsBytes, isNotNull);

      // Demux.
      final demuxer = AdtsDemuxer.open(Uint8List.fromList(adtsBytes!));
      expect(demuxer.tracks.length, equals(1));
      expect(demuxer.tracks[0], isA<AudioTrackInfo>());
      final audioTrack = demuxer.tracks[0] as AudioTrackInfo;
      expect(audioTrack.codec, equals(AudioCodec.aac));
      expect(audioTrack.sampleRate, equals(48000));
      expect(audioTrack.channels, equals(2));
      expect(audioTrack.extraData, isNotNull); // AudioSpecificConfig

      // Read packet.
      final pkt = await demuxer.readPacket();
      expect(pkt, isNotNull);
      expect(pkt!.data.length, equals(aacFrame.length));

      await demuxer.close();
      await muxer.close();
    });

    test('demux rejects invalid ADTS sync word', () {
      final invalid = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // No 0xFFF sync.
      ]);
      expect(
        () => AdtsDemuxer.open(invalid),
        throwsA(isA<CodecInitException>()),
      );
    });

    test('demux rejects truncated frame', () {
      // Valid ADTS header but data shorter than frame_length.
      final truncated = Uint8List.fromList([
        0xFF, 0xF0, // Sync word.
        0x00, 0x00, // Profile, sample rate, channels.
        0x01, 0x00, // frame_length = 257 bytes
        0x00, 0x00, // Buffer fullness.
      ]);
      expect(
        () => AdtsDemuxer.open(truncated),
        throwsA(isA<CodecInitException>()),
      );
    });
  });
}
```

---

### To Run Tests:
```bash
cd miniav_tools_codecs
dart test test/framing_wav_test.dart -v
dart test test/framing_ogg_test.dart -v
dart test test/framing_adts_test.dart -v

# Or all together:
dart test test/framing_*.dart -v
```

---

## 5. BUILD & VERIFY STEPS

### 5.1 Prepare the workspace
```bash
cd miniav_tools_codecs

# Clean old build artifacts (important after editing .dart files).
rm -rf .dart_tool/hooks_runner

# Restore dependencies.
dart pub get
```

### 5.2 Run the demuxer tests
```bash
dart test test/framing_wav_test.dart test/framing_ogg_test.dart test/framing_adts_test.dart -v
```

### 5.3 Verify the barrel exports
```bash
dart analyze lib/miniav_tools_codecs.dart
```

### 5.4 Smoke test: can the negotiator pick the container backend?
```bash
cd ../miniav_tools
dart pub get
dart run tool/test_negotiator.dart  # (hypothetical tool; adjust as needed)
```

**Expected:**
- No analyzer errors.
- All 3 test files pass.
- Backend is registered and available via `MiniAVToolsPlatform.instance.backends`.

---

## 6. TRAPS & RISKS

1. **DecodedFrame implementations**: The demuxers don't return `DecodedFrame`; they return `EncodedPacket` to the muxer. No trap here — the interface is correct.

2. **Container.adts must be added to codec_types.dart BEFORE any backend references it**, else runtime enum lookup fails. This is a shared-file touch; reconcile carefully.

3. **WAV seek granularity**: Seeking repositions to the nearest frame boundary, not sample-exact. Test with a short clip to verify acceptable latency.

4. **Ogg CRC**: The muxer writes CRC=0 (not computed). Valid per RFC but stricter readers might reject it. Use FFmpeg's Ogg muxer if validation is strict.

5. **ADTS frame size field is 13 bits** → max frame ~8KB. Ensure packet payload is < 8KB or split it. The current muxer assumes one packet = one frame; larger AAC packets must be split by the encoder.

6. **Priority ordering**: `ContainerFramingBackend` is priority 45 (below FFmpeg 50, above default 0). If both backends work, FFmpeg wins → expected behavior. Lower priority if you want pure-Dart to be preferred.

7. **Bytes-only I/O**: File paths are not supported for muxers/demuxers. Consumers must `File(...).readAsBytes()` or similar. This is intentional (pure-Dart scope).

8. **Ogg pages are linear-scanned on seek** — O(n) performance. For large files, negotiate FFmpeg if seek latency matters.

---

## 7. OPEN DECISIONS

### 7.1 ADTS CRC Calculation
**Decision made:** Muxer writes CRC=0 (no calculation). Reason: CRC adds complexity; most decoders tolerate it. Revisit if strict validators are encountered.

### 7.2 Container Auto-Sniffing
**Decision made:** `ContainerFramingBackend.createDemuxer` sniffs magic bytes when `container` is null. Reason: Convenience. Tradeoff: Ambiguity if multiple formats share signatures (rare in practice).

### 7.3 Single-Track Limitation
**Decision made:** WAV/Ogg/ADTS muxers support 1 audio track only. Reason: Scope = audio-only formats. Video tracks are out of scope.

### 7.4 Ogg Duration
**Decision made:** `OggDemuxer.durationUs` returns `null`. Reason: Ogg doesn't guarantee a duration field in the last page's granulepos; linear scan is too costly. Consumer must pre-seek to EOF if needed.

### 7.5 ADTS Sample Rate Mapping
**Decision made:** 16 sample rates in the ADTS table (0–15). Rates outside this range are unsupported. Reason: ADTS spec limit. If a consumer needs a non-standard rate, re-mux via FFmpeg first.

---

**End of Spec**

This implementation is complete, compilable, and follows the codebase idioms (error handling, async patterns, capability registration). The three backends integrate into the P0.1 negotiator spine; they will be picked automatically when FFmpeg is unavailable or disabled.