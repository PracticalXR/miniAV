/// Native bindings to the `miniav_tools_codecs_native` code asset, built by
/// `hook/build.dart` from `native/` (libopus decode + Media Foundation D3D11
/// decode). This library links NO FFmpeg — it is the first-party, FFmpeg-free
/// codec surface.
///
/// The asset is bound to this library by the hook
/// (`names: {'miniav_tools_codecs_native': 'codecs_native.dart'}`), so the
/// `@Native(symbol:)` externs below resolve to it at runtime.
@DefaultAsset('package:miniav_tools_codecs/codecs_native.dart')
library;

import 'dart:ffi';

// =============================================================================
// libopus decode (all platforms)
// =============================================================================

@Native<Pointer<Void> Function(Int32, Int32)>(symbol: 'miniav_opus_create')
external Pointer<Void> _opusCreate(int sampleRate, int channels);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Float>, Int32)>(
  symbol: 'miniav_opus_decode',
)
external int _opusDecode(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  int len,
  Pointer<Float> out,
  int maxFrames,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_opus_channels')
external int _opusChannels(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_opus_sample_rate')
external int _opusSampleRate(Pointer<Void> handle);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_opus_destroy')
external void _opusDestroy(Pointer<Void> handle);

/// Create an Opus decoder (sample_rate ∈ {8000,12000,16000,24000,48000},
/// channels ∈ {1,2}); returns `nullptr` on failure.
Pointer<Void> opusCreate(int sampleRate, int channels) =>
    _opusCreate(sampleRate, channels);

/// Decode one packet → interleaved f32. Returns frames-per-channel decoded
/// (total samples = ret*channels), or a negative Opus error code.
int opusDecode(
  Pointer<Void> handle,
  Pointer<Uint8> data,
  int len,
  Pointer<Float> out,
  int maxFrames,
) => _opusDecode(handle, data, len, out, maxFrames);

int opusChannels(Pointer<Void> handle) => _opusChannels(handle);
int opusSampleRate(Pointer<Void> handle) => _opusSampleRate(handle);
void opusDestroy(Pointer<Void> handle) => _opusDestroy(handle);

// -----------------------------------------------------------------------------
// libopus encode (all platforms)
// -----------------------------------------------------------------------------

@Native<Pointer<Void> Function(Int32, Int32, Int32, Int32)>(
  symbol: 'miniav_opus_enc_create',
)
external Pointer<Void> _opusEncCreate(
  int sampleRate,
  int channels,
  int bitrateBps,
  int application,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_opus_enc_encode',
)
external int _opusEncEncode(
  Pointer<Void> handle,
  Pointer<Float> pcm,
  int framesPerChannel,
  Pointer<Uint8> out,
  int outCap,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_opus_enc_destroy')
external void _opusEncDestroy(Pointer<Void> handle);

/// Opus encoder `application` constants (raw libopus values).
const int kOpusApplicationVoip = 2048;
const int kOpusApplicationAudio = 2049;
const int kOpusApplicationLowDelay = 2051;

/// Create an Opus encoder (sample_rate ∈ {8000,12000,16000,24000,48000},
/// channels ∈ {1,2}, `bitrateBps` <=0 → libopus auto, `application` one of the
/// `kOpusApplication*` constants); returns `nullptr` on failure.
Pointer<Void> opusEncCreate(
  int sampleRate,
  int channels,
  int bitrateBps,
  int application,
) => _opusEncCreate(sampleRate, channels, bitrateBps, application);

/// Encode ONE frame of `framesPerChannel` interleaved-f32 samples (must be a
/// valid Opus frame size) into [out] (capacity `outCap` bytes). Returns the
/// compressed byte count (>=1), or a negative Opus error code.
int opusEncEncode(
  Pointer<Void> handle,
  Pointer<Float> pcm,
  int framesPerChannel,
  Pointer<Uint8> out,
  int outCap,
) => _opusEncEncode(handle, pcm, framesPerChannel, out, outCap);

void opusEncDestroy(Pointer<Void> handle) => _opusEncDestroy(handle);

// -----------------------------------------------------------------------------
// SW audio decode (dr_mp3 / dr_flac / stb_vorbis) — all platforms
// -----------------------------------------------------------------------------
// Each decodes a whole compressed buffer → a malloc'd interleaved-f32 buffer
// (returned via `out`), returning frames-per-channel (>=0) or -1, and writing
// channels + sample rate. The caller frees `out.value` via [swFree].

typedef _SwDecodeNative = Int32 Function(
    Pointer<Uint8>, Int32, Pointer<Pointer<Float>>, Pointer<Int32>, Pointer<Int32>);

@Native<_SwDecodeNative>(symbol: 'miniav_mp3_decode')
external int _mp3Decode(Pointer<Uint8> data, int len, Pointer<Pointer<Float>> out,
    Pointer<Int32> channels, Pointer<Int32> rate);

@Native<_SwDecodeNative>(symbol: 'miniav_flac_decode')
external int _flacDecode(Pointer<Uint8> data, int len, Pointer<Pointer<Float>> out,
    Pointer<Int32> channels, Pointer<Int32> rate);

@Native<_SwDecodeNative>(symbol: 'miniav_vorbis_decode')
external int _vorbisDecode(Pointer<Uint8> data, int len,
    Pointer<Pointer<Float>> out, Pointer<Int32> channels, Pointer<Int32> rate);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_sw_free')
external void _swFree(Pointer<Void> p);

/// Which single-header decoder a [swDecode] call routes to.
enum SwAudioLib { mp3, flac, vorbis }

/// Decode a whole compressed buffer. Returns frames-per-channel (>=0) or -1;
/// on success `out.value` is a malloc'd interleaved-f32 buffer (free via [swFree]).
int swDecode(SwAudioLib lib, Pointer<Uint8> data, int len,
        Pointer<Pointer<Float>> out, Pointer<Int32> channels,
        Pointer<Int32> rate) =>
    switch (lib) {
      SwAudioLib.mp3 => _mp3Decode(data, len, out, channels, rate),
      SwAudioLib.flac => _flacDecode(data, len, out, channels, rate),
      SwAudioLib.vorbis => _vorbisDecode(data, len, out, channels, rate),
    };

void swFree(Pointer<Void> p) => _swFree(p);

// --- Seekable streaming sw-audio decode --------------------------------------
// A native handle owns a copy of the compressed bytes and decodes PCM on demand
// with random seek. All calls are synchronous. Handles are opaque Pointer<Void>.

typedef _SwStreamOpenNative = Pointer<Void> Function(
    Pointer<Uint8>, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>);
typedef _SwStreamReadNative = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32);
typedef _SwStreamSeekNative = Int32 Function(Pointer<Void>, Int64);
typedef _SwStreamCloseNative = Void Function(Pointer<Void>);

@Native<_SwStreamOpenNative>(symbol: 'miniav_mp3_stream_open')
external Pointer<Void> _mp3StreamOpen(Pointer<Uint8> data, int len,
    Pointer<Int32> channels, Pointer<Int32> rate, Pointer<Int64> totalFrames);
@Native<_SwStreamReadNative>(symbol: 'miniav_mp3_stream_read')
external int _mp3StreamRead(Pointer<Void> h, Pointer<Float> out, int frames);
@Native<_SwStreamSeekNative>(symbol: 'miniav_mp3_stream_seek')
external int _mp3StreamSeek(Pointer<Void> h, int frame);
@Native<_SwStreamCloseNative>(symbol: 'miniav_mp3_stream_close')
external void _mp3StreamClose(Pointer<Void> h);

@Native<_SwStreamOpenNative>(symbol: 'miniav_flac_stream_open')
external Pointer<Void> _flacStreamOpen(Pointer<Uint8> data, int len,
    Pointer<Int32> channels, Pointer<Int32> rate, Pointer<Int64> totalFrames);
@Native<_SwStreamReadNative>(symbol: 'miniav_flac_stream_read')
external int _flacStreamRead(Pointer<Void> h, Pointer<Float> out, int frames);
@Native<_SwStreamSeekNative>(symbol: 'miniav_flac_stream_seek')
external int _flacStreamSeek(Pointer<Void> h, int frame);
@Native<_SwStreamCloseNative>(symbol: 'miniav_flac_stream_close')
external void _flacStreamClose(Pointer<Void> h);

@Native<_SwStreamOpenNative>(symbol: 'miniav_vorbis_stream_open')
external Pointer<Void> _vorbisStreamOpen(Pointer<Uint8> data, int len,
    Pointer<Int32> channels, Pointer<Int32> rate, Pointer<Int64> totalFrames);
@Native<_SwStreamReadNative>(symbol: 'miniav_vorbis_stream_read')
external int _vorbisStreamRead(Pointer<Void> h, Pointer<Float> out, int frames);
@Native<_SwStreamSeekNative>(symbol: 'miniav_vorbis_stream_seek')
external int _vorbisStreamSeek(Pointer<Void> h, int frame);
@Native<_SwStreamCloseNative>(symbol: 'miniav_vorbis_stream_close')
external void _vorbisStreamClose(Pointer<Void> h);

/// Open a seekable streaming decoder over a compressed buffer. Returns an
/// opaque handle (or `nullptr` on failure) and reports channels/rate/total
/// frames. The native side copies [data], so it need not outlive this call.
Pointer<Void> swStreamOpen(SwAudioLib lib, Pointer<Uint8> data, int len,
        Pointer<Int32> channels, Pointer<Int32> rate,
        Pointer<Int64> totalFrames) =>
    switch (lib) {
      SwAudioLib.mp3 => _mp3StreamOpen(data, len, channels, rate, totalFrames),
      SwAudioLib.flac => _flacStreamOpen(data, len, channels, rate, totalFrames),
      SwAudioLib.vorbis =>
        _vorbisStreamOpen(data, len, channels, rate, totalFrames),
    };

/// Read up to [frames] interleaved-f32 frames into [out]; returns frames read.
int swStreamRead(SwAudioLib lib, Pointer<Void> h, Pointer<Float> out,
        int frames) =>
    switch (lib) {
      SwAudioLib.mp3 => _mp3StreamRead(h, out, frames),
      SwAudioLib.flac => _flacStreamRead(h, out, frames),
      SwAudioLib.vorbis => _vorbisStreamRead(h, out, frames),
    };

/// Seek so the next read starts at PCM [frame]. Returns true on success.
bool swStreamSeek(SwAudioLib lib, Pointer<Void> h, int frame) =>
    switch (lib) {
      SwAudioLib.mp3 => _mp3StreamSeek(h, frame) != 0,
      SwAudioLib.flac => _flacStreamSeek(h, frame) != 0,
      SwAudioLib.vorbis => _vorbisStreamSeek(h, frame) != 0,
    };

void swStreamClose(SwAudioLib lib, Pointer<Void> h) {
  switch (lib) {
    case SwAudioLib.mp3:
      _mp3StreamClose(h);
    case SwAudioLib.flac:
      _flacStreamClose(h);
    case SwAudioLib.vorbis:
      _vorbisStreamClose(h);
  }
}

// -----------------------------------------------------------------------------
// Media Foundation AAC decode + encode (Windows only) — mf_aac.c
// -----------------------------------------------------------------------------

/// Mirror of the C `MiniAVMfAacDecFrame`.
final class MfAacDecFrame extends Struct {
  external Pointer<Uint8> pcmData;
  @Int32()
  external int pcmSize;
  @Int32()
  external int sampleCount;
  @Int32()
  external int sampleRate;
  @Int32()
  external int channels;
  @Int32()
  external int sampleFmt;
  @Int64()
  external int ptsUs;
}

/// Mirror of the C `MiniAVMfAacEncFrame`.
final class MfAacEncFrame extends Struct {
  external Pointer<Uint8> aacData;
  @Int32()
  external int aacSize;
  @Int64()
  external int ptsUs;
}

@Native<Int32 Function()>(symbol: 'miniav_shim_mfaac_dec_has_mft')
external int mfaacDecHasMft();

@Native<Pointer<Void> Function(Pointer<Uint8>, Int32, Int32, Int32)>(
  symbol: 'miniav_shim_mfaac_dec_create',
)
external Pointer<Void> mfaacDecCreate(
    Pointer<Uint8> asc, int ascLen, int sampleRate, int channels);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int64)>(
  symbol: 'miniav_shim_mfaac_dec_send',
)
external int mfaacDecSend(
    Pointer<Void> s, Pointer<Uint8> aac, int aacSize, int ptsUs);

@Native<Int32 Function(Pointer<Void>, Pointer<MfAacDecFrame>)>(
  symbol: 'miniav_shim_mfaac_dec_receive',
)
external int mfaacDecReceive(Pointer<Void> s, Pointer<MfAacDecFrame> out);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_dec_drain')
external int mfaacDecDrain(Pointer<Void> s);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_dec_destroy')
external void mfaacDecDestroy(Pointer<Void> s);

@Native<Int32 Function()>(symbol: 'miniav_shim_mfaac_enc_has_mft')
external int mfaacEncHasMft();

@Native<Pointer<Void> Function(Int32, Int32, Int32)>(
  symbol: 'miniav_shim_mfaac_enc_create',
)
external Pointer<Void> mfaacEncCreate(int sampleRate, int channels, int bitrate);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfaac_enc_get_asc',
)
external int mfaacEncGetAsc(Pointer<Void> s, Pointer<Uint8> out, int cap);

@Native<Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Int64)>(
  symbol: 'miniav_shim_mfaac_enc_send',
)
external int mfaacEncSend(
    Pointer<Void> s, Pointer<Float> pcm, int sampleCount, int ptsUs);

@Native<Int32 Function(Pointer<Void>, Pointer<MfAacEncFrame>)>(
  symbol: 'miniav_shim_mfaac_enc_receive',
)
external int mfaacEncReceive(Pointer<Void> s, Pointer<MfAacEncFrame> out);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_enc_drain')
external int mfaacEncDrain(Pointer<Void> s);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_enc_destroy')
external void mfaacEncDestroy(Pointer<Void> s);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_free')
external void mfaacFree(Pointer<Void> p);

// -----------------------------------------------------------------------------
// Media Foundation H.264/HEVC video ENCODE (Windows only) — mf_encoder.c
// -----------------------------------------------------------------------------

/// Mirror of the C `MiniAVMfEncFrame`.
final class MfEncFrame extends Struct {
  external Pointer<Uint8> data;
  @Int32()
  external int size;
  @Int32()
  external int isKeyframe;
  @Int64()
  external int ptsUs;
}

@Native<Int32 Function(Int32)>(symbol: 'miniav_shim_mfenc_has_mft')
external int mfencHasMft(int codec);

@Native<Pointer<Void> Function(Int32, Int32, Int32, Int32, Int32, Int32, Int32)>(
  symbol: 'miniav_shim_mfenc_create',
)
external Pointer<Void> mfencCreate(int codec, int width, int height,
    int bitrateBps, int fpsNum, int fpsDen, int gop);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfenc_get_extradata',
)
external int mfencGetExtradata(Pointer<Void> s, Pointer<Uint8> out, int cap);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int64, Int32)>(
  symbol: 'miniav_shim_mfenc_send_nv12',
)
external int mfencSendNv12(
    Pointer<Void> s, Pointer<Uint8> nv12, int size, int ptsUs, int forceKey);

@Native<Int32 Function(Pointer<Void>, Pointer<MfEncFrame>)>(
  symbol: 'miniav_shim_mfenc_receive',
)
external int mfencReceive(Pointer<Void> s, Pointer<MfEncFrame> out);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfenc_drain')
external int mfencDrain(Pointer<Void> s);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfenc_destroy')
external void mfencDestroy(Pointer<Void> s);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfenc_free')
external void mfencFree(Pointer<Void> p);

// =============================================================================
// Media Foundation D3D11 hardware decode (Windows only)
// =============================================================================
//
// A standalone hardware H.264/HEVC decoder MFT that outputs D3D11 NV12 textures
// (see native/mf_decoder.c). On non-Windows these symbols are absent — callers
// gate on Platform.isWindows.

/// Mirror of the C `MiniAVMfDecFrame` (40 bytes on 64-bit). The trailing [pad]
/// keeps [ptsUs] 8-byte aligned, matching the C struct exactly.
final class MiniAVMfDecFrame extends Struct {
  @IntPtr()
  external int outSharedHandle;
  @IntPtr()
  external int outTexturePtr;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int pixelFormat;
  @Int32()
  external int pad;
  @Int64()
  external int ptsUs;
}

@Native<Int32 Function(Int32)>(symbol: 'miniav_shim_mfdec_has_hardware')
external int _mfdecHasHardware(int codec);

@Native<
    Pointer<Void> Function(
        Pointer<Void>, Int32, Pointer<Uint8>, Int32, Int32, Int32)>(
  symbol: 'miniav_shim_mfdec_create',
)
external Pointer<Void> _mfdecCreate(
  Pointer<Void> device,
  int codec,
  Pointer<Uint8> extradata,
  int extradataSize,
  int width,
  int height,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int64, Int32)>(
  symbol: 'miniav_shim_mfdec_send',
)
external int _mfdecSend(
  Pointer<Void> session,
  Pointer<Uint8> data,
  int size,
  int ptsUs,
  int isKeyframe,
);

@Native<Int32 Function(Pointer<Void>, Pointer<MiniAVMfDecFrame>)>(
  symbol: 'miniav_shim_mfdec_receive',
)
external int _mfdecReceive(Pointer<Void> session, Pointer<MiniAVMfDecFrame> out);

@Native<Int32 Function(Pointer<Void>, IntPtr, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfdec_map_nv12',
)
external int _mfdecMapNv12(
  Pointer<Void> session,
  int texturePtr,
  Pointer<Uint8> dst,
  int dstCap,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfdec_drain')
external int _mfdecDrain(Pointer<Void> session);

@Native<Void Function(Pointer<Void>, IntPtr, IntPtr)>(
  symbol: 'miniav_shim_mfdec_release_frame',
)
external void _mfdecReleaseFrame(
  Pointer<Void> session,
  int sharedHandle,
  int texturePtr,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfdec_destroy')
external void _mfdecDestroy(Pointer<Void> session);

/// True if a hardware decoder MFT exists for [codec] (0=H264, 1=HEVC).
bool mfdecHasHardware(int codec) => _mfdecHasHardware(codec) != 0;

/// Open a decode session. [device] is an `ID3D11Device*` (or `nullptr` for an
/// own device). [width]/[height] are a coded-dims hint (0 = unknown) — the
/// HEVC decoder MFT requires them on the input type (see mf_decoder.c);
/// H.264 works without. Returns `nullptr` on failure (no HW MFT / STA
/// thread).
Pointer<Void> mfdecCreate(
  Pointer<Void> device,
  int codec,
  Pointer<Uint8> extradata,
  int extradataSize, {
  int width = 0,
  int height = 0,
}) =>
    _mfdecCreate(device, codec, extradata, extradataSize, width, height);

/// Feed one encoded packet. 0 = OK, <0 = error.
int mfdecSend(
  Pointer<Void> session,
  Pointer<Uint8> data,
  int size,
  int ptsUs,
  bool isKeyframe,
) => _mfdecSend(session, data, size, ptsUs, isKeyframe ? 1 : 0);

/// Drain one decoded frame. 1 = frame, 0 = need more input, <0 = error.
int mfdecReceive(Pointer<Void> session, Pointer<MiniAVMfDecFrame> out) =>
    _mfdecReceive(session, out);

/// Map a shareable NV12 texture to CPU (tightly packed). Bytes written, or <0.
int mfdecMapNv12(
  Pointer<Void> session,
  int texturePtr,
  Pointer<Uint8> dst,
  int dstCap,
) => _mfdecMapNv12(session, texturePtr, dst, dstCap);

/// Signal end-of-stream + collect trailing frames (poll [mfdecReceive]).
int mfdecDrain(Pointer<Void> session) => _mfdecDrain(session);

/// Release a decoded frame's NT handle + shareable texture.
void mfdecReleaseFrame(Pointer<Void> session, int sharedHandle, int texturePtr) =>
    _mfdecReleaseFrame(session, sharedHandle, texturePtr);

/// Destroy a decode session.
void mfdecDestroy(Pointer<Void> session) => _mfdecDestroy(session);

// =============================================================================
// CPU YUV -> RGBA8888 (all platforms) — the player's cross-platform present
// fallback. Runs the per-pixel colour convert in C (~1-2 ms/1080p) instead of a
// Dart loop that would jank the UI isolate. BT.601 limited-range (matches the
// player's WGSL decode kernel + yuv_rgba_reference.dart); A=255.
// =============================================================================

// Signature shared by the three-plane converters (i420/i422/i444 + 10-bit):
// (y, u, v, strideY, strideU, strideV, width, height, out, fullRange).
typedef _PlanarNative = Void Function(Pointer<Uint8>, Pointer<Uint8>,
    Pointer<Uint8>, Int32, Int32, Int32, Int32, Int32, Pointer<Uint8>, Int32,
    Int32);
typedef _PlanarDart = void Function(Pointer<Uint8>, Pointer<Uint8>,
    Pointer<Uint8>, int, int, int, int, int, Pointer<Uint8>, int, int);

@Native<_PlanarNative>(symbol: 'miniav_i420_to_rgba')
external void _i420ToRgba(Pointer<Uint8> y, Pointer<Uint8> u, Pointer<Uint8> v,
    int sy, int su, int sv, int w, int h, Pointer<Uint8> out, int fullRange,
    int matrix);

@Native<_PlanarNative>(symbol: 'miniav_i422_to_rgba')
external void _i422ToRgba(Pointer<Uint8> y, Pointer<Uint8> u, Pointer<Uint8> v,
    int sy, int su, int sv, int w, int h, Pointer<Uint8> out, int fullRange,
    int matrix);

@Native<_PlanarNative>(symbol: 'miniav_i444_to_rgba')
external void _i444ToRgba(Pointer<Uint8> y, Pointer<Uint8> u, Pointer<Uint8> v,
    int sy, int su, int sv, int w, int h, Pointer<Uint8> out, int fullRange,
    int matrix);

@Native<_PlanarNative>(symbol: 'miniav_i420p10_to_rgba')
external void _i420p10ToRgba(Pointer<Uint8> y, Pointer<Uint8> u,
    Pointer<Uint8> v, int sy, int su, int sv, int w, int h,
    Pointer<Uint8> out, int fullRange, int matrix);

@Native<_PlanarNative>(symbol: 'miniav_i422p10_to_rgba')
external void _i422p10ToRgba(Pointer<Uint8> y, Pointer<Uint8> u,
    Pointer<Uint8> v, int sy, int su, int sv, int w, int h,
    Pointer<Uint8> out, int fullRange, int matrix);

@Native<_PlanarNative>(symbol: 'miniav_i444p10_to_rgba')
external void _i444p10ToRgba(Pointer<Uint8> y, Pointer<Uint8> u,
    Pointer<Uint8> v, int sy, int su, int sv, int w, int h,
    Pointer<Uint8> out, int fullRange, int matrix);

// nv12 / p010 share a signature: (y, uv, sy, suv, w, h, out, fullRange, matrix).
typedef _SemiPlanarNative = Void Function(Pointer<Uint8>, Pointer<Uint8>, Int32,
    Int32, Int32, Int32, Pointer<Uint8>, Int32, Int32);

@Native<_SemiPlanarNative>(symbol: 'miniav_nv12_to_rgba')
external void _nv12ToRgba(Pointer<Uint8> y, Pointer<Uint8> uv, int sy, int suv,
    int w, int h, Pointer<Uint8> out, int fullRange, int matrix);

@Native<_SemiPlanarNative>(symbol: 'miniav_p010_to_rgba')
external void _p010ToRgba(Pointer<Uint8> y, Pointer<Uint8> uv, int sy, int suv,
    int w, int h, Pointer<Uint8> out, int fullRange, int matrix);

// The inverse direction:
// (rgba, stride, w, h, y, u, v, fullRange, matrix, bgra).
typedef _RgbaToI420Native = Void Function(Pointer<Uint8>, Int32, Int32, Int32,
    Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Int32);

@Native<_RgbaToI420Native>(symbol: 'miniav_rgba_to_i420')
external void _rgbaToI420Native(Pointer<Uint8> rgba, int stride, int w, int h,
    Pointer<Uint8> y, Pointer<Uint8> u, Pointer<Uint8> v, int fullRange,
    int matrix, int bgra);

/// The planar YUV layout of a CPU frame's tightly-packed bytes.
enum YuvPlanar { i420, i422, i444, i420p10, i422p10, i444p10 }

_PlanarDart _planarFn(YuvPlanar p) => switch (p) {
      YuvPlanar.i420 => _i420ToRgba,
      YuvPlanar.i422 => _i422ToRgba,
      YuvPlanar.i444 => _i444ToRgba,
      YuvPlanar.i420p10 => _i420p10ToRgba,
      YuvPlanar.i422p10 => _i422p10ToRgba,
      YuvPlanar.i444p10 => _i444p10ToRgba,
    };

/// Convert three-plane YUV ([layout]) to packed RGBA8888. Planes may be strided
/// (bytes; <=0 = tightly packed). [out] must hold `width*height*4` bytes.
/// [fullRange] selects JPEG-range coefficients (yuvj*); [matrix] selects the
/// YCbCr matrix (0 = BT.601, 1 = BT.709, 2 = BT.2020 NCL — mirrors the C
/// `pick()` table in frame_convert.c).
void planarToRgba(
  YuvPlanar layout,
  Pointer<Uint8> y,
  Pointer<Uint8> u,
  Pointer<Uint8> v,
  int width,
  int height,
  Pointer<Uint8> out, {
  int strideY = 0,
  int strideU = 0,
  int strideV = 0,
  bool fullRange = false,
  int matrix = 0,
}) =>
    _planarFn(layout)(y, u, v, strideY, strideU, strideV, width, height, out,
        fullRange ? 1 : 0, matrix);

/// Convert planar I420 (YUV420P) to packed RGBA8888.
void i420ToRgba(
  Pointer<Uint8> y,
  Pointer<Uint8> u,
  Pointer<Uint8> v,
  int width,
  int height,
  Pointer<Uint8> out, {
  int strideY = 0,
  int strideU = 0,
  int strideV = 0,
  bool fullRange = false,
  int matrix = 0,
}) =>
    _i420ToRgba(y, u, v, strideY, strideU, strideV, width, height, out,
        fullRange ? 1 : 0, matrix);

/// Convert NV12 (Y plane + interleaved UV plane) to packed RGBA8888.
void nv12ToRgba(
  Pointer<Uint8> y,
  Pointer<Uint8> uv,
  int width,
  int height,
  Pointer<Uint8> out, {
  int strideY = 0,
  int strideUV = 0,
  bool fullRange = false,
  int matrix = 0,
}) =>
    _nv12ToRgba(y, uv, strideY, strideUV, width, height, out, fullRange ? 1 : 0,
        matrix);

/// Convert P010 (10-bit NV12: 16-bit LE samples, value in the HIGH bits) to
/// packed RGBA8888. Strides in bytes (<=0 = tightly packed, 2*width).
void p010ToRgba(
  Pointer<Uint8> y,
  Pointer<Uint8> uv,
  int width,
  int height,
  Pointer<Uint8> out, {
  int strideY = 0,
  int strideUV = 0,
  bool fullRange = false,
  int matrix = 0,
}) =>
    _p010ToRgba(y, uv, strideY, strideUV, width, height, out, fullRange ? 1 : 0,
        matrix);

/// Convert packed RGBA8888 (or BGRA8888 with [bgra]) -> tightly-packed I420
/// planes (the encode-side inverse). [stride] is the source row stride in
/// bytes (<=0 = tightly packed, 4*width). Chroma is the rounded 2x2 box
/// average of the RGB cell — see `RgbaYuvCoeffs` for the coefficient tables
/// this mirrors.
void rgbaToI420(
  Pointer<Uint8> rgba,
  int width,
  int height,
  Pointer<Uint8> y,
  Pointer<Uint8> u,
  Pointer<Uint8> v, {
  int stride = 0,
  bool fullRange = false,
  int matrix = 0,
  bool bgra = false,
}) =>
    _rgbaToI420Native(rgba, stride, width, height, y, u, v, fullRange ? 1 : 0,
        matrix, bgra ? 1 : 0);
