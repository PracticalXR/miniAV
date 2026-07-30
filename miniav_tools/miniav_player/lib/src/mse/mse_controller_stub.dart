/// Native stub for [MseController] — MSE / `<video>` playback is web-only. This
/// keeps `mse_controller.dart` (which imports `dart:js_interop` / `package:web`
/// / `dart:ui_web`) out of native builds via conditional import. Every entry
/// point reports unsupported; nothing here should run on native (callers gate on
/// [MseController.isSupportedPlatform]).
library;

import 'dart:async';
import 'dart:typed_data';

class MseController {
  /// Always false off-web.
  static bool get isSupportedPlatform => false;

  static bool isTypeSupported(String mimeWithCodecs) => false;

  factory MseController.blob(Uint8List bytes, {required String mimeType}) =>
      throw UnsupportedError('MSE playback is only available on web');

  factory MseController.stream({required String mimeWithCodecs}) =>
      throw UnsupportedError('MSE playback is only available on web');

  String get viewType => throw UnsupportedError('MSE playback is web-only');
  Future<void> get onReady => Future<void>.error(
      UnsupportedError('MSE playback is web-only'));
  Stream<void> get onEnded => const Stream<void>.empty();
  Future<void> get onFirstFrame =>
      Future<void>.error(UnsupportedError('MSE playback is web-only'));
  Stream<Object> get onError => const Stream<Object>.empty();
  set muted(bool value) {}
  Future<void> appendBytes(Uint8List segment) async {}
  void endOfStream() {}
  Future<bool> play() async => false;
  void pause() {}
  Future<void> seek(Duration position) async {}
  Duration get position => Duration.zero;
  Duration? get duration => null;
  bool get isEnded => false;
  void dispose() {}
}
