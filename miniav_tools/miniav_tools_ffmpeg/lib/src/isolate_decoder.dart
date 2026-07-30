/// Isolate-hosted decoders (video + audio).
///
/// [FfmpegSoftwareDecoder] / [FfmpegAudioDecoder] perform their libav calls
/// synchronously on the calling isolate; at 1080p+ a video decode is tens of
/// ms per frame, which would freeze a Flutter UI isolate. These wrappers host
/// the decoder on a long-lived worker isolate, mirroring
/// `IsolateSoftwareEncoder`'s protocol exactly: packets cross as
/// [TransferableTypedData] (one copy, then zero-copy ownership transfer) and
/// decoded YUV planes / PCM chunks come back the same way, so the calling
/// isolate never touches pixel/sample memory beyond a zero-copy materialize.
///
/// This package is native-only (`dart:ffi` throughout), so `dart:isolate`
/// here does not affect web builds.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_audio_decoder.dart';
import 'ffmpeg_bindings.dart' show ensureFFmpegLoaded;
import 'ffmpeg_decoder.dart';

// =============================================================================
// Shared request plumbing
// =============================================================================

class _WorkerHandle {
  _WorkerHandle(this._isolate, this._toWorker, this._fromWorker);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  final Map<int, Completer<List<dynamic>>> _pending = {};
  int _nextId = 0;
  bool closed = false;

  static Future<_WorkerHandle> spawn(
    void Function(List<dynamic>) entry,
    Object? config,
    String debugName,
    String backendName,
  ) async {
    final fromWorker = ReceivePort();
    final handshake = Completer<List<dynamic>>();

    late final _WorkerHandle self;
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
        entry,
        [fromWorker.sendPort, config],
        debugName: debugName,
        errorsAreFatal: true,
      );
    } catch (e) {
      fromWorker.close();
      throw CodecInitException(backendName, 'isolate spawn failed: $e');
    }

    final ready = await handshake.future;
    if (ready[0] != 'ready') {
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      throw CodecInitException(backendName, ready[1] as String);
    }
    return self = _WorkerHandle(isolate, ready[1] as SendPort, fromWorker);
  }

  Future<List<dynamic>> request(List<dynamic> msg, String backendName) {
    if (closed) {
      throw CodecRuntimeException(backendName, 'decoder closed');
    }
    final id = _nextId++;
    final completer = Completer<List<dynamic>>();
    _pending[id] = completer;
    _toWorker.send([msg[0], id, ...msg.sublist(1)]);
    return completer.future;
  }

  Future<void> close(String backendName) async {
    if (closed) return;
    try {
      // Bounded: a natively-crashed worker (no onExit listener) never replies,
      // so awaiting the 'close' round-trip unguarded would hang forever.
      await request(['close'], backendName).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Worker may already be gone, or timed out; proceed with teardown.
    }
    closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(CodecRuntimeException(backendName, 'decoder closed'));
      }
    }
    _pending.clear();
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

List<dynamic> _packPacket(EncodedPacket packet) => [
  TransferableTypedData.fromList([packet.data]),
  packet.ptsUs,
  packet.dtsUs,
  packet.isKeyframe,
];

EncodedPacket _unpackPacket(List<dynamic> msg, int offset) => EncodedPacket(
  data: (msg[offset] as TransferableTypedData).materialize().asUint8List(),
  ptsUs: msg[offset + 1] as int,
  dtsUs: msg[offset + 2] as int,
  isKeyframe: msg[offset + 3] as bool,
);

// =============================================================================
// Video
// =============================================================================

const String _kVideoBackend = 'ffmpeg-decode-isolate';

/// Video decoder hosted on a dedicated worker isolate. Public API is
/// identical to [PlatformDecoder]; construction is async ([open]).
class IsolateVideoDecoder implements PlatformDecoder {
  IsolateVideoDecoder._(this._worker);

  final _WorkerHandle _worker;

  static Future<IsolateVideoDecoder> open(DecoderConfig cfg) async {
    final worker = await _WorkerHandle.spawn(
      _videoWorkerMain,
      cfg,
      'IsolateVideoDecoder(${cfg.codec.name})',
      _kVideoBackend,
    );
    return IsolateVideoDecoder._(worker);
  }

  @override
  Future<DecodedFrame?> decode(EncodedPacket packet) async {
    final reply = await _worker.request([
      'decode',
      ..._packPacket(packet),
    ], _kVideoBackend);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kVideoBackend, reply[2] as String);
    }
    return _unpackFrame(reply, 2);
  }

  @override
  Future<List<DecodedFrame>> flush() async {
    final reply = await _worker.request(['flush'], _kVideoBackend);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kVideoBackend, reply[2] as String);
    }
    final frames = (reply[2] as List).cast<List>();
    return [
      for (final f in frames) _unpackFrame(f, 0)!,
    ];
  }

  @override
  Future<void> close() => _worker.close(_kVideoBackend);

  static DecodedFrame? _unpackFrame(List<dynamic> msg, int offset) {
    if (msg[offset] as bool != true) return null;
    return _RelayedYuv420pFrame(
      bytes: (msg[offset + 1] as TransferableTypedData)
          .materialize()
          .asUint8List(),
      width: msg[offset + 2] as int,
      height: msg[offset + 3] as int,
      ptsUs: msg[offset + 4] as int,
      pixelLayout: DecodedPixelLayout.values[msg[offset + 5] as int],
      isFullRange: msg[offset + 6] as bool,
      colorMatrix: YuvColorMatrix.values[msg[offset + 7] as int],
    );
  }
}

/// A YUV420P frame relayed from the worker. [bytes] is this isolate's own
/// (materialized) copy: Y (w*h) | U (w*h/4) | V (w*h/4), tightly packed.
class _RelayedYuv420pFrame implements DecodedFrame {
  _RelayedYuv420pFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.ptsUs,
    this.pixelLayout = DecodedPixelLayout.i420,
    this.isFullRange = false,
    this.colorMatrix = YuvColorMatrix.bt601,
  });

  final Uint8List bytes;
  @override
  final int width;
  @override
  final int height;
  @override
  final int ptsUs;
  @override
  final DecodedPixelLayout pixelLayout;
  @override
  final bool isFullRange;
  @override
  final YuvColorMatrix colorMatrix;

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

Future<void> _videoWorkerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final cfg = args[1] as DecoderConfig;

  final PlatformDecoder dec;
  try {
    final loaded = await ensureFFmpegLoaded();
    if (!loaded) {
      toMain.send(['error', 'FFmpeg failed to load in worker isolate']);
      return;
    }
    dec = FfmpegSoftwareDecoder.open(cfg);
  } catch (e) {
    toMain.send(['error', 'decoder open failed in worker: $e']);
    return;
  }

  Future<List<dynamic>> packFrame(DecodedFrame? f) async {
    if (f == null) return [false, null, 0, 0, 0, 0, false, 0];
    final raw = await f.readBytes();
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final packed = [
      true,
      TransferableTypedData.fromList([bytes]),
      f.width,
      f.height,
      f.ptsUs,
      f.pixelLayout.index,
      f.isFullRange,
      f.colorMatrix.index,
    ];
    f.close();
    return packed;
  }

  final commands = ReceivePort();
  toMain.send(['ready', commands.sendPort]);

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'decode':
          final frame = await dec.decode(_unpackPacket(msg, 2));
          toMain.send(['frame', id, ...await packFrame(frame)]);
        case 'flush':
          final frames = await dec.flush();
          toMain.send([
            'frames',
            id,
            [for (final f in frames) await packFrame(f)],
          ]);
        case 'close':
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

// =============================================================================
// Audio
// =============================================================================

const String _kAudioBackend = 'ffmpeg-audio-decode-isolate';

/// Audio decoder hosted on a dedicated worker isolate. Public API is
/// identical to [PlatformAudioDecoder]; construction is async ([open]).
class IsolateAudioDecoder implements PlatformAudioDecoder {
  IsolateAudioDecoder._(this._worker);

  final _WorkerHandle _worker;

  static Future<IsolateAudioDecoder> open(AudioDecoderConfig cfg) async {
    final worker = await _WorkerHandle.spawn(
      _audioWorkerMain,
      cfg,
      'IsolateAudioDecoder(${cfg.codec.name})',
      _kAudioBackend,
    );
    return IsolateAudioDecoder._(worker);
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    final reply = await _worker.request([
      'decode',
      ..._packPacket(packet),
    ], _kAudioBackend);
    return _unpackChunks(reply);
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    final reply = await _worker.request(['flush'], _kAudioBackend);
    return _unpackChunks(reply);
  }

  @override
  Future<void> close() => _worker.close(_kAudioBackend);

  List<DecodedAudio> _unpackChunks(List<dynamic> reply) {
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kAudioBackend, reply[2] as String);
    }
    final datas = (reply[2] as List).cast<TransferableTypedData>();
    final metas = (reply[3] as List).cast<List>();
    return [
      for (var i = 0; i < datas.length; i++)
        DecodedAudio(
          samples: datas[i].materialize().asFloat32List(),
          frameCount: metas[i][0] as int,
          sampleRate: metas[i][1] as int,
          channels: metas[i][2] as int,
          ptsUs: metas[i][3] as int,
        ),
    ];
  }
}

Future<void> _audioWorkerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final cfg = args[1] as AudioDecoderConfig;

  final PlatformAudioDecoder dec;
  try {
    final loaded = await ensureFFmpegLoaded();
    if (!loaded) {
      toMain.send(['error', 'FFmpeg failed to load in worker isolate']);
      return;
    }
    dec = FfmpegAudioDecoder.open(cfg);
  } catch (e) {
    toMain.send(['error', 'audio decoder open failed in worker: $e']);
    return;
  }

  List<dynamic> packChunks(List<DecodedAudio> chunks) => [
    [
      for (final c in chunks) TransferableTypedData.fromList([c.samples]),
    ],
    [
      for (final c in chunks) [c.frameCount, c.sampleRate, c.channels, c.ptsUs],
    ],
  ];

  final commands = ReceivePort();
  toMain.send(['ready', commands.sendPort]);

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'decode':
          final chunks = await dec.decode(_unpackPacket(msg, 2));
          toMain.send(['chunks', id, ...packChunks(chunks)]);
        case 'flush':
          final chunks = await dec.flush();
          toMain.send(['chunks', id, ...packChunks(chunks)]);
        case 'close':
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
