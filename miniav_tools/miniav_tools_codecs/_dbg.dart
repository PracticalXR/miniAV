import 'package:miniav_tools_codecs/src/av1/av1_frame_header.dart';
void main() {
  final r = buildKeyFrameHeader(frameWidth: 64, frameHeight: 64, baseQIdx: 32);
  print('bytes=' + r.payload.length.toString());
  for (final b in r.payload) {
    print(b.toRadixString(16).padLeft(2,'0') + ' ' + b.toRadixString(2).padLeft(8,'0'));
  }
}
