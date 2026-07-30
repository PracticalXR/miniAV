import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

// Umbrella-package coverage for the new remote-desktop primitives: the
// MiniInject wrapper, MiniScreen.setCaptureCursor, and the new MiniAVMouseEvent
// fields (wheelDeltaX / isAbsolute). No real events are injected — that would
// move the cursor / type on the developer's machine.
void main() {
  MiniAV.setLogLevel(MiniAVLogLevel.none);

  group('MiniInject', () {
    test('MiniAV.inject exposes the injector', () {
      expect(MiniAV.inject, isA<MiniInject>());
    });

    test('createContext returns a MiniInjectContext', () async {
      final ctx = await MiniInject.createContext();
      expect(ctx, isA<MiniInjectContext>());
      await ctx.destroy();
    });

    test('configure (keyboard|mouse) then destroy', () async {
      final ctx = await MiniInject.createContext();
      await ctx.configure(
        MiniAVInputType.keyboard.value | MiniAVInputType.mouse.value,
      );
      await ctx.destroy();
    });

    test('use-after-destroy throws, second destroy is safe', () async {
      final ctx = await MiniInject.createContext();
      await ctx.configure(MiniAVInputType.mouse.value);
      await ctx.destroy();
      await ctx.destroy();
      expect(
        () => ctx.injectMouse(
          MiniAVMouseEvent(
            timestampUs: 0,
            x: 0,
            y: 0,
            deltaX: 0,
            deltaY: 0,
            wheelDelta: 0,
            action: MiniAVMouseAction.move,
            button: MiniAVMouseButton.none,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MiniScreen.setCaptureCursor', () {
    test('toggling before configure succeeds', () async {
      final ctx = await MiniScreen.createContext();
      await ctx.setCaptureCursor(true);
      await ctx.setCaptureCursor(false);
      await ctx.destroy();
    });
  });

  group('MiniAVMouseEvent new fields', () {
    test('wheelDeltaX and isAbsolute default (0 / true) when omitted', () {
      final event = MiniAVMouseEvent(
        timestampUs: 1,
        x: 0,
        y: 0,
        deltaX: 0,
        deltaY: 0,
        wheelDelta: 0,
        action: MiniAVMouseAction.move,
        button: MiniAVMouseButton.none,
      );
      // Non-breaking constructor: existing call sites keep working, defaults
      // match capture semantics (absolute coords, no horizontal scroll).
      expect(event.wheelDeltaX, equals(0));
      expect(event.isAbsolute, isTrue);
    });

    test('wheelDeltaX and isAbsolute hold explicit values', () {
      final event = MiniAVMouseEvent(
        timestampUs: 2,
        x: 5,
        y: 6,
        deltaX: 0,
        deltaY: 0,
        wheelDelta: 120,
        wheelDeltaX: -120,
        action: MiniAVMouseAction.wheel,
        button: MiniAVMouseButton.none,
        isAbsolute: false,
      );
      expect(event.wheelDelta, equals(120));
      expect(event.wheelDeltaX, equals(-120));
      expect(event.isAbsolute, isFalse);
    });
  });
}
