/// Media Foundation hardware H.264/HEVC decoder producing D3D11 NV12 textures
/// (Windows only). Drives the FFmpeg-free `native/mf_decoder.c` via the
/// standalone `codecs_native` asset — no FFmpeg dependency.
///
/// Each decoded frame is a GPU-resident NV12 texture (exposed via
/// [DecodedFrame.outputKind] == `d3d11Texture` + [DecodedFrame.gpuHandle]); the
/// player imports the shared handle straight into Dawn (no CPU readback).
/// [DecodedFrame.readBytes] maps it to CPU (NV12→I420) as a software fallback.
///
/// Only ever constructed when a hardware decoder MFT exists — [open] returns
/// `null` otherwise (and on a non-MTA/STA thread), so the facade negotiator
/// falls back to the software decoder for free.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

int? _codecId(VideoCodec codec) => switch (codec) {
  VideoCodec.h264 => 0,
  VideoCodec.hevc => 1,
  _ => null,
};

class MfD3d11Decoder implements PlatformDecoder {
  final Pointer<Void> _session;
  final Pointer<MiniAVMfDecFrame> _out;

  /// avcC/hvcC parameter sets converted to Annex-B, prepended to keyframes when
  /// the bitstream is length-prefixed (`null` = feed packets verbatim).
  final Uint8List? _annexBHeaders;
  final int _lengthSize; // 0 = Annex-B (feed raw); >0 = length-prefixed NALs

  bool _closed = false;
  bool _sentHeaders = false;

  MfD3d11Decoder._(
    this._session,
    this._out,
    this._annexBHeaders,
    this._lengthSize,
  );

  /// Open a hardware MF decode session for [config]. Returns `null` when the
  /// codec isn't H.264/HEVC, the native codecs asset isn't loadable, no
  /// hardware MFT exists, or the calling thread is STA (MF needs MTA).
  static Future<MfD3d11Decoder?> open(DecoderConfig config) async {
    if (!Platform.isWindows) return null;
    final codec = _codecId(config.codec);
    if (codec == null) return null;

    // The codecs_native asset is FFmpeg-free; a hardware check that throws
    // (asset not loadable) or returns false → SW fallback.
    try {
      if (!mfdecHasHardware(codec)) return null;
    } catch (_) {
      return null;
    }

    // Decide the bitstream framing from the extradata. avcC/hvcC (first byte
    // 0x01) means length-prefixed NAL units — convert to Annex-B on the fly.
    final extra = config.extraData;
    var lengthSize = 0;
    Uint8List? headers;
    if (extra != null && extra.isNotEmpty && extra[0] == 1) {
      final parsed = config.codec == VideoCodec.hevc
          ? _parseHvcc(extra)
          : _parseAvcc(extra);
      if (parsed != null) {
        lengthSize = parsed.lengthSize;
        headers = parsed.annexBHeaders;
      }
    }

    // Let the session create its own hardware D3D11 device (nullptr) on the
    // primary adapter — the player's Dawn is on the same adapter, so the shared
    // handle opens there. Coded-dims hint: required by the HEVC decoder MFT
    // (frame size on the input type), harmless for H.264.
    final session = mfdecCreate(nullptr, codec, nullptr, 0,
        width: config.width ?? 0, height: config.height ?? 0);
    if (session == nullptr) return null;

    final out = calloc<MiniAVMfDecFrame>();
    return MfD3d11Decoder._(session, out, headers, lengthSize);
  }

  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async {
    _checkOpen();
    final annexB = _toAnnexB(packet.data, packet.isKeyframe);
    final buf = calloc<Uint8>(annexB.length);
    buf.asTypedList(annexB.length).setAll(0, annexB);
    try {
      mfdecSend(
        _session,
        buf,
        annexB.length,
        packet.ptsUs,
        packet.isKeyframe,
      );
    } finally {
      calloc.free(buf);
    }
    final rc = mfdecReceive(_session, _out);
    if (rc != 1) return null; // buffering / need more input
    return _frameFromOut();
  }

  @override
  Future<List<DecodedFrame>> flush() async {
    _checkOpen();
    mfdecDrain(_session);
    final frames = <DecodedFrame>[];
    // Drain-collected frames were queued native-side; poll them out.
    for (var guard = 0; guard < 8192; guard++) {
      final rc = mfdecReceive(_session, _out);
      if (rc != 1) break;
      frames.add(_frameFromOut());
    }
    return frames;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    mfdecDestroy(_session);
    calloc.free(_out);
  }

  _MfD3d11Frame _frameFromOut() => _MfD3d11Frame(
    session: _session,
    sharedHandle: _out.ref.outSharedHandle,
    texturePtr: _out.ref.outTexturePtr,
    width: _out.ref.width,
    height: _out.ref.height,
    ptsUs: _out.ref.ptsUs,
  );

  /// Convert one packet to Annex-B. Length-prefixed input is rewritten to
  /// start-code framing; keyframes get the parameter sets prepended once.
  Uint8List _toAnnexB(Uint8List data, bool isKeyframe) {
    if (_lengthSize == 0) {
      // Already Annex-B (or the MFT will accept the raw feed). Prepend headers
      // to the first keyframe if we somehow have them out-of-band.
      if (_annexBHeaders != null && isKeyframe && !_sentHeaders) {
        _sentHeaders = true;
        return Uint8List.fromList([..._annexBHeaders, ...data]);
      }
      return data;
    }
    final out = BytesBuilder(copy: false);
    if (_annexBHeaders != null && isKeyframe && !_sentHeaders) {
      _sentHeaders = true;
      out.add(_annexBHeaders);
    }
    var i = 0;
    while (i + _lengthSize <= data.length) {
      var nalLen = 0;
      for (var k = 0; k < _lengthSize; k++) {
        nalLen = (nalLen << 8) | data[i + k];
      }
      i += _lengthSize;
      if (nalLen <= 0 || i + nalLen > data.length) break;
      out.add(const [0, 0, 0, 1]);
      out.add(data.sublist(i, i + nalLen));
      i += nalLen;
    }
    return out.toBytes();
  }

  void _checkOpen() {
    if (_closed) throw StateError('MfD3d11Decoder has been closed.');
  }
}

/// A decoded frame backed by a shareable D3D11 NV12 texture + NT handle.
class _MfD3d11Frame implements DecodedFrame {
  final Pointer<Void> _session;
  final int _sharedHandle;
  final int _texturePtr;
  bool _closed = false;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  _MfD3d11Frame({
    required Pointer<Void> session,
    required int sharedHandle,
    required int texturePtr,
    required this.width,
    required this.height,
    required this.ptsUs,
  }) : _session = session,
       _sharedHandle = sharedHandle,
       _texturePtr = texturePtr;

  @override
  FrameSourceKind get outputKind => FrameSourceKind.d3d11Texture;

  @override
  int get gpuHandle => _sharedHandle;

  @override
  int get subresourceIndex => 0;

  @override
  Object? get webVideoFrame => null;

  // GPU-resident (routed by outputKind/gpuHandle); readBytes converts to I420.
  @override
  DecodedPixelLayout get pixelLayout => DecodedPixelLayout.i420;
  @override
  bool get isFullRange => false;
  @override
  YuvColorMatrix get colorMatrix => YuvColorMatrix.bt601;

  /// Map the NV12 texture to CPU and convert to I420 for the player's existing
  /// YUV→RGBA path (Milestone 1). Milestone 2 skips this via a GPU import.
  @override
  Future<List<int>> readBytes() async {
    final needed = width * height + (width * (height ~/ 2));
    final dst = calloc<Uint8>(needed);
    try {
      final n = mfdecMapNv12(_session, _texturePtr, dst, needed);
      if (n < 0) {
        throw StateError('mfdec_map_nv12 failed ($n)');
      }
      final nv12 = Uint8List.fromList(dst.asTypedList(n));
      return _nv12ToI420(nv12, width, height);
    } finally {
      calloc.free(dst);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    mfdecReleaseFrame(_session, _sharedHandle, _texturePtr);
  }
}

/// NV12 (Y plane, then interleaved UV) → I420 (Y, U, V planes).
Uint8List _nv12ToI420(Uint8List nv12, int w, int h) {
  final ySize = w * h;
  final cW = w ~/ 2, cH = h ~/ 2;
  final cSize = cW * cH;
  final out = Uint8List(ySize + 2 * cSize);
  out.setRange(0, ySize, nv12);
  final uvOff = ySize;
  var ui = ySize, vi = ySize + cSize;
  for (var i = 0; i < cSize; i++) {
    out[ui++] = nv12[uvOff + 2 * i]; // U
    out[vi++] = nv12[uvOff + 2 * i + 1]; // V
  }
  return out;
}

class _ParsedParamSets {
  final int lengthSize;
  final Uint8List annexBHeaders;
  _ParsedParamSets(this.lengthSize, this.annexBHeaders);
}

const List<int> _startCode = [0, 0, 0, 1];

/// Parse an avcC record → (NAL length size, Annex-B SPS/PPS blob).
_ParsedParamSets? _parseAvcc(Uint8List a) {
  if (a.length < 7 || a[0] != 1) return null;
  final lengthSize = (a[4] & 0x03) + 1;
  final out = BytesBuilder(copy: false);
  var p = 5;
  final numSps = a[p++] & 0x1F;
  for (var i = 0; i < numSps; i++) {
    if (p + 2 > a.length) return null;
    final len = (a[p] << 8) | a[p + 1];
    p += 2;
    if (p + len > a.length) return null;
    out.add(_startCode);
    out.add(a.sublist(p, p + len));
    p += len;
  }
  if (p >= a.length) return _ParsedParamSets(lengthSize, out.toBytes());
  final numPps = a[p++];
  for (var i = 0; i < numPps; i++) {
    if (p + 2 > a.length) break;
    final len = (a[p] << 8) | a[p + 1];
    p += 2;
    if (p + len > a.length) break;
    out.add(_startCode);
    out.add(a.sublist(p, p + len));
    p += len;
  }
  return _ParsedParamSets(lengthSize, out.toBytes());
}

/// Parse an hvcC record → (NAL length size, Annex-B VPS/SPS/PPS blob).
_ParsedParamSets? _parseHvcc(Uint8List a) {
  if (a.length < 23 || a[0] != 1) return null;
  final lengthSize = (a[21] & 0x03) + 1;
  final out = BytesBuilder(copy: false);
  var p = 22;
  final numArrays = a[p++];
  for (var i = 0; i < numArrays; i++) {
    if (p + 3 > a.length) return null;
    p += 1; // array_completeness + NAL_unit_type
    final numNals = (a[p] << 8) | a[p + 1];
    p += 2;
    for (var j = 0; j < numNals; j++) {
      if (p + 2 > a.length) return null;
      final len = (a[p] << 8) | a[p + 1];
      p += 2;
      if (p + len > a.length) return null;
      out.add(_startCode);
      out.add(a.sublist(p, p + len));
      p += len;
    }
  }
  return _ParsedParamSets(lengthSize, out.toBytes());
}
