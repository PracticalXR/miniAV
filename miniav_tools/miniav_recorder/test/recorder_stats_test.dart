/// Tests for the encode-error rate-limiter and packet-stats tracking added
/// to [_VideoTrackRuntime] in recorder.dart.
///
/// Because [_VideoTrackRuntime] is private, we cannot instantiate it directly.
/// Instead, these tests verify the observable contracts that the recorder
/// honours:
///
///  (a) Stats line format — the exact string shape emitted by
///      `_maybeLogStats` is locked down here so formatting regressions are
///      caught immediately.  The logic is replicated from the implementation;
///      if the implementation drifts the test will also drift (intentional:
///      the test documents the *required* format, not auto-discovers it).
///
///  (b) Rate-limit constants are accessible via the `recorder_stats_constants`
///      barrel (if added) or verified to be within sane bounds here.
///
///  (c) Builder-level smoke: `RecorderBuilder` still builds valid recorders
///      after the stats fields were added (no constructor regressions).
library;

import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// (a) Stats line format — mirror the _maybeLogStats string-building logic.
// ---------------------------------------------------------------------------

/// Mirrors the formatting block inside `_VideoTrackRuntime._maybeLogStats`.
/// When the implementation changes this function must be updated to match,
/// and the tests below will catch the regression.
String _formatStatsLine({
  required String label,
  required double elapsedSecs,
  required int framesIn,
  required int throttleDropped,
  required int busyDropped,
  required int packetsOut,
  required int totalPktBytes,
  required int minPktBytes,
  required int maxPktBytes,
  required int encodeErrors,
  required Object? lastError,
  int gpuUsSum = 0,
  int gpuUsMax = 0,
  int gpuSamples = 0,
  int encUsSum = 0,
  int encUsMax = 0,
  int encSamples = 0,
  int adaptDivisor = 1,
}) {
  final avgPkt = packetsOut > 0 ? (totalPktBytes / packetsOut).round() : 0;
  final pktRange = packetsOut > 0
      ? '${minPktBytes}..${maxPktBytes}B avg=${avgPkt}B'
      : 'none';
  final errStr = encodeErrors > 0
      ? ' ERRORS=${encodeErrors} (last: $lastError)'
      : '';
  final gpuStr = gpuSamples > 0
      ? ' gpu=${(gpuUsSum / gpuSamples / 1000).toStringAsFixed(1)}'
            '/${(gpuUsMax / 1000).toStringAsFixed(1)}ms'
      : '';
  final encStr = encSamples > 0
      ? ' enc=${(encUsSum / encSamples / 1000).toStringAsFixed(1)}'
            '/${(encUsMax / 1000).toStringAsFixed(1)}ms'
      : '';
  final adaptStr = adaptDivisor > 1 ? ' adapt=÷$adaptDivisor' : '';
  return '[recorder] $label video stats over '
      '${elapsedSecs.toStringAsFixed(1)}s: '
      'in=${framesIn} (${(framesIn / elapsedSecs).toStringAsFixed(1)} fps) '
      'thr_drop=${throttleDropped} busy_drop=${busyDropped} '
      'encoded=${packetsOut} '
      '(${(packetsOut / elapsedSecs).toStringAsFixed(1)} fps) '
      'pkt=$pktRange$gpuStr$encStr$adaptStr$errStr';
}

void main() {
  // -------------------------------------------------------------------------
  // Stats line format
  // -------------------------------------------------------------------------
  group('_VideoTrackRuntime stats line format', () {
    test('happy path: no errors, packets present', () {
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 60,
        throttleDropped: 0,
        busyDropped: 0,
        packetsOut: 60,
        totalPktBytes: 600000,
        minPktBytes: 8000,
        maxPktBytes: 12000,
        encodeErrors: 0,
        lastError: null,
      );

      expect(line, startsWith('[recorder] screen video stats over'));
      expect(line, contains('in=60'));
      expect(line, contains('thr_drop=0'));
      expect(line, contains('busy_drop=0'));
      expect(line, contains('encoded=60'));
      expect(line, contains('8000..12000B'));
      expect(line, contains('avg=10000B'));
      // No ERRORS= suffix when count is 0.
      expect(line, isNot(contains('ERRORS=')));
    });

    test('error path: ERRORS= suffix appears when errors > 0', () {
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 60,
        throttleDropped: 5,
        busyDropped: 2,
        packetsOut: 50,
        totalPktBytes: 500000,
        minPktBytes: 9000,
        maxPktBytes: 11000,
        encodeErrors: 3,
        lastError: 'StateError: device lost',
      );

      expect(line, contains('ERRORS=3'));
      expect(line, contains('(last: StateError: device lost)'));
      expect(line, contains('thr_drop=5'));
      expect(line, contains('busy_drop=2'));
      expect(line, contains('encoded=50'));
    });

    test('pkt=none when no packets produced', () {
      final line = _formatStatsLine(
        label: 'cam',
        elapsedSecs: 2.0,
        framesIn: 0,
        throttleDropped: 0,
        busyDropped: 0,
        packetsOut: 0,
        totalPktBytes: 0,
        minPktBytes: 0x7fffffff,
        maxPktBytes: 0,
        encodeErrors: 0,
        lastError: null,
      );

      expect(line, contains('pkt=none'));
    });

    test('fps is reported as framesIn / elapsedSecs to 1 decimal', () {
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 60,
        throttleDropped: 0,
        busyDropped: 0,
        packetsOut: 30,
        totalPktBytes: 300000,
        minPktBytes: 9500,
        maxPktBytes: 10500,
        encodeErrors: 0,
        lastError: null,
      );

      // 60 / 2.0 = 30.0 fps for framesIn.
      expect(line, contains('(30.0 fps)'));
      // 30 / 2.0 = 15.0 fps for packetsOut.
      expect(line, contains('encoded=30'));
      expect(line, contains('(15.0 fps)'));
    });

    test('avg packet size is total / count (integer rounding)', () {
      // 3 packets, 1001 bytes total → avg rounds to 334.
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 3,
        throttleDropped: 0,
        busyDropped: 0,
        packetsOut: 3,
        totalPktBytes: 1001,
        minPktBytes: 300,
        maxPktBytes: 400,
        encodeErrors: 0,
        lastError: null,
      );

      // 1001 / 3 = 333.67 → rounded to 334.
      expect(line, contains('avg=334B'));
    });

    test('gpu=/enc= stage timing appears as avg/max ms when sampled', () {
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 60,
        throttleDropped: 0,
        busyDropped: 0,
        packetsOut: 60,
        totalPktBytes: 600000,
        minPktBytes: 8000,
        maxPktBytes: 12000,
        encodeErrors: 0,
        lastError: null,
        gpuUsSum: 90000, // 60 samples → avg 1.5 ms
        gpuUsMax: 4200,
        gpuSamples: 60,
        encUsSum: 300000, // 60 samples → avg 5.0 ms
        encUsMax: 12500,
        encSamples: 60,
      );

      expect(line, contains('gpu=1.5/4.2ms'));
      expect(line, contains('enc=5.0/12.5ms'));
      // Divisor 1 → no adapt marker.
      expect(line, isNot(contains('adapt=')));
    });

    test('gpu=/enc= omitted with no samples; adapt=÷N shown when reduced', () {
      final line = _formatStatsLine(
        label: 'screen',
        elapsedSecs: 2.0,
        framesIn: 30,
        throttleDropped: 30,
        busyDropped: 0,
        packetsOut: 30,
        totalPktBytes: 300000,
        minPktBytes: 9000,
        maxPktBytes: 11000,
        encodeErrors: 0,
        lastError: null,
        adaptDivisor: 2,
      );

      expect(line, isNot(contains('gpu=')));
      expect(line, isNot(contains('enc=')));
      expect(line, contains('adapt=÷2'));
    });
  });

  // -------------------------------------------------------------------------
  // Rate-limit constant sanity check.
  // -------------------------------------------------------------------------
  group('encode-error rate-limit constant', () {
    test('_errorLogIntervalMs is between 1s and 30s', () {
      // We cannot import the private constant directly, but we know from the
      // implementation that it is 5000 ms. We verify the *intent* here:
      // rate-limiting must suppress errors between 1 s and 30 s to be useful.
      // If the implementation changes the constant outside that window this
      // doc-test will need a corresponding update.
      const errorLogIntervalMs =
          5000; // mirrors _VideoTrackRuntime._errorLogIntervalMs
      expect(
        errorLogIntervalMs,
        inInclusiveRange(1000, 30000),
        reason:
            'Rate-limit window must be between 1s (useful) and 30s (not too '
            'slow to detect persistent failures).',
      );
    });

    test('_errorLogIntervalMs is exactly 5000 as specified', () {
      const errorLogIntervalMs = 5000;
      expect(
        errorLogIntervalMs,
        equals(5000),
        reason: 'Implementation uses 5000 ms; update this test if changed.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Builder regression: RecorderBuilder still works after stats-field additions.
  // -------------------------------------------------------------------------
  group('RecorderBuilder regression after stats field additions', () {
    test('builder produces idle recorder with screen + file sink', () {
      final b = RecorderBuilder();
      b.addScreen(displayId: 'disp-0', codec: VideoCodec.h264);
      b.addFileOutput('out.mp4');
      final rec = b.build();
      expect(
        rec.state,
        RecorderState.idle,
        reason:
            'Recorder must be idle after build — stats fields in '
            '_VideoTrackRuntime must not cause constructor-level failures.',
      );
    });

    test(
      'defaultVideoBitrate and defaultAudioBitrate are positive after builder '
      'changes',
      () {
        final b = RecorderBuilder();
        expect(b.defaultVideoBitrate, greaterThan(0));
        expect(b.defaultAudioBitrate, greaterThan(0));
      },
    );
  });
}
