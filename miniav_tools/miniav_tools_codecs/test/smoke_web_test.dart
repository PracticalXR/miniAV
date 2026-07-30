/// Browser smoke tests for miniav_tools_codecs.
///
/// Run with:
///   dart test -p chrome --tags browser
///
/// For WebGPU tests, launch Chrome with:
///   --enable-unsafe-webgpu --disable-dawn-features=disallow_unsafe_apis
///
/// CI note: `WebCapability.hasWebGPU` is probed at runtime and the
/// webgpu-tagged test is skipped gracefully if the API is unavailable,
/// so it will not fail on GPU-less CI runners.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:miniav_tools_codecs/web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  // Force lazy registration of WebCodecsBackend into MiniAVToolsPlatform.
  setUpAll(ensureInitialized);

  // -------------------------------------------------------------------------
  // WebCapability — synchronous flags
  // -------------------------------------------------------------------------

  group('WebCapability', () {
    test('hasVideoEncoder returns bool without throwing', () {
      expect(WebCapability.hasVideoEncoder, isA<bool>());
    });

    test('hasAudioEncoder returns bool without throwing', () {
      expect(WebCapability.hasAudioEncoder, isA<bool>());
    });

    test('hasWebGPU returns bool without throwing', () {
      expect(WebCapability.hasWebGPU, isA<bool>());
    });

    test('hasMediaRecorder returns bool without throwing', () {
      expect(WebCapability.hasMediaRecorder, isA<bool>());
    });

    test('hasOffscreenCanvas returns bool without throwing', () {
      expect(WebCapability.hasOffscreenCanvas, isA<bool>());
    });

    test('isVideoEncoderSupported returns bool without throwing', () async {
      final result = await WebCapability.isVideoEncoderSupported('avc1.42E01E');
      expect(result, isA<bool>());
    });
  });

  // -------------------------------------------------------------------------
  // Backend registration
  // -------------------------------------------------------------------------

  group('WebCodecsBackend registration', () {
    test('registers in MiniAVToolsPlatform on import', () {
      // Importing miniav_tools_codecs triggers auto-registration.
      final backends = MiniAVToolsPlatform.instance.backends;
      expect(
        backends.any((b) => b.name == 'webcodecs'),
        isTrue,
        reason: 'WebCodecsBackend should be auto-registered on import',
      );
    });

    test('registering twice is idempotent', () {
      final before = MiniAVToolsPlatform.instance.backends.length;
      // Second registration attempt via the same helper.
      MiniAVToolsPlatform.instance.register(WebCodecsBackend());
      // The platform deduplicates by name so count should be the same.
      final after = MiniAVToolsPlatform.instance.backends.length;
      expect(after, equals(before));
    });

    test('backend has correct name and priority', () {
      final b = WebCodecsBackend();
      expect(b.name, equals('webcodecs'));
      expect(b.priority, equals(80));
    });

    test('backend reports correct accepted frame sources', () {
      final b = WebCodecsBackend();
      expect(b.acceptedFrameSources, contains(FrameSourceKind.cpu));
      expect(b.acceptedFrameSources, contains(FrameSourceKind.webVideoFrame));
    });
  });

  // -------------------------------------------------------------------------
  // WebCodecsBackend capabilities
  // -------------------------------------------------------------------------

  group('WebCodecsBackend capability queries', () {
    final b = WebCodecsBackend();

    test('supportsEncode for unsupported codec returns false', () {
      expect(b.supportsEncode(VideoCodec.mjpeg), isFalse);
    });

    test('supportsEncode for H.264 matches hasVideoEncoder', () {
      expect(
        b.supportsEncode(VideoCodec.h264),
        equals(WebCapability.hasVideoEncoder),
      );
    });

    test('createEncoder returns null for unsupported codec', () async {
      final enc = await b.createEncoder(
        EncoderConfig(
          codec: VideoCodec.mjpeg,
          width: 64,
          height: 64,
          bitrateBps: 1000000,
        ),
      );
      expect(enc, isNull);
    });

    test(
      'createEncoder does not throw when VideoEncoder is unavailable',
      () async {
        // Even if WebCodecs is not present, this must return null, not throw.
        final enc = await b.createEncoder(
          EncoderConfig(
            codec: VideoCodec.h264,
            width: 64,
            height: 64,
            bitrateBps: 1000000,
          ),
        );
        // May be null (no WebCodecs) or a WebCodecsVideoEncoder — both fine.
        expect(enc, anyOf(isNull, isA<PlatformEncoder>()));
      },
    );
  });

  // -------------------------------------------------------------------------
  // MediaRecorderCapture fallback
  // -------------------------------------------------------------------------

  group('MediaRecorderCapture', () {
    test('preferredMimeType returns a non-empty string', () {
      final mime = MediaRecorderCapture.preferredMimeType;
      expect(mime, isNotEmpty);
    });

    test('preferredMimeType is a WebM or MP4 variant', () {
      final mime = MediaRecorderCapture.preferredMimeType;
      expect(mime, anyOf(startsWith('video/webm'), startsWith('video/mp4')));
    });
  });

  // -------------------------------------------------------------------------
  // WebVideoFrameSource (platform interface type)
  // -------------------------------------------------------------------------

  group('WebVideoFrameSource', () {
    test('factory construction works with Object videoFrame', () {
      // Use a trivial JS object to stand in for a real VideoFrame.
      final fakeFame = web.window; // any JSObject works for construction
      final src = FrameSource.webVideoFrame(
        videoFrame: fakeFame,
        width: 640,
        height: 480,
        pixelFormat: MiniAVPixelFormat.rgba32,
        timestampUs: 1000,
      );
      expect(src.kind, equals(FrameSourceKind.webVideoFrame));
      expect(src.width, equals(640));
      expect(src.height, equals(480));
      expect(src.timestampUs, equals(1000));
    });
  });

  // -------------------------------------------------------------------------
  // WebCodecs round-trip (skipped if VideoEncoder unavailable)
  // -------------------------------------------------------------------------

  group('WebCodecs encoding', () {
    test('encode 64x64 RGBA frame via CPU path', () async {
      if (!WebCapability.hasVideoEncoder) {
        markTestSkipped('VideoEncoder API not available in this browser');
        return;
      }
      if (!WebCapability.hasOffscreenCanvas) {
        markTestSkipped('OffscreenCanvas not available in this browser');
        return;
      }

      // Check H.264 support before creating an encoder.
      final h264ok = await WebCapability.isVideoEncoderSupported(
        'avc1.42E01E',
        width: 64,
        height: 64,
      );
      if (!h264ok) {
        markTestSkipped('H.264 not supported at 64x64 in this browser');
        return;
      }

      final backend = WebCodecsBackend();
      final encoder = await backend.createEncoder(
        EncoderConfig(
          codec: VideoCodec.h264,
          width: 64,
          height: 64,
          bitrateBps: 500000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
        ),
      );
      expect(encoder, isNotNull, reason: 'createEncoder should succeed');

      // Solid RGBA frame (red pixels).
      final bytes = Uint8List(64 * 64 * 4);
      for (var i = 0; i < bytes.length; i += 4) {
        bytes[i] = 255; // R
        bytes[i + 1] = 0; // G
        bytes[i + 2] = 0; // B
        bytes[i + 3] = 255; // A
      }

      final frame = FrameSource.cpu(
        bytes: bytes,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: 64,
        height: 64,
        timestampUs: 0,
      );

      final packet = await encoder!.encode(frame);
      // First IDR may or may not flush immediately depending on browser.
      // A null return is valid (encoder buffering); non-null is also valid.
      if (packet != null) {
        expect(packet.data, isNotEmpty);
        expect(packet.isKeyframe, isTrue);
      }

      final flushed = await encoder.flush();
      expect(flushed.length + (packet != null ? 1 : 0), greaterThan(0));

      await encoder.close();
    }, tags: ['browser']);
  });
}
