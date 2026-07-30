import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android MediaProjection consent helper for miniAV screen capture.
///
/// Android's screen-capture consent is an Activity round-trip that native code
/// cannot perform. This helper drives that flow from the Flutter side and hands
/// the resulting `MediaProjection` to the pure-FFI native layer (miniav_c) via a
/// small Kotlin/JNI plugin piece (see the package's `android/` sources and
/// `miniav_ffi/miniav_c/MOBILE_PLATFORM_SPEC.md` §3/§6).
///
/// ## Flow
///
/// 1. Call [requestScreenCapture] and await it. This shows the system consent
///    dialog, starts the required `mediaProjection`-typed foreground service,
///    and — on grant — hands the projection to native.
/// 2. Only *after* it returns `true` will the MiniAV screen-capture APIs
///    (`MiniAVScreen.configureDisplay` / `startCapture`) succeed on Android.
///    If the consent step was skipped or denied, native returns
///    `MINIAV_ERROR_PERMISSION_DENIED` from Configure/Start.
/// 3. When you are done, call [stopScreenCapture] (this also stops the
///    foreground service and clears native state).
///
/// Listen to [onProjectionStopped] to learn when the user revoked the
/// projection from the status bar or the system stopped it — that is the
/// authoritative stop signal (miniAV's native `lost_cb` also fires).
///
/// All methods are safe to call on non-Android platforms: [requestScreenCapture]
/// resolves to `false` and the others are no-ops.
class MiniAVAndroidScreenConsent {
  MiniAVAndroidScreenConsent._();

  static const MethodChannel _channel = MethodChannel('miniav_flutter');

  static final StreamController<void> _stopController =
      StreamController<void>.broadcast(
    onListen: _ensureHandler,
  );

  static bool _handlerInstalled = false;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onProjectionStop') {
      if (!_stopController.isClosed) {
        _stopController.add(null);
      }
    }
    return null;
  }

  /// Requests Android screen-capture consent.
  ///
  /// Shows the system MediaProjection consent dialog, starts the typed
  /// foreground service, and — on grant — hands the projection to the native
  /// miniAV layer. Returns `true` if consent was granted and the projection was
  /// successfully handed off, `false` if the user cancelled (or on any
  /// non-Android platform).
  ///
  /// After a `true` result, `MiniAVScreen` Configure/Start calls will work on
  /// Android. Throws a [PlatformException] if the native handoff fails after a
  /// grant (rare — e.g. the foreground service could not start).
  static Future<bool> requestScreenCapture() async {
    if (!Platform.isAndroid) return false;
    _ensureHandler();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'requestMediaProjection',
    );
    return result?['granted'] == true;
  }

  /// Stops the active screen-capture projection.
  ///
  /// Stops the projection, clears native state (NULLs), and stops the
  /// foreground service. Safe to call when nothing is active, and a no-op on
  /// non-Android platforms.
  static Future<void> stopScreenCapture() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopMediaProjection');
  }

  /// Fires when the projection is stopped outside of [stopScreenCapture] — the
  /// user revoked it from the status bar, or the system stopped it. This is the
  /// authoritative stop signal for the consent layer; you should tear down your
  /// MiniAV screen-capture context in response.
  ///
  /// Never emits on non-Android platforms.
  static Stream<void> get onProjectionStopped => _stopController.stream;
}
