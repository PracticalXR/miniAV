/// FFmpeg backend for miniav_tools.
///
/// This package provides codecs/muxers/demuxers backed by FFmpeg
/// (libavcodec, libavformat, libavutil, libswscale, libswresample).
///
/// Call [registerFfmpegBackend] once at startup (idempotent) to register
/// the backend with [MiniAVToolsPlatform] — importing the library alone is
/// NOT enough (Dart top-level finals are lazy, so an import-side-effect
/// registration never fires). Apps using `miniav_recorder` don't need to:
/// `Recorder.warmup()` and `Recorder.start()` both register it.
///
/// ```dart
/// import 'package:miniav_tools/miniav_tools.dart';
/// import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
///
/// registerFfmpegBackend();
/// final enc = await MiniAVTools.createEncoder(
///   const EncoderConfig(
///     codec: VideoCodec.h264,
///     width: 1920, height: 1080, bitrateBps: 8_000_000,
///   ),
///   preference: BackendPreference.pinned('ffmpeg'),
/// );
/// ```
library;

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
export 'src/ffmpeg_backend.dart' show FfmpegBackend;
export 'src/ffmpeg_bindings.dart'
    show ensureFFmpegLoaded, tryLoadFFmpeg, ffmpegLoadedLibDir;
export 'src/ffmpeg_audio_decoder.dart' show FfmpegAudioDecoder;
export 'src/ffmpeg_audio_encoder.dart' show FfmpegAudioEncoder;
export 'src/ffmpeg_decoder.dart' show FfmpegSoftwareDecoder;
export 'src/ffmpeg_demuxer.dart' show FfmpegDemuxer;
export 'src/ffmpeg_encoder.dart' show FfmpegSoftwareEncoder;
export 'src/isolate_decoder.dart'
    show IsolateVideoDecoder, IsolateAudioDecoder;
export 'src/isolate_demuxer.dart' show IsolateDemuxer;
export 'src/isolate_software_encoder.dart' show IsolateSoftwareEncoder;
export 'src/ffmpeg_muxer.dart' show FfmpegMuxer, FfmpegEncoderBridge;
export 'src/ffmpeg_nvenc_encoder.dart'
    show FfmpegNvencEncoder, ffmpegNvencAvailable;
export 'src/ffmpeg_shim.dart' show FfmpegShim;
export 'src/ffmpeg_hw_encoder.dart'
    show
        FfmpegHwEncoder,
        HwEncoderVendor,
        ffmpegHwEncoderAvailable,
        ffmpegHwVendorsAvailable;
export 'src/ffmpeg_d3d11_hw_encoder.dart'
    show
        FfmpegD3d11HwEncoder,
        D3d11HwVendor,
        D3d11HwSourceFormat,
        ffmpegD3d11EncoderAvailable,
        ffmpegD3d11EncoderCompatibleWith,
        ffmpegD3d11VendorsAvailable,
        ffmpegD3d11WarmUp;
export 'src/ffmpeg_downloader.dart'
    show
        FfmpegDownloader,
        FfmpegDownloadResult,
        kFfmpegReleaseTag,
        kFfmpegVersionSuffix,
        kFfmpegLicense,
        kFfmpegInstallDir;
export 'src/ffmpeg_log.dart'
    show
        FfmpegToolsLogCallback,
        setFfmpegToolsLogCallback,
        setFfmpegToolsLogLevel;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'src/ffmpeg_backend.dart';

/// Register the FFmpeg backend with the tools registry (idempotent).
///
/// Must be called before `MiniAVTools.createEncoder` / `MiniAVTools.warmup()`
/// can pick this backend. `miniav_recorder` calls it automatically.
///
/// The Media Foundation hardware **decode** backend moved to
/// `miniav_tools_codecs` (`registerMfDecodeBackend`) — it's FFmpeg-free.
bool registerFfmpegBackend() {
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == FfmpegBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(FfmpegBackend());
  return true;
}
