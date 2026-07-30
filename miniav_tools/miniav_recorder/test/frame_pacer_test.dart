import 'package:miniav_recorder/src/frame_pacer.dart';
import 'package:test/test.dart';

/// Drives a pacer the way the recorder does: arrival gate, then (for accepted
/// frames) an encode-time claim. Returns every emitted PTS in order —
/// backfill duplicates flattened in front of the live frame that claimed them.
({List<int> emitted, List<int> livePts, int drops, int dups}) run(
  FramePacer pacer,
  Iterable<int> arrivals, {
  int Function(int index)? divisorAt,
}) {
  final emitted = <int>[];
  final livePts = <int>[];
  var drops = 0;
  var dups = 0;
  var i = 0;
  for (final t in arrivals) {
    final divisor = divisorAt?.call(i) ?? 1;
    i++;
    if (pacer.shouldDropOnArrival(t, divisor: divisor)) {
      drops++;
      continue;
    }
    final claim = pacer.claimPts(t);
    if (claim == null) {
      drops++;
      continue;
    }
    for (final b in claim.backfillPtsUs) {
      emitted.add(b);
      dups++;
    }
    emitted.add(claim.ptsUs);
    livePts.add(claim.ptsUs);
  }
  return (emitted: emitted, livePts: livePts, drops: drops, dups: dups);
}

List<int> spaced(int count, int spacingUs, {int start = 1000}) =>
    [for (var n = 0; n < count; n++) start + n * spacingUs];

void main() {
  const interval30 = 33333; // 1e6 * 1 ~/ 30

  group('FramePacer VFR', () {
    test('near-target source (31.5 fps vs 30 target) passes untouched', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      // 31.5 fps = the DXGI-overdelivery case from the field log.
      final arrivals = spaced(400, 31746);
      final r = run(pacer, arrivals);
      expect(r.drops, 0,
          reason: 'a source within tolerance of target must not be thinned — '
              'each drop is a double-length presentation hole');
      expect(pacer.throttleActive, isFalse);
      expect(r.livePts, arrivals, reason: 'VFR keeps capture timestamps');
    });

    test('fast source (60 fps vs 30 target) thins evenly to the target', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final r = run(pacer, spaced(600, 16667));
      expect(pacer.throttleActive, isTrue);
      expect(r.drops / 600, closeTo(0.5, 0.05));
      // Even spacing: no accepted-frame gap may exceed ~2 source intervals.
      for (var i = 1; i < r.livePts.length; i++) {
        expect(r.livePts[i] - r.livePts[i - 1], lessThanOrEqualTo(2 * 16667),
            reason: 'credit scheduler must thin evenly, not in bursts');
      }
    });

    test('cadence shift 60 fps → 31.5 fps releases the throttle', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final fast = spaced(200, 16667);
      final slowStart = fast.last + 31746;
      final slow = spaced(200, 31746, start: slowStart);
      run(pacer, fast);
      expect(pacer.throttleActive, isTrue);
      final r2 = run(pacer, slow);
      expect(pacer.throttleActive, isFalse,
          reason: 'EMA must release the throttle once cadence ≈ target');
      // EMA needs ~a dozen frames to converge; after that, zero drops.
      final tail = slow.sublist(50);
      final pacer2 = FramePacer(frameRateNum: 30, frameRateDen: 1);
      run(pacer2, fast);
      final rTail = run(pacer2, slow.sublist(0, 50));
      expect(r2.drops, rTail.drops,
          reason: 'all drops happen during EMA convergence, none in the tail '
              '(tail = ${tail.length} frames)');
    });

    test('adaptive divisor 2 halves a 30 fps source evenly', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final r = run(pacer, spaced(300, interval30), divisorAt: (_) => 2);
      expect(r.drops / 300, closeTo(0.5, 0.05));
      for (var i = 1; i < r.livePts.length; i++) {
        expect(
            r.livePts[i] - r.livePts[i - 1], lessThanOrEqualTo(2 * interval30 + 2000));
      }
    });

    test('an idle gap does not poison the tolerance estimate', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final before = spaced(100, 31746);
      final after = spaced(100, 31746, start: before.last + 5000000); // 5 s gap
      final r1 = run(pacer, before);
      final r2 = run(pacer, after);
      expect(r1.drops + r2.drops, 0);
      expect(pacer.throttleActive, isFalse);
    });

    test('claimPts is the identity in VFR mode', () {
      final pacer = FramePacer(frameRateNum: 30, frameRateDen: 1);
      final claim = pacer.claimPts(123456)!;
      expect(claim.ptsUs, 123456);
      expect(claim.backfillPtsUs, isEmpty);
    });
  });

  group('FramePacer CFR', () {
    // Grid slot PTS for a 30/1 pacer anchored at [base].
    int slotPts(int base, int slot) => base + (slot * 1000000) ~/ 30;

    test('near-target fast source → exact gapless grid, surplus dropped', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      final arrivals = spaced(300, 31746); // 31.5 fps into a 30 fps grid
      final r = run(pacer, arrivals);
      final base = arrivals.first;
      // Every emitted PTS sits exactly on the grid, consecutively, no dups
      // needed (a faster-than-grid source never skips a slot).
      expect(r.dups, 0);
      for (var i = 0; i < r.emitted.length; i++) {
        expect(r.emitted[i], slotPts(base, i),
            reason: 'slot $i must be exactly on the rational grid');
      }
      // ~1 in 21 arrivals is surplus (two frames nearest the same slot).
      expect(r.drops, inInclusiveRange(8, 20));
      expect(r.emitted.length + r.drops, 300);
    });

    test('sagging 25 fps source → missed slots backfilled with duplicates',
        () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      final arrivals = spaced(120, 40000); // 25 fps into a 30 fps grid
      final r = run(pacer, arrivals);
      final base = arrivals.first;
      expect(r.dups, greaterThan(10),
          reason: '25 fps misses ~1 slot in 6 — those must be backfilled');
      for (var i = 0; i < r.emitted.length; i++) {
        expect(r.emitted[i], slotPts(base, i),
            reason: 'backfill + live together must tile the grid gaplessly');
      }
      expect(r.drops, 0);
    });

    test('long stall caps inline backfill at maxInlineBackfill', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      const base = 1000;
      expect(pacer.shouldDropOnArrival(base), isFalse);
      expect(pacer.claimPts(base)!.ptsUs, base);
      // Jump ~21 slots ahead.
      final late = base + 700000;
      expect(pacer.shouldDropOnArrival(late), isFalse);
      final claim = pacer.claimPts(late)!;
      expect(claim.backfillPtsUs.length, FramePacer.maxInlineBackfill);
      final liveSlot = ((late - base) * 30 + 500000) ~/ 1000000;
      expect(
        claim.backfillPtsUs,
        [
          for (var s = liveSlot - FramePacer.maxInlineBackfill; s < liveSlot; s++)
            slotPts(base, s)
        ],
        reason: 'backfill hugs the live frame; older slots are abandoned',
      );
      expect(claim.ptsUs, slotPts(base, liveSlot));
    });

    test('idle filler claims only slots no live frame can still claim', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      const base = 1000;
      expect(pacer.shouldDropOnArrival(base), isFalse);
      pacer.claimPts(base);
      final slot1 = slotPts(base, 1);
      // Slot 1's claim window (±half interval) still open → no fill.
      expect(pacer.claimIdleSlot(slot1 + 16000), isNull);
      // Window closed → fill slot 1.
      expect(pacer.claimIdleSlot(slot1 + 16667), slot1);
      // Slot 2 is still in the future → no fill.
      expect(pacer.claimIdleSlot(slot1 + 16667), isNull);
    });

    test('live frame whose slot the idle filler took is dropped', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      const base = 1000;
      expect(pacer.shouldDropOnArrival(base), isFalse);
      pacer.claimPts(base);
      // Filler takes slots 1 and 2.
      expect(pacer.claimIdleSlot(slotPts(base, 2) + 16667), isNotNull);
      expect(pacer.claimIdleSlot(slotPts(base, 2) + 16667), isNotNull);
      // A frame captured nearest slot 2 arrives late → arrival gate drops it.
      expect(pacer.shouldDropOnArrival(slotPts(base, 2) + 100), isTrue);
    });

    test('claimPts returns null when the slot was taken while queued', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      const base = 1000;
      expect(pacer.shouldDropOnArrival(base), isFalse);
      pacer.claimPts(base);
      final t = slotPts(base, 2); // maps to slot 2
      expect(pacer.shouldDropOnArrival(t), isFalse); // accepted → queued
      // Idle filler claims slots 1 and 2 before the queued frame encodes.
      expect(pacer.claimIdleSlot(slotPts(base, 2) + 16667), isNotNull);
      expect(pacer.claimIdleSlot(slotPts(base, 2) + 16667), isNotNull);
      expect(pacer.claimPts(t), isNull);
    });

    test('divisor thinning keeps the grid complete via backfill', () {
      final pacer =
          FramePacer(frameRateNum: 30, frameRateDen: 1, cfr: true);
      final arrivals = spaced(200, interval30 + 1); // ~30 fps source
      final r = run(pacer, arrivals, divisorAt: (_) => 2);
      final base = arrivals.first;
      // Live frames land every 2nd slot; duplicates tile the gaps.
      for (var i = 0; i < r.emitted.length; i++) {
        expect(r.emitted[i], slotPts(base, i));
      }
      expect(r.dups, greaterThan(80));
      expect(r.drops / 200, closeTo(0.5, 0.08));
    });

    test('rational rate (30000/1001) grid carries no cumulative drift', () {
      final pacer =
          FramePacer(frameRateNum: 30000, frameRateDen: 1001, cfr: true);
      const base = 1000;
      // Feed frames exactly on the rational grid for 3000 slots.
      var lastPts = -1;
      for (var k = 0; k <= 3000; k++) {
        final t = base + (k * 1000000 * 1001) ~/ 30000;
        expect(pacer.shouldDropOnArrival(t), isFalse, reason: 'slot $k');
        final claim = pacer.claimPts(t)!;
        expect(claim.backfillPtsUs, isEmpty, reason: 'slot $k');
        expect(claim.ptsUs, t, reason: 'slot $k must not drift');
        lastPts = claim.ptsUs;
      }
      // 3000 slots of 29.97 fps = exactly 100.1 s — the truncated per-frame
      // interval (33366 µs) would have drifted 2 ms by now.
      expect(lastPts - base, 100100000);
    });

    test('no target rate (fps 0) is a transparent pass-through', () {
      final pacer = FramePacer(frameRateNum: 0, frameRateDen: 1, cfr: true);
      expect(pacer.shouldDropOnArrival(1000), isFalse);
      final claim = pacer.claimPts(1000)!;
      expect(claim.ptsUs, 1000);
      expect(claim.backfillPtsUs, isEmpty);
      expect(pacer.claimIdleSlot(2000000), isNull);
    });
  });
}
