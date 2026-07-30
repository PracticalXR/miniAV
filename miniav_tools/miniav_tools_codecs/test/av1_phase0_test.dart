@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

void main() {
  group('AV1 Phase 0 — bitstream + MP4 wiring', () {
    final backend = MinigpuBackend();

    test('backend advertises AV1 encode + MP4 mux', () {
      expect(backend.supportsEncode(VideoCodec.av1), isTrue);
      expect(backend.supportsMux(Container.mp4), isTrue);
    });

    test(
      'encoder produces TD+SH+FrameOBU bytes and carries av1C extraData',
      () async {
        const w = 320;
        const h = 240;
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

        try {
          final pkt = await encoder!.encode(
            CpuFrameSource(
              bytes: Uint8List(w * h * 4),
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: w,
              height: h,
              timestampUs: 0,
            ),
          );
          expect(pkt, isNotNull);
          final data = pkt!.data;
          // First byte = OBU header for TD: type=2, has_size_field=1, ext=0
          //   bit layout: 0 [type:4] [ext:1] [has_size:1] [reserved:1]
          //              = 0 0010 0 1 0 = 0b0001_0010 = 0x12
          expect(data[0], 0x12, reason: 'first OBU must be TD');
          // TD payload is 0 bytes → next byte is the leb128 size = 0
          expect(data[1], 0x00);
          // Then sequence header OBU header (type=1):
          //   0 0001 0 1 0 = 0b0000_1010 = 0x0A
          expect(data[2], 0x0A);

          // Extra data carries av1C config record.
          final extra = encoder.extraData;
          expect(extra, isNotNull);
          expect(extra!.bytes.isNotEmpty, isTrue);
          // av1C byte 0: marker=1, version=1 → 0x81
          expect(extra.bytes[0], 0x81);
        } finally {
          await encoder?.close();
        }
      },
    );

    test('writes a parseable MP4 to disk', () async {
      const w = 320;
      const h = 240;
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

      // Encode 5 frames so we exercise stts run-length + stss.
      final packets = <EncodedPacket>[];
      try {
        for (var i = 0; i < 5; i++) {
          final pkt = await encoder!.encode(
            CpuFrameSource(
              bytes: Uint8List(w * h * 4),
              pixelFormat: MiniAVPixelFormat.rgba32,
              width: w,
              height: h,
              timestampUs: i * 33333,
            ),
          );
          expect(pkt, isNotNull);
          packets.add(pkt!);
        }
      } finally {
        await encoder?.close();
      }

      // Mux them.
      final tmp = await Directory.systemTemp.createTemp('av1_phase0_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final outPath = '${tmp.path}/phase0.mp4';

      final muxer = await backend.createMuxer(
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
              extraData: encoder!.extraData,
            ),
          ],
        ),
      );
      expect(muxer, isNotNull);

      try {
        await muxer!.writeHeader();
        for (final p in packets) {
          await muxer.writePacket(p);
        }
        await muxer.finish();
      } finally {
        await muxer?.close();
      }

      // File must exist and start with a sane ftyp box.
      final file = File(outPath);
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.length, greaterThan(64));
      // ftyp box: bytes[4..8] == 'ftyp'
      expect(_fourCc(bytes, 4), 'ftyp');
      // major_brand at bytes[8..12] should be 'isom'
      expect(_fourCc(bytes, 8), 'isom');
      // Should contain 'av01' brand and 'av1C' box somewhere.
      expect(_containsFourCc(bytes, 'av01'), isTrue);
      expect(_containsFourCc(bytes, 'av1C'), isTrue);
      expect(_containsFourCc(bytes, 'moov'), isTrue);
      expect(_containsFourCc(bytes, 'mdat'), isTrue);
      expect(_containsFourCc(bytes, 'stss'), isTrue);
    });
  });
}

String _fourCc(Uint8List bytes, int offset) {
  return String.fromCharCodes(bytes.sublist(offset, offset + 4));
}

bool _containsFourCc(Uint8List bytes, String fcc) {
  final needle = fcc.codeUnits;
  outer:
  for (var i = 0; i + 4 <= bytes.length; i++) {
    for (var j = 0; j < 4; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
