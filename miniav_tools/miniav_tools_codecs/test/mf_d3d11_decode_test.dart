/// Runtime proof for the Media Foundation hardware H.264 → D3D11 NV12 decode
/// path (Windows + a hardware decoder MFT, e.g. an RTX 4090 dev box).
///
/// Drives the backends directly (the facade-level "negotiator picks MF over
/// FFmpeg SW" ranking is covered by miniav_tools' negotiator_decode_test with
/// fake backends). Verifies here, against REAL hardware:
///   1. [MfDecodeBackend.probe] reports a `{mediaFoundation, zeroCopy,
///      d3d11Texture}` decode capability when a hardware MFT exists.
///   2. Real H.264 packets (encoded via FFmpeg) decode to GPU-resident frames:
///      `outputKind == d3d11Texture`, `gpuHandle != 0`, correct w/h, and
///      `readBytes()` yields a full I420 buffer.
///
/// Skips cleanly when not on Windows, FFmpeg can't load, or no hardware
/// decoder MFT exists (the negotiator would fall back to FFmpeg SW there).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:miniav_tools_codecs/src/codecs_native.dart' show mfdecHasHardware;
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show FfmpegBackend, ensureFFmpegLoaded;
import 'package:test/test.dart';

const int kW = 320;
const int kH = 240;
const int kFps = 30;

Uint8List _testCardRgba(int frame) {
  final out = Uint8List(kW * kH * 4);
  final bx = (frame * 5) % (kW - 48);
  final by = (frame * 3) % (kH - 48);
  for (var y = 0; y < kH; y++) {
    for (var x = 0; x < kW; x++) {
      final i = (y * kW + x) * 4;
      final inBlock = x >= bx && x < bx + 48 && y >= by && y < by + 48;
      out[i] = inBlock ? 255 : (x + frame * 3) % 256;
      out[i + 1] = inBlock ? 255 : (y + frame) % 256;
      out[i + 2] = inBlock ? 255 : 128;
      out[i + 3] = 255;
    }
  }
  return out;
}

Future<(List<EncodedPacket>, Uint8List?)> _encodeClip(int frames) async {
  final backend = FfmpegBackend();
  final enc = await backend.createEncoder(
    const EncoderConfig(
      codec: VideoCodec.h264,
      width: kW,
      height: kH,
      bitrateBps: 1500000,
      gopLength: kFps,
      frameRateNumerator: kFps,
      frameRateDenominator: 1,
      hwAccel: HwAccelPreference.forbidden,
      // In-isolate software encoder → deterministic, no worker relay.
      backendOptions: {'sw_isolate': '0'},
    ),
  );
  final packets = <EncodedPacket>[];
  for (var i = 0; i < frames; i++) {
    final pkt = await enc!.encode(
      FrameSource.cpu(
        bytes: _testCardRgba(i),
        pixelFormat: MiniAVPixelFormat.rgba32,
        width: kW,
        height: kH,
        timestampUs: (i * 1000000) ~/ kFps,
      ),
    );
    if (pkt != null) packets.add(pkt);
  }
  packets.addAll(await enc!.flush());
  final asc = enc.extraData?.bytes;
  await enc.close();
  return (packets, asc);
}

void main() {
  group('MF D3D11 decode', () {
    var haveHw = false;

    setUpAll(() async {
      if (!Platform.isWindows) return;
      // FFmpeg is loaded only for the H.264 ENCODER (the test's packet source);
      // the MF DECODER under test is FFmpeg-free (codecs_native asset).
      final ff = await ensureFFmpegLoaded();
      var hw = false;
      try {
        hw = mfdecHasHardware(0);
      } catch (_) {}
      // ignore: avoid_print
      print('MF-DIAG: ffmpegLoaded=$ff hasHardware=$hw');
      haveHw = hw;
    });

    test('probe reports the mediaFoundation zero-copy decode capability',
        () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows only');
        return;
      }
      if (!haveHw) {
        markTestSkipped('no hardware H.264 decoder MFT on this machine');
        return;
      }
      final caps = await MfDecodeBackend().probe(
        const CodecQuery.video(VideoCodec.h264, CodecDirection.decode),
      );
      expect(caps, hasLength(1));
      expect(caps.single.hwPath, HwPath.mediaFoundation);
      expect(caps.single.isHardware, isTrue);
      expect(caps.single.zeroCopy, isTrue);
      expect(
        caps.single.producedOutputs,
        contains(FrameSourceKind.d3d11Texture),
      );
    });

    test('decodes real H.264 packets to D3D11 NV12 textures', () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows only');
        return;
      }
      if (!haveHw) {
        markTestSkipped('no hardware H.264 decoder MFT on this machine');
        return;
      }

      final (packets, asc) = await _encodeClip(45);
      expect(packets, isNotEmpty, reason: 'encoder produced no packets');

      final dec = await MfDecodeBackend().createDecoder(
        DecoderConfig(
          codec: VideoCodec.h264,
          extraData: asc,
          backendOptions: const {'sw_isolate': '0'}, // in-isolate (dart test MTA)
        ),
      );
      expect(dec, isNotNull, reason: 'MF decoder failed to open on HW');

      final frames = <DecodedFrame>[];
      for (final p in packets) {
        final f = await dec!.decode(p);
        if (f != null) frames.add(f);
      }
      frames.addAll(await dec!.flush());

      expect(frames, isNotEmpty, reason: 'decoder produced no frames');

      final first = frames.first;
      expect(first.outputKind, FrameSourceKind.d3d11Texture);
      expect(first.gpuHandle, isNot(0));
      expect(first.width, kW);
      expect(first.height, kH);

      // CPU map → I420 (Milestone-1 present path).
      final i420 = await first.readBytes();
      expect(i420.length, kW * kH + 2 * ((kW ~/ 2) * (kH ~/ 2)));

      for (final f in frames) {
        f.close();
      }
      await dec.close();
    });
  });
}
