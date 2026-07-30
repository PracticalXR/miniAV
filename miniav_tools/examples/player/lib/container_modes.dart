/// Platform selector for the native-only Phase-2 container modes.
///
/// On native (`dart.library.io`) this resolves to the FFmpeg muxer / demux
/// smoke app; on web it resolves to a stub so the web build never references
/// `dart:io` or the FFmpeg bridge. The unified `main.dart` only dispatches into
/// these symbols when `containerModesSupported` is true.
library;

export 'container_modes_stub.dart'
    if (dart.library.io) 'container_modes_io.dart';
