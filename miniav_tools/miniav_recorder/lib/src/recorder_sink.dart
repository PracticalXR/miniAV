/// Sealed config types for recorder sinks.
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'track_chunk.dart';

sealed class RecorderSink {
  const RecorderSink();
}

class FileRecorderSink extends RecorderSink {
  final String path;
  final Container? container;
  const FileRecorderSink({required this.path, this.container});
}

class StreamRecorderSink extends RecorderSink {
  /// Receives [TrackChunk] objects (typed as [Object] in the Builder API
  /// to keep the public surface narrow; cast inside your callback).
  final void Function(Object chunk) onChunk;
  const StreamRecorderSink({required this.onChunk});
}
