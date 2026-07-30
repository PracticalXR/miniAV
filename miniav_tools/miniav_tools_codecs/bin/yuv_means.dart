import 'dart:io';

void main(List<String> args) {
  final f = File(args[0]);
  final w = int.parse(args[1]);
  final h = int.parse(args[2]);
  final n = args.length > 3 ? int.parse(args[3]) : 1;
  final bytes = f.readAsBytesSync();
  final perFrame = w * h * 3 ~/ 2;
  for (var i = 0; i < n; i++) {
    final base = i * perFrame;
    int sumY = 0, sumU = 0, sumV = 0;
    int minY = 255, maxY = 0;
    final ySize = w * h, cSize = w * h ~/ 4;
    for (var k = 0; k < ySize; k++) {
      final v = bytes[base + k];
      sumY += v;
      if (v < minY) minY = v;
      if (v > maxY) maxY = v;
    }
    for (var k = 0; k < cSize; k++) sumU += bytes[base + ySize + k];
    for (var k = 0; k < cSize; k++) sumV += bytes[base + ySize + cSize + k];
    print(
      'Frame $i  Y mean=${(sumY / ySize).toStringAsFixed(1)} '
      'range=[$minY..$maxY]  '
      'U mean=${(sumU / cSize).toStringAsFixed(1)}  '
      'V mean=${(sumV / cSize).toStringAsFixed(1)}',
    );
  }
}
