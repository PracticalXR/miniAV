// Smoke test for SwAudioStreamDecoder (seekable streaming mp3/flac/vorbis).
// Run from the package root: dart run tool/stream_smoke.dart
import 'dart:io';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';

double _maxAbs(List<double> s) {
  var m = 0.0;
  for (final v in s) {
    final a = v.abs();
    if (a > m) m = a;
  }
  return m;
}

void main() async {
  final cases = <(AudioCodec, String)>[
    (AudioCodec.mp3, 'test/assets/tone.mp3'),
    (AudioCodec.flac, 'test/assets/tone.flac'),
    (AudioCodec.vorbis, 'test/assets/tone.ogg'),
  ];
  var failures = 0;
  for (final (codec, path) in cases) {
    final bytes = await File(path).readAsBytes();
    final dec = SwAudioStreamDecoder.open(codec, bytes);
    if (dec == null) {
      print('$codec: OPEN FAILED');
      failures++;
      continue;
    }
    print('$codec: ${dec.sampleRate}Hz ${dec.channels}ch '
        'total=${dec.totalFrames} (${bytes.length} compressed bytes)');

    // Sequential streaming decode.
    var frames = 0;
    var seqMax = 0.0;
    while (true) {
      final pcm = dec.read(2048);
      if (pcm.isEmpty) break;
      frames += pcm.length ~/ dec.channels;
      final m = _maxAbs(pcm);
      if (m > seqMax) seqMax = m;
    }
    print('  sequential: $frames frames, maxAbs=${seqMax.toStringAsFixed(4)}');

    // Random seek to the middle, then read.
    final mid = dec.totalFrames > 0 ? dec.totalFrames ~/ 2 : frames ~/ 2;
    final ok = dec.seekToFrame(mid);
    final pcm2 = dec.read(2048);
    print('  seek($mid)=$ok, read ${pcm2.length ~/ dec.channels} frames, '
        'maxAbs=${_maxAbs(pcm2).toStringAsFixed(4)}');

    final good = frames > 8000 && seqMax > 0.02 && ok && pcm2.isNotEmpty;
    if (!good) {
      print('  ** FAIL: frames=$frames seqMax=$seqMax seek=$ok read2=${pcm2.length}');
      failures++;
    }
    dec.close();
  }
  print(failures == 0 ? 'ALL GOOD ✓' : 'FAILURES: $failures ✗');
  exit(failures == 0 ? 0 : 1);
}
