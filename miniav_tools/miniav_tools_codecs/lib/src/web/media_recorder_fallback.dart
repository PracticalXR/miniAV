/// MediaRecorder-based fallback for browsers without WebCodecs.
///
/// `MediaRecorder` is a combined encode+mux API that operates on a live
/// `MediaStream` rather than individual frames. It does not fit the
/// frame-level [PlatformEncoder] / [PlatformMuxer] interface, so this
/// fallback is exposed as a **standalone class** rather than going through
/// [MiniAVTools].
///
/// ### When to use
///
/// ```dart
/// if (!WebCapability.hasVideoEncoder) {
///   // WebCodecs unavailable — fall back to MediaRecorder.
///   final capture = MediaRecorderCapture(
///     stream: await getDisplayMediaStream(),
///     onChunk: (bytes) => writeToDisk(bytes),
///   );
///   await capture.start();
///   await Future.delayed(const Duration(seconds: 10));
///   await capture.stop();
/// }
/// ```
///
/// ### Container / codec negotiation
///
/// [MediaRecorderCapture.preferredMimeType] iterates a priority list of
/// `video/webm` and `video/mp4` types and returns the first one the browser
/// supports via `MediaRecorder.isTypeSupported()`. Pass the result (or your
/// own string) as [mimeType].
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// ---------------------------------------------------------------------------
// MIME type negotiation
// ---------------------------------------------------------------------------

/// Ordered list of mime types to try when negotiating with the browser.
const _kPreferredTypes = [
  'video/webm;codecs=h264',
  'video/webm;codecs=vp9',
  'video/webm;codecs=vp8',
  'video/webm',
  'video/mp4;codecs=h264',
  'video/mp4',
];

// ---------------------------------------------------------------------------
// MediaRecorderCapture
// ---------------------------------------------------------------------------

/// Lightweight wrapper around the browser `MediaRecorder` API.
///
/// Handles the encode + mux pipeline for browsers that lack WebCodecs
/// (Firefox < 130, older Safari, etc.).
///
/// Each recorded chunk is delivered to [onChunk] as a [Uint8List]. The
/// accumulated bytes form a valid WebM or MP4 file depending on the browser.
class MediaRecorderCapture {
  MediaRecorderCapture({
    required web.MediaStream stream,
    required this.onChunk,
    String? mimeType,
    this.videoBitsPerSecond = 6000000,
    this.audioBitsPerSecond = 128000,

    /// Timeslice in ms: how often [onChunk] fires. 0 = on stop only.
    this.timesliceMs = 1000,
  }) : _stream = stream,
       _mimeType = mimeType ?? preferredMimeType;

  final web.MediaStream _stream;
  final void Function(Uint8List chunk) onChunk;
  final String _mimeType;
  final int videoBitsPerSecond;
  final int audioBitsPerSecond;
  final int timesliceMs;

  web.MediaRecorder? _recorder;
  final _completer = Completer<void>();

  /// Whether this capture is currently recording.
  bool get isRecording => _recorder != null;

  // -------------------------------------------------------------------------
  // Static helpers
  // -------------------------------------------------------------------------

  /// Returns the first MIME type from [_kPreferredTypes] that the current
  /// browser supports via `MediaRecorder.isTypeSupported()`.
  ///
  /// Falls back to `'video/webm'` if nothing matches (should not happen in
  /// practice on any browser that has `MediaRecorder`).
  static String get preferredMimeType {
    for (final t in _kPreferredTypes) {
      if (web.MediaRecorder.isTypeSupported(t)) return t;
    }
    return 'video/webm';
  }

  /// The mime type that will be (or is being) used.
  String get mimeType => _mimeType;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Start recording. Throws if already recording.
  Future<void> start() async {
    if (_recorder != null) throw StateError('Already recording');

    final opts = web.MediaRecorderOptions(
      mimeType: _mimeType,
      videoBitsPerSecond: videoBitsPerSecond,
      audioBitsPerSecond: audioBitsPerSecond,
    );
    _recorder = web.MediaRecorder(_stream, opts);

    _recorder!.addEventListener(
      'dataavailable',
      (web.Event e) {
        final blobEvent = e as web.BlobEvent;
        final blob = blobEvent.data;
        if (blob.size == 0) return;
        blob.arrayBuffer().toDart.then((buf) {
          onChunk(buf.toDart.asUint8List());
        });
      }.toJS,
    );

    _recorder!.addEventListener(
      'stop',
      (web.Event _) {
        if (!_completer.isCompleted) _completer.complete();
      }.toJS,
    );

    _recorder!.addEventListener(
      'error',
      (web.Event e) {
        if (!_completer.isCompleted) {
          _completer.completeError(
            StateError('MediaRecorder error: ${e.type}'),
          );
        }
      }.toJS,
    );

    if (timesliceMs > 0) {
      _recorder!.start(timesliceMs);
    } else {
      _recorder!.start();
    }
  }

  /// Stop recording and wait for the final chunk to be delivered.
  Future<void> stop() async {
    final rec = _recorder;
    if (rec == null) return;
    _recorder = null;
    rec.stop();
    await _completer.future;
  }

  /// Request the recorder to emit any buffered data immediately.
  void requestData() => _recorder?.requestData();
}
