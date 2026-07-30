/// miniav_player E2E demo — one codebase, runs on BOTH web and native.
///
///   synthetic RGBA frame + sine tone
///     → MiniAVTools.createEncoder / createAudioEncoder  (the facade picks the
///       platform backend: WebCodecs on web, FFmpeg on native)
///     → in-process EncodedPacket loopback
///     → MiniavPlayer.open  (decode → GPU YUV→RGBA → minigpu_view present,
///       zero readback; audio → miniaudio sink)
///
/// The default `packet` mode above is fully cross-platform through the
/// `MiniAVTools` facade — it's the "does the player work here?" smoke and shows
/// a PASS/FAIL verdict on-page (also printed as `PLAYER-SMOKE:` to the console).
///
/// On native, two extra Phase-2 modes exist (select with the first CLI arg,
/// e.g. `player stream` / `player file`) that exercise the container paths —
/// a live fMP4 byte-stream and an MP4 file with a mid-playback seek. They need
/// the FFmpeg muxer + `dart:io`, so they live behind `container_modes.dart`'s
/// conditional import and are self-verifying (write a json + exit 0/1). On web
/// only `packet` is reachable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Container;
import 'package:miniav_player/miniav_player.dart';

import 'container_modes.dart';
import 'mse_smoke.dart';

const int kW = 320;
const int kH = 240;
const int kFps = 30;
const int kSampleRate = 48000;
const int kChannels = 2;
const int kAudioFrame = 960; // Opus samples per 20 ms frame at 48 kHz

void main(List<String> args) {
  final mode = args.isNotEmpty ? args.first : 'packet';
  WidgetsFlutterBinding.ensureInitialized();
  // Bind Dawn to the primary-display adapter so the native present texture can
  // be shared with Flutter's ANGLE — must run before any minigpu init. No-op
  // on web (the player presents to a canvas).
  preInitNativeGpu();
  if (mode != 'packet' && containerModesSupported) {
    // Native-only Phase-2 container smoke (self-verifying, exits 0/1).
    runContainerApp(mode, args);
    return;
  }
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: _Page(),
  );
}

class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  MiniavPlayer? _player;
  String _status = 'starting…';
  String _hud = '';
  String? _verdict;
  final List<String> _errors = [];
  Timer? _uiTimer;
  Timer? _feedTimer;
  Timer? _audioTimer;
  bool _hasAudio = false;
  int _audioProbeFrames = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final p = _player;
      if (p != null && mounted && !_done) {
        setState(() => _hud = p.stats.toString());
      }
    });
    _run();
  }

  Future<void> _run() async {
    try {
      // Register the platform codec backend — FFmpeg on native, WebCodecs on
      // web (chosen by the player's conditional import) — and warm it up
      // (native downloads the FFmpeg libs on first run; web is a no-op).
      registerPlayerBackends();
      setState(() => _status = 'warming up codec backend…');
      await MiniAVTools.warmup().drain<void>();

      setState(() => _status = 'encoding synthetic H.264 frames…');
      final enc = await MiniAVTools.createEncoder(
        const EncoderConfig(
          codec: VideoCodec.h264,
          width: kW,
          height: kH,
          bitrateBps: 1500000,
          gopLength: kFps,
          frameRateNumerator: kFps,
          frameRateDenominator: 1,
        ),
      );

      // Encode a batch of frames up front → packets + avcC extradata.
      final packets = <EncodedPacket>[];
      for (var i = 0; i < 90; i++) {
        final pkt = await enc.encode(
          FrameSource.cpu(
            bytes: _testCardRgba(i),
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: kW,
            height: kH,
            timestampUs: (i * 1000000) ~/ kFps,
          ),
        );
        if (pkt != null) packets.add(pkt);
      }
      packets.addAll(await enc.flush());
      final asc = enc.extraData?.bytes;
      await enc.close();
      if (packets.isEmpty) {
        return _finish(fail: 'encoder produced no packets');
      }

      // Encode a batch of Opus audio (facade AudioEncoder) → packets + config.
      final audioPackets = <EncodedPacket>[];
      Uint8List? opusHeader;
      // Opus, not AAC: WebCodecs Opus encode+decode is universally supported,
      // whereas the AAC *encoder* is often absent (needs a platform encoder —
      // a real per-codec capability gap). On native, FFmpeg's libopus handles
      // the same path, so this block is identical across platforms. If the
      // audio codec is unavailable, we degrade to a video-only demo.
      try {
        setState(() => _status = 'encoding synthetic audio (Opus)…');
        final aenc = await MiniAVTools.createAudioEncoder(
          const AudioEncoderConfig(
            codec: AudioCodec.opus,
            sampleRate: kSampleRate,
            channels: kChannels,
            bitrateBps: 128000,
          ),
        );
        for (var i = 0; i < 90; i++) {
          audioPackets.addAll(
            await aenc.encode(
              pcm: _sinePcmF32(i * kAudioFrame, kAudioFrame),
              format: MiniAVAudioFormat.f32,
              frameCount: kAudioFrame,
              ptsUs: (i * kAudioFrame * 1000000) ~/ kSampleRate,
            ),
          );
        }
        audioPackets.addAll(await aenc.flush());
        opusHeader = aenc.extraData?.bytes;
        await aenc.close();

        // PROBE: decode a few packets in isolation to prove the audio decoder
        // produces frames (isolates decode from the sink).
        try {
          final probe = await MiniAVTools.createAudioDecoder(
            AudioDecoderConfig(
              codec: AudioCodec.opus,
              extraData: opusHeader,
              sampleRate: kSampleRate,
              channels: kChannels,
            ),
          );
          var probeFrames = 0;
          for (final p in audioPackets.take(12)) {
            for (final c in await probe.decode(p)) {
              probeFrames += c.frameCount;
            }
          }
          for (final c in await probe.flush()) {
            probeFrames += c.frameCount;
          }
          await probe.close();
          _audioProbeFrames = probeFrames;
        } catch (e) {
          _errors.add('audio decode probe: $e');
        }
      } catch (e) {
        // Audio codec unavailable on this platform — run a video-only demo.
        audioPackets.clear();
        opusHeader = null;
        _errors.add('audio setup skipped: $e');
      }

      setState(() => _status = 'opening player…');
      final player = await MiniavPlayer.open(
        video: VideoStreamSpec(
          config: DecoderConfig(codec: VideoCodec.h264, extraData: asc),
        ),
        audio: audioPackets.isNotEmpty
            ? AudioStreamSpec(
                config: AudioDecoderConfig(
                  codec: AudioCodec.opus,
                  extraData: opusHeader,
                  sampleRate: kSampleRate,
                  channels: kChannels,
                ),
              )
            : null,
        // Container-less packet feed at real time → live latest-wins is fine
        // (we submit one packet per frame interval, no burst).
        latency: PlayerLatencyMode.live,
        onError: (e, s) => _errors.add('$e'),
      );
      _hasAudio = audioPackets.isNotEmpty;
      setState(() {
        _player = player;
        _status =
            'playing${_hasAudio ? " (A/V)" : " (video)"} '
            '· video=${player.videoDecoderBackend}'
            '${_hasAudio ? " audio=${player.audioDecoderBackend}" : ""}…';
      });

      // Feed video at 30 fps + audio at its own rate, looping each batch.
      var vIdx = 0;
      final started = DateTime.now();
      _feedTimer = Timer.periodic(Duration(microseconds: 1000000 ~/ kFps), (_) {
        if (_done) return;
        player.submitVideoPacket(packets[vIdx % packets.length]);
        vIdx++;
        if (DateTime.now().difference(started) > const Duration(seconds: 5)) {
          _evaluate(player);
        }
      });
      if (audioPackets.isNotEmpty) {
        // 20 ms per 960-sample Opus frame at 48 kHz.
        var aIdx = 0;
        _audioTimer = Timer.periodic(
          Duration(microseconds: kAudioFrame * 1000000 ~/ kSampleRate),
          (_) {
            if (_done) return;
            player.submitAudioPacket(audioPackets[aIdx % audioPackets.length]);
            aIdx++;
          },
        );
      }
    } catch (e, s) {
      _finish(fail: 'setup failed: $e\n$s');
    }
  }

  Future<void> _evaluate(MiniavPlayer player) async {
    if (_done) return;
    final s = player.stats;
    var firstFrame = true;
    try {
      await player.onFirstFrame.timeout(const Duration(milliseconds: 1));
    } on TimeoutException {
      firstFrame = false;
    }
    final checks = <String, bool>{
      'firstFramePresented': firstFrame,
      'decoded>=60': s.videoFramesDecoded >= 60,
      'presented>=30': s.videoFramesPresented >= 30,
      'noDecodeErrors': player.videoDecodeErrorCount == 0,
      'noPresentErrors': player.presentErrorCount == 0,
      'noPipelineErrors': _errors.isEmpty,
      // Audio (when present): Opus decode → miniaudio sink. Frames-WRITTEN
      // (>0) proves the decode→sink path works. We can't require sustained
      // draining: without a user gesture a browser keeps the AudioContext
      // suspended, so the ring fills (~one bufferMs) and then stops accepting —
      // audible playback needs a gesture, not verifiable headlessly.
      if (_hasAudio) 'audioDecoded': player.audioDecodeErrorCount == 0,
      if (_hasAudio) 'audioSinkAccepted': s.audioFramesWritten > 0,
    };
    _finish(
      diag: _hasAudio
          ? 'video=${player.videoDecoderBackend} '
                'audio=${player.audioDecoderBackend} '
                'presented=${s.videoFramesPresented} '
                'audioProbeDecoded=$_audioProbeFrames '
                'audioWritten=${s.audioFramesWritten}'
          : 'video=${player.videoDecoderBackend} '
                'presented=${s.videoFramesPresented}',
      pass: checks.values.every((v) => v),
      checks: checks,
      stats: s,
    );
  }

  void _finish({
    bool pass = false,
    String? fail,
    String? diag,
    Map<String, bool>? checks,
    PlayerStats? stats,
  }) {
    if (_done) return;
    _done = true;
    _feedTimer?.cancel();
    _audioTimer?.cancel();
    _uiTimer?.cancel();
    final ok = fail == null && pass;
    final result = {
      'mode': 'packet',
      'pass': ok,
      'reason': ?fail,
      'diag': ?diag,
      'checks': ?checks,
      if (stats != null) 'stats': stats.toString(),
      'errors': _errors,
    };
    // ignore: avoid_print
    print('PLAYER-SMOKE: ${ok ? 'PASS' : 'FAIL'} ${jsonEncode(result)}');
    setState(() {
      _verdict = ok ? 'PASS' : 'FAIL: ${fail ?? _failedChecks(checks)}';
      _status = 'done';
      if (stats != null) _hud = stats.toString();
    });
  }

  String _failedChecks(Map<String, bool>? checks) => checks == null
      ? '?'
      : checks.entries.where((e) => !e.value).map((e) => e.key).join(', ');

  @override
  void dispose() {
    _feedTimer?.cancel();
    _audioTimer?.cancel();
    _uiTimer?.cancel();
    _player?.close();
    super.dispose();
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
              style: const TextStyle(color: Colors.greenAccent, fontSize: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('miniav_player smoke — $_status'),
                  Text(_hud),
                  if (_verdict != null)
                    Text(
                      _verdict!,
                      style: TextStyle(
                        color: _verdict!.startsWith('PASS')
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  if (_errors.isNotEmpty)
                    Text(
                      'errors: ${_errors.take(3).join(' | ')}',
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  const SizedBox(height: 8),
                  const MseSmoke(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Phase-continuous 440 Hz stereo sine, interleaved f32 (Opus encoder input).
Uint8List _sinePcmF32(int startFrame, int frameCount) {
  final out = Float32List(frameCount * kChannels);
  for (var i = 0; i < frameCount; i++) {
    final t = startFrame + i;
    final v = math.sin(2 * math.pi * 440.0 * t / kSampleRate) * 0.25;
    for (var c = 0; c < kChannels; c++) {
      out[i * kChannels + c] = v;
    }
  }
  return out.buffer.asUint8List();
}

/// Animated test card so encode/decode isn't degenerate.
Uint8List _testCardRgba(int frame) {
  final out = Uint8List(kW * kH * 4);
  final blockX = (frame * 5) % (kW - 48);
  final blockY = (frame * 3) % (kH - 48);
  for (var y = 0; y < kH; y++) {
    for (var x = 0; x < kW; x++) {
      final i = (y * kW + x) * 4;
      final inBlock =
          x >= blockX && x < blockX + 48 && y >= blockY && y < blockY + 48;
      if (inBlock) {
        out[i] = 255;
        out[i + 1] = 255;
        out[i + 2] = 255;
      } else {
        out[i] = (x + frame * 3) % 256;
        out[i + 1] = (y + frame) % 256;
        out[i + 2] = 128;
      }
      out[i + 3] = 255;
    }
  }
  return out;
}
