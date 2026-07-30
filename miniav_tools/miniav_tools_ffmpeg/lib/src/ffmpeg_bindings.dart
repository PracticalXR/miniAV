/// FFmpeg dynamic-library probing + minimal FFI binding stub.
///
/// Real ffigen-generated bindings will replace [tryLoadFFmpeg] with a proper
/// `DynamicLibrary` cache + symbol lookup tables for libavcodec, libavformat,
/// libavutil, libswscale, libswresample.
library;

import 'dart:ffi';
import 'dart:io';

import 'ffmpeg_downloader.dart';

DynamicLibrary? _avcodec;
DynamicLibrary? _avformat;
DynamicLibrary? _avutil;
// Pinned dependency handles: avcodec/avformat import from these. Loading them
// first (from the same dir) ensures Windows can resolve their imports without
// modifying the process DLL search path.
DynamicLibrary? _swresample;
DynamicLibrary? _swscale;

/// Extra directory to probe (set after a successful auto-download).
String? _downloadedLibDir;

/// Synchronous probe — does NOT trigger an auto-download. Returns true iff
/// libav* are already discoverable (env var, system path, common locations,
/// or a previously cached download).
bool tryLoadFFmpeg() {
  if (_avcodec != null && _avformat != null && _avutil != null) return true;
  // Pick up an existing cache directory created by a prior run.
  _downloadedLibDir ??= _existingCacheLibDir();
  try {
    final dirs = _candidateDirs();
    _avutil = _open('avutil', dirs, soVersions: const [60, 59, 58, 57, 56]);
    // Pre-load shared dependencies so avcodec/avformat resolve their imports
    // when the containing directory is not on the OS DLL search path.
    _swresample ??= _open('swresample', dirs, soVersions: const [6, 5, 4, 3]);
    _swscale ??= _open('swscale', dirs, soVersions: const [9, 8, 7, 6, 5]);
    _avcodec = _open('avcodec', dirs, soVersions: const [62, 61, 60, 59, 58]);
    _avformat = _open('avformat', dirs, soVersions: const [62, 61, 60, 59, 58]);
    return _avcodec != null && _avformat != null && _avutil != null;
  } catch (_) {
    return false;
  }
}

/// Async ensure: probes first, then triggers an auto-download if probing
/// fails (and auto-download is not disabled). Safe to call multiple times.
Future<bool> ensureFFmpegLoaded({
  void Function(int received, int total)? onDownloadProgress,
}) async {
  if (tryLoadFFmpeg()) return true;
  final result = await FfmpegDownloader.ensureFfmpeg(
    progress: onDownloadProgress,
  );
  if (result == null) return false;
  _downloadedLibDir = result.libDir;
  return tryLoadFFmpeg();
}

/// Best-effort dynamic library getter.
DynamicLibrary? get avcodec => _avcodec;
DynamicLibrary? get avformat => _avformat;
DynamicLibrary? get avutil => _avutil;

/// The directory from which FFmpeg shared libraries were loaded, or `null`
/// if FFmpeg has not been loaded yet. On Windows this is the `bin/` folder
/// that also contains `ffprobe.exe` and `ffmpeg.exe`.
String? get ffmpegLoadedLibDir => _downloadedLibDir;

DynamicLibrary? _open(
  String basename,
  List<String> dirs, {
  required List<int> soVersions,
}) {
  final names = <String>[];
  if (Platform.isWindows) {
    names.add('$basename.dll');
    for (final v in soVersions) {
      names.add('$basename-$v.dll');
    }
  } else if (Platform.isMacOS) {
    names.add('lib$basename.dylib');
    for (final v in soVersions) {
      names.add('lib$basename.$v.dylib');
    }
  } else {
    names.add('lib$basename.so');
    for (final v in soVersions) {
      names.add('lib$basename.so.$v');
    }
  }

  for (final dir in dirs) {
    for (final n in names) {
      final path = dir.isEmpty ? n : '$dir${Platform.pathSeparator}$n';
      try {
        return DynamicLibrary.open(path);
      } catch (_) {
        // Try next.
      }
    }
  }
  return null;
}

List<String> _candidateDirs() {
  final dirs = <String>[];
  // Auto-downloaded build wins over system if present.
  if (_downloadedLibDir != null) dirs.add(_downloadedLibDir!);
  final env = Platform.environment['FFMPEG_LIB_DIR'];
  if (env != null && env.isNotEmpty) dirs.add(env);
  dirs.add(''); // system search path
  if (Platform.isWindows) {
    dirs.addAll(const [r'C:\ffmpeg\bin', r'C:\Program Files\ffmpeg\bin']);
  } else if (Platform.isMacOS) {
    dirs.addAll(const ['/opt/homebrew/lib', '/usr/local/lib']);
  } else {
    dirs.addAll(const [
      '/usr/lib/x86_64-linux-gnu',
      '/usr/lib',
      '/usr/local/lib',
    ]);
  }
  return dirs;
}

/// Look for a previously-downloaded cache directory without doing any
/// network I/O. Returns the lib directory if a usable install is found.
///
/// We do NOT require the `.ready` marker — it can legitimately be missing
/// if a previous run crashed mid-marker-write or a concurrent process is
/// in the middle of extracting. The presence of plausible avcodec /
/// avformat / avutil shared libraries is itself enough evidence.
String? _existingCacheLibDir() {
  try {
    final root = FfmpegDownloader.defaultCacheRoot();
    final installRoot = '$root${Platform.pathSeparator}$kFfmpegInstallDir';
    final dir = Directory(installRoot);
    if (!dir.existsSync()) return null;
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      for (final sub in const ['bin', 'lib']) {
        final candidate = Directory(
          '${entry.path}${Platform.pathSeparator}$sub',
        );
        if (candidate.existsSync() && _hasAvSync(candidate)) {
          return candidate.path;
        }
      }
    }
    // Some archives extract directly without a wrapper folder.
    for (final sub in const ['bin', 'lib']) {
      final candidate = Directory('$installRoot${Platform.pathSeparator}$sub');
      if (candidate.existsSync() && _hasAvSync(candidate)) {
        return candidate.path;
      }
    }
  } catch (_) {}
  return null;
}

bool _hasAvSync(Directory dir) {
  for (final f in dir.listSync()) {
    final name = f.path.toLowerCase();
    final base = name.substring(name.lastIndexOf(Platform.pathSeparator) + 1);
    if (base.startsWith('avcodec') &&
        (base.endsWith('.dll') ||
            base.contains('.so') ||
            base.endsWith('.dylib'))) {
      return true;
    }
  }
  return false;
}
