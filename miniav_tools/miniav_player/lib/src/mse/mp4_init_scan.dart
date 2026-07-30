/// Incremental ISO-BMFF probe for the web MSE byte-stream path — pure Dart (no
/// web APIs), so it is unit-testable on the VM and shared by the conditional
/// web/native code.
///
/// Feeds on arbitrary chunk boundaries and answers, as early as possible:
///   - is this ISO-BMFF at all ([isIsoBmff])?
///   - is the init segment (`ftyp` + complete `moov`) buffered ([moovComplete])?
///   - is it FRAGMENTED (`mvex` inside `moov` → fMP4, MSE-streamable) or a
///     plain progressive MP4 ([fragmented])?
///   - the `codecs=` MIME string MSE needs ([mimeCodecs]), derived from the
///     sample entries in `moov` (avcC profile/compat/level → `avc1.PPCCLL`,
///     hvcC → a safe `hvc1` default, mp4a → AAC-LC, Opus).
///
/// Codec detection scans `moov` for the sample-entry fourccs rather than
/// walking the full trak/mdia/stbl tree — `moov` is pure box structure, so a
/// false positive is vanishingly unlikely, and a wrong string fails loudly at
/// `addSourceBuffer` (surfaced via the controller's onError).
library;

import 'dart:typed_data';

class Mp4InitProbe {
  final _chunks = BytesBuilder(copy: true);
  Uint8List _buf = Uint8List(0);

  bool _scanned = false;
  bool _moovComplete = false;
  bool _fragmented = false;
  String? _mimeCodecs;
  int _moovEnd = 0;

  /// Everything fed so far (the init segment + any media that followed it).
  Uint8List get bufferedBytes => _buf;
  int get bufferedLength => _buf.length;

  /// Byte offset just past the end of `moov` (valid once [moovComplete]).
  int get initSegmentEnd => _moovEnd;

  /// True when the first top-level box is a recognised ISO-BMFF signature.
  /// False once >=8 bytes are buffered and it isn't (caller should fall back).
  /// Null while fewer than 8 bytes have arrived.
  bool? get isIsoBmff {
    if (_buf.length < 8) return null;
    final t = _fourcc(_buf, 4);
    return t == 'ftyp' || t == 'styp' || t == 'moov' || t == 'moof';
  }

  bool get moovComplete => _moovComplete;

  /// `mvex` present inside `moov` → fragmented MP4 (MSE stream mode works,
  /// including for live streams). Valid once [moovComplete].
  bool get fragmented => _fragmented;

  /// Full `video/mp4; codecs="..."` (or `audio/mp4; ...`) string, or null when
  /// no recognisable codec was found. Valid once [moovComplete].
  String? get mimeCodecs => _mimeCodecs;

  /// Feed the next chunk. Returns true once the init segment is complete (the
  /// caller can stop probing and decide a route).
  bool add(List<int> chunk) {
    _chunks.add(chunk);
    _buf = _chunks.toBytes();
    if (!_moovComplete) _scanTopLevel();
    return _moovComplete;
  }

  void _scanTopLevel() {
    var off = 0;
    final len = _buf.length;
    while (off + 8 <= len) {
      var size = _u32(_buf, off);
      final type = _fourcc(_buf, off + 4);
      var header = 8;
      if (size == 1) {
        if (off + 16 > len) return; // largesize header incomplete
        // 64-bit size: high 32 bits are beyond any sane init segment; use low.
        size = (_u32(_buf, off + 8) * 0x100000000) + _u32(_buf, off + 12);
        header = 16;
      } else if (size == 0) {
        // Box extends to EOF — cannot complete incrementally.
        return;
      }
      if (size < header) return; // corrupt; stop scanning
      if (type == 'moov') {
        if (off + size > len) return; // moov not fully buffered yet
        _moovComplete = true;
        _moovEnd = off + size;
        if (!_scanned) {
          _scanned = true;
          _scanMoov(off + header, off + size);
        }
        return;
      }
      if (off + size > len) return; // next box not fully here; wait
      off += size;
    }
  }

  void _scanMoov(int start, int end) {
    final hasVideoAvc = _findFourcc(start, end, 'avcC');
    final hasVideoHvc =
        _findFourcc(start, end, 'hvcC') >= 0 && hasVideoAvc < 0;
    final hasAac = _findFourcc(start, end, 'mp4a') >= 0;
    final hasOpus = _findFourcc(start, end, 'Opus') >= 0;
    _fragmented = _findFourcc(start, end, 'mvex') >= 0;

    final codecs = <String>[];
    if (hasVideoAvc >= 0) {
      // avcC content: [version, profile, compat, level, ...] right after the
      // fourcc → avc1.PPCCLL.
      final c = hasVideoAvc + 4;
      if (c + 4 <= end) {
        codecs.add('avc1.'
            '${_hex2(_buf[c + 1])}${_hex2(_buf[c + 2])}${_hex2(_buf[c + 3])}');
      } else {
        codecs.add('avc1.42E01E');
      }
    } else if (hasVideoHvc) {
      codecs.add('hvc1.1.6.L93.B0');
    }
    if (hasAac) codecs.add('mp4a.40.2');
    if (hasOpus) codecs.add('opus');

    if (codecs.isEmpty) {
      _mimeCodecs = null;
      return;
    }
    final container =
        (hasVideoAvc >= 0 || hasVideoHvc) ? 'video/mp4' : 'audio/mp4';
    _mimeCodecs = '$container; codecs="${codecs.join(',')}"';
  }

  int _findFourcc(int start, int end, String fourcc) {
    final a = fourcc.codeUnitAt(0),
        b = fourcc.codeUnitAt(1),
        c = fourcc.codeUnitAt(2),
        d = fourcc.codeUnitAt(3);
    for (var i = start; i + 4 <= end; i++) {
      if (_buf[i] == a && _buf[i + 1] == b && _buf[i + 2] == c &&
          _buf[i + 3] == d) {
        return i;
      }
    }
    return -1;
  }

  static int _u32(Uint8List b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static String _fourcc(Uint8List b, int i) =>
      String.fromCharCodes(b, i, i + 4);

  static String _hex2(int v) =>
      (v & 0xff).toRadixString(16).padLeft(2, '0').toUpperCase();
}
