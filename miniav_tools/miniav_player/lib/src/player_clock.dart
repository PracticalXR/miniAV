/// Presentation clock: a pts-anchored monotonic wall clock.
///
/// `mediaTimeUs()` answers "which pts should be on screen / audible right
/// now". The first accepted stream chunk anchors it (audio wins when both
/// tracks exist — see `MiniavPlayer`); pausing freezes it; re-anchoring
/// steps it (used when the audio ring overflows and we drop samples).
library;

/// Monotonic microsecond source, injectable for tests.
typedef NowUs = int Function();

final Stopwatch _processClock = Stopwatch()..start();
int _defaultNowUs() => _processClock.elapsedMicroseconds;

class PlayerClock {
  PlayerClock({NowUs? nowUs}) : _nowUs = nowUs ?? _defaultNowUs;

  final NowUs _nowUs;

  int? _anchorPtsUs;
  int _anchorWallUs = 0;

  bool _paused = false;
  int _pausedAtWallUs = 0;

  bool get isAnchored => _anchorPtsUs != null;
  bool get isPaused => _paused;

  /// Anchor (or re-anchor) the clock: from this instant,
  /// `mediaTimeUs() == ptsUs` and advances in real time.
  void anchor(int ptsUs) {
    _anchorPtsUs = ptsUs;
    _anchorWallUs = _nowUs();
    if (_paused) _pausedAtWallUs = _anchorWallUs;
  }

  /// Current media time in µs, or `null` before the first [anchor].
  int? mediaTimeUs() {
    final anchorPts = _anchorPtsUs;
    if (anchorPts == null) return null;
    final wall = _paused ? _pausedAtWallUs : _nowUs();
    return anchorPts + (wall - _anchorWallUs);
  }

  void pause() {
    if (_paused) return;
    _paused = true;
    _pausedAtWallUs = _nowUs();
  }

  void resume() {
    if (!_paused) return;
    // Shift the anchor forward by the paused duration so media time
    // continues from where it froze.
    _anchorWallUs += _nowUs() - _pausedAtWallUs;
    _paused = false;
  }

  /// Drop the anchor (e.g. after a flush/seek); the next stream chunk
  /// re-anchors.
  void reset() {
    _anchorPtsUs = null;
    _paused = false;
  }
}
