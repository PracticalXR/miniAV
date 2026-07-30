// Native-assets FFI smoke for the audio-output module: builds miniav_c, loads
// it, resolves the MiniAV_AudioOutput_* symbols (via @DefaultAsset), and runs
// the full create → configure → start → writeFrames → controls → destroy path.
//
// Run: dart test test/audio_output_ffi_test.dart

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_ffi/modules/miniav_ffi_audio_output.dart';
import 'package:miniav_platform_interface/miniav_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  test('MiniAV_AudioOutput_* resolves and plays f32 PCM through the sink',
      () async {
    const sampleRate = 48000;
    const channels = 2;

    final platform = MiniAVFFIAudioOutputPlatform();

    // Enumerate should return at least the default device on a dev box.
    final devices = await platform.enumerateDevices();
    expect(devices, isNotEmpty);

    final ctx = await platform.createContext();

    await ctx.configure(
      '',
      MiniAVAudioInfo(
        format: MiniAVAudioFormat.f32,
        sampleRate: sampleRate,
        channels: channels,
        numFrames: 0,
      ),
      bufferFrames: sampleRate ~/ 10,
    );

    ctx.volume = 0.2;
    expect(ctx.volume, closeTo(0.2, 1e-4));
    ctx.pan = -0.3;
    expect(ctx.pan, closeTo(-0.3, 1e-4));

    await ctx.start();
    expect(ctx.isStarted, isTrue);

    const toneHz = 440.0;
    const chunkFrames = 480;
    final chunk = Float32List(chunkFrames * channels);
    var phase = 0.0;
    final inc = 2 * math.pi * toneHz / sampleRate;
    var totalAccepted = 0;

    for (var c = 0; c < 40; c++) {
      for (var f = 0; f < chunkFrames; f++) {
        final s = math.sin(phase);
        phase += inc;
        if (phase > 2 * math.pi) phase -= 2 * math.pi;
        chunk[f * channels] = s;
        chunk[f * channels + 1] = s;
      }
      var offset = 0;
      while (offset < chunkFrames) {
        final view = offset == 0
            ? chunk
            : Float32List.sublistView(chunk, offset * channels);
        final accepted = ctx.writeFrames(view, chunkFrames - offset);
        expect(accepted, greaterThanOrEqualTo(0));
        offset += accepted;
        totalAccepted += accepted;
        if (accepted == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(totalAccepted, greaterThan(15000));
    expect(ctx.bufferedFrames, greaterThanOrEqualTo(0));

    await ctx.stop();
    await ctx.clear();
    await ctx.destroy();
  });
}
