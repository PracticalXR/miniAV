/// Software FFmpeg decoder (libavcodec) — Phase A.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_encoder.dart' show address;
import 'ffmpeg_ffi.dart';
import 'ffmpeg_shim.dart';

class FfmpegSoftwareDecoder implements PlatformDecoder {
  FfmpegSoftwareDecoder._(this._ff, this._codecCtx, this._frame, this._packet);

  final Ffmpeg _ff;
  final Pointer<AVCodecContext> _codecCtx;
  final Pointer<AVFrame> _frame;
  final Pointer<AVPacket> _packet;

  bool _closed = false;

  /// pts fallback state for streams that deliver AV_NOPTS frames.
  int _lastPtsUs = 0;
  int _lastDeltaUs = _kFallbackFrameDurationUs;

  static FfmpegSoftwareDecoder open(DecoderConfig cfg) {
    final ff = Ffmpeg.instance();
    if (ff == null) {
      throw const CodecInitException(
        'ffmpeg',
        'FFmpeg not loaded — call ensureFFmpegLoaded() first',
      );
    }
    final codec = ff.avcodecFindDecoder(_videoCodecToAvId(cfg.codec));
    if (codec == address(0)) {
      throw CodecInitException(
        'ffmpeg',
        'No decoder registered for ${cfg.codec}',
      );
    }
    final codecCtx = ff.avcodecAllocContext3(codec);
    if (codecCtx == address(0)) {
      throw const CodecInitException(
        'ffmpeg',
        'avcodec_alloc_context3 returned NULL',
      );
    }
    try {
      // Out-of-band codec-private data (H.264/HEVC avcC/hvcC, VP9/AV1
      // codec-private). Annex-B streams don't need it. Requires the shim
      // (the context must own an av_malloc'd copy).
      final extra = cfg.extraData;
      if (extra != null && extra.isNotEmpty) {
        final shim = FfmpegShim.tryLoad();
        if (shim == null) {
          throw const CodecInitException(
            'ffmpeg',
            'DecoderConfig.extraData requires the miniav_tools_ffmpeg shim '
                '(not loadable) — or feed a self-contained (Annex-B) stream',
          );
        }
        final r = shim.codecSetExtradata(codecCtx.cast<Void>(), extra);
        if (r < 0) {
          throw CodecInitException(
            'ffmpeg',
            'codec_set_extradata failed: ${ff.strError(r)}',
          );
        }
      }
      final ret = ff.avcodecOpen2(codecCtx, codec, nullptr);
      if (ret < 0) {
        throw CodecInitException(
          'ffmpeg',
          'avcodec_open2 (decoder): ${ff.strError(ret)}',
        );
      }
      final frame = ff.avFrameAlloc();
      final packet = ff.avPacketAlloc();
      return FfmpegSoftwareDecoder._(ff, codecCtx, frame, packet);
    } catch (_) {
      final ptr = calloc<Pointer<AVCodecContext>>()..value = codecCtx;
      ff.avcodecFreeContext(ptr);
      calloc.free(ptr);
      rethrow;
    }
  }

  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async {
    _checkOpen();
    final size = packet.data.length;
    final buf = calloc<Uint8>(size);
    try {
      buf.asTypedList(size).setRange(0, size, packet.data);
      _packet.ref
        ..data = buf
        ..size = size
        ..pts = packet.ptsUs
        ..dts = packet.dtsUs == 0 ? packet.ptsUs : packet.dtsUs
        ..flags = packet.isKeyframe ? kPktFlagKey : 0;
      final ret = _ff.avcodecSendPacket(_codecCtx, _packet);
      if (ret < 0 && ret != kAvErrorEAgain) {
        throw CodecRuntimeException(
          'ffmpeg',
          'avcodec_send_packet: ${_ff.strError(ret)}',
        );
      }
    } finally {
      // The packet is consumed by libavcodec immediately (or queued); we
      // can release our copy now since we always reset .data on next call.
      calloc.free(buf);
      _packet.ref.data = nullptr;
      _packet.ref.size = 0;
    }
    return _drainOne();
  }

  @override
  Future<List<DecodedFrame>> flush() async {
    _checkOpen();
    final ret = _ff.avcodecSendPacket(_codecCtx, nullptr);
    if (ret < 0 && ret != kAvErrorEof) {
      throw CodecRuntimeException(
        'ffmpeg',
        'avcodec_send_packet(NULL): ${_ff.strError(ret)}',
      );
    }
    final out = <DecodedFrame>[];
    while (true) {
      final f = _drainOne();
      if (f == null) break;
      out.add(f);
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final fp = calloc<Pointer<AVFrame>>()..value = _frame;
    final pp = calloc<Pointer<AVPacket>>()..value = _packet;
    final cp = calloc<Pointer<AVCodecContext>>()..value = _codecCtx;
    try {
      _ff.avFrameFree(fp);
      _ff.avPacketFree(pp);
      _ff.avcodecFreeContext(cp);
    } finally {
      calloc.free(fp);
      calloc.free(pp);
      calloc.free(cp);
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg', 'decoder closed');
    }
  }

  DecodedFrame? _drainOne() {
    final ret = _ff.avcodecReceiveFrame(_codecCtx, _frame);
    if (ret == kAvErrorEAgain || ret == kAvErrorEof) return null;
    if (ret < 0) {
      throw CodecRuntimeException(
        'ffmpeg',
        'avcodec_receive_frame: ${_ff.strError(ret)}',
      );
    }
    final f = _frame.ref;
    final w = f.width;
    final h = f.height;
    // FAITHFULLY extract whatever libavcodec produced (4:2:0/4:2:2/4:4:4, 8- or
    // 10-bit, limited or full/JPEG range) and TAG the frame with it — the
    // converter then renders correct colour. Reading a 10-bit or 4:2:2 frame as
    // 8-bit 4:2:0 (the old behaviour) silently corrupted the image.
    final info = _pixFmtInfo(_ff, f.format);
    if (info == null) {
      throw CodecRuntimeException(
        'ffmpeg',
        'decoded pixel format av_pix_fmt=${f.format} is not supported by the '
            'first-party YUV extractor (no libswscale on this path)',
      );
    }
    final out = _extractPlanes(f, info.layout, w, h);
    // Colour matrix + range: use EXPLICIT bitstream metadata only (H.264/HEVC
    // VUI via the shim accessors); yuvj* names already imply full range. No
    // resolution heuristic — see [YuvColorMatrix] (miniAV round-trip
    // stability: our own encodes carry no VUI and must stay bt601).
    var fullRange = info.full;
    var matrix = YuvColorMatrix.bt601;
    final shim = FfmpegShim.tryLoad();
    if (shim != null) {
      final fp = _frame.cast<Void>();
      final cs = shim.frameColorspace(fp);
      // AVColorSpace: BT709=1; BT2020 NCL/CL=9/10 (NCL matrix table; PQ/HLG
      // transfer is signalled but not tone-mapped — see YuvColorMatrix.bt2020).
      if (cs == 1) matrix = YuvColorMatrix.bt709;
      if (cs == 9 || cs == 10) matrix = YuvColorMatrix.bt2020;
      if (shim.frameColorRange(fp) == 2) fullRange = true; // AVCOL_RANGE_JPEG
    }
    // Packets are fed with pts in MICROSECONDS and no time_base is set on
    // the codec context, so libavcodec passes pts through 1:1 — decoded
    // `frame.pts` is already µs. For AV_NOPTS frames, extrapolate from the
    // last observed inter-frame delta.
    final int ptsUs;
    if (f.pts == _avNoPts) {
      ptsUs = _lastPtsUs + _lastDeltaUs;
    } else {
      ptsUs = f.pts;
      final delta = ptsUs - _lastPtsUs;
      if (delta > 0) _lastDeltaUs = delta;
    }
    _lastPtsUs = ptsUs;
    return _Yuv420pFrame(
      width: w,
      height: h,
      ptsUs: ptsUs,
      bytes: out,
      pixelLayout: info.layout,
      isFullRange: fullRange,
      colorMatrix: matrix,
    );
  }
}

/// av_pix_fmt int → (planar layout, full-range) for the formats the first-party
/// extractor + converters handle. The ints are resolved by NAME at runtime
/// (memoized) so this survives libavutil enum-value shifts across versions.
Map<int, ({DecodedPixelLayout layout, bool full})>? _fmtMapCache;

({DecodedPixelLayout layout, bool full})? _pixFmtInfo(Ffmpeg ff, int fmt) =>
    (_fmtMapCache ??= _buildFmtMap(ff))[fmt];

Map<int, ({DecodedPixelLayout layout, bool full})> _buildFmtMap(Ffmpeg ff) {
  const specs = <String, ({DecodedPixelLayout layout, bool full})>{
    'yuv420p': (layout: DecodedPixelLayout.i420, full: false),
    'yuvj420p': (layout: DecodedPixelLayout.i420, full: true),
    'yuv422p': (layout: DecodedPixelLayout.i422, full: false),
    'yuvj422p': (layout: DecodedPixelLayout.i422, full: true),
    'yuv444p': (layout: DecodedPixelLayout.i444, full: false),
    'yuvj444p': (layout: DecodedPixelLayout.i444, full: true),
    'yuv420p10le': (layout: DecodedPixelLayout.i420p10, full: false),
    'yuv422p10le': (layout: DecodedPixelLayout.i422p10, full: false),
    'yuv444p10le': (layout: DecodedPixelLayout.i444p10, full: false),
    'nv12': (layout: DecodedPixelLayout.nv12, full: false),
    'p010le': (layout: DecodedPixelLayout.p010, full: false),
  };
  final out = <int, ({DecodedPixelLayout layout, bool full})>{};
  for (final e in specs.entries) {
    final p = e.key.toNativeUtf8();
    try {
      final id = ff.avGetPixFmtByName(p);
      if (id >= 0) out[id] = e.value;
    } finally {
      calloc.free(p);
    }
  }
  return out;
}

/// Copy libavcodec's (possibly strided) planes into one tightly-packed buffer
/// with the geometry [layout] implies. 10-bit planes are copied verbatim as
/// 16-bit LE samples (byte width doubled); the converter scales them.
Uint8List _extractPlanes(AVFrame f, DecodedPixelLayout layout, int w, int h) {
  final cw = (w + 1) >> 1;
  final ch = (h + 1) >> 1;
  // Each entry: (srcPtr, srcStride, rowBytes, rows).
  final List<(Pointer<Uint8>, int, int, int)> planes = switch (layout) {
    // The ffmpeg pix_fmt map only ever tags YUV layouts; rgba can't reach here.
    DecodedPixelLayout.rgba =>
      throw StateError('ffmpeg decoder never produces DecodedPixelLayout.rgba'),
    DecodedPixelLayout.i420 => [
        (f.data0, f.linesize0, w, h),
        (f.data1, f.linesize1, cw, ch),
        (f.data2, f.linesize2, cw, ch),
      ],
    DecodedPixelLayout.i422 => [
        (f.data0, f.linesize0, w, h),
        (f.data1, f.linesize1, cw, h),
        (f.data2, f.linesize2, cw, h),
      ],
    DecodedPixelLayout.i444 => [
        (f.data0, f.linesize0, w, h),
        (f.data1, f.linesize1, w, h),
        (f.data2, f.linesize2, w, h),
      ],
    DecodedPixelLayout.i420p10 => [
        (f.data0, f.linesize0, 2 * w, h),
        (f.data1, f.linesize1, 2 * cw, ch),
        (f.data2, f.linesize2, 2 * cw, ch),
      ],
    DecodedPixelLayout.i422p10 => [
        (f.data0, f.linesize0, 2 * w, h),
        (f.data1, f.linesize1, 2 * cw, h),
        (f.data2, f.linesize2, 2 * cw, h),
      ],
    DecodedPixelLayout.i444p10 => [
        (f.data0, f.linesize0, 2 * w, h),
        (f.data1, f.linesize1, 2 * w, h),
        (f.data2, f.linesize2, 2 * w, h),
      ],
    DecodedPixelLayout.nv12 => [
        (f.data0, f.linesize0, w, h),
        (f.data1, f.linesize1, 2 * cw, ch), // interleaved UV
      ],
    DecodedPixelLayout.p010 => [
        (f.data0, f.linesize0, 2 * w, h), // 16-bit LE Y
        (f.data1, f.linesize1, 4 * cw, ch), // 16-bit LE interleaved UV pairs
      ],
  };
  var total = 0;
  for (final p in planes) {
    total += p.$3 * p.$4;
  }
  final out = Uint8List(total);
  var off = 0;
  for (final p in planes) {
    _copyPlaneOut(out, off, p.$1, p.$2, p.$3, p.$4);
    off += p.$3 * p.$4;
  }
  return out;
}

const int _avNoPts = -0x8000000000000000;

/// Nominal frame spacing used only until a real pts delta is observed.
const int _kFallbackFrameDurationUs = 1000000 ~/ 30;

int _videoCodecToAvId(VideoCodec codec) {
  switch (codec) {
    case VideoCodec.h264:
      return AVCodecId.h264;
    case VideoCodec.hevc:
      return AVCodecId.hevc;
    case VideoCodec.mjpeg:
      return AVCodecId.mjpeg;
    case VideoCodec.vp8:
      return AVCodecId.vp8;
    case VideoCodec.vp9:
      return AVCodecId.vp9;
    case VideoCodec.av1:
      return AVCodecId.av1;
    default:
      throw CodecInitException('ffmpeg', 'unsupported decoder codec: $codec');
  }
}

void _copyPlaneOut(
  Uint8List dst,
  int dstOff,
  Pointer<Uint8> src,
  int srcStride,
  int w,
  int h,
) {
  final view = src.asTypedList(srcStride * h);
  for (var row = 0; row < h; row++) {
    dst.setRange(dstOff + row * w, dstOff + row * w + w, view, row * srcStride);
  }
}

class _Yuv420pFrame implements DecodedFrame {
  _Yuv420pFrame({
    required this.width,
    required this.height,
    required this.ptsUs,
    required Uint8List bytes,
    this.pixelLayout = DecodedPixelLayout.i420,
    this.isFullRange = false,
    this.colorMatrix = YuvColorMatrix.bt601,
  }) : _bytes = bytes;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;
  final Uint8List _bytes;
  @override
  final DecodedPixelLayout pixelLayout;
  @override
  final bool isFullRange;
  @override
  final YuvColorMatrix colorMatrix;

  @override
  Future<List<int>> readBytes() async => _bytes;

  @override
  Object? get webVideoFrame => null; // native YUV path
  @override
  FrameSourceKind get outputKind => FrameSourceKind.cpu; // software YUV planes
  @override
  int get gpuHandle => 0;
  @override
  int get subresourceIndex => 0;

  @override
  void close() {}
}
