// Native FFI verification of the new buffered (pull) capture path — the exact
// C that the web/WASM input impl drives. Also a push-path regression so the
// classic Dart-callback capture still fires (buffered mode must not disturb it).
//
// Run: dart test test/audio_capture_pull_test.dart
// Requires a working capture device (the dev box has one); ma_device_init for
// capture will otherwise fail and the pull test will report it.

@ffi.DefaultAsset('package:miniav_ffi/miniav_ffi_bindings.dart')
library;

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:miniav_ffi/modules/miniav_ffi_audio_input.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:test/test.dart';

// --- Hand-written externs for the flat pull API (bound to the miniav_c DLL) --
@ffi.Native<ffi.Pointer<ffi.Void> Function()>(
  symbol: 'MiniAV_Audio_CreateContextRet',
)
external ffi.Pointer<ffi.Void> _createRet();

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_Audio_DestroyContext',
)
external int _destroy(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int,
    ffi.Uint32,
    ffi.Uint32,
    ffi.Uint32,
  )
>(symbol: 'MiniAV_Audio_ConfigureFlat')
external int _configureFlat(
  ffi.Pointer<ffi.Void> ctx,
  int format,
  int sampleRate,
  int channels,
  int numFrames,
);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Uint32)>(
  symbol: 'MiniAV_Audio_EnableBufferedCapture',
)
external int _enableBuffered(ffi.Pointer<ffi.Void> ctx, int ringFrames);

@ffi.Native<
  ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
>(symbol: 'MiniAV_Audio_StartCapture')
external int _startCapture(
  ffi.Pointer<ffi.Void> ctx,
  ffi.Pointer<ffi.Void> callback,
  ffi.Pointer<ffi.Void> userData,
);

@ffi.Native<ffi.Int Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_Audio_StopCapture',
)
external int _stopCapture(ffi.Pointer<ffi.Void> ctx);

@ffi.Native<
  ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Uint32)
>(symbol: 'MiniAV_Audio_ReadFrames', isLeaf: true)
external int _readFrames(
  ffi.Pointer<ffi.Void> ctx,
  ffi.Pointer<ffi.Float> out,
  int maxFrames,
);

@ffi.Native<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'MiniAV_Audio_GetAvailableFrames',
  isLeaf: true,
)
external int _availableFrames(ffi.Pointer<ffi.Void> ctx);

const int _kSuccess = 0;
const int _fFloat32 = 4; // MINIAV_AUDIO_FORMAT_F32 (enum index)

void main() {
  test('buffered (pull) capture: EnableBufferedCapture → ReadFrames drains PCM',
      () async {
    const sampleRate = 48000;
    const channels = 1;

    final ctx = _createRet();
    expect(ctx, isNot(ffi.nullptr), reason: 'CreateContextRet returned NULL');

    try {
      final cfg = _configureFlat(ctx, _fFloat32, sampleRate, channels, 1024);
      expect(cfg, _kSuccess, reason: 'ConfigureFlat failed ($cfg)');

      final en = _enableBuffered(ctx, 0); // 0 => ~200ms ring
      expect(en, _kSuccess, reason: 'EnableBufferedCapture failed ($en)');

      final start = _startCapture(ctx, ffi.nullptr, ffi.nullptr);
      expect(start, _kSuccess,
          reason: 'StartCapture(NULL) failed ($start) — no capture device?');

      // Drain for ~600 ms. A running capture device fills the ring even with a
      // silent mic, so we must accumulate frames.
      final out = calloc<ffi.Float>(4096 * channels);
      var total = 0;
      try {
        for (var i = 0; i < 60; i++) {
          final avail = _availableFrames(ctx);
          expect(avail, greaterThanOrEqualTo(0));
          final n = _readFrames(ctx, out, 4096);
          expect(n, greaterThanOrEqualTo(0), reason: 'ReadFrames error ($n)');
          total += n;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      } finally {
        calloc.free(out);
      }

      expect(total, greaterThan(0),
          reason: 'no frames captured in ~600ms — device not delivering');

      expect(_stopCapture(ctx), _kSuccess);
    } finally {
      _destroy(ctx);
    }
  });

  test('re-Configure invalidates buffered ring; stop→start restarts clean',
      () async {
    const sampleRate = 48000;
    final ctx = _createRet();
    expect(ctx, isNot(ffi.nullptr));
    final out = calloc<ffi.Float>(4096);
    try {
      expect(_configureFlat(ctx, _fFloat32, sampleRate, 1, 1024), _kSuccess);
      expect(_enableBuffered(ctx, 0), _kSuccess);

      // Re-Configure (different channel count) WITHOUT re-enabling buffered
      // mode must invalidate the ring — ReadFrames then reports NOT_CONFIGURED.
      expect(_configureFlat(ctx, _fFloat32, sampleRate, 2, 1024), _kSuccess);
      expect(_readFrames(ctx, out, 512), lessThan(0),
          reason: 're-Configure must invalidate the buffered ring');

      // Re-enable + start captures normally.
      expect(_enableBuffered(ctx, 0), _kSuccess);
      expect(_startCapture(ctx, ffi.nullptr, ffi.nullptr), _kSuccess);
      var total = 0;
      for (var i = 0; i < 40; i++) {
        total += _readFrames(ctx, out, 4096);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(total, greaterThan(0));
      expect(_stopCapture(ctx), _kSuccess);
      // After stop the ring is drained; available must be 0.
      expect(_availableFrames(ctx), 0,
          reason: 'StopCapture must drain the ring');

      // Restart reuses the (empty) ring and captures fresh frames.
      expect(_startCapture(ctx, ffi.nullptr, ffi.nullptr), _kSuccess);
      var total2 = 0;
      for (var i = 0; i < 40; i++) {
        total2 += _readFrames(ctx, out, 4096);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(total2, greaterThan(0), reason: 'restart must capture again');
      expect(_stopCapture(ctx), _kSuccess);
    } finally {
      calloc.free(out);
      _destroy(ctx);
    }
  });

  test('push (callback) capture path still fires (regression)', () async {
    final platform = MiniAVFFIAudioInputPlatform();
    final ctx = await platform.createContext();
    var buffers = 0;
    try {
      await ctx.configure(
        '',
        MiniAVAudioInfo(
          format: MiniAVAudioFormat.f32,
          sampleRate: 48000,
          channels: 1,
          numFrames: 1024,
        ),
      );
      await ctx.startCapture((MiniAVBuffer buf, Object? _) {
        buffers++;
      });
      // Wait up to ~1.5 s for at least one callback.
      for (var i = 0; i < 150 && buffers == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await ctx.stopCapture();
      expect(buffers, greaterThan(0),
          reason: 'push capture delivered no buffers');
    } finally {
      await ctx.destroy();
    }
  });
}
