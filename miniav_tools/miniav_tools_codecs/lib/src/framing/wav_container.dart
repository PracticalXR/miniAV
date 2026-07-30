/// WAV (RIFF/WAVE) demuxer + muxer — pure Dart, FFmpeg-free.
///
/// Linear PCM only: 16-bit → [AudioCodec.pcmS16le], 32-bit float →
/// [AudioCodec.pcmF32le]. Feeds the pure-Dart PCM decode path. Malformed input
/// throws [CodecInitException] (the negotiator then falls through).
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// WAV demuxer: RIFF/WAVE bytes → PCM packets.
class WavDemuxer implements PlatformDemuxer {
  WavDemuxer._(
    this.tracks,
    this._data,
    this._dataStart,
    this._dataSize,
    this._sampleRate,
    this._channels,
    this._codec,
  );

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

  int get _bytesPerFrame =>
      (_codec == AudioCodec.pcmS16le ? 2 : 4) * _channels;

  /// Open a WAV demuxer, or throw [CodecInitException] on malformed input.
  static WavDemuxer open(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (data.lengthInBytes < 12 ||
        !_fourcc(data, 0, 'RIFF') ||
        !_fourcc(data, 8, 'WAVE')) {
      throw const CodecInitException('wav', 'not a RIFF/WAVE file');
    }

    var fmtStart = -1, fmtSize = 0, dataStart = -1, dataSize = 0;
    var pos = 12;
    while (pos + 8 <= data.lengthInBytes) {
      final id = _readFourcc(data, pos);
      final size = data.getUint32(pos + 4, Endian.little);
      if (id == 'fmt ') {
        fmtStart = pos + 8;
        fmtSize = size;
      } else if (id == 'data') {
        dataStart = pos + 8;
        // Clamp to the actual buffer (some writers leave size=0 or too large).
        dataSize = size;
        if (dataStart + dataSize > data.lengthInBytes) {
          dataSize = data.lengthInBytes - dataStart;
        }
      }
      final next = (pos + 8 + size + 1) & ~1; // 2-byte aligned
      if (next <= pos) break; // guard against overflow / zero-size loop
      pos = next;
    }

    if (fmtStart < 0 || fmtSize < 16) {
      throw const CodecInitException('wav', 'missing/short fmt chunk');
    }
    if (dataStart < 0) {
      throw const CodecInitException('wav', 'missing data chunk');
    }

    final format = data.getUint16(fmtStart, Endian.little);
    if (format != 1 && format != 3) {
      // 1 = PCM integer, 3 = IEEE float. Anything else is unsupported.
      throw CodecInitException('wav', 'unsupported WAVE format tag $format');
    }
    final channels = data.getUint16(fmtStart + 2, Endian.little);
    final sampleRate = data.getUint32(fmtStart + 4, Endian.little);
    final bits = data.getUint16(fmtStart + 14, Endian.little);

    final AudioCodec codec;
    if (format == 1 && bits == 16) {
      codec = AudioCodec.pcmS16le;
    } else if (format == 3 && bits == 32) {
      codec = AudioCodec.pcmF32le;
    } else {
      throw CodecInitException('wav', 'unsupported PCM: fmt=$format bits=$bits');
    }
    if (channels < 1 || channels > 8 || sampleRate < 1) {
      throw CodecInitException('wav', 'bad ch=$channels sr=$sampleRate');
    }

    return WavDemuxer._(
      [AudioTrackInfo(codec: codec, sampleRate: sampleRate, channels: channels)],
      data,
      dataStart,
      dataSize,
      sampleRate,
      channels,
      codec,
    );
  }

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();
    if (_bytesRead >= _dataSize) return null;
    const maxFrames = 4096;
    final maxBytes = maxFrames * _bytesPerFrame;
    var toRead = _dataSize - _bytesRead;
    if (toRead > maxBytes) toRead = maxBytes;
    // Whole frames only.
    toRead -= toRead % _bytesPerFrame;
    if (toRead <= 0) return null;

    final out = Uint8List(toRead);
    out.setRange(
      0,
      toRead,
      _data.buffer.asUint8List(_data.offsetInBytes + _dataStart + _bytesRead),
    );
    final frames = toRead ~/ _bytesPerFrame;
    final ptsUs = (_bytesRead ~/ _bytesPerFrame) * 1000000 ~/ _sampleRate;
    _bytesRead += toRead;
    return EncodedPacket(
      data: out,
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: frames * 1000000 ~/ _sampleRate,
      isKeyframe: true,
    );
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    final frame = timestampUs * _sampleRate ~/ 1000000;
    final byteOffset = (frame * _bytesPerFrame).clamp(0, _dataSize);
    _bytesRead = byteOffset - (byteOffset % _bytesPerFrame);
  }

  @override
  int? get durationUs => _sampleRate > 0
      ? (_dataSize ~/ _bytesPerFrame) * 1000000 ~/ _sampleRate
      : null;

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async => _closed = true;

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('wav', 'demuxer closed');
  }
}

/// WAV muxer: PCM packets → RIFF/WAVE bytes (via [PlatformMuxer.getBytes]).
class WavMuxer implements PlatformMuxer {
  WavMuxer._(this._track);

  final AudioTrackInfo _track;
  final BytesBuilder _pcm = BytesBuilder();
  bool _headerWritten = false;
  bool _closed = false;

  static WavMuxer open(MuxerConfig config) {
    if (config.tracks.isEmpty || config.tracks.first is! AudioTrackInfo) {
      throw const CodecInitException('wav', 'need one AudioTrackInfo');
    }
    final track = config.tracks.first as AudioTrackInfo;
    if (track.codec != AudioCodec.pcmS16le &&
        track.codec != AudioCodec.pcmF32le) {
      throw CodecInitException('wav', 'unsupported codec ${track.codec}');
    }
    return WavMuxer._(track);
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
      throw const CodecRuntimeException('wav', 'writePacket before writeHeader');
    }
    _pcm.add(packet.data);
  }

  @override
  Future<void> finish() async => _checkOpen();

  @override
  Future<void> close() async => _closed = true;

  @override
  List<int>? getBytes() {
    final pcm = _pcm.toBytes();
    final bytesPerSample = _track.codec == AudioCodec.pcmS16le ? 2 : 4;
    final formatTag = _track.codec == AudioCodec.pcmS16le ? 1 : 3;
    final blockAlign = _track.channels * bytesPerSample;

    final out = BytesBuilder();
    out.add('RIFF'.codeUnits);
    _u32(out, 36 + pcm.length);
    out.add('WAVE'.codeUnits);
    out.add('fmt '.codeUnits);
    _u32(out, 16);
    _u16(out, formatTag);
    _u16(out, _track.channels);
    _u32(out, _track.sampleRate);
    _u32(out, _track.sampleRate * blockAlign); // byte rate
    _u16(out, blockAlign);
    _u16(out, bytesPerSample * 8); // bits per sample
    out.add('data'.codeUnits);
    _u32(out, pcm.length);
    out.add(pcm);
    return out.toBytes();
  }

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('wav', 'muxer closed');
  }
}

// --- shared little-endian helpers -------------------------------------------

bool _fourcc(ByteData d, int off, String s) {
  if (off + 4 > d.lengthInBytes) return false;
  for (var i = 0; i < 4; i++) {
    if (d.getUint8(off + i) != s.codeUnitAt(i)) return false;
  }
  return true;
}

String _readFourcc(ByteData d, int off) =>
    String.fromCharCodes([for (var i = 0; i < 4; i++) d.getUint8(off + i)]);

void _u16(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _u32(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}
