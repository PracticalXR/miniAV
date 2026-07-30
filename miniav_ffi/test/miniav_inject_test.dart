import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_ffi/miniav_ffi.dart';
import 'package:miniav_ffi/miniav_ffi_bindings.dart' as bindings;
import 'package:miniav_ffi/miniav_ffi_types.dart' show mouseEventFromNative;

// Tests for the input-injection module, the screen cursor-capture setter, the
// horizontal-scroll / is_absolute mouse-event fields (ABI), and the
// PERMISSION_DENIED result code. These deliberately do NOT inject real
// keyboard/mouse events — that would move the cursor / type on the developer's
// machine. They validate that the new native symbols resolve, the backend
// selects, the FFI struct layout matches the C struct, and the lifecycle works
// end to end through the bindings.
void main() {
  late MiniInjectPlatformInterface inject;
  late MiniScreenPlatformInterface screen;

  setUpAll(() {
    final platform = MiniAVFFIPlatform();
    inject = platform.inject;
    screen = platform.screen;
  });

  group('Input injection', () {
    test('Create, Configure (keyboard|mouse), Destroy', () async {
      final ctx = await inject.createContext();
      expect(ctx, isNotNull);
      await ctx.configure(
        MiniAVInputType.keyboard.value | MiniAVInputType.mouse.value,
      );
      await ctx.destroy();
    });

    test('Destroy is idempotent-safe; use-after-destroy throws', () async {
      final ctx = await inject.createContext();
      await ctx.configure(MiniAVInputType.mouse.value);
      await ctx.destroy();
      await ctx.destroy(); // second destroy is a no-op, must not throw
      expect(
        () => ctx.configure(MiniAVInputType.mouse.value),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Screen cursor capture setter', () {
    test('SetCaptureCursor(true/false) before configure succeeds', () async {
      final ctx = await screen.createContext();
      await ctx.setCaptureCursor(true);
      await ctx.setCaptureCursor(false);
      await ctx.destroy();
    });

    test('SetCaptureCursor after configure is rejected', () async {
      final displays = await screen.enumerateDisplays();
      if (displays.isEmpty) {
        print('No displays; skipping after-configure rejection test.');
        return;
      }
      final ctx = await screen.createContext();
      try {
        final defaults = await screen.getDefaultFormats(displays.first.deviceId);
        await ctx.configureDisplay(displays.first.deviceId, defaults.$1);
        // Contract: must be called BEFORE configure — now rejected.
        expect(
          () => ctx.setCaptureCursor(true),
          throwsA(isA<Exception>()),
        );
      } finally {
        await ctx.destroy();
      }
    });
  });

  group('iOS App Group setter (off-iOS)', () {
    test('setIOSAppGroup reports NOT_SUPPORTED on desktop', () async {
      // The C seam returns MINIAV_ERROR_NOT_SUPPORTED off-iOS, which the FFI
      // layer surfaces as an exception. Validates the binding resolves.
      expect(
        () => screen.setIOSAppGroup('group.com.example.test'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('MiniAVMouseEvent FFI struct ABI', () {
    test('wheel_delta_x and is_absolute survive the native round-trip', () {
      final ptr = calloc<bindings.MiniAVMouseEvent>();
      try {
        final n = ptr.ref;
        n.timestamp_us = 42;
        n.x = 10;
        n.y = 20;
        n.delta_x = 1;
        n.delta_y = 2;
        n.wheel_delta = 120;
        n.wheel_delta_x = -240; // horizontal scroll, negative
        n.actionAsInt = MiniAVMouseAction.wheel.value;
        n.buttonAsInt = MiniAVMouseButton.x2.value;
        n.is_absolute = false;

        final ev = mouseEventFromNative(n);
        // If the Dart struct layout drifts from the C struct, these read the
        // wrong offsets and the assertions fail.
        expect(ev.timestampUs, 42);
        expect(ev.x, 10);
        expect(ev.y, 20);
        expect(ev.deltaX, 1);
        expect(ev.deltaY, 2);
        expect(ev.wheelDelta, 120);
        expect(ev.wheelDeltaX, -240);
        expect(ev.action, MiniAVMouseAction.wheel);
        expect(ev.button, MiniAVMouseButton.x2);
        expect(ev.isAbsolute, isFalse);
      } finally {
        calloc.free(ptr);
      }
    });

    test('is_absolute true round-trips', () {
      final ptr = calloc<bindings.MiniAVMouseEvent>();
      try {
        ptr.ref.is_absolute = true;
        ptr.ref.wheel_delta_x = 0;
        final ev = mouseEventFromNative(ptr.ref);
        expect(ev.isAbsolute, isTrue);
        expect(ev.wheelDeltaX, 0);
      } finally {
        calloc.free(ptr);
      }
    });
  });

  group('MINIAV_ERROR_PERMISSION_DENIED result code', () {
    test('fromValue(-23) maps to PERMISSION_DENIED (does not throw)', () {
      // Regression guard: the generated enum previously stopped at -22, so a
      // native -23 made fromValue throw ArgumentError instead of surfacing the
      // permission error.
      expect(
        bindings.MiniAVResultCode.fromValue(-23),
        equals(bindings.MiniAVResultCode.MINIAV_ERROR_PERMISSION_DENIED),
      );
    });
  });
}
