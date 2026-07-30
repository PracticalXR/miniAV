/// On-page smoke for the web MSE fallback ([MseController] / [MseVideoView] /
/// the capability probes). Runs in the browser on load — the reliable substitute
/// for `flutter test --platform chrome` (which can hang on browser-connect). On
/// native it renders nothing (the MSE stack is the unsupported stub).
///
/// It exercises: capability detection, MIME derivation, and the `<video>` /
/// MediaSource controller lifecycle (blob + stream modes). It does NOT decode a
/// real stream — that needs a bundled media asset — but it proves the whole
/// interop compiles and runs in a real browser.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:miniav_player/miniav_player.dart';

class MseSmoke extends StatefulWidget {
  const MseSmoke({super.key});

  @override
  State<MseSmoke> createState() => _MseSmokeState();
}

class _MseSmokeState extends State<MseSmoke> {
  String _line = 'MSE: checking…';
  bool _pass = false;
  MseController? _controller;

  @override
  void initState() {
    super.initState();
    if (kIsWeb && MseController.isSupportedPlatform) {
      _run();
    } else {
      _line = 'MSE: native (unsupported stub) — web only';
    }
  }

  Future<void> _run() async {
    try {
      final wc = webCodecsVideoAvailable();
      final mse = mseAvailable();
      final rec = mseFallbackRecommended();

      // MIME derivation (pure logic).
      final ftyp = Uint8List.fromList(
          [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0]);
      final sniff = blobMimeForBytes(ftyp);
      final typeOk =
          MseController.isTypeSupported('video/mp4; codecs="avc1.42E01E"');

      // Real playback: load a known-good H.264/MP4 asset and play it via MSE
      // (Blob mode). If MSE works, the <video> below shows the moving test card.
      final mp4 = (await rootBundle.load('assets/mse_demo.mp4'))
          .buffer
          .asUint8List();
      final player = MseController.blob(mp4, mimeType: 'video/mp4')
        ..muted = true; // muted autoplay is allowed without a user gesture
      await player.onReady.timeout(const Duration(seconds: 2));
      final viewOk = player.viewType.startsWith('miniav-mse-video-');
      await player.play();

      final pass = mse && sniff == 'video/mp4' && typeOk && viewOk;
      if (!mounted) {
        player.dispose();
        return;
      }
      setState(() {
        _controller = player; // hosts the playing <video>
        _pass = pass;
        _line = 'MSE: ${pass ? "PASS — playing mse_demo.mp4" : "FAIL"} — '
            'webCodecs=$wc mse=$mse fallbackRec=$rec sniff=$sniff '
            'typeSupported=$typeOk view=$viewOk';
      });
    } catch (e) {
      if (mounted) setState(() => _line = 'MSE: FAIL — $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _line,
          style: TextStyle(
            color: _pass ? Colors.cyanAccent : Colors.orangeAccent,
            fontSize: 12,
          ),
        ),
        // Hosts the <video> platform view (empty here — no real media appended).
        if (c != null)
          SizedBox(
            width: 160,
            height: 90,
            child: MseVideoView(
              controller: c,
              placeholder: const ColoredBox(color: Colors.black26),
            ),
          ),
      ],
    );
  }
}
