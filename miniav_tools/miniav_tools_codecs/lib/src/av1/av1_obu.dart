/// AV1 bitstream low-level primitives:
///   * [BitWriter] — MSB-first bit packer (used by raw bytes-aligned writes
///     inside OBU payloads).
///   * `writeLeb128` — variable-length unsigned encoding (spec §4.10.5).
///   * `writeUvlc` — `uvlc()` function (spec §4.10.3).
///   * [encodeObu] — wraps a payload with an `obu_header` + size field per
///     the low-overhead bitstream format we use (`obu_has_size_field=1`,
///     `obu_extension_flag=0`).
///
/// The Phase 0 implementation only generates payloads that are bytes-aligned
/// (Temporal Delimiter is zero bytes; Sequence Header bit-packs into a single
/// byte string). Once we start emitting tile groups, the boolean coder lives
/// in `av1_bool_coder.dart` — it is *not* a BitWriter.
library;

import 'dart:typed_data';

/// MSB-first bit writer used for AV1 OBU headers and uncompressed syntax
/// elements (Sequence Header, Frame Header).
class BitWriter {
  final BytesBuilder _bytes = BytesBuilder();
  int _scratch = 0;
  int _scratchBits = 0;

  /// Number of bits written so far (does NOT include the trailing-bits pad).
  int get bitLength => _bytes.length * 8 + _scratchBits;

  /// Append the low [n] bits of [value], MSB-first.
  void writeBits(int value, int n) {
    assert(n >= 1 && n <= 32, 'writeBits: n must be 1..32');
    assert(n == 32 || (value >> n) == 0, 'value has bits above bit $n');
    var bitsLeft = n;
    while (bitsLeft > 0) {
      final canTake = 8 - _scratchBits;
      final take = bitsLeft < canTake ? bitsLeft : canTake;
      final shift = bitsLeft - take;
      final chunk = (value >> shift) & ((1 << take) - 1);
      _scratch = (_scratch << take) | chunk;
      _scratchBits += take;
      bitsLeft -= take;
      if (_scratchBits == 8) {
        _bytes.addByte(_scratch & 0xff);
        _scratch = 0;
        _scratchBits = 0;
      }
    }
  }

  /// f(1) bool. Spec §4.10.1.
  void writeFlag(bool b) => writeBits(b ? 1 : 0, 1);

  /// Append `uvlc()` per spec §4.10.3.
  void writeUvlc(int value) {
    assert(value >= 0, 'uvlc cannot be negative');
    var leadingZeros = 0;
    var v = value + 1;
    while ((1 << (leadingZeros + 1)) <= v) {
      leadingZeros++;
    }
    for (var i = 0; i < leadingZeros; i++) {
      writeBits(0, 1);
    }
    writeBits(1, 1);
    if (leadingZeros > 0) {
      writeBits(v - (1 << leadingZeros), leadingZeros);
    }
  }

  /// Trailing bits per spec §6.2.2 — a `1` followed by zero-padding to the
  /// next byte boundary. Must be called once before [toBytes].
  void writeTrailingBits() {
    writeBits(1, 1);
    if (_scratchBits != 0) {
      writeBits(0, 8 - _scratchBits);
    }
  }

  /// Byte-align by flushing the scratch byte with zeros. Used between
  /// uncompressed-header bits and the start of a payload that itself is
  /// already byte-aligned (e.g. tile group).
  void byteAlign() {
    if (_scratchBits != 0) {
      writeBits(0, 8 - _scratchBits);
    }
  }

  Uint8List toBytes() {
    assert(_scratchBits == 0, 'Bits not flushed — call writeTrailingBits()');
    return _bytes.toBytes();
  }
}

/// LEB128 unsigned, max 8 bytes. Spec §4.10.5.
Uint8List encodeLeb128(int value) {
  assert(value >= 0);
  final out = <int>[];
  var v = value;
  do {
    var byte = v & 0x7f;
    v >>= 7;
    if (v != 0) byte |= 0x80;
    out.add(byte);
  } while (v != 0);
  return Uint8List.fromList(out);
}

/// Wrap a single OBU.
///
///   obu_forbidden_bit              f(1) = 0
///   obu_type                       f(4)
///   obu_extension_flag             f(1) = 0  (no temporal/spatial layers)
///   obu_has_size_field             f(1) = 1
///   obu_reserved_1bit              f(1) = 0
///   leb128(payload.length)
///   payload bytes
Uint8List encodeObu({required int type, required Uint8List payload}) {
  final header = ((type & 0xf) << 3) | (1 << 1); // has_size_field=1
  final size = encodeLeb128(payload.length);
  final out = Uint8List(1 + size.length + payload.length);
  out[0] = header;
  out.setRange(1, 1 + size.length, size);
  out.setRange(1 + size.length, out.length, payload);
  return out;
}
