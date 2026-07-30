@TestOn('vm')
library;

import 'dart:io';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

/// Platform-aware backend behaviour:
///
/// `FfmpegBackend.acceptedFrameSources` advertises the GPU-handle frame
/// sources that match the current OS, plus the universal CPU fallbacks.
/// This lets pipelines fingerprint the right zero-copy path at startup
/// without instantiating any encoder.
///
/// We do not exercise the encoder open path here \u2014 those live in
/// vendor-specific test files (`d3d11_hw_encoder_test.dart`, etc.).
void main() {
  group('FfmpegBackend platform dispatch', () {
    final backend = FfmpegBackend();

    test('acceptedFrameSources always includes CPU fallbacks', () {
      final sources = backend.acceptedFrameSources;
      expect(sources, contains(FrameSourceKind.cpu));
      expect(sources, contains(FrameSourceKind.miniavBufferCpu));
    });

    test(
      'acceptedFrameSources advertises the right GPU handle for this OS',
      () {
        final sources = backend.acceptedFrameSources;
        if (Platform.isWindows) {
          expect(sources, contains(FrameSourceKind.miniavBufferD3D11));
          expect(sources, contains(FrameSourceKind.d3d11Texture));
          expect(sources, isNot(contains(FrameSourceKind.cvPixelBuffer)));
          expect(sources, isNot(contains(FrameSourceKind.dmabuf)));
        } else if (Platform.isMacOS || Platform.isIOS) {
          expect(sources, contains(FrameSourceKind.miniavBufferMetal));
          expect(sources, contains(FrameSourceKind.cvPixelBuffer));
          expect(sources, isNot(contains(FrameSourceKind.miniavBufferD3D11)));
          expect(sources, isNot(contains(FrameSourceKind.dmabuf)));
        } else if (Platform.isLinux) {
          expect(sources, contains(FrameSourceKind.miniavBufferDmabuf));
          expect(sources, contains(FrameSourceKind.dmabuf));
          expect(sources, isNot(contains(FrameSourceKind.miniavBufferD3D11)));
          expect(sources, isNot(contains(FrameSourceKind.cvPixelBuffer)));
        } else if (Platform.isAndroid) {
          expect(
            sources,
            contains(FrameSourceKind.miniavBufferAHardwareBuffer),
          );
        }
      },
    );

    test('FrameSourceKind enum still carries every cross-platform variant', () {
      // If anyone removes a variant the encoder fingerprinting breaks
      // silently; pin them so a refactor in the platform interface forces
      // a coordinated update.
      const required = {
        FrameSourceKind.cpu,
        FrameSourceKind.miniavBufferCpu,
        FrameSourceKind.miniavBufferD3D11,
        FrameSourceKind.d3d11Texture,
        FrameSourceKind.miniavBufferMetal,
        FrameSourceKind.cvPixelBuffer,
        FrameSourceKind.miniavBufferDmabuf,
        FrameSourceKind.dmabuf,
        FrameSourceKind.miniavBufferAHardwareBuffer,
      };
      for (final k in required) {
        expect(FrameSourceKind.values, contains(k), reason: '$k');
      }
    });
  });
}
