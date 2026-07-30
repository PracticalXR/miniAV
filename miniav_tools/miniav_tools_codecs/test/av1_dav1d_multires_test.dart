@TestOn('vm')
library;

/// Multi-resolution dav1d round-trip: confirms the encoder produces a
/// bitstream that decodes cleanly at sizes well beyond the 64×64 dev
/// resolution, and that the decoded Y mean / range tracks the gradient
/// source.
///
/// Skipped automatically when `ffmpeg` is not on PATH.

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:minigpu/minigpu.dart' show Minigpu;
import 'package:test/test.dart';

bool _hasFfmpeg() {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

Uint8List _gradient(int w, int h, int frameIdx) {
  final buf = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      buf[o + 0] = ((x * 200) ~/ (w - 1)) & 0xff;
      buf[o + 1] = ((y * 200) ~/ (h - 1)) & 0xff;
      buf[o + 2] = ((x + y + frameIdx * 8) & 0x7f);
      buf[o + 3] = 255;
    }
  }
  return buf;
}

class _Stats {
  final double mean, min, max, stddev;
  _Stats(this.mean, this.min, this.max, this.stddev);
}

_Stats _planeStats(Uint8List bytes, int base, int len) {
  var sum = 0;
  var minV = 255, maxV = 0;
  for (var k = 0; k < len; k++) {
    final v = bytes[base + k];
    sum += v;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
  }
  final mean = sum / len;
  double sq = 0;
  for (var k = 0; k < len; k++) {
    final d = bytes[base + k] - mean;
    sq += d * d;
  }
  return _Stats(
    mean,
    minV.toDouble(),
    maxV.toDouble(),
    (sq / len).abs().clamp(0.0, double.infinity),
  );
}

Future<void> _roundtrip(int w, int h, {int frames = 3}) async {
  final tmp = await Directory.systemTemp.createTemp('av1_mr_');
  final mp4 = File('${tmp.path}/out.mp4');
  final dec = File('${tmp.path}/dec.yuv');
  try {
    final backend = MinigpuBackend();
    final enc = await backend.createEncoder(
      EncoderConfig(
        codec: VideoCodec.av1,
        width: w,
        height: h,
        bitrateBps: 0,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        inputPixelFormat: MiniAVPixelFormat.rgba32,
      ),
    );
    expect(enc, isNotNull, reason: 'no encoder for ${w}x$h');

    final pkts = <EncodedPacket>[];
    for (var i = 0; i < frames; i++) {
      final p = await enc!.encode(
        CpuFrameSource(
          bytes: _gradient(w, h, i),
          pixelFormat: MiniAVPixelFormat.rgba32,
          width: w,
          height: h,
          timestampUs: i * 33333,
        ),
      );
      if (p != null) pkts.add(p);
    }
    expect(
      pkts.length,
      frames,
      reason: '${w}x$h: every frame must produce a pkt',
    );

    final mux = await backend.createMuxer(
      MuxerConfig(
        container: Container.mp4,
        output: MuxerOutput.file(mp4.path),
        tracks: [
          VideoTrackInfo(
            codec: VideoCodec.av1,
            width: w,
            height: h,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            extraData: enc!.extraData,
          ),
        ],
      ),
    );
    await mux!.writeHeader();
    for (final p in pkts) {
      await mux.writePacket(p);
    }
    await mux.finish();
    await mux.close();
    await enc.close();

    final r = Process.runSync('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      mp4.path,
      '-pix_fmt',
      'yuv420p',
      '-y',
      dec.path,
    ]);
    expect(
      r.stderr.toString(),
      isEmpty,
      reason: '${w}x$h: ffmpeg decode produced errors',
    );
    expect(r.exitCode, 0);

    final bytes = dec.readAsBytesSync();
    // AV1 frame_size_override embeds true dims in the bitstream; dav1d
    // outputs exactly w×h (no padded rows/cols). YUV420 3/2 bytes/pixel.
    final perFrame = w * h * 3 ~/ 2;
    expect(
      bytes.length,
      frames * perFrame,
      reason: '${w}x$h: wrong decoded size',
    );

    // Source gradient (r,g) sweep 0..200, b modulates 0..127 per frame.
    // BT.709 limited-range luma is roughly:
    //   Y ≈ 16 + 0.183*R + 0.614*G + 0.062*B
    //   for r=g=x*200/(w-1), b in [0..127], spatial mean R ≈ G ≈ 100.
    //   → expected Y mean ≈ 16 + 0.183*100 + 0.614*100 + 0.062*~64
    //                     ≈ 16 + 18.3 + 61.4 + 4 ≈ 99.7
    // We allow ±8 to absorb DC-only-quantisation rounding at all sizes.
    for (var f = 0; f < frames; f++) {
      final yStats = _planeStats(bytes, f * perFrame, w * h);
      expect(
        yStats.mean,
        inInclusiveRange(91.0, 109.0),
        reason: '${w}x$h frame $f: Y mean out of range: ${yStats.mean}',
      );
      // Gradient must reach a reasonable spread — flat output would mean
      // we lost spatial detail.
      expect(
        yStats.max - yStats.min,
        greaterThan(40),
        reason:
            '${w}x$h frame $f: Y range too narrow '
            '(${yStats.min}..${yStats.max})',
      );
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  final hasFfmpeg = _hasFfmpeg();

  group('AV1 dav1d multi-resolution round-trip', () {
    setUpAll(() {
      Minigpu.setLogCallback(null, level: 3);
    });

    for (final dims in const [
      [128, 128],
      [256, 256],
      [512, 512],
      [1024, 1024],
    ]) {
      test(
        '${dims[0]}x${dims[1]} decodes cleanly',
        () async {
          if (!hasFfmpeg) {
            markTestSkipped('ffmpeg not on PATH');
            return;
          }
          await _roundtrip(dims[0], dims[1]);
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    }

    test('1920x1088 decodes cleanly', () async {
      if (!hasFfmpeg) {
        markTestSkipped('ffmpeg not on PATH');
        return;
      }
      await _roundtrip(1920, 1088, frames: 2);
    }, timeout: const Timeout(Duration(seconds: 180)));

    // Real-world camera/screen resolutions (NOT multiples of 64). The
    // encoder pads to the next superblock boundary internally and signals
    // the true display dims via AV1 render_size; the decoder crops back.
    for (final dims in const [
      [640, 480], // VGA
      [1280, 720], // 720p
      [1920, 1080], // 1080p
    ]) {
      test(
        '${dims[0]}x${dims[1]} (non-mult-64) decodes cleanly',
        () async {
          if (!hasFfmpeg) {
            markTestSkipped('ffmpeg not on PATH');
            return;
          }
          await _roundtrip(dims[0], dims[1], frames: 2);
        },
        timeout: const Timeout(Duration(seconds: 180)),
      );
    }
  });
}
