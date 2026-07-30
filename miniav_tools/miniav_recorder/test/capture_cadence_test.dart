@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:test/test.dart';

/// Spawns a small always-on-top window repainting at ~60 Hz so screen capture
/// always has fresh frames (capture only delivers when the desktop changes).
/// Returns null when unavailable (headless CI) — callers skip on inactivity.
Future<Process?> spawnAnimator() async {
  try {
    return await Process.start('powershell', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-Command',
      r'''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object Windows.Forms.Form
$f.Width = 500; $f.Height = 400
$f.TopMost = $true
$f.StartPosition = 'CenterScreen'
$rnd = New-Object Random
$t = New-Object Windows.Forms.Timer
$t.Interval = 15
$t.add_Tick({
  $f.BackColor = [System.Drawing.Color]::FromArgb(
    $rnd.Next(256), $rnd.Next(256), $rnd.Next(256))
})
$t.Start()
[Windows.Forms.Application]::Run($f)
''',
    ]);
  } catch (_) {
    return null;
  }
}

/// Real-capture cadence check for the screen-capture pacing fix (WGC and
/// DXGI backends): with a 30 fps target the capture must deliver frames at
/// ~33.3 ms spacing — not the ~31.75 ms (31.4 fps) the old relative-sleep
/// pacing produced in timer-resolution-raised processes (WGC's
/// `Sleep(interval-2)`, DXGI's GetTickCount64 + integer-ms sleep), which made
/// the downstream fps throttle delete one frame every ~20 — a visible
/// metronomic stutter — nor the ~46.9 ms those sleeps tick-round up to in
/// default-resolution processes.
///
/// Capture only delivers frames when the desktop CHANGES, so the test spawns
/// a small always-on-top window that repaints at ~60 Hz to guarantee source
/// activity on the primary display. If the animator or a display is
/// unavailable (headless CI), the test skips instead of failing.
void main() {
  test('screen capture paces to the target interval (30 fps → ~33.3 ms)',
      () async {
    if (!Platform.isWindows) {
      markTestSkipped('DXGI capture is Windows-only.');
      return;
    }
    // Surface native DXGI logs (pacing timer type, capture-thread config).
    MiniAV.setLogLevel(MiniAVLogLevel.debug);
    MiniAV.setLogCallback(
        // ignore: avoid_print
        (level, msg) => print('[native $level] $msg'));

    final displays = await MiniScreen.enumerateDisplays();
    if (displays.isEmpty) {
      markTestSkipped('No displays to capture.');
      return;
    }

    // Best-effort; the frame-count guard below skips if the desktop turns
    // out to be static.
    final animator = await spawnAnimator();

    final displayId = displays.first.deviceId;
    final defaults = await MiniScreen.getDefaultFormats(displayId);
    final base = defaults.$1; // (videoFormat, audioFormat) record
    final format = MiniAVVideoInfo(
      width: base.width,
      height: base.height,
      pixelFormat: base.pixelFormat,
      frameRateNumerator: 30,
      frameRateDenominator: 1,
      outputPreference: MiniAVOutputPreference.cpu,
    );

    final ctx = await MiniScreen.createContext();
    final deltasUs = <int>[];
    final sw = Stopwatch()..start();
    var lastUs = -1;
    try {
      await ctx.configureDisplay(displayId, format);
      await ctx.startCapture((MiniAVBuffer buffer, Object? _) {
        final nowUs = sw.elapsedMicroseconds;
        if (lastUs >= 0) deltasUs.add(nowUs - lastUs);
        lastUs = nowUs;
        MiniAV.releaseBufferSync(buffer);
      });
      await Future<void>.delayed(const Duration(seconds: 6));
      await ctx.stopCapture();
    } finally {
      try {
        await ctx.destroy();
      } catch (_) {}
      animator?.kill();
    }

    // Ignore idle stretches (animator startup, moments nothing repainted) —
    // cadence is only defined while the source is producing.
    final active = deltasUs.where((d) => d < 50000).toList();
    if (active.length < 80) {
      markTestSkipped(
        'Not enough capture activity to measure cadence '
        '(${deltasUs.length} deltas, ${active.length} active) — '
        'static desktop or no animator window.',
      );
      return;
    }

    final meanMs =
        active.reduce((a, b) => a + b) / active.length / 1000.0;
    final fastViolations = active.where((d) => d < 30000).length;
    final fastShare = fastViolations / active.length;

    // Histogram for diagnosis (bucket edges in ms).
    const edges = [20, 30, 34, 38, 45, 50];
    final counts = List<int>.filled(edges.length + 1, 0);
    for (final d in active) {
      var b = edges.length;
      for (var i = 0; i < edges.length; i++) {
        if (d < edges[i] * 1000) {
          b = i;
          break;
        }
      }
      counts[b]++;
    }
    // ignore: avoid_print
    print('delta histogram (<20/<30/<34/<38/<45/<50/50+ ms): $counts');

    // Old pacing: mean ≈ 31.75 ms with frequent sub-31 ms deliveries.
    // New pacing: absolute 33.33 ms schedule (± present-phase jitter).
    expect(
      meanMs,
      inInclusiveRange(32.3, 35.5),
      reason: 'mean active delta $meanMs ms — a value near 31.7 ms means the '
          'capture loop is over-delivering again (n=${active.length})',
    );
    expect(
      fastShare,
      lessThan(0.15),
      reason: '${(fastShare * 100).toStringAsFixed(1)}% of deltas were '
          '<30 ms — the schedule should only run fast right after a '
          'catch-up resync',
    );
    // ignore: avoid_print
    print(
      'cadence: n=${active.length} mean=${meanMs.toStringAsFixed(2)}ms '
      'fast<30ms=${(fastShare * 100).toStringAsFixed(1)}% '
      '(target 33.33ms)',
    );
  });

  test('cfrOutput emits a gapless constant-rate PTS grid end-to-end',
      () async {
    if (!Platform.isWindows) {
      markTestSkipped('Screen capture is Windows-only here.');
      return;
    }
    final displays = await MiniScreen.enumerateDisplays();
    if (displays.isEmpty) {
      markTestSkipped('No displays to capture.');
      return;
    }
    final animator = await spawnAnimator();

    final videoPts = <int>[];
    final rec =
        (RecorderBuilder()
              ..addScreen(fps: 30, cfrOutput: true)
              ..addStreamOutput((chunk) {
                if (chunk is TrackChunk && chunk.kind == TrackKind.video) {
                  videoPts.add(chunk.ptsUs);
                }
              }))
            .build();
    try {
      await rec.start();
      await Future<void>.delayed(const Duration(seconds: 6));
    } finally {
      try {
        await rec.stop();
      } catch (_) {}
      animator?.kill();
    }

    if (videoPts.length < 100) {
      markTestSkipped(
        'Not enough video chunks (${videoPts.length}) to judge the grid — '
        'static desktop or encoder unavailable.',
      );
      return;
    }

    // Trim warm-up and the flush tail (flushed packets are stamped with
    // wall-clock PTS, not grid PTS).
    final pts = videoPts.sublist(5, videoPts.length - 3);
    final deltas = [
      for (var i = 1; i < pts.length; i++) pts[i] - pts[i - 1],
    ];
    // A 30 fps rational grid steps by 33333/33334 µs. Slots the capture
    // missed AND could not backfill (CPU-fed paths retain no duplicate
    // source) show up as multiples — allow a few, but nothing longer, and
    // the overwhelming majority must be exactly one slot.
    final exact = deltas.where((d) => d == 33333 || d == 33334).length;
    final exactShare = exact / deltas.length;
    final maxDelta = deltas.reduce((a, b) => a > b ? a : b);
    // ignore: avoid_print
    print(
      'cfr grid: n=${deltas.length} exact=${(exactShare * 100).toStringAsFixed(1)}% '
      'max=${maxDelta}µs',
    );
    expect(exactShare, greaterThan(0.85),
        reason: 'CFR output must sit on the exact fps grid');
    expect(maxDelta, lessThanOrEqualTo(4 * 33334),
        reason: 'no long presentation holes in CFR output');
  });
}
