/// Frame-source abstraction: how a frame is delivered to an encoder.
///
/// Backends declare which sources they accept via
/// [MiniAVToolsBackend.acceptedFrameSources]. The facade negotiates: if a
/// backend cannot consume a given source directly, the facade falls back to
/// CPU readback (slow but always works).
library;

import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:minigpu_platform_interface/minigpu_platform_interface.dart'
    show ExternalPixelFormat;

/// Discriminator for [FrameSource] subtypes — used by backends to declare
/// support without runtime type checks.
enum FrameSourceKind {
  cpu,

  /// Pre-converted planar YUV420P (I420) — three tightly-packed u8 planes.
  yuv420pPlanar,
  miniavBufferCpu,
  miniavBufferD3D11,
  miniavBufferMetal,
  miniavBufferDmabuf,
  miniavBufferAHardwareBuffer,
  gpuTexture,
  d3d11Texture,
  cvPixelBuffer,
  dmabuf,

  /// A browser WebCodecs `VideoFrame` — zero-copy path into `VideoEncoder`.
  /// Only constructed on the web platform; native backends never see this kind.
  webVideoFrame,
}

/// Sealed: every frame handed to an encoder is one of the variants below.
///
/// Use the named factories — never extend this class outside the package.
sealed class FrameSource {
  const FrameSource();

  /// What kind this is, for backend capability checks.
  FrameSourceKind get kind;

  /// Frame width in pixels.
  int get width;

  /// Frame height in pixels.
  int get height;

  /// Pixel format. Backends may need to perform color-space conversion.
  MiniAVPixelFormat get pixelFormat;

  /// Presentation timestamp in microseconds. May be 0 if unknown.
  int get timestampUs;

  /// CPU bytes (always supported, may incur upload to GPU encoder).
  factory FrameSource.cpu({
    required Uint8List bytes,
    required MiniAVPixelFormat pixelFormat,
    required int width,
    required int height,
    List<int>? strideBytes,
    int timestampUs,
  }) = CpuFrameSource;

  /// Pre-converted planar YUV420P (I420): a full-resolution [yPlane] plus
  /// 2×2-subsampled [uPlane]/[vPlane]. Lets a GPU color-conversion step feed
  /// planes straight to a YUV420P encoder with no further conversion. Each
  /// plane must be tightly packed (Y: width*height, U/V: (width/2)*(height/2)).
  factory FrameSource.yuv420p({
    required Uint8List yPlane,
    required Uint8List uPlane,
    required Uint8List vPlane,
    required int width,
    required int height,
    int timestampUs,
  }) = Yuv420pFrameSource;

  /// A miniav-produced buffer — backend extracts native handle for zero-copy
  /// when possible.
  factory FrameSource.miniavBuffer(MiniAVBuffer buffer) = MiniAVBufferSource;

  /// A minigpu video texture (e.g. from `gpu.importVideoFrame`).
  factory FrameSource.gpuTexture({
    required Object platformVideoTexture, // PlatformVideoTexture
    required int width,
    required int height,
    required ExternalPixelFormat externalPixelFormat,
    int timestampUs,
  }) = GpuTextureFrameSource;

  /// Raw D3D11 texture pointer (Windows escape hatch).
  factory FrameSource.d3d11Texture({
    required int texturePtr,
    required int width,
    required int height,
    required MiniAVPixelFormat pixelFormat,
    int subresourceIndex,
    MiniAVNativeFence fence,
    int timestampUs,
  }) = D3D11TextureFrameSource;

  /// Raw CVPixelBuffer (macOS / iOS escape hatch).
  factory FrameSource.cvPixelBuffer({
    required int cvPixelBufferPtr,
    required int width,
    required int height,
    required MiniAVPixelFormat pixelFormat,
    int timestampUs,
  }) = CvPixelBufferFrameSource;

  /// Raw Linux dmabuf (escape hatch).
  factory FrameSource.dmabuf({
    required List<int> fds,
    required List<int> strides,
    required List<int> offsets,
    required int modifier,
    required int width,
    required int height,
    required MiniAVPixelFormat pixelFormat,
    int timestampUs,
  }) = DmabufFrameSource;

  /// A browser WebCodecs `VideoFrame` — zero-copy path into `VideoEncoder`.
  ///
  /// [videoFrame] is the opaque JS `VideoFrame` object (typed as `Object` to
  /// avoid a `dart:js_interop` dependency in the platform-interface package).
  /// On web, cast it to `web.VideoFrame` to call WebCodecs APIs.
  ///
  /// The caller is responsible for closing the `VideoFrame` after encoding.
  factory FrameSource.webVideoFrame({
    required Object videoFrame,
    required int width,
    required int height,
    required MiniAVPixelFormat pixelFormat,
    int timestampUs,
  }) = WebVideoFrameSource;
}

class CpuFrameSource extends FrameSource {
  @override
  final int width;
  @override
  final int height;
  @override
  final MiniAVPixelFormat pixelFormat;
  @override
  final int timestampUs;

  final Uint8List bytes;
  final List<int>? strideBytes;

  const CpuFrameSource({
    required this.bytes,
    required this.pixelFormat,
    required this.width,
    required this.height,
    this.strideBytes,
    this.timestampUs = 0,
  });

  @override
  FrameSourceKind get kind => FrameSourceKind.cpu;
}

/// Pre-converted planar YUV420P (I420) frame: three tightly-packed u8 planes.
class Yuv420pFrameSource extends FrameSource {
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  @override
  final int width;
  @override
  final int height;
  @override
  final int timestampUs;

  const Yuv420pFrameSource({
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    this.timestampUs = 0,
  });

  @override
  MiniAVPixelFormat get pixelFormat => MiniAVPixelFormat.i420;

  @override
  FrameSourceKind get kind => FrameSourceKind.yuv420pPlanar;
}

class MiniAVBufferSource extends FrameSource {
  final MiniAVBuffer buffer;

  const MiniAVBufferSource(this.buffer);

  MiniAVVideoBuffer get _video => buffer.data as MiniAVVideoBuffer;

  @override
  int get width => _video.width;
  @override
  int get height => _video.height;
  @override
  MiniAVPixelFormat get pixelFormat => _video.pixelFormat;
  @override
  int get timestampUs => buffer.timestampUs;

  @override
  FrameSourceKind get kind {
    switch (buffer.contentType) {
      case MiniAVBufferContentType.cpu:
        return FrameSourceKind.miniavBufferCpu;
      case MiniAVBufferContentType.gpuD3D11Handle:
        return FrameSourceKind.miniavBufferD3D11;
      case MiniAVBufferContentType.gpuMetalTexture:
        return FrameSourceKind.miniavBufferMetal;
      case MiniAVBufferContentType.gpuDmabufFd:
        return FrameSourceKind.miniavBufferDmabuf;
      case MiniAVBufferContentType.gpuAHardwareBuffer:
        return FrameSourceKind.miniavBufferAHardwareBuffer;
    }
  }
}

class GpuTextureFrameSource extends FrameSource {
  final Object platformVideoTexture; // typed as PlatformVideoTexture in users
  @override
  final int width;
  @override
  final int height;
  final ExternalPixelFormat externalPixelFormat;
  @override
  final int timestampUs;

  const GpuTextureFrameSource({
    required this.platformVideoTexture,
    required this.width,
    required this.height,
    required this.externalPixelFormat,
    this.timestampUs = 0,
  });

  @override
  MiniAVPixelFormat get pixelFormat {
    switch (externalPixelFormat) {
      case ExternalPixelFormat.rgba32:
        return MiniAVPixelFormat.rgba32;
      case ExternalPixelFormat.bgra32:
        return MiniAVPixelFormat.bgra32;
      case ExternalPixelFormat.nv12:
        return MiniAVPixelFormat.nv12;
      case ExternalPixelFormat.gray8:
        return MiniAVPixelFormat.gray8;
      default:
        return MiniAVPixelFormat.unknown;
    }
  }

  @override
  FrameSourceKind get kind => FrameSourceKind.gpuTexture;
}

class D3D11TextureFrameSource extends FrameSource {
  final int texturePtr;
  @override
  final int width;
  @override
  final int height;
  @override
  final MiniAVPixelFormat pixelFormat;
  final int subresourceIndex;
  final MiniAVNativeFence fence;
  @override
  final int timestampUs;

  const D3D11TextureFrameSource({
    required this.texturePtr,
    required this.width,
    required this.height,
    required this.pixelFormat,
    this.subresourceIndex = 0,
    this.fence = const MiniAVNativeFence(),
    this.timestampUs = 0,
  });

  @override
  FrameSourceKind get kind => FrameSourceKind.d3d11Texture;
}

class CvPixelBufferFrameSource extends FrameSource {
  final int cvPixelBufferPtr;
  @override
  final int width;
  @override
  final int height;
  @override
  final MiniAVPixelFormat pixelFormat;
  @override
  final int timestampUs;

  const CvPixelBufferFrameSource({
    required this.cvPixelBufferPtr,
    required this.width,
    required this.height,
    required this.pixelFormat,
    this.timestampUs = 0,
  });

  @override
  FrameSourceKind get kind => FrameSourceKind.cvPixelBuffer;
}

class DmabufFrameSource extends FrameSource {
  final List<int> fds;
  final List<int> strides;
  final List<int> offsets;
  final int modifier;
  @override
  final int width;
  @override
  final int height;
  @override
  final MiniAVPixelFormat pixelFormat;
  @override
  final int timestampUs;

  const DmabufFrameSource({
    required this.fds,
    required this.strides,
    required this.offsets,
    required this.modifier,
    required this.width,
    required this.height,
    required this.pixelFormat,
    this.timestampUs = 0,
  });

  @override
  FrameSourceKind get kind => FrameSourceKind.dmabuf;
}

/// A browser WebCodecs `VideoFrame` wrapped as a [FrameSource].
///
/// [videoFrame] is an opaque reference to the JS `VideoFrame` object.
/// On web, [WebCodecsVideoEncoder] casts this back to `web.VideoFrame`.
/// The caller owns the `VideoFrame` and must call `.close()` on it after
/// encoding completes.
class WebVideoFrameSource extends FrameSource {
  /// Opaque reference to the JS `VideoFrame`.
  final Object videoFrame;

  @override
  final int width;
  @override
  final int height;
  @override
  final MiniAVPixelFormat pixelFormat;
  @override
  final int timestampUs;

  const WebVideoFrameSource({
    required this.videoFrame,
    required this.width,
    required this.height,
    required this.pixelFormat,
    this.timestampUs = 0,
  });

  @override
  FrameSourceKind get kind => FrameSourceKind.webVideoFrame;
}
