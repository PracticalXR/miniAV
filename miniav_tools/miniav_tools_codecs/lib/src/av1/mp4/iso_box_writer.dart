/// Minimal ISOBMFF box writer used by the AV1 MP4 muxer.
///
/// Only what we need for an AV1-in-MP4 file written in a single shot at
/// `finish()` time. All sizes are 32-bit (no `largesize`); for >4GiB outputs
/// we would switch the relevant boxes to 64-bit.
library;

import 'dart:typed_data';

/// Append a 4-character box type to a [BytesBuilder].
void _writeType(BytesBuilder out, String fourCc) {
  assert(fourCc.length == 4);
  for (var i = 0; i < 4; i++) {
    out.addByte(fourCc.codeUnitAt(i));
  }
}

/// Compose a box: [size:u32][type:4cc][payload].
Uint8List box(String type, List<int> payload) {
  final size = 8 + payload.length;
  final out = BytesBuilder(copy: false);
  _u32be(out, size);
  _writeType(out, type);
  out.add(payload);
  return out.toBytes();
}

/// Compose a fullbox: [size:u32][type:4cc][version:u8][flags:u24][payload].
Uint8List fullBox(String type, int version, int flags, List<int> payload) {
  final out = BytesBuilder(copy: false);
  out.addByte(version & 0xff);
  out.addByte((flags >> 16) & 0xff);
  out.addByte((flags >> 8) & 0xff);
  out.addByte(flags & 0xff);
  out.add(payload);
  return box(type, out.toBytes());
}

void _u32be(BytesBuilder out, int v) {
  out.addByte((v >> 24) & 0xff);
  out.addByte((v >> 16) & 0xff);
  out.addByte((v >> 8) & 0xff);
  out.addByte(v & 0xff);
}

void _u16be(BytesBuilder out, int v) {
  out.addByte((v >> 8) & 0xff);
  out.addByte(v & 0xff);
}

/// Helpers used by the muxer when assembling boxes.
class BoxBuilder {
  final BytesBuilder _b = BytesBuilder(copy: false);

  int get length => _b.length;
  Uint8List toBytes() => _b.toBytes();

  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) => _u16be(_b, v);
  void u32(int v) => _u32be(_b, v);
  void u64(int v) {
    _u32be(_b, (v >> 32) & 0xffffffff);
    _u32be(_b, v & 0xffffffff);
  }

  void bytes(List<int> b) => _b.add(b);
  void fourCc(String s) => _writeType(_b, s);

  /// Reserved zeros.
  void zero(int n) {
    for (var i = 0; i < n; i++) {
      _b.addByte(0);
    }
  }
}
