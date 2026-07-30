import 'dart:typed_data';

import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

/// Pure Dart contract tests for miniav GPU interop types.
///
/// These tests do not require hardware or a live camera — they verify that
/// the Dart type definitions that form the GPU buffer handoff contract are
/// present, correctly typed, and have the expected default values. Any
/// breaking change to the public API will be caught here before it breaks
/// the minigpu integration layer.
void main() {
  // ---------------------------------------------------------------------------
  // MiniAVPixelFormat enum
  // ---------------------------------------------------------------------------
  group('MiniAVPixelFormat', () {
    test('rgba32 variant exists', () {
      expect(MiniAVPixelFormat.values, contains(MiniAVPixelFormat.rgba32));
    });

    test('nv12 variant exists', () {
      expect(MiniAVPixelFormat.values, contains(MiniAVPixelFormat.nv12));
    });

    test('bgra32 variant exists', () {
      expect(MiniAVPixelFormat.values, contains(MiniAVPixelFormat.bgra32));
    });

    test('i420 variant exists', () {
      expect(MiniAVPixelFormat.values, contains(MiniAVPixelFormat.i420));
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVOutputPreference enum
  // ---------------------------------------------------------------------------
  group('MiniAVOutputPreference', () {
    test('cpu variant exists', () {
      expect(
        MiniAVOutputPreference.values,
        contains(MiniAVOutputPreference.cpu),
      );
    });

    test('gpu variant exists', () {
      expect(
        MiniAVOutputPreference.values,
        contains(MiniAVOutputPreference.gpu),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVBufferContentType enum
  // ---------------------------------------------------------------------------
  group('MiniAVBufferContentType', () {
    test('cpu variant exists', () {
      expect(
        MiniAVBufferContentType.values,
        contains(MiniAVBufferContentType.cpu),
      );
    });

    test('gpuD3D11Handle variant exists', () {
      expect(
        MiniAVBufferContentType.values,
        contains(MiniAVBufferContentType.gpuD3D11Handle),
      );
    });

    test('gpuMetalTexture variant exists', () {
      expect(
        MiniAVBufferContentType.values,
        contains(MiniAVBufferContentType.gpuMetalTexture),
      );
    });

    test('gpuDmabufFd variant exists', () {
      expect(
        MiniAVBufferContentType.values,
        contains(MiniAVBufferContentType.gpuDmabufFd),
      );
    });

    test('gpuAHardwareBuffer variant exists', () {
      expect(
        MiniAVBufferContentType.values,
        contains(MiniAVBufferContentType.gpuAHardwareBuffer),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVNativeFence – default field values
  // ---------------------------------------------------------------------------
  group('MiniAVNativeFence', () {
    test('default constructor creates valid fence with sentinel values', () {
      const fence = MiniAVNativeFence();
      expect(fence.syncFd, equals(-1));
      expect(fence.d3d11FencePtr, equals(0));
      expect(fence.metalSharedEventPtr, equals(0));
      expect(fence.metalFenceValue, equals(0));
    });

    test('all fields can be set via named parameters', () {
      const fence = MiniAVNativeFence(
        syncFd: 5,
        d3d11FencePtr: 0xDEADBEEF,
        metalSharedEventPtr: 0xCAFEBABE,
        metalFenceValue: 42,
      );
      expect(fence.syncFd, equals(5));
      expect(fence.d3d11FencePtr, equals(0xDEADBEEF));
      expect(fence.metalSharedEventPtr, equals(0xCAFEBABE));
      expect(fence.metalFenceValue, equals(42));
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVVideoBuffer – GPU contract fields
  // ---------------------------------------------------------------------------
  group('MiniAVVideoBuffer', () {
    test('CPU RGBA32 buffer has correct fields', () {
      final buf = MiniAVVideoBuffer(
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [1920 * 4],
        planes: [Uint8List(1920 * 1080 * 4)],
      );
      expect(buf.width, equals(1920));
      expect(buf.height, equals(1080));
      expect(buf.pixelFormat, equals(MiniAVPixelFormat.rgba32));
      expect(buf.strideBytes, hasLength(1));
      expect(buf.strideBytes[0], equals(1920 * 4));
      expect(buf.planes, hasLength(1));
    });

    test('NV12 buffer has two plane entries', () {
      final buf = MiniAVVideoBuffer(
        width: 1280,
        height: 720,
        pixelFormat: MiniAVPixelFormat.nv12,
        strideBytes: [1280, 1280],
        planes: [Uint8List(1280 * 720), Uint8List(1280 * 360)],
      );
      expect(buf.planes, hasLength(2));
      expect(buf.pixelFormat, equals(MiniAVPixelFormat.nv12));
    });

    test('nativeHandles defaults to empty list', () {
      final buf = MiniAVVideoBuffer(
        width: 4,
        height: 4,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [16],
        planes: [Uint8List(64)],
      );
      expect(buf.nativeHandles, isEmpty);
    });

    test('dmabufFds defaults to empty list', () {
      final buf = MiniAVVideoBuffer(
        width: 4,
        height: 4,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [16],
        planes: [Uint8List(64)],
      );
      expect(buf.dmabufFds, isEmpty);
    });

    test('drmFormatModifiers defaults to empty list', () {
      final buf = MiniAVVideoBuffer(
        width: 4,
        height: 4,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [16],
        planes: [Uint8List(64)],
      );
      expect(buf.drmFormatModifiers, isEmpty);
    });

    test('GPU D3D11 buffer carries nativeHandle', () {
      final fakeHandle = Object();
      final buf = MiniAVVideoBuffer(
        width: 1280,
        height: 720,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [0],
        planes: [null], // GPU texture — no CPU data
        nativeHandles: [fakeHandle],
      );
      expect(buf.nativeHandles, hasLength(1));
      expect(buf.nativeHandles[0], same(fakeHandle));
    });

    // Regression: the README used to tell integrators the GPU handle lives in
    // `planes[0]`. It does not — it is in `nativeHandles[0]`, and `planes[0]`
    // as produced by the FFI shim is a non-null but EMPTY Uint8List (stride 0),
    // so `planes[0] != null` silently takes the CPU branch. `contentType` is
    // the discriminator.
    test('GPU-path layout: contentType discriminates, not planes[0]', () {
      // Exactly what MiniAVBufferFFI.fromPointer produces on the gpuD3D11Handle
      // path: stride 0 => zero-length typed-data view, handle as an int.
      const handleValue = 0x1234;
      final videoBuf = MiniAVVideoBuffer(
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.bgra32,
        strideBytes: [0, 0, 0, 0],
        planes: [Uint8List(0), null, null, null],
        nativeHandles: [handleValue, null, null, null],
      );
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.gpuD3D11Handle,
        timestampUs: 1,
        data: videoBuf,
        dataSizeBytes: 1920 * 1080 * 4,
      );

      // The correct branch.
      expect(buf.contentType, equals(MiniAVBufferContentType.gpuD3D11Handle));
      expect(videoBuf.nativeHandles[0], isA<int>());
      expect(videoBuf.nativeHandles[0], equals(handleValue));

      // The trap: non-null but useless as pixel data / as a discriminator.
      expect(videoBuf.planes[0], isNotNull);
      expect(videoBuf.planes[0], isEmpty);
      expect(videoBuf.strideBytes[0], equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVBuffer – top-level envelope
  // ---------------------------------------------------------------------------
  group('MiniAVBuffer', () {
    test('CPU video buffer has correct fields', () {
      final videoBuf = MiniAVVideoBuffer(
        width: 640,
        height: 480,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [640 * 4],
        planes: [Uint8List(640 * 480 * 4)],
      );
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.cpu,
        timestampUs: 1000000,
        data: videoBuf,
        dataSizeBytes: 640 * 480 * 4,
      );
      expect(buf.type, equals(MiniAVBufferType.video));
      expect(buf.contentType, equals(MiniAVBufferContentType.cpu));
      expect(buf.timestampUs, equals(1000000));
      expect(buf.data, same(videoBuf));
      expect(buf.dataSizeBytes, equals(640 * 480 * 4));
    });

    test('nativeFence defaults to all-sentinel values', () {
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.cpu,
        timestampUs: 0,
        data: null,
        dataSizeBytes: 0,
      );
      expect(buf.nativeFence.syncFd, equals(-1));
      expect(buf.nativeFence.d3d11FencePtr, equals(0));
    });

    test('nativeHandle defaults to null for CPU buffers', () {
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.cpu,
        timestampUs: 0,
        data: null,
        dataSizeBytes: 0,
      );
      expect(buf.nativeHandle, isNull);
    });

    test('GPU D3D11 buffer carries nativeHandle and correct contentType', () {
      const fakeHandleAddr = 0xDEADBEEF;
      final buf = MiniAVBuffer(
        type: MiniAVBufferType.video,
        contentType: MiniAVBufferContentType.gpuD3D11Handle,
        timestampUs: 2000000,
        data: null,
        dataSizeBytes: 0,
        nativeHandle: fakeHandleAddr,
        nativeFence: const MiniAVNativeFence(d3d11FencePtr: 0xCAFE),
      );
      expect(buf.contentType, equals(MiniAVBufferContentType.gpuD3D11Handle));
      expect(buf.nativeHandle, equals(fakeHandleAddr));
      expect(buf.nativeFence.d3d11FencePtr, equals(0xCAFE));
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVVideoBuffer plane count (via planes.length)
  // ---------------------------------------------------------------------------
  group('MiniAVVideoBuffer plane count', () {
    test('RGBA32 has 1 plane', () {
      final buf = MiniAVVideoBuffer(
        width: 8,
        height: 8,
        pixelFormat: MiniAVPixelFormat.rgba32,
        strideBytes: [32],
        planes: [Uint8List(256)],
      );
      expect(buf.planes, hasLength(1));
    });

    test('NV12 has 2 planes', () {
      final buf = MiniAVVideoBuffer(
        width: 8,
        height: 8,
        pixelFormat: MiniAVPixelFormat.nv12,
        strideBytes: [8, 8],
        planes: [Uint8List(64), Uint8List(32)],
      );
      expect(buf.planes, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // MiniAVVideoInfo – outputPreference field
  // ---------------------------------------------------------------------------
  group('MiniAVVideoInfo', () {
    test('outputPreference.cpu is accepted', () {
      final info = MiniAVVideoInfo(
        width: 1280,
        height: 720,
        pixelFormat: MiniAVPixelFormat.nv12,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
        outputPreference: MiniAVOutputPreference.cpu,
      );
      expect(info.outputPreference, equals(MiniAVOutputPreference.cpu));
    });

    test('outputPreference.gpu is accepted', () {
      final info = MiniAVVideoInfo(
        width: 1920,
        height: 1080,
        pixelFormat: MiniAVPixelFormat.rgba32,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        outputPreference: MiniAVOutputPreference.gpu,
      );
      expect(info.outputPreference, equals(MiniAVOutputPreference.gpu));
    });
  });
}
