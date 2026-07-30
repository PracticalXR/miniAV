/// Abstract platform classes implemented by backends.
library;

import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';

import 'config.dart';
import 'frame_source.dart';
import 'packet.dart';

/// Abstract video/audio encoder. Backends return a concrete subclass from
/// [MiniAVToolsBackend.createEncoder].
///
/// Lifecycle:
///   create → encode* (zero or more) → flush → close
abstract class PlatformEncoder {
  /// Submit one frame for encoding. Returns the encoded packet for that
  /// frame, or `null` if the encoder is buffering (e.g. for B-frames or
  /// hardware lookahead). Always call [flush] at end-of-stream to drain any
  /// remaining buffered packets.
  Future<EncodedPacket?> encode(FrameSource frame);

  /// Drain any internally buffered packets. Returns them in DTS order.
  /// Call once at end-of-stream.
  Future<List<EncodedPacket>> flush();

  /// Force the next encoded frame to be a keyframe (IDR for H.264).
  Future<void> requestKeyframe();

  /// Codec extra-data (SPS/PPS, codec-private) for muxer track headers.
  /// May be `null` until the first packet has been emitted.
  CodecExtraData? get extraData;

  /// Release encoder resources.
  Future<void> close();

  /// Whether this encoder can accept GPU buffer input via an out-of-band
  /// path (bypassing the normal [FrameSource] pipeline).  When `true` the
  /// recorder can hand a caller-owned GPU buffer directly to the encoder
  /// without a CPU round-trip.  Default: `false`.
  bool get supportsGpuBufferInput => false;

  /// Whether this encoder consumes pre-converted planar YUV420P (I420) frames
  /// directly (`FrameSource.yuv420p`) without an internal RGBA→YUV conversion.
  /// When `true`, the recorder's GPU-downscale + CPU-readback path can convert
  /// to YUV420P on the GPU and read back the smaller planes instead of RGBA.
  /// Encoders that need a different input layout (e.g. NV12 for a CPU-fed HW
  /// encoder) should leave this `false`.  Default: `false`.
  bool get acceptsYuv420pPlanes => false;
}

/// Abstract audio encoder. Backends return a concrete subclass from
/// [MiniAVToolsBackend.createAudioEncoder].
///
/// Lifecycle:
///   create → encode* → flush → close
///
/// PCM data is supplied per call (not at construction) so a single encoder
/// can transparently accept whichever interleaved PCM layout miniav
/// delivers — the implementation handles deinterleave / sample-format
/// conversion as needed by the underlying codec.
abstract class PlatformAudioEncoder {
  /// Submit interleaved PCM samples for encoding.
  ///
  /// - [pcm]:        raw bytes; size must equal `frameCount * channels *
  ///                 bytesPerSample(format)`.
  /// - [format]:     sample format describing [pcm] (u8/s16/s32/f32).
  /// - [frameCount]: samples per channel in [pcm].
  /// - [ptsUs]:      presentation timestamp of the FIRST sample, microseconds.
  ///
  /// Returns zero or more encoded packets; one input chunk may emit several
  /// codec packets when the codec frame size is smaller than [frameCount],
  /// or none when buffering across chunks.
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  });

  /// Flush any internally buffered samples + emit trailing packets.
  Future<List<EncodedPacket>> flush();

  /// Codec extra-data (e.g. ASC for AAC, OpusHead for Opus). May be `null`
  /// until the first packet has been emitted.
  CodecExtraData? get extraData;

  /// Release encoder resources.
  Future<void> close();
}

///
/// Lifecycle:
///   create → decode* → flush → close
abstract class PlatformDecoder {
  /// Submit one encoded packet. Returns a [DecodedFrame] when one is ready,
  /// or `null` if the decoder is buffering (e.g. waiting for B-frame
  /// dependencies).
  Future<DecodedFrame?> decode(EncodedPacket packet);

  /// Drain any internally buffered frames at end-of-stream.
  Future<List<DecodedFrame>> flush();

  /// Release decoder resources.
  Future<void> close();
}

/// Planar layout + bit depth of a CPU-resident decoded frame's tightly-packed
/// bytes (from [DecodedFrame.readBytes]). The presenter routes to the matching
/// YUV→RGBA converter; combined with [DecodedFrame.isFullRange] it fully
/// determines the colour conversion. GPU/browser frames ignore this (they route
/// by [DecodedFrame.outputKind] / [DecodedFrame.webVideoFrame]).
///
/// A software decoder MUST report the layout it actually produced — emitting
/// 4:2:2 / 4:4:4 / 10-bit bytes while claiming [i420] renders wrong colours.
///
/// ## Stride/pitch contract
///
/// CPU bytes ([DecodedFrame.readBytes]) are TIGHTLY PACKED: row stride == the
/// layout's row byte-width (luma `w` / `2*w` for 10-bit; chroma per the layout;
/// nv12/p010 UV rows `2*ceil(w/2)` samples), no per-row padding, planes
/// back-to-back Y|U|V (or Y|UV). Decoders copy out of the codec's padded
/// buffers into this shape (see the ffmpeg extractor); converters and the GPU
/// upload path rely on it.
///
/// GPU handles ([DecodedFrame.gpuHandle]) are the OPPOSITE: an NV12/P010
/// texture's rows are DRIVER-PITCH aligned (D3D11 `RowPitch`, Vulkan
/// `rowPitch`), which is ≥ and usually > the visible row width. An importer
/// must take the pitch from the map/import API — importing or mapping with an
/// assumed `width`-byte pitch shears the image. When a HW frame is mapped to
/// CPU for the fallback path, the mapper must REPACK to the tight layout above
/// (the MF decoder's NV12→I420 map does exactly this) before tagging the bytes
/// with a [DecodedPixelLayout].
enum DecodedPixelLayout {
  /// 8-bit 4:2:0 planar (Y | U | V), chroma ceil(w/2)×ceil(h/2).
  i420,

  /// 8-bit 4:2:2 planar, chroma ceil(w/2)×h.
  i422,

  /// 8-bit 4:4:4 planar, chroma w×h.
  i444,

  /// 10-bit 4:2:0 planar, 16-bit little-endian samples.
  i420p10,

  /// 10-bit 4:2:2 planar.
  i422p10,

  /// 10-bit 4:4:4 planar.
  i444p10,

  /// 8-bit 4:2:0, Y plane + interleaved UV plane.
  nv12,

  /// 10-bit 4:2:0, Y plane + interleaved UV plane (10-bit NV12): 16-bit
  /// little-endian samples with the 10 significant bits in the HIGH bits
  /// (15..6) — unlike [i420p10], which uses the low bits. This is the
  /// D3D11/NVDEC/VideoToolbox hardware 10-bit surface layout.
  p010,

  /// Packed 8-bit RGBA8888 (`w*h*4` bytes, alpha last) — already displayable,
  /// NO YUV->RGB conversion applies ([DecodedFrame.isFullRange] /
  /// [DecodedFrame.colorMatrix] are meaningless for it). Produced by decoders
  /// whose output is natively RGB: passthrough/debug codecs and
  /// [VideoCodec.custom] backends that decode straight to RGBA.
  rgba,
}

/// YCbCr→RGB matrix of a CPU-resident decoded frame. Combined with
/// [DecodedFrame.isFullRange] it selects the converter's coefficient set.
///
/// The default everywhere is [bt601] — miniAV's own encode pipeline is
/// BT.601, so defaulting keeps miniAV round-trips byte-stable. A software
/// decoder should report [bt709]/[bt2020] ONLY when the bitstream explicitly
/// declares it (H.264/HEVC VUI colour info); do NOT guess from resolution, or
/// miniAV-encoded HD content (no VUI) would silently change colour.
///
/// [bt2020] is the NCL MATRIX only. PQ/HLG transfer functions are NOT applied
/// by the converters (HDR content is rendered with its 10-bit values scaled to
/// 8-bit SDR without tone mapping — watchable but not colour-managed). Proper
/// HDR handling is deferred until a tone-mapping consumer exists.
enum YuvColorMatrix { bt601, bt709, bt2020 }

/// A decoded frame. Backends may return CPU bytes or GPU handles depending on
/// [DecoderConfig.requestGpuOutput].
abstract class DecodedFrame {
  int get width;
  int get height;
  int get ptsUs;

  /// Backend-specific accessor: returns CPU bytes if available.
  /// May trigger GPU→CPU readback if the frame is GPU-resident.
  Future<List<int>> readBytes();

  /// Planar layout of the bytes from [readBytes]. Defaults to [i420]; a software
  /// decoder that produced 4:2:2 / 4:4:4 / 10-bit output MUST override this so
  /// the presenter picks the right converter. Ignored for GPU/browser frames.
  DecodedPixelLayout get pixelLayout => DecodedPixelLayout.i420;

  /// Whether the [readBytes] YUV uses full (JPEG, `yuvj*`) range rather than the
  /// default studio/limited range. Selects the converter's coefficient set.
  bool get isFullRange => false;

  /// YCbCr→RGB matrix of the [readBytes] YUV (see [YuvColorMatrix] for the
  /// default-to-bt601 rationale). Ignored for GPU/browser frames.
  YuvColorMatrix get colorMatrix => YuvColorMatrix.bt601;

  /// An already-presentable browser frame handle (a WebCodecs `VideoFrame`,
  /// as an opaque `Object` so this interface stays platform-neutral), or
  /// `null` when the frame is CPU/GPU-plane data ([readBytes]). The web
  /// backend returns the JS `VideoFrame` here so consumers can present it
  /// directly (browser already decoded it to a displayable surface) instead
  /// of reading back planes. Consumers that use this MUST [close] the frame.
  Object? get webVideoFrame => null;

  /// The output surface kind (mirror of [FrameSource] on the encode side).
  /// Defaults to [FrameSourceKind.cpu]; a hardware decoder that keeps the frame
  /// GPU-resident reports e.g. [FrameSourceKind.d3d11Texture] here so the
  /// consumer imports [gpuHandle] straight into its present device with no CPU
  /// readback. Software decoders leave this `cpu` and serve [readBytes].
  FrameSourceKind get outputKind => FrameSourceKind.cpu;

  /// Native GPU handle when [outputKind] is a GPU surface: the `ID3D11Texture2D*`
  /// (d3d11Texture), `CVPixelBufferRef` (cvPixelBuffer), dmabuf fd, etc., as an
  /// integer pointer. `0` when the frame is CPU-resident. The consumer imports
  /// this into its own present/upload path; ownership stays with the frame
  /// until [close]. For a D3D11 texture array, see [subresourceIndex].
  ///
  /// LIFETIME CONTRACT: this handle points at a decoder-owned pool slot that the
  /// decoder MUST NOT recycle while any consumer (the present device, a
  /// colour-convert pass, a cross-isolate hold) is still reading it. A HW decoder
  /// enforces this with a [GpuHandleLease] (refcount): the frame keeps one hold,
  /// each extra consumer `retain()`s and `release()`s, and the slot is recycled
  /// only when the last hold drops. [close] releases the frame's own hold.
  int get gpuHandle => 0;

  /// Subresource index into a [gpuHandle] D3D11 texture array (decoders often
  /// hand back a pool slot). `0` for single textures / non-D3D11.
  int get subresourceIndex => 0;

  /// Release the decoded frame. Always call when done.
  void close();
}

/// Abstract audio decoder. Backends return a concrete subclass from
/// [MiniAVToolsBackend.createAudioDecoder].
///
/// Lifecycle:
///   create → decode* → flush → close
abstract class PlatformAudioDecoder {
  /// Submit one encoded packet. Returns zero or more decoded chunks — one
  /// packet may decode to several codec frames (or none while buffering).
  Future<List<DecodedAudio>> decode(EncodedPacket packet);

  /// Drain any internally buffered samples at end-of-stream.
  Future<List<DecodedAudio>> flush();

  /// Release decoder resources.
  Future<void> close();
}

/// A chunk of decoded PCM audio.
///
/// Samples are **interleaved float32** in [-1, 1] — the one canonical layout
/// every consumer here (miniaudio `StreamPlayer`, mixers, encoders) accepts —
/// regardless of the codec's internal sample format. [sampleRate] and
/// [channels] describe the stream as the *decoder* discovered it (from the
/// bitstream / extradata), which may differ from any hint in
/// [AudioDecoderConfig]; consumers must follow the frame, not the config.
class DecodedAudio {
  /// Interleaved f32 samples; length == `frameCount * channels`.
  final Float32List samples;

  /// Samples per channel in [samples].
  final int frameCount;

  final int sampleRate;
  final int channels;

  /// Presentation timestamp of the FIRST sample, microseconds.
  final int ptsUs;

  const DecodedAudio({
    required this.samples,
    required this.frameCount,
    required this.sampleRate,
    required this.channels,
    required this.ptsUs,
  });

  /// Duration of this chunk in microseconds.
  int get durationUs =>
      sampleRate == 0 ? 0 : (frameCount * 1000000) ~/ sampleRate;
}

/// Abstract container muxer.
///
/// Lifecycle:
///   create → writeHeader → writePacket* → finish → close
abstract class PlatformMuxer {
  /// Write the container header. Must be called once before any packets.
  /// Track [extraData] from [TrackInfo] is consulted here.
  Future<void> writeHeader();

  /// Write one encoded packet. Packets must be in DTS order per track but
  /// may be interleaved across tracks.
  Future<void> writePacket(EncodedPacket packet);

  /// Finalise the container (write trailing index, MOOV, etc.).
  /// For [BytesMuxerOutput], retrieve the bytes via [getBytes] after calling.
  Future<void> finish();

  /// Only valid for [BytesMuxerOutput].
  List<int>? getBytes() => null;

  /// Release muxer resources.
  Future<void> close();
}

/// Abstract container demuxer.
///
/// Lifecycle:
///   create → trackInfos (probe) → readPacket* → close
abstract class PlatformDemuxer {
  /// Tracks discovered by probing the input. Available after construction.
  ///
  /// `EncodedPacket.trackIndex` on packets returned by [readPacket] indexes
  /// into THIS list (container streams with unsupported codecs are skipped
  /// and their packets dropped).
  List<TrackInfo> get tracks;

  /// Read the next packet from any track. Returns `null` at EOF.
  Future<EncodedPacket?> readPacket();

  /// Seek to the given timestamp (microseconds). Some containers/codecs only
  /// support keyframe-accurate seeking. Throws on non-seekable inputs
  /// (live byte streams) — check [isSeekable].
  Future<void> seek(int timestampUs);

  /// Container duration in microseconds, or `null` when unknown (live
  /// streams). Default: unknown.
  int? get durationUs => null;

  /// Whether [seek] is supported by this input. Default: false.
  bool get isSeekable => false;

  /// Release demuxer resources.
  Future<void> close();
}
