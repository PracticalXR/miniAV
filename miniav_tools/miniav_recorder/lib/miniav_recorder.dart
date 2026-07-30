/// miniav_recorder — high-level synchronized A/V recorder.
///
/// Compose multiple capture sources (screen, camera, mic, loopback) into
/// one or more outputs (MP4/MKV files, chunked stream callbacks). Tracks
/// share a master clock so audio + video stay aligned within a single
/// container.
///
/// ```dart
/// final rec = (RecorderBuilder()
///       ..addCamera(deviceId: cam.deviceId)
///       ..addMic(deviceId: mic.deviceId, codec: AudioCodec.opus)
///       ..addLoopback(deviceId: loop.deviceId, codec: AudioCodec.opus)
///       ..addFileOutput('rec.mkv', container: Container.mkv))
///     .build();
/// await rec.start();
/// await Future.delayed(const Duration(seconds: 10));
/// await rec.stop();
/// ```
library;

export 'package:miniav_tools/miniav_tools.dart'
    show MiniAVTools, WarmupProgress;

export 'src/audio_effect.dart';
export 'src/clip_buffer.dart';
export 'src/container_utils.dart';
export 'src/gpu_screen_processor.dart' show GpuScreenProcessor;
export 'src/recorder.dart';
export 'src/recorder_builder.dart';
export 'src/recorder_devices.dart';
export 'src/screen_effect.dart';
export 'src/screen_scale_policy.dart';
export 'src/track_chunk.dart';
