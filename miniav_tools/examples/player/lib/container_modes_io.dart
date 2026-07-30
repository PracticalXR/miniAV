/// Native-only Phase-2 container modes for the unified player example.
///
///   stream — encode → FfmpegMuxer fMP4 → live chunk stream →
///            MiniavPlayer.openSource(MediaSource.byteStream) (live demux).
///   file   — encode → MP4 file → MiniavPlayer.openSource(file) with a
///            mid-playback seek + onEnded (VOD path).
///
/// These need the FFmpeg muxer + `dart:io`, so they live behind the
/// `container_modes.dart` conditional import and never reach the web build.
/// Self-verifying: writes `player_smoke_result_<mode>.json`, prints a
/// `PLAYER-SMOKE:` marker, exits 0/1.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Container;
import 'package:miniav_player/miniav_player.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show
        registerFfmpegBackend,
        ensureFFmpegLoaded,
        FfmpegMuxer,
        FfmpegEncoderBridge;
import 'package:minigpu/minigpu.dart';

const int kW = 640;
const int kH = 360;
const int kFps = 30;
const int kSampleRate = 48000;
const int kChannels = 2;
const int kAudioChunkFrames = 960; // 20 ms

/// The FFmpeg-backed container modes are available on native.
const bool containerModesSupported = true;

/// Bind Dawn to the primary-display adapter so Flutter's ANGLE (same adapter)
/// can open the shared present texture — MUST run before any minigpu init.
void preInitNativeGpu() => Minigpu.preferDisplayAdapter();

/// Launch the native container smoke app. [mode] is 'stream' or 'file';
/// for 'stream', `args[1]` optionally selects 'paced' (default) or 'live'.
void runContainerApp(String mode, List<String> args) {
  runApp(
    _ContainerApp(
      mode: mode,
      streamLatency: args.length > 1 ? args[1] : 'paced',
    ),
  );
}

class _ContainerApp extends StatelessWidget {
  const _ContainerApp({required this.mode, required this.streamLatency});
  final String mode;
  final String streamLatency;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: _ContainerPage(mode: mode, streamLatency: streamLatency),
  );
}

class _ContainerPage extends StatefulWidget {
  const _ContainerPage({required this.mode, required this.streamLatency});
  final String mode;
  final String streamLatency;

  @override
  State<_ContainerPage> createState() => _ContainerPageState();
}

class _ContainerPageState extends State<_ContainerPage> {
  MiniavPlayer? _player;
  String _status = 'starting…';
  String _statsLine = '';
  final List<String> _errors = [];
  Timer? _uiTimer;
  bool _done = false;

  String get _mode => widget.mode;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final p = _player;
      if (p != null && mounted && !_done) {
        setState(() => _statsLine = p.stats.toString());
      }
    });
    _run();
  }

  Future<void> _run() async {
    try {
      setState(() => _status = '[$_mode] loading FFmpeg…');
      registerFfmpegBackend();
      if (!await ensureFFmpegLoaded()) {
        return _finish(fail: 'FFmpeg failed to load');
      }
      switch (_mode) {
        case 'stream':
          await _runStreamMode();
        case 'file':
          await _runFileMode();
        default:
          _finish(fail: 'unknown container mode "$_mode"');
      }
    } catch (e, s) {
      _finish(fail: 'setup failed: $e\n$s');
    }
  }

  // ---------------------------------------------------------------------------
  // Mode: stream (live fMP4 chunk stream → openSource)
  // ---------------------------------------------------------------------------

  Future<void> _runStreamMode() async {
    final (venc, aenc, _) = await _openEncoders();
    final chunks = StreamController<List<int>>();
    final muxer = FfmpegMuxer.open(
      MuxerConfig(
        container: Container.fmp4,
        output: MuxerOutput.callback(chunks.add),
        fragmentDurationUs: 100000,
        tracks: const [
          VideoTrackInfo(
            codec: VideoCodec.h264,
            width: kW,
            height: kH,
            frameRateNumerator: kFps,
            frameRateDenominator: 1,
          ),
          AudioTrackInfo(
            codec: AudioCodec.aac,
            sampleRate: kSampleRate,
            channels: kChannels,
          ),
        ],
      ),
      encoderForTrack: {
        0: venc.platform as FfmpegEncoderBridge,
        1: aenc.platform as FfmpegEncoderBridge,
      },
    );
    await muxer.writeHeader(); // init segment → chunk stream

    // Server side: keep encoding+muxing on timers.
    var videoFrame = 0;
    var audioFrame = 0;
    final videoTimer = Timer.periodic(Duration(microseconds: 1000000 ~/ kFps), (
      _,
    ) async {
      final i = videoFrame++;
      try {
        final pkt = await venc.encode(_frameSource(i));
        if (pkt != null) await muxer.writePacket(pkt.copyWith(trackIndex: 0));
      } catch (e) {
        _errors.add('mux video: $e');
      }
    });
    final audioTimer = Timer.periodic(const Duration(milliseconds: 20), (
      _,
    ) async {
      final start = audioFrame;
      audioFrame += kAudioChunkFrames;
      try {
        for (final p in await aenc.encode(
          pcm: _sinePcmS16(start, kAudioChunkFrames),
          format: MiniAVAudioFormat.s16,
          frameCount: kAudioChunkFrames,
          ptsUs: (start * 1000000) ~/ kSampleRate,
        )) {
          await muxer.writePacket(p.copyWith(trackIndex: 1));
        }
      } catch (e) {
        _errors.add('mux audio: $e');
      }
    });

    // Client side: play the live container stream.
    final latency = widget.streamLatency == 'live'
        ? PlayerLatencyMode.live
        : PlayerLatencyMode.paced;
    setState(() => _status = '[stream:${widget.streamLatency}] opening player…');
    final player = await MiniavPlayer.openSource(
      MediaSource.byteStream(chunks.stream),
      latency: latency,
      onError: (e, s) => _errors.add('$e'),
    );
    player.volume = 0.05;
    final playStart = DateTime.now();
    setState(() {
      _player = player;
      _status = '[stream:${widget.streamLatency}] playing live fMP4…';
    });

    Timer(const Duration(seconds: 6), () async {
      videoTimer.cancel();
      audioTimer.cancel();
      final s = player.stats;
      final firstFrame = await _completed(player.onFirstFrame);
      final elapsedS =
          DateTime.now().difference(playStart).inMilliseconds / 1000.0;
      final presentFps = s.videoFramesPresented / elapsedS;
      // paced is the correct mode for a demuxed broadcast (smooth ~30fps,
      // no supersession); live latest-wins collapses each demuxed fragment
      // burst to ~2 presented frames — the guard catches a regression to it.
      final smooth = widget.streamLatency == 'live' || presentFps >= 24;
      _finish(
        diag:
            'stream:${widget.streamLatency} '
            'presentFps=${presentFps.toStringAsFixed(1)} '
            'sup=${s.videoFramesDroppedSuperseded} audioDrop=${s.audioFramesDropped}',
        stats: s,
        checks: {
          'firstFramePresented': firstFrame,
          'decoded>=60': s.videoFramesDecoded >= 60,
          'presented>=30': s.videoFramesPresented >= 30,
          'smoothPresentFps': smooth,
          'noPresentErrors': player.presentErrorCount == 0,
          'noDecodeErrors':
              player.videoDecodeErrorCount == 0 &&
              player.audioDecodeErrorCount == 0,
          'noSourceErrors': player.sourceErrorCount == 0,
          'notSeekable(live)': !player.isSeekable,
          'audioWritten>=2s': s.audioFramesWritten >= 2 * kSampleRate,
          'noPipelineErrors': _errors.isEmpty,
        },
      );
      await muxer.finish();
      await muxer.close();
      await chunks.close();
    });
  }

  // ---------------------------------------------------------------------------
  // Mode: file (MP4 file → openSource + seek + onEnded)
  // ---------------------------------------------------------------------------

  Future<void> _runFileMode() async {
    setState(() => _status = '[file] recording a 4 s clip…');
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}miniav_player_smoke.mp4';
    final f = File(path);
    if (f.existsSync()) f.deleteSync();

    final (venc, aenc, _) = await _openEncoders();
    final muxer = FfmpegMuxer.open(
      MuxerConfig(
        container: Container.mp4,
        output: MuxerOutput.file(path),
        tracks: const [
          VideoTrackInfo(
            codec: VideoCodec.h264,
            width: kW,
            height: kH,
            frameRateNumerator: kFps,
            frameRateDenominator: 1,
          ),
          AudioTrackInfo(
            codec: AudioCodec.aac,
            sampleRate: kSampleRate,
            channels: kChannels,
          ),
        ],
      ),
      encoderForTrack: {
        0: venc.platform as FfmpegEncoderBridge,
        1: aenc.platform as FfmpegEncoderBridge,
      },
    );
    await muxer.writeHeader();
    const totalFrames = 4 * kFps;
    for (var i = 0; i < totalFrames; i++) {
      final pkt = await venc.encode(_frameSource(i));
      if (pkt != null) await muxer.writePacket(pkt.copyWith(trackIndex: 0));
    }
    for (final p in await venc.flush()) {
      await muxer.writePacket(p.copyWith(trackIndex: 0));
    }
    for (var start = 0; start < 4 * kSampleRate; start += kAudioChunkFrames) {
      for (final p in await aenc.encode(
        pcm: _sinePcmS16(start, kAudioChunkFrames),
        format: MiniAVAudioFormat.s16,
        frameCount: kAudioChunkFrames,
        ptsUs: (start * 1000000) ~/ kSampleRate,
      )) {
        await muxer.writePacket(p.copyWith(trackIndex: 1));
      }
    }
    for (final p in await aenc.flush()) {
      await muxer.writePacket(p.copyWith(trackIndex: 1));
    }
    await muxer.finish();
    await muxer.close();
    await venc.close();
    await aenc.close();

    setState(() => _status = '[file] playing $path…');
    final player = await MiniavPlayer.openSource(
      MediaSource.file(path),
      onError: (e, s) => _errors.add('$e'),
    );
    player.volume = 0.05;
    setState(() => _player = player);

    final durationOk =
        player.duration != null &&
        player.duration! > const Duration(seconds: 3) &&
        player.duration! < const Duration(seconds: 6);

    // Play ~1.5 s, then seek back to 0.5 s, then let it run to the end.
    await player.onFirstFrame.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final presentedBeforeSeek = player.stats.videoFramesPresented;
    setState(() => _status = '[file] seeking to 0.5 s…');
    await player.seek(const Duration(milliseconds: 500));
    setState(() => _status = '[file] playing to end…');
    // Actually WAIT for playback to reach end-of-stream (drain fires
    // onEnded). Bounded so a stall surfaces as a failed check, not a hang.
    var endedInTime = true;
    try {
      await player.onEnded.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      endedInTime = false;
    }

    final s = player.stats;
    final position = player.position;
    _finish(
      stats: s,
      checks: {
        'durationProbed': durationOk,
        'seekable': player.isSeekable,
        'presentedBeforeSeek>=20': presentedBeforeSeek >= 20,
        'endedInTime': endedInTime,
        // ~1.5 s pre-seek (45) + ~3.5 s post-seek (105) minus drops.
        'presentedTotal>=100': s.videoFramesPresented >= 100,
        'positionNearEnd':
            position != null && position > const Duration(seconds: 3),
        'noPresentErrors': player.presentErrorCount == 0,
        'noDecodeErrors':
            player.videoDecodeErrorCount == 0 &&
            player.audioDecodeErrorCount == 0,
        'noSourceErrors': player.sourceErrorCount == 0,
        'noPipelineErrors': _errors.isEmpty,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Shared plumbing
  // ---------------------------------------------------------------------------

  Future<(Encoder, AudioEncoder, Uint8List)> _openEncoders() async {
    setState(() => _status = '[$_mode] opening encoders…');
    final venc = await MiniAVTools.createEncoder(
      EncoderConfig(
        codec: VideoCodec.h264,
        width: kW,
        height: kH,
        bitrateBps: 2000000,
        gopLength: kFps,
        frameRateNumerator: kFps,
        frameRateDenominator: 1,
        rateControl: RateControl.crf,
        crfQuality: 23,
        hwAccel: HwAccelPreference.forbidden,
        backendOptions: const {
          'preset': 'ultrafast',
          'tune': 'zerolatency',
          // Mux modes bind the encoder bridge (needs the in-isolate encoder)
          // and want out-of-band SPS/PPS in the container.
          'sw_isolate': '0',
          'global_header': '1',
        },
      ),
    );
    final aenc = await MiniAVTools.createAudioEncoder(
      const AudioEncoderConfig(
        codec: AudioCodec.aac,
        sampleRate: kSampleRate,
        channels: kChannels,
        bitrateBps: 128000,
        backendOptions: {'global_header': '1'},
      ),
    );
    final asc = aenc.extraData?.bytes;
    if (asc == null) {
      throw StateError('AAC encoder exposed no ASC extradata');
    }
    return (venc, aenc, asc);
  }

  FrameSource _frameSource(int i) => FrameSource.cpu(
    bytes: _testCardRgba(i),
    pixelFormat: MiniAVPixelFormat.rgba32,
    width: kW,
    height: kH,
    timestampUs: (i * 1000000) ~/ kFps,
  );

  Future<bool> _completed(Future<void> f) async {
    try {
      await f.timeout(const Duration(milliseconds: 1));
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _finish({
    String? fail,
    String? diag,
    PlayerStats? stats,
    Map<String, bool>? checks,
  }) async {
    if (_done) return;
    _done = true;
    _uiTimer?.cancel();
    var reason = fail;
    if (reason == null && checks != null) {
      final failed = checks.entries.where((e) => !e.value).map((e) => e.key);
      if (failed.isNotEmpty) reason = 'checks failed: ${failed.join(', ')}';
    }
    final pass = reason == null;
    final result = <String, Object?>{
      'mode': _mode,
      'pass': pass,
      'reason': ?reason,
      'diag': ?diag,
      'checks': ?checks,
      if (stats != null) 'stats': stats.toString(),
      'errors': _errors,
    };
    // ignore: avoid_print
    print('PLAYER-SMOKE: ${pass ? 'PASS' : 'FAIL'} ${jsonEncode(result)}');
    try {
      File(
        'player_smoke_result_$_mode.json',
      ).writeAsStringSync(jsonEncode(result));
    } catch (_) {}
    try {
      await _player?.close();
    } catch (_) {}
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (player != null)
            Positioned.fill(child: MiniavPlayerView(player: player)),
          Positioned(
            left: 12,
            top: 12,
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('miniav_player [$_mode] smoke — $_status'),
                  Text(_statsLine),
                  if (_errors.isNotEmpty)
                    Text(
                      'errors: ${_errors.take(3).join(' | ')}',
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Synthetic sources
// ---------------------------------------------------------------------------

/// Animated test card: hue-shifting bars + a moving white block.
Uint8List _testCardRgba(int frame) {
  final out = Uint8List(kW * kH * 4);
  final barPhase = frame * 3;
  final blockX = (frame * 7) % (kW - 64);
  final blockY = (frame * 3) % (kH - 64);
  for (var y = 0; y < kH; y++) {
    for (var x = 0; x < kW; x++) {
      final i = (y * kW + x) * 4;
      final inBlock =
          x >= blockX && x < blockX + 64 && y >= blockY && y < blockY + 64;
      if (inBlock) {
        out[i] = 255;
        out[i + 1] = 255;
        out[i + 2] = 255;
      } else {
        out[i] = (x + barPhase) % 256;
        out[i + 1] = (y + frame) % 256;
        out[i + 2] = ((x + y) >> 1) % 256;
      }
      out[i + 3] = 255;
    }
  }
  return out;
}

/// Phase-continuous 440 Hz stereo sine, s16 interleaved.
Uint8List _sinePcmS16(int startFrame, int frameCount) {
  final out = Int16List(frameCount * kChannels);
  for (var i = 0; i < frameCount; i++) {
    final t = startFrame + i;
    final v = (math.sin(2 * math.pi * 440.0 * t / kSampleRate) * 9000).round();
    for (var c = 0; c < kChannels; c++) {
      out[i * kChannels + c] = v;
    }
  }
  return out.buffer.asUint8List();
}
