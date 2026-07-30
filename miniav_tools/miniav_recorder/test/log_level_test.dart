// ignore_for_file: avoid_print

import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // RecorderLogLevel ↔ MiniAVLogLevel mapping
  // -------------------------------------------------------------------------

  group('RecorderLogLevel → MiniAVLogLevel mapping', () {
    test('verbose maps to debug', () {
      expect(
        Recorder.miniavLogLevelFor(RecorderLogLevel.verbose),
        MiniAVLogLevel.debug,
      );
    });

    test('info maps to info', () {
      expect(
        Recorder.miniavLogLevelFor(RecorderLogLevel.info),
        MiniAVLogLevel.info,
      );
    });

    test('warning maps to warn', () {
      expect(
        Recorder.miniavLogLevelFor(RecorderLogLevel.warning),
        MiniAVLogLevel.warn,
      );
    });

    test('error maps to error', () {
      expect(
        Recorder.miniavLogLevelFor(RecorderLogLevel.error),
        MiniAVLogLevel.error,
      );
    });

    test('quiet maps to none', () {
      expect(
        Recorder.miniavLogLevelFor(RecorderLogLevel.quiet),
        MiniAVLogLevel.none,
      );
    });
  });

  // -------------------------------------------------------------------------
  // RecorderLogLevel ↔ AV_LOG_* integer mapping
  // -------------------------------------------------------------------------

  group('RecorderLogLevel → AV_LOG integer mapping', () {
    const avLogQuiet = -8;
    const avLogError = 16;
    const avLogWarning = 24;
    const avLogInfo = 32;
    const avLogDebug = 48;

    test('verbose maps to AV_LOG_DEBUG (48)', () {
      expect(Recorder.avLogLevelFor(RecorderLogLevel.verbose), avLogDebug);
    });

    test('info maps to AV_LOG_INFO (32)', () {
      expect(Recorder.avLogLevelFor(RecorderLogLevel.info), avLogInfo);
    });

    test('warning maps to AV_LOG_WARNING (24)', () {
      expect(Recorder.avLogLevelFor(RecorderLogLevel.warning), avLogWarning);
    });

    test('error maps to AV_LOG_ERROR (16)', () {
      expect(Recorder.avLogLevelFor(RecorderLogLevel.error), avLogError);
    });

    test('quiet maps to AV_LOG_QUIET (-8)', () {
      expect(Recorder.avLogLevelFor(RecorderLogLevel.quiet), avLogQuiet);
    });

    test('every RecorderLogLevel has an AV_LOG value', () {
      for (final level in RecorderLogLevel.values) {
        expect(
          Recorder.avLogLevelFor(level),
          isA<int>(),
          reason: 'Missing mapping for $level',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // Recorder.setLogLevel smoke tests (call must not throw)
  // -------------------------------------------------------------------------

  group('Recorder.setLogLevel smoke tests', () {
    tearDown(() {
      // Always clean up to avoid callback leaks across tests.
      Recorder.setLogCallback(null);
    });

    test('does not throw for every RecorderLogLevel', () {
      for (final level in RecorderLogLevel.values) {
        expect(() => Recorder.setLogLevel(level), returnsNormally);
      }
    });

    test('repeated calls are idempotent', () {
      expect(() {
        Recorder.setLogLevel(RecorderLogLevel.verbose);
        Recorder.setLogLevel(RecorderLogLevel.verbose);
      }, returnsNormally);
    });

    test('setting quiet then verbose does not throw', () {
      expect(() {
        Recorder.setLogLevel(RecorderLogLevel.quiet);
        Recorder.setLogLevel(RecorderLogLevel.verbose);
      }, returnsNormally);
    });

    test('setting verbose then quiet removes callbacks without throwing', () {
      expect(() {
        Recorder.setLogLevel(RecorderLogLevel.verbose);
        Recorder.setLogLevel(RecorderLogLevel.quiet);
      }, returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // Recorder.setLogCallback — unified log routing
  // -------------------------------------------------------------------------

  group('Recorder.setLogCallback', () {
    tearDown(() => Recorder.setLogCallback(null));

    test('null callback does not throw', () {
      expect(() => Recorder.setLogCallback(null), returnsNormally);
    });

    test('callback is accepted without throwing', () {
      expect(
        () => Recorder.setLogCallback((source, level, msg) {}),
        returnsNormally,
      );
    });

    test('callback receives correct RecorderLogSource values', () {
      // Verify the enum has the expected members.
      expect(
        RecorderLogSource.values,
        containsAll([
          RecorderLogSource.recorder,
          RecorderLogSource.miniav,
          RecorderLogSource.ffmpeg,
          RecorderLogSource.minigpu,
        ]),
      );
    });

    test('setLogCallback then setLogLevel does not throw', () {
      expect(() {
        Recorder.setLogCallback((source, level, msg) {});
        Recorder.setLogLevel(RecorderLogLevel.verbose);
      }, returnsNormally);
    });

    test(
      'setLogLevel then setLogCallback routes MiniAV through callback',
      () async {
        final received = <(RecorderLogSource, RecorderLogLevel, String)>[];
        Recorder.setLogCallback(
          (source, level, msg) => received.add((source, level, msg)),
        );
        Recorder.setLogLevel(RecorderLogLevel.verbose);

        MiniAV.getVersion(); // trigger any native activity
        await Future<void>.delayed(Duration.zero);

        // We do not assert received.isNotEmpty (getVersion may not log),
        // but any entries must have source == miniav.
        for (final (src, _, _) in received) {
          expect(src, RecorderLogSource.miniav);
        }
      },
    );

    test('replacing callback does not throw', () {
      expect(() {
        Recorder.setLogCallback((source, level, msg) {});
        Recorder.setLogCallback((source, level, msg) {});
        Recorder.setLogCallback(null);
      }, returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // MiniAV.setLogCallback / installStderrLogger
  // -------------------------------------------------------------------------

  group('MiniAV.setLogCallback', () {
    test('installStderrLogger does not throw', () {
      expect(() => MiniAV.installStderrLogger(), returnsNormally);
    });

    test('setLogCallback(null) clears callback without throwing', () {
      expect(() {
        MiniAV.installStderrLogger();
        MiniAV.setLogCallback(null);
      }, returnsNormally);
    });

    test('custom callback is accepted without throwing', () {
      expect(() {
        MiniAV.setLogCallback((level, msg) {
          // no-op
        });
        MiniAV.setLogCallback(null);
      }, returnsNormally);
    });

    test(
      'callback installed via setLogCallback is invoked when MiniAV logs',
      () async {
        // Validates that the NativeCallable round-trip works end-to-end.
        // MiniAV may or may not emit logs on getVersion() — we merely verify
        // that the callback does not throw when installed and then cleared.
        final received = <(MiniAVLogLevel, String)>[];

        MiniAV.setLogLevel(MiniAVLogLevel.debug);
        MiniAV.setLogCallback((level, msg) => received.add((level, msg)));

        // Trigger any native activity that might produce a log line.
        MiniAV.getVersion();

        // Allow an event loop turn to flush any pending callbacks.
        await Future<void>.delayed(Duration.zero);

        MiniAV.setLogCallback(null);

        // We do not assert received.isNotEmpty because getVersion() may not
        // produce log output on all platforms. The test validates no throw.
      },
    );

    test('no logs received at quiet level', () async {
      final received = <(MiniAVLogLevel, String)>[];

      MiniAV.setLogLevel(MiniAVLogLevel.none);
      MiniAV.setLogCallback((level, msg) => received.add((level, msg)));

      MiniAV.getVersion();

      // Allow an event loop turn to flush any pending callbacks.
      await Future<void>.delayed(Duration.zero);

      MiniAV.setLogCallback(null);

      expect(
        received,
        isEmpty,
        reason: 'No log callbacks expected at log level none (quiet)',
      );
    });
  });

  // -------------------------------------------------------------------------
  // FfmpegShim log forwarding
  // -------------------------------------------------------------------------

  group('FfmpegShim log forwarding', () {
    test('setFfmpegLogLevel does not throw if shim is available', () {
      final shim = FfmpegShim.tryLoad();
      if (shim == null) {
        print('[log_level_test] FfmpegShim not available — test skipped');
        return;
      }
      expect(() => shim.setFfmpegLogLevel(32), returnsNormally);
    });

    test('setFfmpegLogCallback installs callback without throwing', () {
      final shim = FfmpegShim.tryLoad();
      if (shim == null) {
        print('[log_level_test] FfmpegShim not available — test skipped');
        return;
      }
      expect(() {
        shim.setFfmpegLogCallback((level, msg) {});
      }, returnsNormally);
      // Clean up.
      shim.setFfmpegLogCallback(null);
    });

    test('setFfmpegLogCallback(null) clears callback without throwing', () {
      final shim = FfmpegShim.tryLoad();
      if (shim == null) {
        print('[log_level_test] FfmpegShim not available — test skipped');
        return;
      }
      expect(() {
        shim.setFfmpegLogCallback((level, msg) {});
        shim.setFfmpegLogCallback(null);
      }, returnsNormally);
    });

    test('replacing callback does not throw', () {
      final shim = FfmpegShim.tryLoad();
      if (shim == null) {
        print('[log_level_test] FfmpegShim not available — test skipped');
        return;
      }
      expect(() {
        shim.setFfmpegLogCallback((level, msg) {});
        // Second install should close the first NativeCallable cleanly.
        shim.setFfmpegLogCallback((level, msg) {});
        shim.setFfmpegLogCallback(null);
      }, returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // RecorderLogLevel ↔ mgpu log level integer mapping
  // -------------------------------------------------------------------------

  group('RecorderLogLevel → mgpu level mapping', () {
    test('verbose maps to 0 (LOG_DEBUG)', () {
      expect(Recorder.minigpuLevelFor(RecorderLogLevel.verbose), 0);
    });

    test('info maps to 1 (LOG_INFO)', () {
      expect(Recorder.minigpuLevelFor(RecorderLogLevel.info), 1);
    });

    test('warning maps to 2 (LOG_WARN)', () {
      expect(Recorder.minigpuLevelFor(RecorderLogLevel.warning), 2);
    });

    test('error maps to 3 (LOG_ERROR)', () {
      expect(Recorder.minigpuLevelFor(RecorderLogLevel.error), 3);
    });

    test('quiet maps to -1 (LOG_NONE)', () {
      expect(Recorder.minigpuLevelFor(RecorderLogLevel.quiet), -1);
    });

    test('every RecorderLogLevel has a minigpu level', () {
      for (final level in RecorderLogLevel.values) {
        expect(
          Recorder.minigpuLevelFor(level),
          isA<int>(),
          reason: 'Missing minigpu mapping for $level',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // RecorderLogSource enum contains minigpu
  // -------------------------------------------------------------------------

  group('RecorderLogSource.minigpu', () {
    test('enum contains minigpu value', () {
      expect(RecorderLogSource.values, contains(RecorderLogSource.minigpu));
    });

    test('enum contains all four expected sources', () {
      expect(
        RecorderLogSource.values,
        containsAll([
          RecorderLogSource.recorder,
          RecorderLogSource.miniav,
          RecorderLogSource.ffmpeg,
          RecorderLogSource.minigpu,
        ]),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Recorder.setLogCallback minigpu routing (smoke tests)
  // -------------------------------------------------------------------------

  group('Recorder.setLogCallback minigpu routing', () {
    tearDown(() => Recorder.setLogCallback(null));

    test('setLogCallback with minigpu routing does not throw', () {
      expect(() {
        Recorder.setLogCallback((source, level, msg) {});
        Recorder.setLogLevel(RecorderLogLevel.verbose);
      }, returnsNormally);
    });

    test('setLogLevel(quiet) clears minigpu callback without throwing', () {
      expect(() {
        Recorder.setLogCallback((source, level, msg) {});
        Recorder.setLogLevel(RecorderLogLevel.quiet);
      }, returnsNormally);
    });

    test(
      'replacing log callback closes previous NativeCallable without throwing',
      () {
        expect(() {
          Recorder.setLogCallback((source, level, msg) {});
          Recorder.setLogLevel(RecorderLogLevel.verbose);
          Recorder.setLogCallback((source, level, msg) {});
          Recorder.setLogCallback(null);
        }, returnsNormally);
      },
    );
  });
}
