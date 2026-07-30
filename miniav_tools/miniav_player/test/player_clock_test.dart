import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/src/player_clock.dart';

void main() {
  test('unanchored clock reports null', () {
    final clock = PlayerClock(nowUs: () => 1000);
    expect(clock.isAnchored, isFalse);
    expect(clock.mediaTimeUs(), isNull);
  });

  test('anchor maps pts to wall time', () {
    var now = 1000000;
    final clock = PlayerClock(nowUs: () => now);
    clock.anchor(500000);
    expect(clock.mediaTimeUs(), 500000);
    now += 250000;
    expect(clock.mediaTimeUs(), 750000);
  });

  test('pause freezes, resume continues without a jump', () {
    var now = 0;
    final clock = PlayerClock(nowUs: () => now);
    clock.anchor(100);
    now = 50;
    clock.pause();
    expect(clock.mediaTimeUs(), 150);
    now = 500; // wall time marches on while paused
    expect(clock.mediaTimeUs(), 150);
    clock.resume();
    expect(clock.mediaTimeUs(), 150);
    now = 600;
    expect(clock.mediaTimeUs(), 250);
  });

  test('re-anchor steps media time', () {
    var now = 0;
    final clock = PlayerClock(nowUs: () => now);
    clock.anchor(0);
    now = 100;
    clock.anchor(1000000); // e.g. stream restart / overflow step
    expect(clock.mediaTimeUs(), 1000000);
  });

  test('reset drops the anchor', () {
    final clock = PlayerClock(nowUs: () => 7);
    clock.anchor(1);
    clock.reset();
    expect(clock.isAnchored, isFalse);
    expect(clock.mediaTimeUs(), isNull);
  });
}
