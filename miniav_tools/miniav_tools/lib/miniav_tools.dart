/// User-facing facade for miniav_tools.
///
/// Backends register themselves with [MiniAVToolsPlatform] when their package
/// is imported. This facade routes user requests to the
/// highest-priority backend that supports the request.
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'src/encoder.dart';
import 'src/audio_encoder.dart';
import 'src/audio_decoder.dart';
import 'src/decoder.dart';
import 'src/muxer.dart';
import 'src/demuxer.dart';

export 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

export 'src/encoder.dart';
export 'src/audio_encoder.dart';
export 'src/audio_decoder.dart';
export 'src/audio_source.dart';
export 'src/decoder.dart';
export 'src/muxer.dart';
export 'src/demuxer.dart';

/// Static facade. All factory methods route through
/// [MiniAVToolsPlatform.instance] and try each registered backend in priority
/// order until one succeeds.
class MiniAVTools {
  MiniAVTools._();

  /// All registered backends (snapshot; immutable).
  static List<MiniAVToolsBackend> get backends =>
      MiniAVToolsPlatform.instance.backends;

  /// Create a video encoder — **negotiated** (same probe→filter→rank→open flow
  /// as [createDecoder]).
  ///
  /// Every eligible backend is probed for its concrete [CodecCapability]s,
  /// filtered by [hwPreference] (path exclude / zero-copy / HW mode), ranked
  /// (hardware → explicit path order → zero-copy → score → backend priority →
  /// init cost), and opened best-first. Each candidate opens on EXACTLY its
  /// ranked path — `config.copyWith(hwAccel: cap.isHardware ? required :
  /// forbidden)` — so the [Encoder.capability] attached to the result is honest
  /// (a backend that reported a HW cap can't silently fall back to SW). A failed
  /// HW open drops through to the next-ranked candidate.
  ///
  /// [hwPreference] defaults to one derived from `config.hwAccel`; pass an
  /// explicit [HwPreference] for the richer knobs (`order`, `exclude`,
  /// `requireZeroCopy`). [preference] (`excluded`/`pinned`) is honored
  /// identically to decode.
  ///
  /// Throws [NoBackendForCodecException] if no backend supports [config.codec].
  /// Throws [CodecInitException] if a candidate was selected but failed to open.
  static Future<Encoder> createEncoder(
    EncoderConfig config, {
    BackendPreference preference = BackendPreference.auto,
    BackendContext? context,
    HwPreference? hwPreference,
  }) async {
    final hw = hwPreference ?? HwPreference.fromMode(config.hwAccel);
    final candidates = await _negotiateCandidates(
      CodecQuery.video(config.codec, CodecDirection.encode,
          customName: config.customCodecName),
      hw,
      preference,
    );

    Object? lastInitError;
    for (final cand in candidates) {
      final cap = cand.cap;
      // Honest attach: open on exactly the cap's path so a backend that
      // reported a HW cap can't silently open SW while we attach a HW cap.
      //
      // EXCEPTION — the generic base-probe [HwPath.hardware] cap names no real
      // path and doesn't know whether the device is actually present. Forcing
      // `required` on it would (a) fail on boxes without that HW and (b)
      // pre-empt a backend's own HW→SW fallback and the caller's options that
      // were tuned to match it (the recorder tunes preset/tune/rate-control by
      // its requested hwAccel). So for the generic cap we pass the caller's
      // original config and let the backend decide, exactly as before this
      // path was negotiated.
      final openConfig = cap.hwPath == HwPath.hardware
          ? config
          : config.copyWith(
              hwAccel: cap.isHardware
                  ? HwAccelPreference.required
                  : HwAccelPreference.forbidden,
            );
      try {
        final platform =
            await cand.backend.createEncoder(openConfig, context: context);
        if (platform == null) continue;
        return Encoder(platform, cand.backend.name, capability: cap);
      } on CodecInitException catch (e) {
        lastInitError = e;
        continue;
      }
    }
    if (lastInitError is CodecInitException) {
      throw lastInitError;
    }
    throw NoBackendForCodecException.video(
      config.codec,
      hwAccel: hw.prefersHardware,
    );
  }

  /// Create an audio encoder — **negotiated**. Throws
  /// [NoBackendForCodecException] if no registered backend supports
  /// [config.codec].
  ///
  /// Audio configs carry no `hwAccel`, so the default [HwPreference] (`preferred`)
  /// lets a backend that reports a hardware/OS audio capability (e.g. a future
  /// Media Foundation AAC encoder) out-rank a software one; `excluded`/`pinned`
  /// [preference] and `requireZeroCopy` (via [hwPreference]) work as for decode.
  static Future<AudioEncoder> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendPreference preference = BackendPreference.auto,
    BackendContext? context,
    HwPreference? hwPreference,
  }) async {
    final candidates = await _negotiateCandidates(
      CodecQuery.audio(config.codec, CodecDirection.encode),
      hwPreference ?? const HwPreference(),
      preference,
    );
    Object? lastInitError;
    for (final cand in candidates) {
      try {
        final platform = await cand.backend.createAudioEncoder(
          config,
          context: context,
        );
        if (platform == null) continue;
        return AudioEncoder(platform, cand.backend.name, capability: cand.cap);
      } on CodecInitException catch (e) {
        lastInitError = e;
        continue;
      }
    }
    if (lastInitError is CodecInitException) {
      throw lastInitError;
    }
    throw NoBackendForCodecException.audio(config.codec);
  }

  /// Create an audio decoder — **negotiated**. Throws
  /// [NoBackendForCodecException] if no registered backend supports
  /// [config.codec].
  ///
  /// Selection honors `excluded`/`pinned` [preference] and prefers a
  /// hardware/OS audio capability over software (via the default
  /// [HwPreference]); the chosen [CodecCapability] is attached to the result.
  static Future<AudioDecoder> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendPreference preference = BackendPreference.auto,
    BackendContext? context,
    HwPreference? hwPreference,
  }) async {
    final candidates = await _negotiateCandidates(
      CodecQuery.audio(config.codec, CodecDirection.decode),
      hwPreference ?? const HwPreference(),
      preference,
    );
    Object? lastInitError;
    for (final cand in candidates) {
      try {
        final platform = await cand.backend.createAudioDecoder(
          config,
          context: context,
        );
        if (platform == null) continue;
        return AudioDecoder(platform, cand.backend.name, capability: cand.cap);
      } on CodecInitException catch (e) {
        lastInitError = e;
        continue;
      }
    }
    if (lastInitError is CodecInitException) {
      throw lastInitError;
    }
    throw NoBackendForCodecException.audio(config.codec);
  }

  /// Create a video decoder — **negotiated**.
  ///
  /// Rather than the plain priority scan the other factories use, this probes
  /// every eligible backend for its concrete [CodecCapability]s, filters them
  /// by [hwPreference] (path exclude / zero-copy / HW mode), ranks them
  /// (hardware → explicit path order → zero-copy → score → backend priority →
  /// init cost), and opens them best-first. The chosen capability is attached
  /// to the returned [Decoder] (`decoder.capability`) so consumers pick their
  /// frame path deterministically — e.g. take the GPU-texture branch when
  /// `producedOutputs` contains `d3d11Texture`, with no first-frame probing.
  ///
  /// [hwPreference] defaults to one derived from `config.hwAccel`, so existing
  /// callers keep working unchanged. Pass an explicit [HwPreference] to use the
  /// richer knobs (path `order`, `exclude`, `requireZeroCopy`).
  static Future<Decoder> createDecoder(
    DecoderConfig config, {
    BackendPreference preference = BackendPreference.auto,
    BackendContext? context,
    HwPreference? hwPreference,
  }) async {
    final hw = hwPreference ?? HwPreference.fromMode(config.hwAccel);
    final candidates = await _negotiateCandidates(
      CodecQuery.video(config.codec, CodecDirection.decode,
          customName: config.customCodecName),
      hw,
      preference,
    );

    Object? lastInitError;
    for (final cand in candidates) {
      // Open the candidate on EXACTLY its ranked path so the attached
      // capability is honest: pin hwAccel to the cap's HW/SW-ness (a backend
      // that reported a HW cap must open HW, not silently fall back to SW).
      // A HW open that fails drops through to the next-ranked candidate below.
      final openConfig = config.copyWith(
        hwAccel: cand.cap.isHardware
            ? HwAccelPreference.required
            : HwAccelPreference.forbidden,
      );
      try {
        final platform = await cand.backend.createDecoder(
          openConfig,
          context: context,
        );
        if (platform == null) continue;
        return Decoder(platform, cand.backend.name, capability: cand.cap);
      } on CodecInitException catch (e) {
        // Don't give up on the first failure — the next-ranked path may open
        // (e.g. nvdec fails → d3d11va succeeds). Only surface the error if
        // nothing opens at all.
        lastInitError = e;
        continue;
      }
    }
    if (lastInitError is CodecInitException) {
      throw lastInitError;
    }
    throw NoBackendForCodecException.video(
      config.codec,
      hwAccel: hw.prefersHardware,
    );
  }

  /// Create a container muxer — **negotiated** (honors `excluded`/`pinned`
  /// [preference] so a first-party muxer is selectable over FFmpeg).
  static Future<Muxer> createMuxer(
    MuxerConfig config, {
    BackendPreference preference = BackendPreference.auto,
  }) async {
    final candidates = await _negotiateCandidates(
      CodecQuery.container(config.container, CodecDirection.mux),
      const HwPreference(),
      preference,
    );
    for (final cand in candidates) {
      final platform = await cand.backend.createMuxer(config);
      if (platform == null) continue;
      return Muxer(platform, cand.backend.name, capability: cand.cap);
    }
    throw NoBackendForCodecException.container(config.container);
  }

  /// Create a container demuxer.
  ///
  /// When [config.container] is known this is **negotiated** (honors
  /// `excluded`/`pinned` [preference] so a first-party demuxer is selectable
  /// over FFmpeg). When it is `null` (auto-probe), the container can't be
  /// negotiated up front, so we fall back to an ordered scan and let each
  /// backend sniff the input.
  static Future<Demuxer> createDemuxer(
    DemuxerConfig config, {
    BackendPreference preference = BackendPreference.auto,
  }) async {
    if (config.container != null) {
      final candidates = await _negotiateCandidates(
        CodecQuery.container(config.container!, CodecDirection.demux),
        const HwPreference(),
        preference,
      );
      for (final cand in candidates) {
        final platform = await cand.backend.createDemuxer(config);
        if (platform == null) continue;
        return Demuxer(platform, cand.backend.name, capability: cand.cap);
      }
      throw NoBackendForCodecException.container(config.container!);
    }

    // Auto-probe: container unknown, so let each backend sniff the input.
    for (final backend in MiniAVToolsPlatform.instance.orderedBackends(
      preference,
    )) {
      final platform = await backend.createDemuxer(config);
      if (platform == null) continue;
      return Demuxer(platform, backend.name);
    }
    throw NoBackendForCodecException.container(
      config.container ?? Container.mp4,
    );
  }

  // -------------------------------------------------------------------------
  // Negotiation engine (probe → filter → rank)
  // -------------------------------------------------------------------------

  /// Probe every eligible backend for [query], flatten their capabilities,
  /// filter by [hw], and rank best-first. The caller opens candidates in order
  /// and attaches the chosen [CodecCapability] to the returned wrapper.
  static Future<List<_RankedCap>> _negotiateCandidates(
    CodecQuery query,
    HwPreference hw,
    BackendPreference pref,
  ) async {
    final ordered = MiniAVToolsPlatform.instance.orderedBackends(pref).toList();
    final byName = {for (final b in ordered) b.name: b};

    final cands = <_RankedCap>[];
    for (final b in ordered) {
      for (final cap in await MiniAVToolsPlatform.instance.cachedProbe(
        b,
        query,
      )) {
        // Trust the capability's self-reported backend name (a backend may
        // report on behalf of a delegate); fall back to the probed backend.
        cands.add(_RankedCap(byName[cap.backendName] ?? b, cap));
      }
    }

    final filtered = cands.where((rc) {
      final c = rc.cap;
      // Custom codecs match by NAME: a capability for a different custom
      // codec (or a query for one) never pairs up.
      if (query.customName != c.customName) return false;
      if (hw.exclude.contains(c.hwPath)) return false;
      if (hw.requireZeroCopy && !c.zeroCopy) return false;
      if (hw.forbidsHardware && c.isHardware) return false;
      if (hw.requiresHardware && !c.isHardware) return false;
      return true;
    }).toList();

    filtered.sort((a, b) => _compareCaps(a, b, hw));
    return filtered;
  }

  /// Best-first comparator for two candidates under preference [hw].
  static int _compareCaps(_RankedCap a, _RankedCap b, HwPreference hw) {
    final ca = a.cap, cb = b.cap;
    // 1. Hardware first — but only when the caller actually wants HW. In
    //    `allowed`/`forbidden` modes HW gets no inherent edge here.
    if (hw.prefersHardware && ca.isHardware != cb.isHardware) {
      return ca.isHardware ? -1 : 1;
    }
    // 2. Explicit path order, e.g. [nvdec, d3d11va]. Listed paths beat
    //    unlisted; unlisted paths tie at the end.
    final oa = _orderIndex(hw.order, ca.hwPath);
    final ob = _orderIndex(hw.order, cb.hwPath);
    if (oa != ob) return oa - ob;
    // 3. Zero-copy (GPU-resident) paths before readback paths.
    if (ca.zeroCopy != cb.zeroCopy) return ca.zeroCopy ? -1 : 1;
    // 4. Higher backend-defined quality/preference score.
    if (ca.score != cb.score) return cb.score - ca.score;
    // 5. Higher effective backend priority (respects setBackendPriority).
    final pa = MiniAVToolsPlatform.instance.priorityOf(a.backend);
    final pb = MiniAVToolsPlatform.instance.priorityOf(b.backend);
    if (pa != pb) return pb - pa;
    // 6. Cheaper to open wins remaining ties.
    return ca.initCostHint - cb.initCostHint;
  }

  /// Rank of [p] within an explicit [order]; unlisted paths sort last, and a
  /// null order makes every path tie (so later keys decide).
  static int _orderIndex(List<HwPath>? order, HwPath p) {
    if (order == null) return 0;
    final i = order.indexOf(p);
    return i < 0 ? order.length : i;
  }

  // -------------------------------------------------------------------------
  // Warmup
  // -------------------------------------------------------------------------

  /// Run all registered backends' warmup tasks in parallel and merge their
  /// progress events into a single stream.
  ///
  /// Call this **once at application start** before the first
  /// encoder/muxer creation. On a cold start — for example, when FFmpeg
  /// shared libraries need to be downloaded — this lets you show a progress
  /// indicator instead of blocking silently inside `createEncoder`.
  ///
  /// The returned stream completes (`onDone`) when every backend finishes
  /// its warmup (or skips it). Each event carries [WarmupProgress.backendName]
  /// so you can attribute progress to a specific backend.
  ///
  /// The stream never errors: backend failures are delivered as
  /// [WarmupProgress] events with [WarmupProgress.error] set.
  ///
  /// ### Flutter example
  ///
  /// ```dart
  /// @override
  /// void initState() {
  ///   super.initState();
  ///   MiniAVTools.warmup().listen(
  ///     (p) => setState(() => _warmupProgress = p),
  ///     onDone: () => setState(() => _ready = true),
  ///   );
  /// }
  /// ```
  ///
  /// ### Command-line / background example
  ///
  /// ```dart
  /// await MiniAVTools.warmup().last; // block until all warmup is done
  /// ```
  ///
  /// If no backends are registered the stream completes immediately.
  static Stream<WarmupProgress> warmup() {
    final backends = MiniAVToolsPlatform.instance.backends;
    if (backends.isEmpty) return const Stream.empty();
    if (backends.length == 1) return _guardedWarmup(backends.first);

    // Fan out to all backends in parallel and merge into one stream.
    final ctrl = StreamController<WarmupProgress>();
    var remaining = backends.length;

    for (final backend in backends) {
      _guardedWarmup(backend).listen(
        ctrl.add,
        onDone: () {
          if (--remaining == 0) ctrl.close();
        },
        // _guardedWarmup never errors — errors are already converted to events.
        cancelOnError: false,
      );
    }

    return ctrl.stream;
  }

  /// Wraps a single backend's [warmup] stream so that stream errors are
  /// converted to [WarmupProgress] events and the stream always completes.
  static Stream<WarmupProgress> _guardedWarmup(MiniAVToolsBackend backend) {
    final ctrl = StreamController<WarmupProgress>();

    backend.warmup().listen(
      ctrl.add,
      onError: (Object e, StackTrace _) {
        ctrl.add(
          WarmupProgress(
            backendName: backend.name,
            task: 'warmup',
            isDone: true,
            error: e,
          ),
        );
      },
      onDone: ctrl.close,
      cancelOnError: false,
    );

    return ctrl.stream;
  }
}

/// A filtered, ranked negotiation candidate: the backend that will open it and
/// the [CodecCapability] the facade chose (attached to the returned wrapper).
class _RankedCap {
  final MiniAVToolsBackend backend;
  final CodecCapability cap;
  const _RankedCap(this.backend, this.cap);
}
