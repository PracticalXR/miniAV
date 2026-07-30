import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

class Decoder {
  final PlatformDecoder _platform;
  final String backendName;

  /// The capability the negotiator chose to open this decoder, or `null` when
  /// it was created via a path that didn't negotiate. Consumers read
  /// [CodecCapability.producedOutputs] / [CodecCapability.zeroCopy] to pick
  /// their frame path deterministically — e.g. the player takes the D3D11
  /// texture branch when `capability.producedOutputs` contains
  /// `FrameSourceKind.d3d11Texture`, instead of probing the first frame.
  final CodecCapability? capability;

  bool _closed = false;

  Decoder(this._platform, this.backendName, {this.capability});

  bool get isClosed => _closed;

  /// Whether the chosen path keeps frames GPU-resident end-to-end (no CPU
  /// readback). Convenience over `capability?.zeroCopy`.
  bool get isZeroCopy => capability?.zeroCopy ?? false;

  Future<DecodedFrame?> decode(EncodedPacket packet) {
    _checkOpen();
    return _platform.decode(packet);
  }

  Future<List<DecodedFrame>> flush() {
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
      throw StateError('Decoder[$backendName] has been closed.');
    }
  }
}
