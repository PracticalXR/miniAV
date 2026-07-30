// Phase-2b (Approach C′) validation: a MIXED inter-residual frame.
//
// Frame 0 is a KEY frame of source S0 (a checkerboard). Frame 1 is an
// INTER_FRAME in which EVERY block is inter (single-ref LAST, GLOBALMV, MV=0)
// but the source S1 differs from S0 in a rectangular region. Unchanged blocks
// quantise to an all-zero residual and are coded skip=1 (the decoder copies
// the co-located reference). Changed blocks carry an inter DCT residual
// (source − co-located reference) coded skip=0.
//
// Because the decoded frame 1 is NOT equal to frame 0 (it contains the changed
// region), we validate against the ENCODER's own closed-loop reconstruction of
// frame 1: the bitstream is bit-exact iff ffmpeg/dav1d decodes frame 1 to the
// exact pixels the encoder reconstructed. This script decodes the MP4 with
// ffmpeg and asserts byte-equality on the cropped display region.
//
// Usage:  dart run bin/dump_av1_inter_residual.dart [out.mp4] [W] [H] [crf]
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
// ignore_for_file: implementation_imports
import 'package:miniav_tools_codecs/src/av1/av1_constants.dart';
import 'package:miniav_tools_codecs/src/av1/av1_frame_header.dart';
import 'package:miniav_tools_codecs/src/av1/av1_obu.dart';
import 'package:miniav_tools_codecs/src/av1/av1_residual_tile_group.dart'
    as residual;
import 'package:miniav_tools_codecs/src/av1/av1_sequence_header.dart';
import 'package:miniav_tools_codecs/src/av1/mp4/av1_mp4_muxer.dart'
    show buildAv1ConfigRecord;

Future<void> main(List<String> argv) async {
  final outPath = argv.isNotEmpty ? argv[0] : 'out.mp4';
  final w = argv.length >= 2 ? int.parse(argv[1]) : 64;
  final h = argv.length >= 3 ? int.parse(argv[2]) : 64;
  final crf = argv.length >= 4 ? int.parse(argv[3]) : 16;

  final codedW = ((w + 63) >> 6) << 6;
  final codedH = ((h + 63) >> 6) << 6;
  final baseQIdx = crf.clamp(1, 20);

  final sh = buildSequenceHeader(
    width: codedW,
    height: codedH,
    frameRateNumerator: 30,
    frameRateDenominator: 1,
  );
  final shObu = encodeObu(type: ObuType.sequenceHeader, payload: sh.payload);
  final av1c = buildAv1ConfigRecord(
    seqProfile: sh.seqProfile,
    seqLevelIdx0: sh.seqLevelIdx0,
    seqTier0: sh.seqTier0,
    highBitDepth: sh.highBitDepth,
    twelveBit: sh.twelveBit,
    monochrome: sh.monochrome,
    chromaSubsamplingX: sh.chromaSubsamplingX,
    chromaSubsamplingY: sh.chromaSubsamplingY,
    chromaSamplePosition: sh.chromaSamplePosition,
    sequenceHeaderObu: shObu,
  );
  final tdObu = encodeObu(
    type: ObuType.temporalDelimiter,
    payload: Uint8List(0),
  );

  Float32List makeRgba(bool changed) {
    final rgba = Float32List(codedW * codedH * 4);
    // Changed region: a centred rectangle (display coords) filled solid.
    final rx0 = (w ~/ 4).clamp(0, codedW);
    final ry0 = (h ~/ 4).clamp(0, codedH);
    final rx1 = (w * 3 ~/ 4).clamp(0, codedW);
    final ry1 = (h * 3 ~/ 4).clamp(0, codedH);
    for (var y = 0; y < codedH; y++) {
      for (var x = 0; x < codedW; x++) {
        final o = (y * codedW + x) * 4;
        double v = ((x ^ y) & 1) == 0 ? 220.0 : 20.0;
        if (changed && x >= rx0 && x < rx1 && y >= ry0 && y < ry1) {
          v = 128.0; // solid grey patch overwrites the checkerboard
        }
        rgba[o + 0] = v;
        rgba[o + 1] = v;
        rgba[o + 2] = v;
        rgba[o + 3] = 255;
      }
    }
    return rgba;
  }

  final yuv0 = rgbaToYuv420Bt709LimitedCpu(
    rgba: makeRgba(false),
    width: codedW,
    height: codedH,
  );
  final yuv1 = rgbaToYuv420Bt709LimitedCpu(
    rgba: makeRgba(true),
    width: codedW,
    height: codedH,
  );

  // ---- frame 0: KEY of S0 ----
  final kfh = buildKeyFrameHeader(
    frameWidth: w,
    frameHeight: h,
    codedWidth: codedW,
    codedHeight: codedH,
    baseQIdx: baseQIdx,
  );
  final keyTg = residual.buildResidualTileGroup(
    quantCoeffs: null,
    yuv420: yuv0,
    frameWidth: codedW,
    frameHeight: codedH,
    useCoefficients: true,
    baseQIdx: baseQIdx,
    trueFrameWidth: w,
    trueFrameHeight: h,
  );
  final keyTu =
      (BytesBuilder(copy: false)
            ..add(tdObu)
            ..add(shObu)
            ..add(
              encodeObu(
                type: ObuType.frame,
                payload:
                    (BytesBuilder(copy: false)
                          ..add(kfh.payload)
                          ..add(keyTg.payload))
                        .toBytes(),
              ),
            ))
          .toBytes();

  // ---- frame 1: INTER-residual of S1, reference = frame-0 recon ----
  final ifh = buildInterFrameHeader(
    frameWidth: w,
    frameHeight: h,
    codedWidth: codedW,
    codedHeight: codedH,
    baseQIdx: baseQIdx,
    refreshFrameFlags: 0x01,
    refIdx: 0,
  );
  final interTg = residual.buildResidualTileGroup(
    quantCoeffs: null,
    yuv420: yuv1,
    frameWidth: codedW,
    frameHeight: codedH,
    useCoefficients: true,
    baseQIdx: baseQIdx,
    trueFrameWidth: w,
    trueFrameHeight: h,
    interFrame: true,
    interResidual: true,
    referenceY: keyTg.reconY,
    referenceU: keyTg.reconU,
    referenceV: keyTg.reconV,
  );
  final interTu =
      (BytesBuilder(copy: false)
            ..add(tdObu)
            ..add(
              encodeObu(
                type: ObuType.frame,
                payload:
                    (BytesBuilder(copy: false)
                          ..add(ifh.payload)
                          ..add(interTg.payload))
                        .toBytes(),
              ),
            ))
          .toBytes();

  stdout.writeln(
    'key TU ${keyTu.length} B, inter-residual TU ${interTu.length} B, '
    'coded ${codedW}x$codedH display ${w}x$h q=$baseQIdx',
  );

  final backend = MinigpuBackend();
  final mux = await backend.createMuxer(
    MuxerConfig(
      container: Container.mp4,
      output: MuxerOutput.file(outPath),
      tracks: [
        VideoTrackInfo(
          codec: VideoCodec.av1,
          width: w,
          height: h,
          frameRateNumerator: 30,
          frameRateDenominator: 1,
          extraData: CodecExtraData.video(VideoCodec.av1, av1c),
        ),
      ],
    ),
  );
  if (mux == null) {
    stderr.writeln('no muxer');
    exit(2);
  }
  await mux.writeHeader();
  await mux.writePacket(
    EncodedPacket(
      data: keyTu,
      ptsUs: 0,
      dtsUs: 0,
      durationUs: 33333,
      isKeyframe: true,
    ),
  );
  await mux.writePacket(
    EncodedPacket(
      data: interTu,
      ptsUs: 33333,
      dtsUs: 33333,
      durationUs: 33333,
      isKeyframe: false,
    ),
  );
  await mux.finish();
  await mux.close();
  stdout.writeln('wrote $outPath (2 samples)');

  // ---- closed-loop validation against ffmpeg decode of frame 1 ----
  final yuvPath = '$outPath.dec.yuv';
  final ff = await Process.run('ffmpeg', [
    '-y',
    '-loglevel',
    'error',
    '-i',
    outPath,
    '-f',
    'rawvideo',
    '-pix_fmt',
    'yuv420p',
    yuvPath,
  ]);
  if (ff.exitCode != 0) {
    stderr.writeln('ffmpeg failed: ${ff.stderr}');
    exit(3);
  }
  final dec = await File(yuvPath).readAsBytes();
  final cw = w >> 1, ch = h >> 1;
  final frameSize = w * h + 2 * (cw * ch);
  if (dec.length < 2 * frameSize) {
    stderr.writeln('decoded ${dec.length} B < 2 frames ($frameSize each)');
    exit(4);
  }

  // Expected frame-1 pixels = encoder closed-loop recon, cropped coded→display.
  final eY = interTg.reconY!;
  final eU = interTg.reconU!;
  final eV = interTg.reconV!;
  final ccw = codedW >> 1;

  var mismatches = 0;
  var maxDiff = 0;
  var firstBad = -1;
  final base = frameSize; // start of frame 1 in the decoded buffer
  // Y
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = dec[base + y * w + x];
      final e = eY[y * codedW + x];
      final diff = (d - e).abs();
      if (diff != 0) {
        mismatches++;
        if (diff > maxDiff) maxDiff = diff;
        if (firstBad < 0) firstBad = y * w + x;
      }
    }
  }
  // U
  final decU = base + w * h;
  final decV = decU + cw * ch;
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      final du = dec[decU + y * cw + x];
      final eu = eU[y * ccw + x];
      final dv = dec[decV + y * cw + x];
      final ev = eV[y * ccw + x];
      if (du != eu || dv != ev) {
        mismatches++;
        final m = (du - eu).abs();
        final n = (dv - ev).abs();
        if (m > maxDiff) maxDiff = m;
        if (n > maxDiff) maxDiff = n;
      }
    }
  }

  if (mismatches == 0) {
    stdout.writeln(
      'PASS: decoded frame 1 == encoder closed-loop recon (bit-exact), '
      '${w}x$h',
    );
    exit(0);
  } else {
    stderr.writeln(
      'FAIL: $mismatches mismatched samples, maxDiff=$maxDiff, '
      'firstBad(Y idx)=$firstBad',
    );
    exit(1);
  }
}
