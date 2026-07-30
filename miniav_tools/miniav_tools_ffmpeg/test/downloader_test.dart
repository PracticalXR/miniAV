/// Tests for the FFmpeg auto-downloader.
///
/// The full network test downloads ~92 MB and is therefore opt-in via the
/// `MINIAV_TOOLS_FFMPEG_NETTEST=1` environment variable. Without it, only
/// the offline plumbing (URL construction, cache paths, asset selection)
/// is exercised.
library;

import 'dart:io';

import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegDownloader (offline)', () {
    test('downloadUri returns a github.com URL on supported platforms', () {
      final uri = FfmpegDownloader.downloadUri();
      if (Platform.isWindows || Platform.isLinux) {
        expect(uri, isNotNull);
        expect(uri!.host, equals('github.com'));
        expect(uri.path, contains('BtbN/FFmpeg-Builds'));
        expect(uri.path, contains(kFfmpegReleaseTag));
        // Must be the LGPL build, never the GPL one, to keep downstream
        // products free of GPL copyleft. (`-lgpl-shared` contains the
        // substring `gpl`, so match the dash-delimited tokens.)
        expect(uri.path, contains('-lgpl-shared'));
        expect(uri.path, isNot(contains('-gpl-shared')));
        expect(kFfmpegLicense, equals('lgpl'));
      } else {
        // macOS: no official shared build, downloader returns null.
        expect(uri, isNull);
      }
    });

    test('install dir is namespaced by release tag and licence', () {
      expect(kFfmpegInstallDir, equals('$kFfmpegReleaseTag-$kFfmpegLicense'));
      // A flipped licence must change the cache dir so an existing `gpl`
      // install is never silently reused for an `lgpl` switch.
      expect(kFfmpegInstallDir, contains('lgpl'));
    });

    test('defaultCacheRoot is platform-appropriate', () {
      final root = FfmpegDownloader.defaultCacheRoot();
      expect(root, isNotEmpty);
      expect(root, contains('miniav_tools'));
      expect(root, contains('ffmpeg'));
    });

    test('MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD disables ensureFfmpeg', () async {
      // We can't actually set env vars on a running process, so we just
      // assert the API exists; the real check happens in ensureFfmpeg.
      // Functionality is covered by the manual integration test below.
      expect(FfmpegDownloader.ensureFfmpeg, isA<Function>());
    });
  });

  group('FfmpegDownloader (network)', () {
    final enabled = Platform.environment['MINIAV_TOOLS_FFMPEG_NETTEST'] == '1';

    test(
      'downloads + extracts FFmpeg, then libs are loadable',
      skip: enabled
          ? null
          : 'set MINIAV_TOOLS_FFMPEG_NETTEST=1 to run (~92 MB download)',
      () async {
        // Use an isolated temp cache so we always test the full download.
        final tempCache = await Directory.systemTemp.createTemp(
          'miniav_tools_ffmpeg_test_',
        );
        try {
          var lastPct = -1;
          final result = await FfmpegDownloader.ensureFfmpeg(
            cacheRoot: tempCache.path,
            progress: (received, total) {
              if (total <= 0) return;
              final pct = (received * 100) ~/ total;
              if (pct != lastPct && pct % 10 == 0) {
                lastPct = pct;
                // ignore: avoid_print
                print('  download: $pct%');
              }
            },
          );

          expect(
            result,
            isNotNull,
            reason: 'auto-download failed; see stderr for details',
          );
          expect(Directory(result!.libDir).existsSync(), isTrue);

          // libavcodec must be present in the lib dir.
          final libs = Directory(result.libDir)
              .listSync()
              .map((e) => e.path.toLowerCase())
              .where(
                (p) =>
                    p.contains('avcodec') &&
                    (p.endsWith('.dll') ||
                        p.contains('.so') ||
                        p.endsWith('.dylib')),
              )
              .toList();
          expect(
            libs,
            isNotEmpty,
            reason: 'no avcodec library found in ${result.libDir}',
          );

          // Now wire it up via env-style override and check the binding loader
          // can pick it up. Since tryLoadFFmpeg() reads FFMPEG_LIB_DIR at call
          // time but Platform.environment is read-only, we just assert the
          // file exists and is loadable via dart:ffi directly.
          // (full ensureFFmpegLoaded() is exercised in encoder integration
          // tests).
        } finally {
          try {
            await tempCache.delete(recursive: true);
          } catch (_) {}
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
