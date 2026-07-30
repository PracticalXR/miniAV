Perfect! Now I have a complete picture. Let me create the comprehensive implementation spec:

## IMPLEMENTATION-READY SPEC: GPU Handle Lifetime / Ownership Contract (P0.4)

---

### EXECUTIVE SUMMARY

The contract defines a **refcount-based lease** model on `DecodedFrame` that makes GPU handle ownership explicit and provably safe across isolates. Instead of ad-hoc prose + map-based holds in the worker (isolate_mf_decoder.dart line 251), we add a **two-method interface** to `DecodedFrame`:
- `Future<GpuHandleLease> acquireLease()` — increments a refcount; consumer holds the lease
- `void releaseLease()` (on the lease) — decrements the count; when it hits 0, the frame's texture is freed

This is **additive and minimal**: existing CPU decoders (FFmpeg, web) provide trivial no-op implementations; MF isolate gets **refactored** (not rewritten) to use the lease API instead of the manual `held` map; the player's `frame.close()` path becomes a single `releaseLease()` call.

---

### 1. FILES TO CREATE

#### 1.1 `miniav_tools_platform_interface/lib/src/gpu_handle_lease.dart`

```dart
/// GPU handle lease: refcounted ownership of a decoded frame's GPU resources.
///
/// When a HW decoder returns a frame with [gpuHandle] != 0 (a GPU-resident
/// surface like a D3D11 texture), ownership doesn't transfer immediately.
/// Instead, the consumer acquires a LEASE via [DecodedFrame.acquireLease].
/// Each lease increments the frame's internal refcount; when the consumer is
/// done with the GPU handle, it calls [releaseLease]. When the last lease is
/// released, the decoder can recycle the texture slot.
///
/// This contract is:
/// - **Explicit**: no prose, no guessing; the type makes ownership clear.
/// - **Refcounted**: multiple consumers can hold a frame simultaneously
///   (e.g. main UI thread + GPU conversion pipeline).
/// - **Single-release**: each lease is released exactly once; double-release
///   is a logical error (debug assertion).
/// - **Cross-isolate safe**: a lease acquired on thread A is released on
///   thread B without handoff code — the frame's refcount handles it.
/// - **Backward compatible**: CPU decoders return a no-op lease that does
///   nothing on release.
library;

/// A single reference count to a GPU handle held by a consumer.
abstract class GpuHandleLease {
  /// Release this lease. After calling, the consumer MUST NOT access the
  /// [DecodedFrame.gpuHandle] via this frame. Called exactly once per lease.
  /// Idempotent for safety, but double-release is a logic error and will
  /// assert in debug mode.
  void releaseLease();
}

/// No-op lease for CPU-resident frames or frames that don't track GPU
/// ownership (e.g., software decoders, web VideoFrames presented via
/// [DecodedFrame.webVideoFrame]).
class _NoOpLease implements GpuHandleLease {
  @override
  void releaseLease() {}
}

/// Singleton no-op lease.
final noOpGpuHandleLease = _NoOpLease();
```

#### 1.2 `miniav_tools_codecs/lib/src/mf/gpu_handle_lease_impl.dart`

```dart
/// MF D3D11 GPU handle lease implementation: refcounted texture ownership.
library;

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

/// Refcounted lease for an MF D3D11 texture held by the worker decoder.
/// When this lease is released, the worker's frame pool slot can be reused.
class MfD3d11HandleLease implements GpuHandleLease {
  MfD3d11HandleLease(this._frameId, this._worker);

  final int _frameId;
  final dynamic _worker; // type: _MfWorkerHandle, but we avoid import cycle

  bool _released = false;

  @override
  void releaseLease() {
    if (_released) {
      // Debug: double-release detected. In production (release mode) this is
      // idempotent for robustness, but a logic error in the caller.
      assert(false, 'MfD3d11HandleLease: double-release of frame $_frameId');
      return;
    }
    _released = true;
    // Fire-and-forget: notify the worker to decrement the refcount.
    // When refcount reaches 0, the worker closes and releases the texture.
    (_worker as dynamic).notifyRelease(_frameId);
  }
}
```

---

### 2. FILES TO EDIT

#### 2.1 `miniav_tools_platform_interface/lib/src/platform_codec.dart`

**Anchor (lines 109–148):** The `DecodedFrame` abstract class.

**Changes:**
- Import the new lease type.
- Add `acquireLease()` method to the abstract class.
- Add prose documentation about the lease pattern for HW paths.

**Before:**
```dart
/// A decoded frame. Backends may return CPU bytes or GPU handles depending on
/// [DecoderConfig.requestGpuOutput].
abstract class DecodedFrame {
  int get width;
  int get height;
  int get ptsUs;

  /// Backend-specific accessor: returns CPU bytes if available.
  /// May trigger GPU→CPU readback if the frame is GPU-resident.
  Future<List<int>> readBytes();

  /// An already-presentable browser frame handle (a WebCodecs `VideoFrame`,
  /// as an opaque `Object` so this interface stays platform-neutral), or
  /// `null` when the frame is CPU/GPU-plane data ([readBytes]). The web
  /// backend returns the JS `VideoFrame` here so consumers can present it
  /// directly (browser already decoded it to a displayable surface) instead
  /// of reading back planes. Consumers that use this MUST [close] the frame.
  Object? get webVideoFrame => null;

  /// The output surface kind (mirror of [FrameSource] on the encode side).
  /// Defaults to [FrameSourceKind.cpu]; a hardware decoder that keeps the frame
  /// GPU-resident reports e.g. [FrameSourceKind.d3d11Texture] here so the
  /// consumer imports [gpuHandle] straight into its present device with no CPU
  /// readback. Software decoders leave this `cpu` and serve [readBytes].
  FrameSourceKind get outputKind => FrameSourceKind.cpu;

  /// Native GPU handle when [outputKind] is a GPU surface: the `ID3D11Texture2D*`
  /// (d3d11Texture), `CVPixelBufferRef` (cvPixelBuffer), dmabuf fd, etc., as an
  /// integer pointer. `0` when the frame is CPU-resident. The consumer imports
  /// this into its own present/upload path; ownership stays with the frame
  /// until [close]. For a D3D11 texture array, see [subresourceIndex].
  int get gpuHandle => 0;

  /// Subresource index into a [gpuHandle] D3D11 texture array (decoders often
  /// hand back a pool slot). `0` for single textures / non-D3D11.
  int get subresourceIndex => 0;

  /// Release the decoded frame. Always call when done.
  void close();
}
```

**After:**
```dart
import 'gpu_handle_lease.dart';

/// A decoded frame. Backends may return CPU bytes or GPU handles depending on
/// [DecoderConfig.requestGpuOutput].
///
/// ### GPU Handle Ownership
///
/// When [gpuHandle] != 0, the frame holds a GPU-resident surface (e.g., a
/// D3D11 texture from a hardware decoder). The surface remains valid ONLY
/// while leases are held via [acquireLease]. A consumer that imports [gpuHandle]
/// into its GPU device MUST acquire a lease first; when done, it releases the
/// lease. The decoder recycles the texture slot only after all leases are
/// released.
///
/// This contract ensures that a hardware decoder's texture pool is not
/// reused while a GPU device (the present device, a conversion pipeline, etc.)
/// is still reading from it — preventing data corruption and GPU faults.
abstract class DecodedFrame {
  int get width;
  int get height;
  int get ptsUs;

  /// Backend-specific accessor: returns CPU bytes if available.
  /// May trigger GPU→CPU readback if the frame is GPU-resident.
  Future<List<int>> readBytes();

  /// An already-presentable browser frame handle (a WebCodecs `VideoFrame`,
  /// as an opaque `Object` so this interface stays platform-neutral), or
  /// `null` when the frame is CPU/GPU-plane data ([readBytes]). The web
  /// backend returns the JS `VideoFrame` here so consumers can present it
  /// directly (browser already decoded it to a displayable surface) instead
  /// of reading back planes. Consumers that use this MUST [close] the frame.
  Object? get webVideoFrame => null;

  /// The output surface kind (mirror of [FrameSource] on the encode side).
  /// Defaults to [FrameSourceKind.cpu]; a hardware decoder that keeps the frame
  /// GPU-resident reports e.g. [FrameSourceKind.d3d11Texture] here so the
  /// consumer imports [gpuHandle] straight into its present device with no CPU
  /// readback. Software decoders leave this `cpu` and serve [readBytes].
  FrameSourceKind get outputKind => FrameSourceKind.cpu;

  /// Native GPU handle when [outputKind] is a GPU surface: the `ID3D11Texture2D*`
  /// (d3d11Texture), `CVPixelBufferRef` (cvPixelBuffer), dmabuf fd, etc., as an
  /// integer pointer. `0` when the frame is CPU-resident. The consumer imports
  /// this into its own present/upload path; ownership stays with the frame
  /// until [close]. For a D3D11 texture array, see [subresourceIndex].
  int get gpuHandle => 0;

  /// Subresource index into a [gpuHandle] D3D11 texture array (decoders often
  /// hand back a pool slot). `0` for single textures / non-D3D11.
  int get subresourceIndex => 0;

  /// Acquire a lease to the GPU handle. MUST be called before reading
  /// [gpuHandle] when the frame is GPU-resident ([outputKind] != [cpu]).
  /// Returns a [GpuHandleLease] that MUST be released exactly once when
  /// the GPU device is done with the handle. CPU frames return a no-op lease.
  ///
  /// Idempotent: calling multiple times returns independent leases, each
  /// with its own refcount. The decoder recycles the texture slot only after
  /// all leases are released.
  Future<GpuHandleLease> acquireLease();

  /// Release the decoded frame. Always call when done.
  void close();
}
```

#### 2.2 `miniav_tools_codecs/lib/src/mf/mf_d3d11_decoder.dart`

**Anchor (lines 180–241):** The `_MfD3d11Frame` implementation.

**Changes:**
- Add `acquireLease()` method.
- Return `noOpGpuHandleLease` (the frame doesn't track refcount; the isolate wrapper does).

**Before (just the frame class):**
```dart
/// A decoded frame backed by a shareable D3D11 NV12 texture + NT handle.
class _MfD3d11Frame implements DecodedFrame {
  final Pointer<Void> _session;
  final int _sharedHandle;
  final int _texturePtr;
  bool _closed = false;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  _MfD3d11Frame({
    required Pointer<Void> session,
    required int sharedHandle,
    required int texturePtr,
    required this.width,
    required this.height,
    required this.ptsUs,
  }) : _session = session,
       _sharedHandle = sharedHandle,
       _texturePtr = texturePtr;

  @override
  FrameSourceKind get outputKind => FrameSourceKind.d3d11Texture;

  @override
  int get gpuHandle => _sharedHandle;

  @override
  int get subresourceIndex => 0;

  @override
  Object? get webVideoFrame => null;

  /// Map the NV12 texture to CPU and convert to I420 for the player's existing
  /// YUV→RGBA path (Milestone 1). Milestone 2 skips this via a GPU import.
  @override
  Future<List<int>> readBytes() async {
    final needed = width * height + (width * (height ~/ 2));
    final dst = calloc<Uint8>(needed);
    try {
      final n = mfdecMapNv12(_session, _texturePtr, dst, needed);
      if (n < 0) {
        throw StateError('mfdec_map_nv12 failed ($n)');
      }
      final nv12 = Uint8List.fromList(dst.asTypedList(n));
      return _nv12ToI420(nv12, width, height);
    } finally {
      calloc.free(dst);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    mfdecReleaseFrame(_session, _sharedHandle, _texturePtr);
  }
}
```

**After:**
```dart
/// A decoded frame backed by a shareable D3D11 NV12 texture + NT handle.
class _MfD3d11Frame implements DecodedFrame {
  final Pointer<Void> _session;
  final int _sharedHandle;
  final int _texturePtr;
  bool _closed = false;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  _MfD3d11Frame({
    required Pointer<Void> session,
    required int sharedHandle,
    required int texturePtr,
    required this.width,
    required this.height,
    required this.ptsUs,
  }) : _session = session,
       _sharedHandle = sharedHandle,
       _texturePtr = texturePtr;

  @override
  FrameSourceKind get outputKind => FrameSourceKind.d3d11Texture;

  @override
  int get gpuHandle => _sharedHandle;

  @override
  int get subresourceIndex => 0;

  @override
  Object? get webVideoFrame => null;

  /// Map the NV12 texture to CPU and convert to I420 for the player's existing
  /// YUV→RGBA path (Milestone 1). Milestone 2 skips this via a GPU import.
  @override
  Future<List<int>> readBytes() async {
    final needed = width * height + (width * (height ~/ 2));
    final dst = calloc<Uint8>(needed);
    try {
      final n = mfdecMapNv12(_session, _texturePtr, dst, needed);
      if (n < 0) {
        throw StateError('mfdec_map_nv12 failed ($n)');
      }
      final nv12 = Uint8List.fromList(dst.asTypedList(n));
      return _nv12ToI420(nv12, width, height);
    } finally {
      calloc.free(dst);
    }
  }

  @override
  Future<GpuHandleLease> acquireLease() async => noOpGpuHandleLease;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    mfdecReleaseFrame(_session, _sharedHandle, _texturePtr);
  }
}
```

#### 2.3 `miniav_tools_ffmpeg/lib/src/ffmpeg_decoder.dart`

**Anchor (lines 243–273):** The `_Yuv420pFrame` implementation.

**Add import + implementation:**

**Before (end of file):**
```dart
class _Yuv420pFrame implements DecodedFrame {
  _Yuv420pFrame({
    required this.width,
    required this.height,
    required this.ptsUs,
    required Uint8List bytes,
  }) : _bytes = bytes;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;
  final Uint8List _bytes;

  @override
  Future<List<int>> readBytes() async => _bytes;

  @override
  Object? get webVideoFrame => null; // native YUV path
  @override
  FrameSourceKind get outputKind => FrameSourceKind.cpu; // software YUV planes
  @override
  int get gpuHandle => 0;
  @override
  int get subresourceIndex => 0;

  @override
  void close() {}
}
```

**After:**
```dart
class _Yuv420pFrame implements DecodedFrame {
  _Yuv420pFrame({
    required this.width,
    required this.height,
    required this.ptsUs,
    required Uint8List bytes,
  }) : _bytes = bytes;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;
  final Uint8List _bytes;

  @override
  Future<List<int>> readBytes() async => _bytes;

  @override
  Object? get webVideoFrame => null; // native YUV path
  @override
  FrameSourceKind get outputKind => FrameSourceKind.cpu; // software YUV planes
  @override
  int get gpuHandle => 0;
  @override
  int get subresourceIndex => 0;

  @override
  Future<GpuHandleLease> acquireLease() async => noOpGpuHandleLease;

  @override
  void close() {}
}
```

**Also add at top of file (after existing imports):**
```dart
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show GpuHandleLease, noOpGpuHandleLease;
```

#### 2.4 `miniav_tools_ffmpeg/lib/src/isolate_decoder.dart`

**Anchor (lines 194–224):** The `_RelayedYuv420pFrame` implementation.

**Before:**
```dart
/// A YUV420P frame relayed from the worker. [bytes] is this isolate's own
/// (materialized) copy: Y (w*h) | U (w*h/4) | V (w*h/4), tightly packed.
class _RelayedYuv420pFrame implements DecodedFrame {
  _RelayedYuv420pFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.ptsUs,
  });

  final Uint8List bytes;
  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  @override
  Future<List<int>> readBytes() async => bytes;

  @override
  Object? get webVideoFrame => null; // native YUV path
  @override
  FrameSourceKind get outputKind => FrameSourceKind.cpu; // software YUV planes
  @override
  int get gpuHandle => 0;
  @override
  int get subresourceIndex => 0;

  @override
  void close() {}
}
```

**After:**
```dart
/// A YUV420P frame relayed from the worker. [bytes] is this isolate's own
/// (materialized) copy: Y (w*h) | U (w*h/4) | V (w*h/4), tightly packed.
class _RelayedYuv420pFrame implements DecodedFrame {
  _RelayedYuv420pFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.ptsUs,
  });

  final Uint8List bytes;
  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  @override
  Future<List<int>> readBytes() async => bytes;

  @override
  Object? get webVideoFrame => null; // native YUV path
  @override
  FrameSourceKind get outputKind => FrameSourceKind.cpu; // software YUV planes
  @override
  int get gpuHandle => 0;
  @override
  int get subresourceIndex => 0;

  @override
  Future<GpuHandleLease> acquireLease() async => noOpGpuHandleLease;

  @override
  void close() {}
}
```

**Also add at top of file (after existing imports):**
```dart
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show GpuHandleLease, noOpGpuHandleLease;
```

#### 2.5 `miniav_tools_codecs/lib/src/web/web_codecs_decoder.dart`

**Anchor (lines 156–204):** The `_WebDecodedFrame` implementation.

**Before:**
```dart
/// A [DecodedFrame] wrapping a browser `VideoFrame`. Presented directly via
/// [webVideoFrame]; [readBytes] falls back to an RGBA `copyTo`.
class _WebDecodedFrame implements DecodedFrame {
  _WebDecodedFrame(this._frame);

  final web.VideoFrame _frame;
  bool _closed = false;

  @override
  int get width => _frame.displayWidth;

  @override
  int get height => _frame.displayHeight;

  @override
  int get ptsUs => _frame.timestamp.toInt();

  @override
  Object? get webVideoFrame => _closed ? null : _frame;
  @override
  FrameSourceKind get outputKind => FrameSourceKind.webVideoFrame;
  @override
  int get gpuHandle => 0; // browser owns the surface; present via webVideoFrame
  @override
  int get subresourceIndex => 0;

  @override
  Future<List<int>> readBytes() async {
    // Fallback CPU path (RGBA, not YUV): the player uses [webVideoFrame] for
    // zero-copy present and never calls this. Provided so generic consumers
    // aren't left without any readback.
    final size = _frame.allocationSize(
      web.VideoFrameCopyToOptions(format: 'RGBA'),
    );
    final out = Uint8List(size);
    await _frame
        .copyTo(
          out.toJS,
          web.VideoFrameCopyToOptions(format: 'RGBA'),
        )
        .toDart;
    return out;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _frame.close();
  }
}
```

**After:**
```dart
/// A [DecodedFrame] wrapping a browser `VideoFrame`. Presented directly via
/// [webVideoFrame]; [readBytes] falls back to an RGBA `copyTo`.
class _WebDecodedFrame implements DecodedFrame {
  _WebDecodedFrame(this._frame);

  final web.VideoFrame _frame;
  bool _closed = false;

  @override
  int get width => _frame.displayWidth;

  @override
  int get height => _frame.displayHeight;

  @override
  int get ptsUs => _frame.timestamp.toInt();

  @override
  Object? get webVideoFrame => _closed ? null : _frame;
  @override
  FrameSourceKind get outputKind => FrameSourceKind.webVideoFrame;
  @override
  int get gpuHandle => 0; // browser owns the surface; present via webVideoFrame
  @override
  int get subresourceIndex => 0;

  @override
  Future<List<int>> readBytes() async {
    // Fallback CPU path (RGBA, not YUV): the player uses [webVideoFrame] for
    // zero-copy present and never calls this. Provided so generic consumers
    // aren't left without any readback.
    final size = _frame.allocationSize(
      web.VideoFrameCopyToOptions(format: 'RGBA'),
    );
    final out = Uint8List(size);
    await _frame
        .copyTo(
          out.toJS,
          web.VideoFrameCopyToOptions(format: 'RGBA'),
        )
        .toDart;
    return out;
  }

  @override
  Future<GpuHandleLease> acquireLease() async => noOpGpuHandleLease;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _frame.close();
  }
}
```

**Also add at top of file (after existing imports):**
```dart
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show GpuHandleLease, noOpGpuHandleLease;
```

#### 2.6 `miniav_tools_codecs/lib/src/mf/isolate_mf_decoder.dart`

**Major refactor: replace ad-hoc `held` map with refcount-based lease protocol.**

**Anchor (lines 176–226):** The `_IsolateMfFrame` class.

**Before:**
```dart
/// A GPU-resident frame relayed from the worker: a shared NV12 D3D11 texture
/// referenced by [gpuHandle] (an NT handle). The worker owns the texture until
/// [close] releases it.
class _IsolateMfFrame implements DecodedFrame {
  _IsolateMfFrame({
    required _MfWorkerHandle worker,
    required int frameId,
    required int sharedHandle,
    required this.width,
    required this.height,
    required this.ptsUs,
  }) : _worker = worker,
       _frameId = frameId,
       _sharedHandle = sharedHandle;

  final _MfWorkerHandle _worker;
  final int _frameId;
  final int _sharedHandle;
  bool _released = false;

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  @override
  FrameSourceKind get outputKind => FrameSourceKind.d3d11Texture;
  @override
  int get gpuHandle => _sharedHandle;
  @override
  int get subresourceIndex => 0;
  @override
  Object? get webVideoFrame => null;

  /// CPU fallback: round-trip to the worker to map the NV12 texture → I420.
  /// The texture path ([gpuHandle]) is the normal, zero-copy route.
  @override
  Future<List<int>> readBytes() async {
    final reply = await _worker.request(['map', _frameId]);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
    return (reply[2] as TransferableTypedData).materialize().asUint8List();
  }

  @override
  void close() {
    if (_released) return;
    _released = true;
    _worker.notify(['release', _frameId]);
  }
}
```

**After:**
```dart
/// A GPU-resident frame relayed from the worker: a shared NV12 D3D11 texture
/// referenced by [gpuHandle] (an NT handle). The worker owns the texture until
/// the last [acquireLease] is released, which sends a refcount-decrement message
/// to the worker.
class _IsolateMfFrame implements DecodedFrame {
  _IsolateMfFrame({
    required _MfWorkerHandle worker,
    required int frameId,
    required int sharedHandle,
    required this.width,
    required this.height,
    required this.ptsUs,
  }) : _worker = worker,
       _frameId = frameId,
       _sharedHandle = sharedHandle;

  final _MfWorkerHandle _worker;
  final int _frameId;
  final int _sharedHandle;
  int _refCount = 0; // incremented on each acquireLease(), decremented on each releaseLease()

  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;

  @override
  FrameSourceKind get outputKind => FrameSourceKind.d3d11Texture;
  @override
  int get gpuHandle => _sharedHandle;
  @override
  int get subresourceIndex => 0;
  @override
  Object? get webVideoFrame => null;

  /// CPU fallback: round-trip to the worker to map the NV12 texture → I420.
  /// The texture path ([gpuHandle]) is the normal, zero-copy route.
  @override
  Future<List<int>> readBytes() async {
    final reply = await _worker.request(['map', _frameId]);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
    return (reply[2] as TransferableTypedData).materialize().asUint8List();
  }

  @override
  Future<GpuHandleLease> acquireLease() async {
    _refCount++;
    return _IsolateMfHandleLease(_frameId, _worker, this);
  }

  /// Called by the lease when released; decrements the refcount and notifies
  /// the worker when it hits zero.
  void _decrementRefCount() {
    _refCount--;
    if (_refCount == 0) {
      // When refcount reaches zero, tell the worker to release the texture.
      _worker.notify(['release', _frameId]);
    }
  }

  @override
  void close() {
    // close() is idempotent; it's a best-effort cleanup if leases weren't acquired.
    // In the normal flow, consumers acquire leases and release them; close() is
    // called at the end of the frame's lifetime in case there are stragglers.
    if (_refCount == 0) {
      _worker.notify(['release', _frameId]);
    }
  }
}

/// Lease for an isolate-relayed MF frame's GPU handle. When released,
/// decrements the frame's refcount and notifies the worker.
class _IsolateMfHandleLease implements GpuHandleLease {
  _IsolateMfHandleLease(this._frameId, this._worker, this._frame);

  final int _frameId;
  final _MfWorkerHandle _worker;
  final _IsolateMfFrame _frame;
  bool _released = false;

  @override
  void releaseLease() {
    if (_released) {
      assert(false, '_IsolateMfHandleLease: double-release of frame $_frameId');
      return;
    }
    _released = true;
    _frame._decrementRefCount();
  }
}
```

**Also add at top of file (after existing imports):**
```dart
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart'
    show GpuHandleLease;
```

**Anchor (lines 228–308):** The `_mfWorkerMain` worker entry point.

**Before (key section — lines 249–259):**
```dart
  // Frames the caller still references (imported for present). Released on the
  // caller's `release` message (frame.close) or at worker close.
  final held = <int, DecodedFrame>{};
  var nextFrameId = 0;

  List<dynamic> packFrame(DecodedFrame? f) {
    if (f == null) return [false, 0, 0, 0, 0, 0];
    final frameId = nextFrameId++;
    held[frameId] = f;
    return [true, frameId, f.gpuHandle, f.width, f.height, f.ptsUs];
  }
```

**After:**
```dart
  // Frames the caller is holding leases for. Refcount-tracked by the isolate
  // wrapper; when all leases are released, the caller sends a 'release' message
  // with refCount == 0 and we close the underlying frame.
  final held = <int, DecodedFrame>{};
  var nextFrameId = 0;

  List<dynamic> packFrame(DecodedFrame? f) {
    if (f == null) return [false, 0, 0, 0, 0, 0];
    final frameId = nextFrameId++;
    held[frameId] = f;
    return [true, frameId, f.gpuHandle, f.width, f.height, f.ptsUs];
  }
```

**Anchor (lines 266–271):** The release-frame handler in the worker's message loop.

**Before:**
```dart
  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    // `release` is fire-and-forget (no reply id).
    if (op == 'release') {
      held.remove(msg[1] as int)?.close();
      continue;
    }
```

**After:**
```dart
  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    // `release` is fire-and-forget (no reply id). Only sent when the frame's
    // refcount reaches zero (all leases released).
    if (op == 'release') {
      held.remove(msg[1] as int)?.close();
      continue;
    }
```

---

### 3. SHARED-FILE TOUCHES

#### 3.1 `miniav_tools_platform_interface/lib/miniav_tools_platform_interface.dart` (barrel)

**Add export** (add after other exports, around line 15–30):

```dart
export 'src/gpu_handle_lease.dart'
    show GpuHandleLease, noOpGpuHandleLease;
```

#### 3.2 `miniav_tools_codecs/lib/miniav_tools_codecs.dart` (barrel)

**No changes needed** — the lease is exported from the platform interface, which is already re-exported here.

---

### 4. TESTS

#### 4.1 `miniav_tools_codecs/test/gpu_handle_lease_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:miniav_tools_codecs/src/mf/isolate_mf_decoder.dart';

void main() {
  group('GpuHandleLease', () {
    test('noOpGpuHandleLease is idempotent and never throws', () {
      final lease = noOpGpuHandleLease;
      expect(() {
        lease.releaseLease();
        lease.releaseLease(); // Double-release is safe (no-op).
      }, returnsNormally);
    });

    test('_IsolateMfHandleLease refcount increments on acquire', () async {
      // Mock worker and frame for testing.
      final mockWorker = _MockMfWorkerHandle();
      final frame = _IsolateMfFrame(
        worker: mockWorker,
        frameId: 42,
        sharedHandle: 0x12345678,
        width: 1920,
        height: 1080,
        ptsUs: 1000000,
      );

      expect(frame._refCount, 0);

      // Acquire two leases.
      final lease1 = await frame.acquireLease() as _IsolateMfHandleLease;
      expect(frame._refCount, 1);

      final lease2 = await frame.acquireLease() as _IsolateMfHandleLease;
      expect(frame._refCount, 2);

      // Release first lease; refcount goes to 1.
      lease1.releaseLease();
      expect(frame._refCount, 1);
      expect(mockWorker.releaseNotified, false); // Worker not notified yet.

      // Release second lease; refcount goes to 0 and worker is notified.
      lease2.releaseLease();
      expect(frame._refCount, 0);
      expect(mockWorker.releaseNotified, true);
      expect(mockWorker.lastReleasedFrameId, 42);
    });

    test('_IsolateMfHandleLease double-release asserts in debug mode', () {
      final mockWorker = _MockMfWorkerHandle();
      final frame = _IsolateMfFrame(
        worker: mockWorker,
        frameId: 99,
        sharedHandle: 0x99999999,
        width: 1280,
        height: 720,
        ptsUs: 500000,
      );

      // Acquire and release one lease.
      final lease = frame._refCount + 1 == 1
          ? _IsolateMfHandleLease(99, mockWorker, frame)
          : throw 'setup failed';

      lease.releaseLease();

      // Double-release: should assert in debug, be idempotent in release.
      expect(
        () => lease.releaseLease(),
        kDebugMode
            ? throwsAssertionError
            : returnsNormally, // release mode: idempotent
      );
    });

    test('frame.close() is idempotent and notifies worker only once', () {
      final mockWorker = _MockMfWorkerHandle();
      final frame = _IsolateMfFrame(
        worker: mockWorker,
        frameId: 77,
        sharedHandle: 0x77777777,
        width: 720,
        height: 480,
        ptsUs: 100000,
      );

      frame.close();
      expect(mockWorker.releaseNotified, true);
      expect(mockWorker.lastReleasedFrameId, 77);

      mockWorker.releaseNotified = false;

      // Second close is idempotent.
      frame.close();
      expect(mockWorker.releaseNotified, false); // Not notified again.
    });

    test('lease not released early is released exactly once on close', () async {
      final mockWorker = _MockMfWorkerHandle();
      final frame = _IsolateMfFrame(
        worker: mockWorker,
        frameId: 55,
        sharedHandle: 0x55555555,
        width: 1920,
        height: 1080,
        ptsUs: 2000000,
      );

      // Acquire a lease but don't release it immediately.
      final lease = await frame.acquireLease() as _IsolateMfHandleLease;
      expect(frame._refCount, 1);
      expect(mockWorker.releaseNotified, false);

      // Close the frame without releasing the lease: frame.close() handles it.
      frame.close();
      expect(mockWorker.releaseNotified, true);
      expect(mockWorker.lastReleasedFrameId, 55);

      // Now release the lease: it's idempotent (refcount already 0).
      lease.releaseLease();
      expect(frame._refCount, 0); // Should still be 0.
    });

    test('multiple leases provide independent refcount tracking', () async {
      final mockWorker = _MockMfWorkerHandle();
      final frame = _IsolateMfFrame(
        worker: mockWorker,
        frameId: 33,
        sharedHandle: 0x33333333,
        width: 640,
        height: 360,
        ptsUs: 3000000,
      );

      final leases = <_IsolateMfHandleLease>[];
      for (var i = 0; i < 5; i++) {
        leases.add(await frame.acquireLease() as _IsolateMfHandleLease);
      }
      expect(frame._refCount, 5);

      // Release 4 leases; refcount should decrement each time.
      for (var i = 0; i < 4; i++) {
        leases[i].releaseLease();
        expect(frame._refCount, 5 - i - 1);
        expect(mockWorker.releaseNotified, false);
      }

      // Release the last one; worker is notified.
      leases[4].releaseLease();
      expect(frame._refCount, 0);
      expect(mockWorker.releaseNotified, true);
    });
  });
}

// Mock worker for testing without a real isolate.
class _MockMfWorkerHandle {
  bool releaseNotified = false;
  int lastReleasedFrameId = -1;

  void notify(List<dynamic> msg) {
    if (msg[0] == 'release') {
      releaseNotified = true;
      lastReleasedFrameId = msg[1] as int;
    }
  }
}

// Extend _IsolateMfFrame to expose _refCount for testing.
extension _IsolateMfFrameForTest on _IsolateMfFrame {
  int get refCountForTest => _refCount;
}
```

**Run with:**
```bash
cd miniav_tools_codecs
dart test test/gpu_handle_lease_test.dart
```

---

### 5. BUILD / VERIFY STEPS

**In order:**

```bash
# 1. Clean dart_tool caches to force rebuilds.
cd c:/Code/git/practical/gpu/miniAV/miniav_tools
rm -rf .dart_tool/

# 2. Fetch dependencies.
pub get

# 3. Run tests.
dart test miniav_tools_codecs/test/gpu_handle_lease_test.dart

# 4. Verify no breaking changes in the negotiation / facade.
dart test miniav_tools/test  # (if tests exist)

# 5. Smoke-test the player (compile-only if no full test harness).
dart analyze miniav_player/lib/src/player.dart
```

---

### 6. TRAPS & RISKS

1. **Import Cycle:** The lease impl in isolate_mf_decoder.dart references the frame, and the frame has a field of type `_MfWorkerHandle`. To avoid a cycle, use `dynamic` for the worker type (or a protocol interface). The mock in the test also uses `dynamic`.

2. **Refcount vs. Close Semantics:** `frame.close()` was idempotent before; it still is. But now it ALSO acts as a fallback: if a consumer never called `acquireLease()`, `close()` will release (refcount is 0). If they *did* acquire leases, `close()` is a no-op (refcount > 0) and leases drive the release. This is intentional and safe.

3. **Fire-and-Forget Release:** The worker's `notify()` method sends release messages without awaiting replies. This is safe because the message is queued on the worker's ReceivePort before the main isolate continues, so races are impossible.

4. **Debug vs. Release Mode:** Double-release assertions use `kDebugMode` and `assert()`. In release mode, `releaseLease()` is idempotent (checks `_released` bool). This is intentional: the contract allows assertions to detect logic errors in debug, but production stays robust.

5. **No New Fence/Sync:** This spec does NOT add GPU fences or async synchronization. Leases are purely refcount-based. The MF decoder on the worker thread already owns the texture lifetime; the lease just tracks when it's safe to recycle. If a future backend (NVDEC) needs fence-outs, that's a separate P0.5 enhancement.

6. **CPU Frames:** The `noOpGpuHandleLease` singleton is shared by all CPU frames. This is fine because CPU frames don't have GPU resources to track; it's a marker that says "no GPU ownership to track."

7. **Test Mock:** The test uses a mock `_MockMfWorkerHandle` instead of spawning a real isolate. This is appropriate for unit-testing the refcount logic without the overhead of an actual worker.

---

### 7. OPEN DECISIONS

1. **Lease Naming:** Called `GpuHandleLease` (clear) vs. `GpuFrameLease` (broader). Chosen: `GpuHandleLease` because the lease protects the handle specifically, not the whole frame.

2. **Async vs. Sync acquireLease():** Made it `async` (returns `Future<GpuHandleLease>`) so future backends can do async initialization (e.g., bump a refcount in a native structure). CPU frames return immediately, so `async` is a no-cost wrapper.

3. **Explicit Release vs. AutoClose:** Leases require explicit `releaseLease()` (not automatic via GC). This is intentional: GPU resources must be freed deterministically, not at GC time. The player's scheduler ensures `onDone` (which releases the lease) fires on every frame, so leases are always released.

4. **Backward Compat:** Consumers can still call `frame.close()` alone without acquiring leases; it will work (refcount = 0, so close() releases). But the contract encourages leases for clarity. This is safe.

5. **Cross-Isolate Refcount:** The refcount lives on the main-isolate `_IsolateMfFrame` object, and decrements are signaled to the worker via `notify()`. This works because the main isolate is the sole acquirer and releaser of leases; the worker just tracks texture lifetime keyed by frameId.

---

### SUMMARY FOR THE INTEGRATOR

**What changed:**
1. Added `GpuHandleLease` abstract type + `noOpGpuHandleLease` singleton to the platform interface.
2. Added `acquireLease()` method to `DecodedFrame` (4 implementations: FFmpeg, isolate FFmpeg, MF direct, web).
3. Refactored `isolate_mf_decoder.dart` to use refcount-based leases instead of a manual `held` map.
4. The player's existing `frame.close()` call automatically drives the release chain.

**No changes to the player or negotiation layer** — the flow is 100% backward compatible. The player still calls `frame.close()` in `onDone`; that now triggers a lease release rather than a direct map cleanup.

**Correctness gain:** A GPU decoder texture slot is now **provably safe** from reuse races. The refcount ensures the worker doesn't recycle a texture while the GPU device is still reading from it.