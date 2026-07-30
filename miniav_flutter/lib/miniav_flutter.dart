/// Flutter companion for miniav.
///
/// Re-exports the full `miniav` public API so that `package:miniav_flutter`
/// can be used as a drop-in replacement for `package:miniav` in Flutter apps.
///
/// Additionally provides [MiniAVBinding], a thin root widget whose
/// [State.reassemble] automatically calls [MiniAV.dispose] during Flutter
/// hot reload.  This prevents the `"Callback invoked after it has been deleted"`
/// fatal crash that occurs when native capture threads still hold live
/// `NativeCallable` function pointers while the Dart isolate is being rebuilt.
///
/// ## Usage
///
/// Wrap your root widget with [MiniAVBinding]:
///
/// ```dart
/// void main() {
///   runApp(const MiniAVBinding(child: MyApp()));
/// }
/// ```
///
/// That is the only change required.  Remove any manual `reassemble()`
/// overrides that previously called `MiniAV.dispose()`.
///
/// ## Android screen-capture consent
///
/// On Android, screen capture requires a MediaProjection consent round-trip
/// that native code cannot perform.  [MiniAVAndroidScreenConsent] drives that
/// flow and hands the projection to the native layer:
///
/// ```dart
/// if (await MiniAVAndroidScreenConsent.requestScreenCapture()) {
///   // MiniAV screen Configure/Start now works on Android.
/// }
/// ```
library;

export 'package:miniav/miniav.dart';
export 'src/miniav_android_screen_consent.dart';
export 'src/miniav_flutter_binding.dart';
