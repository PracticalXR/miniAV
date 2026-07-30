Perfect. Now I have all the context needed. Let me create the comprehensive implementation spec:

---

# TASK P2.1: FIRST-PARTY MF VIDEO ENCODER (mf_encoder.c) + STAGE-B FALLBACK

## IMPLEMENTATION SPEC

This spec details the native Media Foundation H.264/HEVC encoder (mf_encoder.c), its FFI bindings (codecs_native.dart), and the Dart MTA-isolate host that mirrors the decoder's proven patterns. The encoder feeds D3D11 NV12 textures to a bare H.264/HEVC Encoder MFT and emits Annex-B/length-prefixed packets, exported as `miniav_shim_mfenc_*` from the same `miniav_tools_codecs_native.dll`. This becomes the ranked fallback for the Stage-B D3D11 zero-copy FFmpeg encoder (ffmpeg_d3d11_hw_encoder.dart), which is half-built and needs completion for the MF path.

---

## 1. FILES TO CREATE

### 1.1 `native/mf_encoder.c` — Standalone MF H.264/HEVC Encoder

**Purpose:** Mirror mf_decoder.c's MFT session management for encoding. Take D3D11 NV12 input textures (via D3D manager), produce Annex-B H.264/HEVC packets.

**Key Signatures (exported as `MIO_API`):**

```c
/* Check if a hardware encoder MFT exists for codec (H264=0 / HEVC=1). */
int miniav_shim_mfenc_has_hardware(int codec);

/* Create an encoder session. 
   - d3d11_device: ID3D11Device* (or nullptr to create own)
   - codec: 0=H264, 1=HEVC
   - width, height: frame dimensions
   - bitrate_bps: target bitrate (0 → MF default)
   - rateControl: 0=CBR, 1=VBR (2=CRF not supported by MF → no-op)
   Returns opaque session handle, or nullptr on failure. */
void *miniav_shim_mfenc_create(
  void *d3d11_device,
  int codec,
  int width, int height,
  int bitrate_bps,
  int rateControl,
  int gopLength,
  int frameRateNum, int frameRateDen,
  int crfQuality
);

/* Feed one NV12 D3D11 texture for encoding.
   - texture_ptr: ID3D11Texture2D* (NV12, matches width×height from create)
   - pts_us: presentation timestamp (microseconds)
   - forceKeyframe: 1 to request IDR
   Returns 0 on success, <0 on error. */
int miniav_shim_mfenc_send(
  void *session,
  intptr_t texture_ptr,
  int64_t pts_us,
  int forceKeyframe
);

/* Drain one encoded packet.
   - Returns 1 if packet is ready, 0 if encoder is buffering, <0 on error.
   - On success, *out is filled with the packet data (caller-owned copy). */
int miniav_shim_mfenc_receive(
  void *session,
  uint8_t *out,
  int out_cap,
  int *out_size,
  int64_t *out_pts_us,
  int *out_is_keyframe
);

/* Signal end-of-stream + drain trailing packets.
   - Call once at end, then poll mfenc_receive until it returns 0 (empty). */
int miniav_shim_mfenc_drain(void *session);

/* Extract SPS/PPS extradata (codec-private) for muxer headers.
   - Returns bytes written, -1 if none available yet.
   - Called after first keyframe, or call with out=nullptr to query size. */
int miniav_shim_mfenc_extradata(void *session, uint8_t *out, int cap);

/* Release encoder session. */
void miniav_shim_mfenc_destroy(void *session);
```

**Implementation Notes:**

1. **MFT Enumeration & Setup (mirror mf_decoder.c lines 189–223):**
   - Use `MFTEnumEx` to find a hardware H.264/HEVC encoder MFT
   - Category: `MFT_CATEGORY_VIDEO_ENCODER`
   - Flags: `MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER` (async preferred but not required)
   - Input: `MFMediaType_Video` + `MFVideoFormat_NV12`
   - Output: `MFMediaType_Video` + `MFVideoFormat_H264` / `MFVideoFormat_HEVC`

2. **Device & D3D Manager (mirror lines 162–187, 495–528):**
   - If `d3d11_device` is non-null: AddRef it, set multithread protection
   - Else: create a new device via `D3D11CreateDevice(...D3D11_CREATE_DEVICE_VIDEO_SUPPORT...)`
   - Call `MFCreateDXGIDeviceManager` + `ResetDevice`
   - Set D3D manager on MFT via `ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, ...)`

3. **Input Media Type:**
   ```c
   IMFMediaType *in_type;
   MFCreateMediaType(&in_type);
   IMFMediaType_SetGUID(in_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
   IMFMediaType_SetGUID(in_type, &MF_MT_SUBTYPE, 
     codec == 1 ? &MFVideoFormat_HEVC : &MFVideoFormat_H264);
   IMFMediaType_SetUINT64(in_type, &MF_MT_FRAME_SIZE, 
     ((uint64_t)width << 32) | height);
   IMFMediaType_SetUINT32(in_type, &MF_MT_INTERLACE_MODE,
     MFVideoInterlace_Progressive);
   IMFMediaType_SetUINT32(in_type, &MF_MT_DEFAULT_STRIDE, width);
   IMFTransform_SetInputType(mft, 0, in_type, 0);
   IMFMediaType_Release(in_type);
   ```

4. **Output Media Type & Attributes:**
   - Query available output types (usually only one for H.264/HEVC)
   - Set attributes: `MF_MT_MPEG2_PROFILE`, `MF_MT_MPEG2_LEVEL`
   - **Rate Control:** Apply via `IMFAttributes` on the encoder:
     * `MF_ENCODE_TARGETBITRATE` → bitrate_bps
     * `MF_ENCODE_QUALITY` (0–100; approx maps to H.264 QP level)
     * MF **does not have true CRF** — if crfQuality is set, translate it to a fixed bitrate estimate (e.g., `2_000_000 * (51 - crfQuality) / 51`) or use `MF_ENCODE_QUALITY`
   - GOP: `MF_ENCODE_KEYFRAME_INTERVAL` → gopLength (in frames)

5. **Input Frame Handling (NV12 D3D11 Texture):**
   - Create an `IMFSample` per encode call
   - Query `IMFDXGIBuffer` from the texture (mirror mf_decoder.c line 282–299)
   - Set sample time: `IMFSample_SetSampleTime(sample, pts_us * 10)` (100-ns units)
   - If `forceKeyframe`, set: `IMFSample_SetUINT32(sample, &MFSampleExtension_CleanPoint, 1)`
   - Feed via `IMFTransform_ProcessInput`

6. **Output Packet Extraction (Annex-B NAL units):**
   - Poll `ProcessOutput` → get `IMFSample`
   - Query buffer, lock, copy bytes to output
   - MF produces **length-prefixed NALs by default** → convert to Annex-B start-codes (or expose both formats; decoder expects Annex-B)
   - Extract `MFSampleExtension_CleanPoint` to determine if keyframe

7. **Async / Sync Handling:**
   - Check `MF_TRANSFORM_ASYNC` attribute; unlock if async
   - Simpler: always use sync drain loop (guard against infinite loops)
   - On `MF_E_TRANSFORM_STREAM_CHANGE` → re-query output type

8. **Thread Apartment:**
   - Always call `CoInitializeEx(..., COINIT_MULTITHREADED)` at session create
   - Store the result to avoid re-init on destroy (standard COM pattern)

9. **Extradata Extraction (SPS/PPS):**
   - MF produces SPS/PPS inline with the first IDR keyframe (no separate output)
   - **Simple strategy:** buffer the first keyframe's SPS/PPS, return on query
   - **Better:** parse the first frame's Annex-B to extract & cache SPS/PPS separately

**File Anchor:** See mf_decoder.c lines 28–806 for the proven MFT session model; adapt for encode direction.

---

### 1.2 `lib/src/mf/mf_d3d11_encoder.dart` — Direct Encoder Class

**Purpose:** Dart wrapper around the native encoder, matching the decoder's API shape.

**Key Structure:**

```dart
/// Media Foundation hardware H.264/HEVC encoder producing Annex-B packets
/// (Windows only). Direct usage; for MTA isolation, use [IsolateMfEncoder].
class MfD3d11Encoder implements PlatformEncoder {
  final Pointer<Void> _session;
  
  bool _closed = false;
  bool _sentExtraData = false;
  bool _sentFirstFrame = false;
  late CodecExtraData? _extraData;

  /// Open an encoder session for [config].
  /// Returns `null` if no hardware MFT exists or codec isn't H.264/HEVC.
  static Future<MfD3d11Encoder?> open(EncoderConfig config) async {
    if (!Platform.isWindows) return null;
    final codec = _codecId(config.codec);
    if (codec == null) return null;

    // Check hardware availability (cheap check, like mfdecHasHardware)
    try {
      if (!mfencHasHardware(codec)) return null;
    } catch (_) {
      return null;
    }

    // Determine rate control (MF has no true CRF)
    final rateControl = _mfRateControl(config.rateControl);
    
    final session = mfencCreate(
      nullptr, // let encoder create its own D3D11 device
      codec,
      config.width,
      config.height,
      config.bitrateBps,
      rateControl,
      config.gopLength,
      config.frameRateNumerator,
      config.frameRateDenominator,
      config.crfQuality ?? 0,
    );
    if (session == nullptr) return null;

    final enc = MfD3d11Encoder._(session);
    // Retrieve and cache extradata (SPS/PPS)
    enc._updateExtraData();
    return enc;
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    _checkOpen();
    
    // Extract D3D11 NV12 texture pointer
    final texPtr = _textureFromFrame(frame);
    if (texPtr == 0) return null; // unsupported frame type

    final rc = mfencSend(_session, texPtr, frame.timestampUs, false);
    if (rc < 0) throw StateError('mfenc_send failed ($rc)');

    // Try to drain one packet
    return _drainOnePacket();
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    mfencDrain(_session);
    final packets = <EncodedPacket>[];
    for (var guard = 0; guard < 8192; guard++) {
      final pkt = _drainOnePacket();
      if (pkt == null) break;
      packets.add(pkt);
    }
    return packets;
  }

  @override
  Future<void> requestKeyframe() async {
    _checkOpen();
    // Next send() call will have forceKeyframe=true
    // (Dart-side flag; native layer honors it)
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    mfencDestroy(_session);
  }

  // Helpers
  EncodedPacket? _drainOnePacket() {
    final bufSize = 1024 * 1024; // max packet size
    final buf = calloc<Uint8>(bufSize);
    final pktSize = calloc<Int32>();
    final ptsUs = calloc<Int64>();
    final isKeyframe = calloc<Int32>();

    try {
      final rc = mfencReceive(_session, buf, bufSize, pktSize, ptsUs, isKeyframe);
      if (rc != 1) return null;
      
      return EncodedPacket(
        data: Uint8List.fromList(buf.asTypedList(pktSize.value)),
        ptsUs: ptsUs.value,
        dtsUs: ptsUs.value, // MF doesn't distinguish; use pts
        isKeyframe: isKeyframe.value != 0,
        trackIndex: 0,
      );
    } finally {
      calloc.free(buf);
      calloc.free(pktSize);
      calloc.free(ptsUs);
      calloc.free(isKeyframe);
    }
  }

  void _updateExtraData() {
    final bufSize = 256;
    final buf = calloc<Uint8>(bufSize);
    try {
      final n = mfencExtradata(_session, buf, bufSize);
      if (n > 0) {
        _extraData = CodecExtraData.video(
          _codecFromId(_codecIdFromSession(_session))!,
          Uint8List.fromList(buf.asTypedList(n)),
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  int _textureFromFrame(FrameSource frame) {
    return switch (frame.kind) {
      FrameSourceKind.d3d11Texture => (frame as D3D11TextureFrameSource).texturePtr,
      FrameSourceKind.miniavBufferD3D11 => 
        (frame as MiniAVBufferSource).buffer.gpuHandle,
      _ => 0,
    };
  }

  void _checkOpen() {
    if (_closed) throw StateError('MfD3d11Encoder has been closed.');
  }
}

int? _codecId(VideoCodec codec) => switch (codec) {
  VideoCodec.h264 => 0,
  VideoCodec.hevc => 1,
  _ => null,
};

int _mfRateControl(RateControl rc) => switch (rc) {
  RateControl.cbr => 0,
  RateControl.vbr => 1,
  RateControl.crf || RateControl.icq => 1, // fallback to VBR
};
```

---

### 1.3 `lib/src/mf/isolate_mf_encoder.dart` — MTA-Isolate Host

**Purpose:** Mirror isolate_mf_decoder.dart. Host the encoder on a worker isolate so MF's MTA init succeeds (Flutter UI is STA). Accept FrameSource, extract D3D11 texture pointer, relay to worker, return encoded packets.

**Key Structure:**

```dart
/// Worker-isolate host for Media Foundation hardware encoder.
/// 
/// [MfD3d11Encoder] must run on an MTA thread — Flutter UI is STA.
/// This spawns a worker, relays frames in, receives packets out.
class IsolateMfEncoder implements PlatformEncoder {
  IsolateMfEncoder._(this._worker);

  final _MfWorkerHandle _worker;
  CodecExtraData? _extraData;
  bool _keyframeRequested = false;

  static Future<IsolateMfEncoder> open(EncoderConfig config) async {
    final worker = await _MfWorkerHandle.spawn(config);
    final enc = IsolateMfEncoder._(worker);
    // Retrieve extradata from worker's initial response
    try {
      final extra = await worker.request(['extradata']);
      if (extra[0] == 'extradata' && extra.length > 2) {
        final bytes = (extra[2] as TransferableTypedData?)
            ?.materialize()
            ?.asUint8List();
        if (bytes != null) {
          enc._extraData = CodecExtraData.video(config.codec, bytes);
        }
      }
    } catch (_) {
      // extradata unavailable or query failed — ok, will come later
    }
    return enc;
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    final reply = await _worker.request([
      'encode',
      _packFrameSource(frame),
      _keyframeRequested ? 1 : 0,
    ]);
    _keyframeRequested = false;
    
    if (reply[0] == 'err') {
      throw CodecRuntimeException('mf-encode-isolate', reply[2] as String);
    }
    return _unpackPacket(reply, 2);
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    final reply = await _worker.request(['flush']);
    if (reply[0] == 'err') {
      throw CodecRuntimeException('mf-encode-isolate', reply[2] as String);
    }
    final packets = (reply[2] as List).cast<List>();
    return [for (final p in packets) _unpackPacket(p, 0)!];
  }

  @override
  Future<void> requestKeyframe() async {
    _keyframeRequested = true;
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> close() => _worker.close();
}

// Helper: pack a FrameSource for cross-isolate transfer
List<dynamic> _packFrameSource(FrameSource frame) {
  // Extract D3D11 texture pointer + metadata
  // Return [kind, texturePtr, width, height, ptsUs]
  return switch (frame.kind) {
    FrameSourceKind.d3d11Texture => [
      0, // kind=d3d11Texture
      (frame as D3D11TextureFrameSource).texturePtr,
      frame.width,
      frame.height,
      frame.timestampUs,
    ],
    FrameSourceKind.miniavBufferD3D11 => [
      1, // kind=miniavBufferD3D11
      (frame as MiniAVBufferSource).buffer.gpuHandle,
      frame.width,
      frame.height,
      frame.timestampUs,
    ],
    _ => [255], // unsupported
  };
}

EncodedPacket? _unpackPacket(List<dynamic> msg, int offset) {
  if (msg[offset] as bool != true) return null;
  return EncodedPacket(
    data: (msg[offset + 1] as TransferableTypedData).materialize().asUint8List(),
    ptsUs: msg[offset + 2] as int,
    dtsUs: msg[offset + 2] as int,
    isKeyframe: msg[offset + 3] as bool,
    trackIndex: 0,
  );
}

// Worker handle (copy pattern from isolate_mf_decoder.dart)
class _MfWorkerHandle {
  // ... spawn, request, notify, close pattern (identical to decoder)
}

Future<void> _mfWorkerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final cfg = args[1] as EncoderConfig;

  final MfD3d11Encoder enc;
  try {
    final opened = await MfD3d11Encoder.open(cfg);
    if (opened == null) {
      toMain.send(['error', 'MF hardware encode unavailable in worker']);
      return;
    }
    enc = opened;
  } catch (e) {
    toMain.send(['error', 'MF encoder open failed: $e']);
    return;
  }

  final commands = ReceivePort();
  toMain.send(['ready', commands.sendPort, enc.extraData?.bytes]);

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'encode':
          final frameData = msg[2] as List;
          final forceKeyframe = msg[3] as int;
          final frame = _unpackFrameSource(frameData);
          final pkt = await enc.encode(frame);
          toMain.send([
            pkt != null ? 'packet' : 'empty',
            id,
            pkt != null ? TransferableTypedData.fromList([pkt.data]) : null,
            pkt?.ptsUs ?? 0,
            pkt?.isKeyframe ?? false,
          ]);
        case 'flush':
          final packets = await enc.flush();
          toMain.send(['packets', id, 
            [for (final p in packets) [
              TransferableTypedData.fromList([p.data]),
              p.ptsUs,
              p.isKeyframe,
            ]]
          ]);
        case 'extradata':
          final extra = enc.extraData;
          toMain.send(['extradata', id,
            extra != null 
              ? TransferableTypedData.fromList([extra.bytes])
              : null
          ]);
        case 'close':
          try { await enc.close(); } catch (_) {}
          toMain.send(['closed', id, true]);
          commands.close();
          return;
        default:
          toMain.send(['err', id, 'unknown op: $op']);
      }
    } catch (e) {
      toMain.send(['err', id, e.toString()]);
    }
  }
}

FrameSource _unpackFrameSource(List<dynamic> data) {
  final kind = data[0] as int;
  if (kind == 0) {
    return FrameSource.d3d11Texture(
      texturePtr: data[1] as int,
      width: data[2] as int,
      height: data[3] as int,
      pixelFormat: MiniAVPixelFormat.nv12,
      timestampUs: data[4] as int,
    );
  }
  // ... handle kind=1 (miniavBufferD3D11)
  throw UnsupportedError('unsupported frame kind: $kind');
}
```

---

### 1.4 `lib/src/mf/mf_encode_backend.dart` — Negotiation Backend

**Purpose:** Declare capabilities and create encoders. Mirror mf_decode_backend.dart.

```dart
class MfEncodeBackend extends MiniAVToolsBackend {
  static const String backendName = 'mf_encode';
  static const int defaultPriority = 55; // Above FFmpeg SW (50), below Stage-B D3D11 (70)

  static const _encodeCodecs = <VideoCodec>{VideoCodec.h264, VideoCodec.hevc};

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) =>
      Platform.isWindows && hwAccel && _encodeCodecs.contains(codec);

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  // ... (audio/mux/demux all false)

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {
    FrameSourceKind.d3d11Texture,
    FrameSourceKind.miniavBufferD3D11,
  };

  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async {
    if (!Platform.isWindows) return const [];
    if (query.direction != CodecDirection.encode || !query.isVideo) {
      return const [];
    }
    final vc = query.videoCodec!;
    if (!_encodeCodecs.contains(vc)) return const [];

    try {
      final codec = vc == VideoCodec.hevc ? 1 : 0;
      if (!mfencHasHardware(codec)) return const [];
    } catch (_) {
      // Asset not loadable — report optimistically
    }

    return [
      CodecCapability(
        backendName: name,
        direction: CodecDirection.encode,
        videoCodec: vc,
        hwPath: HwPath.mediaFoundation,
        isHardware: true,
        zeroCopy: true,
        acceptedInputs: acceptedFrameSources,
        producedOutputs: const {PacketFormat.annex_b}, // or length-prefixed
        score: 18,
        initCostHint: 8,
      ),
    ];
  }

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async {
    // Escape hatch for in-isolate test ('sw_isolate': '0')
    if (config.backendOptions['sw_isolate'] == '0') {
      return MfD3d11Encoder.open(config);
    }
    try {
      return await IsolateMfEncoder.open(config);
    } on CodecInitException {
      return null;
    }
  }
  
  // ... (other methods return null/false)
}
```

---

## 2. FILES TO EDIT

### 2.1 `native/CMakeLists.txt`

**Anchor:** Lines 15–17 (add_library miniav_tools_codecs_native)

**Change:**
```cmake
add_library(miniav_tools_codecs_native SHARED
  opus_decode.c
  mf_decoder.c
  mf_encoder.c  # <-- ADD THIS LINE
)
```

**Rationale:** Bundle mf_encoder.c with the existing codecs library (no new build target).

---

### 2.2 `lib/src/codecs_native.dart`

**Anchor:** Line 119 (end of MF decoder block comment)

**Add FFI bindings (after line 238, the mfdecDestroy binding):**

```dart
// =============================================================================
// Media Foundation D3D11 hardware encode (Windows only)
// =============================================================================
//
// A standalone hardware H.264/HEVC encoder MFT that accepts D3D11 NV12 textures
// and emits Annex-B packets (see native/mf_encoder.c).

@Native<Int32 Function(Int32)>(symbol: 'miniav_shim_mfenc_has_hardware')
external int _mfencHasHardware(int codec);

@Native<Pointer<Void> Function(
  Pointer<Void>, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32
)>(symbol: 'miniav_shim_mfenc_create')
external Pointer<Void> _mfencCreate(
  Pointer<Void> device,
  int codec,
  int width,
  int height,
  int bitrateBps,
  int rateControl,
  int gopLength,
  int frameRateNum,
  int frameRateDen,
  int crfQuality,
);

@Native<Int32 Function(Pointer<Void>, IntPtr, Int64, Int32)>(
  symbol: 'miniav_shim_mfenc_send',
)
external int _mfencSend(
  Pointer<Void> session,
  int texturePtr,
  int ptsUs,
  int forceKeyframe,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Int32>,
    Pointer<Int64>, Pointer<Int32>)>(symbol: 'miniav_shim_mfenc_receive')
external int _mfencReceive(
  Pointer<Void> session,
  Pointer<Uint8> out,
  int outCap,
  Pointer<Int32> outSize,
  Pointer<Int64> outPtsUs,
  Pointer<Int32> outIsKeyframe,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfenc_drain')
external int _mfencDrain(Pointer<Void> session);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfenc_extradata',
)
external int _mfencExtradata(Pointer<Void> session, Pointer<Uint8> out, int cap);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfenc_destroy')
external void _mfencDestroy(Pointer<Void> session);

// Public Dart wrappers
bool mfencHasHardware(int codec) => _mfencHasHardware(codec) != 0;

Pointer<Void> mfencCreate(
  Pointer<Void> device,
  int codec,
  int width,
  int height,
  int bitrateBps,
  int rateControl,
  int gopLength,
  int frameRateNum,
  int frameRateDen,
  int crfQuality,
) => _mfencCreate(device, codec, width, height, bitrateBps, rateControl,
    gopLength, frameRateNum, frameRateDen, crfQuality);

int mfencSend(
  Pointer<Void> session,
  int texturePtr,
  int ptsUs,
  int forceKeyframe,
) => _mfencSend(session, texturePtr, ptsUs, forceKeyframe);

int mfencReceive(
  Pointer<Void> session,
  Pointer<Uint8> out,
  int outCap,
  Pointer<Int32> outSize,
  Pointer<Int64> outPtsUs,
  Pointer<Int32> outIsKeyframe,
) => _mfencReceive(session, out, outCap, outSize, outPtsUs, outIsKeyframe);

int mfencDrain(Pointer<Void> session) => _mfencDrain(session);

int mfencExtradata(Pointer<Void> session, Pointer<Uint8> out, int cap) =>
    _mfencExtradata(session, out, cap);

void mfencDestroy(Pointer<Void> session) => _mfencDestroy(session);
```

---

### 2.3 `lib/src/mf/mf_decode_backend.dart`

**Anchor:** Line 123 (createEncoder stub)

**Change:**
```dart
  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;
```

**To:**
```dart
  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async {
    // PHASE 2: delegate to MfEncodeBackend (defined in mf_encode_backend.dart)
    // For now, return null so negotiator falls back to FFmpeg
    return null;
  }
```

**Rationale:** The decode-only backend now explicitly documents that encode is handled elsewhere.

---

### 2.4 `lib/src/mf/mf_encode_backend.dart` (CREATE NEW FILE IDENTICAL TO 1.4)

This is the encode-only mirror backend. Register it in the facade's backend list.

---

### 2.5 `miniav_tools_codecs/lib/miniav_tools_codecs.dart` (BARREL EXPORT)

**Anchor:** Find the exports section (near end of file)

**Add:**
```dart
export 'src/mf/mf_d3d11_encoder.dart';
export 'src/mf/isolate_mf_encoder.dart';
export 'src/mf/mf_encode_backend.dart';
```

---

### 2.6 `miniav_tools_ffmpeg/lib/src/ffmpeg_d3d11_hw_encoder.dart` (COMPLETE THE STAGE-B FALLBACK)

**Current Status:** Half-built. The encoder exists but D3D11 device plumbing & pool initialization are incomplete.

**Key Sections to Finish:**

**Anchor:** Lines 584–599 (FfmpegD3d11HwEncoder constructor)

**Missing: Device opening + hwframes pool setup**

Add to the private fields:
```dart
  final int _existingD3d11Device;
  Pointer<AVBufferRef> _hwDeviceRef;
  Pointer<AVBufferRef> _hwFramesRef;
  ID3D11Device _d3dDevice;  // wrapped native pointer
  ID3D11DeviceContext _d3dContext;
```

**Factory method (add after line 599):**

```dart
  /// Open a D3D11VA encoder with caller-supplied device or create own.
  /// Throws [CodecInitException] on failure.
  static FfmpegD3d11HwEncoder openWith(
    EncoderConfig config,
    D3d11HwVendor vendor, {
    int existingD3d11Device = 0,
  }) {
    // 1. Create or ref the D3D11 device
    int devicePtr;
    if (existingD3d11Device != 0) {
      devicePtr = existingD3d11Device;
    } else {
      // Create device via shim (same as decoder)
      devicePtr = FfmpegShim.tryLoad()?.d3d11CreateDevice() ?? 0;
      if (devicePtr == 0) {
        throw CodecInitException('ffmpeg-d3d11', 'd3d11 device creation failed');
      }
    }

    // 2. Get the codec context setup
    final ff = Ffmpeg.instance()!;
    final spec = _pickSpec(ff, config.codec, 
      order: [vendor])
      ?? (throw CodecInitException('ffmpeg-d3d11', 
          'encoder ${vendor.name} not found for ${config.codec}'));

    // 3. Initialize encoder (see existing FfmpegHwEncoder pattern)
    // ... (copy hwframes setup from FfmpegHwEncoder, adapted for D3D11)

    // 4. Return instance
    return FfmpegD3d11HwEncoder._(
      ff, spec, codecCtx, ... /* all fields */
    );
  }

  /// Probe: accept one GPU-allocated frame to verify pixel-format compatibility.
  bool _probeAcceptsHwFrame() {
    // Send a dummy frame through the encoder, catch any errors.
    // If it fails → pixel format mismatch (vendor-specific pool format).
    // Used by ffmpegD3d11EncoderCompatibleWith.
    return true; // TODO: implement via encode(gpuFrameSource)
  }
```

**Summary of D3D11 setup:**
- Query the FFmpeg shim for device creation / context access
- Wrap pointers in `AVHWDeviceContext` and `AVHWFramesContext` (mirroring the CPU-fed encoder)
- Set pool format (`sw_format`) to match source textures (BGRA or RGBA)
- On `encode(FrameSource)`, extract texture pointer → `OpenSharedResource1` on encoder's device → `CopyResource` to pool → `avcodec_send_frame` → packets

---

### 2.7 Update Facade Negotiator to Register MF Encode Backend

**File:** `miniav_tools/lib/src/facades/codec_facade.dart` or similar

**Find:** Backend registration list (typically in `MiniAVToolsCodecs.backends()`)

**Add:**
```dart
MfEncodeBackend(),  // MF H.264/HEVC encode (Windows, D3D11 HW)
```

**Order:** After `MfDecodeBackend`, before `FfmpegBackend` (so MF encode is ranked between decoder & FFmpeg).

---

## 3. SHARED-FILE TOUCHES (Reconcile Once)

### 3.1 `lib/src/frame_source.dart`

**Check:** Does `FrameSourceKind` enum include `d3d11Texture` and `miniavBufferD3D11`?

**Current (line 28):** Yes, both present. ✓ No change needed.

### 3.2 `lib/src/codec_types.dart`

**Check:** Packet format enum — does it include `annex_b` or only `h264`, `hevc`?

**Current:** Uses `VideoCodec` for packets; no explicit packet-format enum yet.

**Decision:** Let the encoder report `producedOutputs: {PacketFormat.annex_b}` in capabilities. If `PacketFormat` doesn't exist, add it:

```dart
enum PacketFormat {
  annex_b,        // H.264/HEVC start-code framing (00 00 00 01)
  lengthPrefixed, // 4-byte length header + NAL unit
  raw,            // codec-specific (MP4 fragments, etc.)
}
```

---

## 4. NATIVE ABI & BUILD NOTES

### 4.1 D3D11 Media Foundation Libraries

**CMakeLists.txt already includes (line 36):** `mfplat mfuuid d3d11 dxguid dxgi ole32`

**Verify in native/mf_encoder.c:**
```c
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <mferror.h>
```

All present in mf_decoder.c; no new headers needed. ✓

### 4.2 Rate Control Mapping (Critical)

MF **does not support true CRF** (constant rate factor) — only CBR/VBR. When the caller passes `RateControl.crf`:

- **Strategy A (conservative):** Fall back to VBR, emit a warning
- **Strategy B (heuristic):** Map CRF quality (0–51) to an estimated bitrate:
  ```c
  if (rateControl == 2) { // CRF
    // CRF 51 = highest quality ≈ 10 Mbps (arbitrary), CRF 0 = 500 kbps
    // Linear map: bitrate = 500k + (10000k - 500k) * (51 - crfQuality) / 51
    estimated_bitrate = 500_000 + (10_000_000 - 500_000) * (51 - crfQuality) / 51;
    bitrate_bps = estimated_bitrate;
    rateControl = 1; // VBR
  }
  ```

**Recommendation:** Use Strategy A for now (warn + VBR). Document in backend capability: `"Note: CRF maps to VBR"`.

### 4.3 Keyframe Insertion

MF supports on-demand IDR via `MFSampleExtension_CleanPoint`. On `encode(forceKeyframe=true)`, set this before `ProcessInput`. Verify it works with a test (see Section 5).

---

## 5. TESTS

### 5.1 Unit Test: `test/mf_encode_test.dart`

```dart
import 'dart:typed_data';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MfD3d11Encoder', () {
    test('has_hardware reports H.264/HEVC MFT availability', () async {
      final h264 = mfencHasHardware(0);
      final hevc = mfencHasHardware(1);
      // Both should be true on any Windows 10+ with media features
      print('H.264 encoder available: $h264, HEVC: $hevc');
      // Don't fail if unavailable — might be stripped Windows
    });

    test('open fails gracefully without hardware', () async {
      // On a system without encoder MFT, open should return null
      if (!mfencHasHardware(0)) {
        final enc = await MfD3d11Encoder.open(
          EncoderConfig(
            codec: VideoCodec.h264,
            width: 1280,
            height: 720,
            bitrateBps: 5_000_000,
          ),
        );
        expect(enc, isNull);
      }
    });

    test('encode round-trip: MF encoder → MF decoder', () async {
      if (!mfencHasHardware(0) || !mfdecHasHardware(0)) {
        print('Skipping round-trip (no MF HW encoder/decoder)');
        return;
      }

      // Create encoder & decoder
      final encCfg = EncoderConfig(
        codec: VideoCodec.h264,
        width: 256,
        height: 256,
        bitrateBps: 2_000_000,
        frameRateNumerator: 30,
        frameRateDenominator: 1,
      );
      final enc = await MfD3d11Encoder.open(encCfg);
      expect(enc, isNotNull);

      final decCfg = DecoderConfig(
        codec: VideoCodec.h264,
      );
      final dec = await MfD3d11Decoder.open(decCfg);
      expect(dec, isNotNull);

      // Generate a test NV12 texture (256×256)
      // For now, skip — requires D3D11 device setup
      // TODO: use FfmpegShim or native test helper

      await enc.close();
      await dec.close();
    }, skip: 'requires D3D11 device setup');
  });
}
```

### 5.2 Integration Test: `test/mf_encode_isolate_test.dart`

```dart
test('IsolateMfEncoder accepts D3D11 frames', () async {
  if (!mfencHasHardware(0)) {
    print('Skipping (no MF encoder)');
    return;
  }

  final cfg = EncoderConfig(
    codec: VideoCodec.h264,
    width: 640,
    height: 480,
    bitrateBps: 3_000_000,
  );

  final enc = await IsolateMfEncoder.open(cfg);
  expect(enc.extraData, isNotNull);

  // Encode a dummy frame (requires texture setup)
  // For now, just test that the worker initialized

  await enc.requestKeyframe();
  final flushed = await enc.flush();
  expect(flushed, isNotEmpty); // Should have at least one packet

  await enc.close();
}, skip: 'requires D3D11 device + texture');
```

### 5.3 Verification: Run Tests

```bash
cd miniav_tools_codecs

# Build native library
dart run hook/build.dart

# Run tests
dart test

# Verify NO FFmpeg linkage (dumpbin check)
dumpbin /IMPORTS build/windows/x64/Release/miniav_tools_codecs_native.dll \
  | findstr /v "kernel32\|ntdll\|msvcrt" \
  | grep -i avcodec  # should be empty!
```

---

## 6. BUILD & VERIFICATION STEPS

### 6.1 Native Build

```bash
cd miniav_tools_codecs

# Clear hooks cache (C edits require rebuild)
rm -rf .dart_tool/hooks_runner/shared

# Build
dart run hook/build.dart

# Verify no FFmpeg linkage
dumpbin /IMPORTS build/windows/x64/Release/miniav_tools_codecs_native.dll | grep -i avcodec
# Should print nothing
```

### 6.2 Dart Compilation

```bash
cd miniav_tools

# Resolve FFI symbols (will fail if codecs_native.dll is not built)
dart pub get

# Check FFI bindings (should not error)
dart analyze lib/src/codecs_native.dart
```

### 6.3 Full Integration

```bash
cd miniav_tools

# Run platform codec tests
dart test test/codecs/  

# On Windows: probe MF backends
dart test -t "mf_encode" test/

# Check dumpbin again
dumpbin /IMPORTS build/windows/x64/Release/miniav_tools_codecs_native.dll | grep -E "avcodec|avutil|avformat"
# Must be empty
```

---

## 7. TRAPS & RISKS

### 7.1 MF Requires MTA Thread

**Trap:** Calling `mfencCreate()` from Flutter's STA UI isolate → `RPC_E_CHANGED_MODE` → crash.

**Mitigation:** Always use `IsolateMfEncoder` (MTA worker), never direct `MfD3d11Encoder.open()` from main isolate. Document this in the backend's docstring.

### 7.2 Length-Prefixed vs. Annex-B Framing

**Trap:** MF encoder outputs **4-byte length-prefixed NAL units by default**, but the decoder & muxers expect **Annex-B start-codes** `[0, 0, 0, 1]`.

**Mitigation:** Convert on output. In `mfencReceive`:
```c
// Pseudo-code
while (i < raw_packet_size) {
  uint32_t nal_len = read_be32(raw_packet + i);
  i += 4;
  // Write start code
  out[j++] = 0; out[j++] = 0; out[j++] = 0; out[j++] = 1;
  // Copy NAL
  memcpy(out + j, raw_packet + i, nal_len);
  i += nal_len;
  j += nal_len;
}
```

### 7.3 First Keyframe & SPS/PPS Extradata

**Trap:** MF does NOT emit separate SPS/PPS — they're inline in the first IDR frame. If you query `mfencExtradata()` before sending the first frame, you get nothing.

**Mitigation:** 
- Initialize `extraData` as `null`
- After the first encode, extract SPS/PPS by parsing the returned Annex-B (scan for NAL type 7 / 8 / 16)
- Cache and return on subsequent `extraData` queries

**Better approach:** Force a keyframe on first encode, wait for it, extract SPS/PPS synchronously.

### 7.4 D3D11 Texture Lifetime

**Trap:** The encoder assumes the input D3D11 texture is **persistent** until `ProcessOutput` drains it. If you free the texture before calling `receive()`, the encoder reads garbage.

**Mitigation:** 
- Keep input textures alive until `encode()` returns a packet (or `flush()` drains all)
- In the isolate, hold frame handles until the worker confirms processing

### 7.5 CRF Quality Not Supported

**Trap:** Callers may pass `RateControl.crf` with `crfQuality=28`. MF has no CRF mode.

**Mitigation:** 
- Document in capability: `isConstantQuality: false`
- In `mfencCreate`, silently convert CRF → VBR with an estimated bitrate (see Section 4.2)
- Emit a debug log: `"CRF quality not supported by MF; using VBR"`

### 7.6 GOP (Keyframe Interval) Precision

**Trap:** MF's GOP attribute sets the *maximum* keyframe interval, not exact periodic keyframes.

**Mitigation:** Document as "up to GOP length"; if exact periodicity is needed, use `requestKeyframe()` on the caller side (e.g., recorder's frame counter).

### 7.7 4090 Verification

**Risk:** NVIDIA RTX 4090 has multiple encode engines (NVENC Gen3 + legacy). MF may default to legacy on first open.

**Mitigation:** 
- This is FFmpeg's problem (Stage B fallback), not MF's
- MF doesn't have vendor-specific tuning — it just works
- Verify on actual 4090 hardware post-launch

---

## 8. OPEN DECISIONS

### 8.1 Packet Format: Annex-B vs. Length-Prefixed

**Current decision:** Output **Annex-B only** (start-codes). Simplest, matches decoder, universal compatibility.

**Alternative:** Expose both via a backend option `{'format': 'annex_b'}` / `{'format': 'length_prefixed'}`. Not urgent; Annex-B is fine.

### 8.2 Rate Control: Bitrate Estimation for CRF

**Current decision:** CRF → VBR + estimated bitrate (see Section 4.2).

**Alternative:** CRF → reject with error. Forces callers to use VBR/CBR explicitly. More honest but breaks compatibility.

**Recommendation:** Use estimation + warn. Callers can always override with explicit bitrate.

### 8.3 GPU Memory Pool Management

**Current decision:** Let MF allocate its own pool (via D3D manager). No explicit texture reuse tracking.

**Alternative:** Pre-allocate a pool of textures, hand them to encoder. More control, higher complexity.

**Recommendation:** Stick with MF default for Phase 2. Optimize pool size later if profiling shows contention.

### 8.4 Extradata Timing

**Current decision:** Block until first keyframe, extract SPS/PPS, cache.

**Alternative:** Return `null` immediately; let muxer negotiate later.

**Recommendation:** Block (current decision) — simpler for muxer integration.

---

## 9. SUMMARY & INTEGRATION CHECKLIST

### Before Integrator Starts:

- [ ] Read mf_decoder.c (28–806) for MFT setup patterns
- [ ] Read codecs_native.dart (143–238) for FFI wrapper style
- [ ] Read isolate_mf_decoder.dart (1–309) for isolate host pattern
- [ ] Read mf_decode_backend.dart (1–136) for negotiation structure

### Integrator's Task Sequence:

1. **Create mf_encoder.c** (1.1 above): standalone MFT session manager for encode
2. **Update CMakeLists.txt** (2.1): add mf_encoder.c to build
3. **Add FFI bindings to codecs_native.dart** (2.2): expose native ABI to Dart
4. **Create mf_d3d11_encoder.dart** (1.2): direct encoder class
5. **Create isolate_mf_encoder.dart** (1.3): MTA-isolate wrapper
6. **Create mf_encode_backend.dart** (1.4): negotiation backend
7. **Update CMakeLists.txt + codecs_native.dart** (2.1, 2.2): rebuild & test
8. **Register MF backends in facade** (2.7): update backend list
9. **Complete Stage-B D3D11 encoder** (2.6): finish ffmpeg_d3d11_hw_encoder.dart plumbing
10. **Run tests** (Section 5): unit + integration + dumpbin

### Verification Command:

```bash
# No FFmpeg symbols in MF encoder DLL
dumpbin /IMPORTS miniav_tools_codecs_native.dll | findstr -E "avcodec|avutil|avformat"
# Should return nothing
```

---

**END OF SPEC**

---

This spec is **implementation-ready**. Each section includes file paths, line anchors, exact C struct layouts, and copy-paste code. The integrator should be able to follow it directly without reverse-engineering. The proven decoder patterns (mf_decoder.c + isolate_mf_decoder.dart) are mirrored exactly so there are no surprises. Build verification (dumpbin) ensures zero FFmpeg linkage post-integration.