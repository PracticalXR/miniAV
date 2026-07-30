/// Cross-backend collaboration context.
///
/// A [BackendContext] is an optional bag of resources the *facade* can hand
/// to a backend's factory methods so the backend can opt into a faster path
/// when those resources are available — e.g. the FFmpeg backend can open a
/// D3D11VA zero-copy encoder when the recorder has already initialised
/// minigpu and shared its `ID3D11Device` here.
///
/// The interface package intentionally does **not** depend on `minigpu` (or
/// any concrete GPU runtime). [sharedGpu] is therefore typed as `Object?` —
/// backends that recognise the runtime can downcast; everyone else ignores it.
///
/// All fields are optional. A `null` context is equivalent to "no shared
/// resources, behave as before" — backends MUST tolerate `context == null`.
library;

/// Optional shared resources passed across backend boundaries.
class BackendContext {
  /// Opaque GPU runtime instance shared by the caller (e.g. a `Minigpu`).
  /// Backends that recognise the type may downcast; others must ignore.
  final Object? sharedGpu;

  /// Native `ID3D11Device*` pointer (as int) the caller wants encoders to
  /// reuse. Zero / unset means "backend may create its own". On non-Windows
  /// platforms this is always 0.
  final int d3d11DeviceHandle;

  /// Caller hint: prefer a zero-copy data path even if it costs init time
  /// or has tighter requirements. Backends still fall back transparently
  /// when the path is unavailable, unless the caller pinned `hwAccel:
  /// required` (in which case failures propagate).
  final bool preferZeroCopy;

  /// Free-form extension slot for forward-compatible additions. Backends
  /// look up keys they recognise; unknown keys are ignored.
  final Map<Object, Object> attachments;

  const BackendContext({
    this.sharedGpu,
    this.d3d11DeviceHandle = 0,
    this.preferZeroCopy = false,
    this.attachments = const {},
  });

  /// Convenience: empty context (equivalent to passing `null`, but lets
  /// callers write `BackendContext.empty` for clarity).
  static const BackendContext empty = BackendContext();

  BackendContext copyWith({
    Object? sharedGpu,
    int? d3d11DeviceHandle,
    bool? preferZeroCopy,
    Map<Object, Object>? attachments,
  }) {
    return BackendContext(
      sharedGpu: sharedGpu ?? this.sharedGpu,
      d3d11DeviceHandle: d3d11DeviceHandle ?? this.d3d11DeviceHandle,
      preferZeroCopy: preferZeroCopy ?? this.preferZeroCopy,
      attachments: attachments ?? this.attachments,
    );
  }
}
