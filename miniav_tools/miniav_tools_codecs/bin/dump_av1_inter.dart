// Standalone validation harness for the Phase-1 P-frame (inter) path.
//
// Emits an MP4 with:
//   * frame 0 — KEY_FRAME (real intra residual on a checkerboard), and
//   * frames 1..N-1 — INTER_FRAME, every block single-ref LAST + GLOBALMV +
//     skip, i.e. a verbatim copy of the reference frame.
//
// Because every inter frame just copies its reference (the decoded key
// frame, which all inter frames refresh back into slot 0), the decoded
// output of frame k>0 must be byte-identical to the decoded key frame.
// That is the bit-exactness check against dav1d.
//
// Usage:  dart run bin/dump_av1_inter.dart [out.mp4] [num_frames] [W] [H] [crf]
//
// Validate:
//   dart run bin/dump_av1_inter.dart t.mp4 3 64 64
//   ffmpeg -y -loglevel error -i t.mp4 -f rawvideo -pix_fmt yuv420p t.yuv
//   dart run bin/av1_inter_check.dart t.yuv 64 64 3
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
// ignore_for_file: implementation_imports
import 'package:miniav_tools_codecs/src/av1/av1_constants.dart';
import 'package:miniav_tools_codecs/src/av1/av1_frame_header.dart';
import 'package:miniav_tools_codecs/src/av1/av1_inter_tile_group.dart';
import 'package:miniav_tools_codecs/src/av1/av1_obu.dart';
import 'package:miniav_tools_codecs/src/av1/av1_residual_tile_group.dart'
    as residual;
import 'package:miniav_tools_codecs/src/av1/av1_sequence_header.dart';
import 'package:miniav_tools_codecs/src/av1/mp4/av1_mp4_muxer.dart'
    show buildAv1ConfigRecord;

Future<void> main(List<String> argv) async {
  final outPath = argv.isNotEmpty ? argv[0] : 'out.mp4';
  final frames = argv.length >= 2 ? int.parse(argv[1]) : 3;
  final w = argv.length >= 3 ? int.parse(argv[2]) : 64;
  final h = argv.length >= 4 ? int.parse(argv[3]) : 64;
  final crf = argv.length >= 5 ? int.parse(argv[4]) : 16;

  final codedW = ((w + 63) >> 6) << 6;
  final codedH = ((h + 63) >> 6) << 6;
  final baseQIdx = crf.clamp(1, 20);

  // ---- sequence header + av1C config record ----
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

  // ---- frame 0: KEY_FRAME from a checkerboard ----
  final rgba = Float32List(codedW * codedH * 4);
  int clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
  for (var y = 0; y < codedH; y++) {
    for (var x = 0; x < codedW; x++) {
      final o = (y * codedW + x) * 4;
      final cb = ((x ^ y) & 1) == 0 ? 220 : 20;
      rgba[o + 0] = clamp(cb).toDouble();
      rgba[o + 1] = clamp(cb).toDouble();
      rgba[o + 2] = clamp(cb).toDouble();
      rgba[o + 3] = 255;
    }
  }
  final yuv = rgbaToYuv420Bt709LimitedCpu(
    rgba: rgba,
    width: codedW,
    height: codedH,
  );

  final kfh = buildKeyFrameHeader(
    frameWidth: w,
    frameHeight: h,
    codedWidth: codedW,
    codedHeight: codedH,
    baseQIdx: baseQIdx,
  );
  final keyTg = residual.buildResidualTileGroup(
    quantCoeffs: null,
    yuv420: yuv,
    frameWidth: codedW,
    frameHeight: codedH,
    useCoefficients: true,
    baseQIdx: baseQIdx,
    trueFrameWidth: w,
    trueFrameHeight: h,
  );
  final keyFrameObu = encodeObu(
    type: ObuType.frame,
    payload:
        (BytesBuilder(copy: false)
              ..add(kfh.payload)
              ..add(keyTg.payload))
            .toBytes(),
  );
  final keyTu =
      (BytesBuilder(copy: false)
            ..add(tdObu)
            ..add(shObu)
            ..add(keyFrameObu))
          .toBytes();

  // ---- frames 1..N-1: INTER_FRAME (copy reference, refresh slot 0) ----
  final ifh = buildInterFrameHeader(
    frameWidth: w,
    frameHeight: h,
    codedWidth: codedW,
    codedHeight: codedH,
    baseQIdx: baseQIdx,
    refreshFrameFlags: 0x01,
    refIdx: 0,
  );
  final interTg = buildInterTileGroup(
    frameWidth: codedW,
    frameHeight: codedH,
    trueFrameWidth: w,
    trueFrameHeight: h,
  );
  final interFrameObu = encodeObu(
    type: ObuType.frame,
    payload:
        (BytesBuilder(copy: false)
              ..add(ifh.payload)
              ..add(interTg.payload))
            .toBytes(),
  );
  final interTu =
      (BytesBuilder(copy: false)
            ..add(tdObu)
            ..add(interFrameObu))
          .toBytes();

  stdout.writeln(
    'key TU ${keyTu.length} B (${keyTg.symbolsEmitted} sym), '
    'inter TU ${interTu.length} B (${interTg.symbolsEmitted} sym), '
    'coded ${codedW}x$codedH display ${w}x$h q=$baseQIdx',
  );

  // ---- mux ----
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
  for (var i = 0; i < frames; i++) {
    final isKey = i == 0;
    await mux.writePacket(
      EncodedPacket(
        data: isKey ? keyTu : interTu,
        ptsUs: i * 33333,
        dtsUs: i * 33333,
        durationUs: 33333,
        isKeyframe: isKey,
      ),
    );
  }
  await mux.finish();
  await mux.close();
  stdout.writeln('wrote $outPath ($frames samples)');
  exit(0);
}
