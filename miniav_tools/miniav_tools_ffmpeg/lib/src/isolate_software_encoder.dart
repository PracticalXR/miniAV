/// Isolate-hosted video encoder (software, or CPU-fed hardware).
///
/// [FfmpegSoftwareEncoder] / [FfmpegHwEncoder] perform their libav calls
/// (`avcodec_send_frame` / `avcodec_receive_packet`, plus the one-time
/// `avcodec_open2` init) synchronously on the calling isolate. On the
/// recorder's fallback path that isolate is the Flutter UI isolate, so:
///   * a 2560×720 openh264/SVT encode takes tens of ms per frame — the app
///     visibly freezes while recording; and
///   * QSV / MediaFoundation encoder init fails outright, because their COM
///     objects require the MTA apartment and Flutter's UI isolate is STA
///     (`miniav_shim_ensure_mta` → `RPC_E_CHANGED_MODE`).
///
/// This class wraps the encoder in a long-lived worker isolate: frames cross
/// as [TransferableTypedData] (one copy, then zero-copy ownership transfer),
/// packets come back the same way, and the UI isolate only pays the transfer
/// cost (~1 ms/frame at 720p) instead of the encode cost. The worker's thread
/// is a fresh OS thread, so it can enter the MTA apartment — which is what
/// finally lets QSV / MediaFoundation initialise.
///
/// When [open] is given a [hwVendorOrder], the worker first tries each
/// CPU-fed hardware vendor in turn ([FfmpegHwEncoder.openWith], which is
/// stopped at the first that opens), then falls back to the software encoder
/// (unless `requireHardware`). This is NOT the zero-copy D3D11 path — frames
/// arrive in system memory (RGBA) and the vendor MFT/SDK uploads them — so it
/// works from an isolate without any cross-isolate texture sharing, at the
/// cost of a read-back.
///
/// This package is native-only (it imports `dart:ffi` throughout), so using
/// `dart:isolate` here does not affect web builds — the web backend lives in
/// `miniav_tools_codecs (web.dart)`.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:miniav_platform_interface/miniav_platform_types.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'ffmpeg_bindings.dart' show ensureFFmpegLoaded;
import 'ffmpeg_encoder.dart';
import 'ffmpeg_hw_encoder.dart';
import 'ffmpeg_log.dart';

/// Encoder hosted on a dedicated worker isolate. Public API is identical to
/// [PlatformEncoder]; construction is async ([open]). Despite the name it may
/// host either the software encoder or a CPU-fed hardware encoder (see
/// [open]'s `hwVendorOrder`); [activeEncoderDescription] reports which.
class IsolateSoftwareEncoder implements PlatformEncoder {
  IsolateSoftwareEncoder._(this._isolate, this._toWorker, this._fromWorker);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  final Map<int, Completer<List<dynamic>>> _pending = {};
  int _nextId = 0;
  bool _closed = false;
  bool _forceKeyframe = false;
  CodecExtraData? _extraData;
  VideoCodec? _codec;
  bool _acceptsYuv420pPlanes = true;
  String _description = 'software';

  /// Spawns the worker isolate, loads FFmpeg there, and opens an encoder for
  /// [cfg]. Throws [CodecInitException] if the worker fails to open one.
  ///
  /// [hwVendorOrder] — when non-null and non-empty, the worker first tries
  /// each CPU-fed hardware vendor in order (stopping at the first that opens)
  /// before the software encoder. The order should already be adapter-aware
  /// (e.g. MediaFoundation before AMF on AMD, where AMF can silently encode
  /// black). Pass `null` for a software-only worker (the historical default).
  ///
  /// [requireHardware] — when true, the worker does NOT fall back to software:
  /// if no hardware vendor opens it reports failure and [open] throws. Maps
  /// from `HwAccelPreference.required`.
  static Future<IsolateSoftwareEncoder> open(
    EncoderConfig cfg, {
    List<HwEncoderVendor>? hwVendorOrder,
    bool requireHardware = false,
  }) async {
    final fromWorker = ReceivePort();
    final handshake = Completer<List<dynamic>>();

    late final IsolateSoftwareEncoder self;
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
        _workerMain,
        [
          fromWorker.sendPort,
          cfg,
          hwVendorOrder?.map((v) => v.index).toList(),
          requireHardware,
        ],
        debugName: 'IsolateSoftwareEncoder(${cfg.codec.name})',
        errorsAreFatal: true,
      );
    } catch (e) {
      fromWorker.close();
      throw CodecInitException('ffmpeg-sw-isolate', 'isolate spawn failed: $e');
    }

    final ready = await handshake.future;
    if (ready[0] != 'ready') {
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      throw CodecInitException('ffmpeg-sw-isolate', ready[1] as String);
    }

    self = IsolateSoftwareEncoder._(
      isolate,
      ready[1] as SendPort,
      fromWorker,
    );
    self._codec = cfg.codec;
    final extra = ready[2] as TransferableTypedData?;
    if (extra != null) {
      self._extraData = CodecExtraData.video(
        cfg.codec,
        extra.materialize().asUint8List(),
      );
    }
    // ready[3] = acceptsYuv420pPlanes (worker's actual encoder), ready[4] =
    // human description (e.g. 'h264_mf (hw)' / 'libopenh264 (sw)').
    self._acceptsYuv420pPlanes = ready.length > 3 ? ready[3] as bool : true;
    self._description = ready.length > 4 ? ready[4] as String : 'software';
    ffmpegToolsLog(
      MiniAVLogLevel.info,
      '[ffmpeg-isolate] worker ready for ${cfg.codec} '
      '${cfg.width}x${cfg.height} — ${self._description} '
      '(yuv420p=${self._acceptsYuv420pPlanes}, extraData: '
      '${self._extraData?.bytes.length ?? 0}B)',
    );
    return self;
  }

  /// Human-readable description of the encoder the worker actually opened,
  /// e.g. `h264_mf (hw)` or `libopenh264 (sw)`.
  String get activeEncoderDescription => _description;

  Future<List<dynamic>> _request(List<dynamic> msg) {
    if (_closed) {
      throw const CodecRuntimeException('ffmpeg-sw-isolate', 'encoder closed');
    }
    final id = _nextId++;
    final completer = Completer<List<dynamic>>();
    _pending[id] = completer;
    _toWorker.send([msg[0], id, ...msg.sublist(1)]);
    return completer.future;
  }

  void _absorbExtra(TransferableTypedData? extra) {
    if (extra == null || _extraData != null) return;
    _extraData = CodecExtraData.video(
      _codec,
      extra.materialize().asUint8List(),
    );
  }

  EncodedPacket? _unpackPacket(List<dynamic> reply) {
    if (reply[0] == 'err') {
      throw CodecRuntimeException('ffmpeg-sw-isolate', reply[2] as String);
    }
    _absorbExtra(reply.length > 7 ? reply[7] as TransferableTypedData? : null);
    if (reply[2] as bool != true) return null;
    return EncodedPacket(
      data: (reply[3] as TransferableTypedData).materialize().asUint8List(),
      ptsUs: reply[4] as int,
      dtsUs: reply[5] as int,
      durationUs: reply[6] as int,
      isKeyframe: reply.length > 8 ? reply[8] as bool : false,
    );
  }

  @override
  Future<EncodedPacket?> encode(FrameSource frame) async {
    final forceKey = _forceKeyframe;
    _forceKeyframe = false;
    switch (frame) {
      case Yuv420pFrameSource():
        // One copy into a transferable, then zero-copy hand-off — required
        // anyway because the recorder's plane buffers are reused per frame.
        final payload = TransferableTypedData.fromList([
          frame.yPlane,
          frame.uPlane,
          frame.vPlane,
        ]);
        return _unpackPacket(
          await _request([
            'encode',
            'yuv',
            frame.width,
            frame.height,
            payload,
            0,
            const <int>[],
            forceKey,
          ]),
        );
      case CpuFrameSource():
        return _unpackPacket(
          await _request([
            'encode',
            'cpu',
            frame.width,
            frame.height,
            TransferableTypedData.fromList([frame.bytes]),
            frame.pixelFormat.index,
            frame.strideBytes ?? const <int>[],
            forceKey,
          ]),
        );
      case MiniAVBufferSource():
        final video = frame.buffer.data;
        if (video is! MiniAVVideoBuffer ||
            video.planes.isEmpty ||
            video.planes[0] == null) {
          throw const CodecRuntimeException(
            'ffmpeg-sw-isolate',
            'MiniAVBufferSource: only CPU plane bytes are supported by the '
                'software encoder (plane[0] was null — likely a GPU buffer)',
          );
        }
        return _unpackPacket(
          await _request([
            'encode',
            'cpu',
            video.width,
            video.height,
            TransferableTypedData.fromList([video.planes[0]!]),
            video.pixelFormat.index,
            video.strideBytes,
            forceKey,
          ]),
        );
      default:
        throw CodecRuntimeException(
          'ffmpeg-sw-isolate',
          'unsupported FrameSource: ${frame.runtimeType}',
        );
    }
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    final reply = await _request(['flush']);
    if (reply[0] == 'err') {
      throw CodecRuntimeException('ffmpeg-sw-isolate', reply[2] as String);
    }
    final datas = (reply[2] as List).cast<TransferableTypedData>();
    final metas = (reply[3] as List).cast<List>();
    return [
      for (var i = 0; i < datas.length; i++)
        EncodedPacket(
          data: datas[i].materialize().asUint8List(),
          ptsUs: metas[i][0] as int,
          dtsUs: metas[i][1] as int,
          durationUs: metas[i][2] as int,
          isKeyframe: metas[i][3] as bool,
        ),
    ];
  }

  @override
  Future<void> requestKeyframe() async => _forceKeyframe = true;

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  bool get supportsGpuBufferInput => false;

  // Reflects the worker's actual encoder: the software encoder consumes
  // YUV420P planes directly (true); the CPU-fed hardware encoder wants RGBA
  // and converts to NV12 itself (false). The recorder branches on this to
  // pick processToYuv420 vs processToBytes.
  @override
  bool get acceptsYuv420pPlanes => _acceptsYuv420pPlanes;

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _request(['close']);
    } catch (_) {
      // Worker may already be gone; proceed with teardown.
    }
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          const CodecRuntimeException('ffmpeg-sw-isolate', 'encoder closed'),
        );
      }
    }
    _pending.clear();
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

/// Worker-isolate entry point. args is a 4-element list:
/// `toMain` (SendPort), `cfg` (EncoderConfig), `hwVendorOrderIndices`
/// (nullable list of HwEncoderVendor indices), `requireHardware` (bool).
Future<void> _workerMain(List<dynamic> args) async {
  final toMain = args[0] as SendPort;
  final cfg = args[1] as EncoderConfig;
  final hwOrderIndices = (args[2] as List?)?.cast<int>();
  final requireHardware = args.length > 3 ? args[3] as bool : false;

  final PlatformEncoder enc;
  final bool acceptsYuv420pPlanes;
  final String description;
  try {
    final loaded = await ensureFFmpegLoaded();
    if (!loaded) {
      toMain.send(['error', 'FFmpeg failed to load in worker isolate']);
      return;
    }

    // 1) CPU-fed hardware, if requested. This worker's thread is a fresh OS
    //    thread, so FfmpegHwEncoder.openWith() can enter the MTA apartment
    //    (via miniav_shim_ensure_mta) that QSV / MediaFoundation require —
    //    the exact init that fails on the STA UI isolate. Try each vendor in
    //    order; stop at the first that opens. Unlike FfmpegHwEncoder.open
    //    (which picks a single present-in-build vendor and gives up if it
    //    fails to open), we loop so a registered-but-nonfunctional vendor
    //    (e.g. NVENC with no NVIDIA GPU) falls through to the next.
    FfmpegHwEncoder? hw;
    if (hwOrderIndices != null && hwOrderIndices.isNotEmpty) {
      final order = hwOrderIndices
          .map((i) => HwEncoderVendor.values[i])
          .toList(growable: false);
      final failures = <String>[];
      for (final vendor in order) {
        try {
          hw = FfmpegHwEncoder.openWith(cfg, vendor); // gpu: null → CPU rescale
          ffmpegToolsLog(
            MiniAVLogLevel.info,
            '[ffmpeg-isolate] worker opened CPU-fed HW encoder '
            '${hw.encoderName} (${vendor.name})',
          );
          break;
        } catch (e) {
          failures.add('${vendor.name}(${e is CodecInitException ? e.message.split('\n').first : e})');
        }
      }
      if (hw == null) {
        ffmpegToolsLog(
          MiniAVLogLevel.warn,
          '[ffmpeg-isolate] worker: no CPU-fed HW vendor opened — '
          'tried ${failures.join(' | ')}',
        );
        if (requireHardware) {
          toMain.send([
            'error',
            'no hardware encoder opened in worker (hwAccel=required): '
                '${failures.join(' | ')}',
          ]);
          return;
        }
      }
    }

    if (hw != null) {
      enc = hw;
      acceptsYuv420pPlanes = hw.acceptsYuv420pPlanes; // false → wants RGBA
      description = '${hw.encoderName} (hw)';
    } else {
      final sw = FfmpegSoftwareEncoder.open(cfg);
      enc = sw;
      acceptsYuv420pPlanes = sw.acceptsYuv420pPlanes; // true → YUV420P planes
      description = 'software (${cfg.codec.name})';
    }
  } catch (e) {
    toMain.send(['error', 'encoder open failed in worker: $e']);
    return;
  }

  final commands = ReceivePort();
  toMain.send([
    'ready',
    commands.sendPort,
    enc.extraData != null
        ? TransferableTypedData.fromList([enc.extraData!.bytes])
        : null,
    acceptsYuv420pPlanes,
    description,
  ]);

  var extraSent = enc.extraData != null;
  TransferableTypedData? pendingExtra() {
    if (extraSent || enc.extraData == null) return null;
    extraSent = true;
    return TransferableTypedData.fromList([enc.extraData!.bytes]);
  }

  await for (final dynamic raw in commands) {
    final msg = raw as List;
    final op = msg[0] as String;
    final id = msg[1] as int;
    try {
      switch (op) {
        case 'encode':
          final kind = msg[2] as String;
          final w = msg[3] as int;
          final h = msg[4] as int;
          final payload = (msg[5] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final pixFmtIndex = msg[6] as int;
          final strides = (msg[7] as List).cast<int>();
          final forceKey = msg[8] as bool;
          if (forceKey) await enc.requestKeyframe();

          final FrameSource src;
          if (kind == 'yuv') {
            final ySize = w * h;
            final uvSize = (w ~/ 2) * (h ~/ 2);
            src = FrameSource.yuv420p(
              yPlane: Uint8List.sublistView(payload, 0, ySize),
              uPlane: Uint8List.sublistView(payload, ySize, ySize + uvSize),
              vPlane: Uint8List.sublistView(
                payload,
                ySize + uvSize,
                ySize + 2 * uvSize,
              ),
              width: w,
              height: h,
            );
          } else {
            src = FrameSource.cpu(
              bytes: payload,
              pixelFormat: MiniAVPixelFormat.values[pixFmtIndex],
              width: w,
              height: h,
              strideBytes: strides.isEmpty ? null : strides,
            );
          }
          final pkt = await enc.encode(src);
          toMain.send([
            'pkt',
            id,
            pkt != null,
            pkt != null ? TransferableTypedData.fromList([pkt.data]) : null,
            pkt?.ptsUs ?? 0,
            pkt?.dtsUs ?? 0,
            pkt?.durationUs ?? 0,
            pendingExtra(),
            pkt?.isKeyframe ?? false,
          ]);
        case 'flush':
          final pkts = await enc.flush();
          toMain.send([
            'pkts',
            id,
            [
              for (final p in pkts) TransferableTypedData.fromList([p.data]),
            ],
            [
              for (final p in pkts)
                [p.ptsUs, p.dtsUs, p.durationUs, p.isKeyframe],
            ],
          ]);
        case 'close':
          try {
            await enc.close();
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
