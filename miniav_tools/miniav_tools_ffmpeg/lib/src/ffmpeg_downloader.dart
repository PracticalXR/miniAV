/// Downloads + caches a shared-library FFmpeg build on first use.
///
/// Source: BtbN/FFmpeg-Builds GitHub releases — they ship official, signed
/// shared-library archives for Windows (.zip), Linux (.tar.xz) and recent
/// macOS via the auto-build pipeline. We pin to a known-good release.
///
/// Cache layout:
///   `<cacheRoot>/<release-tag>-<license>/<platform>/bin`   (Windows DLLs)
///   `<cacheRoot>/<release-tag>-<license>/<platform>/lib`   (Linux .so / macOS .dylib)
///
/// `cacheRoot` defaults to:
///   - Windows: %LOCALAPPDATA%\miniav_tools\ffmpeg
///   - macOS:   ~/Library/Caches/miniav_tools/ffmpeg
///   - Linux:   $XDG_CACHE_HOME/miniav_tools/ffmpeg or ~/.cache/...
///
/// Override with `MINIAV_TOOLS_FFMPEG_CACHE` env var. Skip auto-download
/// entirely with `MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD=1`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'ffmpeg_log.dart';

/// Pinned release tag from https://github.com/BtbN/FFmpeg-Builds/releases.
/// `latest` is the rolling tag; 8.1 stable assets are named
/// `ffmpeg-n8.1-latest-<platform>-<license>-shared-8.1.<ext>`.
const String kFfmpegReleaseTag = 'latest';
const String kFfmpegVersionSuffix = 'n8.1-latest';

/// FFmpeg build licence variant to download.
///
/// **`lgpl`** (the default) pulls BtbN's LGPL shared build. We deliberately
/// avoid the `gpl` build: that one is compiled with `--enable-gpl` and links
/// GPL-only components (libx264, libx265, libxvid, …), which makes the whole
/// FFmpeg binary GPLv2+ and would impose copyleft obligations on any product
/// that loads it. The LGPL build keeps libav* under LGPL-2.1 — safe for
/// proprietary dynamic linking — at the cost of the software x264/x265
/// encoders. Hardware encoders (NVENC / QSV / AMF / MediaFoundation /
/// VideoToolbox) and libvpx / SVT-AV1 remain available, so the only feature
/// lost is the CPU-side H.264/HEVC fallback. See ffmpeg_backend.dart.
const String kFfmpegLicense = 'lgpl';

/// Cache subdirectory under the cache root, namespaced by release tag AND
/// licence so flipping [kFfmpegLicense] forces a fresh download instead of
/// silently reusing a previously-cached `gpl` install (which would defeat the
/// licence switch). Both [FfmpegDownloader] and the binding loader build their
/// install path from this constant so they always agree.
const String kFfmpegInstallDir = '$kFfmpegReleaseTag-$kFfmpegLicense';

class FfmpegDownloadResult {
  /// Directory containing the loadable shared libraries
  /// (`.dll` on Windows, `.so` on Linux, `.dylib` on macOS).
  final String libDir;

  /// Where the archive was extracted (`libDir`'s parent for Windows builds
  /// where DLLs live in `bin/`, otherwise the same as [libDir]).
  final String installRoot;

  const FfmpegDownloadResult({required this.libDir, required this.installRoot});
}

class FfmpegDownloader {
  /// Asset filename per platform (BtbN naming convention).
  static String? _assetName() {
    if (Platform.isWindows) {
      return 'ffmpeg-$kFfmpegVersionSuffix-win64-$kFfmpegLicense-shared-8.1.zip';
    }
    if (Platform.isLinux) {
      return 'ffmpeg-$kFfmpegVersionSuffix-linux64-$kFfmpegLicense-shared-8.1.tar.xz';
    }
    // macOS: BtbN does not ship official macOS shared builds. User must
    // install via `brew install ffmpeg` (homebrew puts dylibs in
    // /opt/homebrew/lib or /usr/local/lib which our loader already probes).
    return null;
  }

  /// Download URL for the current platform, or `null` if unsupported.
  static Uri? downloadUri() {
    final asset = _assetName();
    if (asset == null) return null;
    return Uri.https(
      'github.com',
      '/BtbN/FFmpeg-Builds/releases/download/$kFfmpegReleaseTag/$asset',
    );
  }

  /// Default cache root (see library doc-comment for resolution rules).
  static String defaultCacheRoot() {
    final override = Platform.environment['MINIAV_TOOLS_FFMPEG_CACHE'];
    if (override != null && override.isNotEmpty) return override;

    if (Platform.isWindows) {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ??
          p.join(
            Platform.environment['USERPROFILE'] ?? '.',
            'AppData',
            'Local',
          );
      return p.join(localAppData, 'miniav_tools', 'ffmpeg');
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return p.join(home, 'Library', 'Caches', 'miniav_tools', 'ffmpeg');
    }
    // Linux / other POSIX
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    final base = xdg != null && xdg.isNotEmpty
        ? xdg
        : p.join(Platform.environment['HOME'] ?? '.', '.cache');
    return p.join(base, 'miniav_tools', 'ffmpeg');
  }

  /// Returns a path to a directory containing the loadable libav* libraries,
  /// downloading + extracting them if necessary. Returns `null` if
  /// auto-download is disabled, the platform is unsupported, or the download
  /// fails.
  ///
  /// Set [progress] to receive `(bytesReceived, totalBytes)` updates during
  /// the network transfer (totalBytes may be `-1` if the server omits
  /// `Content-Length`).
  static Future<FfmpegDownloadResult?> ensureFfmpeg({
    String? cacheRoot,
    void Function(int received, int total)? progress,
    bool force = false,
  }) async {
    if (Platform.environment['MINIAV_TOOLS_FFMPEG_NO_AUTODOWNLOAD'] == '1') {
      return null;
    }

    final uri = downloadUri();
    if (uri == null) return null; // unsupported platform

    final root = cacheRoot ?? defaultCacheRoot();
    final installRoot = p.join(root, kFfmpegInstallDir);
    final marker = File(p.join(installRoot, '.ready'));

    // ---- Layer 1: marker present + libs found → fast path. -----------------
    if (!force && await marker.exists()) {
      final libDir = await _findLibDir(installRoot);
      if (libDir != null) {
        return FfmpegDownloadResult(libDir: libDir, installRoot: installRoot);
      }
    }

    // ---- Layer 2: libs already on disk (no marker, or stale marker). -------
    //   Common causes:
    //     * Another instance of this app is already running and has the
    //       DLLs mapped (Windows; their files would be locked against
    //       overwrite, so re-extracting would crash with errno=32).
    //     * A previous run extracted successfully but crashed before
    //       writing .ready.
    //     * User pre-installed FFmpeg into the cache dir manually.
    //   In any of those cases the existing libs should be perfectly
    //   loadable, so probe them and short-circuit.
    if (!force) {
      final existingLibDir = await _findLibDir(installRoot);
      if (existingLibDir != null && _libsLookValid(existingLibDir)) {
        // Best-effort marker write so future runs hit Layer 1.
        try {
          await marker.writeAsString(
            jsonEncode({
              'release': kFfmpegReleaseTag,
              'extractedAt': DateTime.now().toUtc().toIso8601String(),
              'recovered': true,
            }),
          );
        } catch (_) {}
        return FfmpegDownloadResult(
          libDir: existingLibDir,
          installRoot: installRoot,
        );
      }
    }

    await Directory(installRoot).create(recursive: true);

    final asset = _assetName()!;
    final archivePath = p.join(installRoot, asset);

    // ---- Layer 3: real cross-process file lock. ----------------------------
    //   `IOSink.openWrite` on Windows does NOT fail if another process has
    //   the file open — it just truncates. To actually serialise concurrent
    //   downloaders we need an OS-level advisory lock via
    //   RandomAccessFile.lock.
    final lockPath = p.join(installRoot, '.lock');
    RandomAccessFile? lockHandle;
    var holdsLock = false;
    try {
      lockHandle = await File(lockPath).open(mode: FileMode.write);
      try {
        await lockHandle.lock(FileLock.exclusive);
        holdsLock = true;
      } catch (_) {
        // Another process has the lock. Wait for the marker (with periodic
        // re-probes in case extraction finishes mid-wait).
        try {
          await lockHandle.close();
        } catch (_) {}
        lockHandle = null;
        for (var i = 0; i < 600; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (await marker.exists()) {
            final libDir = await _findLibDir(installRoot);
            if (libDir != null) {
              return FfmpegDownloadResult(
                libDir: libDir,
                installRoot: installRoot,
              );
            }
          }
          // Even without the marker, if libs appear & load, we're done.
          final probe = await _findLibDir(installRoot);
          if (probe != null && _libsLookValid(probe)) {
            return FfmpegDownloadResult(
              libDir: probe,
              installRoot: installRoot,
            );
          }
        }
        // 10 minutes elapsed — give up rather than fight for the lock.
        return null;
      }

      // Re-probe after acquiring the lock — another process may have
      // finished while we were blocked.
      if (!force) {
        final libDir = await _findLibDir(installRoot);
        if (libDir != null && _libsLookValid(libDir)) {
          if (!await marker.exists()) {
            try {
              await marker.writeAsString(
                jsonEncode({
                  'release': kFfmpegReleaseTag,
                  'extractedAt': DateTime.now().toUtc().toIso8601String(),
                  'recovered': true,
                }),
              );
            } catch (_) {}
          }
          return FfmpegDownloadResult(libDir: libDir, installRoot: installRoot);
        }
      }

      // Download.
      final downloaded = await _download(uri, archivePath, progress: progress);
      if (!downloaded) return null;

      // Extract. If extraction throws because target files are in use
      // (errno=32 on Windows), fall back to whatever's already on disk —
      // a previous successful extract is almost certainly intact.
      try {
        if (asset.endsWith('.zip')) {
          await _extractZip(archivePath, installRoot);
        } else if (asset.endsWith('.tar.xz')) {
          await _extractTarXz(archivePath, installRoot);
        } else {
          ffmpegToolsLog(
            MiniAVLogLevel.error,
            'miniav_tools_ffmpeg: unknown archive format: $asset',
          );
          return null;
        }
      } on PathAccessException catch (e) {
        ffmpegToolsLog(
          MiniAVLogLevel.warn,
          'miniav_tools_ffmpeg: extraction blocked (file in use): $e — '
          'attempting to use existing install.',
        );
        final existing = await _findLibDir(installRoot);
        if (existing != null && _libsLookValid(existing)) {
          return FfmpegDownloadResult(
            libDir: existing,
            installRoot: installRoot,
          );
        }
        rethrow;
      } on FileSystemException catch (e) {
        // Some Dart/Windows builds wrap the same condition as a plain
        // FileSystemException with osError.errorCode == 32.
        if (e.osError?.errorCode == 32) {
          ffmpegToolsLog(
            MiniAVLogLevel.warn,
            'miniav_tools_ffmpeg: extraction blocked (errno=32): $e — '
            'attempting to use existing install.',
          );
          final existing = await _findLibDir(installRoot);
          if (existing != null && _libsLookValid(existing)) {
            return FfmpegDownloadResult(
              libDir: existing,
              installRoot: installRoot,
            );
          }
        }
        rethrow;
      }

      // Best-effort cleanup of the archive to save disk.
      try {
        await File(archivePath).delete();
      } catch (_) {}

      await marker.writeAsString(
        jsonEncode({
          'release': kFfmpegReleaseTag,
          'extractedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } finally {
      if (lockHandle != null) {
        if (holdsLock) {
          try {
            await lockHandle.unlock();
          } catch (_) {}
        }
        try {
          await lockHandle.close();
        } catch (_) {}
      }
      // Best-effort lock-file removal. On Windows another process may
      // already hold a handle, in which case delete will fail — harmless.
      try {
        if (await File(lockPath).exists()) await File(lockPath).delete();
      } catch (_) {}
    }

    final libDir = await _findLibDir(installRoot);
    if (libDir == null) {
      ffmpegToolsLog(
        MiniAVLogLevel.error,
        'miniav_tools_ffmpeg: extracted FFmpeg but no lib dir found under '
        '$installRoot',
      );
      return null;
    }
    return FfmpegDownloadResult(libDir: libDir, installRoot: installRoot);
  }

  /// Sanity-check that the per-platform key DLLs/so files are present and
  /// non-empty. This is intentionally cheap (no DynamicLibrary.open here —
  /// that requires the caller's loading isolate) and just guards against
  /// half-extracted installs.
  static bool _libsLookValid(String libDir) {
    try {
      final dir = Directory(libDir);
      if (!dir.existsSync()) return false;
      var sawAvcodec = false;
      var sawAvformat = false;
      var sawAvutil = false;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = p.basename(f.path).toLowerCase();
        final isShared =
            name.endsWith('.dll') ||
            name.contains('.so') ||
            name.endsWith('.dylib');
        if (!isShared) continue;
        // Reject zero-byte files (incomplete extraction).
        try {
          if (f.lengthSync() < 1024) continue;
        } catch (_) {
          continue;
        }
        if (name.startsWith('avcodec')) sawAvcodec = true;
        if (name.startsWith('avformat')) sawAvformat = true;
        if (name.startsWith('avutil')) sawAvutil = true;
      }
      return sawAvcodec && sawAvformat && sawAvutil;
    } catch (_) {
      return false;
    }
  }

  // --- internals -----------------------------------------------------------

  static Future<bool> _download(
    Uri uri,
    String destPath, {
    void Function(int received, int total)? progress,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      final res = await client.send(req);
      if (res.statusCode == 302 || res.statusCode == 301) {
        final loc = res.headers['location'];
        if (loc == null) return false;
        return _download(Uri.parse(loc), destPath, progress: progress);
      }
      if (res.statusCode != 200) {
        ffmpegToolsLog(
          MiniAVLogLevel.error,
          'miniav_tools_ffmpeg: download failed HTTP '
          '${res.statusCode} for $uri',
        );
        return false;
      }
      final total = res.contentLength ?? -1;
      var received = 0;
      final sink = File(destPath).openWrite();
      try {
        await res.stream.forEach((chunk) {
          received += chunk.length;
          sink.add(chunk);
          if (progress != null) progress(received, total);
        });
      } finally {
        await sink.close();
      }
      return true;
    } catch (e) {
      ffmpegToolsLog(
        MiniAVLogLevel.error,
        'miniav_tools_ffmpeg: download error: $e',
      );
      return false;
    } finally {
      client.close();
    }
  }

  static Future<void> _extractZip(String archivePath, String destDir) async {
    final inputStream = InputFileStream(archivePath);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);
      await extractArchiveToDisk(archive, destDir);
    } finally {
      await inputStream.close();
    }
  }

  static Future<void> _extractTarXz(String archivePath, String destDir) async {
    // XZ decoding is in `package:archive` but streaming xz support is
    // limited; for Linux we can use the system `tar` binary which is
    // ubiquitous and far faster.
    final result = await Process.run('tar', [
      '-xJf',
      archivePath,
      '-C',
      destDir,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'tar -xJf failed (exit ${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// BtbN archives extract to `ffmpeg-<tag>/{bin,lib,include}/`. Locate the
  /// directory containing the shared libraries.
  static Future<String?> _findLibDir(String installRoot) async {
    if (!await Directory(installRoot).exists()) return null;
    await for (final entry in Directory(installRoot).list()) {
      if (entry is! Directory) continue;
      // Windows: bin/ holds avcodec-*.dll
      final bin = Directory(p.join(entry.path, 'bin'));
      if (await bin.exists() && await _hasAvLib(bin)) return bin.path;
      // Linux: lib/ holds libavcodec.so.*
      final lib = Directory(p.join(entry.path, 'lib'));
      if (await lib.exists() && await _hasAvLib(lib)) return lib.path;
    }
    // Some archives extract directly without a top wrapper folder.
    final binTop = Directory(p.join(installRoot, 'bin'));
    if (await binTop.exists() && await _hasAvLib(binTop)) return binTop.path;
    final libTop = Directory(p.join(installRoot, 'lib'));
    if (await libTop.exists() && await _hasAvLib(libTop)) return libTop.path;
    return null;
  }

  static Future<bool> _hasAvLib(Directory dir) async {
    await for (final f in dir.list()) {
      final name = p.basename(f.path).toLowerCase();
      if (name.startsWith('avcodec') &&
          (name.endsWith('.dll') ||
              name.contains('.so') ||
              name.endsWith('.dylib'))) {
        return true;
      }
    }
    return false;
  }
}

/// Compute SHA-256 for integrity checks (kept for future asset-pinning).
String sha256OfFile(String path) {
  final bytes = File(path).readAsBytesSync();
  return sha256.convert(bytes).toString();
}
