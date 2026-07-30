/// M2 proof: MF hardware H.264 decode → D3D11 NV12 shared handle → minigpu
/// Dawn import (`importVideoFrame`) → `toRGBA()` GPU compute pass → RGBA
/// readback, with ZERO CPU readback of the decoded planes.
///
/// This is the technical crux of the zero-copy present path: it proves the
/// MF decoder's shared NV12 texture can be imported into Dawn and converted to
/// RGBA entirely on the GPU. The player-side wiring (worker-isolate host +
/// SharedOutputTexture present) builds on this.
///
/// Skips cleanly off Windows / without FFmpeg / without a hardware decoder MFT
/// / without a working Dawn D3D11 import.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:minigpu/minigpu.dart';
// Platform types + the FFmpeg-free MF decode backend come from codecs.
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_codecs/src/codecs_native.dart' show mfdecHasHardware;
// FFmpeg is used only to ENCODE the H.264 test packets (a packet source).
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show FfmpegBackend, ensureFFmpegLoaded;
import 'package:test/test.dart';

const int kW = 320;
const int kH = 240;
const int kFps = 30;

Uint8List _testCardRgba(int frame) {
  final out = Uint8List(kW * kH * 4);
  final bx = (frame * 5) % (kW - 48);
  final by = (frame * 3) % (kH - 48);
  for (var y = 0; y < kH; y++) {
    for (var x = 0; x < kW; x++) {
      final i = (y * kW + x) * 4;
      final inBlock = x >= bx && x < bx + 48 && y >= by && y < by + 48;
      out[i] = inBlock ? 255 : (x + frame * 3) % 256;
      out[i + 1] = inBlock ? 255 : (y + frame) % 256;
      out[i + 2] = inBlock ? 255 : 128;
      out[i + 3] = 255;
    }
  }
  return out;
}

Future<(List<EncodedPacket>, Uint8List?)> _encodeClip(int frames) async {
  final enc = await FfmpegBackend().createEncoder(
    const EncoderConfig(
      codec: VideoCodec.h264,
      width: kW,
      height: kH,
      bitrateBps: 1500000,
      gopLength: kFps,
      frameRateNumerator: kFps,
      frameRateDenominator: 1,
      hwAccel: HwAccelPreference.forbidden,
      backendOptions: {'sw_isolate': '0'},
    ),
  );
  final packets = <EncodedPacket>[];
  for (var i = 0; i < frames; i++) {
    final pkt = await enc!.encode(
      FrameSource.cpu(
        bytes: _testCardRgba(i),
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: kW,
        height: kH,
        timestampUs: (i * 1000000) ~/ kFps,
      ),
    );
    if (pkt != null) packets.add(pkt);
  }
  packets.addAll(await enc!.flush());
  final asc = enc.extraData?.bytes;
  await enc.close();
  return (packets, asc);
}

void main() {
  group('MF decode → Dawn import → toRGBA (zero-copy)', () {
    late Minigpu gpu;
    var haveHw = false;
    var dawnImportSupported = false;

    setUpAll(() async {
      if (!Platform.isWindows) return;
      Minigpu.preferDisplayAdapter();
      gpu = Minigpu();
      await gpu.init();
      dawnImportSupported = gpu.isExternalContentTypeSupported(
            ExternalContentType.d3d11SharedHandle,
          ) &&
          gpu.isExternalPixelFormatSupported(ExternalPixelFormat.nv12);
      await ensureFFmpegLoaded(); // encode side only
      try {
        haveHw = mfdecHasHardware(0);
      } catch (_) {
        haveHw = false;
      }
      // ignore: avoid_print
      print('MF-GPU-DIAG: hasHardware=$haveHw dawnImport=$dawnImportSupported');
    });

    tearDownAll(() async {
      if (!Platform.isWindows) return;
      gpu.destroyAllTrackedShaders();
      await gpu.destroy();
    });

    test('decoded NV12 texture imports into Dawn and converts to RGBA on GPU',
        () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows only');
        return;
      }
      if (!haveHw) {
        markTestSkipped('no hardware H.264 decoder MFT');
        return;
      }
      if (!dawnImportSupported) {
        markTestSkipped('Dawn D3D11 shared-handle / NV12 import unsupported');
        return;
      }

      final (packets, asc) = await _encodeClip(45);
      // Worker-isolate path (the realistic player path): the decoder runs on a
      // worker, and the NV12 shared handle is relayed here for a cross-isolate,
      // cross-device (worker device → main Dawn, same adapter) import.
      final dec = await MfDecodeBackend().createDecoder(
        DecoderConfig(codec: VideoCodec.h264, extraData: asc),
      );
      expect(dec, isNotNull);

      DecodedFrame? frame;
      for (final p in packets) {
        frame = await dec!.decode(p);
        if (frame != null) break;
      }
      frame ??= (await dec!.flush()).firstOrNull;
      expect(frame, isNotNull, reason: 'decoder produced no frame');
      expect(frame!.outputKind, FrameSourceKind.d3d11Texture);
      expect(frame.gpuHandle, isNot(0));

      // Diagnostic: CPU readback of the SAME frame (NV12→I420) to confirm the
      // decoded content is real (wide luma range), isolating decode-content
      // issues from GPU-import/sync issues.
      final cpuI420 = await frame.readBytes();
      var cpuMin = 255, cpuMax = 0;
      for (var i = 0; i < frame.width * frame.height; i++) {
        final y = cpuI420[i];
        if (y < cpuMin) cpuMin = y;
        if (y > cpuMax) cpuMax = y;
      }
      // ignore: avoid_print
      print('MF-GPU-DIAG: CPU-I420 Y range $cpuMin..$cpuMax');

      // Import the shared NV12 D3D11 texture into Dawn and convert to RGBA on
      // the GPU — no CPU readback of the decoded planes.
      final vtex = gpu.importVideoFrame(
        ExternalVideoBuffer(
          contentType: ExternalContentType.d3d11SharedHandle,
          pixelFormat: ExternalPixelFormat.nv12,
          width: frame.width,
          height: frame.height,
          planes: [
            ExternalPlane(
              dataPtr: frame.gpuHandle,
              width: frame.width,
              height: frame.height,
              strideBytes: 0,
            ),
          ],
        ),
      );
      expect(vtex, isNotNull, reason: 'Dawn importVideoFrame returned null');

      final rgbaBuf = vtex!.toRGBA();
      final rgba = Uint8List(frame.width * frame.height * 4);
      await rgbaBuf.read(rgba, rgba.length, dataType: BufferDataType.uint8);

      // The test card is a bright, varied image — the GPU-converted RGBA must
      // be non-degenerate (not all-black, not a single flat colour).
      var minLuma = 255, maxLuma = 0, nonBlack = 0;
      for (var i = 0; i < frame.width * frame.height; i++) {
        final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
        final luma = (r + g + b) ~/ 3;
        if (luma < minLuma) minLuma = luma;
        if (luma > maxLuma) maxLuma = luma;
        if (luma > 16) nonBlack++;
      }
      expect(nonBlack, greaterThan(frame.width * frame.height ~/ 4),
          reason: 'GPU-converted image is mostly black — import/convert failed');
      expect(maxLuma - minLuma, greaterThan(40),
          reason: 'GPU-converted image has no contrast — import likely garbage');

      rgbaBuf.destroy();
      vtex.destroy();
      frame.close();
      await dec!.close();
    });
  });
}
