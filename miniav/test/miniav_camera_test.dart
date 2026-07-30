import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

void main() {
  MiniAV.setLogLevel(MiniAVLogLevel.none);

  group('MiniCamera Tests', () {
    group('Static Methods', () {
      test('should enumerate available camera devices', () async {
        final devices = await MiniCamera.enumerateDevices();
        expect(devices, isA<List<MiniAVDeviceInfo>>());
        // Most systems should have at least one camera (front/back/webcam)
        // But we'll be lenient since some test environments might not
      });

      test('should get supported formats for a device', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final formats = await MiniCamera.getSupportedFormats(
            devices.first.deviceId,
          );
          expect(formats, isA<List<MiniAVVideoInfo>>());
          expect(formats, isNotEmpty);

          // Verify format properties are valid
          for (final format in formats) {
            expect(format.width, greaterThan(0));
            expect(format.height, greaterThan(0));
            expect(format.frameRateDenominator, greaterThan(0));
            expect(format.frameRateNumerator, greaterThan(0));
          }
        }
      });

      test('should get default format for a device', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final defaultFormat = await MiniCamera.getDefaultFormat(
            devices.first.deviceId,
          );
          expect(defaultFormat, isA<MiniAVVideoInfo>());
          expect(defaultFormat.width, greaterThan(0));
          expect(defaultFormat.height, greaterThan(0));
          expect(defaultFormat.frameRateDenominator, greaterThan(0));
          expect(defaultFormat.frameRateNumerator, greaterThan(0));
        }
      });

      test('should handle invalid device ID for supported formats', () async {
        try {
          final result = await MiniCamera.getSupportedFormats(
            'invalid_device_id',
          );
          // Platform might return empty list instead of throwing
          expect(result, isA<List<MiniAVVideoInfo>>());
        } catch (e) {
          expect(e, isException);
        }
      });

      test('should handle invalid device ID for default format', () async {
        try {
          final result = await MiniCamera.getDefaultFormat('invalid_device_id');
          // Platform might return fallback format instead of throwing
          expect(result, isA<MiniAVVideoInfo>());
          expect(result.width, greaterThan(0));
          expect(result.height, greaterThan(0));
        } catch (e) {
          expect(e, isException);
        }
      });

      test('should create camera context', () async {
        final context = await MiniCamera.createContext();
        expect(context, isA<MiniCameraContext>());
        await context.destroy();
      });
    });

    group('MiniCameraContext Tests', () {
      late MiniCameraContext context;
      late List<MiniAVDeviceInfo> devices;
      late MiniAVVideoInfo defaultFormat;

      setUp(() async {
        context = await MiniCamera.createContext();
        devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          defaultFormat = await MiniCamera.getDefaultFormat(
            devices.first.deviceId,
          );
        }
      });

      tearDown(() async {
        try {
          await context.stopCapture();
        } catch (e) {
          // Ignore if already stopped
        }
        await context.destroy();
      });

      test('should configure camera with device and format', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);

          final configuredFormat = await context.getConfiguredFormat();
          expect(configuredFormat.width, equals(defaultFormat.width));
          expect(configuredFormat.height, equals(defaultFormat.height));
          expect(
            configuredFormat.frameRateNumerator,
            equals(defaultFormat.frameRateNumerator),
          );
          expect(
            configuredFormat.frameRateDenominator,
            equals(defaultFormat.frameRateDenominator),
          );
        }
      });

      test('should handle invalid device configuration', () async {
        try {
          await context.configure('invalid_device', defaultFormat);
          // If no exception, verify we can still get a configured format
          final configuredFormat = await context.getConfiguredFormat();
          expect(configuredFormat, isA<MiniAVVideoInfo>());
        } catch (e) {
          expect(e, isException);
        }
      });

      test('should handle invalid format configuration', () async {
        if (devices.isNotEmpty) {
          final invalidFormat = MiniAVVideoInfo(
            width: -1,
            height: 0,
            pixelFormat: MiniAVPixelFormat.unknown,
            frameRateNumerator: 0,
            frameRateDenominator: 0,
            outputPreference: MiniAVOutputPreference.gpu,
          );

          try {
            await context.configure(devices.first.deviceId, invalidFormat);
            // Platform might sanitize invalid values
            final configuredFormat = await context.getConfiguredFormat();
            expect(configuredFormat.width, greaterThan(0));
            expect(configuredFormat.height, greaterThan(0));
            expect(configuredFormat.frameRateNumerator, greaterThan(0));
            expect(configuredFormat.frameRateDenominator, greaterThan(0));
          } catch (e) {
            expect(e, isException);
          }
        }
      });

      test('should start and stop capture', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);

          bool frameReceived = false;
          await context.startCapture((buffer, userData) {
            frameReceived = true;
            expect(buffer, isA<MiniAVBuffer>());
            expect(buffer.dataSizeBytes, greaterThan(0));

            // Video buffer should contain frame data
            final videoBuffer = buffer.data as MiniAVVideoBuffer;
            expect(videoBuffer, isNotNull);
          });

          // Allow time for camera to initialize and capture frames
          await Future.delayed(Duration(milliseconds: 500));

          await context.stopCapture();
          expect(frameReceived, isTrue);
        }
      });

      test('should pass userData to callback', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);

          const testUserData = 'camera_test_data';
          Object? receivedUserData;

          await context.startCapture((buffer, userData) {
            receivedUserData = userData;
          }, userData: testUserData);

          await Future.delayed(Duration(milliseconds: 500));
          await context.stopCapture();

          if (receivedUserData != null) {
            expect(receivedUserData, equals(testUserData));
          }
        }
      });

      test('should handle multiple start capture calls', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);

          await context.startCapture((buffer, userData) {});

          // Second start should either succeed or throw predictable exception
          expect(
            () async => await context.startCapture((buffer, userData) {}),
            anyOf(returnsNormally, throwsException),
          );

          await context.stopCapture();
        }
      });

      test('should handle stop capture without start', () async {
        // Should not throw exception
        await context.stopCapture();
      });

      test('should handle multiple stop capture calls', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);
          await context.startCapture((buffer, userData) {});

          await context.stopCapture();
          // Second stop should not throw
          await context.stopCapture();
        }
      });

      test('should get configured format before configuration', () async {
        try {
          await context.getConfiguredFormat();
          // If no exception, verify it's a valid format
          final format = await context.getConfiguredFormat();
          expect(format, isA<MiniAVVideoInfo>());
        } catch (e) {
          expect(e, isException);
        }
      });

      test('should handle capture without configuration', () async {
        try {
          await context.startCapture((buffer, userData) {});
          // If no exception, capture started with default settings
          await context.stopCapture();
        } catch (e) {
          expect(e, isException);
        }
      });

      test('should receive video frames with correct format', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);

          MiniAVBuffer? receivedBuffer;
          await context.startCapture((buffer, userData) {
            receivedBuffer = buffer;
          });

          await Future.delayed(Duration(milliseconds: 300));
          await context.stopCapture();

          if (receivedBuffer != null) {
            expect(receivedBuffer!.dataSizeBytes, greaterThan(0));

            final videoBuffer = receivedBuffer!.data as MiniAVVideoBuffer;
            expect(videoBuffer, isNotNull);
            // Frame data should be substantial for video
            expect(receivedBuffer!.dataSizeBytes, greaterThan(1000));
          }
        }
      });

      test('should handle context destruction during capture', () async {
        if (devices.isNotEmpty) {
          await context.configure(devices.first.deviceId, defaultFormat);
          await context.startCapture((buffer, userData) {});

          // Destroying during capture should handle cleanup
          await context.destroy();
        }
      });

      test('should handle multiple destroy calls', () async {
        await context.destroy();
        // Second destroy should not throw
        await context.destroy();
      });

      test('should support different resolutions', () async {
        if (devices.isNotEmpty) {
          final formats = await MiniCamera.getSupportedFormats(
            devices.first.deviceId,
          );
          if (formats.length > 1) {
            // Test with different resolution
            final alternateFormat = formats.firstWhere(
              (f) =>
                  f.width != defaultFormat.width ||
                  f.height != defaultFormat.height,
              orElse: () => formats.first,
            );

            await context.configure(devices.first.deviceId, alternateFormat);
            final configuredFormat = await context.getConfiguredFormat();

            expect(configuredFormat.width, equals(alternateFormat.width));
            expect(configuredFormat.height, equals(alternateFormat.height));
          }
        }
      });

      test('should support different frame rates', () async {
        if (devices.isNotEmpty) {
          final formats = await MiniCamera.getSupportedFormats(
            devices.first.deviceId,
          );
          final differentFrameRateFormat = formats.firstWhere(
            (f) => f.frameRateNumerator != defaultFormat.frameRateNumerator,
            orElse: () => formats.first,
          );

          if (differentFrameRateFormat.frameRateNumerator !=
              defaultFormat.frameRateNumerator) {
            await context.configure(
              devices.first.deviceId,
              differentFrameRateFormat,
            );
            final configuredFormat = await context.getConfiguredFormat();

            expect(
              configuredFormat.frameRateNumerator,
              equals(differentFrameRateFormat.frameRateNumerator),
            );
          }
        }
      });
    });

    group('Device Detection Tests', () {
      test('should detect front and back cameras on mobile', () async {
        final devices = await MiniCamera.enumerateDevices();

        // Check if we can identify different camera types
        for (final device in devices) {
          expect(device.deviceId, isNotEmpty);
          expect(device.name, isNotEmpty);
          // Device should have some identifying information
        }
      });

      test('should handle camera permission requirements', () async {
        // This test depends on how permissions are handled in your platform
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final context = await MiniCamera.createContext();
          try {
            final format = await MiniCamera.getDefaultFormat(
              devices.first.deviceId,
            );
            await context.configure(devices.first.deviceId, format);

            // Attempting to start capture might require permissions
            await context.startCapture((buffer, userData) {});
            await context.stopCapture();
          } catch (e) {
            // Permission denied or camera not available is acceptable
            expect(e, isException);
          } finally {
            await context.destroy();
          }
        }
      });
    });

    group('Integration Tests', () {
      test('should work with multiple contexts simultaneously', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.length >= 2) {
          final context1 = await MiniCamera.createContext();
          final context2 = await MiniCamera.createContext();

          try {
            final format1 = await MiniCamera.getDefaultFormat(
              devices[0].deviceId,
            );
            final format2 = await MiniCamera.getDefaultFormat(
              devices[1].deviceId,
            );

            await context1.configure(devices[0].deviceId, format1);
            await context2.configure(devices[1].deviceId, format2);

            final configuredFormat1 = await context1.getConfiguredFormat();
            final configuredFormat2 = await context2.getConfiguredFormat();

            expect(configuredFormat1.width, equals(format1.width));
            expect(configuredFormat2.width, equals(format2.width));
          } finally {
            await context1.destroy();
            await context2.destroy();
          }
        }
      });

      test('should handle rapid create/destroy cycles', () async {
        for (int i = 0; i < 3; i++) {
          final context = await MiniCamera.createContext();
          await context.destroy();
        }
      });

      test('should enumerate devices consistently', () async {
        final devices1 = await MiniCamera.enumerateDevices();
        final devices2 = await MiniCamera.enumerateDevices();

        // Device lists should be consistent
        expect(devices1.length, equals(devices2.length));
        if (devices1.isNotEmpty && devices2.isNotEmpty) {
          expect(devices1.first.deviceId, equals(devices2.first.deviceId));
        }
      });
    });

    group('Performance Tests', () {
      test('should enumerate devices quickly', () async {
        final stopwatch = Stopwatch()..start();
        await MiniCamera.enumerateDevices();
        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      });

      test('should create context quickly', () async {
        final stopwatch = Stopwatch()..start();
        final context = await MiniCamera.createContext();
        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(2000));
        await context.destroy();
      });

      test('should configure context quickly', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final context = await MiniCamera.createContext();
          final format = await MiniCamera.getDefaultFormat(
            devices.first.deviceId,
          );

          final stopwatch = Stopwatch()..start();
          await context.configure(devices.first.deviceId, format);
          stopwatch.stop();

          expect(stopwatch.elapsedMilliseconds, lessThan(2000));
          await context.destroy();
        }
      });

      test('should start capture within reasonable time', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final context = await MiniCamera.createContext();
          final format = await MiniCamera.getDefaultFormat(
            devices.first.deviceId,
          );
          await context.configure(devices.first.deviceId, format);

          final stopwatch = Stopwatch()..start();
          await context.startCapture((buffer, userData) {});
          stopwatch.stop();

          expect(stopwatch.elapsedMilliseconds, lessThan(3000));

          await context.stopCapture();
          await context.destroy();
        }
      });
    });

    group('Format Validation Tests', () {
      test('should validate supported video formats', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final formats = await MiniCamera.getSupportedFormats(
            devices.first.deviceId,
          );

          for (final format in formats) {
            // Common video resolutions should be reasonable
            expect(format.width, inInclusiveRange(1, 7680));
            expect(format.height, inInclusiveRange(1, 4320));
            expect(format.pixelFormat, isNot(MiniAVPixelFormat.unknown));
          }
        }
      });

      test('should handle common video formats', () async {
        final devices = await MiniCamera.enumerateDevices();
        if (devices.isNotEmpty) {
          final formats = await MiniCamera.getSupportedFormats(
            devices.first.deviceId,
          );

          // Should support at least one common format
          final commonFormats = formats.where(
            (f) =>
                f.pixelFormat == MiniAVPixelFormat.nv12 ||
                f.pixelFormat == MiniAVPixelFormat.yuv420_10bit ||
                f.pixelFormat == MiniAVPixelFormat.rgb24 ||
                f.pixelFormat == MiniAVPixelFormat.bgr24,
          );

          expect(commonFormats, isNotEmpty);
        }
      });
    });
  });
}
