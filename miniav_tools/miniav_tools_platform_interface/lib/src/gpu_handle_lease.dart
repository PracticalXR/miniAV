/// Refcounted ownership of a decoded frame's GPU resource — the formal contract
/// for "don't recycle this texture slot until every consumer is done".
///
/// A hardware decoder hands back a frame whose [DecodedFrame.gpuHandle] points
/// at a pool-slot surface (a D3D11 texture, an `IOSurface`, a DMABUF, an
/// `AHardwareBuffer`, …). That slot MUST stay valid until the present device —
/// and any intermediate GPU step (a colour-convert pass, a cross-isolate hold)
/// — is finished reading it; recycling it early corrupts the frame or faults
/// the GPU. Today the Media Foundation path enforces this with bespoke code (a
/// worker isolate holds each texture in a map until the main isolate fires a
/// release). This primitive makes that pattern EXPLICIT, REFCOUNTED, and REUSED
/// across HW backends (MF now; NVDEC / VideoToolbox / VAAPI / MediaCodec later)
/// instead of each re-inventing — and re-breaking — it.
///
/// Ownership rules:
///   - A lease starts with one hold (the decoder's own reference to the frame).
///   - Each additional consumer calls [retain] before using [gpuHandle], and
///     [release] when done.
///   - When the LAST hold is released, `onLastRelease` fires exactly once — that
///     is where the backend recycles the pool slot / frees the surface / sends
///     the cross-isolate release message.
///   - Double-release and retain-after-release are logic errors ([StateError]).
///
/// This object lives within a single isolate; the cross-isolate case (worker
/// holds, main releases) is modelled by giving the main isolate's frame a lease
/// whose `onLastRelease` sends the release message to the worker.
library;

class GpuHandleLease {
  /// Create a lease with a single initial hold. [onLastRelease] runs exactly
  /// once, when the hold count drops to zero.
  GpuHandleLease(this._onLastRelease) : _count = 1;

  final void Function() _onLastRelease;
  int _count;

  /// Current number of holders. `0` once fully released.
  int get holdCount => _count;

  /// True once every hold has been released (`onLastRelease` has fired).
  bool get isReleased => _count <= 0;

  /// Add a holder. Returns `this` for chaining. Throws if already released.
  GpuHandleLease retain() {
    if (_count <= 0) {
      throw StateError('GpuHandleLease.retain() after the lease was released');
    }
    _count++;
    return this;
  }

  /// Drop a holder. When the last holder is dropped, `onLastRelease` fires
  /// exactly once. Throws on release of an already-freed lease.
  void release() {
    if (_count <= 0) {
      throw StateError('GpuHandleLease.release() of an already-freed lease');
    }
    _count--;
    if (_count == 0) {
      _onLastRelease();
    }
  }
}
