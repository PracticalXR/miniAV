import 'package:miniav_platform_interface/miniav_platform_interface.dart';

/// Input injection (event replay) — the sink twin of [MiniInput]. Replays
/// synthetic keyboard/mouse events onto the LOCAL machine (the server side of
/// a remote-desktop stack). Desktop only.
///
/// Permissions (miniAV never prompts — a missing permission surfaces as an
/// error): macOS needs Accessibility approval; Linux needs write access to
/// `/dev/uinput` (a udev rule or root). Windows needs none (SendInput).
class MiniInject {
  MiniInject();

  static MiniInjectPlatformInterface get _platform =>
      MiniAVPlatformInterface.instance.inject;

  /// Create an input injection context.
  static Future<MiniInjectContext> createContext() async {
    final context = await _platform.createContext();
    return MiniInjectContext._(context);
  }
}

/// Injection context for replaying synthetic input events.
class MiniInjectContext {
  final MiniInjectContextPlatformInterface _context;

  MiniInjectContext._(this._context);

  /// Prepare the injector for the given input types (bitmask of
  /// [MiniAVInputType] values — keyboard/mouse). On Linux this creates the
  /// backing uinput virtual device.
  Future<void> configure(int inputTypes) => _context.configure(inputTypes);

  /// Inject a keyboard event. Codes are platform-native (Windows VK / macOS
  /// keycode / Linux evdev), matching what [MiniInput] capture reports — so a
  /// captured event can be replayed verbatim on the same platform.
  Future<void> injectKeyboard(MiniAVKeyboardEvent event) =>
      _context.injectKeyboard(event);

  /// Inject a mouse event. For [MiniAVMouseAction.move], honors
  /// [MiniAVMouseEvent.isAbsolute] (absolute x/y vs relative deltas).
  Future<void> injectMouse(MiniAVMouseEvent event) =>
      _context.injectMouse(event);

  /// Destroy the context and release resources.
  Future<void> destroy() => _context.destroy();
}
