// Phase-2a validation: an INTER frame whose blocks are ALL intra-coded.
//
// Frame 0 is a KEY frame of a checkerboard source S. Frame 1 is an
// INTER_FRAME encoding the SAME source S, but with every block signalled as
// intra (is_inter=0) using the inter-frame if_y_mode CDF. Because both frames
// reconstruct the identical source with the identical intra pipeline, the
// decoded frame 1 must be byte-identical to the decoded frame 0. That proves
// the intra-in-inter syntax (is_inter context + if_y_mode CDF) is bit-exact.
//
// Usage:  dart run bin/dump_av1_intra_inter.dart [out.mp4] [W] [H] [crf]
// Validate (frame 1 == frame 0):
//   dart run bin/dump_av1_intra_inter.dart t2.mp4 64 64
//   ffmpeg -y -loglevel error -i t2.mp4 -f rawvideo -pix_fmt yuv420p t2.yuv
//   dart run bin/av1_inter_check.dart t2.yuv 64 64 2
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

  // Shared checkerboard source S.
  final rgba = Float32List(codedW * codedH * 4);
  for (var y = 0; y < codedH; y++) {
    for (var x = 0; x < codedW; x++) {
      final o = (y * codedW + x) * 4;
      final cb = ((x ^ y) & 1) == 0 ? 220.0 : 20.0;
      rgba[o + 0] = cb;
      rgba[o + 1] = cb;
      rgba[o + 2] = cb;
      rgba[o + 3] = 255;
    }
  }
  final yuv = rgbaToYuv420Bt709LimitedCpu(
    rgba: rgba,
    width: codedW,
    height: codedH,
  );

  // ---- frame 0: KEY ----
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

  // ---- frame 1: INTER, all blocks intra-coded (same source) ----
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
    yuv420: yuv,
    frameWidth: codedW,
    frameHeight: codedH,
    useCoefficients: true,
    baseQIdx: baseQIdx,
    trueFrameWidth: w,
    trueFrameHeight: h,
    interFrame: true,
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
    'key TU ${keyTu.length} B, intra-inter TU ${interTu.length} B, '
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
  exit(0);
}
