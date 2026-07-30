/// Network-first zero-copy A/V player.
///
/// Feed [EncodedPacket]s from any transport; the player decodes on worker
/// isolates (miniav_tools codecs), converts YUV→RGBA on the GPU (minigpu),
/// and presents through a shared texture (minigpu_view) with zero readback —
/// the single CPU→GPU upload of decoded planes is the only pixel traffic.
/// Audio decodes to f32 PCM and plays via miniaudio.
///
/// See `docs/PLAYER_PLAN.md` for the architecture and phase plan.
library;

export 'package:miniav_tools/miniav_tools.dart';
export 'package:minigpu_view/minigpu_view.dart'
    show MinigpuPreviewController, MiniavGpuPreview;

export 'package:miniav_tools_codecs/gpu.dart'
    show GpuPlanarYuvToRgbaConverter;

export 'src/audio_output.dart' show PlayerAudioOutput;
export 'src/media_source.dart'
    show
        MediaSource,
        FileMediaSource,
        BytesMediaSource,
        ByteStreamMediaSource;
export 'src/player.dart' show MiniavPlayer;
// Cross-platform codec-backend registration: FFmpeg on native, WebCodecs on
// web (picked by conditional import). `MiniavPlayer.open` calls this itself;
// exported so examples/consumers that use `MiniAVTools.createEncoder` directly
// (before a player exists) can register the backend the same way.
export 'src/backend_register_native.dart'
    if (dart.library.js_interop) 'src/backend_register_web.dart'
    show registerPlayerBackends;
export 'src/player_clock.dart' show PlayerClock, NowUs;
export 'src/player_config.dart'
    show VideoStreamSpec, AudioStreamSpec, PlayerStats, PlayerLatencyMode;
export 'src/player_view.dart' show MiniavPlayerView;
// Web MSE fallback (browser <video> playback) — real on web, unsupported stub
// on native. Use when WebCodecs is unavailable or for browser-native container
// playback. See MiniavPlayer.openMse.
export 'src/mse/mse_controller_stub.dart'
    if (dart.library.js_interop) 'src/mse/mse_controller.dart'
    show MseController;
export 'src/mse/mse_support_stub.dart'
    if (dart.library.js_interop) 'src/mse/mse_support.dart'
    show
        mseFallbackRecommended,
        webCodecsVideoAvailable,
        mseAvailable,
        blobMimeForBytes,
        mp4MimeForTracks;
export 'src/mse/mse_view.dart' show MseVideoView;
export 'src/video_presenter.dart'
    show VideoFramePresenter, PresenterTimings, makeSharedTexturePreviewSource;
export 'src/video_scheduler.dart' show VideoScheduler, ScheduledVideoFrame;
export 'src/yuv_rgba_reference.dart' show yuv420pToRgba8;
// Web VideoFrame → PreviewSource helper (web-only; a native stub throws).
// Exported so any consumer presenting a WebCodecs `VideoFrame` zero-readback
// (e.g. livetensor meet) reuses it instead of re-registering frames itself.
export 'src/web_present_stub.dart'
    if (dart.library.js_interop) 'src/web_present.dart'
    show makeWebVideoFramePreviewSource;
