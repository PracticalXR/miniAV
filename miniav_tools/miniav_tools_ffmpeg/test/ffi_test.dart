/// FFI smoke test: ensures all looked-up symbols actually resolve in the
/// loaded shared libraries. Network-gated (needs FFmpeg DLLs available).
library;

import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:miniav_tools_ffmpeg/src/ffmpeg_ffi.dart';
import 'package:test/test.dart';

void main() {
  final enabled =
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();

  test(
    'all FFmpeg FFI symbols resolve',
    skip: enabled
        ? null
        : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 (first run downloads ~92 MB)',
    () async {
      final ok = await ensureFFmpegLoaded();
      expect(ok, isTrue);

      Ffmpeg.resetForTests();
      final ff = Ffmpeg.instance();
      expect(ff, isNotNull);

      // Touching each late-bound function forces the symbol lookup. If any
      // lookup throws ArgumentError("Failed to lookup symbol"), the test
      // fails with a useful message.
      final symbols = <String, Object>{
        'av_frame_alloc': ff!.avFrameAlloc,
        'av_frame_free': ff.avFrameFree,
        'av_frame_get_buffer': ff.avFrameGetBuffer,
        'av_frame_make_writable': ff.avFrameMakeWritable,
        'av_packet_alloc': ff.avPacketAlloc,
        'av_packet_free': ff.avPacketFree,
        'av_packet_unref': ff.avPacketUnref,
        'avcodec_find_encoder_by_name': ff.avcodecFindEncoderByName,
        'avcodec_find_encoder': ff.avcodecFindEncoder,
        'avcodec_find_decoder': ff.avcodecFindDecoder,
        'avcodec_alloc_context3': ff.avcodecAllocContext3,
        'avcodec_free_context': ff.avcodecFreeContext,
        'avcodec_open2': ff.avcodecOpen2,
        'avcodec_send_frame': ff.avcodecSendFrame,
        'avcodec_receive_packet': ff.avcodecReceivePacket,
        'avcodec_send_packet': ff.avcodecSendPacket,
        'avcodec_receive_frame': ff.avcodecReceiveFrame,
        'av_dict_set': ff.avDictSet,
        'av_dict_free': ff.avDictFree,
        'av_opt_set_int': ff.avOptSetInt,
        'av_opt_set': ff.avOptSet,
        'av_opt_set_q': ff.avOptSetQ,
        'av_strerror': ff.avStrError,
        'av_image_get_buffer_size': ff.avImageGetBufferSize,
        'av_image_fill_arrays': ff.avImageFillArrays,
      };
      for (final entry in symbols.entries) {
        expect(entry.value, isNotNull, reason: entry.key);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'LGPL build: GPL encoders absent, libopenh264 present',
    skip: enabled ? null : 'requires FFmpeg DLLs',
    () async {
      await ensureFFmpegLoaded();
      final ff = Ffmpeg.instance()!;

      bool hasEncoder(String name) {
        final p = name.toNativeUtf8();
        try {
          return ff.avcodecFindEncoderByName(p).address != 0;
        } finally {
          calloc.free(p);
        }
      }

      // License guard: we ship the BtbN **LGPL** build (kFfmpegLicense). The
      // GPL-only software encoders must NOT be present — their presence would
      // mean a `-gpl-shared` build slipped in and downstream products would
      // inherit GPL copyleft. See ffmpeg_downloader.dart.
      expect(
        hasEncoder('libx264'),
        isFalse,
        reason:
            'libx264 is GPL — its presence means a GPL FFmpeg build was '
            'downloaded. Check kFfmpegLicense == "lgpl".',
      );
      expect(
        hasEncoder('libx265'),
        isFalse,
        reason: 'libx265 is GPL — must not be in the LGPL build.',
      );

      // The LGPL build supplies software H.264 via libopenh264 (Cisco, BSD),
      // which is the CPU H.264 fallback. Informational — don't hard-fail if a
      // future BtbN build drops it, but log loudly.
      if (!hasEncoder('libopenh264')) {
        // ignore: avoid_print
        print(
          'WARN: libopenh264 not present — software H.264 fallback relies on '
          'MediaFoundation (h264_mf) only on this build.',
        );
      }
    },
  );
}
