/// camera_mp4.dart
///
/// Camera → MP4 example. Mirrors the structure of `screenshare_mp4` but
/// for webcam input (CPU-side NV12/BGRA/YUY2 from MediaFoundation/AVFoundation/V4L2).
///
/// Data path:
///   miniav MiniCamera → CPU buffer (NV12 / BGRA / YUY2 / I420 / RGB24)
///     → FrameSource.miniavBuffer
///     → FfmpegHwEncoder (NVENC / AMF / QSV / VideoToolbox / MF)
///       or FfmpegSoftwareEncoder libx264
///     → FfmpegMuxer → output.mp4
///
/// Usage:
///   dart run bin/camera_mp4.dart [seconds] [output.mp4] [--hw] [--device=ID] [--width=W --height=H]
///
///   --hw           Use the best available hardware encoder.
///   --device=ID    Camera device ID (default = first / system default).
///   --width / --height / --fps  Override format selection.
///   --list         List camera devices and exit.
library;

import 'dart:io';

import 'package:miniav/miniav.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

const int _defaultDurationSeconds = 10;
const int _targetBitrateBps = 4 * 1000 * 1000; // 4 Mbps

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final useHw = args.contains('--hw');
  final listOnly = args.contains('--list');

  String? deviceId;
  int? wantW;
  int? wantH;
  int? wantFps;
  for (final a in args) {
    if (a.startsWith('--device=')) deviceId = a.substring('--device='.length);
    if (a.startsWith('--width='))
      wantW = int.tryParse(a.substring('--width='.length));
    if (a.startsWith('--height='))
      wantH = int.tryParse(a.substring('--height='.length));
    if (a.startsWith('--fps='))
      wantFps = int.tryParse(a.substring('--fps='.length));
  }

  final int durationSecs = positional.isNotEmpty
      ? int.tryParse(positional[0]) ?? _defaultDurationSeconds
      : _defaultDurationSeconds;
  final String outputPath = positional.length >= 2
      ? positional[1]
      : 'camera_output.mp4';

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  // ── 1. Enumerate cameras ──────────────────────────────────────────────────
  final devices = await MiniCamera.enumerateDevices();
  if (devices.isEmpty) {
    stderr.writeln('[error] No camera devices found.');
    exit(1);
  }

  if (listOnly) {
    print('Available cameras:');
    for (final d in devices) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    exit(0);
  }

  final device = deviceId != null
      ? devices.firstWhere(
          (d) => d.deviceId == deviceId,
          orElse: () =>
              throw StateError('Camera deviceId "$deviceId" not found.'),
        )
      : devices.firstWhere((d) => d.isDefault, orElse: () => devices.first);

  print('━━━ camera → MP4 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('  Duration : ${durationSecs}s');
  print('  Output   : $outputPath');
  print('  Device   : ${device.name} (${device.deviceId})');

  // ── 2. Choose a video format ──────────────────────────────────────────────
  final formats = await MiniCamera.getSupportedFormats(device.deviceId);
  if (formats.isEmpty) {
    stderr.writeln('[error] Camera reports no supported formats.');
    exit(1);
  }

  MiniAVVideoInfo pickFormat() {
    Iterable<MiniAVVideoInfo> candidates = formats;
    if (wantW != null) candidates = candidates.where((f) => f.width == wantW);
    if (wantH != null) candidates = candidates.where((f) => f.height == wantH);
    if (wantFps != null) {
      candidates = candidates.where(
        (f) =>
            (f.frameRateNumerator / f.frameRateDenominator).round() == wantFps,
      );
    }
    final list = candidates.toList();
    if (list.isNotEmpty) return list.first;
    // No exact match — prefer 1920x1080 @ ~30fps then fall back to default.
    final preferred = formats
        .where((f) => f.width == 1920 && f.height == 1080)
        .toList();
    if (preferred.isNotEmpty) return preferred.first;
    return formats.first;
  }

  final base = pickFormat();
  final captureFormat = MiniAVVideoInfo(
    width: base.width,
    height: base.height,
    pixelFormat: base.pixelFormat,
    frameRateNumerator: base.frameRateNumerator,
    frameRateDenominator: base.frameRateDenominator,
    outputPreference: MiniAVOutputPreference.cpu,
  );

  final int W = captureFormat.width;
  final int H = captureFormat.height;
  final int fpsNum = captureFormat.frameRateNumerator;
  final int fpsDen = captureFormat.frameRateDenominator;
  final int fps = fpsDen > 0 ? (fpsNum ~/ fpsDen) : 30;
  print(
    '  Format   : ${W}x${H} @ ${fps}fps  ${base.pixelFormat.name.toUpperCase()}  (CPU)',
  );

  // ── 3. Load FFmpeg ────────────────────────────────────────────────────────
  print('\n[ffmpeg] Loading libraries…');
  if (!await ensureFFmpegLoaded()) {
    stderr.writeln('[error] Could not load FFmpeg.');
    exit(1);
  }
  print('[ffmpeg] Ready.');

  // ── 4. Create encoder ─────────────────────────────────────────────────────
  // H.264 HW caps at 4096px wide; promote to HEVC if needed.
  final backend = FfmpegBackend();
  final chosenCodec = FfmpegBackend.bestCodecForResolution(
    width: W,
    height: H,
    hwAccel: useHw,
    preferred: VideoCodec.h264,
  );
  if (chosenCodec != VideoCodec.h264) {
    print('[encoder] ${W}x${H} promoted to ${chosenCodec.name.toUpperCase()}.');
  }
  final encoderCfg = EncoderConfig(
    codec: chosenCodec,
    width: W,
    height: H,
    bitrateBps: _targetBitrateBps,
    frameRateNumerator: fpsNum,
    frameRateDenominator: fpsDen,
    bFrameCount: 0,
    hwAccel: useHw ? HwAccelPreference.preferred : HwAccelPreference.forbidden,
    rateControl: RateControl.vbr,
    backendOptions: useHw
        ? const {'preset': 'p4', 'tune': 'll', 'global_header': '1'}
        : const {
            'preset': 'ultrafast',
            'tune': 'zerolatency',
            'global_header': '1',
          },
  );

  final platformEncoder = await backend.createEncoder(encoderCfg);
  if (platformEncoder == null) {
    stderr.writeln(
      '[error] Failed to create ${chosenCodec.name.toUpperCase()} encoder.',
    );
    exit(1);
  }
  final encoderName = platformEncoder is FfmpegD3d11HwEncoder
      ? platformEncoder.encoderName
      : platformEncoder is FfmpegHwEncoder
      ? platformEncoder.encoderName
      : 'libx264';
  print(
    '[encoder] ${chosenCodec.name.toUpperCase()} $encoderName ${W}x${H} @ ${fps}fps ready.',
  );

  // ── 5. Open MP4 muxer ─────────────────────────────────────────────────────
  final muxerCfg = MuxerConfig(
    container: Container.mp4,
    output: MuxerOutput.file(outputPath),
    tracks: [
      VideoTrackInfo(
        codec: chosenCodec,
        width: W,
        height: H,
        frameRateNumerator: fpsNum,
        frameRateDenominator: fpsDen,
      ),
    ],
  );
  final muxer = FfmpegMuxer.open(
    muxerCfg,
    encoderForTrack: {0: platformEncoder as FfmpegEncoderBridge},
  );
  await muxer.writeHeader();
  print('[muxer ] MP4 → $outputPath  (header written)');

  // ── 6. Capture ────────────────────────────────────────────────────────────
  final cam = await MiniCamera.createContext();
  await cam.configure(device.deviceId, captureFormat);

  int frameIn = 0;
  int frameOut = 0;
  int bytesWritten = 0;
  int framesDropped = 0;
  bool busy = false;
  bool stopping = false;

  print('\n[capture] Starting… (${durationSecs}s)');

  await cam.startCapture((MiniAVBuffer buffer, Object? _) async {
    if (busy || stopping) {
      framesDropped++;
      await MiniAV.releaseBuffer(buffer);
      return;
    }
    busy = true;
    try {
      frameIn++;
      try {
        final pkt = await platformEncoder.encode(
          FrameSource.miniavBuffer(buffer),
        );
        if (pkt != null) {
          await muxer.writePacket(pkt);
          frameOut++;
          bytesWritten += pkt.data.length;
        }
      } catch (e, st) {
        stderr.writeln('[encode] frame $frameIn error: $e');
        if (frameIn <= 2) stderr.writeln(st);
      } finally {
        await MiniAV.releaseBuffer(buffer);
      }
      if (frameIn % 30 == 0) {
        stdout.write(
          '\r  frame=$frameIn  encoded=$frameOut  '
          'written=${(bytesWritten / 1024).toStringAsFixed(0)}KB  '
          'dropped=$framesDropped   ',
        );
      }
    } finally {
      busy = false;
    }
  });

  await Future.delayed(Duration(seconds: durationSecs));
  print('\n\n[capture] Stopping…');
  stopping = true;
  await cam.stopCapture();
  await cam.destroy();

  while (busy) {
    await Future.delayed(const Duration(milliseconds: 10));
  }

  print('[encoder] Flushing…');
  for (final pkt in await platformEncoder.flush()) {
    await muxer.writePacket(pkt);
    frameOut++;
  }

  await muxer.finish();
  await muxer.close();
  await platformEncoder.close();
  MiniAV.dispose();

  final file = File(outputPath);
  final fileSizeKb = file.existsSync()
      ? (file.lengthSync() / 1024).toStringAsFixed(0)
      : '?';
  print('');
  print('━━━ Done ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('  Captured : $frameIn frames');
  print('  Encoded  : $frameOut packets');
  print('  Output   : $outputPath  (${fileSizeKb}KB)');
  print('─────────────────────────────────────────────────────────────');
}
