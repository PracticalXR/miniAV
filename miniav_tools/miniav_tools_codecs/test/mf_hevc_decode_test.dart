/// HEVC through the MF pair: MS HEVC encoder MFT → hardware HEVC decoder MFT.
///
/// Regression for a native crash: the Microsoft HEVC decoder MFT (HEVC Video
/// Extensions) hard-crashed (access violation) inside
/// `ProcessMessage(NOTIFY_BEGIN_STREAMING)` when its output type was still
/// unset — which is ALWAYS the case for HEVC at create time, because unlike
/// the H.264 MFT it cannot propose an output type until it parses an SPS.
/// `mf_decoder.c` now defers the streaming notifications for a sync MFT until
/// the lazy output negotiation succeeds; this test pins both the crash-free
/// create AND a real decode.
///
/// Skips when the machine lacks the HEVC encoder MFT (HEVC Video Extensions)
/// or a hardware HEVC decoder.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show MfDecodeBackend, MfEncodeBackend;
import 'package:miniav_tools_codecs/src/codecs_native.dart'
    show mfdecHasHardware, mfencHasMft;
import 'package:test/test.dart';

const kW = 320, kH = 240, kFps = 30;

/// Moving NV12 gradient (Y shifts per frame; neutral chroma).
Uint8List _nv12(int frame) {
  final ySize = kW * kH;
  final buf = Uint8List(ySize + ySize ~/ 2);
  for (var j = 0; j < kH; j++) {
    for (var i = 0; i < kW; i++) {
      buf[j * kW + i] = (i + j + frame * 4) & 0xFF;
    }
  }
  buf.fillRange(ySize, buf.length, 128);
  return buf;
}

void main() {
  test('MF HEVC encode → HW decode round-trips without crashing', () async {
    if (!Platform.isWindows) {
      markTestSkipped('MF is Windows-only');
      return;
    }
    if (mfencHasMft(1) == 0) {
      markTestSkipped('no HEVC encoder MFT (HEVC Video Extensions absent)');
      return;
    }
    if (!mfdecHasHardware(1)) {
      markTestSkipped('no hardware HEVC decoder MFT');
      return;
    }

    final enc = await MfEncodeBackend().createEncoder(const EncoderConfig(
      codec: VideoCodec.hevc,
      width: kW,
      height: kH,
      bitrateBps: 1500000,
      gopLength: kFps,
      frameRateNumerator: kFps,
      frameRateDenominator: 1,
      hwAccel: HwAccelPreference.forbidden,
    ));
    expect(enc, isNotNull, reason: 'MF HEVC encoder failed to open');

    final packets = <EncodedPacket>[];
    for (var i = 0; i < 45; i++) {
      final pkt = await enc!.encode(CpuFrameSource(
        bytes: _nv12(i),
        pixelFormat: MiniAVPixelFormat.nv12,
        width: kW,
        height: kH,
        timestampUs: (i * 1000000) ~/ kFps,
      ));
      if (pkt != null) packets.add(pkt);
    }
    packets.addAll(await enc!.flush());
    final extra = enc.extraData?.bytes;
    await enc.close();
    expect(packets, isNotEmpty, reason: 'HEVC encoder produced no packets');

    // The crash was here: decoder create with the (deferred) HEVC output type.
    // width/height: the HEVC decoder MFT needs the coded dims on its input
    // type — without them it rejects all input (MF_E_TRANSFORM_TYPE_NOT_SET).
    final dec = await MfDecodeBackend().createDecoder(DecoderConfig(
      codec: VideoCodec.hevc,
      extraData: extra,
      width: kW,
      height: kH,
      backendOptions: const {'sw_isolate': '0'}, // in-isolate (dart test MTA)
    ));
    expect(dec, isNotNull, reason: 'MF HEVC decoder failed to open');

    final frames = <DecodedFrame>[];
    for (final p in packets) {
      final f = await dec!.decode(p);
      if (f != null) frames.add(f);
    }
    frames.addAll(await dec!.flush());
    expect(frames, isNotEmpty, reason: 'HEVC decoder produced no frames');
    expect(frames.first.width, kW);
    expect(frames.first.height, kH);

    // CPU map sanity: tightly-packed I420 for the coded dims.
    final bytes = await frames.first.readBytes();
    expect(bytes.length, kW * kH + 2 * ((kW ~/ 2) * (kH ~/ 2)));

    for (final f in frames) {
      f.close();
    }
    await dec.close();
  });
}
