/// Where a source-driven player reads its container from.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';

/// A container source for [MiniavPlayer.openSource]: a file, a fully
/// buffered container, or a live/progressive byte stream (fMP4/MKV/MPEG-TS
/// over the network, a recorder chunk stream, …).
sealed class MediaSource {
  const MediaSource();

  /// A container file on disk. Seekable.
  const factory MediaSource.file(String path) = FileMediaSource;

  /// A fully buffered container in memory.
  const factory MediaSource.bytes(Uint8List bytes) = BytesMediaSource;

  /// A progressive/live container byte stream. Non-seekable; pair with
  /// `PlayerLatencyMode.live` for realtime feeds. Note: plain MP4 needs its
  /// moov up-front — use fMP4 (`Container.fmp4`) / MKV / MPEG-TS for
  /// streaming.
  const factory MediaSource.byteStream(
    Stream<List<int>> stream, {
    int bufferBytes,
  }) = ByteStreamMediaSource;

  DemuxerInput toDemuxerInput();
}

class FileMediaSource extends MediaSource {
  const FileMediaSource(this.path);
  final String path;

  @override
  DemuxerInput toDemuxerInput() => DemuxerInput.file(path);
}

class BytesMediaSource extends MediaSource {
  const BytesMediaSource(this.bytes);
  final Uint8List bytes;

  @override
  DemuxerInput toDemuxerInput() => DemuxerInput.bytes(bytes);
}

class ByteStreamMediaSource extends MediaSource {
  const ByteStreamMediaSource(
    this.stream, {
    this.bufferBytes = 16 * 1024 * 1024,
  });

  final Stream<List<int>> stream;

  /// Undemuxed input the backend may buffer before pausing [stream].
  final int bufferBytes;

  @override
  DemuxerInput toDemuxerInput() =>
      DemuxerInput.byteStream(stream, bufferBytes: bufferBytes);
}
