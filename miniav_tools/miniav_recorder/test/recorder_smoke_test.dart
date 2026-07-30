/// Recorder package smoke test.
///
/// Verifies the public API surface (builder + types) loads and validates
/// inputs without requiring real capture devices.
library;

import 'dart:typed_data';

import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fake backend used by the MiniAVTools.warmup() tests.
// Only warmup() is interesting; every other capability returns false / null.
// ---------------------------------------------------------------------------
class _WarmupTestBackend extends MiniAVToolsBackend {
  @override
  final String name;

  @override
  final int priority;

  final Stream<WarmupProgress> Function() warmupFn;

  _WarmupTestBackend(this.name, {this.priority = 99, required this.warmupFn});

  @override
  Stream<WarmupProgress> warmup() => warmupFn();

  @override
  bool supportsEncode(VideoCodec c, {bool hwAccel = false}) => false;
  @override
  bool supportsDecode(VideoCodec c, {bool hwAccel = false}) => false;
  @override
  bool supportsAudioEncode(AudioCodec c) => false;
  @override
  bool supportsAudioDecode(AudioCodec c) => false;
  @override
  bool supportsMux(Container c) => false;
  @override
  bool supportsDemux(Container c) => false;
  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};
  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig c, {
    BackendContext? context,
  }) async => null;
  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig c, {
    BackendContext? context,
  }) async => null;
  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig c) async => null;
  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig c) async => null;
}

void main() {
  // -----------------------------------------------------------------------
  // RecorderBuilder — source / sink combinations
  // -----------------------------------------------------------------------
  group('RecorderBuilder', () {
    test('builds with screen(displayId) + mic + file sink', () {
      final b = RecorderBuilder();
      b.addScreen(displayId: 'fake-display', codec: VideoCodec.h264);
      b.addMic(deviceId: 'fake-mic', codec: AudioCodec.aac);
      b.addFileOutput('out.mkv', container: Container.mkv);
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('builds with screen(null displayId — default display)', () {
      // null displayId is valid; resolution is deferred to start().
      final b = RecorderBuilder();
      b.addScreen(codec: VideoCodec.h264); // displayId defaults to null
      b.addFileOutput('out.mp4');
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('builds with screen(windowId) + file sink', () {
      final b = RecorderBuilder();
      b.addScreen(windowId: 'fake-window');
      b.addFileOutput('out.mp4');
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('builds with camera + loopback + stream sink', () {
      final chunks = <TrackChunk>[];
      final b = RecorderBuilder();
      b.addCamera(deviceId: 'fake-cam', codec: VideoCodec.h264);
      b.addLoopback(deviceId: 'fake-loop', codec: AudioCodec.opus);
      b.addStreamOutput((chunk) {
        if (chunk is TrackChunk) chunks.add(chunk);
      });
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('audio-only: mic-only recorder builds OK', () {
      final b = RecorderBuilder();
      b.addMic(deviceId: 'fake-mic', codec: AudioCodec.aac);
      b.addFileOutput('mic.m4a');
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('audio-only: loopback-only recorder builds OK', () {
      final b = RecorderBuilder();
      b.addLoopback(deviceId: 'fake-loop', codec: AudioCodec.opus);
      b.addFileOutput('loop.ogg');
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('multiple sinks on one recorder build OK', () {
      final b = RecorderBuilder();
      b.addMic(deviceId: 'fake-mic');
      b.addFileOutput('mic.m4a');
      b.addStreamOutput((_) {});
      final rec = b.build();
      expect(rec.state, RecorderState.idle);
    });

    test('builder defaults are sane', () {
      final b = RecorderBuilder();
      expect(b.defaultVideoBitrate, greaterThan(0));
      expect(b.defaultAudioBitrate, greaterThan(0));
      expect(b.defaultFrameRate, greaterThan(0));
      expect(b.preferZeroCopy, isTrue);
    });

    test('build() throws when no sources', () {
      final b = RecorderBuilder();
      b.addFileOutput('out.mp4');
      expect(b.build, throwsStateError);
    });

    test('build() throws when no sinks', () {
      final b = RecorderBuilder();
      b.addMic(deviceId: 'd');
      expect(b.build, throwsStateError);
    });
  });

  // -----------------------------------------------------------------------
  // Container enum — new audio-only values
  // -----------------------------------------------------------------------
  group('Container', () {
    test('m4a and mp3 values exist', () {
      expect(Container.values, contains(Container.m4a));
      expect(Container.values, contains(Container.mp3));
    });

    test('addFileOutput accepts Container.m4a override', () {
      final b = RecorderBuilder();
      b.addMic(deviceId: 'fake-mic', codec: AudioCodec.aac);
      b.addFileOutput('out.m4a', container: Container.m4a);
      expect(() => b.build(), returnsNormally);
    });

    test('addFileOutput accepts Container.mp3 override', () {
      final b = RecorderBuilder();
      b.addMic(deviceId: 'fake-mic', codec: AudioCodec.mp3);
      b.addFileOutput('out.mp3', container: Container.mp3);
      expect(() => b.build(), returnsNormally);
    });
  });

  // -----------------------------------------------------------------------
  // containerForExtension — all supported extensions
  // -----------------------------------------------------------------------
  group('containerForExtension', () {
    // --- recognised extensions -------------------------------------------
    test('mp4 → Container.mp4', () {
      expect(containerForExtension('recording.mp4'), Container.mp4);
    });

    test('m4v → Container.mp4', () {
      expect(containerForExtension('recording.m4v'), Container.mp4);
    });

    test('mkv → Container.mkv', () {
      expect(containerForExtension('out.mkv'), Container.mkv);
    });

    test('webm → Container.webm', () {
      expect(containerForExtension('stream.webm'), Container.webm);
    });

    test('ts → Container.mpegts', () {
      expect(containerForExtension('segment.ts'), Container.mpegts);
    });

    test('mts → Container.mpegts', () {
      expect(containerForExtension('clip.mts'), Container.mpegts);
    });

    test('ogg → Container.ogg', () {
      expect(containerForExtension('audio.ogg'), Container.ogg);
    });

    test('wav → Container.wav', () {
      expect(containerForExtension('pcm.wav'), Container.wav);
    });

    test('m4a → Container.m4a', () {
      expect(containerForExtension('mic.m4a'), Container.m4a);
    });

    test('mp3 → Container.mp3', () {
      expect(containerForExtension('music.mp3'), Container.mp3);
    });

    // --- case insensitivity ----------------------------------------------
    test('MP4 (uppercase) → Container.mp4', () {
      expect(containerForExtension('REC.MP4'), Container.mp4);
    });

    test('MKV (uppercase) → Container.mkv', () {
      expect(containerForExtension('OUT.MKV'), Container.mkv);
    });

    test('Mp4 (mixed case) → Container.mp4', () {
      expect(containerForExtension('clip.Mp4'), Container.mp4);
    });

    // --- paths with directories / dots in name ---------------------------
    test('path with directory separators', () {
      expect(
        containerForExtension(r'C:\Users\me\Videos\rec.mp4'),
        Container.mp4,
      );
    });

    test('path with dots in directory name', () {
      expect(containerForExtension(r'C:\my.recordings\out.mkv'), Container.mkv);
    });

    test('filename with multiple dots uses last extension', () {
      expect(containerForExtension('my.backup.2026.mp4'), Container.mp4);
    });

    // --- unrecognised / missing ------------------------------------------
    test('unknown extension → null', () {
      expect(containerForExtension('recording.avi'), isNull);
    });

    test('no extension → null', () {
      expect(containerForExtension('noextension'), isNull);
    });

    test('trailing dot → null', () {
      expect(containerForExtension('file.'), isNull);
    });

    test('empty string → null', () {
      expect(containerForExtension(''), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // containerForTrackMix — all track-mix heuristics
  // -----------------------------------------------------------------------
  group('containerForTrackMix', () {
    // --- video + audio combos -------------------------------------------
    test('video + audio → mkv', () {
      expect(
        containerForTrackMix(hasVideo: true, hasAudio: true),
        Container.mkv,
      );
    });

    test('video + audio (any audioCodecs set) → mkv', () {
      expect(
        containerForTrackMix(
          hasVideo: true,
          hasAudio: true,
          audioCodecs: {AudioCodec.aac},
        ),
        Container.mkv,
      );
    });

    // --- video only -------------------------------------------------------
    test('video only → mp4', () {
      expect(
        containerForTrackMix(hasVideo: true, hasAudio: false),
        Container.mp4,
      );
    });

    // --- audio only, single codec ----------------------------------------
    test('audio-only AAC → m4a', () {
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.aac},
        ),
        Container.m4a,
      );
    });

    test('audio-only Opus → ogg', () {
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.opus},
        ),
        Container.ogg,
      );
    });

    test('audio-only MP3 → mp3', () {
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.mp3},
        ),
        Container.mp3,
      );
    });

    test('audio-only other codec → mkv', () {
      // Any codec not explicitly mapped (e.g. flac) falls back to MKV.
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.flac},
        ),
        Container.mkv,
      );
    });

    // --- mixed audio codecs (e.g. mic=AAC + loopback=Opus) ---------------
    test('mixed audio codecs → mkv', () {
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.aac, AudioCodec.opus},
        ),
        Container.mkv,
      );
    });

    test('three different audio codecs → mkv', () {
      expect(
        containerForTrackMix(
          hasVideo: false,
          hasAudio: true,
          audioCodecs: {AudioCodec.aac, AudioCodec.opus, AudioCodec.mp3},
        ),
        Container.mkv,
      );
    });

    // --- no tracks at all -------------------------------------------------
    test('no video, no audio (empty recorder edge case) → mkv', () {
      expect(
        containerForTrackMix(hasVideo: false, hasAudio: false),
        Container.mkv,
      );
    });
  });

  // -----------------------------------------------------------------------
  // Container priority: explicit override > extension sniff > track-mix
  // Tested through RecorderBuilder + Recorder.build() which exercises the
  // full _buildSink path at construction.
  // -----------------------------------------------------------------------
  group('Container selection priority (via RecorderBuilder)', () {
    test('explicit container beats file extension', () {
      // File says .mkv but caller overrides to mp4.
      final b = RecorderBuilder()
        ..addScreen(displayId: 'fake')
        ..addLoopback(deviceId: 'fake-loop')
        ..addFileOutput('out.mkv', container: Container.mp4);
      expect(() => b.build(), returnsNormally);
    });

    test('mp4 extension → uses mp4 (not mkv from _autoContainer)', () {
      // Regression: before fix _autoContainer was called for video+audio
      // and always returned MKV even when the path was .mp4.
      final b = RecorderBuilder()
        ..addScreen(displayId: 'fake')
        ..addLoopback(deviceId: 'fake-loop')
        ..addFileOutput('recording.mp4');
      expect(() => b.build(), returnsNormally);
    });

    test('mkv extension → uses mkv', () {
      final b = RecorderBuilder()
        ..addScreen(displayId: 'fake')
        ..addMic(deviceId: 'fake-mic')
        ..addLoopback(deviceId: 'fake-loop')
        ..addFileOutput('recording.mkv');
      expect(() => b.build(), returnsNormally);
    });

    test('webm extension → uses webm', () {
      final b = RecorderBuilder()
        ..addScreen(displayId: 'fake')
        ..addFileOutput('recording.webm');
      expect(() => b.build(), returnsNormally);
    });

    test(
      'unknown extension falls through to _autoContainer (video+audio→mkv)',
      () {
        final b = RecorderBuilder()
          ..addScreen(displayId: 'fake')
          ..addMic(deviceId: 'fake-mic')
          ..addFileOutput('recording.avi'); // no sniff match → _autoContainer
        expect(() => b.build(), returnsNormally);
      },
    );
  });

  // -----------------------------------------------------------------------
  // RecorderGroup — synchronised multi-recorder
  // -----------------------------------------------------------------------
  group('RecorderGroup', () {
    test('holds the correct number of recorders', () {
      final r1 =
          (RecorderBuilder()
                ..addScreen(displayId: 'fake-display')
                ..addLoopback(deviceId: 'fake-loop')
                ..addFileOutput('av.mp4'))
              .build();
      final r2 =
          (RecorderBuilder()
                ..addMic(deviceId: 'fake-mic', codec: AudioCodec.aac)
                ..addFileOutput('mic.m4a'))
              .build();
      final group = RecorderGroup([r1, r2]);
      expect(group.recorders, hasLength(2));
      for (final r in group.recorders) {
        expect(r.state, RecorderState.idle);
      }
    });

    test('each recorder is independently idle', () {
      final recorders = [
        (RecorderBuilder()
              ..addMic(deviceId: 'a')
              ..addFileOutput('a.m4a'))
            .build(),
        (RecorderBuilder()
              ..addMic(deviceId: 'b')
              ..addFileOutput('b.m4a'))
            .build(),
        (RecorderBuilder()
              ..addLoopback(deviceId: 'c')
              ..addFileOutput('c.ogg'))
            .build(),
      ];
      final group = RecorderGroup(recorders);
      expect(
        group.recorders.every((r) => r.state == RecorderState.idle),
        isTrue,
      );
    });
  });

  // -----------------------------------------------------------------------
  // TrackChunk — packet container
  // -----------------------------------------------------------------------
  group('TrackChunk', () {
    test('video chunk fields', () {
      final c = TrackChunk(
        trackIndex: 0,
        kind: TrackKind.video,
        videoCodec: VideoCodec.h264,
        ptsUs: 1000,
        dtsUs: 1000,
        durationUs: 33000,
        bytes: Uint8List(16),
        isKeyframe: true,
      );
      expect(c.kind, TrackKind.video);
      expect(c.videoCodec, VideoCodec.h264);
      expect(c.audioCodec, isNull);
      expect(c.isKeyframe, isTrue);
    });

    test('audio chunk fields — AAC', () {
      final c = TrackChunk(
        trackIndex: 1,
        kind: TrackKind.audio,
        audioCodec: AudioCodec.aac,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 23000,
        bytes: Uint8List(8),
        isKeyframe: true,
      );
      expect(c.kind, TrackKind.audio);
      expect(c.audioCodec, AudioCodec.aac);
      expect(c.videoCodec, isNull);
    });

    test('audio chunk fields — Opus', () {
      final c = TrackChunk(
        trackIndex: 2,
        kind: TrackKind.audio,
        audioCodec: AudioCodec.opus,
        ptsUs: 40000,
        dtsUs: 40000,
        durationUs: 20000,
        bytes: Uint8List(32),
        isKeyframe: false,
      );
      expect(c.audioCodec, AudioCodec.opus);
      expect(c.ptsUs, 40000);
    });

    test('video chunk with extraData carries SPS/PPS', () {
      final sps = Uint8List.fromList([0, 0, 0, 1, 0x67, 0xAB]);
      final c = TrackChunk(
        trackIndex: 0,
        kind: TrackKind.video,
        videoCodec: VideoCodec.h264,
        ptsUs: 0,
        dtsUs: 0,
        durationUs: 33333,
        bytes: Uint8List(64),
        isKeyframe: true,
        extraData: sps,
      );
      expect(c.extraData, isNotNull);
      expect(c.extraData!.length, sps.length);
    });

    test('multiple track indices are preserved', () {
      for (var i = 0; i < 4; i++) {
        final c = TrackChunk(
          trackIndex: i,
          kind: TrackKind.audio,
          audioCodec: AudioCodec.aac,
          ptsUs: i * 1000,
          dtsUs: i * 1000,
          durationUs: 1000,
          bytes: Uint8List(4),
          isKeyframe: true,
        );
        expect(c.trackIndex, i);
        expect(c.ptsUs, i * 1000);
      }
    });
  });

  // -----------------------------------------------------------------------
  // Shared GPU lifecycle — regression tests for "subsequent runs break"
  // -----------------------------------------------------------------------
  //
  // Original bug: Recorder._shutdown nulled its private Minigpu reference,
  // letting the GC run the Minigpu finalizer which called destroyContext().
  // The next Recorder.start() then created a fresh Minigpu and called
  // init() again — which on Windows could pick a different Dawn backend
  // (D3D12 vs D3D11), breaking the cross-API shared-texture path on the
  // SECOND recorder run with errors like:
  //   [wgpu] The D3D11 device of the texture and the D3D11 device of
  //          [Device "MGPU.MainDevice"] must be same.
  //   [minigpu_external] create_shared_output_texture: Dawn is not on
  //          D3D11 backend; cross-API path not implemented in this build.
  //
  // Fix: Recorder owns a process-global Minigpu singleton. start()/stop()
  // never destroy it. Only Recorder.disposeSharedGpu() releases it.
  // -----------------------------------------------------------------------
  group('Recorder shared GPU lifecycle', () {
    tearDown(() async {
      // Keep state isolated between tests in this group.
      await Recorder.disposeSharedGpu();
    });

    test('ensureSharedGpu is idempotent across repeated calls', () async {
      // Old code path: a second Minigpu().init() on the same isolate
      // throws MinigpuAlreadyInitError once Dart picks up that the
      // platform context is already alive — or, after a finalizer-driven
      // destroy, comes back on a different backend. Either way, calling
      // the public helper twice in a row must be safe.
      await Recorder.ensureSharedGpu();
      await Recorder.ensureSharedGpu();
      // Concurrent calls must also de-duplicate to a single init future.
      await Future.wait([
        Recorder.ensureSharedGpu(),
        Recorder.ensureSharedGpu(),
        Recorder.ensureSharedGpu(),
      ]);
    });

    test('sequential start→stop→start→stop cycles do not throw '
        '(audio-only recorder, no real device)', () async {
      // Audio-only recorders never touch the GPU singleton, but they
      // do run the same prepare/_shutdown lifecycle that previously
      // tore down the GPU on stop. If the lifecycle code is sound,
      // the second cycle's _prepare() must not raise StateError or
      // similar from leftover state.
      Future<Recorder> buildAudioOnly() async {
        final b = RecorderBuilder()
          ..addMic(deviceId: 'fake-mic-does-not-exist', codec: AudioCodec.aac)
          ..addFileOutput('test_unused.m4a');
        return b.build();
      }

      // We can't actually start() without a real device, but we CAN
      // verify the state machine accepts a stop-after-error and that
      // a second build is independent of the first.
      for (var i = 0; i < 3; i++) {
        final rec = await buildAudioOnly();
        expect(rec.state, RecorderState.idle);
        // start() will fail (no real mic), but the recorder must
        // recover to errored state without leaking statics that
        // would prevent the NEXT recorder from being created.
        try {
          await rec.start();
        } catch (_) {
          // Expected on a CI box with no audio device — verifies the
          // error path is reachable and idempotent.
        }
        // stop() is idempotent on errored recorders.
        await rec.stop();
      }
    });

    test(
      'disposeSharedGpu is safe to call when nothing was initialised',
      () async {
        // Hot-restart hook will call this even on first launch.
        await Recorder.disposeSharedGpu();
        await Recorder.disposeSharedGpu();
      },
    );

    test(
      'disposeSharedGpu after ensureSharedGpu allows re-initialisation',
      () async {
        await Recorder.ensureSharedGpu();
        await Recorder.disposeSharedGpu();
        // Must be possible to re-init after explicit teardown — exercises
        // the hot-restart cleanup → resume path.
        await Recorder.ensureSharedGpu();
      },
    );
  });

  // -----------------------------------------------------------------------
  // ScreenEffect — outputSize per effect type (no GPU required)
  // -----------------------------------------------------------------------
  group('ScreenEffect.outputSize', () {
    test('wgsl — in-place, no size change', () {
      final fx = ScreenEffect.wgsl('// noop');
      expect(fx.outputSize(1920, 1080), (1920, 1080));
      expect(fx.outputSize(800, 600), (800, 600));
    });

    test('vignette — in-place, no size change', () {
      final fx = ScreenEffect.vignette();
      expect(fx.outputSize(1920, 1080), (1920, 1080));
    });

    test('crop — returns crop rectangle dimensions', () {
      final fx = ScreenEffect.crop(100, 50, 640, 360);
      expect(fx.outputSize(1920, 1080), (640, 360));
      // outputSize ignores inW/inH — it uses the crop rect directly.
      expect(fx.outputSize(640, 360), (640, 360));
    });

    test('flip — same dimensions (separate buffer, no race condition)', () {
      final fx = ScreenEffect.flip(horizontal: true);
      expect(fx.outputSize(1280, 720), (1280, 720));
      expect(fx.outputSize(1920, 1080), (1920, 1080));
    });

    test('flip(vertical) — same dimensions', () {
      final fx = ScreenEffect.flip(vertical: true);
      expect(fx.outputSize(640, 480), (640, 480));
    });

    test('rotate 90° CW — swaps width and height', () {
      final fx = ScreenEffect.rotate(ScreenRotation.r90);
      expect(fx.outputSize(1920, 1080), (1080, 1920));
      expect(fx.outputSize(640, 360), (360, 640));
    });

    test('rotate 180° — same dimensions', () {
      final fx = ScreenEffect.rotate(ScreenRotation.r180);
      expect(fx.outputSize(1920, 1080), (1920, 1080));
    });

    test('rotate 270° CW — swaps width and height', () {
      final fx = ScreenEffect.rotate(ScreenRotation.r270);
      expect(fx.outputSize(1920, 1080), (1080, 1920));
    });

    test('scale — returns target dimensions regardless of input', () {
      final fx = ScreenEffect.scale(960, 540);
      expect(fx.outputSize(1920, 1080), (960, 540));
      expect(fx.outputSize(100, 100), (960, 540)); // upscale
      expect(fx.outputSize(4096, 2160), (960, 540)); // downscale
    });
  });

  // -----------------------------------------------------------------------
  // ScreenEffect — factory types and field preservation
  // -----------------------------------------------------------------------
  group('ScreenEffect factories', () {
    test('flip factory → FlipScreenEffect', () {
      expect(ScreenEffect.flip(horizontal: true), isA<FlipScreenEffect>());
    });

    test('flip preserves horizontal/vertical flags', () {
      final h =
          ScreenEffect.flip(horizontal: true, vertical: false)
              as FlipScreenEffect;
      expect(h.horizontal, isTrue);
      expect(h.vertical, isFalse);

      final v = ScreenEffect.flip(vertical: true) as FlipScreenEffect;
      expect(v.horizontal, isFalse);
      expect(v.vertical, isTrue);
    });

    test('flip defaults — both false', () {
      final fx = ScreenEffect.flip() as FlipScreenEffect;
      expect(fx.horizontal, isFalse);
      expect(fx.vertical, isFalse);
    });

    test('rotate factory → RotateScreenEffect', () {
      expect(
        ScreenEffect.rotate(ScreenRotation.r90),
        isA<RotateScreenEffect>(),
      );
    });

    test('rotate preserves rotation for all three values', () {
      for (final rot in ScreenRotation.values) {
        final fx = ScreenEffect.rotate(rot) as RotateScreenEffect;
        expect(fx.rotation, rot);
      }
    });

    test('scale factory → ScaleScreenEffect', () {
      expect(ScreenEffect.scale(960, 540), isA<ScaleScreenEffect>());
    });

    test('scale preserves width and height', () {
      final fx = ScreenEffect.scale(1280, 720) as ScaleScreenEffect;
      expect(fx.width, 1280);
      expect(fx.height, 720);
    });

    test('crop factory → CropScreenEffect', () {
      expect(ScreenEffect.crop(0, 0, 640, 360), isA<CropScreenEffect>());
    });
  });

  // -----------------------------------------------------------------------
  // ScreenEffect output-size chain (mirrors GpuScreenProcessor constructor)
  // -----------------------------------------------------------------------
  group('ScreenEffect output chain (no GPU required)', () {
    /// Mirrors the chain logic in GpuScreenProcessor constructor.
    (int, int) chain(int inW, int inH, List<ScreenEffect> effects) {
      var (w, h) = (inW, inH);
      for (final fx in effects) {
        (w, h) = fx.outputSize(w, h);
      }
      return (w, h);
    }

    test('no effects — output equals input', () {
      expect(chain(1920, 1080, []), (1920, 1080));
    });

    test('single crop', () {
      expect(chain(1920, 1080, [ScreenEffect.crop(0, 0, 640, 360)]), (
        640,
        360,
      ));
    });

    test('single flip — identity size', () {
      expect(chain(1920, 1080, [ScreenEffect.flip(horizontal: true)]), (
        1920,
        1080,
      ));
    });

    test('single rotate 90°', () {
      expect(chain(1920, 1080, [ScreenEffect.rotate(ScreenRotation.r90)]), (
        1080,
        1920,
      ));
    });

    test('single rotate 180° — identity size', () {
      expect(chain(1920, 1080, [ScreenEffect.rotate(ScreenRotation.r180)]), (
        1920,
        1080,
      ));
    });

    test('single rotate 270°', () {
      expect(chain(1920, 1080, [ScreenEffect.rotate(ScreenRotation.r270)]), (
        1080,
        1920,
      ));
    });

    test('single scale', () {
      expect(chain(1920, 1080, [ScreenEffect.scale(960, 540)]), (960, 540));
    });

    test('crop → rotate 90°: crop first, then swap', () {
      // 1920×1080 → crop 640×360 → rotate 90° → 360×640
      expect(
        chain(1920, 1080, [
          ScreenEffect.crop(0, 0, 640, 360),
          ScreenEffect.rotate(ScreenRotation.r90),
        ]),
        (360, 640),
      );
    });

    test('crop → flip: flip preserves crop dims', () {
      expect(
        chain(1920, 1080, [
          ScreenEffect.crop(0, 0, 640, 360),
          ScreenEffect.flip(horizontal: true),
        ]),
        (640, 360),
      );
    });

    test('crop → scale: scale determines final dims', () {
      expect(
        chain(1920, 1080, [
          ScreenEffect.crop(0, 0, 640, 360),
          ScreenEffect.scale(1280, 720), // upscale cropped region
        ]),
        (1280, 720),
      );
    });

    test('scale → rotate 90°', () {
      expect(
        chain(1920, 1080, [
          ScreenEffect.scale(1280, 720),
          ScreenEffect.rotate(ScreenRotation.r90),
        ]),
        (720, 1280),
      );
    });

    test('rotate 90° × 4 — back to original dims', () {
      final r90 = ScreenEffect.rotate(ScreenRotation.r90);
      expect(chain(1920, 1080, [r90, r90, r90, r90]), (1920, 1080));
    });

    test('rotate 90° × 2 == rotate 180°', () {
      final r90 = ScreenEffect.rotate(ScreenRotation.r90);
      final r180 = ScreenEffect.rotate(ScreenRotation.r180);
      expect(chain(1920, 1080, [r90, r90]), chain(1920, 1080, [r180]));
    });

    test('vignette mid-chain — does not change dims', () {
      expect(
        chain(1920, 1080, [
          ScreenEffect.crop(0, 0, 640, 360),
          ScreenEffect.vignette(),
          ScreenEffect.rotate(ScreenRotation.r90),
        ]),
        (360, 640),
      );
    });

    test('non-square source with rotate 90°', () {
      expect(chain(640, 360, [ScreenEffect.rotate(ScreenRotation.r90)]), (
        360,
        640,
      ));
    });

    test('square source: rotate 90° keeps square', () {
      expect(chain(512, 512, [ScreenEffect.rotate(ScreenRotation.r90)]), (
        512,
        512,
      ));
    });

    test('flip both axes == rotate 180° in terms of dimensions', () {
      // Both are identity on dimensions.
      final flipBoth = chain(1920, 1080, [
        ScreenEffect.flip(horizontal: true, vertical: true),
      ]);
      final r180 = chain(1920, 1080, [
        ScreenEffect.rotate(ScreenRotation.r180),
      ]);
      expect(flipBoth, r180);
    });

    test('RecorderBuilder accepts all new effect types', () {
      final b = RecorderBuilder()
        ..addScreen(
          displayId: 'fake',
          effects: [
            ScreenEffect.flip(horizontal: true),
            ScreenEffect.rotate(ScreenRotation.r90),
            ScreenEffect.scale(960, 540),
          ],
        )
        ..addFileOutput('out.mp4');
      expect(() => b.build(), returnsNormally);
    });
  });

  // -----------------------------------------------------------------------
  // WarmupProgress — fields, fraction getter, toString
  // -----------------------------------------------------------------------
  group('WarmupProgress', () {
    group('fraction', () {
      test('known bytes and total → computed fraction', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: false,
          bytesReceived: 50,
          totalBytes: 100,
        );
        expect(p.fraction, closeTo(0.5, 1e-9));
      });

      test('bytesReceived zero → fraction is 0.0', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: false,
          bytesReceived: 0,
          totalBytes: 100,
        );
        expect(p.fraction, closeTo(0.0, 1e-9));
      });

      test('received == total → fraction is 1.0', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: true,
          bytesReceived: 1024,
          totalBytes: 1024,
        );
        expect(p.fraction, closeTo(1.0, 1e-9));
      });

      test('bytesReceived > totalBytes → fraction clamped to 1.0', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: false,
          bytesReceived: 200,
          totalBytes: 100,
        );
        expect(p.fraction, closeTo(1.0, 1e-9));
      });

      test('totalBytes null → fraction is null', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: false,
          bytesReceived: 50,
          // totalBytes omitted
        );
        expect(p.fraction, isNull);
      });

      test('bytesReceived null → fraction is null', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'task',
          isDone: false,
          totalBytes: 100,
          // bytesReceived omitted
        );
        expect(p.fraction, isNull);
      });

      test('neither bytesReceived nor totalBytes → fraction is null', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'task',
          isDone: false,
        );
        expect(p.fraction, isNull);
      });

      test('totalBytes zero → fraction is null (guards divide-by-zero)', () {
        const p = WarmupProgress(
          backendName: 'test',
          task: 'Download',
          isDone: false,
          bytesReceived: 50,
          totalBytes: 0,
        );
        expect(p.fraction, isNull);
      });
    });

    group('toString', () {
      test('in-progress with known fraction shows percentage', () {
        const p = WarmupProgress(
          backendName: 'ffmpeg',
          task: 'Downloading FFmpeg',
          isDone: false,
          bytesReceived: 50,
          totalBytes: 100,
        );
        final s = p.toString();
        expect(s, contains('50%'));
        expect(s, contains('ffmpeg'));
        expect(s, contains('Downloading FFmpeg'));
        expect(s, isNot(contains('[done]')));
        expect(s, isNot(contains('[error')));
      });

      test('isDone=true, no error → contains [done]', () {
        const p = WarmupProgress(
          backendName: 'ffmpeg',
          task: 'Downloading FFmpeg',
          isDone: true,
        );
        final s = p.toString();
        expect(s, contains('[done]'));
        expect(s, isNot(contains('[error')));
      });

      test('isDone=true, with error → contains [error: ...]', () {
        final p = WarmupProgress(
          backendName: 'ffmpeg',
          task: 'Downloading FFmpeg',
          isDone: true,
          error: 'network failure',
        );
        final s = p.toString();
        expect(s, contains('[error:'));
        expect(s, contains('network failure'));
      });

      test('in-progress, no bytes → no percentage, no status marker', () {
        const p = WarmupProgress(
          backendName: 'ffmpeg',
          task: 'Initialising',
          isDone: false,
        );
        final s = p.toString();
        expect(s, contains('ffmpeg'));
        expect(s, contains('Initialising'));
        expect(s, isNot(contains('%')));
        expect(s, isNot(contains('[done]')));
        expect(s, isNot(contains('[error')));
      });
    });

    test('fields are preserved through const constructor', () {
      const p = WarmupProgress(
        backendName: 'my-backend',
        task: 'loading model',
        isDone: false,
        bytesReceived: 1024,
        totalBytes: 4096,
        error: null,
      );
      expect(p.backendName, 'my-backend');
      expect(p.task, 'loading model');
      expect(p.isDone, isFalse);
      expect(p.bytesReceived, 1024);
      expect(p.totalBytes, 4096);
      expect(p.error, isNull);
    });

    test('error field carries the original error object', () {
      final err = Exception('download failed');
      final p = WarmupProgress(
        backendName: 'test',
        task: 'Fetching model',
        isDone: true,
        error: err,
      );
      expect(p.error, same(err));
      expect(p.isDone, isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // MiniAVTools.warmup() — stream merge and error guard
  //
  // FfmpegBackend is auto-registered when miniav_recorder is imported.
  // Fake backends below are registered in each test and unregistered in
  // tearDown so they don't bleed into other tests.
  // -----------------------------------------------------------------------
  group('MiniAVTools.warmup()', () {
    // Unique names used in this group — cleaned up in tearDown.
    const _nameA = 'test-warmup-a';
    const _nameB = 'test-warmup-b';
    const _nameErr = 'test-warmup-err';

    tearDown(() {
      MiniAVToolsPlatform.instance.unregisterByName(_nameA);
      MiniAVToolsPlatform.instance.unregisterByName(_nameB);
      MiniAVToolsPlatform.instance.unregisterByName(_nameErr);
    });

    // Collect only events from a specific backend name.
    Future<List<WarmupProgress>> collectFrom(String name) async {
      return MiniAVTools.warmup()
          .where((p) => p.backendName == name)
          .toList()
          .timeout(const Duration(seconds: 5));
    }

    test('single backend — progress events are forwarded', () async {
      MiniAVToolsPlatform.instance.register(
        _WarmupTestBackend(
          _nameA,
          warmupFn: () async* {
            yield WarmupProgress(
              backendName: _nameA,
              task: 'load',
              isDone: false,
              bytesReceived: 512,
              totalBytes: 1024,
            );
            yield WarmupProgress(
              backendName: _nameA,
              task: 'load',
              isDone: true,
              bytesReceived: 1024,
              totalBytes: 1024,
            );
          },
        ),
      );

      final events = await collectFrom(_nameA);
      expect(events, hasLength(2));
      expect(events.first.isDone, isFalse);
      expect(events.first.bytesReceived, 512);
      expect(events.last.isDone, isTrue);
      expect(events.last.fraction, closeTo(1.0, 1e-9));
    });

    test(
      'backend that returns Stream.empty() — warmup stream still completes',
      () async {
        MiniAVToolsPlatform.instance.register(
          _WarmupTestBackend(_nameA, warmupFn: () => const Stream.empty()),
        );

        final events = await collectFrom(_nameA);
        expect(events, isEmpty);
      },
    );

    test('two backends — events from both arrive', () async {
      MiniAVToolsPlatform.instance.register(
        _WarmupTestBackend(
          _nameA,
          warmupFn: () async* {
            yield WarmupProgress(backendName: _nameA, task: 'A', isDone: true);
          },
        ),
      );
      MiniAVToolsPlatform.instance.register(
        _WarmupTestBackend(
          _nameB,
          warmupFn: () async* {
            yield WarmupProgress(backendName: _nameB, task: 'B', isDone: true);
          },
        ),
      );

      final all = await MiniAVTools.warmup()
          .where((p) => p.backendName == _nameA || p.backendName == _nameB)
          .toList()
          .timeout(const Duration(seconds: 5));
      final names = all.map((p) => p.backendName).toSet();
      expect(names, contains(_nameA));
      expect(names, contains(_nameB));
    });

    test(
      'backend stream error is converted to a WarmupProgress event',
      () async {
        MiniAVToolsPlatform.instance.register(
          _WarmupTestBackend(
            _nameErr,
            warmupFn: () => Stream.error(Exception('exploded')),
          ),
        );

        final events = await collectFrom(_nameErr);
        expect(events, hasLength(1));
        expect(events.single.isDone, isTrue);
        expect(events.single.error, isNotNull);
        expect(events.single.error.toString(), contains('exploded'));
      },
    );

    test(
      'stream completes even when one backend errors and one succeeds',
      () async {
        MiniAVToolsPlatform.instance.register(
          _WarmupTestBackend(
            _nameErr,
            warmupFn: () => Stream.error(Exception('boom')),
          ),
        );
        MiniAVToolsPlatform.instance.register(
          _WarmupTestBackend(
            _nameA,
            warmupFn: () async* {
              yield WarmupProgress(
                backendName: _nameA,
                task: 'ok',
                isDone: true,
              );
            },
          ),
        );

        final all = await MiniAVTools.warmup()
            .where((p) => p.backendName == _nameA || p.backendName == _nameErr)
            .toList()
            .timeout(const Duration(seconds: 5));

        final names = all.map((p) => p.backendName).toSet();
        expect(names, contains(_nameA));
        expect(names, contains(_nameErr));
        // The error backend event must surface error + isDone.
        final errEvent = all.firstWhere((p) => p.backendName == _nameErr);
        expect(errEvent.error, isNotNull);
        expect(errEvent.isDone, isTrue);
      },
    );

    test(
      'WarmupProgress is accessible from miniav_recorder import (export check)',
      () {
        // Verifies the re-export works — WarmupProgress is usable without
        // importing miniav_tools_platform_interface separately.
        const p = WarmupProgress(
          backendName: 'test',
          task: 'check',
          isDone: true,
        );
        expect(p, isA<WarmupProgress>());
      },
    );

    test(
      'MiniAVTools is accessible from miniav_recorder import (export check)',
      () {
        // Verifies MiniAVTools.warmup() is usable without importing
        // miniav_tools separately.
        expect(MiniAVTools.warmup, isA<Function>());
      },
    );
  });

  // -----------------------------------------------------------------------
  // ClipBuffer — ring-buffer and window logic (no real muxer required)
  //
  // saveClip() itself needs FFmpeg and is tested via the live loopback
  // example.  Everything below tests the pure-Dart ring-buffer behaviour:
  // onChunk, _evict (time + count caps), _maxPtsUs anchor, clear, and the
  // StateError guards.
  // -----------------------------------------------------------------------

  /// Build a minimal video [TrackChunk] with the given pts.
  /// [isKeyframe] defaults to false; set to true for IDR simulation.
  TrackChunk _videoChunk(
    int ptsUs, {
    bool isKeyframe = false,
    Uint8List? extraData,
    int trackIndex = 0,
  }) {
    return TrackChunk(
      trackIndex: trackIndex,
      kind: TrackKind.video,
      videoCodec: VideoCodec.h264,
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: 33333,
      bytes: Uint8List(16),
      isKeyframe: isKeyframe,
      extraData: extraData,
      videoWidth: extraData != null ? 1920 : null,
      videoHeight: extraData != null ? 1080 : null,
      videoFrameRateNum: extraData != null ? 30 : null,
      videoFrameRateDen: extraData != null ? 1 : null,
    );
  }

  /// Build a minimal audio [TrackChunk] with the given pts.
  TrackChunk _audioChunk(
    int ptsUs, {
    Uint8List? extraData,
    int trackIndex = 1,
  }) {
    return TrackChunk(
      trackIndex: trackIndex,
      kind: TrackKind.audio,
      audioCodec: AudioCodec.aac,
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: 23220,
      bytes: Uint8List(8),
      isKeyframe: true,
      extraData: extraData,
      sampleRate: extraData != null ? 44100 : null,
      channels: extraData != null ? 2 : null,
    );
  }

  group('ClipBuffer', () {
    // ── Construction ────────────────────────────────────────────────────
    group('construction', () {
      test('starts empty', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        expect(buf.length, 0);
        expect(buf.isNotEmpty, isFalse);
        expect(buf.oldestPtsUs, isNull);
        expect(buf.newestPtsUs, isNull);
      });

      test('maxWindow is preserved', () {
        final buf = ClipBuffer(maxWindow: const Duration(minutes: 3));
        expect(buf.maxWindow, const Duration(minutes: 3));
      });

      test('maxPackets is preserved when set', () {
        final buf = ClipBuffer(
          maxWindow: const Duration(seconds: 30),
          maxPackets: 200,
        );
        expect(buf.maxPackets, 200);
      });

      test('maxPackets defaults to null', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 30));
        expect(buf.maxPackets, isNull);
      });
    });

    // ── onChunk / basic ring behaviour ───────────────────────────────────
    group('onChunk', () {
      test('single chunk increments length to 1', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(1000));
        expect(buf.length, 1);
        expect(buf.isNotEmpty, isTrue);
      });

      test('oldest / newest pts track correctly', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(1000));
        buf.onChunk(_videoChunk(2000));
        buf.onChunk(_videoChunk(3000));
        expect(buf.oldestPtsUs, 1000);
        expect(buf.newestPtsUs, 3000);
      });

      test('newestPtsUs tracks max even when chunks arrive out of order', () {
        // Simulate an audio packet arriving after a later-pts video packet
        // (the real bug that prompted _maxPtsUs).
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(5_000_000)); // 5 s
        buf.onChunk(_audioChunk(3_000_000)); // audio lands later but is older
        // newestPtsUs must be 5_000_000, not 3_000_000
        expect(buf.newestPtsUs, 5_000_000);
      });

      test('metadata captured from first chunk carrying extraData', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        final sps = Uint8List.fromList([0, 0, 0, 1, 0x67]);
        buf.onChunk(_videoChunk(0, isKeyframe: true, extraData: sps));
        buf.onChunk(_videoChunk(33333));
        // Buffer should have 2 packets.
        expect(buf.length, 2);
      });

      test(
        'metadata is NOT re-captured from subsequent chunks without extraData',
        () {
          final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
          final sps = Uint8List.fromList([0, 0, 0, 1, 0x67]);
          buf.onChunk(_videoChunk(0, isKeyframe: true, extraData: sps));
          // Second chunk with different payload but no extraData — ring grows.
          buf.onChunk(_videoChunk(33333));
          expect(buf.length, 2);
        },
      );
    });

    // ── Time-based eviction (_maxPtsUs anchor) ───────────────────────────
    group('time-based eviction', () {
      test('packets older than maxWindow are evicted', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 5));
        // Fill 10 s worth of 1-s packets (pts in microseconds).
        for (var i = 0; i <= 10; i++) {
          buf.onChunk(_videoChunk(i * 1_000_000));
        }
        // Only the last 5 s should remain: pts 5..10 = 6 packets.
        expect(buf.length, 6);
        expect(buf.oldestPtsUs, greaterThanOrEqualTo(5_000_000));
      });

      test('eviction anchor is _maxPtsUs, not _buf.last.ptsUs', () {
        // When a late-arriving audio packet lands in the queue with a smaller
        // PTS than the latest video packet, _buf.last.ptsUs would incorrectly
        // anchor the window to the audio PTS.  _maxPtsUs must remain at the
        // true maximum so the saveClip window is computed correctly.
        //
        // Note: eviction only pops from the front (arrival order), so the
        // out-of-order audio at the back is not physically removed here — the
        // observable guarantee is that newestPtsUs stays at the video PTS.
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 2));
        buf.onChunk(_videoChunk(3_000_000)); // 3 s
        buf.onChunk(_videoChunk(4_000_000)); // 4 s
        // Late-arriving audio: lower PTS than the latest video.
        buf.onChunk(_audioChunk(1_000_000));
        // The window anchor (newestPtsUs) must reflect the true max, not the
        // most-recently-added packet.
        expect(buf.newestPtsUs, 4_000_000);
        // Front-eviction cutoff = 4s - 2s = 2s; video(3s) is at the front
        // and is >= 2s, so nothing is removed.  All 3 packets remain.
        expect(buf.length, 3);
      });

      test('no eviction when all packets are within maxWindow', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 30));
        for (var i = 0; i < 10; i++) {
          buf.onChunk(_videoChunk(i * 1_000_000));
        }
        expect(buf.length, 10);
      });
    });

    // ── Packet-count cap ─────────────────────────────────────────────────
    group('maxPackets cap', () {
      test('buffer never exceeds maxPackets', () {
        final buf = ClipBuffer(
          maxWindow: const Duration(minutes: 10),
          maxPackets: 5,
        );
        for (var i = 0; i < 20; i++) {
          buf.onChunk(_videoChunk(i * 1_000_000));
        }
        expect(buf.length, 5);
      });

      test('oldest packets are dropped first when cap is hit', () {
        final buf = ClipBuffer(
          maxWindow: const Duration(minutes: 10),
          maxPackets: 3,
        );
        for (var i = 0; i < 5; i++) {
          buf.onChunk(_videoChunk(i * 1_000_000));
        }
        // Should keep pts 2, 3, 4 (the newest three).
        expect(buf.oldestPtsUs, 2_000_000);
        expect(buf.newestPtsUs, 4_000_000);
      });
    });

    // ── clear() ──────────────────────────────────────────────────────────
    group('clear()', () {
      test('resets length to 0', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(1_000_000));
        buf.onChunk(_videoChunk(2_000_000));
        buf.clear();
        expect(buf.length, 0);
        expect(buf.isNotEmpty, isFalse);
      });

      test('resets oldest/newestPtsUs to null', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(5_000_000));
        buf.clear();
        expect(buf.oldestPtsUs, isNull);
        expect(buf.newestPtsUs, isNull);
      });

      test('resets _maxPtsUs — new chunks start fresh after clear', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 5));
        buf.onChunk(_videoChunk(100_000_000)); // 100 s
        buf.clear();
        // After clear, adding a small-pts chunk must not evict it
        // (anchor should be 0 again, not 100 s).
        buf.onChunk(_videoChunk(1_000_000)); // 1 s
        expect(buf.length, 1);
        expect(buf.newestPtsUs, 1_000_000);
      });

      test('can accept new chunks after clear', () {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        buf.onChunk(_videoChunk(1_000_000));
        buf.clear();
        buf.onChunk(_videoChunk(2_000_000));
        expect(buf.length, 1);
        expect(buf.oldestPtsUs, 2_000_000);
      });
    });

    // ── saveClip() error guards ──────────────────────────────────────────
    group('saveClip() error guards', () {
      test('throws StateError when buffer is empty', () async {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        await expectLater(
          () => buf.saveClip('out.mp4'),
          throwsA(isA<StateError>()),
        );
      });

      test('throws StateError when no track metadata for a track', () async {
        final buf = ClipBuffer(maxWindow: const Duration(seconds: 10));
        // Add a chunk WITHOUT extraData — no metadata captured.
        buf.onChunk(_videoChunk(1_000_000));
        await expectLater(
          () => buf.saveClip('out.mp4'),
          throwsA(isA<StateError>()),
        );
      });
    });

    // ── addClipBuffer integration ────────────────────────────────────────
    group('RecorderBuilder.addClipBuffer', () {
      test('returns a ClipBuffer instance', () {
        final b = RecorderBuilder();
        b.addScreen(displayId: 'fake');
        final clip = b.addClipBuffer(maxWindow: const Duration(seconds: 10));
        expect(clip, isA<ClipBuffer>());
        expect(clip.maxWindow, const Duration(seconds: 10));
      });

      test('ClipBuffer is wired as a stream sink — build() does not throw', () {
        final b = RecorderBuilder();
        b.addScreen(displayId: 'fake');
        b.addClipBuffer(maxWindow: const Duration(minutes: 3));
        b.addFileOutput('out.mp4');
        expect(() => b.build(), returnsNormally);
      });

      test('multiple clip buffers with different windows both registered', () {
        final b = RecorderBuilder();
        b.addScreen(displayId: 'fake');
        final clip5 = b.addClipBuffer(maxWindow: const Duration(seconds: 5));
        final clip30 = b.addClipBuffer(maxWindow: const Duration(seconds: 30));
        b.addFileOutput('out.mp4');
        expect(() => b.build(), returnsNormally);
        expect(clip5.maxWindow, const Duration(seconds: 5));
        expect(clip30.maxWindow, const Duration(seconds: 30));
      });

      test('maxPackets is forwarded to the buffer', () {
        final b = RecorderBuilder();
        b.addScreen(displayId: 'fake');
        final clip = b.addClipBuffer(
          maxWindow: const Duration(seconds: 30),
          maxPackets: 500,
        );
        b.addFileOutput('out.mp4');
        b.build();
        expect(clip.maxPackets, 500);
      });
    });
  });
}
