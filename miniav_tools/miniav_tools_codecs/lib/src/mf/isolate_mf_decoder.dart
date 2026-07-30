/// Worker-isolate host for the Media Foundation D3D11 hardware decoder.
///
/// [MfD3d11Decoder] must run on an MTA thread — the Flutter UI isolate is STA
/// (`CoInitializeEx(MTA)` → `RPC_E_CHANGED_MODE`), so MF decode can only init
/// on a fresh worker isolate's thread. This hosts one such worker and relays:
///   - packets in (as [TransferableTypedData]);
///   - decoded frames out as a **GPU-handle descriptor** (the NV12 shared NT
///     handle + w/h/pts) — NOT pixel bytes. The NT handle is process-global, so
///     it's valid in the calling isolate; the caller imports it into Dawn for a
///     zero-copy present. The worker keeps each frame's D3D11 texture alive
///     until the caller signals release via [DecodedFrame.close] (a
///     fire-and-forget `release` message), which the player's scheduler fires
///     on present-or-drop — so no frame leaks.
///   - [DecodedFrame.readBytes] round-trips to the worker (NV12→I420 map) as a
///     CPU fallback for consumers that don't take the texture path.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'mf_d3d11_decoder.dart';

const String _kBackend = 'mf-decode-isolate';

class _MfWorkerHandle {
  _MfWorkerHandle(this._isolate, this._toWorker, this._fromWorker);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  final Map<int, Completer<List<dynamic>>> _pending = {};
  int _nextId = 0;
  bool closed = false;

  SendPort get toWorker => _toWorker;

  static Future<_MfWorkerHandle> spawn(DecoderConfig cfg) async {
    final fromWorker = ReceivePort();
    final handshake = Completer<List<dynamic>>();

    late final _MfWorkerHandle self;
    fromWorker.listen((dynamic msg) {
      final list = msg as List;
      if (!handshake.isCompleted) {
        handshake.complete(list);
        return;
      }
      final id = list[1] as int;
      self._pending.remove(id)?.complete(list);
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _mfWorkerMain,
        [fromWorker.sendPort, cfg],
        debugName: 'IsolateMfDecoder(${cfg.codec.name})',
        errorsAreFatal: true,
      );
    } catch (e) {
      fromWorker.close();
      throw CodecInitException(_kBackend, 'isolate spawn failed: $e');
    }

    final ready = await handshake.future;
    if (ready[0] != 'ready') {
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      throw CodecInitException(_kBackend, ready[1] as String);
    }
    return self = _MfWorkerHandle(isolate, ready[1] as SendPort, fromWorker);
  }

  Future<List<dynamic>> request(List<dynamic> msg) {
    if (closed) throw CodecRuntimeException(_kBackend, 'decoder closed');
    final id = _nextId++;
    final completer = Completer<List<dynamic>>();
    _pending[id] = completer;
    _toWorker.send([msg[0], id, ...msg.sublist(1)]);
    return completer.future;
  }

  /// Fire-and-forget (no reply) — used for per-frame release.
  void notify(List<dynamic> msg) {
    if (closed) return;
    _toWorker.send(msg);
  }

  Future<void> close() async {
    if (closed) return;
    try {
      await request(['close']).timeout(const Duration(seconds: 2));
    } catch (_) {}
    closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(CodecRuntimeException(_kBackend, 'decoder closed'));
      }
    }
    _pending.clear();
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

List<dynamic> _packPacket(EncodedPacket p) => [
  TransferableTypedData.fromList([p.data]),
  p.ptsUs,
  p.dtsUs,
  p.isKeyframe,
];

EncodedPacket _unpackPacket(List<dynamic> msg, int offset) => EncodedPacket(
  data: (msg[offset] as TransferableTypedData).materialize().asUint8List(),
  ptsUs: msg[offset + 1] as int,
  dtsUs: msg[offset + 2] as int,
  isKeyframe: msg[offset + 3] as bool,
);

/// MF hardware decoder hosted on a worker isolate. API-identical to
/// [PlatformDecoder]; construction is async ([open]) and throws
/// [CodecInitException] if the worker can't init HW MF decode (→ the facade
/// negotiator falls back to a software decoder for free).
class IsolateMfDecoder implements PlatformDecoder {
  IsolateMfDecoder._(this._worker);

  final _MfWorkerHandle _worker;

  static Future<IsolateMfDecoder> open(DecoderConfig cfg) async {
    final worker = await _MfWorkerHandle.spawn(cfg);
    return IsolateMfDecoder._(worker);
  }

  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async {
    final reply = await _worker.request(['decode', ..._packPacket(packet)]);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
    return _unpackFrame(reply, 2);
  }

  @override
  Future<List<DecodedFrame>> flush() async {
    final reply = await _worker.request(['flush']);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
    final frames = (reply[2] as List).cast<List>();
    return [for (final f in frames) _unpackFrame(f, 0)!];
  }

  @override
  Future<void> close() => _worker.close();

  DecodedFrame? _unpackFrame(List<dynamic> msg, int offset) {
    if (msg[offset] as bool != true) return null;
    return _IsolateMfFrame(
      worker: _worker,
      frameId: msg[offset + 1] as int,
      sharedHandle: msg[offset + 2] as int,
      width: msg[offset + 3] as int,
      height: msg[offset + 4] as int,
      ptsUs: msg[offset + 5] as int,
    );
  }
}

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
  @override
  DecodedPixelLayout get pixelLayout => DecodedPixelLayout.i420;
  @override
  bool get isFullRange => false;
  @override
  YuvColorMatrix get colorMatrix => YuvColorMatrix.bt601;

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

Future<void> _mfWorkerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final cfg = args[1] as DecoderConfig;

  final MfD3d11Decoder dec;
  try {
    // No FFmpeg: the MF decoder lives in the standalone codecs_native asset.
    final opened = await MfD3d11Decoder.open(cfg);
    if (opened == null) {
      toMain.send([
        'error',
        'MF hardware decode unavailable in worker (no HW MFT / device)',
      ]);
      return;
    }
    dec = opened;
  } catch (e) {
    toMain.send(['error', 'MF decoder open failed in worker: $e']);
    return;
  }

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

  final commands = ReceivePort();
  toMain.send(['ready', commands.sendPort]);

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    // `release` is fire-and-forget (no reply id).
    if (op == 'release') {
      held.remove(msg[1] as int)?.close();
      continue;
    }
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'decode':
          final frame = await dec.decode(_unpackPacket(msg, 2));
          toMain.send(['frame', id, ...packFrame(frame)]);
        case 'flush':
          final frames = await dec.flush();
          toMain.send(['frames', id, [for (final f in frames) packFrame(f)]]);
        case 'map':
          final f = held[msg[2] as int];
          if (f == null) {
            toMain.send(['err', id, 'map: frame already released']);
            break;
          }
          final raw = await f.readBytes();
          final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
          toMain.send(['bytes', id, TransferableTypedData.fromList([bytes])]);
        case 'close':
          for (final f in held.values) {
            f.close();
          }
          held.clear();
          try {
            await dec.close();
          } catch (_) {}
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
