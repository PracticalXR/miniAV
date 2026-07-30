import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// User-facing wrapper around a [PlatformAudioEncoder].
class AudioEncoder {
  final PlatformAudioEncoder _platform;
  final String backendName;

  /// The capability the negotiator chose to open this encoder, or `null` when
  /// created via a non-negotiated path.
  final CodecCapability? capability;

  bool _closed = false;

  AudioEncoder(this._platform, this.backendName, {this.capability});

  bool get isClosed => _closed;

  /// Underlying [PlatformAudioEncoder]. Exposed for backend-specific
  /// bridging (e.g. `FfmpegEncoderBridge`).
  PlatformAudioEncoder get platform => _platform;

  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) {
    _checkOpen();
    return _platform.encode(
      pcm: pcm,
      format: format,
      frameCount: frameCount,
      ptsUs: ptsUs,
    );
  }

  Future<List<EncodedPacket>> flush() {
    _checkOpen();
    return _platform.flush();
  }

  CodecExtraData? get extraData => _platform.extraData;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _platform.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('AudioEncoder[$backendName] has been closed.');
    }
  }
}
