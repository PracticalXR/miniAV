/// screenshare_mp4.dart
///
/// GPU-accelerated screenshare → MP4 pipeline.
///
/// Data path (no effect):
///   miniav WGC capture → D3D11 NT HANDLE → FfmpegD3d11HwEncoder (zero-copy)
///   or miniav WGC capture → CPU BGRA → FfmpegHwEncoder / libx264
///
/// Data path (with --effect, fully zero-copy on GPU):
///   miniav WGC capture → D3D11 NT HANDLE
///     → minigpu CopyResource (same D3D11 device, sync'd)
///     → Dawn D3D11 compute toRGBA + vignette effect
///     → SharedOutputTexture (shared ID3D11Device with encoder)
///     → FfmpegD3d11HwEncoder hevc_nvenc / AMF / QSV
///     → FfmpegMuxer → output.mp4
///
///   For widths > 4096 the encoder is promoted from H.264 to HEVC.
///
/// Usage:
///   dart run bin/screenshare_mp4.dart [seconds] [output.mp4] [--hw] [--zerocopy] [--effect]
///
///   --hw           Use the best available hardware encoder.
///   --zerocopy     D3D11VA encoder — no GPU↔CPU copies.
///   --effect       Apply vignette+warm GPU effect (zero-copy when --zerocopy).
library;

import 'dart:ffi' show Pointer;
import 'dart:io';
import 'dart:typed_data';

import 'package:miniav/miniav.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:minigpu/minigpu.dart';

const int _defaultDurationSeconds = 10;
const int _targetBitrateBps = 4 * 1000 * 1000; // 4 Mbps

// ─── main ─────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final useHw = args.contains('--hw');
  final useEffect = args.contains('--effect');
  final useZeroCopy = args.contains('--zerocopy');

  final int durationSecs = positional.isNotEmpty
      ? int.tryParse(positional[0]) ?? _defaultDurationSeconds
      : _defaultDurationSeconds;
  final String outputPath = positional.length >= 2
      ? positional[1]
      : 'screenshare_output.mp4';

  print('━━━ screenshare → MP4 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('  Duration : ${durationSecs}s');
  print('  Output   : $outputPath');
  print(
    '  Encoder  : ${useHw ? "HW${useZeroCopy ? " zero-copy (D3D11VA)" : ""}" : "libx264 (CPU)"}',
  );
  print('  Effect   : ${useEffect ? "vignette+warm (GPU)" : "off"}');
  print('─────────────────────────────────────────────────────────────');

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  // ── 1. Enumerate displays ──────────────────────────────────────────────────
  final displays = await MiniScreen.enumerateDisplays();
  if (displays.isEmpty) {
    stderr.writeln('[error] No displays found.');
    exit(1);
  }
  final display = displays.firstWhere(
    (d) => d.isDefault,
    orElse: () => displays.first,
  );
  print('  Display  : ${display.name} (${display.deviceId})');

  // ── 2. Query capture format ────────────────────────────────────────────────
  final formats = await MiniScreen.getDefaultFormats(display.deviceId);
  // Request GPU output (D3D11 NT handle) when we need on-GPU work;
  // otherwise CPU BGRA bytes for full capture framerate.
  final wantGpuCapture = useEffect || useZeroCopy;
  final MiniAVVideoInfo captureFormat = MiniAVVideoInfo(
    width: formats.$1.width,
    height: formats.$1.height,
    pixelFormat: MiniAVPixelFormat.bgra32, // DXGI always produces BGRA
    frameRateNumerator: formats.$1.frameRateNumerator,
    frameRateDenominator: formats.$1.frameRateDenominator,
    outputPreference: wantGpuCapture
        ? MiniAVOutputPreference
              .gpu // → D3D11 NT HANDLE (for minigpu)
        : MiniAVOutputPreference.cpu, // → BGRA bytes in system memory
  );

  final int W = captureFormat.width;
  final int H = captureFormat.height;
  final int fpsNum = captureFormat.frameRateNumerator;
  final int fpsDen = captureFormat.frameRateDenominator;
  print('  Format   : ${W}x${H} @ ${fpsNum ~/ fpsDen} fps  (GPU output)');

  // ── 3. Initialise minigpu ─────────────────────────────────────────────────
  print('\n[minigpu] Initialising WebGPU context…');
  final gpu = Minigpu();
  await gpu.init();
  final gpuSupported = gpu.isExternalContentTypeSupported(
    ExternalContentType.d3d11SharedHandle,
  );
  print('[minigpu] Ready.  D3D11 import supported: $gpuSupported');

  // ── 4. Optionally load the minigpu effect shader ──────────────────────────
  GpuEffect? effect;
  if (useEffect) {
    final wgsl = await File(_resolveDefaultEffectShader()).readAsString();
    effect = GpuEffect(gpu: gpu, wgsl: wgsl, strength: 1.0);
    print('[effect ] vignette_warm loaded');
  }

  // ── 4. Load FFmpeg (auto-download if not present) ─────────────────────────
  print('\n[ffmpeg] Loading libraries…');
  final loaded = await ensureFFmpegLoaded();
  if (!loaded) {
    stderr.writeln(
      '[error] Could not load FFmpeg. Ensure FFmpeg is installed '
      'or allow the auto-download (needs network access).',
    );
    exit(1);
  }
  print('[ffmpeg] Ready.');

  // ── 5. Create video encoder ───────────────────────────────────────────────
  // H.264 hardware encoders cap at 4096px wide on every shipping vendor.
  // For ultrawide / 4K+ captures we transparently promote to HEVC.
  final backend = FfmpegBackend();
  final chosenCodec = FfmpegBackend.bestCodecForResolution(
    width: W,
    height: H,
    hwAccel: useHw,
    preferred: VideoCodec.h264,
  );
  if (chosenCodec != VideoCodec.h264) {
    print(
      '[encoder] ${W}x${H} exceeds H.264 HW cap (4096); promoting to '
      '${chosenCodec.name.toUpperCase()}.',
    );
  }
  final encoderCfg = EncoderConfig(
    codec: chosenCodec,
    width: W,
    height: H,
    bitrateBps: _targetBitrateBps,
    frameRateNumerator: fpsNum,
    frameRateDenominator: fpsDen,
    bFrameCount: 0, // B-frames would require DTS re-ordering; keep 0 for
    // live/low-latency capture.
    hwAccel: useHw ? HwAccelPreference.preferred : HwAccelPreference.forbidden,
    rateControl: RateControl.vbr,
    backendOptions: useHw
        ? {
            // NVENC tuning for screen capture.
            'preset': 'p4', // balanced (p1=fastest..p7=slowest)
            'tune': 'll', // low-latency
            'global_header': '1', // MP4 needs SPS/PPS in extradata.
            // D3D11VA zero-copy opt-in (AMF/QSV/MF), ignored otherwise.
            if (useZeroCopy) 'zerocopy': '1',
          }
        : const {
            'preset': 'ultrafast', // low encode latency for screen capture
            'tune': 'zerolatency',
            'global_header': '1',
          },
  );

  // On Windows with zero-copy, inject Dawn's own ID3D11Device into the
  // encoder so the shared output texture and encoder share one device.
  int dawnD3d11Device = 0;
  if (useZeroCopy && useHw && gpuSupported && Platform.isWindows) {
    dawnD3d11Device = gpu.createD3D11DeviceOnDawnAdapter();
  }

  PlatformEncoder? platformEncoder;
  if (dawnD3d11Device != 0) {
    try {
      platformEncoder = FfmpegD3d11HwEncoder.open(
        encoderCfg,
        existingD3d11Device: dawnD3d11Device,
        sourceTextureFormat: D3d11HwSourceFormat.bgra,
      );
    } on CodecInitException catch (e) {
      print('[encoder] D3D11 encoder failed: $e');
      platformEncoder = null;
    }
  }
  platformEncoder ??= await backend.createEncoder(encoderCfg);
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
  final isZeroCopyEncoder = platformEncoder is FfmpegD3d11HwEncoder;
  if (useZeroCopy && !isZeroCopyEncoder) {
    print('[encoder] --zerocopy unavailable for $chosenCodec — falling back.');
  }
  if (useHw && platformEncoder is! FfmpegHwEncoder && !isZeroCopyEncoder) {
    print('[encoder] No HW encoder available; using libx264.');
  }
  final ffEncoder = platformEncoder;
  print(
    '[encoder] ${chosenCodec.name.toUpperCase()} $encoderName '
    '${W}x${H} @ ${fpsNum ~/ fpsDen}fps ready.',
  );

  // ── 5b. SharedOutputTexture for zero-copy effect path ────────────────────
  // When effect + D3D11 encoder, route GPU Buffer directly into the shared
  // texture so the encoder reads it without any GPU↔CPU copy.
  SharedOutputTexture? sharedTex;
  if (useEffect && isZeroCopyEncoder && gpuSupported) {
    sharedTex = gpu.createSharedOutputTexture(W, H);
    if (sharedTex == null) {
      print(
        '[gpu] WARNING: createSharedOutputTexture failed — using CPU readback.',
      );
    } else {
      print('[gpu] SharedOutputTexture ${W}x${H} ready.');
    }
  }

  // ── 6. Open MP4 muxer ─────────────────────────────────────────────────────
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
        // extraData is null here because FfmpegMuxer.open(encoderForTrack:)
        // pulls it directly from the native AVCodecContext instead.
      ),
    ],
  );

  final muxer = FfmpegMuxer.open(
    muxerCfg,
    encoderForTrack: {0: ffEncoder as FfmpegEncoderBridge},
  );
  await muxer.writeHeader();
  print('[muxer ] MP4 → $outputPath  (header written)');

  // ── 7. Screen capture ─────────────────────────────────────────────────────
  final screenCtx = await MiniScreen.createContext();
  await screenCtx.configureDisplay(display.deviceId, captureFormat);

  // Warn when the GPU readback path will be the bottleneck.
  if (useEffect && sharedTex != null) {
    print(
      '[gpu   ] Zero-copy effect path: GPU Buffer → SharedOutputTexture → D3D11 encoder.',
    );
  } else if (useEffect && W * H > 1920 * 1080) {
    print(
      '[perf  ] NOTE: GPU effect + readback at ${W}x${H} will be slow. Add --zerocopy for zero-copy path.',
    );
  }

  int frameIn = 0;
  int frameOut = 0;
  int bytesWritten = 0;
  int framesDropped = 0;
  // miniav fires callbacks on the capture thread without awaiting; if our
  // (GPU readback + encode) work is slower than the capture rate, callbacks
  // queue up unboundedly and exhaust native resources (observed: STATUS_
  // STACK_BUFFER_OVERRUN once hundreds of in-flight D3D11 imports accumulate).
  // Drop frames while one is being processed — realtime capture semantics.
  bool busy = false;
  // Set to true after stopCapture() so that any callback that fires late
  // (still in-flight when the capture stops) skips encoding cleanly.
  bool stopping = false;

  print('\n[capture] Starting… (${durationSecs}s)');

  await screenCtx.startCapture((MiniAVBuffer buffer, Object? _) async {
    if (busy || stopping) {
      framesDropped++;
      await MiniAV.releaseBuffer(buffer);
      return;
    }
    busy = true;
    try {
      // ── 7a. Build a FrameSource ──────────────────────────────────────────────
      //
      // Zero-copy effect path (effect + D3D11 encoder + sharedTex):
      //   D3D11 import → toRGBA → effect.apply → sharedTex → D3D11TextureFrameSource
      //
      // Zero-copy direct path (no effect, D3D11 encoder):
      //   Feed miniav's D3D11 NT handle straight to FfmpegD3d11HwEncoder.
      //
      // CPU readback path (effect, no D3D11 encoder):
      //   toRGBA → effect.apply → GPU→CPU readback → encoder CPU upload.
      //
      // CPU fallback:
      //   If minigpu import fails fall back to miniavBuffer.

      FrameSource frameSource;

      // Zero-copy effect path: GPU effect → shared texture → D3D11 encoder.
      if (isZeroCopyEncoder &&
          effect != null &&
          sharedTex != null &&
          buffer.contentType == MiniAVBufferContentType.gpuD3D11Handle &&
          gpuSupported) {
        final ok = await _d3d11EffectToSharedTex(
          buffer,
          gpu,
          effect: effect,
          sharedTex: sharedTex,
        );
        if (ok) {
          frameSource = D3D11TextureFrameSource(
            texturePtr: sharedTex.d3d11TexturePtr,
            width: W,
            height: H,
            pixelFormat: MiniAVPixelFormat.rgba32,
          );
          frameIn++;
          try {
            final EncodedPacket? pkt = await ffEncoder.encode(frameSource);
            if (pkt != null) {
              await muxer.writePacket(pkt);
              frameOut++;
              bytesWritten += pkt.data.length;
            }
          } finally {
            await MiniAV.releaseBuffer(buffer);
          }
          return;
        } else {
          stderr.writeln(
            '[gpu] frame $frameIn: zero-copy effect path failed — skipping',
          );
          await MiniAV.releaseBuffer(buffer);
          return;
        }
      }

      // Zero-copy direct path: D3D11 NT handle straight to encoder.
      if (isZeroCopyEncoder &&
          buffer.contentType == MiniAVBufferContentType.gpuD3D11Handle) {
        frameSource = FrameSource.miniavBuffer(buffer);
        frameIn++;
        try {
          final EncodedPacket? pkt = await ffEncoder.encode(frameSource);
          if (pkt != null) {
            await muxer.writePacket(pkt);
            frameOut++;
            bytesWritten += pkt.data.length;
          }
        } finally {
          await MiniAV.releaseBuffer(buffer);
        }
        return;
      }

      final wantGpuPath = useEffect;
      if (wantGpuPath &&
          buffer.contentType == MiniAVBufferContentType.gpuD3D11Handle &&
          gpuSupported) {
        final rgba = await _d3d11ToRgba(buffer, gpu, effect: effect);
        if (rgba != null) {
          frameSource = FrameSource.cpu(
            bytes: rgba,
            pixelFormat: MiniAVPixelFormat.rgba32,
            width: W,
            height: H,
            timestampUs: buffer.timestampUs,
          );
        } else {
          stderr.writeln(
            '[gpu] frame $frameIn: D3D11 import returned null — skipping',
          );
          await MiniAV.releaseBuffer(buffer);
          return;
        }
      } else {
        // CPU fallback: FfmpegSoftwareEncoder reads plane[0] (BGRA32) directly.
        frameSource = FrameSource.miniavBuffer(buffer);
      }

      frameIn++;

      // ── 7b. Encode ──────────────────────────────────────────────────────────
      try {
        final EncodedPacket? pkt = await ffEncoder.encode(frameSource);
        if (pkt != null) {
          await muxer.writePacket(pkt);
          frameOut++;
          bytesWritten += pkt.data.length;
        }
      } catch (e, st) {
        stderr.writeln('[encode] frame $frameIn error: $e');
        if (frameIn <= 2) stderr.writeln(st);
      }

      // Always release the miniav buffer; the native capture layer recycles it.
      await MiniAV.releaseBuffer(buffer);

      if (frameIn % 30 == 0) {
        final kbWritten = (bytesWritten / 1024).toStringAsFixed(0);
        stdout.write(
          '\r  frame=$frameIn  encoded=$frameOut  '
          'written=${kbWritten}KB  dropped=$framesDropped   ',
        );
      }
    } finally {
      busy = false;
    }
  });

  // ── 8. Run for the requested duration ─────────────────────────────────────
  await Future.delayed(Duration(seconds: durationSecs));
  print('\n\n[capture] Stopping…');

  stopping = true; // tell any future callbacks to drop immediately
  await screenCtx.stopCapture();
  await screenCtx.destroy();

  // Wait for any capture callback that was already mid-flight (GPU readback +
  // encode) when stopCapture() returned. Without this, ffEncoder.close() races
  // with the in-flight encode() and throws "encoder closed".
  while (busy) {
    await Future.delayed(const Duration(milliseconds: 10));
  }

  // ── 9. Flush encoder — drain any buffered B-frames ────────────────────────
  print('[encoder] Flushing…');
  final List<EncodedPacket> tail = await ffEncoder.flush();
  for (final pkt in tail) {
    await muxer.writePacket(pkt);
    frameOut++;
  }

  // ── 10. Finalise MP4 ──────────────────────────────────────────────────────
  await muxer.finish();
  await muxer.close();
  await ffEncoder.close();

  sharedTex?.destroy();

  await gpu.destroy();
  MiniAV.dispose();

  // ── 11. Summary ───────────────────────────────────────────────────────────
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

// ─── GPU zero-copy effect helper ─────────────────────────────────────────────

/// Import a miniav GPU buffer, run BGRA→RGBA on GPU, apply [GpuEffect],
/// then copy into [sharedTex] — all on GPU, no PCIe transfer.
///
/// Returns true on success; false on any failure (caller skips the frame).
Future<bool> _d3d11EffectToSharedTex(
  MiniAVBuffer buffer,
  Minigpu gpu, {
  required GpuEffect effect,
  required SharedOutputTexture sharedTex,
}) async {
  final video = buffer.data;
  if (video is! MiniAVVideoBuffer) return false;
  if (video.nativeHandles.isEmpty || video.nativeHandles[0] == null) {
    return false;
  }
  // nativeHandles[0] is the shared NT HANDLE value as a plain Dart int
  // (older builds handed out a Pointer<Void>; accept both).
  final rawHandle = video.nativeHandles[0];
  final int handleAddr = rawHandle is int
      ? rawHandle
      : (rawHandle as Pointer).address;
  if (handleAddr == 0) return false;

  final int stride = video.strideBytes.isNotEmpty
      ? video.strideBytes[0]
      : video.width * 4;

  final extBuf = ExternalVideoBuffer(
    contentType: ExternalContentType.d3d11SharedHandle,
    pixelFormat: ExternalPixelFormat.bgra32,
    width: video.width,
    height: video.height,
    planes: [
      ExternalPlane(
        dataPtr: handleAddr,
        width: video.width,
        height: video.height,
        strideBytes: stride,
      ),
    ],
    fence: ExternalFence(d3d11FencePtr: buffer.nativeFence.d3d11FencePtr),
    timestampUs: buffer.timestampUs,
  );

  VideoTexture? tex;
  Buffer? rgbaBuf;
  try {
    tex = gpu.importVideoFrame(extBuf);
    if (tex == null) return false;

    // BGRA→RGBA on GPU (compute dispatch → GPU storage Buffer).
    rgbaBuf = tex.toRGBA();

    // Apply effect in-place on the GPU buffer (compute dispatch).
    await effect.apply(rgbaBuf, video.width, video.height);

    // Copy GPU buffer → SharedOutputTexture (compute dispatch, no PCIe).
    final copied = sharedTex.copyFromBuffer(rgbaBuf);
    rgbaBuf.destroy();
    rgbaBuf = null;
    return copied;
  } catch (e, st) {
    stderr.writeln('[gpu] _d3d11EffectToSharedTex error: $e');
    stderr.writeln(st);
    return false;
  } finally {
    rgbaBuf?.destroy();
    tex?.destroy();
  }
}

// ─── GPU readback helper ──────────────────────────────────────────────────────

/// Import a miniav GPU buffer (D3D11 NT HANDLE) into minigpu, run an on-GPU
/// BGRA→RGBA conversion via [VideoTexture.toRGBA], then read the result back
/// to a [Uint8List].
///
/// Returns `null` on any failure so the caller can fall back to the CPU path.
Future<Uint8List?> _d3d11ToRgba(
  MiniAVBuffer buffer,
  Minigpu gpu, {
  GpuEffect? effect,
}) async {
  final video = buffer.data;
  if (video is! MiniAVVideoBuffer) return null;

  if (video.nativeHandles.isEmpty || video.nativeHandles[0] == null) {
    return null;
  }
  // nativeHandles[0] is the shared NT HANDLE value as a plain Dart int
  // (older builds handed out a Pointer<Void>; accept both).
  final rawHandle = video.nativeHandles[0];
  final int handleAddr = rawHandle is int
      ? rawHandle
      : (rawHandle as Pointer).address;
  if (handleAddr == 0) return null;

  final int stride = video.strideBytes.isNotEmpty
      ? video.strideBytes[0]
      : video.width * 4;

  // Build the cross-API descriptor.  minigpu calls DuplicateHandle internally
  // so ownership stays with miniav until MiniAV.releaseBuffer().
  final extBuf = ExternalVideoBuffer(
    contentType: ExternalContentType.d3d11SharedHandle,
    pixelFormat: ExternalPixelFormat.bgra32, // DXGI DDA always gives BGRA
    width: video.width,
    height: video.height,
    planes: [
      ExternalPlane(
        dataPtr: handleAddr,
        width: video.width,
        height: video.height,
        strideBytes: stride,
      ),
    ],
    // Forward the D3D11 fence: minigpu waits for DXGI to finish writing the
    // texture before the compute pass reads it.
    fence: ExternalFence(d3d11FencePtr: buffer.nativeFence.d3d11FencePtr),
    timestampUs: buffer.timestampUs,
  );

  VideoTexture? tex;
  try {
    tex = gpu.importVideoFrame(extBuf);
    if (tex == null) return null;

    // BGRA→RGBA on GPU (single compute dispatch, no CPU involvement until
    // the readback below).
    final rgbaBuf = tex.toRGBA();
    final pixelCount = video.width * video.height;

    // Optional minigpu effect pass — modifies rgbaBuf in place on the GPU.
    if (effect != null) {
      await effect.apply(rgbaBuf, video.width, video.height);
    }

    final out = Uint8List(pixelCount * 4);
    await rgbaBuf.read(out, pixelCount * 4, dataType: BufferDataType.uint8);
    rgbaBuf.destroy();
    return out;
  } catch (e, st) {
    stderr.writeln('[gpu] _d3d11ToRgba error: $e');
    stderr.writeln(st);
    return null;
  } finally {
    tex?.destroy();
  }
}

// ─── minigpu effect pass ─────────────────────────────────────────────────────

/// Lightweight wrapper around a single-kernel WGSL compute shader applied
/// in-place to an RGBA8 [Buffer]. Binding layout (set in
/// `shaders/vignette_warm.wgsl`):
///   @binding(0) storage read_write u32 array  — the RGBA pixels (in/out)
///   @binding(1) storage read       Params     — width/height/strength
class GpuEffect {
  GpuEffect({required this.gpu, required this.wgsl, required this.strength});

  final Minigpu gpu;
  final String wgsl;
  final double strength;

  ComputeShader? _shader;
  Buffer? _params;
  int _lastW = -1;
  int _lastH = -1;

  Future<void> apply(Buffer pixels, int width, int height) async {
    final shader = _shader ??= () {
      final s = gpu.createComputeShader();
      s.loadKernelString(wgsl);
      return s;
    }();

    if (_params == null || _lastW != width || _lastH != height) {
      _params?.destroy();
      // Params layout: u32 width, u32 height, f32 strength, f32 _pad → 4 f32s = 16 bytes.
      // Note: Minigpu.createBuffer's first arg is byte size, NOT element count.
      final p = gpu.createBuffer(16, BufferDataType.float32);
      final view = ByteData(16);
      view.setUint32(0, width, Endian.little);
      view.setUint32(4, height, Endian.little);
      view.setFloat32(8, strength.clamp(0.0, 1.0), Endian.little);
      view.setFloat32(12, 0.0, Endian.little);
      await p.write(
        view.buffer.asFloat32List(),
        4,
        dataType: BufferDataType.float32,
      );
      _params = p;
      _lastW = width;
      _lastH = height;
    }

    shader.resetTagOrder();
    shader.setBufferAtSlot(0, pixels);
    shader.setBufferAtSlot(1, _params!);

    // Workgroup size in WGSL is 8x8, so dispatch ceil(w/8) x ceil(h/8).
    final gx = (width + 7) ~/ 8;
    final gy = (height + 7) ~/ 8;
    await shader.dispatch(gx, gy, 1);
  }

  void destroy() {
    _shader?.destroy();
    _params?.destroy();
    _shader = null;
    _params = null;
  }
}

/// Locate `shaders/vignette_warm.wgsl` relative to this script. Works for
/// both `dart run` (script Uri points at bin/) and AOT-compiled snapshots.
String _resolveDefaultEffectShader() {
  final scriptUri = Platform.script;
  // bin/screenshare_mp4.dart → ../shaders/vignette_warm.wgsl
  final base = scriptUri.resolve('../shaders/vignette_warm.wgsl');
  if (base.scheme == 'file') {
    final p = base.toFilePath();
    if (File(p).existsSync()) return p;
  }
  // Fallback: relative to CWD.
  const rel = 'shaders/vignette_warm.wgsl';
  if (File(rel).existsSync()) return rel;
  throw StateError(
    'Could not locate vignette_warm.wgsl. Pass --effect-shader=PATH.',
  );
}
