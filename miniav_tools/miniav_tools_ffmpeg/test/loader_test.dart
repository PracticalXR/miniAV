/// End-to-end auto-download → load test for the FFmpeg backend.
///
/// Opt-in via `MINIAV_TOOLS_FFMPEG_NETTEST=1` because it downloads ~92 MB
/// the first time. Subsequent runs hit the cache and complete in <100 ms.
library;

import 'dart:io';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1';

  test(
    'ensureFFmpegLoaded auto-downloads and DynamicLibrary.open succeeds',
    skip: enabled
        ? null
        : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (~92 MB first run)',
    () async {
      final ok = await ensureFFmpegLoaded();
      expect(
        ok,
        isTrue,
        reason:
            'auto-download + library load should succeed; check '
            'network and stderr for diagnostics',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'second call to ensureFFmpegLoaded is fast (cached)',
    skip: enabled ? null : 'requires MINIAV_TOOLS_FFMPEG_NETTEST=1',
    () async {
      final sw = Stopwatch()..start();
      final ok = await ensureFFmpegLoaded();
      sw.stop();
      expect(ok, isTrue);
      // Cached path should be near-instant; allow generous bound for first
      // load when the file is not yet warm.
      expect(
        sw.elapsed.inMilliseconds,
        lessThan(2000),
        reason: 'cached load took ${sw.elapsedMilliseconds} ms',
      );
    },
  );
}
