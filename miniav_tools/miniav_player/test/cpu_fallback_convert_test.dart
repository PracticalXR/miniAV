// The CPU present fallback's colour convert must be IDENTICAL to the player's
// fast (GPU) path, else the same video looks different depending on whether a
// platform has zero-copy present. This pins the native C converter
// (CpuFrameConverter, codecs) byte-for-byte against the player's canonical
// decode reference (yuv420pToRgba8 — the lockstep target for the WGSL kernel),
// and checks the C output is validly consumed by dart:ui as rgba8888.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/src/yuv_rgba_reference.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';

/// The fallback subtree MiniavPlayerView paints for a published ui.Image
/// (mirrors player_view.dart's CPU-fallback branch). Extracted here so a
/// regression test can pin its layout behaviour in an unbounded-axis parent.
Widget _fallbackSubtree(ui.Image image,
        {BoxFit fit = BoxFit.contain,
        Alignment alignment = Alignment.center}) =>
    FittedBox(
      fit: fit,
      alignment: alignment,
      child: SizedBox(
        width: image.width.toDouble(),
        height: image.height.toDouble(),
        child: RawImage(image: image, filterQuality: FilterQuality.medium),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CpuFrameConverter (C) == player GPU-path reference, byte-exact', () {
    const w = 64, h = 48; // even dims (the reference requires even)
    final cw = w >> 1, ch = h >> 1;
    final yuv = Uint8List(w * h + 2 * cw * ch);
    var s = 0xC0FFEE;
    for (var i = 0; i < yuv.length; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      yuv[i] = (s >> 8) & 0xff;
    }
    final reference = yuv420pToRgba8(yuv, w, h);
    final c = CpuFrameConverter();
    try {
      final got = Uint8List.fromList(c.i420ToRgba(yuv, w, h));
      expect(got, equals(reference),
          reason: 'fallback convert diverged from the player decode reference');
    } finally {
      c.dispose();
    }
  });

  testWidgets('C RGBA decodes to a ui.Image with the expected pixels',
      (tester) async {
    // Solid mid-gray-ish frame; verify decodeImageFromPixels reads the C output
    // as rgba8888 and round-trips the exact bytes back. The engine decode +
    // toByteData callbacks only pump inside runAsync() in flutter_test.
    await tester.runAsync(() async {
      const w = 8, h = 8;
      final cw = w >> 1, ch = h >> 1;
      final yuv = Uint8List(w * h + 2 * cw * ch)
        ..fillRange(0, w * h, 150) // Y
        ..fillRange(w * h, w * h + cw * ch, 128) // U (neutral)
        ..fillRange(w * h + cw * ch, w * h + 2 * cw * ch, 128); // V (neutral)

      final rgba = cpuI420ToRgba(yuv, w, h);
      final image = await _decode(rgba, w, h);
      expect(image.width, w);
      expect(image.height, h);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      expect(bytes.length, w * h * 4);
      // Neutral chroma + Y=150 -> a gray; every pixel identical, A=255.
      final r0 = bytes[0], g0 = bytes[1], b0 = bytes[2];
      expect(bytes[3], 255);
      expect(r0, equals(g0)); // neutral chroma => R==G==B (gray)
      expect(g0, equals(b0));
      for (var p = 0; p < w * h; p++) {
        expect(bytes[p * 4], r0);
        expect(bytes[p * 4 + 3], 255);
      }
      image.dispose();
    });
  });

  testWidgets('fallback subtree lays out in an unbounded-height parent',
      (tester) async {
    // Regression for the SizedBox.expand crash: the CPU-fallback image subtree
    // must survive an unbounded-axis parent (Column/ListView) — the layouts the
    // view's doc invites — not just the tight-bounded Positioned.fill the
    // shipped example uses.
    late ui.Image image;
    await tester.runAsync(() async {
      const w = 16, h = 8;
      final cw = w >> 1, ch = h >> 1;
      final yuv = Uint8List(w * h + 2 * cw * ch)
        ..fillRange(0, w * h, 120)
        ..fillRange(w * h, w * h + 2 * cw * ch, 128);
      image = await _decode(cpuI420ToRgba(yuv, w, h), w, h);
    });

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [_fallbackSubtree(image)], // unbounded height
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsOneWidget);
    image.dispose();
  });
}

Future<ui.Image> _decode(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}
