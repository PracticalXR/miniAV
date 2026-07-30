/// Media Foundation H.264/HEVC video encoder (Windows) — FFmpeg-free, via the
/// OS encoder MFT. First cut: system-memory NV12 input (the sync MS encoder).
///
/// Follow-ups (same pattern as the MF video decoder): D3D11 zero-copy texture
/// input, hardware/async encoders, and an MTA-isolate host so the STA Flutter
/// player can use it (today `open` returns `null` on an STA thread → FFmpeg).
/// The [extraData] is the MF sequence header (Annex-B SPS/PPS); an avcC/hvcC
/// conversion for MP4 muxing is a follow-up.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

class MfVideoEncoder implements PlatformEncoder {
  MfVideoEncoder._(this._handle, this._extra);

  final Pointer<Void> _handle;
  final CodecExtraData? _extra;

  final List<EncodedPacket> _pending = [];
  final Pointer<MfEncFrame> _frame = calloc<MfEncFrame>();
  bool _forceKeyframe = false;
  bool _closed = false;

  static Future<MfVideoEncoder?> open(EncoderConfig config) async {
    if (!Platform.isWindows) return null;
    final codecId = switch (config.codec) {
      VideoCodec.h264 => 0,
      VideoCodec.hevc => 1,
      _ => null,
    };
    if (codecId == null) return null;
    Pointer<Void> h = nullptr;
    try {
      if (mfencHasMft(codecId) == 0) return null;
      h = mfencCreate(
        codecId,
        config.width,
        config.height,
        config.bitrateBps,
        config.frameRateNumerator,
        config.frameRateDenominator,
        config.gopLength,
      );
    } catch (_) {
      return null;
    }
    if (h == nullptr) return null;

    CodecExtraData? extra;
    final buf = calloc<Uint8>(256);
    try {
      final n = mfencGetExtradata(h, buf, 256);
      if (n > 0) {
        extra = CodecExtraData.video(
          config.codec,
          Uint8List.fromList(buf.asTypedList(n)),
        );
      }
    } finally {
      calloc.free(buf);
    }
    return MfVideoEncoder._(h, extra);
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _check();
    final nv12 = _nv12Bytes(frame);
    final inBuf = calloc<Uint8>(nv12.length);
    inBuf.asTypedList(nv12.length).setAll(0, nv12);
    try {
      final force = _forceKeyframe ? 1 : 0;
      _forceKeyframe = false;
      var r = mfencSendNv12(_handle, inBuf, nv12.length, frame.timestampUs, force);
      if (r == 1) {
        _drain();
        r = mfencSendNv12(_handle, inBuf, nv12.length, frame.timestampUs, force);
      }
      if (r < 0) {
        throw const CodecRuntimeException('mf_encode', 'ProcessInput failed');
      }
      _drain();
      return _pending.isEmpty ? null : _pending.removeAt(0);
    } finally {
      calloc.free(inBuf);
    }
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _check();
    mfencDrain(_handle);
    _drain();
    final out = List<EncodedPacket>.of(_pending);
    _pending.clear();
    return out;
  }

  void _drain() {
    while (true) {
      final r = mfencReceive(_handle, _frame);
      if (r == 2) continue; // stream change
      if (r != 1) break;
      final f = _frame.ref;
      if (f.size <= 0 || f.data == nullptr) break;
      final data = Uint8List.fromList(f.data.asTypedList(f.size));
      mfencFree(f.data.cast());
      _pending.add(EncodedPacket(
        data: data,
        ptsUs: f.ptsUs,
        dtsUs: f.ptsUs,
        isKeyframe: f.isKeyframe == 1,
      ));
    }
  }

  /// Extract tightly-packed NV12 bytes from [frame]. First cut: CPU NV12 only
  /// (planar I420 conversion + D3D11-texture input are follow-ups).
  Uint8List _nv12Bytes(FrameSource frame) {
    if (frame is CpuFrameSource &&
        frame.pixelFormat == MiniAVPixelFormat.nv12) {
      return frame.bytes;
    }
    throw UnsupportedFrameSourceException(
      'mf_encode',
      'MF video encode (first cut) needs a CPU NV12 frame; got '
          '${frame.runtimeType} / ${frame.pixelFormat}',
    );
  }

  @override
  bool get acceptsYuv420pPlanes => false;

  @override
  bool get supportsGpuBufferInput => false;

  @override
  Future<void> requestKeyframe() async {
    _forceKeyframe = true;
  }

  @override
  CodecExtraData? get extraData => _extra;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    mfencDestroy(_handle);
    calloc.free(_frame);
  }

  void _check() {
    if (_closed) throw StateError('MfVideoEncoder has been closed.');
  }
}
