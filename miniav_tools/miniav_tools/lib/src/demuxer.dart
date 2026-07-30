import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

class Demuxer {
  final PlatformDemuxer _platform;
  final String backendName;

  /// The capability the negotiator chose, or `null` for a non-negotiated path.
  final CodecCapability? capability;

  bool _closed = false;

  Demuxer(this._platform, this.backendName, {this.capability});

  bool get isClosed => _closed;

  /// Tracks discovered by probing the input.
  List<TrackInfo> get tracks => _platform.tracks;

  /// Read the next packet, or `null` at EOF.
  Future<EncodedPacket?> readPacket() {
    _checkOpen();
    return _platform.readPacket();
  }

  /// Seek to the given timestamp (microseconds). Throws on non-seekable
  /// inputs — check [isSeekable].
  Future<void> seek(int timestampUs) {
    _checkOpen();
    return _platform.seek(timestampUs);
  }

  /// Container duration in microseconds, or `null` when unknown (live).
  int? get durationUs => _platform.durationUs;

  /// Whether [seek] is supported by this input.
  bool get isSeekable => _platform.isSeekable;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _platform.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('Demuxer[$backendName] has been closed.');
    }
  }
}
