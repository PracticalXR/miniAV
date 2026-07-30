/// Validates the [GpuScreenProcessor] shared-output texture ring (Phase E of
/// the GPU-saturation work): with `sharedRingDepth: 2`, consecutive
/// `process()` calls must return ALTERNATING textures, so the pipelined
/// runtime can encode frame N's texture while frame N+1's is being written.
/// Runs the real minigpu import + blit path; skips without a GPU/shim.
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

const _w = 128;
const _h = 64;

MiniAVBuffer _bufferFor(Pointer<Void> ntHandle, int ts) => MiniAVBuffer(
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
);

void main() {
  test('sharedRingDepth=2 rotates between two output textures', () async {
    if (!Platform.isWindows) {
      markTestSkipped('D3D11 shared textures are Windows-only');
      return;
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      markTestSkipped('ffmpeg shim asset not available');
      return;
    }
    await Recorder.ensureSharedGpu();
    final gpu = Recorder.sharedGpu;
    if (gpu == null) {
      markTestSkipped('No GPU/Dawn device available');
      return;
    }

    final srcTex = shim.testCreateSharedBgra(_w, _h);
    if (srcTex == nullptr) {
      markTestSkipped('Could not create D3D11 test texture');
      return;
    }

    final proc = GpuScreenProcessor(
      gpu: gpu,
      srcWidth: _w,
      srcHeight: _h,
      dstWidth: _w,
      dstHeight: _h,
      sharedRingDepth: 2,
    );
    try {
      shim.testFillBgra(srcTex, 0);
      final nt = shim.testTextureHandle(srcTex);

      final slot0 = await proc.process(_bufferFor(nt, 0));
      final slot1 = await proc.process(_bufferFor(nt, 33333));
      final slot2 = await proc.process(_bufferFor(nt, 66666));

      expect(slot0, isNotNull, reason: 'first process() failed');
      expect(slot1, isNotNull, reason: 'second process() failed');
      expect(slot2, isNotNull, reason: 'third process() failed');

      final p0 = slot0!.d3d11TexturePtr;
      final p1 = slot1!.d3d11TexturePtr;
      final p2 = slot2!.d3d11TexturePtr;
      expect(p0, isNot(0));
      expect(p1, isNot(0));
      expect(
        p1,
        isNot(equals(p0)),
        reason: 'depth-2 ring must alternate textures between frames',
      );
      expect(
        p2,
        equals(p0),
        reason: 'third frame must wrap back to the first slot',
      );
    } finally {
      proc.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('default sharedRingDepth=1 keeps returning the same texture', () async {
    if (!Platform.isWindows) {
      markTestSkipped('D3D11 shared textures are Windows-only');
      return;
    }
    final shim = FfmpegShim.tryLoad();
    if (shim == null) {
      markTestSkipped('ffmpeg shim asset not available');
      return;
    }
    await Recorder.ensureSharedGpu();
    final gpu = Recorder.sharedGpu;
    if (gpu == null) {
      markTestSkipped('No GPU/Dawn device available');
      return;
    }
    final srcTex = shim.testCreateSharedBgra(_w, _h);
    if (srcTex == nullptr) {
      markTestSkipped('Could not create D3D11 test texture');
      return;
    }
    final proc = GpuScreenProcessor(
      gpu: gpu,
      srcWidth: _w,
      srcHeight: _h,
      dstWidth: _w,
      dstHeight: _h,
    );
    try {
      shim.testFillBgra(srcTex, 1);
      final nt = shim.testTextureHandle(srcTex);
      final a = await proc.process(_bufferFor(nt, 0));
      final b = await proc.process(_bufferFor(nt, 33333));
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(b!.d3d11TexturePtr, equals(a!.d3d11TexturePtr));
    } finally {
      proc.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
