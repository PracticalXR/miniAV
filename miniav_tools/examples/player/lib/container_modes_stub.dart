/// Web stub for the native-only Phase-2 container modes.
///
/// The `stream` / `file` modes demux an fMP4 byte-stream / MP4 file with the
/// FFmpeg muxer and `dart:io`, neither of which exists on the web. On web the
/// unified demo only ever runs the cross-platform `packet` path, so these
/// symbols are never invoked — they exist purely to satisfy the compiler.
library;

/// Container modes are unavailable on this platform.
const bool containerModesSupported = false;

/// No GPU adapter binding needed on web (the player presents to a canvas).
void preInitNativeGpu() {}

/// Never reached on web (guarded by [containerModesSupported]).
void runContainerApp(String mode, List<String> args) =>
    throw UnsupportedError('Container modes ($mode) are native-only');
