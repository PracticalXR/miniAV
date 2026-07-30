import '../miniav_platform_types.dart';

/// Abstract interface for input injection (event replay) on all platforms —
/// the sink twin of input capture. Replays synthetic keyboard/mouse events
/// onto the local machine (the server side of a remote-desktop stack).
///
/// Desktop only. On web there is no injection API, so [createContext] throws.
abstract class MiniInjectPlatformInterface {
  /// Create an input injection context.
  Future<MiniInjectContextPlatformInterface> createContext();
}

/// Abstract injection context for replaying synthetic input events.
abstract class MiniInjectContextPlatformInterface {
  /// Prepare the injector for the given input types (bitmask of
  /// [MiniAVInputType] values — keyboard/mouse). On Linux this creates the
  /// backing uinput virtual device.
  Future<void> configure(int inputTypes);

  /// Inject a keyboard event. Codes are platform-native (Windows VK / macOS
  /// keycode / Linux evdev), matching what capture reports.
  Future<void> injectKeyboard(MiniAVKeyboardEvent event);

  /// Inject a mouse event. For [MiniAVMouseAction.move], honors
  /// [MiniAVMouseEvent.isAbsolute] (absolute x/y vs relative deltas).
  Future<void> injectMouse(MiniAVMouseEvent event);

  /// Destroy this injection context and release resources.
  Future<void> destroy();
}
