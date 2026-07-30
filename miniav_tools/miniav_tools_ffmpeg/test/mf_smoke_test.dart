/// MediaFoundation (`h264_mf` / `hevc_mf`) smoke + fallback-viability test.
///
/// Context: the package now downloads the **LGPL** FFmpeg build, which omits
/// the GPL software encoders libx264/libx265. That removes the CPU-side
/// H.264/HEVC fallback, leaving MediaFoundation as the only universal
/// H.264/HEVC path on Windows when no vendor SDK (NVENC/QSV/AMF) is present.
///
/// These tests verify whether MF can actually carry that role:
///
///   1. `h264_mf` is registered in the loaded build (cheap name lookup).
///   2. MF encodes H.264 via its **software** MFT (`hw_encoding=0`) — this is
///      the real CPU-fallback path and the one that MUST work for the LGPL
///      switch to leave us with a usable fallback. If this fails on a normal
///      Windows box, that is the signal to wire up libopenh264 instead.
///   3. MF encodes H.264 with the package default (`hw_encoding=1`, hardware
///      MFT) — informational; only succeeds where a HW MFT exists, which is
///      precisely where MF would never be reached in normal probe order.
///   4. `hevc_mf` software path — informational.
///
/// MF is Windows-only; the whole suite is skipped elsewhere. It also skips
/// cleanly when FFmpeg could not be loaded (offline CI).
@TestOn('vm && windows')
library;

import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('MediaFoundation h264_mf', () {
    var ffmpegReady = false;

    setUpAll(() async {
      ffmpegReady = await ensureFFmpegLoaded();
      // QSV/MF need an MTA thread on Windows; the real app elevates via the
      // native shim. Mirror that here so a COM-apartment quirk doesn't get
      // misread as "MF is broken". No-op when the shim asset isn't built.
      final shim = FfmpegShim.tryLoad();
      // ignore: avoid_print
      print('FfmpegShim available for ensureMta: ${shim != null}');
      shim?.ensureMta();
    });

    test('h264_mf is registered in the loaded (LGPL) FFmpeg build', () {
      if (!ffmpegReady) {
        print('SKIP: FFmpeg not available (offline?)');
        return;
      }
      final vendors = ffmpegHwVendorsAvailable();
      print('HW vendors detected: $vendors');
      expect(
        vendors,
        contains(HwEncoderVendor.mediafoundation),
        reason:
            'h264_mf must be compiled into the build — it is the universal '
            'Windows H.264 fallback once libx264 is gone (LGPL build).',
      );
    });

    test(
      'h264_mf SOFTWARE MFT (hw_encoding=0) encodes 1280x720 H.264 — '
      'the real CPU fallback path',
      () async {
        if (!ffmpegReady) {
          print('SKIP: FFmpeg not available');
          return;
        }
        if (!ffmpegHwVendorsAvailable().contains(
          HwEncoderVendor.mediafoundation,
        )) {
          print('SKIP: h264_mf not present in this build');
          return;
        }

        const w = 1280, h = 720;
        final rgba = _gradient(w, h);

        FfmpegHwEncoder enc;
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: w,
              height: h,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.preferred,
              rateControl: RateControl.vbr,
              // Allow the Media Foundation *software* H.264 MFT so this works
              // on machines with no hardware encoder — overrides the spec
              // default of hw_encoding=1.
              backendOptions: {'hw_encoding': '0'},
            ),
            HwEncoderVendor.mediafoundation,
          );
        } on CodecInitException catch (e) {
          fail(
            'h264_mf software MFT failed to OPEN — MF cannot serve as the '
            'CPU H.264 fallback on this machine. This is the trigger to add '
            'libopenh264. Error: ${e.message}',
          );
        }

        try {
          final (packets, bytes) = await _drive(enc, rgba, w, h, 30);
          print('h264_mf (sw MFT): $packets packets, $bytes bytes');
          expect(
            packets,
            greaterThan(0),
            reason:
                'h264_mf opened but produced no packets — not a usable '
                'fallback. Trigger to add libopenh264.',
          );
          expect(bytes, greaterThan(0));
        } finally {
          await enc.close();
        }
      },
    );

    test(
      'h264_mf with the package-DEFAULT spec encodes (no forced hardware)',
      () async {
        if (!ffmpegReady) {
          print('SKIP: FFmpeg not available');
          return;
        }
        if (!ffmpegHwVendorsAvailable().contains(
          HwEncoderVendor.mediafoundation,
        )) {
          print('SKIP: h264_mf not present');
          return;
        }

        const w = 1280, h = 720;
        final rgba = _gradient(w, h);

        // No backendOptions: exercises the _hwSpecs default for MF, which must
        // NOT force hw_encoding=1 (regression guard). With auto-select MF uses
        // a HW MFT when present and the software MFT otherwise — so this must
        // produce packets on any Windows machine, with or without a GPU.
        FfmpegHwEncoder enc;
        try {
          enc = FfmpegHwEncoder.openWith(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: w,
              height: h,
              bitrateBps: 2_000_000,
              frameRateNumerator: 30,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.preferred,
              rateControl: RateControl.vbr,
            ),
            HwEncoderVendor.mediafoundation,
          );
        } on CodecInitException catch (e) {
          fail(
            'h264_mf failed to open with default options — the MF spec must '
            'not force hardware-only encoding. Error: ${e.message}',
          );
        }
        try {
          final (packets, bytes) = await _drive(enc, rgba, w, h, 30);
          print('h264_mf (default spec): $packets packets, $bytes bytes');
          expect(packets, greaterThan(0));
          expect(bytes, greaterThan(0));
        } finally {
          await enc.close();
        }
      },
    );

    // Informational: documents that there is NO reliable HEVC CPU fallback in
    // the LGPL build. The Store "HEVCVideoExtensionEncoder" software MFT
    // returns E_FAIL on input on typical machines; HEVC realistically needs a
    // hardware MFT. Tolerant of both open- and encode-time failure.
    test('hevc_mf software MFT — informational (no hard fallback for HEVC)', () async {
      if (!ffmpegReady) {
        print('SKIP: FFmpeg not available');
        return;
      }
      if (!ffmpegHwVendorsAvailable().contains(
        HwEncoderVendor.mediafoundation,
      )) {
        print('SKIP: MF not present');
        return;
      }

      const w = 1280, h = 720;
      final rgba = _gradient(w, h);
      try {
        final enc = FfmpegHwEncoder.openWith(
          const EncoderConfig(
            codec: VideoCodec.hevc,
            width: w,
            height: h,
            bitrateBps: 3_000_000,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            bFrameCount: 0,
            hwAccel: HwAccelPreference.preferred,
            rateControl: RateControl.vbr,
            backendOptions: {'hw_encoding': '0'},
          ),
          HwEncoderVendor.mediafoundation,
        );
        try {
          final (packets, bytes) = await _drive(enc, rgba, w, h, 20);
          print('hevc_mf (sw MFT): $packets packets, $bytes bytes');
        } finally {
          await enc.close();
        }
      } catch (e) {
        print('INFO: hevc_mf software MFT unusable (expected): $e');
      }
    });
  });
}

Uint8List _gradient(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final v = (y * 255 ~/ (h - 1)) & 0xff;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = v;
      rgba[i + 1] = (x * 255 ~/ (w - 1)) & 0xff;
      rgba[i + 2] = 255 - v;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<(int, int)> _drive(
  FfmpegHwEncoder enc,
  Uint8List rgba,
  int w,
  int h,
  int n,
) async {
  var packets = 0;
  var bytes = 0;
  for (var i = 0; i < n; i++) {
    final pkt = await enc.encode(
      FrameSource.cpu(
        bytes: rgba,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: w,
        height: h,
        timestampUs: i * 33333,
      ),
    );
    if (pkt != null) {
      packets++;
      bytes += pkt.data.length;
    }
  }
  for (final p in await enc.flush()) {
    packets++;
    bytes += p.data.length;
  }
  return (packets, bytes);
}
