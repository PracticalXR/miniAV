import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

class Muxer {
  final PlatformMuxer _platform;
  final String backendName;

  /// The capability the negotiator chose, or `null` for a non-negotiated path.
  final CodecCapability? capability;

  bool _closed = false;
  bool _headerWritten = false;
  bool _finished = false;

  Muxer(this._platform, this.backendName, {this.capability});

  bool get isClosed => _closed;

  /// Write the container header. Must be called once before any packets.
  Future<void> writeHeader() async {
    _checkOpen();
    if (_headerWritten) {
      throw StateError('Muxer[$backendName] header already written.');
    }
    _headerWritten = true;
    await _platform.writeHeader();
  }

  /// Write one packet. Auto-calls [writeHeader] on first invocation.
  Future<void> writePacket(EncodedPacket packet) async {
    _checkOpen();
    if (!_headerWritten) await writeHeader();
    await _platform.writePacket(packet);
  }

  /// Finalise the container.
  Future<void> finish() async {
    _checkOpen();
    if (_finished) return;
    _finished = true;
    await _platform.finish();
  }

  /// For [BytesMuxerOutput]: the assembled bytes (only valid after [finish]).
  List<int>? getBytes() => _platform.getBytes();

  Future<void> close() async {
    if (_closed) return;
    if (_headerWritten && !_finished) {
      try {
        await finish();
      } catch (_) {}
    }
    _closed = true;
    await _platform.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('Muxer[$backendName] has been closed.');
    }
  }
}
