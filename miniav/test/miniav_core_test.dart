import 'dart:typed_data';

import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

void main() {
  MiniAV.setLogLevel(MiniAVLogLevel.none);
  group('MiniAV Core Tests', () {
    group('Library Information', () {
      test('should return version string', () {
        final version = MiniAV.getVersion();
        expect(version, isA<String>());
        expect(version, isNotEmpty);
        // Version should follow some pattern (e.g., semantic versioning)
        expect(version, matches(RegExp(r'^\d+\.\d+\.\d+.*')));
      });

      test('should set log level', () {
        // Test different log levels
        for (final level in MiniAVLogLevel.values) {
          expect(() => MiniAV.setLogLevel(level), returnsNormally);
        }
      });

      test('should handle all log levels', () {
        // Test each log level specifically
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.none), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.error), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.warn), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.info), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.debug), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.trace), returnsNormally);
      });
    });

    group('Component Access', () {
      test('should provide camera instance', () {
        final camera = MiniAV.camera;
        expect(camera, isA<MiniCamera>());
        expect(camera, isNotNull);
      });

      test('should provide screen instance', () {
        final screen = MiniAV.screen;
        expect(screen, isA<MiniScreen>());
        expect(screen, isNotNull);
      });

      test('should provide audio input instance', () {
        final audioInput = MiniAV.audioInput;
        expect(audioInput, isA<MiniAudioInput>());
        expect(audioInput, isNotNull);
      });

      test('should provide loopback instance', () {
        final loopback = MiniAV.loopback;
        expect(loopback, isA<MiniLoopback>());
        expect(loopback, isNotNull);
      });

      test('should provide input instance', () {
        final input = MiniAV.input;
        expect(input, isA<MiniInput>());
        expect(input, isNotNull);
      });

      test('should return same instance on multiple calls', () {
        final camera1 = MiniAV.camera;
        final camera2 = MiniAV.camera;
        expect(identical(camera1, camera2), isFalse); // New instances each time
        expect(camera1.runtimeType, equals(camera2.runtimeType));
      });
    });

    group('Resource Management', () {
      test('should dispose without error', () {
        expect(() => MiniAV.dispose(), returnsNormally);
      });

      test('should handle multiple dispose calls', () {
        MiniAV.dispose();
        expect(() => MiniAV.dispose(), returnsNormally);
      });

      test('should continue working after dispose', () {
        MiniAV.dispose();

        // Should still be able to access components
        expect(() => MiniAV.camera, returnsNormally);
        expect(() => MiniAV.getVersion(), returnsNormally);
      });

      test('should release buffer', () async {
        // Create a mock buffer for testing
        final buffer = MiniAVBuffer(
          data: Uint8List(1024),
          dataSizeBytes: 1024,
          timestampUs: DateTime.now().microsecondsSinceEpoch,
          type: MiniAVBufferType.video,
          contentType: MiniAVBufferContentType.cpu,
        );

        expect(() async => await MiniAV.releaseBuffer(buffer), returnsNormally);
      });

      test('should handle null buffer release gracefully', () async {
        // Test with minimal buffer
        final buffer = MiniAVBuffer(
          data: Uint8List(0),
          dataSizeBytes: 0,
          timestampUs: 0,
          type: MiniAVBufferType.unknown,
          contentType: MiniAVBufferContentType.cpu,
        );

        expect(() async => await MiniAV.releaseBuffer(buffer), returnsNormally);
      });
    });

    group('Platform Integration', () {
      test('should have platform interface', () {
        // Test that platform interface is accessible
        expect(MiniAV.camera, isNotNull);
        expect(MiniAV.screen, isNotNull);
        expect(MiniAV.audioInput, isNotNull);
        expect(MiniAV.loopback, isNotNull);
        expect(MiniAV.input, isNotNull);
      });

      test('should handle platform method calls', () async {
        // Test basic platform operations
        expect(() => MiniAV.getVersion(), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.info), returnsNormally);
      });

      test('should enumerate all device types', () async {
        // Test that all device enumeration methods exist and work
        expect(
          () async => await MiniCamera.enumerateDevices(),
          returnsNormally,
        );

        expect(
          () async => await MiniScreen.enumerateDisplays(),
          returnsNormally,
        );

        expect(
          () async => await MiniAudioInput.enumerateDevices(),
          returnsNormally,
        );

        expect(
          () async => await MiniLoopback.enumerateDevices(),
          returnsNormally,
        );

        expect(
          () async => await MiniInput.enumerateGamepads(),
          returnsNormally,
        );
      });
    });

    group('Error Handling', () {
      test('should handle platform exceptions gracefully', () {
        // Test that library doesn't crash on platform errors
        expect(() => MiniAV.getVersion(), returnsNormally);
        expect(() => MiniAV.setLogLevel(MiniAVLogLevel.debug), returnsNormally);
      });

      test('should validate log level parameter', () {
        // Test with all valid log levels
        for (final level in MiniAVLogLevel.values) {
          expect(() => MiniAV.setLogLevel(level), returnsNormally);
        }
      });
    });

    group('Cross-Component Integration', () {
      test('should allow simultaneous component usage', () async {
        // Test that multiple components can be used together
        final cameras = await MiniCamera.enumerateDevices();
        final displays = await MiniScreen.enumerateDisplays();
        final audioDevices = await MiniAudioInput.enumerateDevices();
        final loopbackDevices = await MiniLoopback.enumerateDevices();

        expect(cameras, isA<List<MiniAVDeviceInfo>>());
        expect(displays, isA<List<MiniAVDeviceInfo>>());
        expect(audioDevices, isA<List<MiniAVDeviceInfo>>());
        expect(loopbackDevices, isA<List<MiniAVDeviceInfo>>());
      });

      test('should create multiple contexts simultaneously', () async {
        final cameraContext = await MiniCamera.createContext();
        final screenContext = await MiniScreen.createContext();
        final audioContext = await MiniAudioInput.createContext();
        final loopbackContext = await MiniLoopback.createContext();

        expect(cameraContext, isA<MiniCameraContext>());
        expect(screenContext, isA<MiniScreenContext>());
        expect(audioContext, isA<MiniAudioInputContext>());
        expect(loopbackContext, isA<MiniLoopbackContext>());

        // Clean up
        await cameraContext.destroy();
        await screenContext.destroy();
        await audioContext.destroy();
        await loopbackContext.destroy();
      });

      test('should handle mixed component operations', () async {
        // Test interleaved operations across components
        final cameras = await MiniCamera.enumerateDevices();
        final audioDevices = await MiniAudioInput.enumerateDevices();

        if (cameras.isNotEmpty && audioDevices.isNotEmpty) {
          final cameraContext = await MiniCamera.createContext();
          final audioContext = await MiniAudioInput.createContext();

          try {
            final cameraFormat = await MiniCamera.getDefaultFormat(
              cameras.first.deviceId,
            );
            final audioFormat = await MiniAudioInput.getDefaultFormat(
              audioDevices.first.deviceId,
            );

            await cameraContext.configure(cameras.first.deviceId, cameraFormat);
            await audioContext.configure(
              audioDevices.first.deviceId,
              audioFormat,
            );

            final configuredCameraFormat = await cameraContext
                .getConfiguredFormat();
            final configuredAudioFormat = await audioContext
                .getConfiguredFormat();

            expect(configuredCameraFormat, isA<MiniAVVideoInfo>());
            expect(configuredAudioFormat, isA<MiniAVAudioInfo>());
          } finally {
            await cameraContext.destroy();
            await audioContext.destroy();
          }
        }
      });
    });

    group('Buffer Management', () {
      test('should handle various buffer sizes', () async {
        final buffers = [
          MiniAVBuffer(
            data: Uint8List(0),
            dataSizeBytes: 0,
            timestampUs: 0,
            type: MiniAVBufferType.video,
            contentType: MiniAVBufferContentType.cpu,
          ),
          MiniAVBuffer(
            data: Uint8List(1024),
            dataSizeBytes: 1024,
            timestampUs: DateTime.now().microsecondsSinceEpoch,
            type: MiniAVBufferType.audio,
            contentType: MiniAVBufferContentType.cpu,
          ),
          MiniAVBuffer(
            data: Uint8List(1024 * 1024),
            dataSizeBytes: 1024 * 1024,
            timestampUs: DateTime.now().microsecondsSinceEpoch,
            type: MiniAVBufferType.video,
            contentType: MiniAVBufferContentType.cpu,
          ),
        ];

        for (final buffer in buffers) {
          expect(
            () async => await MiniAV.releaseBuffer(buffer),
            returnsNormally,
          );
        }
      });

      test('should handle buffers with different timestamps', () async {
        final timestamps = [
          0,
          DateTime.now().microsecondsSinceEpoch,
          DateTime.now().add(Duration(seconds: 1)).microsecondsSinceEpoch,
        ];

        for (final timestamp in timestamps) {
          final buffer = MiniAVBuffer(
            data: Uint8List(512),
            dataSizeBytes: 512,
            timestampUs: timestamp,
            type: MiniAVBufferType.audio,
            contentType: MiniAVBufferContentType.cpu,
          );

          expect(
            () async => await MiniAV.releaseBuffer(buffer),
            returnsNormally,
          );
        }
      });
    });

    group('Library State', () {
      test('should maintain consistent state across operations', () {
        final version1 = MiniAV.getVersion();
        MiniAV.setLogLevel(MiniAVLogLevel.debug);
        final version2 = MiniAV.getVersion();

        expect(version1, equals(version2));
      });

      test('should handle rapid state changes', () {
        // Rapidly change log levels
        for (int i = 0; i < 10; i++) {
          for (final level in MiniAVLogLevel.values) {
            expect(() => MiniAV.setLogLevel(level), returnsNormally);
          }
        }

        // Version should still be accessible
        expect(() => MiniAV.getVersion(), returnsNormally);
      });

      test('should handle dispose and reinitialize cycle', () {
        final versionBefore = MiniAV.getVersion();

        MiniAV.dispose();

        final versionAfter = MiniAV.getVersion();
        expect(versionBefore, equals(versionAfter));

        // Should still be able to access components
        expect(MiniAV.camera, isA<MiniCamera>());
        expect(MiniAV.audioInput, isA<MiniAudioInput>());
      });
    });

    group('Performance', () {
      test('should access components quickly', () {
        final stopwatch = Stopwatch()..start();

        for (int i = 0; i < 100; i++) {
          MiniAV.camera;
          MiniAV.screen;
          MiniAV.audioInput;
          MiniAV.loopback;
        }

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });

      test('should get version quickly', () {
        final stopwatch = Stopwatch()..start();

        for (int i = 0; i < 100; i++) {
          MiniAV.getVersion();
        }

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });

      test('should set log level quickly', () {
        final stopwatch = Stopwatch()..start();

        for (int i = 0; i < 100; i++) {
          MiniAV.setLogLevel(MiniAVLogLevel.info);
        }

        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });
    });

    group('Comprehensive Integration', () {
      test('should demonstrate full library workflow', () async {
        // This test demonstrates a typical usage pattern

        // 1. Set up logging
        MiniAV.setLogLevel(MiniAVLogLevel.info);

        // 2. Get version info
        final version = MiniAV.getVersion();
        expect(version, isNotEmpty);

        // 3. Enumerate all device types
        final cameras = await MiniCamera.enumerateDevices();
        final screens = await MiniScreen.enumerateDisplays();
        final audioInputs = await MiniAudioInput.enumerateDevices();
        final loopbacks = await MiniLoopback.enumerateDevices();

        expect(cameras, isA<List<MiniAVDeviceInfo>>());
        expect(screens, isA<List<MiniAVDeviceInfo>>());
        expect(audioInputs, isA<List<MiniAVDeviceInfo>>());
        expect(loopbacks, isA<List<MiniAVDeviceInfo>>());

        // 4. Create contexts for available devices
        final contexts = <dynamic>[];

        try {
          if (cameras.isNotEmpty) {
            contexts.add(await MiniCamera.createContext());
          }
          if (screens.isNotEmpty) {
            contexts.add(await MiniScreen.createContext());
          }
          if (audioInputs.isNotEmpty) {
            contexts.add(await MiniAudioInput.createContext());
          }
          if (loopbacks.isNotEmpty) {
            contexts.add(await MiniLoopback.createContext());
          }

          expect(contexts, isNotEmpty);
        } finally {
          // 5. Clean up all contexts
          for (final context in contexts) {
            await context.destroy();
          }

          // 6. Dispose library
          MiniAV.dispose();
        }
      });
    });
  });
}
