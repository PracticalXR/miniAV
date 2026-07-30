/// Universal GPU codec pipeline abstraction.
///
/// Wraps `gpu_pipeline.Pipeline` so that a *codec* (MJPEG, future MotionJPEG-2K,
/// future GPU-driven WebP-lite, future NVENC bridge, …) is expressed as a
/// **stage graph** rather than a bespoke `PlatformEncoder` implementation.
///
/// ## Contract
///
/// A subclass of [GpuCodecPipeline] must:
///
/// 1. Build a `gpu_pipeline.Pipeline` whose first stage takes a single tensor
///    input named [kFrameInputKey] holding **interleaved RGBA bytes uploaded
///    as Float32** values in `[0, 255]`, with shape `[H, W, 4]`.
/// 2. Produce a final stage output tensor named [kEncodedOutputKey] with
///    `BufferDataType.uint8` and shape `[N]` — the encoded bitstream for
///    that frame.
/// 3. Override [isKeyframe] to declare per-packet keyframe status. (For
///    intra-only codecs like MJPEG this is always `true`.)
/// 4. Optionally override [extraData] (codec-private bytes for muxers).
///
/// The [GpuCodecEncoder] adapter wraps any [GpuCodecPipeline] into a
/// `PlatformEncoder`, handling frame-source dispatch, pts management, and
/// EncodedPacket construction. Adding a new codec is a single new subclass —
/// no new `PlatformEncoder` boilerplate.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:gpu_pipeline/gpu_pipeline.dart';
import 'package:gpu_tensor/gpu_tensor.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart'
    show MiniAVPixelFormat, MiniAVVideoBuffer;
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:minigpu/minigpu.dart' show Buffer;
import 'package:minigpu_platform_interface/minigpu_platform_interface.dart'
    show BufferDataType;

/// Tensor key the abstraction expects on the input stage.
const String kFrameInputKey = 'frame';

/// Tensor key the abstraction expects on the terminal stage.
const String kEncodedOutputKey = 'encoded';

/// Subclasses define a stage graph that turns one RGBA frame into an encoded
/// byte stream. Lifecycle is owned by [GpuCodecEncoder].
abstract class GpuCodecPipeline {
  GpuCodecPipeline({required this.config});

  /// Encoder configuration this pipeline was built for. Subclasses use this
  /// to size buffers, pick quantization tables, etc.
  final EncoderConfig config;

  /// Lazily-built underlying pipeline.
  Pipeline? _pipeline;
  Future<void>? _building;

  /// Subclass hook: build the gpu_pipeline.Pipeline. Called exactly once
  /// (lazily, on first encode). Implementations:
  ///   - call [Pipeline] constructor
  ///   - add stages whose first input port is [kFrameInputKey]
  ///   - whose final output port is [kEncodedOutputKey] (uint8 tensor)
  ///   - call `await pipeline.start()` themselves if needed
  Future<Pipeline> buildPipeline();

  /// Per-packet keyframe flag (defaults to `true`: most GPU-friendly codecs
  /// here are intra-only).
  bool isKeyframe(int frameIndex) => true;

  /// Hook: the host requested that the next encoded frame be a keyframe.
  /// Inter-capable pipelines override this to force an intra refresh and
  /// reset their reference state. Default: no-op (intra-only pipelines emit
  /// keyframes every frame anyway).
  void onKeyframeRequested() {}

  /// Codec-private extras (e.g. JFIF tail bytes for MJPEG; SPS/PPS for
  /// future GPU H.264). Default: none.
  CodecExtraData? get extraData => null;

  /// Internal: lazily start the underlying pipeline.
  Future<Pipeline> _ensure() async {
    if (_pipeline != null) return _pipeline!;
    _building ??= () async {
      final p = await buildPipeline();
      _pipeline = p;
    }();
    await _building;
    return _pipeline!;
  }

  /// If `true`, the encoder adapter uploads pixel bytes as a
  /// `BufferDataType.uint32` tensor of shape `[height, width]` where each
  /// `u32` packs one RGBA pixel in native little-endian byte order (R in
  /// byte 0, A in byte 3 — i.e. the layout of `Uint8List.buffer.asUint32List()`).
  /// This skips the per-pixel `u8 → f32` conversion (8 M iterations at 1080p)
  /// and quarters the GPU upload size. The pipeline's first stage must
  /// declare its input binding as `array<u32>` and use `unpack4x8unorm`.
  bool get acceptsPackedRgba8 => false;

  /// Width of the buffer the pipeline actually wants to receive. Subclasses
  /// whose internal stages require dimensional alignment (e.g. AV1 needs
  /// multiples of 64 to walk the partition tree to 64×64 superblocks) can
  /// override this to a padded value. The encoder adapter pads the input
  /// frame to these dims before upload. Display/decode crop is the
  /// pipeline's responsibility (e.g. via AV1 render_size).
  int get codedWidth => config.width;
  int get codedHeight => config.height;

  /// Run one frame through the pipeline. Returns the encoded byte stream
  /// for that frame, or `null` if the pipeline buffered (rare for intra
  /// codecs; reserved for future GPU codecs with lookahead).
  Future<Uint8List?> runOneFrameInternal(
    Tensor input, {
    void Function(double)? runOnceMs,
    void Function(double)? downloadMs,
  }) async {
    final p = await _ensure();
    final tRun = Stopwatch()..start();
    final outputs = await p.runOnce({kFrameInputKey: input});
    tRun.stop();
    runOnceMs?.call(tRun.elapsedMicroseconds / 1000.0);
    final encoded = outputs[kEncodedOutputKey];
    if (encoded == null) {
      throw CodecRuntimeException(
        'minigpu',
        'pipeline produced no "$kEncodedOutputKey" output (saw '
            '${outputs.keys.toList()})',
      );
    }
    final tDl = Stopwatch()..start();
    final bytes = await encoded.getData();
    tDl.stop();
    downloadMs?.call(tDl.elapsedMicroseconds / 1000.0);
    // The pipeline's CPU stage uploads outputs as Float32 tensors (one float
    // per byte), so we materialise them back to a tight Uint8List here.
    if (bytes is Float32List) {
      final out = Uint8List(bytes.length);
      for (var i = 0; i < bytes.length; i++) {
        final v = bytes[i];
        out[i] = v <= 0 ? 0 : (v >= 255 ? 255 : v.round());
      }
      return out;
    } else if (bytes is Uint8List) {
      return Uint8List(bytes.length)..setAll(0, bytes);
    } else {
      throw CodecRuntimeException(
        'minigpu',
        'pipeline produced unsupported encoded type ${bytes.runtimeType}',
      );
    }
  }

  /// GPU-buffer fast path: run one frame starting from an already-materialised
  /// GPU [buf] containing packed RGBA8 pixels (one `u32` per pixel, layout
  /// `[height, width]`).  The buffer is **borrowed** — the pipeline must not
  /// destroy it.  The buffer must contain at least [width]×[height] u32 values
  /// and [width]/[height] must match the pipeline's coded dimensions.
  ///
  /// The default implementation returns `null` (not supported); subclasses
  /// that support zero-copy GPU input should override this.
  Future<Uint8List?> runOneFrameFromGpuBuffer(
    Buffer buf,
    int width,
    int height,
  ) async => null;

  /// Fast path: if a subclass can produce the encoded bytes for [frameIndex]
  /// **without any GPU work** (e.g. constant-output baselines, all-skip
  /// intra-only AV1 placeholder paths), it may override this to return the
  /// bytes directly. The adapter will then skip the per-frame
  /// `Tensor.create + write + destroy` and pipeline dispatch entirely,
  /// which on Windows/Dawn saves an O(ms) GPU round-trip per frame.
  ///
  /// Return `null` to fall back to the normal GPU pipeline.
  Future<Uint8List?> encodeFast(int frameIndex) async => null;

  /// Drain any internally buffered packets at end-of-stream. Default: none
  /// (intra-only codec).
  Future<List<Uint8List>> _flushFrames() async => const [];

  /// Release the underlying pipeline + GPU resources.
  Future<void> _close() async {
    final p = _pipeline;
    _pipeline = null;
    if (p != null) {
      await p.stop();
    }
  }
}

/// Adapter: turns any [GpuCodecPipeline] into a [PlatformEncoder].
///
/// Backends construct one of these per `createEncoder()` call:
/// ```dart
/// return GpuCodecEncoder(MinigpuMjpegPipeline(config));
/// ```
class GpuCodecEncoder implements PlatformEncoder {
  GpuCodecEncoder(this._pipeline);

  final GpuCodecPipeline _pipeline;
  bool _closed = false;
  int _frameIndex = 0;
  int _nextFrameIndexForFlush = 0;

  /// The underlying codec pipeline. Exposed so tests and dev tools can
  /// introspect codec-specific intermediate state (e.g. captured YUV
  /// buffers). Production code generally interacts with the encoder via
  /// [PlatformEncoder] and does not need this.
  GpuCodecPipeline get pipeline => _pipeline;

  /// Last frame timing breakdown (ms) for benchmarks.
  double get lastUploadMs => _lastUploadMs;
  double _lastUploadMs = 0;
  double get lastRunOnceMs => _lastRunOnceMs;
  double _lastRunOnceMs = 0;
  double get lastDownloadMs => _lastDownloadMs;
  double _lastDownloadMs = 0;

  EncoderConfig get _cfg => _pipeline.config;

  @override
  CodecExtraData? get extraData => _pipeline.extraData;

  @override
  bool get supportsGpuBufferInput => true;

  // Consumes packed-RGBA8 GPU buffers (encodeFromGpuBuffer), not YUV420P planes.
  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  Future<void> requestKeyframe() async {
    _pipeline.onKeyframeRequested();
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _checkOpen();
    // Fast path: pipelines that don't actually need pixel data (e.g. all-skip
    // AV1 placeholder mode) can supply the encoded bytes directly, bypassing
    // the per-frame GPU upload + dispatch + read-back. This is the biggest
    // single optimisation for the AV1 intra-only baseline on Windows/Dawn,
    // where each read-back costs an OS timer tick (~1-15ms) regardless of
    // payload size.
    final fastBytes = await _pipeline.encodeFast(_frameIndex);
    if (fastBytes != null) {
      final pts = _ptsForFrame(_frameIndex, frame.timestampUs);
      final pkt = EncodedPacket(
        data: fastBytes,
        ptsUs: pts,
        dtsUs: pts,
        durationUs: _frameDurationUs,
        isKeyframe: _pipeline.isKeyframe(_frameIndex),
      );
      _frameIndex++;
      return pkt;
    }
    final rgba = _frameToRgba(frame);
    // Upload at the *display* (config) dims. The pipeline's first GPU stage
    // (RGBA→YUV) edge-extends from these source dims to the coded
    // (64-aligned) dims internally, so no CPU pad + re-upload is needed and
    // the CPU and GPU-buffer paths share identical input layout.
    final w = _cfg.width;
    final h = _cfg.height;
    final tUp = Stopwatch()..start();
    final Tensor input;
    if (_pipeline.acceptsPackedRgba8) {
      // Zero-copy reinterpret: the Uint8List RGBA buffer becomes an array
      // of u32s (4 bytes per pixel). One GPU upload of width*height*4 bytes,
      // no per-element conversion.
      final packed = rgba.buffer.asUint32List(
        rgba.offsetInBytes,
        rgba.lengthInBytes >> 2,
      );
      final t = await Tensor.create<Uint32List>([
        h,
        w,
      ], dataType: BufferDataType.uint32);
      await t.write(packed);
      input = t;
    } else {
      final t = await Tensor.create<Float32List>([
        h,
        w,
        4,
      ], dataType: BufferDataType.float32);
      final asFloat = Float32List(rgba.length);
      for (var i = 0; i < rgba.length; i++) {
        asFloat[i] = rgba[i].toDouble();
      }
      await t.write(asFloat);
      input = t;
    }
    tUp.stop();
    _lastUploadMs = tUp.elapsedMicroseconds / 1000.0;
    try {
      final bytes = await _pipeline.runOneFrameInternal(
        input,
        runOnceMs: (ms) => _lastRunOnceMs = ms,
        downloadMs: (ms) => _lastDownloadMs = ms,
      );
      if (bytes == null) return null;
      final pts = _ptsForFrame(_frameIndex, frame.timestampUs);
      final pkt = EncodedPacket(
        data: bytes,
        ptsUs: pts,
        dtsUs: pts,
        durationUs: _frameDurationUs,
        isKeyframe: _pipeline.isKeyframe(_frameIndex),
      );
      _frameIndex++;
      return pkt;
    } finally {
      input.destroy();
    }
  }

  /// Encode one frame directly from an already-materialised GPU buffer of
  /// packed RGBA8 pixels (one `u32` per pixel).  Skips CPU read-back and GPU
  /// re-upload entirely.
  ///
  /// Returns `null` if the underlying pipeline does not support the GPU buffer
  /// path (i.e. [GpuCodecPipeline.runOneFrameFromGpuBuffer] returned `null`).
  Future<EncodedPacket?> encodeFromGpuBuffer(
    Buffer srcRgba,
    int width,
    int height, {
    int? timestampUs,
  }) async {
    _checkOpen();
    // Honor the fast path (e.g. all-skip placeholder that doesn't need pixels).
    final fastBytes = await _pipeline.encodeFast(_frameIndex);
    if (fastBytes != null) {
      final pts = _ptsForFrame(_frameIndex, timestampUs);
      final pkt = EncodedPacket(
        data: fastBytes,
        ptsUs: pts,
        dtsUs: pts,
        durationUs: _frameDurationUs,
        isKeyframe: _pipeline.isKeyframe(_frameIndex),
      );
      _frameIndex++;
      return pkt;
    }
    final bytes = await _pipeline.runOneFrameFromGpuBuffer(
      srcRgba,
      width,
      height,
    );
    if (bytes == null) return null;
    final pts = _ptsForFrame(_frameIndex, timestampUs);
    final pkt = EncodedPacket(
      data: bytes,
      ptsUs: pts,
      dtsUs: pts,
      durationUs: _frameDurationUs,
      isKeyframe: _pipeline.isKeyframe(_frameIndex),
    );
    _frameIndex++;
    return pkt;
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final frames = await _pipeline._flushFrames();
    final out = <EncodedPacket>[];
    for (final bytes in frames) {
      final i = _nextFrameIndexForFlush++;
      final pts = _ptsForFrame(i, null);
      out.add(
        EncodedPacket(
          data: bytes,
          ptsUs: pts,
          dtsUs: pts,
          durationUs: _frameDurationUs,
          isKeyframe: _pipeline.isKeyframe(i),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _pipeline._close();
  }

  // --- helpers -------------------------------------------------------------

  void _checkOpen() {
    if (_closed) {
      throw const CodecRuntimeException('minigpu', 'encoder closed');
    }
  }

  int get _frameDurationUs =>
      (1000000 * _cfg.frameRateDenominator) ~/ _cfg.frameRateNumerator;

  int _ptsForFrame(int frameIndex, int? sourceTsUs) {
    if (sourceTsUs != null && sourceTsUs > 0) return sourceTsUs;
    return frameIndex * _frameDurationUs;
  }

  /// Always materialise an RGBA byte buffer of size `width*height*4` for
  /// the GPU upload. Pixel format conversion lives here so subclasses can
  /// rely on a uniform input layout.
  Uint8List _frameToRgba(FrameSource src) {
    switch (src) {
      case CpuFrameSource():
        return _convertToRgba(
          bytes: src.bytes,
          format: src.pixelFormat,
          width: src.width,
          height: src.height,
        );
      case MiniAVBufferSource():
        final buf = src.buffer.data;
        if (buf is! MiniAVVideoBuffer) {
          throw const CodecRuntimeException(
            'minigpu',
            'GpuCodecEncoder expects video buffers',
          );
        }
        // Multi-plane formats (NV12, NV21, I420, YV12) need every plane
        // and per-plane strides — dispatch before the single-plane path.
        switch (buf.pixelFormat) {
          case MiniAVPixelFormat.nv12:
          case MiniAVPixelFormat.nv21:
            return _nv12LikeToRgba(
              buf,
              swapUV: buf.pixelFormat == MiniAVPixelFormat.nv21,
            );
          case MiniAVPixelFormat.i420:
          case MiniAVPixelFormat.yv12:
            return _i420LikeToRgba(
              buf,
              swapUV: buf.pixelFormat == MiniAVPixelFormat.yv12,
            );
          default:
            break;
        }
        final plane0 = buf.planes.isNotEmpty ? buf.planes[0] : null;
        if (plane0 == null) {
          throw const CodecRuntimeException(
            'minigpu',
            'GpuCodecEncoder MVP only accepts CPU-backed MiniAV buffers '
                '(plane[0] was null — likely a GPU buffer; zero-copy import '
                'is a follow-up)',
          );
        }
        final stride0 = buf.strideBytes.isNotEmpty ? buf.strideBytes[0] : 0;
        return _convertToRgba(
          bytes: plane0,
          format: buf.pixelFormat,
          width: buf.width,
          height: buf.height,
          stride: stride0,
        );
      default:
        throw CodecRuntimeException(
          'minigpu',
          'Unsupported FrameSource: ${src.runtimeType}',
        );
    }
  }
}

/// Convert any of the supported MiniAV pixel formats to interleaved RGBA8.
/// Kept private to this file — codecs share one canonical input layout.
///
/// [stride] is the bytes per row in [bytes]. Pass `0` (or any value `<=` the
/// natural row width for the format) to assume tightly packed.
Uint8List _convertToRgba({
  required Uint8List bytes,
  required MiniAVPixelFormat format,
  required int width,
  required int height,
  int stride = 0,
}) {
  final n = width * height;
  final out = Uint8List(n * 4);
  // Single-plane natural row widths.
  int rowBytes;
  switch (format) {
    case MiniAVPixelFormat.rgba32:
    case MiniAVPixelFormat.bgra32:
    case MiniAVPixelFormat.argb32:
    case MiniAVPixelFormat.abgr32:
    case MiniAVPixelFormat.rgbx32:
    case MiniAVPixelFormat.bgrx32:
    case MiniAVPixelFormat.xrgb32:
    case MiniAVPixelFormat.xbgr32:
      rowBytes = width * 4;
      break;
    case MiniAVPixelFormat.rgb24:
    case MiniAVPixelFormat.bgr24:
      rowBytes = width * 3;
      break;
    case MiniAVPixelFormat.yuy2:
    case MiniAVPixelFormat.uyvy:
      rowBytes = width * 2;
      break;
    case MiniAVPixelFormat.gray8:
      rowBytes = width;
      break;
    default:
      rowBytes = 0;
  }
  final rs = (stride > rowBytes) ? stride : rowBytes;

  switch (format) {
    case MiniAVPixelFormat.rgba32:
      if (rs == width * 4) {
        out.setRange(0, n * 4, bytes);
      } else {
        for (var y = 0; y < height; y++) {
          out.setRange(y * width * 4, (y + 1) * width * 4, bytes, y * rs);
        }
      }
      return out;
    case MiniAVPixelFormat.bgra32:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          out[di + x * 4 + 0] = bytes[si + x * 4 + 2];
          out[di + x * 4 + 1] = bytes[si + x * 4 + 1];
          out[di + x * 4 + 2] = bytes[si + x * 4 + 0];
          out[di + x * 4 + 3] = bytes[si + x * 4 + 3];
        }
      }
      return out;
    case MiniAVPixelFormat.argb32:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          out[di + x * 4 + 0] = bytes[si + x * 4 + 1];
          out[di + x * 4 + 1] = bytes[si + x * 4 + 2];
          out[di + x * 4 + 2] = bytes[si + x * 4 + 3];
          out[di + x * 4 + 3] = bytes[si + x * 4 + 0];
        }
      }
      return out;
    case MiniAVPixelFormat.abgr32:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          out[di + x * 4 + 0] = bytes[si + x * 4 + 3];
          out[di + x * 4 + 1] = bytes[si + x * 4 + 2];
          out[di + x * 4 + 2] = bytes[si + x * 4 + 1];
          out[di + x * 4 + 3] = bytes[si + x * 4 + 0];
        }
      }
      return out;
    case MiniAVPixelFormat.rgbx32:
    case MiniAVPixelFormat.xbgr32:
      // RGBX: RGB in first three bytes; XBGR: BGR in last three bytes
      // (X in byte 0). For now treat rgbx as straight RGB+opaque alpha.
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        final isXbgr = format == MiniAVPixelFormat.xbgr32;
        for (var x = 0; x < width; x++) {
          if (isXbgr) {
            out[di + x * 4 + 0] = bytes[si + x * 4 + 3];
            out[di + x * 4 + 1] = bytes[si + x * 4 + 2];
            out[di + x * 4 + 2] = bytes[si + x * 4 + 1];
          } else {
            out[di + x * 4 + 0] = bytes[si + x * 4 + 0];
            out[di + x * 4 + 1] = bytes[si + x * 4 + 1];
            out[di + x * 4 + 2] = bytes[si + x * 4 + 2];
          }
          out[di + x * 4 + 3] = 0xff;
        }
      }
      return out;
    case MiniAVPixelFormat.bgrx32:
    case MiniAVPixelFormat.xrgb32:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        final isXrgb = format == MiniAVPixelFormat.xrgb32;
        for (var x = 0; x < width; x++) {
          if (isXrgb) {
            out[di + x * 4 + 0] = bytes[si + x * 4 + 1];
            out[di + x * 4 + 1] = bytes[si + x * 4 + 2];
            out[di + x * 4 + 2] = bytes[si + x * 4 + 3];
          } else {
            out[di + x * 4 + 0] = bytes[si + x * 4 + 2];
            out[di + x * 4 + 1] = bytes[si + x * 4 + 1];
            out[di + x * 4 + 2] = bytes[si + x * 4 + 0];
          }
          out[di + x * 4 + 3] = 0xff;
        }
      }
      return out;
    case MiniAVPixelFormat.rgb24:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          out[di + x * 4 + 0] = bytes[si + x * 3 + 0];
          out[di + x * 4 + 1] = bytes[si + x * 3 + 1];
          out[di + x * 4 + 2] = bytes[si + x * 3 + 2];
          out[di + x * 4 + 3] = 0xff;
        }
      }
      return out;
    case MiniAVPixelFormat.bgr24:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          out[di + x * 4 + 0] = bytes[si + x * 3 + 2];
          out[di + x * 4 + 1] = bytes[si + x * 3 + 1];
          out[di + x * 4 + 2] = bytes[si + x * 3 + 0];
          out[di + x * 4 + 3] = 0xff;
        }
      }
      return out;
    case MiniAVPixelFormat.gray8:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x++) {
          final g = bytes[si + x];
          out[di + x * 4 + 0] = g;
          out[di + x * 4 + 1] = g;
          out[di + x * 4 + 2] = g;
          out[di + x * 4 + 3] = 0xff;
        }
      }
      return out;
    case MiniAVPixelFormat.yuy2:
      // YUYV macropixel covers two pixels: Y0 U Y1 V (BT.601 limited).
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x += 2) {
          final y0 = bytes[si + x * 2 + 0];
          final u = bytes[si + x * 2 + 1];
          final y1 = bytes[si + x * 2 + 2];
          final v = bytes[si + x * 2 + 3];
          _yuv601LimitedToRgba(out, di + x * 4, y0, u, v);
          _yuv601LimitedToRgba(out, di + (x + 1) * 4, y1, u, v);
        }
      }
      return out;
    case MiniAVPixelFormat.uyvy:
      for (var y = 0; y < height; y++) {
        final si = y * rs;
        final di = y * width * 4;
        for (var x = 0; x < width; x += 2) {
          final u = bytes[si + x * 2 + 0];
          final y0 = bytes[si + x * 2 + 1];
          final v = bytes[si + x * 2 + 2];
          final y1 = bytes[si + x * 2 + 3];
          _yuv601LimitedToRgba(out, di + x * 4, y0, u, v);
          _yuv601LimitedToRgba(out, di + (x + 1) * 4, y1, u, v);
        }
      }
      return out;
    default:
      throw CodecRuntimeException(
        'minigpu',
        'GpuCodecEncoder: pixel format $format not supported by the '
            'shared RGBA upload path',
      );
  }
}

/// NV12 / NV21 → RGBA8. Plane 0 is Y (stride0), plane 1 is interleaved
/// UV (NV12) or VU (NV21) at half width × half height.
Uint8List _nv12LikeToRgba(MiniAVVideoBuffer buf, {required bool swapUV}) {
  final w = buf.width;
  final h = buf.height;
  final yPlane = buf.planes.isNotEmpty ? buf.planes[0] : null;
  final uvPlane = buf.planes.length > 1 ? buf.planes[1] : null;
  if (yPlane == null || uvPlane == null) {
    throw const CodecRuntimeException(
      'minigpu',
      'NV12/NV21 buffer is missing Y or UV plane',
    );
  }
  final ys = buf.strideBytes.isNotEmpty && buf.strideBytes[0] >= w
      ? buf.strideBytes[0]
      : w;
  final uvs = buf.strideBytes.length > 1 && buf.strideBytes[1] >= w
      ? buf.strideBytes[1]
      : w;
  final out = Uint8List(w * h * 4);
  final uOff = swapUV ? 1 : 0;
  final vOff = swapUV ? 0 : 1;
  for (var y = 0; y < h; y++) {
    final yi = y * ys;
    final di = y * w * 4;
    final uvi = (y >> 1) * uvs;
    for (var x = 0; x < w; x++) {
      final yv = yPlane[yi + x];
      final cx = (x >> 1) * 2;
      final u = uvPlane[uvi + cx + uOff];
      final v = uvPlane[uvi + cx + vOff];
      _yuv601LimitedToRgba(out, di + x * 4, yv, u, v);
    }
  }
  return out;
}

/// I420 / YV12 → RGBA8. Three planes: Y, then U then V (I420) or V then U
/// (YV12), each chroma plane at half width × half height.
Uint8List _i420LikeToRgba(MiniAVVideoBuffer buf, {required bool swapUV}) {
  final w = buf.width;
  final h = buf.height;
  if (buf.planes.length < 3) {
    throw const CodecRuntimeException(
      'minigpu',
      'I420/YV12 buffer must have 3 planes',
    );
  }
  final yPlane = buf.planes[0];
  final p1 = buf.planes[1];
  final p2 = buf.planes[2];
  if (yPlane == null || p1 == null || p2 == null) {
    throw const CodecRuntimeException(
      'minigpu',
      'I420/YV12 buffer plane is null',
    );
  }
  final uPlane = swapUV ? p2 : p1;
  final vPlane = swapUV ? p1 : p2;
  final cw = w >> 1;
  final ys = buf.strideBytes.isNotEmpty && buf.strideBytes[0] >= w
      ? buf.strideBytes[0]
      : w;
  final us = buf.strideBytes.length > 1 && buf.strideBytes[1] >= cw
      ? buf.strideBytes[1]
      : cw;
  final vs = buf.strideBytes.length > 2 && buf.strideBytes[2] >= cw
      ? buf.strideBytes[2]
      : cw;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final yi = y * ys;
    final di = y * w * 4;
    final cy = y >> 1;
    final ui = cy * us;
    final vi = cy * vs;
    for (var x = 0; x < w; x++) {
      final cx = x >> 1;
      final yv = yPlane[yi + x];
      final u = uPlane[ui + cx];
      final v = vPlane[vi + cx];
      _yuv601LimitedToRgba(out, di + x * 4, yv, u, v);
    }
  }
  return out;
}

/// BT.601 limited-range YUV → RGB with integer math.
/// Y∈[16,235], U/V∈[16,240]. The matrix is the standard 8-bit accurate
/// libyuv-style approximation.
void _yuv601LimitedToRgba(Uint8List out, int di, int y, int u, int v) {
  final yy = (y - 16) * 298;
  final uu = u - 128;
  final vv = v - 128;
  final r = (yy + 409 * vv + 128) >> 8;
  final g = (yy - 100 * uu - 208 * vv + 128) >> 8;
  final b = (yy + 516 * uu + 128) >> 8;
  out[di + 0] = r < 0 ? 0 : (r > 255 ? 255 : r);
  out[di + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
  out[di + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
  out[di + 3] = 0xff;
}

/// Pad an RGBA8 buffer of [srcWidth]×[srcHeight] to [dstWidth]×[dstHeight]
/// by edge-extending the right column and bottom row. Used to satisfy GPU
/// stages that need dimensional alignment (e.g. AV1's 64×64 superblocks)
/// without changing visible content — the encoder advertises true dims via
/// its bitstream's render_size so the decoder crops.
///
/// NOTE: The AV1 pipeline now edge-extends on the GPU inside the RGBA→YUV
/// stage (see `buildRgba8ToYuv420Bt709LimitedStage`'s `srcWidth`/`srcHeight`),
/// so the encode path uploads display-sized RGBA directly. This helper is
/// retained for other codecs / callers that still need a CPU-side pad.
// ignore: unused_element
Uint8List _padRgbaToCodedDims(
  Uint8List src, {
  required int srcWidth,
  required int srcHeight,
  required int dstWidth,
  required int dstHeight,
}) {
  final out = Uint8List(dstWidth * dstHeight * 4);
  for (var y = 0; y < srcHeight; y++) {
    final si = y * srcWidth * 4;
    final di = y * dstWidth * 4;
    out.setRange(di, di + srcWidth * 4, src, si);
    // edge-extend right.
    final lastR = src[si + (srcWidth - 1) * 4 + 0];
    final lastG = src[si + (srcWidth - 1) * 4 + 1];
    final lastB = src[si + (srcWidth - 1) * 4 + 2];
    final lastA = src[si + (srcWidth - 1) * 4 + 3];
    for (var x = srcWidth; x < dstWidth; x++) {
      final p = di + x * 4;
      out[p + 0] = lastR;
      out[p + 1] = lastG;
      out[p + 2] = lastB;
      out[p + 3] = lastA;
    }
  }
  // edge-extend bottom by copying the last filled row.
  if (srcHeight < dstHeight) {
    final lastRowStart = (srcHeight - 1) * dstWidth * 4;
    final lastRowEnd = lastRowStart + dstWidth * 4;
    for (var y = srcHeight; y < dstHeight; y++) {
      out.setRange(y * dstWidth * 4, (y + 1) * dstWidth * 4, out, lastRowStart);
    }
    // ignore: unused_local_variable
    final _ = lastRowEnd;
  }
  return out;
}
