// Verifies that every decoded inter frame is byte-identical to the decoded
// key frame (frame 0), proving the Phase-1 "copy reference" P-frame path is
// bit-exact through dav1d.
//
// Usage:  dart run bin/av1_inter_check.dart <decoded.yuv> <W> <H> <numFrames>
import 'dart:io';

void main(List<String> argv) {
  if (argv.length < 4) {
    stderr.writeln('usage: av1_inter_check.dart <decoded.yuv> <W> <H> <N>');
    exit(2);
  }
  final path = argv[0];
  final w = int.parse(argv[1]);
  final h = int.parse(argv[2]);
  final n = int.parse(argv[3]);

  final frameSize = w * h + 2 * ((w >> 1) * (h >> 1));
  final data = File(path).readAsBytesSync();
  final got = data.length ~/ frameSize;
  stdout.writeln(
    'frame size $frameSize B, file ${data.length} B → $got frame(s) '
    '(expected $n)',
  );
  if (got < 2) {
    stderr.writeln('FAIL: need at least 2 decoded frames to compare');
    exit(1);
  }

  var allOk = true;
  for (var f = 1; f < got; f++) {
    var diffs = 0;
    var maxDiff = 0;
    for (var i = 0; i < frameSize; i++) {
      final a = data[i];
      final b = data[f * frameSize + i];
      if (a != b) {
        diffs++;
        final d = (a - b).abs();
        if (d > maxDiff) maxDiff = d;
      }
    }
    if (diffs == 0) {
      stdout.writeln('frame $f == frame 0  ✓');
    } else {
      allOk = false;
      stdout.writeln(
        'frame $f != frame 0  ✗  ($diffs/$frameSize bytes differ, '
        'max |Δ|=$maxDiff)',
      );
    }
  }

  if (allOk) {
    stdout.writeln('PASS: all inter frames identical to the key frame');
    exit(0);
  } else {
    stdout.writeln('FAIL: inter frames diverge from the key frame');
    exit(1);
  }
}
