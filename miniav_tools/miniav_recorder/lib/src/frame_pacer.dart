/// Per-frame pacing for a video track: which frames to drop, what PTS to
/// stamp, and (in CFR mode) which output grid slots to backfill with
/// duplicates. Pure timing policy — no I/O — so it is unit-testable.
library;

/// Result of [FramePacer.claimPts] for an accepted live frame.
class PaceClaim {
  const PaceClaim({required this.ptsUs, required this.backfillPtsUs});

  /// PTS to stamp on the live frame (grid-snapped in CFR mode, the capture
  /// timestamp otherwise).
  final int ptsUs;

  /// CFR mode: PTS of grid slots the capture missed since the previous frame,
  /// oldest first. The caller should emit a duplicate of the PREVIOUS frame at
  /// each of these before encoding the live frame, so the output timeline has
  /// no presentation holes. Empty in VFR mode.
  final List<int> backfillPtsUs;
}

/// Decides frame pacing for one video track. Two modes:
///
/// **VFR (default)** — frames keep their capture timestamps. The fps throttle
/// engages only when the source meaningfully outruns the target rate (e.g. a
/// 60 Hz display captured at 30 fps). A source within ~15% of the target — the
/// classic case is DXGI duplication delivering ~31.4 fps against a 30 fps
/// target — passes through untouched: deleting frames from an almost-on-target
/// cadence replaces one source frame with a double-length presentation hole
/// every ~20 frames, a metronomic visible stutter, whereas keeping them yields
/// a smooth VFR stream that players handle natively.
///
/// The throttle itself is the credit scheduler: the ideal schedule advances by
/// exactly one interval per accepted frame (never reset to `now`), so a source
/// that outruns the target is thinned evenly instead of in bursts.
///
/// **CFR** — output PTS are quantized to the exact rational fps grid
/// (`base + n·10⁶·den/num`). Each grid slot is filled at most once: a live
/// frame claims the slot nearest its capture time; slots the capture missed
/// (GPU contention, dropped frames) are reported via [PaceClaim.backfillPtsUs]
/// for duplicate backfill; the idle filler claims overdue slots via
/// [claimIdleSlot]; a frame mapping to an already-filled slot is dropped. The
/// result is a constant-frame-rate stream with no timing holes regardless of
/// source cadence — a missed capture becomes an (invisible) duplicated frame
/// instead of a visible playback hiccup.
class FramePacer {
  FramePacer({
    required this.frameRateNum,
    required this.frameRateDen,
    this.cfr = false,
  }) : intervalUs = frameRateNum > 0 && frameRateDen > 0
           ? (1000000 * frameRateDen) ~/ frameRateNum
           : 0;

  final int frameRateNum;
  final int frameRateDen;
  final bool cfr;

  /// Nominal frame interval in µs (0 = no target rate; everything passes).
  final int intervalUs;

  // ---- VFR near-target tolerance --------------------------------------
  // The throttle engages when the arrival-interval EMA drops below
  // [_engagePermille]/1000 of the target interval (source ≳18% fast) and
  // releases above [_disengagePermille]/1000 — hysteresis so a source
  // sitting exactly on the boundary doesn't flap between modes.
  static const int _engagePermille = 850;
  static const int _disengagePermille = 900;

  /// EMA smoothing: new = (old*7 + sample) / 8 — converges in ~20 frames.
  int _emaUs = 0;
  int _lastArrivalUs = -1;
  bool _throttleActive = false;

  /// Credit-scheduler ideal timestamp (advanced by exactly one effective
  /// interval per accepted frame while the throttle is engaged).
  int _scheduleUs = -1;

  // ---- CFR grid --------------------------------------------------------
  /// Cap on slots backfilled inline ahead of one live frame. Covers the
  /// adaptive GPU-throttle's worst divisor (÷4 → 3 missed slots per live
  /// frame); longer stalls are the idle filler's job, and anything beyond
  /// both is abandoned (a timeline hole) rather than burst-encoded.
  static const int maxInlineBackfill = 4;

  int _baseUs = -1;
  int _nextSlot = 0;

  /// Highest slot handed out at arrival time (claims happen later, at encode
  /// time; this catches two arrivals mapping to the same slot before either
  /// has been encoded, so the loser is dropped before wasting GPU work).
  int _lastArrivalSlot = -1;

  /// Whether the VFR fps throttle is currently engaged (source meaningfully
  /// faster than the target rate). Always false in CFR mode.
  bool get throttleActive => _throttleActive;

  /// Source cadence estimate (EMA of arrival spacing), in milliseconds.
  double get arrivalEmaMs => _emaUs / 1000.0;

  int _slotPts(int slot) =>
      _baseUs + (slot * 1000000 * frameRateDen) ~/ frameRateNum;

  /// Grid slot nearest to [captureUs] (rational rounding — no drift).
  int _slotFor(int captureUs) {
    final elapsed = captureUs - _baseUs;
    return (elapsed * frameRateNum + 500000 * frameRateDen) ~/
        (1000000 * frameRateDen);
  }

  /// Arrival-side gate: returns true when the frame should be dropped without
  /// entering the encode pipeline. Also tracks the source cadence EMA.
  /// [divisor] is the adaptive GPU-pressure divisor (1 = no pressure).
  bool shouldDropOnArrival(int captureUs, {int divisor = 1}) {
    if (intervalUs <= 0) return false;

    // Source cadence tracking (sample clamped so an idle stretch on a static
    // screen doesn't poison the estimate; a large clamped sample still drives
    // the EMA above the disengage threshold within a few frames).
    if (_lastArrivalUs >= 0) {
      var d = captureUs - _lastArrivalUs;
      if (d < 0) d = 0;
      final cap = intervalUs * 4;
      if (d > cap) d = cap;
      _emaUs = _emaUs <= 0 ? d : (_emaUs * 7 + d) >> 3;
    }
    _lastArrivalUs = captureUs;

    if (cfr) {
      if (_baseUs < 0) {
        // First accepted frame anchors the grid at its capture time.
        _baseUs = captureUs;
        _lastArrivalSlot = 0;
        return false;
      }
      final slot = _slotFor(captureUs);
      // Under GPU pressure, thin live frames to every `divisor`-th slot; the
      // gaps are backfilled with cheap duplicate encodes at claim time.
      if (divisor > 1 && slot < _lastArrivalSlot + divisor) return true;
      // Slot already filled (idle filler / earlier claim) or already promised
      // to a frame still in the pipeline.
      if (slot < _nextSlot || slot <= _lastArrivalSlot) return true;
      _lastArrivalSlot = slot;
      return false;
    }

    // VFR. Under GPU pressure the credit scheduler always engages (the whole
    // point is thinning below the source rate); otherwise it engages only
    // when the source meaningfully outruns the target.
    if (divisor > 1) {
      return _dropByCredit(captureUs, intervalUs * divisor);
    }
    if (_emaUs > 0) {
      if (_emaUs * 1000 < intervalUs * _engagePermille) {
        _throttleActive = true;
      } else if (_emaUs * 1000 > intervalUs * _disengagePermille) {
        _throttleActive = false;
      }
    }
    if (!_throttleActive) {
      _scheduleUs = -1; // forget stale credit so re-engage starts fresh
      return false;
    }
    return _dropByCredit(captureUs, intervalUs);
  }

  bool _dropByCredit(int captureUs, int effIntervalUs) {
    if (_scheduleUs >= 0 && captureUs - _scheduleUs < effIntervalUs) {
      return true;
    }
    _scheduleUs = _scheduleUs < 0 ? captureUs : _scheduleUs + effIntervalUs;
    return false;
  }

  /// Encode-time PTS claim for a live frame. In VFR mode this is the identity
  /// (PTS = capture time). In CFR mode it claims the nearest grid slot and
  /// reports any missed slots to backfill first. Returns null when the slot
  /// was filled while the frame waited in the pipeline (drop the frame).
  PaceClaim? claimPts(int captureUs) {
    if (!cfr || intervalUs <= 0) {
      return PaceClaim(ptsUs: captureUs, backfillPtsUs: const []);
    }
    if (_baseUs < 0) {
      // Defensive: normally the arrival gate anchored the grid already.
      _baseUs = captureUs;
      _lastArrivalSlot = 0;
    }
    final slot = _slotFor(captureUs);
    if (slot < _nextSlot) return null;
    var fillFrom = _nextSlot;
    if (slot - fillFrom > maxInlineBackfill) {
      fillFrom = slot - maxInlineBackfill;
    }
    final backfill = <int>[for (var s = fillFrom; s < slot; s++) _slotPts(s)];
    _nextSlot = slot + 1;
    return PaceClaim(ptsUs: _slotPts(slot), backfillPtsUs: backfill);
  }

  /// Idle-filler claim (CFR only): returns the PTS of the next unfilled grid
  /// slot iff its moment has passed far enough that no live frame can claim it
  /// anymore (live frames claim their NEAREST slot, i.e. within ±half an
  /// interval of the slot time), else null. VFR mode always returns null —
  /// the caller keeps its wall-clock idle-fill behaviour there.
  int? claimIdleSlot(int nowUs) {
    if (!cfr || _baseUs < 0 || intervalUs <= 0) return null;
    final duePts = _slotPts(_nextSlot);
    if (nowUs - duePts < (intervalUs + 1) ~/ 2) return null;
    _nextSlot++;
    return duePts;
  }
}
