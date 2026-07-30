/// Proves the Windows packet path — Media Foundation **hardware** H.264/HEVC
/// video + **libopus** audio — is genuinely FFmpeg-free.
///
/// Three independent lines of evidence back the claim:
///
///   1. **Link-time (out of band):** `dumpbin /imports
///      miniav_tools_codecs_native.dll` shows ZERO `avcodec` / `avutil` /
///      `avformat` imports — the DLL that links both decoders (opus_decode.c +
///      mf_decoder.c + static libopus) pulls no FFmpeg. The FFmpeg shim DLL, by
///      contrast, does import `avcodec-62` etc. (it is the fallback).
///
///   2. **Selection with FFmpeg EXCLUDED (this file):** with all three player
///      backends registered (MF + Opus + FFmpeg — the real player config), the
///      negotiator is asked to decode Opus audio and H.264 video with
///      `BackendPreference.excluded({'ffmpeg'})`. Both still open — via `opus`
///      and `mf_decode` (→ `mediaFoundation`, D3D11 zero-copy) — so the path
///      needs no FFmpeg in the process. This is order-independent: it does not
///      depend on FFmpeg being absent from the global registry.
///
///   3. **Default preference (this file):** even with FFmpeg available, the
///      negotiator *prefers* the FFmpeg-free backends (Opus priority 60 > FFmpeg
///      50; the MF hardware capability out-ranks FFmpeg's software one).
///
/// Together: the H.264/HEVC-video + Opus-audio packet-streaming player runs with
/// zero FFmpeg on Windows; FFmpeg remains only the fallback for other
/// codecs/containers.
@TestOn('vm')
library;

import 'dart:io';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerMfDecodeBackend, registerOpusBackend;
// Same-package src import (as mf_gpu_import_test.dart) — the HW capability probe.
import 'package:miniav_tools_codecs/src/codecs_native.dart' show mfdecHasHardware;
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show registerFfmpegBackend;
import 'package:test/test.dart';

/// H.264 (codec index 0) hardware decode present on this host?
bool _haveMfHw() {
  try {
    return mfdecHasHardware(0);
  } catch (_) {
    return false;
  }
}

void main() {
  // Register EXACTLY what miniav_player's backend_register_native.dart registers
  // — the real, shipping player configuration. FFmpeg IS present; the point is
  // that the FFmpeg-free path is both selected by default and works when FFmpeg
  // is explicitly excluded.
  setUpAll(() {
    registerMfDecodeBackend(); // FFmpeg-free HW video (Windows)
    registerOpusBackend(); //     FFmpeg-free Opus audio
    registerFfmpegBackend(); //   software floor + fallback
  });

  group('Opus audio is FFmpeg-free', () {
    test('opens with FFmpeg EXCLUDED from the negotiation', () async {
      final dec = await MiniAVTools.createAudioDecoder(
        const AudioDecoderConfig(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
        ),
        preference: BackendPreference.excluded({'ffmpeg'}),
      );
      expect(
        dec.backendName,
        'opus',
        reason: 'Opus must decode with no FFmpeg backend available',
      );
      await dec.close();
    });

    test('is preferred over FFmpeg by default (priority 60 > 50)', () async {
      final dec = await MiniAVTools.createAudioDecoder(
        const AudioDecoderConfig(
          codec: AudioCodec.opus,
          sampleRate: 48000,
          channels: 2,
        ),
      );
      expect(dec.backendName, 'opus');
      await dec.close();
    });
  });

  group('H.264 hardware video is FFmpeg-free', () {
    test('opens via Media Foundation with FFmpeg EXCLUDED (Windows + HW)',
        () async {
      if (!Platform.isWindows || !_haveMfHw()) {
        markTestSkipped('MF hardware H.264 decode not available on this host');
        return;
      }
      final dec = await MiniAVTools.createDecoder(
        const DecoderConfig(codec: VideoCodec.h264),
        preference: BackendPreference.excluded({'ffmpeg'}),
      );
      expect(
        dec.backendName,
        'mf_decode',
        reason: 'H.264 HW decode must open with no FFmpeg backend available',
      );
      expect(dec.capability?.hwPath, HwPath.mediaFoundation);
      expect(dec.capability?.isHardware, isTrue);
      expect(dec.capability?.zeroCopy, isTrue,
          reason: 'MF path keeps frames on the GPU (D3D11 NV12) end-to-end');
      expect(
        dec.capability?.producedOutputs,
        contains(FrameSourceKind.d3d11Texture),
      );
      await dec.close();
    });

    test('is preferred over FFmpeg software by default (Windows + HW)',
        () async {
      if (!Platform.isWindows || !_haveMfHw()) {
        markTestSkipped('MF hardware H.264 decode not available on this host');
        return;
      }
      final dec = await MiniAVTools.createDecoder(
        const DecoderConfig(codec: VideoCodec.h264),
      );
      expect(dec.backendName, 'mf_decode',
          reason: 'a HW capability out-ranks FFmpeg software decode');
      expect(dec.capability?.isHardware, isTrue);
      await dec.close();
    });
  });
}
