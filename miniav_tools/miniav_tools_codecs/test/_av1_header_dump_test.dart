import 'package:miniav_tools_codecs/src/av1/av1_frame_header.dart';
import 'package:test/test.dart';

void main() {
  test('dump frame header bits', () {
    final r = buildKeyFrameHeader(
      frameWidth: 64,
      frameHeight: 64,
      baseQIdx: 32,
    );
    final buf = StringBuffer('bytes=${r.payload.length}\n');
    for (var i = 0; i < r.payload.length; i++) {
      buf.writeln(
        '  [$i] 0x${r.payload[i].toRadixString(16).padLeft(2, '0')} '
        '${r.payload[i].toRadixString(2).padLeft(8, '0')}',
      );
    }
    print(buf);
  });
}
