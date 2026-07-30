/// Isolate-hosted demuxer.
///
/// `av_read_frame` is synchronous FFI, and on live byte-pipe inputs it
/// BLOCKS until the transport delivers more bytes — so the demuxer must live
/// on a worker isolate. This wrapper mirrors `IsolateVideoDecoder`'s
/// protocol; the data path for live streams never hops isolates: the feed
/// side (main isolate) writes straight into the shim's native byte pipe via
/// FFI, and the worker's `av_read_frame` unblocks on the C condition
/// variable.
///
/// Shutdown protocol for a possibly-starved live worker: close the pipe
/// FIRST (main isolate, unblocks the reader with EOF), then send 'close',
/// then destroy the pipe once the worker confirms.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_bindings.dart' show ensureFFmpegLoaded;
import 'ffmpeg_demuxer.dart';
import 'ffmpeg_shim.dart';

const String _kBackend = 'ffmpeg-demux-isolate';

/// Feeds a `Stream<List<int>>` into a shim byte pipe with backpressure:
/// when the ring fills, the subscription pauses and the remainder retries
/// on a short timer.
class _PipeFeeder {
  _PipeFeeder(this._shim, this._pipe, Stream<List<int>> stream) {
    _sub = stream.listen(
      _onData,
      onDone: _closePipe,
      onError: (Object e, StackTrace s) {
        error = e;
        _closePipe();
      },
      cancelOnError: true,
    );
  }

  final FfmpegShim _shim;
  final Pointer<Void> _pipe;
  late final StreamSubscription<List<int>> _sub;
  Timer? _retry;
  bool _stopped = false;

  /// First transport error, surfaced by IsolateDemuxer.readPacket at EOF.
  Object? error;

  void _onData(List<int> chunk) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _write(bytes, 0);
  }

  void _write(Uint8List bytes, int offset) {
    if (_stopped) return;
    var off = offset;
    while (off < bytes.length) {
      final w = _shim.bytepipeWrite(_pipe, bytes, off, bytes.length - off);
      if (w < 0) {
        // Pipe closed under us (demuxer shutting down) — stop feeding.
        stop();
        return;
      }
      if (w == 0) {
        // Ring full: pause the transport, retry the remainder shortly.
        _sub.pause();
        _retry = Timer(const Duration(milliseconds: 5), () {
          if (_stopped) return;
          _sub.resume();
          _write(bytes, off);
        });
        return;
      }
      off += w;
    }
  }

  void _closePipe() {
    if (_stopped) return;
    _shim.bytepipeClose(_pipe);
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _retry?.cancel();
    _sub.cancel();
  }
}

class IsolateDemuxer implements PlatformDemuxer {
  IsolateDemuxer._(
    this._isolate,
    this._toWorker,
    this._fromWorker,
    this._tracks,
    this._durationUs,
    this._isSeekable,
    this._shim,
    this._pipe,
    this._feeder,
  );

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final List<TrackInfo> _tracks;
  final int? _durationUs;
  final bool _isSeekable;

  /// Main-isolate-owned pipe for bytes/byteStream inputs (null for files).
  final FfmpegShim? _shim;
  final Pointer<Void>? _pipe;
  final _PipeFeeder? _feeder;

  final Map<int, Completer<List<dynamic>>> _pending = {};
  int _nextId = 0;
  bool _closed = false;

  static Future<IsolateDemuxer> open(DemuxerConfig config) async {
    // File inputs need no pipe; bytes/byteStream create one on the MAIN
    // isolate (requires FFmpeg + shim loaded here too — cheap, idempotent).
    Pointer<Void>? pipe;
    FfmpegShim? shim;
    _PipeFeeder? feeder;
    final input = config.input;

    Object? workerArg;
    var mode = 'file';
    if (input is FileDemuxerInput) {
      workerArg = input.path;
    } else {
      if (!await ensureFFmpegLoaded()) {
        throw const CodecInitException(_kBackend, 'FFmpeg failed to load');
      }
      shim = FfmpegShim.tryLoad();
      if (shim == null) {
        throw const CodecInitException(
          _kBackend,
          'shim not loadable — byte inputs need the byte pipe',
        );
      }
      switch (input) {
        case BytesDemuxerInput(:final bytes):
          // Seekable in-worker open from a transferred copy (moov-at-end
          // MP4s need seeks — a forward-only pipe cannot probe them).
          mode = 'bytes';
          workerArg = TransferableTypedData.fromList([bytes]);
        case StreamDemuxerInput(:final stream, :final bufferBytes):
          pipe = shim.bytepipeCreate(bufferBytes);
          if (pipe == nullptr) {
            throw const CodecInitException(_kBackend, 'bytepipe OOM');
          }
          feeder = _PipeFeeder(shim, pipe, stream);
          mode = 'pipe';
          workerArg = pipe.address;
        case FileDemuxerInput():
          throw StateError('unreachable');
      }
    }

    void cleanupPipe() {
      feeder?.stop();
      if (pipe != null) {
        shim!.bytepipeClose(pipe);
        shim.bytepipeDestroy(pipe);
      }
    }

    final fromWorker = ReceivePort();
    final handshake = Completer<List<dynamic>>();
    late final IsolateDemuxer self;
    var ready = false;
    fromWorker.listen((dynamic msg) {
      final list = msg as List;
      if (!ready) {
        ready = true;
        handshake.complete(list);
        return;
      }
      final id = list[1] as int;
      self._pending.remove(id)?.complete(list);
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _demuxWorkerMain,
        [fromWorker.sendPort, mode, workerArg],
        debugName: 'IsolateDemuxer($mode)',
        errorsAreFatal: true,
      );
    } catch (e) {
      fromWorker.close();
      cleanupPipe();
      throw CodecInitException(_kBackend, 'isolate spawn failed: $e');
    }

    // Open timeout: a live byte stream that stalls mid-probe
    // (avformat_find_stream_info reads ahead and BLOCKS on the pipe) would
    // otherwise hang open() forever — a dead/stalled connection must surface
    // an error instead. Only applies to pipe (stream) inputs; file/bytes
    // open from local/in-memory data that cannot stall. Default 15s; override
    // via backendOptions {'open_timeout_ms': '...'} ('0' disables).
    final int? openTimeoutMs = () {
      final raw = config.backendOptions['open_timeout_ms'];
      if (raw != null) {
        final v = int.tryParse(raw);
        return (v == null || v <= 0) ? null : v;
      }
      return mode == 'pipe' ? 15000 : null;
    }();

    final List<dynamic> readyMsg;
    try {
      readyMsg = openTimeoutMs != null
          ? await handshake.future.timeout(
              Duration(milliseconds: openTimeoutMs),
            )
          : await handshake.future;
    } on TimeoutException {
      // Unblock the worker's blocked probe (read cb → EOF → open fails), then
      // wait briefly for it to unwind and release the pipe before destroying.
      if (pipe != null) shim!.bytepipeClose(pipe);
      var workerReleased = false;
      try {
        await handshake.future.timeout(const Duration(seconds: 2));
        workerReleased = true; // worker sent its (now-error) handshake
      } on TimeoutException {
        // Still blocked — leak the pipe rather than risk a use-after-free by
        // destroying it under a live native reader.
      }
      feeder?.stop();
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      if (workerReleased && pipe != null) shim!.bytepipeDestroy(pipe);
      throw CodecInitException(
        _kBackend,
        'open timed out after ${openTimeoutMs}ms — the stream did not deliver '
        'enough data to probe (dead or stalled connection?)',
      );
    }
    if (readyMsg[0] != 'ready') {
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      cleanupPipe();
      throw CodecInitException(_kBackend, readyMsg[1] as String);
    }

    return self = IsolateDemuxer._(
      isolate,
      readyMsg[1] as SendPort,
      fromWorker,
      (readyMsg[2] as List).cast<TrackInfo>(),
      readyMsg[3] as int?,
      readyMsg[4] as bool,
      shim,
      pipe,
      feeder,
    );
  }

  Future<List<dynamic>> _request(List<dynamic> msg) {
    if (_closed) {
      throw const CodecRuntimeException(_kBackend, 'demuxer closed');
    }
    final id = _nextId++;
    final completer = Completer<List<dynamic>>();
    _pending[id] = completer;
    _toWorker.send([msg[0], id, ...msg.sublist(1)]);
    return completer.future;
  }

  @override
  List<TrackInfo> get tracks => _tracks;

  @override
  int? get durationUs => _durationUs;

  @override
  bool get isSeekable => _isSeekable;

  @override
  Future<EncodedPacket?> readPacket() async {
    final reply = await _request(['read']);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
    if (reply[2] as bool != true) {
      // EOF — surface a transport error (if the feed died) exactly once.
      final err = _feeder?.error;
      if (err != null) {
        _feeder?.error = null;
        throw CodecRuntimeException(_kBackend, 'source stream error: $err');
      }
      return null;
    }
    return EncodedPacket(
      data: (reply[3] as TransferableTypedData).materialize().asUint8List(),
      ptsUs: reply[4] as int,
      dtsUs: reply[5] as int,
      durationUs: reply[6] as int,
      isKeyframe: reply[7] as bool,
      trackIndex: reply[8] as int,
    );
  }

  @override
  Future<void> seek(int timestampUs) async {
    if (!_isSeekable) {
      throw const CodecRuntimeException(
        _kBackend,
        'seek unsupported on a non-seekable (live byte stream) input',
      );
    }
    final reply = await _request(['seek', timestampUs]);
    if (reply[0] == 'err') {
      throw CodecRuntimeException(_kBackend, reply[2] as String);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _feeder?.stop();
    final pipe = _pipe;
    // Unblock a starved av_read_frame BEFORE asking the worker to close.
    if (pipe != null) _shim!.bytepipeClose(pipe);
    try {
      // Bounded: if the worker isolate already died (e.g. a native FFmpeg
      // crash on corrupt input — no onExit listener is registered), the
      // 'close' reply never arrives and awaiting it would hang forever.
      await _request(['close']).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Worker may already be gone, or timed out — proceed to force teardown.
    }
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          const CodecRuntimeException(_kBackend, 'demuxer closed'),
        );
      }
    }
    _pending.clear();
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    if (pipe != null) _shim!.bytepipeDestroy(pipe);
  }
}

Future<void> _demuxWorkerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final mode = args[1] as String;

  final FfmpegDemuxer dem;
  try {
    final loaded = await ensureFFmpegLoaded();
    if (!loaded) {
      toMain.send(['error', 'FFmpeg failed to load in worker isolate']);
      return;
    }
    dem = switch (mode) {
      'file' => FfmpegDemuxer.openUrl(args[2] as String),
      'bytes' => FfmpegDemuxer.openBytes(
        (args[2] as TransferableTypedData).materialize().asUint8List(),
      ),
      _ => FfmpegDemuxer.openPipe(
        Pointer<Void>.fromAddress(args[2] as int),
        ownsPipe: false, // main isolate owns + destroys
      ),
    };
  } catch (e) {
    toMain.send(['error', 'demuxer open failed in worker: $e']);
    return;
  }

  final commands = ReceivePort();
  toMain.send([
    'ready',
    commands.sendPort,
    dem.tracks, // plain const objects — isolate-sendable
    dem.durationUs,
    dem.isSeekable,
  ]);

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'read':
          final pkt = await dem.readPacket();
          toMain.send([
            'pkt',
            id,
            pkt != null,
            pkt != null ? TransferableTypedData.fromList([pkt.data]) : null,
            pkt?.ptsUs ?? 0,
            pkt?.dtsUs ?? 0,
            pkt?.durationUs ?? 0,
            pkt?.isKeyframe ?? false,
            pkt?.trackIndex ?? 0,
          ]);
        case 'seek':
          await dem.seek(msg[2] as int);
          toMain.send(['ok', id]);
        case 'close':
          try {
            await dem.close();
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
