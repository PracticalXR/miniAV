/// End-to-end frame-data test: verifies that MP4 files produced by all
/// recorder encoder code paths actually contain video frames.
///
/// All paths use FfmpegMuxer (same as the recorder's internal ClipBuffer /
/// FileRecorderSink). The four paths map directly to the code paths in
/// recorder.dart `_encodeOne()`:
///
///  PATH B — MiniAVBufferSource (CPU): recorder normal/fallback path
///    FrameSource.miniavBuffer(MiniAVBuffer{cpu}) ─► SW encoder ─► FfmpegMuxer ─► MP4
///    The real device path: miniav delivers MiniAVBuffer with
///    outputPreference=cpu, the recorder wraps it in FrameSource.miniavBuffer.
///    Regression: planes[0] being silently ignored produces black frames.
///
///  PATH B-HW — same CPU buffer → HW encoder (NVENC / AMF / QSV / MF)
///
///  PATH C — D3D11TextureFrameSource: recorder GPU-processor output path
///    D3D11TextureFrameSource(texturePtr:...) ─► FfmpegD3d11HwEncoder ─► MP4
///    Corresponds to recorder.dart `_encodeOne()` GPU branch: GPU processor
///    output is a SharedOutputTexture whose d3d11TexturePtr is passed directly.
///    Skipped when no D3D11 vendor is available (non-Windows or no GPU).
///
///  PATH D — MiniAVBufferSource (gpuD3D11Handle): recorder D3D11 fallback path
///    FrameSource.miniavBuffer(MiniAVBuffer{gpuD3D11Handle}) ─► FfmpegD3d11HwEncoder ─► MP4
///    Corresponds to recorder.dart `_encodeOne()` normal path when
///    contentType=gpuD3D11Handle (OpenSharedResource1 path in the encoder).
///    Skipped when no D3D11 vendor is available.
///
/// Validation uses ffprobe (bundled in the same bin/ dir as the FFmpeg DLLs)
/// to count the decoded video frames in each output file.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

// Width / height must be even for YUV420.
const _w = 320;
const _h = 240;
const _fps = 30;
const _frames = 30; // 1 second

void main() {
  bool enabled() =>
      Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1' ||
      tryLoadFFmpeg();

  group('Recorder MP4 frame data', () {
    setUpAll(() async {
      if (enabled()) await ensureFFmpegLoaded();
    });

    // -----------------------------------------------------------------------
    // PATH C: D3D11TextureFrameSource (recorder GPU-processor output path)
    // -----------------------------------------------------------------------
    test(
      'Path C (D3D11TextureFrameSource → FfmpegD3d11HwEncoder): MP4 has $_frames frames',
      skip: enabled()
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        if (!Platform.isWindows) {
          markTestSkipped('D3D11 path is Windows-only');
          return;
        }
        final shim = FfmpegShim.tryLoad();
        if (shim == null) {
          markTestSkipped('shim asset not available');
          return;
        }
        if (ffmpegD3d11VendorsAvailable().isEmpty) {
          markTestSkipped('no D3D11 encoder vendor on this system');
          return;
        }

        FfmpegD3d11HwEncoder enc;
        try {
          enc = FfmpegD3d11HwEncoder.open(
            const EncoderConfig(
              codec: VideoCodec.h264,
              width: _w,
              height: _h,
              bitrateBps: 2_000_000,
              gopLength: _fps,
              frameRateNumerator: _fps,
              frameRateDenominator: 1,
              bFrameCount: 0,
              hwAccel: HwAccelPreference.required,
              rateControl: RateControl.vbr,
              backendOptions: {'global_header': '1'},
            ),
            sourceTextureFormat: D3d11HwSourceFormat.bgra,
          );
        } on CodecInitException catch (e) {
          markTestSkipped('D3D11 encoder open failed: ${e.message}');
          return;
        }

        final tex = shim.testCreateSharedBgra(_w, _h);
        if (tex == nullptr) {
          await enc.close();
          markTestSkipped('Could not create D3D11 test texture');
          return;
        }

        // D3D11TextureFrameSource requires a texture on the encoder's own
        // device. We open each NT-shared handle on that device so the
        // CopySubresourceRegion stays intra-device (same as the recorder,
        // which gets a same-device texture from GpuScreenProcessor).
        final devicePtr = Pointer<Void>.fromAddress(enc.d3dDeviceAddress);

        final outFile = File(
          '${Directory.systemTemp.path}'
          '/miniav_recorder_mp4_frame_test_d3d11_texture.mp4',
        );
        if (outFile.existsSync()) outFile.deleteSync();

        final muxer = FfmpegMuxer.open(
          MuxerConfig(
            container: Container.mp4,
            output: FileMuxerOutput(outFile.path),
            tracks: [
              VideoTrackInfo(
                codec: VideoCodec.h264,
                width: _w,
                height: _h,
                frameRateNumerator: _fps,
                frameRateDenominator: 1,
              ),
            ],
          ),
          encoderForTrack: {0: enc as FfmpegEncoderBridge},
        );
        await muxer.writeHeader();

        try {
          for (var i = 0; i < _frames; i++) {
            shim.testFillBgra(tex, i);
            final ntHandle = shim.testTextureHandle(tex);
            // Open the NT handle on the encoder's device → valid
            // ID3D11Texture2D* on the same device for D3D11TextureFrameSource.
            final openedTex = shim.d3d11OpenSharedHandle(devicePtr, ntHandle);
            if (openedTex == nullptr) continue;
            final src = FrameSource.d3d11Texture(
              texturePtr: openedTex.address,
              width: _w,
              height: _h,
              pixelFormat: MiniAVPixelFormat.bgra32,
              timestampUs: i * (1000000 ~/ _fps),
            );
            final pkt = await enc.encode(src);
            // Release after encode — CopySubresourceRegion has been queued.
            shim.d3d11Release(openedTex);
            if (pkt != null)
              await muxer.writePacket(pkt.copyWith(trackIndex: 0));
          }
          for (final pkt in await enc.flush()) {
            await muxer.writePacket(pkt.copyWith(trackIndex: 0));
          }
        } finally {
          shim.testDestroyTexture(tex);
        }

        await muxer.finish();
        await muxer.close();
        await enc.close();

        expect(outFile.existsSync(), isTrue, reason: 'MP4 not created');
        print(
          '[d3d11_texture] MP4: ${outFile.path} (${outFile.lengthSync()} bytes)',
        );
        expect(
          outFile.lengthSync(),
          greaterThan(4096),
          reason: 'MP4 too small',
        );
        await _assertMp4HasFrames(outFile, expectedFrames: _frames);
      },
    );

    // -----------------------------------------------------------------------
    // PATH B: MiniAVBufferSource (CPU content type)
    // -----------------------------------------------------------------------
    test(
      'Path B (MiniAVBufferSource CPU): MP4 has $_frames video frames with non-black luma',
      skip: enabled()
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        final frames = List.generate(_frames, (i) {
          final rgba = _gradientRgba(_w, _h, i);
          return FrameSource.miniavBuffer(
            MiniAVBuffer(
              type: MiniAVBufferType.video,
              contentType: MiniAVBufferContentType.cpu,
              timestampUs: i * (1000000 ~/ _fps),
              dataSizeBytes: rgba.length,
              data: MiniAVVideoBuffer(
                width: _w,
                height: _h,
                pixelFormat: MiniAVPixelFormat.rgba32,
                strideBytes: [_w * 4],
                planes: [rgba],
              ),
            ),
          );
        });
        final file = await _encodeToMp4(frames, 'miniav_buffer_cpu_path');
        await _assertMp4HasFrames(file, expectedFrames: _frames);
      },
    );

    // -----------------------------------------------------------------------
    // HW encoder paths (skipped when no HW encoder present)
    // -----------------------------------------------------------------------
    // -----------------------------------------------------------------------
    // PATH D: MiniAVBufferSource/gpuD3D11Handle (recorder D3D11 fallback path)
    // -----------------------------------------------------------------------
    test(
      'Path D (MiniAVBufferSource gpuD3D11Handle → FfmpegD3d11HwEncoder): MP4 has $_frames frames',
      skip: enabled()
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        if (!Platform.isWindows) {
          markTestSkipped('D3D11 path is Windows-only');
          return;
        }
        if (FfmpegShim.tryLoad() == null) {
          markTestSkipped('shim asset not available');
          return;
        }
        if (ffmpegD3d11VendorsAvailable().isEmpty) {
          markTestSkipped('no D3D11 encoder vendor on this system');
          return;
        }
        final file = await _encodeD3d11ToMp4(
          'd3d11_buffer',
          (ts, ntHandle) => FrameSource.miniavBuffer(
            MiniAVBuffer(
              type: MiniAVBufferType.video,
              contentType: MiniAVBufferContentType.gpuD3D11Handle,
              timestampUs: ts,
              dataSizeBytes: 0,
              data: MiniAVVideoBuffer(
                width: _w,
                height: _h,
                pixelFormat: MiniAVPixelFormat.bgra32,
                strideBytes: const [],
                planes: const [],
                nativeHandles: [ntHandle],
              ),
            ),
          ),
        );
        if (file == null) {
          print('SKIP: D3D11 encoder unavailable on this machine');
          return;
        }
        await _assertMp4HasFrames(file, expectedFrames: _frames);
      },
    );

    test(
      'Path B-HW (MiniAVBufferSource CPU → best HW encoder): MP4 has $_frames frames',
      skip: enabled()
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (auto-downloads FFmpeg)',
      () async {
        final vendors = ffmpegHwVendorsAvailable();
        if (vendors.isEmpty) {
          print('SKIP: no HW encoder vendors present');
          return;
        }
        final frames = List.generate(_frames, (i) {
          final rgba = _gradientRgba(_w, _h, i);
          return FrameSource.miniavBuffer(
            MiniAVBuffer(
              type: MiniAVBufferType.video,
              contentType: MiniAVBufferContentType.cpu,
              timestampUs: i * (1000000 ~/ _fps),
              dataSizeBytes: rgba.length,
              data: MiniAVVideoBuffer(
                width: _w,
                height: _h,
                pixelFormat: MiniAVPixelFormat.rgba32,
                strideBytes: [_w * 4],
                planes: [rgba],
              ),
            ),
          );
        });
        final file = await _encodeToMp4(
          frames,
          'hw_miniav_buffer_cpu_path',
          hw: true,
        );
        if (file == null) {
          print('SKIP: HW encoder open failed on this machine');
          return;
        }
        await _assertMp4HasFrames(file, expectedFrames: _frames);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Encode a list of FrameSource frames to an MP4 file using SW or HW encoder.
// Returns null if hw=true and no HW encoder is available.
// ---------------------------------------------------------------------------

Future<File?> _encodeToMp4(
  List<FrameSource> frames,
  String tag, {
  bool hw = false,
}) async {
  final backend = FfmpegBackend();

  PlatformEncoder enc;
  if (hw) {
    try {
      enc = FfmpegHwEncoder.open(
        EncoderConfig(
          codec: VideoCodec.h264,
          width: _w,
          height: _h,
          bitrateBps: 2_000_000,
          frameRateNumerator: _fps,
          frameRateDenominator: 1,
          bFrameCount: 0,
          hwAccel: HwAccelPreference.required,
          rateControl: RateControl.vbr,
          backendOptions: const {'global_header': '1'},
        ),
      );
    } on CodecInitException catch (e) {
      print('HW encoder unavailable: ${e.message}');
      return null;
    }
  } else {
    final swEnc = await backend.createEncoder(
      EncoderConfig(
        codec: VideoCodec.h264,
        width: _w,
        height: _h,
        bitrateBps: 2_000_000,
        gopLength: _fps,
        frameRateNumerator: _fps,
        frameRateDenominator: 1,
        rateControl: RateControl.crf,
        crfQuality: 18,
        hwAccel: HwAccelPreference.forbidden,
        backendOptions: const {
          'preset': 'ultrafast',
          'tune': 'zerolatency',
          'global_header': '1',
          // This helper wires the encoder's FfmpegEncoderBridge into the
          // muxer below, so keep the in-isolate software encoder (the
          // isolate host has no bridge; the live recorder covers that path
          // via VideoTrackInfo.extraData instead).
          'sw_isolate': '0',
        },
      ),
    );
    expect(swEnc, isNotNull, reason: 'SW encoder failed to open');
    enc = swEnc!;
  }

  final outFile = File(
    '${Directory.systemTemp.path}/miniav_recorder_mp4_frame_test_$tag.mp4',
  );
  if (outFile.existsSync()) outFile.deleteSync();

  final muxer = FfmpegMuxer.open(
    MuxerConfig(
      container: Container.mp4,
      output: FileMuxerOutput(outFile.path),
      tracks: [
        VideoTrackInfo(
          codec: VideoCodec.h264,
          width: _w,
          height: _h,
          frameRateNumerator: _fps,
          frameRateDenominator: 1,
        ),
      ],
    ),
    encoderForTrack: {0: enc as FfmpegEncoderBridge},
  );
  await muxer.writeHeader();

  for (final src in frames) {
    final pkt = await enc.encode(src);
    if (pkt != null) await muxer.writePacket(pkt.copyWith(trackIndex: 0));
  }
  for (final pkt in await enc.flush()) {
    await muxer.writePacket(pkt.copyWith(trackIndex: 0));
  }

  await muxer.finish();
  await muxer.close();
  await enc.close();

  expect(outFile.existsSync(), isTrue, reason: 'MP4 file was not created');
  final size = outFile.lengthSync();
  print('[$tag] MP4: ${outFile.path} ($size bytes)');
  expect(size, greaterThan(4096), reason: 'MP4 file too small — likely empty');
  return outFile;
}

// ---------------------------------------------------------------------------
// Encode frames via the D3D11 zero-copy path (FfmpegD3d11HwEncoder) and mux
// to MP4. Returns null when D3D11 is unavailable (non-Windows, no shim, no
// vendor) or the encoder fails to open; the caller should skip in that case.
//
// [makeFrame] is called once per frame with (timestampUs, ntHandle) and
// returns the FrameSource to encode — this lets callers exercise either the
// D3D11TextureFrameSource path or the MiniAVBufferSource/gpuD3D11Handle path.
// ---------------------------------------------------------------------------

Future<File?> _encodeD3d11ToMp4(
  String tag,
  FrameSource Function(int timestampUs, Pointer<Void> ntHandle) makeFrame,
) async {
  if (!Platform.isWindows) return null;
  final shim = FfmpegShim.tryLoad();
  if (shim == null) return null;
  if (ffmpegD3d11VendorsAvailable().isEmpty) return null;

  FfmpegD3d11HwEncoder enc;
  try {
    enc = FfmpegD3d11HwEncoder.open(
      EncoderConfig(
        codec: VideoCodec.h264,
        width: _w,
        height: _h,
        bitrateBps: 2_000_000,
        gopLength: _fps,
        frameRateNumerator: _fps,
        frameRateDenominator: 1,
        bFrameCount: 0,
        hwAccel: HwAccelPreference.required,
        rateControl: RateControl.vbr,
        backendOptions: const {'global_header': '1'},
      ),
      sourceTextureFormat: D3d11HwSourceFormat.bgra,
    );
  } on CodecInitException catch (e) {
    print('D3D11 encoder open failed: ${e.message}');
    return null;
  }

  final tex = shim.testCreateSharedBgra(_w, _h);
  if (tex == nullptr) {
    await enc.close();
    return null;
  }

  final outFile = File(
    '${Directory.systemTemp.path}/miniav_recorder_mp4_frame_test_$tag.mp4',
  );
  if (outFile.existsSync()) outFile.deleteSync();

  final muxer = FfmpegMuxer.open(
    MuxerConfig(
      container: Container.mp4,
      output: FileMuxerOutput(outFile.path),
      tracks: [
        VideoTrackInfo(
          codec: VideoCodec.h264,
          width: _w,
          height: _h,
          frameRateNumerator: _fps,
          frameRateDenominator: 1,
        ),
      ],
    ),
    encoderForTrack: {0: enc as FfmpegEncoderBridge},
  );
  await muxer.writeHeader();

  try {
    for (var i = 0; i < _frames; i++) {
      shim.testFillBgra(tex, i);
      final ntHandle = shim.testTextureHandle(tex);
      final src = makeFrame(i * (1000000 ~/ _fps), ntHandle);
      final pkt = await enc.encode(src);
      if (pkt != null) await muxer.writePacket(pkt.copyWith(trackIndex: 0));
    }
    for (final pkt in await enc.flush()) {
      await muxer.writePacket(pkt.copyWith(trackIndex: 0));
    }
  } finally {
    shim.testDestroyTexture(tex);
  }

  await muxer.finish();
  await muxer.close();
  await enc.close();

  expect(outFile.existsSync(), isTrue, reason: 'D3D11 MP4 not created');
  print('[$tag] MP4: ${outFile.path} (${outFile.lengthSync()} bytes)');
  expect(
    outFile.lengthSync(),
    greaterThan(4096),
    reason: 'D3D11 MP4 too small — likely empty',
  );
  return outFile;
}

// ---------------------------------------------------------------------------
// Use ffprobe to count decoded video frames and verify luma is non-zero.
// ---------------------------------------------------------------------------

Future<void> _assertMp4HasFrames(
  File? file, {
  required int expectedFrames,
}) async {
  expect(file, isNotNull);
  final mp4 = file!;

  // Locate ffprobe in the same bin/ dir as the loaded FFmpeg DLLs.
  final ffprobeExe = _findFfprobe();
  if (ffprobeExe == null) {
    // ffprobe not found (non-BtbN install, or system FFmpeg). Fall back to a
    // file-size heuristic — better than nothing.
    print('WARNING: ffprobe not found; skipping frame-count check');
    expect(mp4.lengthSync(), greaterThan(4096));
    return;
  }

  // Count the number of decoded video frames.
  // -count_frames reads every frame; nb_read_frames is the actual count.
  final result = await Process.run(ffprobeExe, [
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-count_frames',
    '-show_entries',
    'stream=nb_read_frames',
    '-of',
    'default=noprint_wrappers=1:nokey=1',
    mp4.path,
  ]);

  if (result.exitCode != 0) {
    fail(
      'ffprobe failed (exit ${result.exitCode}):\n'
      '${result.stderr}',
    );
  }

  final raw = (result.stdout as String).trim();
  final frameCount = int.tryParse(raw);
  expect(
    frameCount,
    isNotNull,
    reason: 'ffprobe returned non-integer frame count: "$raw"',
  );
  print('[${mp4.uri.pathSegments.last}] ffprobe frame count: $frameCount');
  expect(
    frameCount,
    equals(expectedFrames),
    reason:
        'MP4 has $frameCount decoded frames but expected $expectedFrames. '
        'The encoder may have silently produced black/empty frames that were '
        'dropped, or plane[0] bytes were not forwarded.',
  );

  // Also verify that mean luma of the video stream is > 0, which catches
  // all-black content even when the frame count is correct.
  final lumaResult = await Process.run(ffprobeExe, [
    '-v', 'error',
    '-f', 'lavfi',
    '-i', 'movie=${mp4.path}[out0],signalstats',
    '-show_entries', 'frame_tags=lavfi.signalstats.YAVG',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    '-read_intervals', '%+1', // only first 1 second
  ]);

  // signalstats is a lavfi filter — available in gpl-shared builds. If it
  // fails (stripped FFmpeg build), just skip the luma check.
  if (lumaResult.exitCode == 0) {
    final lines = LineSplitter.split(
      lumaResult.stdout as String,
    ).where((l) => l.isNotEmpty).toList();
    if (lines.isNotEmpty) {
      final avgY = double.tryParse(lines.first);
      if (avgY != null) {
        print('[${mp4.uri.pathSegments.last}] mean Y (first frame): $avgY');
        expect(
          avgY,
          greaterThan(0.0),
          reason:
              'Decoded luma is 0 — MP4 contains all-black frames. '
              'Encoder received no/empty pixel data (CPU path regression).',
        );
      }
    }
  } else {
    print('Note: signalstats lavfi unavailable; skipping luma check');
  }
}

// ---------------------------------------------------------------------------
// Locate ffprobe next to the loaded FFmpeg DLLs.
// ---------------------------------------------------------------------------

String? _findFfprobe() {
  final libDir = ffmpegLoadedLibDir;
  if (libDir != null) {
    final name = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    // On Windows BtbN layout: bin/avcodec-62.dll  + bin/ffprobe.exe
    for (final candidate in [
      '$libDir${Platform.pathSeparator}$name',
      '${File(libDir).parent.path}${Platform.pathSeparator}bin'
          '${Platform.pathSeparator}$name',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  // System PATH fallback.
  final name = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
  for (final dir in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    final f = File('$dir${Platform.pathSeparator}$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _gradientRgba(int w, int h, int frameIdx) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = (y * w + x) * 4;
      out[p] = ((x + frameIdx * 3) & 0xff);
      out[p + 1] = ((y + frameIdx * 5) & 0xff);
      out[p + 2] = (((x ^ y) + frameIdx) & 0xff);
      out[p + 3] = 255;
    }
  }
  return out;
}
