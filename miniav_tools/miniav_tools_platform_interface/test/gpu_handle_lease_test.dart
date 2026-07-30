// P0.4: the GpuHandleLease refcount primitive — the formal "hold the GPU pool
// slot until every consumer is done" contract. Verifies the last release fires
// onLastRelease exactly once, and that double-release / retain-after-release
// are logic errors.
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  test('single hold: release fires onLastRelease exactly once', () {
    var released = 0;
    final lease = GpuHandleLease(() => released++);
    expect(lease.holdCount, 1);
    expect(lease.isReleased, isFalse);

    lease.release();
    expect(released, 1);
    expect(lease.isReleased, isTrue);
    expect(lease.holdCount, 0);
  });

  test('retain adds holds; onLastRelease fires only at zero', () {
    var released = 0;
    final lease = GpuHandleLease(() => released++);
    lease.retain(); // 2
    lease.retain(); // 3
    expect(lease.holdCount, 3);

    lease.release(); // 2
    lease.release(); // 1
    expect(released, 0, reason: 'not the last hold yet');

    lease.release(); // 0
    expect(released, 1, reason: 'fires exactly once at the last release');
    expect(lease.isReleased, isTrue);
  });

  test('retain returns this for chaining', () {
    final lease = GpuHandleLease(() {});
    expect(identical(lease.retain(), lease), isTrue);
    lease.release();
    lease.release();
  });

  test('double-release throws (never fires onLastRelease twice)', () {
    var released = 0;
    final lease = GpuHandleLease(() => released++);
    lease.release();
    expect(() => lease.release(), throwsA(isA<StateError>()));
    expect(released, 1);
  });

  test('retain after release throws (a freed slot must not resurrect)', () {
    final lease = GpuHandleLease(() {});
    lease.release();
    expect(() => lease.retain(), throwsA(isA<StateError>()));
  });
}
