@TestOn('browser')
library;

// Verifies the web MSE fallback: compiles the dart:js_interop / package:web /
// dart:ui_web interop through dart2js, and exercises it in a real (headless)
// Chrome — feature probes, MIME derivation, and <video>/MediaSource lifecycle.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// The barrel's conditional export resolves mse_support to the real web impl
// under `--platform chrome` (this test is @TestOn('browser')); importing the
// src file directly too would make every symbol ambiguous on VM analysis.
import 'package:miniav_player/miniav_player.dart';

void main() {
  group('capability probes (Chrome)', () {
    test('WebCodecs + MSE are available', () {
      expect(webCodecsVideoAvailable(), isTrue);
      expect(mseAvailable(), isTrue);
    });

    test('MseController reports supported + type support', () {
      expect(MseController.isSupportedPlatform, isTrue);
      expect(
        MseController.isTypeSupported('video/mp4; codecs="avc1.42E01E,mp4a.40.2"'),
        isTrue,
      );
      expect(MseController.isTypeSupported('video/x-nonsense; codecs="fake"'),
          isFalse);
    });
  });

  group('MIME derivation', () {
    test('blobMimeForBytes sniffs containers', () {
      // ISO-BMFF: box size (4) + 'ftyp'
      final mp4 = Uint8List.fromList(
          [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0]);
      expect(blobMimeForBytes(mp4), 'video/mp4');
      expect(blobMimeForBytes(mp4, hasVideo: false), 'audio/mp4');
      expect(blobMimeForBytes(Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3])),
          'video/webm');
      expect(blobMimeForBytes(Uint8List.fromList([0x4F, 0x67, 0x67, 0x53])),
          'audio/ogg');
      expect(blobMimeForBytes(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });

    test('mp4MimeForTracks derives avc1 from avcC + mp4a for AAC', () {
      // avcC: version=1, profile=0x64 (High), compat=0x00, level=0x28 (4.0)
      final v = VideoTrackInfo(
        codec: VideoCodec.h264,
        width: 1920,
        height: 1080,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        extraData: CodecExtraData.video(
            VideoCodec.h264, Uint8List.fromList([1, 0x64, 0x00, 0x28])),
      );
      const a = AudioTrackInfo(
          codec: AudioCodec.aac, sampleRate: 48000, channels: 2);
      expect(mp4MimeForTracks(v, a),
          'video/mp4; codecs="avc1.640028,mp4a.40.2"');
      // Audio-only -> audio/mp4
      expect(mp4MimeForTracks(null, a), 'audio/mp4; codecs="mp4a.40.2"');
      // Unknown video codec -> null (don't attempt MSE)
      final av1 = VideoTrackInfo(
        codec: VideoCodec.av1,
        width: 640,
        height: 480,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
      );
      expect(mp4MimeForTracks(av1, null), isNull);
    });
  });

  group('MseController lifecycle', () {
    test('blob mode: creates a video platform view, ready immediately', () async {
      final bytes = Uint8List.fromList(
          [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]);
      final c = MseController.blob(bytes, mimeType: 'video/mp4');
      expect(c.viewType, startsWith('miniav-mse-video-'));
      await c.onReady.timeout(const Duration(seconds: 2));
      c.dispose();
    });

    test('stream mode: MediaSource opens + SourceBuffer added', () async {
      final c = MseController.stream(
          mimeWithCodecs: 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
      expect(c.viewType, startsWith('miniav-mse-video-'));
      // sourceopen fires asynchronously once the element loads the object URL.
      await c.onReady.timeout(const Duration(seconds: 5));
      c.dispose();
    });

    test('dispose is idempotent', () {
      final c = MseController.blob(Uint8List.fromList([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]),
          mimeType: 'video/mp4');
      c.dispose();
      c.dispose(); // no throw
    });
  });
}
