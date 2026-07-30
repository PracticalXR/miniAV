/// Tests for the diagnostic log lines added to [FfmpegBackend.createEncoder].
///
/// The test suite verifies the observable contracts introduced by the logging
/// changes:
///
///  1. `createEncoder` returns null immediately (without calling
///     `_ensureAvailable`) when the requested codec is not in the backend's
///     supported set — exercisable without FFmpeg installed.
///
///  2. When FFmpeg *is* available, the software encoder path returns a
///     non-null encoder for a VP9 software-only config, verifying the path
///     that emits the `[ffmpeg] createEncoder: software encoder opened` line.
///
///  3. The `hwAccel=preferred` with a SW-only codec (vp9 not in _hwEncode)
///     falls through to the software encoder path.
///
///  4. The `preferZeroCopy` + `d3d11DeviceHandle=0` BackendContext does NOT
///     trigger the zero-copy open path (handle must be non-zero).
///
/// Tests that need real FFmpeg libraries skip cleanly when those libs are not
/// present (CI without the DLLs).
@TestOn('vm')
library;

import 'dart:io';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  final backend = FfmpegBackend();

  // -------------------------------------------------------------------------
  // 1. Null return for unsupported codec — no FFmpeg needed.
  // -------------------------------------------------------------------------
  group('createEncoder — unsupported codec returns null', () {
    test('returns null for an unrecognised VideoCodec', () async {
      // Find a codec the backend does NOT support.
      for (final codec in VideoCodec.values) {
        if (backend.supportsEncode(codec)) continue; // supported — skip
        // Found an unsupported codec. createEncoder should return null.
        final result = await backend.createEncoder(
          EncoderConfig(
            codec: codec,
            width: 1280,
            height: 720,
            bitrateBps: 2_000_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
          ),
        );
        expect(result, isNull, reason: '${codec.name} is not in supported set');
        return; // One case is enough to prove the contract.
      }
      // If *all* codecs are supported by this backend, skip.
      markTestSkipped('All VideoCodec values are listed as supported');
    });
  });

  // -------------------------------------------------------------------------
  // 2. Software encoder is returned — requires FFmpeg.
  // -------------------------------------------------------------------------
  group('createEncoder — software encoder path', () {
    test(
      'returns the isolate-hosted software encoder for VP9 with '
      'hwAccel=forbidden',
      () async {
        if (!tryLoadFFmpeg()) {
          markTestSkipped('FFmpeg shared libraries not available');
          return;
        }

        const config = EncoderConfig(
          codec: VideoCodec.vp9,
          width: 320,
          height: 240,
          bitrateBps: 500_000,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          hwAccel: HwAccelPreference.forbidden,
        );

        final enc = await backend.createEncoder(config);
        expect(enc, isNotNull, reason: 'VP9 software encoder must succeed.');
        expect(
          enc,
          isA<IsolateSoftwareEncoder>(),
          reason:
              'hwAccel=forbidden must return the software encoder path — '
              'hosted on a worker isolate by default so libav encode never '
              'blocks the calling isolate.',
        );
        enc?.close();
      },
    );

    test('hwAccel=preferred returns a non-null encoder for VP9 '
        '(SW-only codec — falls to software path)', () async {
      if (!tryLoadFFmpeg()) {
        markTestSkipped('FFmpeg shared libraries not available');
        return;
      }

      // vp9 is in _swEncode but NOT in _hwEncode, so the "no HW encoder
      // available" branch fires and falls through to software.
      const config = EncoderConfig(
        codec: VideoCodec.vp9,
        width: 320,
        height: 240,
        bitrateBps: 500_000,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        hwAccel: HwAccelPreference.preferred,
      );

      final enc = await backend.createEncoder(config);
      expect(
        enc,
        isNotNull,
        reason:
            'hwAccel=preferred with a SW-only codec must fall back to '
            'software. This path emits the "no HW encoder available" log '
            'line followed by "software encoder opened".',
      );
      enc?.close();
    });
  });

  // -------------------------------------------------------------------------
  // 3. D3D11 zero-copy branch does NOT fire when d3d11DeviceHandle == 0.
  // -------------------------------------------------------------------------
  group('createEncoder — D3D11 zero-copy branch', () {
    test('Windows: preferZeroCopy=true + d3d11DeviceHandle=0 does NOT open '
        'zero-copy encoder (handle must be non-zero)', () async {
      if (!Platform.isWindows) {
        markTestSkipped('D3D11 zero-copy path is Windows-only');
        return;
      }
      if (!tryLoadFFmpeg()) {
        markTestSkipped('FFmpeg shared libraries not available');
        return;
      }

      // d3d11DeviceHandle = 0 → ctxZeroCopy condition is false.
      // The path must fall through to Stage A / software.
      const config = EncoderConfig(
        codec: VideoCodec.hevc,
        width: 1280,
        height: 720,
        bitrateBps: 2_000_000,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        hwAccel: HwAccelPreference.preferred,
      );
      const ctx = BackendContext(
        preferZeroCopy: true,
        d3d11DeviceHandle: 0, // zero → zero-copy condition false
      );

      // Should succeed (preferred falls back) — returns Stage A or SW.
      final enc = await backend.createEncoder(config, context: ctx);
      // Don't assert the type: NVENC may or may not be present.
      // The key invariant: createEncoder must not throw, and it must not
      // return a FfmpegD3d11HwEncoder opened with a null device
      // (that would cause a crash on first frame).
      expect(
        enc,
        isNot(isA<FfmpegD3d11HwEncoder>()),
        reason:
            'd3d11DeviceHandle=0 must NOT produce a D3D11 zero-copy encoder.',
      );
      enc?.close();
    });
  });

  // -------------------------------------------------------------------------
  // 4. supportsEncode gate prevents unsupported codecs.
  // -------------------------------------------------------------------------
  group('FfmpegBackend.supportsEncode', () {
    test('returns true for VP9 (software)', () {
      expect(backend.supportsEncode(VideoCodec.vp9), isTrue);
    });

    test('returns true for h264 and hevc', () {
      expect(backend.supportsEncode(VideoCodec.h264), isTrue);
      expect(backend.supportsEncode(VideoCodec.hevc), isTrue);
    });

    test('hwAccel=true returns true only for h264/hevc/av1', () {
      // These are the _hwEncode set.
      expect(backend.supportsEncode(VideoCodec.h264, hwAccel: true), isTrue);
      expect(backend.supportsEncode(VideoCodec.hevc, hwAccel: true), isTrue);
      expect(backend.supportsEncode(VideoCodec.av1, hwAccel: true), isTrue);
      // vp9 is SW only.
      expect(backend.supportsEncode(VideoCodec.vp9, hwAccel: true), isFalse);
    });
  });
}
