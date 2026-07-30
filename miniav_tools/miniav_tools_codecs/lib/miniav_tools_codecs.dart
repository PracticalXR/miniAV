/// First-party codecs for miniav_tools.
///
/// This is the home for direct, GPU-handle-first codec backends — kept distinct
/// from `miniav_tools_ffmpeg` (the shrinking software/container fallback):
///   - GPU-compute codecs via minigpu (WGSL) — MJPEG today; AV1 / custom
///     ML-oriented codecs in progress.
///   - Hardware video codecs via native platform APIs (Media Foundation first,
///     then vendor SDKs — NVENC/NVDEC, VideoToolbox, AMF, VAAPI, MediaCodec),
///     producing/consuming GPU surfaces (D3D11 texture, etc.) with no readback.
///   - Direct audio codec libraries (libopus, …).
///
/// Web codec support (WebCodecs + MSE fallback) also lives here.
library;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
export 'src/minigpu_backend.dart' show MinigpuBackend;
export 'src/gpu_codec_pipeline.dart'
    show GpuCodecPipeline, GpuCodecEncoder, kFrameInputKey, kEncodedOutputKey;
export 'src/minigpu_mjpeg_pipeline.dart' show MinigpuMjpegPipeline;
export 'src/av1/minigpu_av1_pipeline.dart' show MinigpuAv1Pipeline;
export 'src/av1/av1_yuv420_stage.dart'
    show Yuv420Layout, buildRgba8ToYuv420Bt709LimitedStage, kYuv420Key;
export 'src/av1/av1_yuv420_reference.dart' show rgbaToYuv420Bt709LimitedCpu;
export 'src/av1/mp4/av1_mp4_muxer.dart' show Av1Mp4Muxer;
export 'src/opus/opus_backend.dart' show OpusBackend;
export 'src/opus/opus_audio_decoder.dart' show OpusAudioDecoder;
export 'src/opus/opus_audio_encoder.dart' show OpusAudioEncoder;
export 'src/mf/mf_decode_backend.dart' show MfDecodeBackend;
export 'src/mf/mf_d3d11_decoder.dart' show MfD3d11Decoder;
export 'src/mf/aac_backend.dart' show AacBackend;
export 'src/mf/mf_aac_decoder.dart' show MfAacDecoder;
export 'src/mf/mf_aac_encoder.dart' show MfAacEncoder;
export 'src/mf/mf_encode_backend.dart' show MfEncodeBackend;
export 'src/mf/mf_video_encoder.dart' show MfVideoEncoder;
export 'src/pcm/pcm_backend.dart' show PcmBackend;
export 'src/pcm/pcm_audio_decoder.dart' show PcmAudioDecoder;
export 'src/pcm/pcm_audio_encoder.dart' show PcmAudioEncoder;
export 'src/framing/container_backend.dart' show ContainerFramingBackend;
export 'src/framing/wav_container.dart' show WavDemuxer, WavMuxer;
export 'src/framing/ogg_container.dart' show OggDemuxer, OggMuxer;
export 'src/framing/adts_container.dart'
    show AdtsDemuxer, AdtsMuxer, ascToAdtsParams, adtsSampleRates;
export 'src/framing/mp4_container.dart' show Mp4Demuxer, Mp4Muxer;
export 'src/sw_audio/sw_audio_backend.dart' show SwAudioBackend;
export 'src/sw_audio/sw_audio_decoder.dart' show SwAudioDecoder;
export 'src/sw_audio/sw_audio_stream_decoder.dart' show SwAudioStreamDecoder;
export 'src/frame_convert.dart'
    show
        CpuFrameConverter,
        YuvPlanar,
        cpuI420ToRgba,
        cpuNv12ToRgba,
        cpuP010ToRgba,
        cpuPlanarToRgba,
        cpuRgbaToI420;
// The platform-neutral colour-conversion boundary (also importable on its own
// as `package:miniav_tools_codecs/convert.dart` — no FFI/io/minigpu). GPU
// converters live in `package:miniav_tools_codecs/gpu.dart` (web-safe minigpu).
export 'convert.dart'
    show
        YuvRgbCoeffs,
        RgbaYuvCoeffs,
        I420Planes,
        dartI420ToRgba,
        dartI420ToRgbaAsync,
        dartI422ToRgba,
        dartRgbaToI420,
        dartRgbaToI420Async;

import 'dart:io';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'src/framing/container_backend.dart';
import 'src/mf/aac_backend.dart';
import 'src/mf/mf_decode_backend.dart';
import 'src/mf/mf_encode_backend.dart';
import 'src/minigpu_backend.dart';
import 'src/opus/opus_backend.dart';
import 'src/pcm/pcm_backend.dart';
import 'src/sw_audio/sw_audio_backend.dart';

// ignore: unused_element
final _registered = registerMinigpuBackend();

bool registerMinigpuBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == MinigpuBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(MinigpuBackend());
  return true;
}

/// Register the first-party Opus audio-decode backend (idempotent). Reports
/// `supportsAudioDecode(opus)` at a higher priority than the FFmpeg backend, so
/// the facade picks it for Opus — a decode path with zero FFmpeg. Falls back to
/// FFmpeg automatically if libopus init fails.
bool registerOpusBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == OpusBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(OpusBackend());
  return true;
}

/// Register the Media Foundation hardware video-decode backend (Windows only,
/// idempotent; no-op elsewhere). Reports a `{mediaFoundation, zeroCopy,
/// d3d11Texture}` capability the negotiator ranks over software decode — a
/// hardware H.264/HEVC → D3D11 path with **zero FFmpeg** (the decoder lives in
/// the standalone `codecs_native` asset). Falls back to software for free when
/// no hardware MFT is available.
bool registerMfDecodeBackend() {
  if (!Platform.isWindows) return false;
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == MfDecodeBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(MfDecodeBackend());
  return true;
}

/// Register the first-party MF video-encode backend (Windows only, idempotent;
/// no-op elsewhere). H.264/HEVC via the OS encoder MFT. Priority 45 (below
/// FFmpeg) — opt-in via `excluded({'ffmpeg'})` until the D3D11/HW/isolate
/// follow-ups land; first cut is sync SW + CPU-NV12 input.
bool registerMfEncodeBackend() {
  if (!Platform.isWindows) return false;
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == MfEncodeBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(MfEncodeBackend());
  return true;
}

/// Register the first-party OS AAC backend (Windows only, idempotent; no-op
/// elsewhere). Media Foundation AAC decode + encode, preferred over FFmpeg for
/// AAC — falls back to FFmpeg for free when no MFT is available or the thread is
/// STA. License-clean (the OS codec; libfdk-aac is GPL-banned).
bool registerAacBackend() {
  if (!Platform.isWindows) return false;
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == AacBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(AacBackend());
  return true;
}

/// Register the first-party raw-PCM audio backend (pcmS16le / pcmF32le;
/// idempotent, all platforms). Pure Dart, no native lib — decodes/encodes raw
/// interleaved PCM at a priority above FFmpeg, giving raw PCM a real path
/// (previously FFmpeg's audio codec map threw on it).
bool registerPcmBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == PcmBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(PcmBackend());
  return true;
}

/// Register the pure-Dart container framing backend — WAV + Ogg + ADTS + MP4
/// demux/mux (idempotent, all platforms). Priority 55 (above FFmpeg's 50) so
/// these containers open/write FFmpeg-free by default; a parse failure returns
/// `null`, so the negotiator still falls through to FFmpeg.
bool registerContainerFramingBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == ContainerFramingBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(ContainerFramingBackend());
  return true;
}

/// Register the first-party software audio-decode backend — MP3 / FLAC / Vorbis
/// via dr_mp3 / dr_flac / stb_vorbis (idempotent, all platforms). Priority 55
/// (above FFmpeg) — an FFmpeg-free decode path for these three codecs.
bool registerSwAudioBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == SwAudioBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(SwAudioBackend());
  return true;
}
