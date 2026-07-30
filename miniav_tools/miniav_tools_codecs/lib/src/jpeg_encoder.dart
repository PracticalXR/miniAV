/// Minimal baseline JPEG / JFIF encoder (pure Dart).
///
/// Standards-compliant enough to interop with `libavcodec`'s `mjpeg` decoder
/// and consumer image viewers. Used by [MinigpuMjpegPipeline] as the CPU tail
/// of the GPU codec pipeline. Future iterations move DCT + quantization to
/// WGSL shader stages and keep only Huffman + JFIF marker writing on the CPU.
///
/// Supported:
///   - 4:4:4 chroma sampling (no subsampling) for simplicity.
///   - Baseline DCT (SOF0) + standard JFIF Huffman tables (DC/AC × luma/chroma).
///   - Quality 1..100 mapping per IJG `jpeg_set_quality` formula.
///
/// Input: YCbCr planar (Y, Cb, Cr) each `width*height` bytes in `[0, 255]`.
/// Output: a JFIF byte stream (SOI ... EOI).
library;

import 'dart:typed_data';

/// Standard JPEG quantization tables (Annex K).
const List<int> _stdLumaQuant = [
  16,
  11,
  10,
  16,
  24,
  40,
  51,
  61,
  12,
  12,
  14,
  19,
  26,
  58,
  60,
  55,
  14,
  13,
  16,
  24,
  40,
  57,
  69,
  56,
  14,
  17,
  22,
  29,
  51,
  87,
  80,
  62,
  18,
  22,
  37,
  56,
  68,
  109,
  103,
  77,
  24,
  35,
  55,
  64,
  81,
  104,
  113,
  92,
  49,
  64,
  78,
  87,
  103,
  121,
  120,
  101,
  72,
  92,
  95,
  98,
  112,
  100,
  103,
  99,
];

const List<int> _stdChromaQuant = [
  17,
  18,
  24,
  47,
  99,
  99,
  99,
  99,
  18,
  21,
  26,
  66,
  99,
  99,
  99,
  99,
  24,
  26,
  56,
  99,
  99,
  99,
  99,
  99,
  47,
  66,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
  99,
];

/// Zigzag scan order (8×8 → 64).
const List<int> _zigzag = [
  0,
  1,
  8,
  16,
  9,
  2,
  3,
  10,
  17,
  24,
  32,
  25,
  18,
  11,
  4,
  5,
  12,
  19,
  26,
  33,
  40,
  48,
  41,
  34,
  27,
  20,
  13,
  6,
  7,
  14,
  21,
  28,
  35,
  42,
  49,
  56,
  57,
  50,
  43,
  36,
  29,
  22,
  15,
  23,
  30,
  37,
  44,
  51,
  58,
  59,
  52,
  45,
  38,
  31,
  39,
  46,
  53,
  60,
  61,
  54,
  47,
  55,
  62,
  63,
];

// Standard JPEG Huffman tables (Annex K.3).
const List<int> _dcLumBits = [
  0,
  0,
  1,
  5,
  1,
  1,
  1,
  1,
  1,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];
const List<int> _dcLumVal = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _dcChrBits = [
  0,
  0,
  3,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  0,
  0,
  0,
  0,
  0,
];
const List<int> _dcChrVal = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _acLumBits = [
  0,
  0,
  2,
  1,
  3,
  3,
  2,
  4,
  3,
  5,
  5,
  4,
  4,
  0,
  0,
  1,
  0x7d,
];
const List<int> _acLumVal = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, //
  0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
  0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
  0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
  0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
  0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
  0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
  0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
  0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
  0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];
const List<int> _acChrBits = [
  0,
  0,
  2,
  1,
  2,
  4,
  4,
  3,
  4,
  7,
  5,
  4,
  4,
  0,
  1,
  2,
  0x77,
];
const List<int> _acChrVal = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, //
  0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
  0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
  0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
  0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
  0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
  0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
  0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
  0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
  0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
  0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
  0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
  0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
  0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

/// Build a Huffman code lookup: `huffCode[symbol] = (code, length)`.
class _Huffman {
  final Uint16List code;
  final Uint8List length;
  _Huffman(this.code, this.length);

  factory _Huffman.build(List<int> bits, List<int> values) {
    // Standard table-build (per JPEG Annex C.2).
    final huffSize = <int>[];
    final huffCode = <int>[];
    var p = 0;
    for (var l = 1; l <= 16; l++) {
      for (var i = 1; i <= bits[l]; i++) {
        huffSize.add(l);
        p++;
      }
    }
    huffSize.add(0);

    var code = 0;
    var si = huffSize[0];
    var k = 0;
    while (huffSize[k] != 0) {
      while (huffSize[k] == si) {
        huffCode.add(code);
        code++;
        k++;
      }
      code <<= 1;
      si++;
    }

    final codeOut = Uint16List(256);
    final lenOut = Uint8List(256);
    for (var i = 0; i < values.length; i++) {
      codeOut[values[i]] = huffCode[i];
      lenOut[values[i]] = huffSize[i];
    }
    return _Huffman(codeOut, lenOut);
  }
}

class _BitWriter {
  _BitWriter(this._bytes);
  final BytesBuilder _bytes;
  int _buffer = 0;
  int _bitsInBuffer = 0;

  void writeBits(int code, int length) {
    if (length == 0) return;
    _buffer = (_buffer << length) | (code & ((1 << length) - 1));
    _bitsInBuffer += length;
    while (_bitsInBuffer >= 8) {
      _bitsInBuffer -= 8;
      final b = (_buffer >> _bitsInBuffer) & 0xff;
      _bytes.addByte(b);
      // JPEG byte-stuffing: 0xff in entropy data must be followed by 0x00.
      if (b == 0xff) _bytes.addByte(0x00);
    }
  }

  void flush() {
    if (_bitsInBuffer > 0) {
      // Pad with 1-bits per JPEG rules.
      final pad = 8 - _bitsInBuffer;
      writeBits((1 << pad) - 1, pad);
    }
  }
}

/// Forward 8×8 DCT (AAN integer-friendly). Operates in-place on a Float32List
/// of length 64 (row-major). After this call the array contains floating
/// point DCT coefficients; quantization handles rounding to ints.
void _fdct8x8(Float32List b) {
  // Type-II DCT, AAN factorization. Two passes (rows then cols).
  for (var pass = 0; pass < 2; pass++) {
    for (var i = 0; i < 8; i++) {
      // Index helpers: row-pass uses [i*8 + k]; col-pass uses [k*8 + i].
      int idx(int k) => pass == 0 ? i * 8 + k : k * 8 + i;
      final t0 = b[idx(0)] + b[idx(7)];
      final t7 = b[idx(0)] - b[idx(7)];
      final t1 = b[idx(1)] + b[idx(6)];
      final t6 = b[idx(1)] - b[idx(6)];
      final t2 = b[idx(2)] + b[idx(5)];
      final t5 = b[idx(2)] - b[idx(5)];
      final t3 = b[idx(3)] + b[idx(4)];
      final t4 = b[idx(3)] - b[idx(4)];

      final c0 = t0 + t3;
      final c3 = t0 - t3;
      final c1 = t1 + t2;
      final c2 = t1 - t2;

      b[idx(0)] = c0 + c1;
      b[idx(4)] = c0 - c1;

      final z1 = (c2 + c3) * 0.7071067811865476;
      b[idx(2)] = c3 + z1;
      b[idx(6)] = c3 - z1;

      final z5 = (t4 - t6) * 0.38268343236508984;
      final z2 = 0.5411961001461971 * t6 + z5;
      final z4 = 1.3065629648763766 * t4 + z5;
      final z3 = t5 * 0.7071067811865476;

      final z11 = t7 + z3;
      final z13 = t7 - z3;

      b[idx(5)] = z13 + z2;
      b[idx(3)] = z13 - z2;
      b[idx(1)] = z11 + z4;
      b[idx(7)] = z11 - z4;
    }
  }
}

/// Quantize one 8×8 block in-place and return zigzag-ordered Int16 coeffs.
Int16List _quantizeAndZigzag(Float32List block, Int32List quant) {
  final out = Int16List(64);
  for (var i = 0; i < 64; i++) {
    final v = block[i] / quant[i];
    out[_zigzag[i]] = v >= 0 ? (v + 0.5).floor() : -((-v + 0.5).floor());
  }
  return out;
}

/// Encode one 8×8 quantized + zigzagged block.
void _encodeBlock(
  _BitWriter w,
  Int16List zz,
  int prevDc,
  _Huffman dcHuff,
  _Huffman acHuff,
) {
  // DC: difference from previous DC, then size-category code.
  final dc = zz[0];
  final diff = dc - prevDc;
  if (diff == 0) {
    w.writeBits(dcHuff.code[0], dcHuff.length[0]);
  } else {
    final size = _bitSize(diff);
    w.writeBits(dcHuff.code[size], dcHuff.length[size]);
    w.writeBits(_signedBits(diff, size), size);
  }
  // AC: run-length of zeros + non-zero coefficient.
  var zeroRun = 0;
  for (var k = 1; k < 64; k++) {
    final c = zz[k];
    if (c == 0) {
      zeroRun++;
      continue;
    }
    while (zeroRun >= 16) {
      // ZRL = 0xF0
      w.writeBits(acHuff.code[0xF0], acHuff.length[0xF0]);
      zeroRun -= 16;
    }
    final size = _bitSize(c);
    final symbol = (zeroRun << 4) | size;
    w.writeBits(acHuff.code[symbol], acHuff.length[symbol]);
    w.writeBits(_signedBits(c, size), size);
    zeroRun = 0;
  }
  if (zeroRun > 0) {
    // EOB = 0x00
    w.writeBits(acHuff.code[0x00], acHuff.length[0x00]);
  }
}

int _bitSize(int v) {
  if (v < 0) v = -v;
  var n = 0;
  while (v != 0) {
    v >>= 1;
    n++;
  }
  return n;
}

int _signedBits(int v, int size) {
  // Negative numbers store one's complement of |v| in `size` bits.
  if (v < 0) v = (1 << size) - 1 + v;
  return v & ((1 << size) - 1);
}

/// Quality-scale a quantization table per IJG `jpeg_set_quality`.
Int32List _scaledQuant(List<int> base, int quality) {
  var q = quality.clamp(1, 100);
  final scale = q < 50 ? 5000 ~/ q : 200 - q * 2;
  final out = Int32List(64);
  for (var i = 0; i < 64; i++) {
    var v = (base[i] * scale + 50) ~/ 100;
    if (v < 1) v = 1;
    if (v > 255) v = 255;
    out[i] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Public utilities for GPU-path JFIF assembly.
// ---------------------------------------------------------------------------

/// Pre-built standard JPEG Huffman table accessors (read-only).
///
/// The tables are the JPEG Annex K standard tables — identical to what the
/// CPU encoder uses, so GPU-coded scan data is decodeable by any JPEG decoder.
/// Used by [MinigpuMjpegPipeline] to embed Huffman codes as WGSL const arrays.
class JpegStandardTables {
  JpegStandardTables._();

  static final _dcLum = _Huffman.build(_dcLumBits, _dcLumVal);
  static final _dcChr = _Huffman.build(_dcChrBits, _dcChrVal);
  static final _acLum = _Huffman.build(_acLumBits, _acLumVal);
  static final _acChr = _Huffman.build(_acChrBits, _acChrVal);

  static Uint16List get dcLumaCode => _dcLum.code;
  static Uint8List get dcLumaLen => _dcLum.length;
  static Uint16List get dcChromaCode => _dcChr.code;
  static Uint8List get dcChromaLen => _dcChr.length;
  static Uint16List get acLumaCode => _acLum.code;
  static Uint8List get acLumaLen => _acLum.length;
  static Uint16List get acChromaCode => _acChr.code;
  static Uint8List get acChromaLen => _acChr.length;

  /// Quality-scaled luma quantization table (natural order, 64 entries).
  static Int32List lumaQt(int quality) => _scaledQuant(_stdLumaQuant, quality);

  /// Quality-scaled chroma quantization table (natural order, 64 entries).
  static Int32List chromaQt(int quality) =>
      _scaledQuant(_stdChromaQuant, quality);
}

/// Emit JFIF markers from SOI through SOS (header only, no scan data).
///
/// The restart interval marker (DRI) is inserted before SOS so that GPU-coded
/// scan data — which resets DC prediction at each MCU — decodes correctly.
/// The caller appends MCU bytes (with RST0..7 between them) and then `EOI`.
Uint8List encodeJpegHeader({
  required int width,
  required int height,
  required int quality,
  int rstInterval = 1,
}) {
  final qY = _scaledQuant(_stdLumaQuant, quality);
  final qC = _scaledQuant(_stdChromaQuant, quality);
  final out = BytesBuilder();

  // SOI
  out.add([0xFF, 0xD8]);

  // APP0 / JFIF marker
  out.add([
    0xFF, 0xE0, 0x00, 0x10,
    0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
    0x01, 0x01,
    0x00,
    0x00, 0x01, 0x00, 0x01,
    0x00, 0x00,
  ]);

  // DQT — luma table 0
  out.add([0xFF, 0xDB, 0x00, 0x43, 0x00]);
  for (var i = 0; i < 64; i++) out.addByte(qY[_zigzag[i]]);
  // DQT — chroma table 1
  out.add([0xFF, 0xDB, 0x00, 0x43, 0x01]);
  for (var i = 0; i < 64; i++) out.addByte(qC[_zigzag[i]]);

  // SOF0 — baseline DCT, 3 components, 4:4:4 sampling.
  out.add([
    0xFF,
    0xC0,
    0x00,
    0x11,
    0x08,
    (height >> 8) & 0xff,
    height & 0xff,
    (width >> 8) & 0xff,
    width & 0xff,
    0x03,
    0x01,
    0x11,
    0x00,
    0x02,
    0x11,
    0x01,
    0x03,
    0x11,
    0x01,
  ]);

  // DHT × 4
  void writeHuff(int classAndId, List<int> bits, List<int> values) {
    final len = 2 + 1 + 16 + values.length;
    out.add([0xFF, 0xC4, (len >> 8) & 0xff, len & 0xff, classAndId]);
    out.add(bits.sublist(1, 17));
    out.add(values);
  }

  writeHuff(0x00, _dcLumBits, _dcLumVal);
  writeHuff(0x10, _acLumBits, _acLumVal);
  writeHuff(0x01, _dcChrBits, _dcChrVal);
  writeHuff(0x11, _acChrBits, _acChrVal);

  // DRI — restart interval
  out.add([
    0xFF,
    0xDD,
    0x00,
    0x04,
    (rstInterval >> 8) & 0xff,
    rstInterval & 0xff,
  ]);

  // SOS — start of scan header (entropy data follows immediately after).
  out.add([
    0xFF,
    0xDA,
    0x00,
    0x0C,
    0x03,
    0x01,
    0x00,
    0x02,
    0x11,
    0x03,
    0x11,
    0x00,
    0x3F,
    0x00,
  ]);

  return out.toBytes();
}

/// Encode a YCbCr 4:4:4 frame as baseline JPEG / JFIF.
///
/// [y], [cb], [cr] each have `width*height` bytes, range `[0, 255]`.
/// [quality] ∈ [1, 100]; 75 is the standard "good" default.
Uint8List encodeJpeg444({
  required Uint8List y,
  required Uint8List cb,
  required Uint8List cr,
  required int width,
  required int height,
  int quality = 75,
}) {
  if (y.length != width * height ||
      cb.length != width * height ||
      cr.length != width * height) {
    throw ArgumentError(
      'plane sizes must equal width*height (=${width * height}); '
      'got y=${y.length} cb=${cb.length} cr=${cr.length}',
    );
  }

  final qY = _scaledQuant(_stdLumaQuant, quality);
  final qC = _scaledQuant(_stdChromaQuant, quality);

  final dcLum = _Huffman.build(_dcLumBits, _dcLumVal);
  final acLum = _Huffman.build(_acLumBits, _acLumVal);
  final dcChr = _Huffman.build(_dcChrBits, _dcChrVal);
  final acChr = _Huffman.build(_acChrBits, _acChrVal);

  final out = BytesBuilder();

  // SOI
  out.add([0xFF, 0xD8]);

  // APP0 / JFIF marker
  out.add([
    0xFF, 0xE0, 0x00, 0x10, // marker + len(16)
    0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
    0x01, 0x01, // version 1.1
    0x00, // aspect ratio units = none
    0x00, 0x01, 0x00, 0x01, // X/Y density = 1
    0x00, 0x00, // thumbnail 0×0
  ]);

  // DQT — luma table 0
  out.add([0xFF, 0xDB, 0x00, 0x43, 0x00]);
  for (var i = 0; i < 64; i++) {
    out.addByte(qY[_zigzag[i]]);
  }
  // DQT — chroma table 1
  out.add([0xFF, 0xDB, 0x00, 0x43, 0x01]);
  for (var i = 0; i < 64; i++) {
    out.addByte(qC[_zigzag[i]]);
  }

  // SOF0 — baseline DCT, 3 components, 4:4:4 sampling.
  out.add([
    0xFF, 0xC0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03,
    0x01, 0x11, 0x00, // Y:  H=1 V=1, qtable 0
    0x02, 0x11, 0x01, // Cb: H=1 V=1, qtable 1
    0x03, 0x11, 0x01, // Cr: H=1 V=1, qtable 1
  ]);

  // DHT × 4 (DC luma, AC luma, DC chroma, AC chroma).
  void writeHuff(int classAndId, List<int> bits, List<int> values) {
    final len = 2 + 1 + 16 + values.length;
    out.add([0xFF, 0xC4, (len >> 8) & 0xff, len & 0xff, classAndId]);
    out.add(bits.sublist(1, 17));
    out.add(values);
  }

  writeHuff(0x00, _dcLumBits, _dcLumVal);
  writeHuff(0x10, _acLumBits, _acLumVal);
  writeHuff(0x01, _dcChrBits, _dcChrVal);
  writeHuff(0x11, _acChrBits, _acChrVal);

  // SOS — start of scan.
  out.add([
    0xFF, 0xDA, 0x00, 0x0C, 0x03,
    0x01, 0x00, // Y:  DC tbl 0, AC tbl 0
    0x02, 0x11, // Cb: DC tbl 1, AC tbl 1
    0x03, 0x11, // Cr: DC tbl 1, AC tbl 1
    0x00, 0x3F, 0x00, // Ss=0, Se=63, Ah/Al=0 (baseline)
  ]);

  // Entropy-coded scan, MCU = one 8×8 block per component (4:4:4).
  final w = _BitWriter(out);
  final block = Float32List(64);
  var prevDcY = 0;
  var prevDcCb = 0;
  var prevDcCr = 0;
  final mcuRows = (height + 7) >> 3;
  final mcuCols = (width + 7) >> 3;

  void loadBlock(Uint8List src, int x0, int y0) {
    for (var by = 0; by < 8; by++) {
      final yy = y0 + by < height ? y0 + by : height - 1;
      final rowOff = yy * width;
      for (var bx = 0; bx < 8; bx++) {
        final xx = x0 + bx < width ? x0 + bx : width - 1;
        // Level shift per JPEG: subtract 128.
        block[by * 8 + bx] = (src[rowOff + xx] - 128).toDouble();
      }
    }
  }

  for (var my = 0; my < mcuRows; my++) {
    for (var mx = 0; mx < mcuCols; mx++) {
      final x0 = mx * 8;
      final y0 = my * 8;

      loadBlock(y, x0, y0);
      _fdct8x8(block);
      var zz = _quantizeAndZigzag(block, qY);
      _encodeBlock(w, zz, prevDcY, dcLum, acLum);
      prevDcY = zz[0];

      loadBlock(cb, x0, y0);
      _fdct8x8(block);
      zz = _quantizeAndZigzag(block, qC);
      _encodeBlock(w, zz, prevDcCb, dcChr, acChr);
      prevDcCb = zz[0];

      loadBlock(cr, x0, y0);
      _fdct8x8(block);
      zz = _quantizeAndZigzag(block, qC);
      _encodeBlock(w, zz, prevDcCr, dcChr, acChr);
      prevDcCr = zz[0];
    }
  }

  w.flush();

  // EOI
  out.add([0xFF, 0xD9]);
  return out.toBytes();
}
