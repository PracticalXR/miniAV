// P2.1: first-party MF H.264 video ENCODE (Windows). Encodes system-memory NV12
// frames and checks the output is a valid H.264 elementary stream (NAL units +
// a keyframe + SPS available), FFmpeg-free. Skips off-Windows / no encoder MFT.
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerMfEncodeBackend;
import 'package:miniav_tools_codecs/src/codecs_native.dart';
import 'package:test/test.dart';

/// A simple moving NV12 pattern (Y gradient that shifts per frame; neutral UV).
Uint8List _nv12(int w, int h, int frame) {
  final ySize = w * h;
  final buf = Uint8List(ySize + ySize ~/ 2);
  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      buf[j * w + i] = (i + j + frame * 4) & 0xFF;
    }
  }
  for (var k = 0; k < ySize ~/ 2; k++) {
    buf[ySize + k] = 128; // neutral chroma
  }
  return buf;
}

/// NAL unit types present in an Annex-B buffer (3- or 4-byte start codes).
Set<int> _nalTypes(Uint8List d) {
  final types = <int>{};
  for (var i = 0; i + 3 < d.length; i++) {
    if (d[i] == 0 && d[i + 1] == 0) {
      int nalOff;
      if (d[i + 2] == 1) {
        nalOff = i + 3;
      } else if (d[i + 2] == 0 && d[i + 3] == 1) {
        nalOff = i + 4;
      } else {
        continue;
      }
      if (nalOff < d.length) types.add(d[nalOff] & 0x1F);
    }
  }
  return types;
}

void main() {
  test('MF H.264 encode → valid H.264 (NAL units + keyframe + SPS)', () async {
    if (!Platform.isWindows) {
      markTestSkipped('MF encode is Windows-only');
      return;
    }
    if (mfencHasMft(0) == 0) {
      markTestSkipped('no H.264 encoder MFT');
      return;
    }
    const w = 320, h = 240;
    final handle = mfencCreate(0, w, h, 2000000, 30, 1, 30);
    expect(handle, isNot(nullptr));

    final extBuf = calloc<Uint8>(256);
    final extLen = mfencGetExtradata(handle, extBuf, 256);
    final extra =
        extLen > 0 ? Uint8List.fromList(extBuf.asTypedList(extLen)) : Uint8List(0);
    calloc.free(extBuf);

    final frame = calloc<MfEncFrame>();
    final packets = <Uint8List>[];
    var keyframes = 0;
    void drain() {
      while (true) {
        final r = mfencReceive(handle, frame);
        if (r == 2) continue; // stream change
        if (r != 1) break;
        final f = frame.ref;
        if (f.size <= 0 || f.data == nullptr) break;
        packets.add(Uint8List.fromList(f.data.asTypedList(f.size)));
        if (f.isKeyframe == 1) keyframes++;
        mfencFree(f.data.cast());
      }
    }

    for (var i = 0; i < 30; i++) {
      final nv12 = _nv12(w, h, i);
      final inBuf = calloc<Uint8>(nv12.length);
      inBuf.asTypedList(nv12.length).setAll(0, nv12);
      var r = mfencSendNv12(handle, inBuf, nv12.length, i * 33333, i == 0 ? 1 : 0);
      if (r == 1) {
        drain();
        r = mfencSendNv12(handle, inBuf, nv12.length, i * 33333, 0);
      }
      calloc.free(inBuf);
      drain();
    }
    mfencDrain(handle);
    drain();
    calloc.free(frame);
    mfencDestroy(handle);

    expect(packets, isNotEmpty, reason: 'encoder produced H.264 packets');
    expect(keyframes, greaterThan(0), reason: 'at least one keyframe');

    final types = <int>{..._nalTypes(extra)};
    for (final p in packets) {
      types.addAll(_nalTypes(p));
    }
    // A coded slice (IDR=5 or non-IDR=1) must be present.
    expect(types.contains(5) || types.contains(1), isTrue,
        reason: 'coded slice NAL present; got $types');
    // SPS (7) must be available — either in extradata or in-band.
    expect(extra.isNotEmpty || types.contains(7), isTrue,
        reason: 'SPS available (extradata len=$extLen, NAL types=$types)');
  });

  test('facade selects mf_encode + encodes NV12 frames (FFmpeg excluded)',
      () async {
    if (!Platform.isWindows || mfencHasMft(0) == 0) {
      markTestSkipped('no H.264 encoder MFT');
      return;
    }
    registerMfEncodeBackend();
    const w = 320, h = 240;
    final enc = await MiniAVTools.createEncoder(
      const EncoderConfig(
        codec: VideoCodec.h264,
        width: w,
        height: h,
        bitrateBps: 2000000,
      ),
      preference: BackendPreference.excluded({'ffmpeg'}),
    );
    expect(enc.backendName, 'mf_encode');
    expect(enc.capability?.videoCodec, VideoCodec.h264);

    var packets = 0;
    for (var i = 0; i < 20; i++) {
      final p = await enc.encode(FrameSource.cpu(
        bytes: _nv12(w, h, i),
        pixelFormat: MiniAVPixelFormat.nv12,
        width: w,
        height: h,
        timestampUs: i * 33333,
      ));
      if (p != null) packets++;
    }
    packets += (await enc.flush()).length;
    await enc.close();
    expect(packets, greaterThan(0), reason: 'facade-driven encode produced AUs');
  });
}
