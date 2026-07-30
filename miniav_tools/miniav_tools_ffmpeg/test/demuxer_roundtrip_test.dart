/// Demuxer roundtrips: encode H.264+AAC → mux → demux back, across all three
/// input flavours (in-memory bytes, file + seek, live progressive byte
/// stream), plus the starved-worker shutdown path.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

const int kW = 320;
const int kH = 240;
const int kFps = 30;
const int kFrames = 30;
const int kSampleRate = 48000;
const int kChannels = 2;

/// Encode one second of synthetic A/V and mux into [output]. Returns the
/// number of video packets written and, for [BytesMuxerOutput], the muxed
/// container bytes.
Future<(int, Uint8List?)> _encodeAv({
  required Container container,
  required MuxerOutput output,
}) async {
  final backend = FfmpegBackend();
  final v = (await backend.createEncoder(
    const EncoderConfig(
      codec: VideoCodec.h264,
      width: kW,
      height: kH,
      bitrateBps: 800000,
      gopLength: 10, // keyframes at 0/10/20 → seek tests have targets
      frameRateNumerator: kFps,
      frameRateDenominator: 1,
      backendOptions: {'global_header': '1', 'sw_isolate': '0'},
    ),
  ))!;
  final a = (await backend.createAudioEncoder(
    const AudioEncoderConfig(
      codec: AudioCodec.aac,
      sampleRate: kSampleRate,
      channels: kChannels,
      bitrateBps: 128000,
      backendOptions: {'global_header': '1'},
    ),
  ))!;

  final muxer = FfmpegMuxer.open(
    MuxerConfig(
      container: container,
      output: output,
      fragmentDurationUs: container == Container.fmp4 ? 200000 : 0,
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
      0: v as FfmpegEncoderBridge,
      1: a as FfmpegEncoderBridge,
    },
  );
  await muxer.writeHeader();

  var videoPackets = 0;
  final rgba = Uint8List(kW * kH * 4);
  for (var i = 0; i < kFrames; i++) {
    // Moving diagonal so packets are not degenerate.
    for (var y = 0; y < kH; y++) {
      for (var x = 0; x < kW; x++) {
        final off = (y * kW + x) * 4;
        rgba[off] = (x + i * 4) % 256;
        rgba[off + 1] = (y + i * 2) % 256;
        rgba[off + 2] = 128;
        rgba[off + 3] = 255;
      }
    }
    final p = await v.encode(
      FrameSource.cpu(
        bytes: rgba,
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: kW,
        height: kH,
        timestampUs: (i * 1000000) ~/ kFps,
      ),
    );
    if (p != null) {
      await muxer.writePacket(p.copyWith(trackIndex: 0));
      videoPackets++;
    }
  }
  for (final p in await v.flush()) {
    await muxer.writePacket(p.copyWith(trackIndex: 0));
    videoPackets++;
  }

  final pcm = Float32List(kSampleRate * kChannels);
  for (var i = 0; i < kSampleRate; i++) {
    final s = math.sin(2 * math.pi * 440 * i / kSampleRate) * 0.25;
    pcm[i * kChannels] = s;
    pcm[i * kChannels + 1] = s;
  }
  for (final p in await a.encode(
    pcm: Uint8List.view(pcm.buffer),
    format: MiniAVAudioFormat.f32,
    frameCount: kSampleRate,
    ptsUs: 0,
  )) {
    await muxer.writePacket(p.copyWith(trackIndex: 1));
  }
  for (final p in await a.flush()) {
    await muxer.writePacket(p.copyWith(trackIndex: 1));
  }

  await muxer.finish();
  final bytes = output is BytesMuxerOutput
      ? Uint8List.fromList(muxer.getBytes()!)
      : null;
  await muxer.close();
  await v.close();
  await a.close();
  return (videoPackets, bytes);
}

void _expectTracks(List<TrackInfo> tracks) {
  final video = tracks.whereType<VideoTrackInfo>().toList();
  final audio = tracks.whereType<AudioTrackInfo>().toList();
  expect(video, hasLength(1));
  expect(audio, hasLength(1));
  expect(video.single.codec, VideoCodec.h264);
  expect(video.single.width, kW);
  expect(video.single.height, kH);
  expect(
    video.single.extraData?.bytes,
    isNotNull,
    reason: 'avcC must surface for out-of-band decode',
  );
  expect(audio.single.codec, AudioCodec.aac);
  expect(audio.single.sampleRate, kSampleRate);
  expect(audio.single.channels, kChannels);
  expect(
    audio.single.extraData?.bytes,
    isNotNull,
    reason: 'ASC must surface for out-of-band decode',
  );
}

/// Drain a demuxer; returns (videoPackets, audioPackets, firstVideoKeyframe,
/// videoPtsMonotonic).
Future<(int, int, bool, bool)> _drain(
  PlatformDemuxer dem,
  List<TrackInfo> tracks,
) async {
  final videoTrack = tracks.indexWhere((t) => t is VideoTrackInfo);
  var nv = 0, na = 0;
  var firstVideoKey = false;
  var monotonic = true;
  var lastVideoPts = -1 << 62;
  while (true) {
    final p = await dem.readPacket();
    if (p == null) break;
    if (p.trackIndex == videoTrack) {
      if (nv == 0) firstVideoKey = p.isKeyframe;
      if (p.ptsUs < lastVideoPts) monotonic = false; // pts order (no B-frames)
      lastVideoPts = p.ptsUs;
      nv++;
    } else {
      na++;
    }
  }
  return (nv, na, firstVideoKey, monotonic);
}

void main() {
  final enabled =
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();
  final skip = enabled
      ? null
      : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)';

  setUpAll(() async {
    if (enabled) await ensureFFmpegLoaded();
  });

  test('MP4 bytes → FfmpegDemuxer.openBytes roundtrip', skip: skip, () async {
    final (written, bytes) = await _encodeAv(
      container: Container.mp4,
      output: const BytesMuxerOutput(),
    );
    expect(written, kFrames);
    expect(bytes, isNotNull);

    final dem = FfmpegDemuxer.openBytes(bytes!);
    _expectTracks(dem.tracks);
    expect(
      dem.durationUs,
      allOf(greaterThan(800000), lessThan(1500000)),
      reason: '~1 s container (moov is present even through the pipe)',
    );
    final (nv, na, firstKey, monotonic) = await _drain(dem, dem.tracks);
    expect(nv, kFrames);
    expect(na, greaterThan(20));
    expect(firstKey, isTrue);
    expect(monotonic, isTrue);
    await dem.close();
  });

  test('MP4 file → demux (isolate host), duration + seek', skip: skip,
      () async {
    final tmp = File(
      '${Directory.systemTemp.path}/miniav_demux_roundtrip.mp4',
    );
    if (tmp.existsSync()) tmp.deleteSync();
    final (written, _) = await _encodeAv(
      container: Container.mp4,
      output: FileMuxerOutput(tmp.path),
    );
    expect(written, kFrames);

    final backend = FfmpegBackend();
    final dem = (await backend.createDemuxer(
      DemuxerConfig(input: DemuxerInput.file(tmp.path)),
    ))!;
    _expectTracks(dem.tracks);
    expect(dem.isSeekable, isTrue);
    expect(
      dem.durationUs,
      allOf(greaterThan(800000), lessThan(1500000)),
      reason: '~1 s container',
    );

    final (nv, na, firstKey, monotonic) = await _drain(dem, dem.tracks);
    expect(nv, kFrames);
    expect(na, greaterThan(20));
    expect(firstKey, isTrue);
    expect(monotonic, isTrue);

    // Seek back to ~0.5 s: the next video packet must be the keyframe at or
    // before the target (gop 10 → keyframe pts 333333).
    const target = 500000;
    await dem.seek(target);
    EncodedPacket? p;
    do {
      p = await dem.readPacket();
    } while (p != null && dem.tracks[p.trackIndex] is! VideoTrackInfo);
    expect(p, isNotNull);
    expect(p!.isKeyframe, isTrue);
    expect(p.ptsUs, lessThanOrEqualTo(target));
    expect(p.ptsUs, greaterThanOrEqualTo(0));
    await dem.close();
  });

  test('fMP4 live byte stream → demux while still being fed', skip: skip,
      () async {
    // Mux to chunks first (the "server side").
    final chunks = <Uint8List>[];
    final (written, _) = await _encodeAv(
      container: Container.fmp4,
      output: MuxerOutput.callback((c) => chunks.add(Uint8List.fromList(c))),
    );
    expect(written, kFrames);
    expect(chunks.length, greaterThan(2), reason: 'fragmented output');

    // Progressive feed: one chunk per event-loop turn with small delays.
    final ctrl = StreamController<List<int>>();
    var feedDone = false;
    var firstPacketBeforeFeedDone = false;
    unawaited(() async {
      for (final c in chunks) {
        ctrl.add(c);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      feedDone = true;
      await ctrl.close();
    }());

    final backend = FfmpegBackend();
    final dem = (await backend.createDemuxer(
      DemuxerConfig(input: DemuxerInput.byteStream(ctrl.stream)),
    ))!;
    _expectTracks(dem.tracks);
    expect(dem.isSeekable, isFalse);

    var nv = 0, na = 0;
    final videoTrack = dem.tracks.indexWhere((t) => t is VideoTrackInfo);
    while (true) {
      final p = await dem.readPacket();
      if (p == null) break;
      if (nv + na == 0 && !feedDone) firstPacketBeforeFeedDone = true;
      if (p.trackIndex == videoTrack) {
        nv++;
      } else {
        na++;
      }
    }
    expect(nv, kFrames);
    expect(na, greaterThan(20));
    expect(
      firstPacketBeforeFeedDone,
      isTrue,
      reason: 'packets must flow while the transport is still delivering',
    );
    await dem.close();
  });

  test('closing a starved live demuxer unblocks the worker', skip: skip,
      () async {
    final chunks = <Uint8List>[];
    await _encodeAv(
      container: Container.fmp4,
      output: MuxerOutput.callback((c) => chunks.add(Uint8List.fromList(c))),
    );
    final ctrl = StreamController<List<int>>();
    final backend = FfmpegBackend();
    final open = backend.createDemuxer(
      DemuxerConfig(input: DemuxerInput.byteStream(ctrl.stream)),
    );
    // Feed the WHOLE clip up front but keep the stream OPEN, so probing
    // (avformat_find_stream_info, which reads ahead well past the init
    // segment) completes, then reads starve at the tail. Starving DURING
    // probe would instead hang open() — a distinct concern covered by the
    // 'openStream times out' test.
    for (final c in chunks) {
      ctrl.add(c);
    }
    final dem = (await open)!;

    // Drain what is decodable, then issue one read that will BLOCK the
    // worker inside av_read_frame (stream still open, no more bytes coming).
    Future<EncodedPacket?> pending;
    while (true) {
      pending = dem.readPacket();
      final p = await pending.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () =>
            EncodedPacket(data: kStarvedMarker, ptsUs: -1, dtsUs: -1),
      );
      if (p != null && identical(p.data, kStarvedMarker)) break; // starved
      expect(p, isNotNull, reason: 'EOF must not arrive while feed is open');
    }

    // close() must complete PROMPTLY despite the blocked read: bytepipe
    // close → read cb returns EOF → av_read_frame unblocks → worker exits.
    // (Isolate.kill alone cannot preempt a natively-blocked isolate.)
    await dem.close().timeout(const Duration(seconds: 5));
    final last = await pending.timeout(const Duration(seconds: 5));
    expect(last, isNull, reason: 'starved read resolves as EOF on close');
    await ctrl.close();
  });

  test('opening a live stream that stalls mid-probe times out (not hang)',
      skip: skip, () async {
    // Feed only the init segment then go silent WITHOUT closing: probing
    // blocks waiting for more bytes. open() must surface a bounded error
    // rather than hanging forever (dead-connection robustness).
    final chunks = <Uint8List>[];
    await _encodeAv(
      container: Container.fmp4,
      output: MuxerOutput.callback((c) => chunks.add(Uint8List.fromList(c))),
    );
    final ctrl = StreamController<List<int>>();
    final backend = FfmpegBackend();
    final open = backend.createDemuxer(
      DemuxerConfig(
        input: DemuxerInput.byteStream(ctrl.stream),
        backendOptions: const {'open_timeout_ms': '1500'},
      ),
    );
    // One partial chunk, then stall.
    if (chunks.isNotEmpty) ctrl.add(chunks.first.sublist(0, 8));

    await expectLater(
      open.timeout(const Duration(seconds: 6)),
      throwsA(isA<CodecInitException>()),
      reason: 'a stalled probe must error within the open timeout, not hang',
    );
    await ctrl.close();
  });
}

final Uint8List kStarvedMarker = Uint8List(0);
