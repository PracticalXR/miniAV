/// WebCodecs-backed video decoder.
///
/// Wraps the browser `VideoDecoder` API and implements [PlatformDecoder]. The
/// browser decodes each [EncodedPacket] to a `VideoFrame` that is ALREADY a
/// displayable surface (GPU-backed when the decode is hardware), so the
/// decoded frame is surfaced via [DecodedFrame.webVideoFrame] and presented
/// directly — no YUV→RGBA readback/convert (unlike the native FFmpeg path).
///
/// ### Codec configuration
/// For `avc1.*` / `hev1.*` the browser needs the codec-private description
/// (avcC / hvcC) — supplied via [DecoderConfig.extraData]. Annex-B streams
/// (no extradata) are configured without a description.
///
/// ### Async-output bridge
/// `VideoDecoder` emits frames on an output callback, not per-`decode()`
/// promise. `decode()` submits the chunk, yields the event loop so the output
/// task can run, and returns the oldest buffered frame (so frames flow with
/// ~one decode of latency — fine, pts is carried per frame). It does NOT
/// `flush()` per frame (that would reset inter-frame reference state).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:web/web.dart' as web;

import 'web_backend.dart';

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

/// [PlatformDecoder] backed by the browser `VideoDecoder` API.
class WebCodecsVideoDecoder implements PlatformDecoder {
  WebCodecsVideoDecoder._();

  web.VideoDecoder? _decoder;
  final List<DecodedFrame> _pending = [];
  Object? _lastError;

  void _handleFrame(JSAny? frameJs) {
    if (frameJs == null || frameJs.isUndefined) return;
    final frame = frameJs as web.VideoFrame;
    _pending.add(_WebDecodedFrame(frame));
  }

  void _handleError(JSAny? errJs) => _lastError = errJs;

  void _throwIfError() {
    final e = _lastError;
    if (e != null) {
      _lastError = null;
      throw CodecRuntimeException(WebCodecsBackend.backendName, e.toString());
    }
  }

  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async {
    _throwIfError();
    final dec = _decoder;
    if (dec == null) throw StateError('WebCodecsVideoDecoder: not open');

    // Drain a previously-decoded frame first (steady state = 1 in / 1 out).
    if (_pending.isNotEmpty) return _pending.removeAt(0);

    final data = packet.data;
    final chunk = web.EncodedVideoChunk(
      web.EncodedVideoChunkInit(
        type: packet.isKeyframe ? 'key' : 'delta',
        timestamp: packet.ptsUs,
        data: data.buffer.toJS,
      ),
    );
    dec.decode(chunk);

    // Let the output callback (a queued task) run. Bounded yields so we
    // don't spin if this chunk produced no frame (priming/buffering).
    for (var i = 0; i < 16 && _pending.isEmpty && _lastError == null; i++) {
      if (dec.decodeQueueSize == 0 && i > 0) break;
      await Future<void>.delayed(Duration.zero);
    }
    _throwIfError();
    return _pending.isEmpty ? null : _pending.removeAt(0);
  }

  @override
  Future<List<DecodedFrame>> flush() async {
    final dec = _decoder;
    if (dec == null) return const [];
    await dec.flush().toDart;
    _throwIfError();
    final out = List<DecodedFrame>.from(_pending);
    _pending.clear();
    return out;
  }

  @override
  Future<void> close() async {
    try {
      _decoder?.close();
    } catch (_) {}
    _decoder = null;
    for (final f in _pending) {
      f.close();
    }
    _pending.clear();
  }

  /// Create and configure a decoder from a [DecoderConfig].
  static Future<WebCodecsVideoDecoder> create(DecoderConfig config) async {
    final dec = WebCodecsVideoDecoder._();
    final codecStr = _toWebCodecsString(config.codec, config.backendOptions);

    dec._decoder = web.VideoDecoder(
      web.VideoDecoderInit(
        output: (JSAny? frame) {
          dec._handleFrame(frame);
        }.toJS,
        error: (JSAny? err) {
          dec._handleError(err);
        }.toJS,
      ),
    );

    // avcC / hvcC description for avc1./hev1. codec strings; omit for Annex-B.
    final extra = config.extraData;
    // Pass a tight copy so `description` is exactly the avcC/hvcC bytes
    // (extra may be a view into a larger buffer).
    final cfg = (extra != null && extra.isNotEmpty)
        ? web.VideoDecoderConfig(
            codec: codecStr,
            description: Uint8List.fromList(extra).toJS,
          )
        : web.VideoDecoderConfig(codec: codecStr);
    dec._decoder!.configure(cfg);
    dec._throwIfError();
    return dec;
  }
}

/// A [DecodedFrame] wrapping a browser `VideoFrame`. Presented directly via
/// [webVideoFrame]; [readBytes] falls back to an RGBA `copyTo`.
class _WebDecodedFrame implements DecodedFrame {
  _WebDecodedFrame(this._frame);

  final web.VideoFrame _frame;
  bool _closed = false;

  @override
  int get width => _frame.displayWidth;

  @override
  int get height => _frame.displayHeight;

  @override
  int get ptsUs => _frame.timestamp.toInt();

  @override
  Object? get webVideoFrame => _closed ? null : _frame;
  @override
  FrameSourceKind get outputKind => FrameSourceKind.webVideoFrame;
  @override
  int get gpuHandle => 0; // browser owns the surface; present via webVideoFrame
  @override
  int get subresourceIndex => 0;
  @override
  DecodedPixelLayout get pixelLayout => DecodedPixelLayout.i420;
  @override
  bool get isFullRange => false;
  @override
  YuvColorMatrix get colorMatrix => YuvColorMatrix.bt601;

  @override
  Future<List<int>> readBytes() async {
    // Fallback CPU path (RGBA, not YUV): the player uses [webVideoFrame] for
    // zero-copy present and never calls this. Provided so generic consumers
    // aren't left without any readback.
    final size = _frame.allocationSize(
      web.VideoFrameCopyToOptions(format: 'RGBA'),
    );
    final out = Uint8List(size);
    await _frame
        .copyTo(
          out.toJS,
          web.VideoFrameCopyToOptions(format: 'RGBA'),
        )
        .toDart;
    return out;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _frame.close();
  }
}
