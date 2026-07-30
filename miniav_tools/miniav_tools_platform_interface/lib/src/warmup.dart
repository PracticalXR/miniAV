/// Progress events for [MiniAVToolsBackend.warmup] /
/// [MiniAVTools.warmup].
library;

/// A single progress snapshot emitted during backend warmup.
///
/// ### Stream contract
/// - Events are emitted as work progresses.
/// - The stream completes (via `onDone`) when all warmup tasks finish.
/// - Failures are surfaced as events with [isDone] = `true` and a non-null
///   [error] — the stream never errors, so callers don't need `onError`.
///
/// ### Typical usage (Flutter)
///
/// ```dart
/// MiniAVTools.warmup().listen(
///   (p) {
///     if (p.fraction != null) {
///       setState(() => _download = p.fraction!);
///     }
///   },
///   onDone: () => setState(() => _ready = true),
/// );
/// ```
class WarmupProgress {
  const WarmupProgress({
    required this.backendName,
    required this.task,
    required this.isDone,
    this.bytesReceived,
    this.totalBytes,
    this.error,
  });

  /// Name of the backend emitting this event (e.g. `"ffmpeg"`).
  final String backendName;

  /// Human-readable description of the current task
  /// (e.g. `"Downloading FFmpeg"`).
  final String task;

  /// Whether this event marks the end of [task].
  ///
  /// Always `true` on the last event for a given task, whether the task
  /// succeeded or failed.
  final bool isDone;

  /// Bytes received so far (only present for download-type tasks).
  final int? bytesReceived;

  /// Total expected bytes. `null` means the total is unknown (e.g. the
  /// server did not send `Content-Length`).
  final int? totalBytes;

  /// Set when [task] completed with an error. [isDone] is always `true` when
  /// this is non-null.
  final Object? error;

  // ---------------------------------------------------------------------------

  /// Download progress in `[0.0, 1.0]`, or `null` when:
  /// - this is not a download event,
  /// - [totalBytes] is unknown (`null`), or
  /// - [totalBytes] is zero.
  double? get fraction {
    final t = totalBytes;
    final r = bytesReceived;
    if (t == null || t <= 0 || r == null) return null;
    return (r / t).clamp(0.0, 1.0);
  }

  @override
  String toString() {
    final pct = fraction != null
        ? ' (${(fraction! * 100).toStringAsFixed(0)}%)'
        : '';
    final status = error != null
        ? ' [error: $error]'
        : isDone
        ? ' [done]'
        : '';
    return 'WarmupProgress[$backendName] $task$pct$status';
  }
}
