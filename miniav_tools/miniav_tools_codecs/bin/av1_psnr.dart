// Dev helper: compute PSNR between the encoder's source YUV (regenerated
// from the same RGBA gradient used by dump_av1_mp4.dart) and a decoded
// YUV420p raw file (e.g. produced by `ffmpeg -i out.mp4 ... o.yuv`).
//
// Usage:  dart run bin/av1_psnr.dart <decoded.yuv> [width] [height]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';

void main(List<String> argv) {
  if (argv.isEmpty) {
    stderr.writeln('usage: av1_psnr.dart <decoded.yuv> [w] [h]');
    exit(2);
  }
  final path = argv[0];
  final w = argv.length >= 2 ? int.parse(argv[1]) : 64;
  final h = argv.length >= 3 ? int.parse(argv[2]) : 64;

  // Regenerate frame 0's RGBA pattern exactly as in dump_av1_mp4.dart.
  final rgba = Float32List(w * h * 4);
  int clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
  var rngState = 0x2545F491 ^ 0;
  int rnd() {
    rngState ^= (rngState << 13) & 0xFFFFFFFF;
    rngState ^= rngState >> 17;
    rngState ^= (rngState << 5) & 0xFFFFFFFF;
    return rngState & 0xFF;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final cb = ((x ^ y) & 1) == 0 ? 220 : 20;
      rgba[o + 0] = clamp(cb + rnd() - 128).toDouble();
      rgba[o + 1] = clamp(rnd()).toDouble();
      rgba[o + 2] = clamp((x * 4) ^ (y * 4) ^ rnd()).toDouble();
      rgba[o + 3] = 255;
    }
  }

  final srcF = rgbaToYuv420Bt709LimitedCpu(rgba: rgba, width: w, height: h);
  // Pack the float reference into a Uint8 YUV420p buffer (Y then U then V).
  final ySize = w * h;
  final cSize = (w >> 1) * (h >> 1);
  final src = Uint8List(ySize + 2 * cSize);
  int u8(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  for (var i = 0; i < ySize; i++) {
    src[i] = u8(srcF[i]);
  }
  for (var i = 0; i < cSize; i++) {
    src[ySize + i] = u8(srcF[ySize + i]);
    src[ySize + cSize + i] = u8(srcF[ySize + cSize + i]);
  }

  final dec = File(path).readAsBytesSync();
  if (dec.length != src.length) {
    stderr.writeln('size mismatch: decoded ${dec.length} vs src ${src.length}');
    exit(3);
  }

  double mse(int off, int n) {
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final d = src[off + i] - dec[off + i];
      sum += d * d;
    }
    return sum / n;
  }

  double psnr(double m) =>
      m == 0 ? double.infinity : 10 * (log(255 * 255 / m) / ln10);

  final mY = mse(0, ySize);
  final mU = mse(ySize, cSize);
  final mV = mse(ySize + cSize, cSize);
  final mAll = (mY * ySize + mU * cSize + mV * cSize) / (ySize + 2 * cSize);

  stdout.writeln(
    'PSNR-Y  : ${psnr(mY).toStringAsFixed(2)} dB (MSE ${mY.toStringAsFixed(3)})',
  );
  stdout.writeln(
    'PSNR-U  : ${psnr(mU).toStringAsFixed(2)} dB (MSE ${mU.toStringAsFixed(3)})',
  );
  stdout.writeln(
    'PSNR-V  : ${psnr(mV).toStringAsFixed(2)} dB (MSE ${mV.toStringAsFixed(3)})',
  );
  stdout.writeln(
    'PSNR-all: ${psnr(mAll).toStringAsFixed(2)} dB (MSE ${mAll.toStringAsFixed(3)})',
  );
}
