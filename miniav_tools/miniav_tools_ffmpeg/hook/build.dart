// Native-assets build hook for the miniav_tools_ffmpeg shim.
//
// Compiles `tool/shim_c/shim.c` into `miniav_tools_ffmpeg_shim` and
// registers it as a code asset bound to `lib/src/ffmpeg_shim.dart`.
//
// FFmpeg headers and import libs are sourced from the auto-downloader
// cache (see `lib/src/ffmpeg_downloader.dart`). On first build the cache
// is populated by calling `FfmpegDownloader.ensureFfmpeg()`. If that
// fails (no network, etc.) the shim is silently skipped — Stage B
// (zero-copy HW encode) becomes unavailable but Stage A (CPU staging)
// still works.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';
import 'package:path/path.dart' as p;

import 'package:miniav_tools_ffmpeg/src/ffmpeg_downloader.dart';

const _shimAssetName = 'miniav_tools_ffmpeg_shim';
const _shimDartFile = 'ffmpeg_shim.dart';
final _sourceDir = Directory('./tool/shim_c');

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    hierarchicalLoggingEnabled = true;
    final logger = Logger('build')
      ..level = Level.ALL
      ..onRecord.listen((r) => stderr.writeln('[shim] ${r.message}'));

    final os = input.config.code.targetOS;
    if (os != OS.windows &&
        os != OS.linux &&
        os != OS.macOS &&
        os != OS.iOS &&
        os != OS.android) {
      logger.info('shim not built on $os (Stage B unsupported)');
      return;
    }

    // Ensure FFmpeg dev distribution is on disk (downloads ~120MB once).
    FfmpegDownloadResult? ff;
    try {
      ff = await FfmpegDownloader.ensureFfmpeg();
    } catch (e) {
      logger.warning(
        'FFmpeg auto-download failed: $e\n'
        'Skipping shim build. Stage B will be unavailable; Stage A '
        '(CPU staging) still works.',
      );
      return;
    }
    if (ff == null) {
      logger.warning(
        'FFmpeg auto-download disabled or unsupported on this platform. '
        'Skipping shim build.',
      );
      return;
    }

    final top = p.dirname(ff.libDir);
    final includeDir = p.join(top, 'include');
    final libDir = p.join(top, 'lib');

    if (!Directory(includeDir).existsSync() ||
        !Directory(libDir).existsSync()) {
      logger.warning(
        'FFmpeg cache is missing include/ or lib/ at $top. '
        'Skipping shim build.',
      );
      return;
    }

    logger.info('FFmpeg headers: $includeDir');
    logger.info('FFmpeg libs:    $libDir');

    final generator = switch (os) {
      OS.linux || OS.android => Generator.ninja,
      OS.macOS || OS.iOS => Generator.make,
      _ => Generator.defaultGenerator,
    };

    final builder = CMakeBuilder.create(
      name: _shimAssetName,
      sourceDir: _sourceDir.absolute.uri,
      generator: generator,
      buildMode: BuildMode.release,
      targets: const [_shimAssetName],
      defines: {'FFMPEG_INCLUDE_DIR': includeDir, 'FFMPEG_LIB_DIR': libDir},
    );
    await builder.run(input: input, output: output, logger: logger);

    final assets = await output.findAndAddCodeAssets(
      input,
      names: const {_shimAssetName: _shimDartFile},
    );
    for (final asset in assets) {
      logger.info('registered asset: ${asset.file}');
    }
  });
}
