import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

void main() {
  MiniAV.setLogLevel(MiniAVLogLevel.none);

  group('MiniInput Tests', () {
    group('Static Methods', () {
      test('should enumerate gamepads', () async {
        final devices = await MiniInput.enumerateGamepads();
        expect(devices, isA<List<MiniAVDeviceInfo>>());
        // Gamepads may not be connected on all systems

        for (final device in devices) {
          expect(device.deviceId, isNotEmpty);
          expect(device.name, isNotEmpty);
        }
      });

      test('should create input context', () async {
        final context = await MiniInput.createContext();
        expect(context, isA<MiniInputContext>());
        await context.destroy();
      });
    });

    group('MiniInputContext Tests', () {
      late MiniInputContext context;

      setUp(() async {
        context = await MiniInput.createContext();
      });

      tearDown(() async {
        try {
          await context.stopCapture();
        } catch (_) {}
        await context.destroy();
      });

      test('should configure with keyboard only', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        await context.configure(config);
      });

      test('should configure with mouse only', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.mouse.value,
        );
        await context.configure(config);
      });

      test('should configure with gamepad only', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.gamepad.value,
        );
        await context.configure(config);
      });

      test('should configure with all input types', () async {
        final config = MiniAVInputConfig(
          inputTypes:
              MiniAVInputType.keyboard.value |
              MiniAVInputType.mouse.value |
              MiniAVInputType.gamepad.value,
        );
        await context.configure(config);
      });

      test('should configure with custom throttle rates', () async {
        final config = MiniAVInputConfig(
          inputTypes:
              MiniAVInputType.mouse.value | MiniAVInputType.gamepad.value,
          mouseThrottleHz: 120,
          gamepadPollHz: 30,
        );
        await context.configure(config);
      });

      test('should configure with zero throttle (unlimited)', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.mouse.value,
          mouseThrottleHz: 0,
        );
        await context.configure(config);
      });

      test('should start and stop capture with keyboard', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        await context.configure(config);

        bool keyboardCalled = false;
        await context.startCapture(
          onKeyboard: (event, userData) {
            keyboardCalled = true;
            expect(event, isA<MiniAVKeyboardEvent>());
            expect(event.keyCode, greaterThanOrEqualTo(0));
            expect(
              event.action,
              anyOf(MiniAVKeyAction.down, MiniAVKeyAction.up),
            );
          },
        );

        // Input requires physical interaction; just verify start/stop works
        await Future.delayed(const Duration(milliseconds: 100));
        await context.stopCapture();
        // keyboardCalled may or may not be true depending on environment
      });

      test('should start and stop capture with mouse', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.mouse.value,
          mouseThrottleHz: 60,
        );
        await context.configure(config);

        await context.startCapture(
          onMouse: (event, userData) {
            expect(event, isA<MiniAVMouseEvent>());
          },
        );

        await Future.delayed(const Duration(milliseconds: 100));
        await context.stopCapture();
      });

      test('should start and stop capture with gamepad', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.gamepad.value,
          gamepadPollHz: 60,
        );
        await context.configure(config);

        await context.startCapture(
          onGamepad: (event, userData) {
            expect(event, isA<MiniAVGamepadEvent>());
            expect(event.gamepadIndex, lessThan(4));
          },
        );

        await Future.delayed(const Duration(milliseconds: 200));
        await context.stopCapture();
      });

      test('should start and stop capture with all types', () async {
        final config = MiniAVInputConfig(
          inputTypes:
              MiniAVInputType.keyboard.value |
              MiniAVInputType.mouse.value |
              MiniAVInputType.gamepad.value,
          mouseThrottleHz: 60,
          gamepadPollHz: 60,
        );
        await context.configure(config);

        await context.startCapture(
          onKeyboard: (event, _) {},
          onMouse: (event, _) {},
          onGamepad: (event, _) {},
        );

        await Future.delayed(const Duration(milliseconds: 200));
        await context.stopCapture();
      });

      test('should pass userData to callbacks', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        await context.configure(config);

        const testData = 'input_test_data';
        Object? received;

        await context.startCapture(
          onKeyboard: (event, userData) {
            received = userData;
          },
          userData: testData,
        );

        await Future.delayed(const Duration(milliseconds: 100));
        await context.stopCapture();
        // received may be null if no keys pressed during test
      });

      test('should handle stop capture without start', () async {
        // Should not throw
        await context.stopCapture();
      });

      test('should handle multiple stop capture calls', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        await context.configure(config);
        await context.startCapture(onKeyboard: (_, __) {});

        await context.stopCapture();
        // Second stop should not throw
        await context.stopCapture();
      });

      test('should handle capture without configuration', () async {
        try {
          await context.startCapture(onKeyboard: (_, __) {});
          // If no exception, capture started somehow
          await context.stopCapture();
        } catch (e) {
          expect(e, isA<StateError>());
        }
      });

      test('should handle context destruction during capture', () async {
        final config = MiniAVInputConfig(
          inputTypes:
              MiniAVInputType.keyboard.value | MiniAVInputType.mouse.value,
        );
        await context.configure(config);
        await context.startCapture(onKeyboard: (_, __) {}, onMouse: (_, __) {});

        // Destroying during capture should handle cleanup
        await context.destroy();
      });

      test('should handle multiple destroy calls', () async {
        await context.destroy();
        // Second destroy should not throw
        await context.destroy();
      });

      test('should handle start capture with no callbacks', () async {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        await context.configure(config);

        // Starting with no callbacks should still work
        await context.startCapture();
        await Future.delayed(const Duration(milliseconds: 100));
        await context.stopCapture();
      });
    });

    group('MiniAVInputConfig Tests', () {
      test('should create config with defaults', () {
        final config = MiniAVInputConfig(
          inputTypes: MiniAVInputType.keyboard.value,
        );
        expect(config.inputTypes, equals(MiniAVInputType.keyboard.value));
        expect(config.mouseThrottleHz, equals(60));
        expect(config.gamepadPollHz, equals(60));
      });

      test('should create config with custom values', () {
        final config = MiniAVInputConfig(
          inputTypes:
              MiniAVInputType.keyboard.value | MiniAVInputType.mouse.value,
          mouseThrottleHz: 120,
          gamepadPollHz: 30,
        );
        expect(
          config.inputTypes,
          equals(MiniAVInputType.keyboard.value | MiniAVInputType.mouse.value),
        );
        expect(config.mouseThrottleHz, equals(120));
        expect(config.gamepadPollHz, equals(30));
      });

      test('should support combined input type bitmask', () {
        final all =
            MiniAVInputType.keyboard.value |
            MiniAVInputType.mouse.value |
            MiniAVInputType.gamepad.value;
        expect(all & MiniAVInputType.keyboard.value, isNonZero);
        expect(all & MiniAVInputType.mouse.value, isNonZero);
        expect(all & MiniAVInputType.gamepad.value, isNonZero);
      });
    });

    group('Input Event Type Tests', () {
      test('MiniAVKeyAction values should be correct', () {
        expect(MiniAVKeyAction.down.value, equals(0));
        expect(MiniAVKeyAction.up.value, equals(1));
      });

      test('MiniAVKeyAction fromValue should work', () {
        expect(MiniAVKeyAction.fromValue(0), equals(MiniAVKeyAction.down));
        expect(MiniAVKeyAction.fromValue(1), equals(MiniAVKeyAction.up));
        expect(
          () => MiniAVKeyAction.fromValue(99),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('MiniAVMouseAction values should be correct', () {
        expect(MiniAVMouseAction.move.value, equals(0));
        expect(MiniAVMouseAction.buttonDown.value, equals(1));
        expect(MiniAVMouseAction.buttonUp.value, equals(2));
        expect(MiniAVMouseAction.wheel.value, equals(3));
      });

      test('MiniAVMouseAction fromValue should work', () {
        expect(MiniAVMouseAction.fromValue(0), equals(MiniAVMouseAction.move));
        expect(
          MiniAVMouseAction.fromValue(1),
          equals(MiniAVMouseAction.buttonDown),
        );
        expect(
          MiniAVMouseAction.fromValue(2),
          equals(MiniAVMouseAction.buttonUp),
        );
        expect(MiniAVMouseAction.fromValue(3), equals(MiniAVMouseAction.wheel));
        expect(
          () => MiniAVMouseAction.fromValue(99),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('MiniAVMouseButton values should be correct', () {
        expect(MiniAVMouseButton.none.value, equals(0));
        expect(MiniAVMouseButton.left.value, equals(1));
        expect(MiniAVMouseButton.right.value, equals(2));
        expect(MiniAVMouseButton.middle.value, equals(3));
        expect(MiniAVMouseButton.x1.value, equals(4));
        expect(MiniAVMouseButton.x2.value, equals(5));
      });

      test('MiniAVMouseButton fromValue should work', () {
        expect(MiniAVMouseButton.fromValue(0), equals(MiniAVMouseButton.none));
        expect(MiniAVMouseButton.fromValue(1), equals(MiniAVMouseButton.left));
        expect(MiniAVMouseButton.fromValue(5), equals(MiniAVMouseButton.x2));
        expect(
          () => MiniAVMouseButton.fromValue(99),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('MiniAVInputType bitmask values should be correct', () {
        expect(MiniAVInputType.keyboard.value, equals(0x01));
        expect(MiniAVInputType.mouse.value, equals(0x02));
        expect(MiniAVInputType.gamepad.value, equals(0x04));
      });

      test('MiniAVKeyboardEvent should hold correct data', () {
        final event = MiniAVKeyboardEvent(
          timestampUs: 123456,
          keyCode: 65,
          scanCode: 30,
          action: MiniAVKeyAction.down,
        );
        expect(event.timestampUs, equals(123456));
        expect(event.keyCode, equals(65));
        expect(event.scanCode, equals(30));
        expect(event.action, equals(MiniAVKeyAction.down));
      });

      test('MiniAVMouseEvent should hold correct data', () {
        final event = MiniAVMouseEvent(
          timestampUs: 789012,
          x: 100,
          y: 200,
          deltaX: 5,
          deltaY: -3,
          wheelDelta: 120,
          action: MiniAVMouseAction.wheel,
          button: MiniAVMouseButton.none,
        );
        expect(event.timestampUs, equals(789012));
        expect(event.x, equals(100));
        expect(event.y, equals(200));
        expect(event.deltaX, equals(5));
        expect(event.deltaY, equals(-3));
        expect(event.wheelDelta, equals(120));
        expect(event.action, equals(MiniAVMouseAction.wheel));
        expect(event.button, equals(MiniAVMouseButton.none));
      });

      test('MiniAVGamepadEvent should hold correct data', () {
        final event = MiniAVGamepadEvent(
          timestampUs: 111222,
          gamepadIndex: 0,
          buttons: 0x1000,
          leftStickX: -16000,
          leftStickY: 32000,
          rightStickX: 100,
          rightStickY: -200,
          leftTrigger: 128,
          rightTrigger: 255,
          connected: true,
        );
        expect(event.timestampUs, equals(111222));
        expect(event.gamepadIndex, equals(0));
        expect(event.buttons, equals(0x1000));
        expect(event.leftStickX, equals(-16000));
        expect(event.leftStickY, equals(32000));
        expect(event.rightStickX, equals(100));
        expect(event.rightStickY, equals(-200));
        expect(event.leftTrigger, equals(128));
        expect(event.rightTrigger, equals(255));
        expect(event.connected, isTrue);
      });
    });
  });
}
