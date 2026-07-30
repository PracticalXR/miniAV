@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:miniav/miniav.dart';
import 'package:test/test.dart';

/// Regression check for the camera timestamp unit fix: Media Foundation
/// delivers 100 ns REFERENCE_TIME which used to be stored into
/// `timestamp_us` unconverted (10× too large) and on an epoch unrelated to
/// miniav_get_time_us(). After the fix, timestamps are rebased microseconds,
/// so at any real capture rate the inter-frame delta must look like a frame
/// interval (a few ms .. 200 ms), not 10× that.
///
/// Skips when no camera is connected (CI / headless).
void main() {
  test('camera buffer timestamps are microseconds on a sane cadence',
      () async {
    final devices = await MiniCamera.enumerateDevices();
    if (devices.isEmpty) {
      markTestSkipped('No camera devices available.');
      return;
    }

    // Try each device until one actually streams — capture cards without an
    // input source (e.g. an INOGENI with no HDMI attached) enumerate fine but
    // fail to start.
    final tsUs = <int>[];
    for (final device in devices) {
      MiniCameraContext? ctx;
      try {
        ctx = await MiniCamera.createContext();
        final formats = await MiniCamera.getSupportedFormats(device.deviceId);
        if (formats.isEmpty) continue;
        await ctx.configure(device.deviceId, formats.first);
        await ctx.startCapture((MiniAVBuffer buffer, Object? _) {
          tsUs.add(buffer.timestampUs);
          MiniAV.releaseBufferSync(buffer);
        });
        await Future<void>.delayed(const Duration(seconds: 3));
        await ctx.stopCapture();
      } catch (_) {
        // fall through to the next device
      } finally {
        try {
          await ctx?.destroy();
        } catch (_) {}
      }
      if (tsUs.length >= 10) {
        // ignore: avoid_print
        print('camera ts: using "${device.name}"');
        break;
      }
      tsUs.clear();
    }

    if (tsUs.length < 10) {
      markTestSkipped('No camera produced enough frames to judge.');
      return;
    }

    final deltas = [for (var i = 1; i < tsUs.length; i++) tsUs[i] - tsUs[i - 1]]
      ..sort();
    final median = deltas[deltas.length ~/ 2];
    // ignore: avoid_print
    print('camera ts: n=${tsUs.length} median delta=${median}µs');

    expect(median, greaterThan(1000),
        reason: 'sub-ms cadence would mean a wrong (too small) unit');
    expect(median, lessThan(200000),
        reason: 'median inter-frame delta ${median}µs — a value ~10× the '
            'frame interval means the 100ns→µs conversion regressed');
    // Monotonic non-decreasing (rebase must not jump backwards mid-run).
    for (var i = 1; i < tsUs.length; i++) {
      expect(tsUs[i], greaterThanOrEqualTo(tsUs[i - 1]),
          reason: 'timestamps must be monotonic (index $i)');
    }
  });
}
