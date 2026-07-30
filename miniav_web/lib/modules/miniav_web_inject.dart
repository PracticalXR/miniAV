part of '../miniav_web.dart';

/// Web has no input-injection API — there is no way to synthesize OS-level
/// keyboard/mouse events from a browser sandbox. [createContext] throws.
class MiniAVWebInjectPlatform implements MiniInjectPlatformInterface {
  @override
  Future<MiniInjectContextPlatformInterface> createContext() =>
      throw UnsupportedError('Input injection is not supported on web.');
}
