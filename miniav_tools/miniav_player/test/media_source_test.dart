import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniav_player/miniav_player.dart';

void main() {
  test('MediaSource.file maps to FileDemuxerInput', () {
    final input = const MediaSource.file('/x/y.mp4').toDemuxerInput();
    expect(input, isA<FileDemuxerInput>());
    expect((input as FileDemuxerInput).path, '/x/y.mp4');
  });

  test('MediaSource.bytes maps to BytesDemuxerInput', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final input = MediaSource.bytes(bytes).toDemuxerInput();
    expect(input, isA<BytesDemuxerInput>());
    expect((input as BytesDemuxerInput).bytes, same(bytes));
  });

  test('MediaSource.byteStream maps stream + buffer size through', () {
    final ctrl = StreamController<List<int>>();
    final stream = ctrl.stream;
    final input = MediaSource.byteStream(
      stream,
      bufferBytes: 1024,
    ).toDemuxerInput();
    expect(input, isA<StreamDemuxerInput>());
    final s = input as StreamDemuxerInput;
    expect(s.stream, same(stream));
    expect(s.bufferBytes, 1024);
    ctrl.close();
  });
}
