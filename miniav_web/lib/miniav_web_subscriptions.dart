part of 'miniav_web.dart';

/// Web-side device-change subscription helper.
///
/// Listens to `navigator.mediaDevices.ondevicechange`, re-enumerates devices,
/// diffs against the previous snapshot (filtered by [kind]), and fires
/// add/remove events. One instance per module/kind is shared across all
/// listeners.
class _WebDeviceChangeWatcher {
  _WebDeviceChangeWatcher({required this.kind, required this.deviceFactory});

  /// MediaDeviceInfo.kind to filter on, e.g. 'videoinput', 'audioinput',
  /// 'audiooutput'.
  final String kind;

  /// Convert a [web.MediaDeviceInfo] into a [MiniAVDeviceInfo].
  final MiniAVDeviceInfo Function(web.MediaDeviceInfo info, bool isDefault)
  deviceFactory;

  final List<MiniAVDeviceChangeListener> _listeners =
      <MiniAVDeviceChangeListener>[];
  Map<String, MiniAVDeviceInfo> _last = <String, MiniAVDeviceInfo>{};
  JSFunction? _jsHandler;

  void Function() add(MiniAVDeviceChangeListener listener) {
    _listeners.add(listener);
    if (_jsHandler == null) {
      _jsHandler = ((JSAny? _) {
        _refresh();
      }).toJS;
      web.window.navigator.mediaDevices.addEventListener(
        'devicechange',
        _jsHandler,
      );
      // Seed snapshot.
      _refresh(suppressEvents: true);
    }
    return () => _remove(listener);
  }

  void _remove(MiniAVDeviceChangeListener listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty && _jsHandler != null) {
      web.window.navigator.mediaDevices.removeEventListener(
        'devicechange',
        _jsHandler,
      );
      _jsHandler = null;
      _last = <String, MiniAVDeviceInfo>{};
    }
  }

  Future<void> _refresh({bool suppressEvents = false}) async {
    try {
      final devices = await web.window.navigator.mediaDevices
          .enumerateDevices()
          .toDart;
      final next = <String, MiniAVDeviceInfo>{};
      var idx = 0;
      for (final d in devices.toDart) {
        if (d.kind != kind) continue;
        next[d.deviceId] = deviceFactory(d, idx == 0);
        idx++;
      }

      if (suppressEvents) {
        _last = next;
        return;
      }

      final snapshot = List<MiniAVDeviceChangeListener>.from(_listeners);

      // Removed
      for (final entry in _last.entries) {
        if (!next.containsKey(entry.key)) {
          final notif = MiniAVDeviceChangeNotification(
            MiniAVDeviceChangeEvent.removed,
            entry.value,
          );
          for (final l in snapshot) {
            try {
              l(notif);
            } catch (_) {}
          }
        }
      }
      // Added
      for (final entry in next.entries) {
        if (!_last.containsKey(entry.key)) {
          final notif = MiniAVDeviceChangeNotification(
            MiniAVDeviceChangeEvent.added,
            entry.value,
          );
          for (final l in snapshot) {
            try {
              l(notif);
            } catch (_) {}
          }
        }
      }

      _last = next;
    } catch (_) {
      // Ignore enumeration failures.
    }
  }
}
