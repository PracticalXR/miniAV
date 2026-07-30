import 'dart:collection';
import 'dart:typed_data';

// The package barrel: defines MiniAVTools and re-exports the platform-interface
// types (DecodedAudio, AudioTrackInfo, DemuxerInput, …), Demuxer and AudioDecoder.
import '../miniav_tools.dart';

/// A seekable, pull-based decoded-audio source over any container + codec
/// miniav_tools can demux and decode (mp3, aac, flac, vorbis, opus, pcm, …).
///
/// It wires a [Demuxer] to an [AudioDecoder] and hands back interleaved float32
/// PCM on demand — the reusable middle layer between the low-level demux/decode
/// primitives and a full player sink. Nothing is held resident beyond the most
/// recently decoded packet(s); [read] pulls and decodes lazily, so a large file
/// costs no disk cache and no resident PCM.
///
/// Output is the decoder's NATIVE sample rate and channel count — *follow the
/// frames*: [sampleRate]/[channels] reflect the latest decode and can differ
/// from any container hint. Resample in the consumer if a fixed rate/layout is
/// required (miniav_tools has no resampler yet).
///
/// Not internally synchronised: drive one source from a single logical reader
/// (interleave [read]/[seekToUs] on one timeline). Use several sources for
/// several independent playheads over the same file.
class AudioFileSource {
  AudioFileSource._(
    this._demuxer,
    this._decoder,
    this._audioTrack,
    AudioTrackInfo info,
  )   : _sampleRate = info.sampleRate,
        _channels = info.channels;

  final Demuxer _demuxer;
  final AudioDecoder _decoder;
  final int _audioTrack;

  /// Decoded-but-unread chunks (FIFO); [_headOffset] interleaved samples of the
  /// head chunk have already been returned.
  final Queue<DecodedAudio> _pending = Queue<DecodedAudio>();
  int _headOffset = 0;

  int _sampleRate;
  int _channels;
  bool _eof = false;
  bool _flushed = false;
  bool _closed = false;

  /// Native sample rate of the most recently decoded audio (the container hint
  /// until the first packet decodes).
  int get sampleRate => _sampleRate;

  /// Native channel count of the most recently decoded audio.
  int get channels => _channels;

  /// Container duration in microseconds, or null when unknown (e.g. live).
  int? get durationUs => _demuxer.durationUs;

  /// Whether [seekToUs] is supported by the input.
  bool get isSeekable => _demuxer.isSeekable;

  bool get isClosed => _closed;

  /// Frames per channel currently decoded but not yet read.
  int get bufferedFrames {
    if (_channels <= 0) return 0;
    var samples = -_headOffset;
    for (final c in _pending) {
      samples += c.samples.length;
    }
    return samples <= 0 ? 0 : samples ~/ _channels;
  }

  /// Open [input] (e.g. `DemuxerInput.file(path)`), select its first audio
  /// track, and create an [AudioDecoder] auto-configured from the container.
  static Future<AudioFileSource> open(
    DemuxerInput input, {
    BackendPreference preference = BackendPreference.auto,
  }) async {
    final demuxer = await MiniAVTools.createDemuxer(
      DemuxerConfig(input: input),
      preference: preference,
    );

    AudioTrackInfo? info;
    var track = -1;
    for (var i = 0; i < demuxer.tracks.length; i++) {
      final t = demuxer.tracks[i];
      if (t is AudioTrackInfo) {
        info = t;
        track = i;
        break;
      }
    }
    if (info == null) {
      await demuxer.close();
      throw StateError(
        'AudioFileSource: input has no audio track (tracks: ${demuxer.tracks}).',
      );
    }

    AudioDecoder decoder;
    try {
      decoder = await MiniAVTools.createAudioDecoder(
        AudioDecoderConfig(
          codec: info.codec,
          extraData: info.extraData?.bytes,
          sampleRate: info.sampleRate > 0 ? info.sampleRate : null,
          channels: info.channels > 0 ? info.channels : null,
        ),
        preference: preference,
      );
    } catch (_) {
      await demuxer.close();
      rethrow;
    }
    return AudioFileSource._(demuxer, decoder, track, info);
  }

  /// Seek so the next [read] returns samples at/after [timestampUs]. Flushes the
  /// decoder and drops buffered frames. Throws if [isSeekable] is false.
  Future<void> seekToUs(int timestampUs) async {
    _checkOpen();
    await _demuxer.seek(timestampUs);
    await _decoder.flush(); // discard in-flight decoder state
    _pending.clear();
    _headOffset = 0;
    _eof = false;
    _flushed = false;
  }

  /// Pull up to [frameCount] frames of interleaved float32 at the source's
  /// native rate/channels, advancing the read position. A result shorter than
  /// `frameCount * channels` samples means end-of-stream was reached.
  Future<Float32List> read(int frameCount) async {
    _checkOpen();
    if (frameCount <= 0) return Float32List(0);

    // One decode first so [channels] is authoritative before we size the buffer.
    if (_pending.isEmpty && !_eof) await _fill();

    final ch = _channels <= 0 ? 1 : _channels;
    final out = Float32List(frameCount * ch);
    var written = 0;

    while (written < out.length) {
      if (_pending.isEmpty) {
        if (_eof) break;
        await _fill();
        if (_pending.isEmpty) break; // EOF reached inside _fill
        continue;
      }
      final head = _pending.first;
      final avail = head.samples.length - _headOffset;
      final want = out.length - written;
      final n = want < avail ? want : avail;
      out.setRange(written, written + n, head.samples, _headOffset);
      written += n;
      _headOffset += n;
      if (_headOffset >= head.samples.length) {
        _pending.removeFirst();
        _headOffset = 0;
      }
    }

    if (written == out.length) return out;
    return Float32List.sublistView(out, 0, written); // short read at EOF
  }

  /// Decode forward until at least one chunk is buffered, or EOF is reached.
  Future<void> _fill() async {
    while (_pending.isEmpty && !_eof) {
      final pkt = await _demuxer.readPacket();
      if (pkt == null) {
        // Container EOF: drain the decoder tail once, then mark done.
        if (!_flushed) {
          _flushed = true;
          _enqueue(await _decoder.flush());
        } else {
          _eof = true;
        }
        continue;
      }
      if (pkt.trackIndex != _audioTrack) continue;
      // A decoder may need priming (returns nothing until it has enough input);
      // the loop keeps feeding packets until a chunk emerges.
      _enqueue(await _decoder.decode(pkt));
    }
  }

  void _enqueue(List<DecodedAudio> chunks) {
    for (final c in chunks) {
      if (c.frameCount <= 0 || c.samples.isEmpty) continue;
      if (c.sampleRate > 0) _sampleRate = c.sampleRate;
      if (c.channels > 0) _channels = c.channels;
      _pending.add(c);
    }
  }

  /// Close the demuxer + decoder and release resources.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    await _decoder.close();
    await _demuxer.close();
  }

  void _checkOpen() {
    if (_closed) throw StateError('AudioFileSource has been closed.');
  }
}
