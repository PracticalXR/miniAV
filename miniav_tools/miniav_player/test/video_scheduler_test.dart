import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/src/player_clock.dart';
import 'package:miniav_player/src/video_scheduler.dart';

ScheduledVideoFrame frame(int ptsUs) => ScheduledVideoFrame(
  ptsUs: ptsUs,
  width: 2,
  height: 2,
  yuv420p: Uint8List(6),
);

void main() {
  group('live (latest-wins)', () {
    test('presents immediately when idle', () async {
      final presented = <int>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.live,
        clock: PlayerClock(nowUs: () => 0),
        present: (f) async => presented.add(f.ptsUs),
      );
      s.submit(frame(10));
      await Future<void>.delayed(Duration.zero);
      expect(presented, [10]);
      expect(s.presentedCount, 1);
    });

    test('supersedes queued frame while presenter is busy', () async {
      final presented = <int>[];
      final gates = <Completer<void>>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.live,
        clock: PlayerClock(nowUs: () => 0),
        present: (f) {
          presented.add(f.ptsUs);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );
      s.submit(frame(1)); // starts presenting, holds on gate 0
      s.submit(frame(2)); // pending
      s.submit(frame(3)); // supersedes 2
      s.submit(frame(4)); // supersedes 3
      expect(s.droppedSupersededCount, 2);
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(presented, [1, 4]); // only the newest pending followed
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(s.presentedCount, 2);
    });

    test('present errors are counted, scheduling continues', () async {
      final errors = <Object>[];
      var calls = 0;
      final s = VideoScheduler(
        mode: PlayerLatencyMode.live,
        clock: PlayerClock(nowUs: () => 0),
        present: (f) async {
          calls++;
          if (calls == 1) throw StateError('lost device');
        },
        onPresentError: (e, _) => errors.add(e),
      );
      s.submit(frame(1));
      await Future<void>.delayed(Duration.zero);
      s.submit(frame(2));
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(calls, 2);
    });
  });

  group('paced', () {
    test('presents due frames in pts order, holds early ones', () async {
      var now = 0;
      final clock = PlayerClock(nowUs: () => now);
      final presented = <int>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) async => presented.add(f.ptsUs),
      );
      // First frame anchors the clock at pts 100 → due immediately.
      s.submit(frame(100));
      await Future<void>.delayed(Duration.zero);
      expect(presented, [100]);

      // 1 s in the future — held (gap is large so the real backstop timer
      // cannot race the fake clock during this test).
      s.submit(frame(1000100));
      await Future<void>.delayed(Duration.zero);
      expect(presented, [100]);

      now += 1000000; // media time reaches the held pts
      s.pump();
      await Future<void>.delayed(Duration.zero);
      expect(presented, [100, 1000100]);
      s.dispose();
    });

    test('drops hopelessly late frames when newer are queued', () async {
      var now = 0;
      final clock = PlayerClock(nowUs: () => now);
      final presented = <int>[];
      final gates = <Completer<void>>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) {
          presented.add(f.ptsUs);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
        lateDropThresholdUs: 50000,
      );
      s.submit(frame(0)); // anchors, presents, holds on gate 0
      expect(presented, [0]);

      // Stall: media time runs 400ms ahead while the presenter is blocked
      // and the network keeps delivering.
      now += 400000;
      s.submit(frame(100000)); // 300ms late by the time the gate opens
      s.submit(frame(200000)); // 200ms late
      s.submit(frame(400000)); // on time
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(presented, [0, 400000]);
      expect(s.droppedLateCount, 2);
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      s.dispose();
    });

    test('a late frame with nothing newer queued still presents', () async {
      // Late-drop only applies when a newer frame waits behind — during a
      // stall the freshest (even stale) frame beats a frozen screen.
      var now = 0;
      final clock = PlayerClock(nowUs: () => now);
      final presented = <int>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) async => presented.add(f.ptsUs),
        lateDropThresholdUs: 50000,
      );
      s.submit(frame(0));
      await Future<void>.delayed(Duration.zero);
      now += 400000;
      s.submit(frame(100000)); // 300ms late, but the only candidate
      await Future<void>.delayed(Duration.zero);
      expect(presented, [0, 100000]);
      expect(s.droppedLateCount, 0);
      s.dispose();
    });

    test('out-of-order submission is pts-sorted', () async {
      var now = 0;
      final clock = PlayerClock(nowUs: () => now);
      final presented = <int>[];
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) async => presented.add(f.ptsUs),
      );
      clock.anchor(0);
      s.submit(frame(300));
      s.submit(frame(100));
      s.submit(frame(200));
      now = 1000; // everything due
      s.pump();
      // Each present completion re-pumps; drain the microtask chain.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(presented, [100, 200, 300]);
      s.dispose();
    });

    test('queue overflow drops oldest', () async {
      final clock = PlayerClock(nowUs: () => 0);
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) async {},
        maxQueuedFrames: 2,
      );
      clock.anchor(-1000000); // nothing is due; frames pile up
      s.submit(frame(1));
      s.submit(frame(2));
      s.submit(frame(3));
      expect(s.queueDepth, 2);
      expect(s.droppedLateCount, 1);
      s.dispose();
    });

    test('clear drops queued frames', () async {
      final clock = PlayerClock(nowUs: () => 0);
      final s = VideoScheduler(
        mode: PlayerLatencyMode.paced,
        clock: clock,
        present: (f) async {},
      );
      clock.anchor(-1000000);
      s.submit(frame(1));
      s.submit(frame(2));
      s.clear();
      expect(s.queueDepth, 0);
    });
  });
}
