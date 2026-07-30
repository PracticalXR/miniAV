/// WebCodecs-backed video encoder.
///
/// Wraps the browser `VideoEncoder` API and implements [PlatformEncoder] so
/// it slots into the [MiniAVTools] backend pipeline without changes to the
/// calling code.
///
/// ### Frame input
///
/// | [FrameSource] kind | Behaviour |
/// |---|---|
/// | [FrameSourceKind.webVideoFrame] | Zero-copy: the JS `VideoFrame` is passed directly to `VideoEncoder.encode()`. |
/// | [FrameSourceKind.cpu] | The raw RGBA bytes are wrapped in a `VideoFrame` via an `OffscreenCanvas` + `ImageData.putImageData`. |
/// | anything else | Throws [UnsupportedFrameSourceException]. |
///
/// ### Codec string defaults
///
/// | [VideoCodec] | Default string |
/// |---|---|
/// | h264 | `avc1.42E01E` (Baseline 3.0) |
/// | hevc | `hev1.1.6.L93.B0` (Main Profile L3.1) |
/// | vp8 | `vp8` |
/// | vp9 | `vp09.00.10.08` (Profile 0, L1.0, 8-bit) |
/// | av1 | `av01.0.04M.08` (Main, L2.0, 8-bit) |
///
/// Override via `EncoderConfig.backendOptions['codecString']`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'web_backend.dart';

// ---------------------------------------------------------------------------
// Codec string helpers
// ---------------------------------------------------------------------------

String _toWebCodecsString(VideoCodec codec, Map<String, String> opts) {
  if (opts.containsKey('codecString')) return opts['codecString']!;
  return switch (codec) {
    VideoCodec.h264 => 'avc1.42E01E',
    VideoCodec.hevc => 'hev1.1.6.L93.B0',
    VideoCodec.vp8 => 'vp8',
    VideoCodec.vp9 => 'vp09.00.10.08',
    VideoCodec.av1 => 'av01.0.04M.08',
    _ => throw UnsupportedError(
      'WebCodecs: no default codec string for $codec. '
      "Supply one via backendOptions['codecString'].",
    ),
  };
}

// ---------------------------------------------------------------------------
// WebCodecsVideoEncoder
// ---------------------------------------------------------------------------

/// [PlatformEncoder] backed by the browser `VideoEncoder` API.
///
/// Do not construct directly — use [WebCodecsVideoEncoder.create].
class WebCodecsVideoEncoder implements PlatformEncoder {
  WebCodecsVideoEncoder._({required VideoCodec codec}) : _codec = codec;

  final VideoCodec _codec;
  web.VideoEncoder? _nativeEncoder;
  final List<EncodedPacket> _pending = [];
  CodecExtraData? _extraData;
  Object? _lastError;
  bool _nextKeyframe = false;

  @override
  CodecExtraData? get extraData => _extraData;

  // -------------------------------------------------------------------------
  // JS callbacks
  // -------------------------------------------------------------------------

  void _handleChunk(JSAny? chunkJs, JSAny? metaJs) {
    if (chunkJs == null || chunkJs.isUndefined) return;
    final chunk = chunkJs as web.EncodedVideoChunk;

    final bytes = Uint8List(chunk.byteLength);
    chunk.copyTo(bytes.buffer.toJS);

    // Try to extract codec-private data (avcC/hvcC) from the first IDR's
    // metadata. `EncodedVideoChunkMetadata` is available as a JSObject even
    // if not typed — access via property bag.
    if (_extraData == null && metaJs != null && !metaJs.isUndefined) {
      try {
        final meta = metaJs as JSObject;
        final dc = meta.getProperty<JSAny?>('decoderConfig'.toJS);
        if (dc != null && !dc.isUndefined) {
          final desc = (dc as JSObject).getProperty<JSAny?>('description'.toJS);
          if (desc != null && !desc.isUndefined) {
            final buf = desc as JSArrayBuffer;
            final descBytes = buf.toDart.asUint8List();
            if (descBytes.isNotEmpty) {
              _extraData = CodecExtraData.video(
                _codec,
                Uint8List.fromList(descBytes),
              );
            }
          }
        }
      } catch (_) {
        // Metadata not available in this browser — skip extraData.
      }
    }

    final tsUs = chunk.timestamp.toInt();
    _pending.add(
      EncodedPacket(
        data: bytes,
        ptsUs: tsUs,
        dtsUs: tsUs,
        isKeyframe: chunk.type == 'key',
        trackIndex: 0,
      ),
    );
  }

  void _handleError(JSAny? errJs) => _lastError = errJs;

  // -------------------------------------------------------------------------
  // PlatformEncoder interface
  // -------------------------------------------------------------------------

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _throwIfError();
    final enc = _nativeEncoder;
    if (enc == null) throw StateError('WebCodecsVideoEncoder: not open');

    final vf = _buildVideoFrame(frame);
    final ownFrame = frame is! WebVideoFrameSource;
    enc.encode(vf, web.VideoEncoderEncodeOptions(keyFrame: _nextKeyframe));
    _nextKeyframe = false;
    if (ownFrame) vf.close();

    await enc.flush().toDart;
    return _pending.isEmpty ? null : _pending.removeAt(0);
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    if (_nativeEncoder == null) return const [];
    await _nativeEncoder!.flush().toDart;
    final result = List<EncodedPacket>.unmodifiable(_pending);
    _pending.clear();
    return result;
  }

  @override
  Future<void> requestKeyframe() async => _nextKeyframe = true;

  // WebCodecs consumes VideoFrames (FrameSource.webVideoFrame / cpu), not GPU
  // storage buffers or pre-converted YUV420P planes.
  @override
  bool get supportsGpuBufferInput => false;

  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  Future<void> close() async {
    try {
      _nativeEncoder?.close();
    } catch (_) {}
    _nativeEncoder = null;
    _pending.clear();
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  web.VideoFrame _buildVideoFrame(FrameSource frame) {
    if (frame is WebVideoFrameSource) {
      return frame.videoFrame as web.VideoFrame;
    }
    if (frame is CpuFrameSource) {
      return _cpuToVideoFrame(frame);
    }
    throw UnsupportedFrameSourceException(
      WebCodecsBackend.backendName,
      'Unsupported FrameSourceKind: ${frame.kind}. '
      'WebCodecsVideoEncoder accepts cpu and webVideoFrame only.',
    );
  }

  /// Wraps raw RGBA bytes in a `VideoFrame` via `OffscreenCanvas`.
  web.VideoFrame _cpuToVideoFrame(CpuFrameSource frame) {
    final canvas = web.OffscreenCanvas(frame.width, frame.height);
    final ctx =
        canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D;

    final clamped = Uint8ClampedList.fromList(frame.bytes);
    final imageData = web.ImageData(
      clamped.toJS,
      frame.width,
      frame.height.toJS,
    );
    ctx.putImageData(imageData, 0, 0);

    return web.VideoFrame(
      canvas,
      web.VideoFrameInit(timestamp: frame.timestampUs),
    );
  }

  void _throwIfError() {
    final e = _lastError;
    if (e != null) {
      throw CodecRuntimeException(WebCodecsBackend.backendName, e.toString());
    }
  }

  // -------------------------------------------------------------------------
  // Factory
  // -------------------------------------------------------------------------

  /// Create and configure a [WebCodecsVideoEncoder] from an [EncoderConfig].
  static Future<WebCodecsVideoEncoder> create(EncoderConfig config) async {
    final enc = WebCodecsVideoEncoder._(codec: config.codec);
    final codecStr = _toWebCodecsString(config.codec, config.backendOptions);
    final fps = config.frameRateNumerator / config.frameRateDenominator;

    enc._nativeEncoder = web.VideoEncoder(
      web.VideoEncoderInit(
        output: (JSAny? chunk, JSAny? meta) {
          enc._handleChunk(chunk, meta);
        }.toJS,
        error: (JSAny? err) {
          enc._handleError(err);
        }.toJS,
      ),
    );

    enc._nativeEncoder!.configure(
      web.VideoEncoderConfig(
        codec: codecStr,
        width: config.width,
        height: config.height,
        bitrate: config.bitrateBps,
        framerate: fps,
        latencyMode: 'realtime',
      ),
    );

    await enc._nativeEncoder!.flush().toDart;
    enc._throwIfError();

    return enc;
  }
}
