import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// User-facing wrapper around a [PlatformAudioDecoder].
class AudioDecoder {
  final PlatformAudioDecoder _platform;
  final String backendName;

  /// The capability the negotiator chose to open this decoder, or `null` when
  /// created via a non-negotiated path.
  final CodecCapability? capability;

  bool _closed = false;

  AudioDecoder(this._platform, this.backendName, {this.capability});

  bool get isClosed => _closed;

  /// Underlying [PlatformAudioDecoder]. Exposed for backend-specific bridging.
  PlatformAudioDecoder get platform => _platform;

  Future<List<DecodedAudio>> decode(EncodedPacket packet) {
    _checkOpen();
    return _platform.decode(packet);
  }

  Future<List<DecodedAudio>> flush() {
    _checkOpen();
    return _platform.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _platform.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('AudioDecoder[$backendName] has been closed.');
    }
  }
}
