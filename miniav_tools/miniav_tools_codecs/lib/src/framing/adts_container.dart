/// ADTS (ISO/IEC 13818-7) demuxer + muxer for AAC — pure Dart, FFmpeg-free.
///
/// ADTS frames are self-describing (7-byte header, or 9 with CRC): profile,
/// sample-rate index, channel config, frame length. The demuxer emits raw AAC
/// packets + a 2-byte AudioSpecificConfig ([CodecExtraData]) so an AAC decoder
/// (a later OS-AAC epic) can init. [adtsToAsc] / [ascToAdtsParams] bridge the
/// two representations. The framing carries no codec logic, so it round-trips
/// any AAC payload today, ahead of a first-party AAC codec.
library;

import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// The 13 ADTS sampling-frequency-index → rate table (indexes 13-15 reserved).
const List<int> adtsSampleRates = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
  16000, 12000, 11025, 8000, 7350, 0, 0, 0, //
];

int _sampleRateIndex(int rate) {
  final i = adtsSampleRates.indexOf(rate);
  return i < 0 ? 4 : i; // default 44100
}

/// Build a 2-byte AAC-LC AudioSpecificConfig from ADTS params.
/// `[objType(5)=2 | srIndex(4) | chanCfg(4) | 0(3)]`.
Uint8List ascToAdtsParams(int sampleRateIndex, int channelConfig) {
  const objectType = 2; // AAC-LC
  final asc = Uint8List(2);
  asc[0] = (objectType << 3) | ((sampleRateIndex >> 1) & 0x07);
  asc[1] = ((sampleRateIndex & 0x01) << 7) | ((channelConfig & 0x0F) << 3);
  return asc;
}

class _AdtsHeader {
  _AdtsHeader(
    this.frameLength,
    this.srIndex,
    this.channels,
    this.headerSize,
  );
  final int frameLength; // total frame incl. header
  final int srIndex;
  final int channels;
  final int headerSize; // 7 (no CRC) or 9 (CRC)
}

/// Parse an ADTS header at [off], or `null` if invalid/truncated.
_AdtsHeader? _parseHeader(ByteData d, int off) {
  if (off + 7 > d.lengthInBytes) return null;
  final b1 = d.getUint8(off + 1);
  // Sync = 12 bits of 1 (0xFFF).
  if (d.getUint8(off) != 0xFF || (b1 & 0xF0) != 0xF0) return null;
  final protectionAbsent = b1 & 0x01; // 1 = no CRC → 7-byte header
  final headerSize = protectionAbsent == 1 ? 7 : 9;

  final b2 = d.getUint8(off + 2);
  final b3 = d.getUint8(off + 3);
  final b4 = d.getUint8(off + 4);
  final b5 = d.getUint8(off + 5);

  final srIndex = (b2 >> 2) & 0x0F;
  // channel_configuration = b2[0] << 2 | b3[7:6] — the channel COUNT directly.
  final channels = ((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03);
  // frame_length is 13 bits: b3[1:0] | b4 | b5[7:5].
  final frameLength =
      ((b3 & 0x03) << 11) | (b4 << 3) | ((b5 >> 5) & 0x07);
  if (frameLength < headerSize) return null;

  return _AdtsHeader(frameLength, srIndex, channels, headerSize);
}

/// ADTS demuxer: raw AAC-in-ADTS bytes → AAC packets.
class AdtsDemuxer implements PlatformDemuxer {
  AdtsDemuxer._(this.tracks, this._data, this._sampleRate);

  @override
  final List<TrackInfo> tracks;

  final ByteData _data;
  final int _sampleRate;
  int _pos = 0;
  int _frame = 0;
  bool _closed = false;

  static AdtsDemuxer open(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final h = _parseHeader(data, 0);
    if (h == null) throw const CodecInitException('adts', 'no ADTS sync');
    final sampleRate = adtsSampleRates[h.srIndex];
    if (sampleRate == 0 || h.channels < 1) {
      throw const CodecInitException('adts', 'bad ADTS sample-rate/channels');
    }
    final asc = ascToAdtsParams(h.srIndex, h.channels);
    return AdtsDemuxer._(
      [
        AudioTrackInfo(
          codec: AudioCodec.aac,
          sampleRate: sampleRate,
          channels: h.channels,
          extraData: CodecExtraData.audio(AudioCodec.aac, asc),
        ),
      ],
      data,
      sampleRate,
    );
  }

  @override
  Future<EncodedPacket?> readPacket() async {
    _checkOpen();
    if (_pos + 7 > _data.lengthInBytes) return null;
    final h = _parseHeader(_data, _pos);
    if (h == null || _pos + h.frameLength > _data.lengthInBytes) return null;

    final payloadOff = _pos + h.headerSize;
    final payloadLen = h.frameLength - h.headerSize;
    final out = Uint8List(payloadLen)
      ..setRange(
        0,
        payloadLen,
        _data.buffer.asUint8List(_data.offsetInBytes + payloadOff),
      );
    // Each AAC frame = 1024 samples.
    final ptsUs = _sampleRate > 0 ? _frame * 1024 * 1000000 ~/ _sampleRate : 0;
    _pos += h.frameLength;
    _frame++;
    return EncodedPacket(
      data: out,
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: _sampleRate > 0 ? 1024 * 1000000 ~/ _sampleRate : 0,
      isKeyframe: true,
    );
  }

  @override
  Future<void> seek(int timestampUs) async {
    _checkOpen();
    _pos = 0;
    _frame = 0;
    final target = _sampleRate > 0
        ? (timestampUs * _sampleRate ~/ 1000000) ~/ 1024
        : 0;
    while (_frame < target && _pos + 7 <= _data.lengthInBytes) {
      final h = _parseHeader(_data, _pos);
      if (h == null) break;
      _pos += h.frameLength;
      _frame++;
    }
  }

  @override
  int? get durationUs => null;

  @override
  bool get isSeekable => true;

  @override
  Future<void> close() async => _closed = true;

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('adts', 'demuxer closed');
  }
}

/// ADTS muxer: raw AAC packets → ADTS bytes (7-byte headers, no CRC, VBR).
class AdtsMuxer implements PlatformMuxer {
  AdtsMuxer._(this._track);

  final AudioTrackInfo _track;
  final BytesBuilder _out = BytesBuilder();
  bool _headerWritten = false;
  bool _closed = false;

  static AdtsMuxer open(MuxerConfig config) {
    if (config.tracks.isEmpty || config.tracks.first is! AudioTrackInfo) {
      throw const CodecInitException('adts', 'need one AudioTrackInfo');
    }
    final track = config.tracks.first as AudioTrackInfo;
    if (track.codec != AudioCodec.aac) {
      throw CodecInitException('adts', 'unsupported codec ${track.codec}');
    }
    return AdtsMuxer._(track);
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
      throw const CodecRuntimeException('adts', 'writePacket before writeHeader');
    }
    final srIndex = _sampleRateIndex(_track.sampleRate);
    final chanCfg = _track.channels & 0x0F;
    final frameLen = packet.data.length + 7;

    // 7-byte ADTS header (MPEG-4, AAC-LC, protection_absent=1, VBR fullness).
    _out.addByte(0xFF);
    _out.addByte(0xF1); // syncword low + MPEG-4 + layer 0 + no CRC
    _out.addByte((1 << 6) | (srIndex << 2) | ((chanCfg >> 2) & 0x01));
    _out.addByte(((chanCfg & 0x03) << 6) | ((frameLen >> 11) & 0x03));
    _out.addByte((frameLen >> 3) & 0xFF);
    _out.addByte(((frameLen & 0x07) << 5) | 0x1F); // + buffer_fullness hi (VBR)
    _out.addByte(0xFC); // buffer_fullness lo (VBR) + 0 raw-data-blocks
    _out.add(packet.data);
  }

  @override
  Future<void> finish() async => _checkOpen();

  @override
  Future<void> close() async => _closed = true;

  @override
  List<int>? getBytes() => _out.toBytes();

  void _checkOpen() {
    if (_closed) throw const CodecRuntimeException('adts', 'muxer closed');
  }
}
