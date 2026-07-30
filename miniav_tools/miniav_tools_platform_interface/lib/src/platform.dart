/// Registry of registered backends, queried by the facade.
library;

import 'backend.dart';
import 'capability.dart';
import 'codec_types.dart';

/// User preference for backend selection on a per-call basis.
///
/// - [auto]: pick the highest-priority backend that supports the request.
/// - [pinned]: only use the named backend; fail if it can't satisfy.
/// - [excluded]: try any backend except the listed ones.
sealed class BackendPreference {
  const BackendPreference();

  static const BackendPreference auto = _AutoBackendPreference();

  factory BackendPreference.pinned(String backendName) =
      PinnedBackendPreference;
  factory BackendPreference.excluded(Set<String> backendNames) =
      ExcludedBackendPreference;
}

class _AutoBackendPreference extends BackendPreference {
  const _AutoBackendPreference();
}

class PinnedBackendPreference extends BackendPreference {
  final String backendName;
  const PinnedBackendPreference(this.backendName);
}

class ExcludedBackendPreference extends BackendPreference {
  final Set<String> backendNames;
  const ExcludedBackendPreference(this.backendNames);
}

/// Process-global registry of installed [MiniAVToolsBackend]s.
///
/// Backends self-register on import (top-level call in their library file).
class MiniAVToolsPlatform {
  MiniAVToolsPlatform._();

  static final MiniAVToolsPlatform instance = MiniAVToolsPlatform._();

  final List<MiniAVToolsBackend> _backends = [];
  final Map<String, int> _priorityOverrides = {};

  /// Memoized [MiniAVToolsBackend.probe] results, keyed by backend + query.
  /// Probe results are stable for a fixed backend set (a backend reports the
  /// same capabilities for the same codec/direction each time — including
  /// native availability checks that don't change within a process), so the
  /// negotiator can reuse them instead of re-probing (and re-loading libs) on
  /// every `createDecoder`/`createEncoder`. Invalidated whenever the registry
  /// changes.
  final Map<String, List<CodecCapability>> _probeCache = {};

  /// Register a backend. Idempotent by backend name.
  void register(MiniAVToolsBackend backend) {
    if (_backends.any((b) => b.name == backend.name)) return;
    _backends.add(backend);
    _probeCache.clear();
  }

  /// Unregister all backends with the given name. Mainly for tests.
  void unregisterByName(String name) {
    _backends.removeWhere((b) => b.name == name);
    _probeCache.clear();
  }

  /// Override the priority of a registered backend by name.
  void setBackendPriority(String name, int priority) {
    _priorityOverrides[name] = priority;
    // Priority feeds ranking, not probe() output, but clear anyway so nothing
    // stale can ever linger.
    _probeCache.clear();
  }

  /// [MiniAVToolsBackend.probe] with memoization (see [_probeCache]). The
  /// negotiator calls this instead of `backend.probe` directly.
  Future<List<CodecCapability>> cachedProbe(
    MiniAVToolsBackend backend,
    CodecQuery query,
  ) async {
    final key = '${backend.name}|${query.direction.name}|'
        '${query.videoCodec?.name}|${query.audioCodec?.name}|'
        '${query.container?.name}|${query.customName}';
    final hit = _probeCache[key];
    if (hit != null) return hit;
    final caps = List<CodecCapability>.unmodifiable(await backend.probe(query));
    _probeCache[key] = caps;
    return caps;
  }

  /// Snapshot of installed backends (read-only).
  List<MiniAVToolsBackend> get backends => List.unmodifiable(_backends);

  int _priorityOf(MiniAVToolsBackend b) =>
      _priorityOverrides[b.name] ?? b.priority;

  /// Effective priority of [b] including any override set via
  /// [setBackendPriority]. Exposed so the facade's negotiator can tie-break
  /// ranked capabilities deterministically (`List.sort` is not stable).
  int priorityOf(MiniAVToolsBackend b) => _priorityOf(b);

  /// Backends in priority order (highest first), filtered by [pref].
  Iterable<MiniAVToolsBackend> orderedBackends(BackendPreference pref) sync* {
    final filtered = switch (pref) {
      _AutoBackendPreference() => _backends,
      PinnedBackendPreference(:final backendName) =>
        _backends.where((b) => b.name == backendName).toList(),
      ExcludedBackendPreference(:final backendNames) =>
        _backends.where((b) => !backendNames.contains(b.name)).toList(),
    };
    final sorted = [...filtered]
      ..sort((a, b) => _priorityOf(b).compareTo(_priorityOf(a)));
    yield* sorted;
  }

  /// Discovery helpers for inspection / UI.
  Set<VideoCodec> supportedEncodeCodecs({bool hwAccel = false}) {
    return {
      for (final b in _backends)
        for (final c in VideoCodec.values)
          if (b.supportsEncode(c, hwAccel: hwAccel)) c,
    };
  }

  Set<VideoCodec> supportedDecodeCodecs({bool hwAccel = false}) {
    return {
      for (final b in _backends)
        for (final c in VideoCodec.values)
          if (b.supportsDecode(c, hwAccel: hwAccel)) c,
    };
  }

  Set<Container> supportedMuxContainers() {
    return {
      for (final b in _backends)
        for (final c in Container.values)
          if (b.supportsMux(c)) c,
    };
  }
}
