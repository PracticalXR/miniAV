@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

/// Extract the display-dims region from a CODED-dims (superblock-aligned)
/// planar YUV420 buffer. The pipeline's [MinigpuAv1Pipeline.lastYuv420] is the
/// coded buffer (e.g. 64x32 display -> 64x64 coded, edge-extended); the CPU
/// reference is computed at display dims, so comparisons slice the real region.
Float32List depadYuv420(
    Float32List coded, int codedW, int codedH, int w, int h) {
  final uw = w ~/ 2, uh = h ~/ 2;
  final cuw = codedW ~/ 2, cuh = codedH ~/ 2;
  final out = Float32List(w * h + 2 * uw * uh);
  var o = 0;
  for (var y = 0; y < h; y++) {
    out.setRange(o, o + w, coded, y * codedW);
    o += w;
  }
  final uOff = codedW * codedH;
  for (var y = 0; y < uh; y++) {
    out.setRange(o, o + uw, coded, uOff + y * cuw);
    o += uw;
  }
  final vOff = uOff + cuw * cuh;
  for (var y = 0; y < uh; y++) {
    out.setRange(o, o + uw, coded, vOff + y * cuw);
    o += uw;
  }
  return out;
}

void main() {
  group('AV1 Phase 1a — BGRA→YUV420 GPU stage', () {
    final backend = MinigpuBackend();

    test('GPU YUV420 matches CPU reference on a colour gradient', () async {
      const w = 64;
      const h = 32;

      // Build a deterministic gradient + a few synthetic colour blobs.
      final rgba = Float32List(w * h * 4);
      final rng = math.Random(0xA51);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          // Gradient base
          rgba[i + 0] = (x * 255 / (w - 1));
          rgba[i + 1] = (y * 255 / (h - 1));
          rgba[i + 2] = ((x + y) * 255 / (w + h - 2));
          // Sprinkle some noise so chroma decimation actually exercises
          // averaging of differing pixels.
          rgba[i + 0] += (rng.nextDouble() - 0.5) * 8;
          rgba[i + 1] += (rng.nextDouble() - 0.5) * 8;
          rgba[i + 2] += (rng.nextDouble() - 0.5) * 8;
          rgba[i + 3] = 255;
        }
      }
      // Pack a few pure-colour cells.
      void cell(int cx, int cy, double r, double g, double b) {
        for (var dy = 0; dy < 2; dy++) {
          for (var dx = 0; dx < 2; dx++) {
            final i = ((cy + dy) * w + cx + dx) * 4;
            rgba[i + 0] = r;
            rgba[i + 1] = g;
            rgba[i + 2] = b;
            rgba[i + 3] = 255;
          }
        }
      }

      cell(0, 0, 255, 0, 0);
      cell(10, 10, 0, 255, 0);
      cell(20, 20, 0, 0, 255);
      cell(40, 28, 255, 255, 255);
      cell(50, 4, 16, 16, 16);

      // CPU reference.
      final refYuv = rgbaToYuv420Bt709LimitedCpu(
        rgba: rgba,
        width: w,
        height: h,
      );

      // GPU path (run the full encoder so the YUV stage actually executes,
      // then read back the captured intermediate buffer).
      final cfg = EncoderConfig(
        codec: VideoCodec.av1,
        width: w,
        height: h,
        bitrateBps: 0,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        inputPixelFormat: MiniAVPixelFormat.rgba32,
      );
      final encoder = await backend.createEncoder(cfg);
      expect(encoder, isNotNull);
      MinigpuAv1Pipeline? pipelineRef;
      // Pull the underlying pipeline out of the encoder for introspection.
      // The GpuCodecEncoder stores the pipeline as the only field that
      // matters here; we get to it via createEncoder's known type.
      final gpuEncoder = encoder as GpuCodecEncoder;
      pipelineRef = gpuEncoder.pipeline as MinigpuAv1Pipeline;

      try {
        // Pack rgba floats as raw RGBA bytes for the frame source. The
        // existing GpuCodecEncoder path wants a Uint8List from CpuFrameSource;
        // we round-and-clamp.
        final bytes = Uint8List(rgba.length);
        for (var i = 0; i < rgba.length; i++) {
          final v = rgba[i];
          final r = v <= 0 ? 0 : (v >= 255 ? 255 : v.round());
          bytes[i] = r;
        }
        final pkt = await encoder.encode(
          CpuFrameSource(
            bytes: bytes,
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: w,
            height: h,
            timestampUs: 0,
          ),
        );
        expect(pkt, isNotNull);
      } finally {
        await encoder.close();
      }

      final codedYuv = pipelineRef.lastYuv420;
      expect(codedYuv, isNotNull, reason: 'pipeline must capture YUV buffer');
      // The capture is CODED dims (64-aligned superblocks, edge-extended):
      // 64x32 display -> 64x64 coded -> 6144 floats.
      final cw = pipelineRef.codedWidth, chh = pipelineRef.codedHeight;
      expect(codedYuv!.length, cw * chh + 2 * (cw ~/ 2) * (chh ~/ 2));
      final gpuYuv = depadYuv420(codedYuv, cw, chh, w, h);
      expect(gpuYuv.length, refYuv.length);

      // The CPU reference uses doubles, the GPU shader uses 32-bit floats —
      // expect mostly-exact agreement but allow tiny rounding slop.
      var maxDelta = 0.0;
      var sumSqDelta = 0.0;
      for (var i = 0; i < refYuv.length; i++) {
        final d = (gpuYuv[i] - refYuv[i]).abs();
        if (d > maxDelta) maxDelta = d;
        sumSqDelta += d * d;
      }
      // The rgba input we send to the GPU is byte-quantised (round-and-clamp
      // for the CpuFrameSource), so the float source ≠ the byte source. The
      // CPU reference was computed from the float source. Allow a bit of
      // slack for that quantisation (≤1 LSB) + float ops (≤ ~0.5).
      expect(
        maxDelta,
        lessThanOrEqualTo(2.5),
        reason: 'max per-sample delta too large',
      );
      final rms = math.sqrt(sumSqDelta / refYuv.length);
      expect(rms, lessThan(0.5));
    });

    test('Pure-grey input produces Y=126, Cb=128, Cr=128', () async {
      // Mid-grey 128/128/128 RGBA -> Y' = 16 + (219/255)*128 ≈ 125.96.
      const w = 16;
      const h = 16;
      final cfg = EncoderConfig(
        codec: VideoCodec.av1,
        width: w,
        height: h,
        bitrateBps: 0,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        inputPixelFormat: MiniAVPixelFormat.rgba32,
      );
      final encoder = (await backend.createEncoder(cfg))! as GpuCodecEncoder;
      final pipeline = encoder.pipeline as MinigpuAv1Pipeline;
      final bytes = Uint8List(w * h * 4);
      for (var i = 0; i < bytes.length; i += 4) {
        bytes[i + 0] = 128;
        bytes[i + 1] = 128;
        bytes[i + 2] = 128;
        bytes[i + 3] = 255;
      }
      try {
        await encoder.encode(
          CpuFrameSource(
            bytes: bytes,
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: w,
            height: h,
            timestampUs: 0,
          ),
        );
      } finally {
        await encoder.close();
      }
      final yuv = pipeline.lastYuv420!;
      final layout = pipeline.yuv420Layout;
      // All Y entries equal.
      for (var i = 0; i < layout.ySize; i++) {
        expect(yuv[i], closeTo(125.96, 0.05), reason: 'Y[$i]');
      }
      for (var i = 0; i < layout.uvSize; i++) {
        expect(yuv[layout.uOffset + i], closeTo(128.0, 0.05));
        expect(yuv[layout.vOffset + i], closeTo(128.0, 0.05));
      }
    });
  });
}
