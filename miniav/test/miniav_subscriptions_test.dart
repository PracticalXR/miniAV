// Tests for the device-change and context-lost subscription APIs added across
// camera, audio input, loopback, screen, and input modules.
//
// These tests verify the public API surface only — they validate that
// listeners can be registered, returned disposers can be called, and that
// repeated subscribe/unsubscribe cycles don't throw. Real add/remove and
// device-loss events are hardware-driven and cannot be reproducibly fired
// in CI, so behavioural verification of the notification payload itself is
// not attempted here.

import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

void main() {
  MiniAV.setLogLevel(MiniAVLogLevel.none);

  group('Subscription API — device-change listeners', () {
    test('MiniCamera.addDeviceChangeListener returns a working disposer', () {
      void Function()? dispose;
      expect(() {
        dispose = MiniCamera.addDeviceChangeListener((notification) {
          expect(notification, isA<MiniAVDeviceChangeNotification>());
        });
      }, returnsNormally);
      expect(dispose, isNotNull);
      expect(dispose!, returnsNormally);
    });

    test(
      'MiniAudioInput.addDeviceChangeListener returns a working disposer',
      () {
        void Function()? dispose;
        expect(() {
          dispose = MiniAudioInput.addDeviceChangeListener((_) {});
        }, returnsNormally);
        expect(dispose, isNotNull);
        expect(dispose!, returnsNormally);
      },
    );

    test('MiniLoopback.addDeviceChangeListener returns a working disposer', () {
      void Function()? dispose;
      expect(() {
        dispose = MiniLoopback.addDeviceChangeListener((_) {});
      }, returnsNormally);
      expect(dispose, isNotNull);
      expect(dispose!, returnsNormally);
    });

    test('MiniScreen.addDisplayChangeListener returns a working disposer', () {
      void Function()? dispose;
      expect(() {
        dispose = MiniScreen.addDisplayChangeListener((_) {});
      }, returnsNormally);
      expect(dispose, isNotNull);
      expect(dispose!, returnsNormally);
    });

    test('MiniScreen.addWindowChangeListener returns a working disposer', () {
      void Function()? dispose;
      expect(() {
        dispose = MiniScreen.addWindowChangeListener((_) {});
      }, returnsNormally);
      expect(dispose, isNotNull);
      expect(dispose!, returnsNormally);
    });

    test('MiniInput.addGamepadChangeListener returns a working disposer', () {
      void Function()? dispose;
      expect(() {
        dispose = MiniInput.addGamepadChangeListener((_) {});
      }, returnsNormally);
      expect(dispose, isNotNull);
      expect(dispose!, returnsNormally);
    });

    test('multiple listeners can coexist and be disposed independently', () {
      final notifications = <int>[];
      final dispose1 = MiniCamera.addDeviceChangeListener((_) {
        notifications.add(1);
      });
      final dispose2 = MiniCamera.addDeviceChangeListener((_) {
        notifications.add(2);
      });
      final dispose3 = MiniCamera.addDeviceChangeListener((_) {
        notifications.add(3);
      });

      // Disposing in arbitrary order should not throw.
      expect(dispose2, returnsNormally);
      expect(dispose1, returnsNormally);
      expect(dispose3, returnsNormally);
    });

    test('disposer is idempotent (calling it twice does not throw)', () {
      final dispose = MiniCamera.addDeviceChangeListener((_) {});
      expect(dispose, returnsNormally);
      expect(dispose, returnsNormally);
    });

    test('subscribe/unsubscribe cycles can be repeated', () {
      for (var i = 0; i < 5; i++) {
        final dispose = MiniAudioInput.addDeviceChangeListener((_) {});
        dispose();
      }
    });
  });

  group('Subscription API — context-lost listeners', () {
    test(
      'MiniCameraContext.addLostListener returns a working disposer',
      () async {
        final ctx = await MiniCamera.createContext();
        try {
          late void Function() dispose;
          expect(() {
            dispose = ctx.addLostListener((reason) {
              expect(reason, isA<int>());
            });
          }, returnsNormally);
          expect(dispose, returnsNormally);
        } finally {
          await ctx.destroy();
        }
      },
    );

    test(
      'MiniAudioInputContext.addLostListener returns a working disposer',
      () async {
        final ctx = await MiniAudioInput.createContext();
        try {
          late void Function() dispose;
          expect(() {
            dispose = ctx.addLostListener((_) {});
          }, returnsNormally);
          expect(dispose, returnsNormally);
        } finally {
          await ctx.destroy();
        }
      },
    );

    test(
      'MiniLoopbackContext.addLostListener returns a working disposer',
      () async {
        final ctx = await MiniLoopback.createContext();
        try {
          late void Function() dispose;
          expect(() {
            dispose = ctx.addLostListener((_) {});
          }, returnsNormally);
          expect(dispose, returnsNormally);
        } finally {
          await ctx.destroy();
        }
      },
    );

    test(
      'MiniScreenContext.addLostListener returns a working disposer',
      () async {
        final ctx = await MiniScreen.createContext();
        try {
          late void Function() dispose;
          expect(() {
            dispose = ctx.addLostListener((_) {});
          }, returnsNormally);
          expect(dispose, returnsNormally);
        } finally {
          await ctx.destroy();
        }
      },
    );

    test(
      'multiple lost listeners on a single context are independent',
      () async {
        final ctx = await MiniCamera.createContext();
        try {
          final d1 = ctx.addLostListener((_) {});
          final d2 = ctx.addLostListener((_) {});
          expect(d1, returnsNormally);
          expect(d2, returnsNormally);
        } finally {
          await ctx.destroy();
        }
      },
    );

    test(
      'destroying a context with active lost listeners does not throw',
      () async {
        final ctx = await MiniAudioInput.createContext();
        ctx.addLostListener((_) {});
        ctx.addLostListener((_) {});
        // No explicit dispose call — destroy() must clean up internally.
        await ctx.destroy();
      },
    );
  });

  group('Subscription API — types', () {
    test('MiniAVDeviceChangeNotification exposes event and device', () {
      final device = MiniAVDeviceInfo(
        deviceId: 'test',
        name: 'Test Device',
        isDefault: true,
      );
      final notification = MiniAVDeviceChangeNotification(
        MiniAVDeviceChangeEvent.added,
        device,
      );
      expect(notification.event, equals(MiniAVDeviceChangeEvent.added));
      expect(notification.device.deviceId, equals('test'));
      expect(notification.toString(), contains('test'));
    });

    test('MiniAVDeviceChangeEvent has all expected variants', () {
      expect(MiniAVDeviceChangeEvent.values, hasLength(3));
      expect(
        MiniAVDeviceChangeEvent.values,
        containsAll(<MiniAVDeviceChangeEvent>[
          MiniAVDeviceChangeEvent.added,
          MiniAVDeviceChangeEvent.removed,
          MiniAVDeviceChangeEvent.defaultChanged,
        ]),
      );
    });
  });
}
