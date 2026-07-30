/// Runtime validation of the minigpu async shared-output copy (Phase 2 #6):
/// `SharedOutputTexture.copyFromBufferAsync` must run the GPU copy on minigpu's
/// worker thread and complete its Future (instead of busy-polling the present
/// wait on this isolate). Exercises the real native path; skips if the
/// cross-API shared-texture path is unavailable in this environment.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:minigpu/minigpu.dart';
import 'package:test/test.dart';

void main() {
  test('copyFromBufferAsync completes off the isolate', () async {
    await Recorder.ensureSharedGpu();
    final gpu = Recorder.sharedGpu;
    if (gpu == null) {
      markTestSkipped('No GPU/Dawn device available');
      return;
    }

    const w = 64, h = 32;
    SharedOutputTexture? tex;
    try {
      tex = gpu.createSharedOutputTexture(w, h);
    } catch (e) {
      markTestSkipped('Shared output texture unsupported here: $e');
      return;
    }
    if (tex == null) {
      markTestSkipped('createSharedOutputTexture returned null');
      return;
    }

    final buf = gpu.createBuffer(w * h * 4, BufferDataType.uint8);
    try {
      final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 128);
      await buf.write(rgba, w * h * 4, dataType: BufferDataType.uint8);

      // The async copy: the Future must complete (proving the native symbol is
      // exported and the worker-thread callback fires back into Dart).
      final ok = await tex.copyFromBufferAsync(buf);
      expect(ok, isTrue, reason: 'async GPU copy + present sync should succeed');

      // It must remain usable repeatedly (per-frame hot path).
      final ok2 = await tex.copyFromBufferAsync(buf);
      expect(ok2, isTrue);
    } finally {
      buf.destroy();
      tex.destroy();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
