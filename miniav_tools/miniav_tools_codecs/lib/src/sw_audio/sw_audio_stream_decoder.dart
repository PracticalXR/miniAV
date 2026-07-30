/// Seekable, streaming, SYNCHRONOUS software audio decoder — MP3 (dr_mp3),
/// FLAC (dr_flac), Vorbis (stb_vorbis). Unlike [SwAudioDecoder] (which
/// accumulates and decodes the whole file at once), this keeps only the small
/// COMPRESSED bytes resident and decodes PCM frames on demand, with random
/// [seekToFrame] — no disk cache and no resident PCM. All calls are synchronous
/// (direct dr_* calls via FFI), so it can back a real-time pull without an async
/// decode-ahead stage; run it off the UI isolate.
///
/// Output is the stream's NATIVE [sampleRate] / [channels]; resample in the
/// consumer if a fixed rate/layout is required.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

class SwAudioStreamDecoder {
  SwAudioStreamDecoder._(
    this._lib,
    this._handle,
    this.channels,
    this.sampleRate,
    this.totalFrames,
  );

  final SwAudioLib _lib;
  Pointer<Void> _handle;

  /// Native channel count.
  final int channels;

  /// Native sample rate (Hz).
  final int sampleRate;

  /// Total PCM frames per channel (0 if the container didn't report it).
  final int totalFrames;

  // Reusable native scratch for reads (grown on demand) to avoid per-call
  // malloc churn on the hot path.
  Pointer<Float> _scratch = nullptr;
  int _scratchFrames = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  /// True for the codecs this decoder handles (mp3/flac/vorbis).
  static bool supports(AudioCodec codec) => _libFor(codec) != null;

  static SwAudioLib? _libFor(AudioCodec c) => switch (c) {
        AudioCodec.mp3 => SwAudioLib.mp3,
        AudioCodec.flac => SwAudioLib.flac,
        AudioCodec.vorbis => SwAudioLib.vorbis,
        _ => null,
      };

  /// Open a streaming decoder over the [bytes] of a raw `.mp3` / `.flac` /
  /// Ogg-Vorbis file. Returns null if [codec] is unsupported here or the bytes
  /// fail to open. The native side copies [bytes], so the caller may reuse them.
  static SwAudioStreamDecoder? open(AudioCodec codec, Uint8List bytes) {
    final lib = _libFor(codec);
    if (lib == null || bytes.isEmpty) return null;

    final dataPtr = malloc<Uint8>(bytes.length);
    final chPtr = malloc<Int32>();
    final ratePtr = malloc<Int32>();
    final totalPtr = malloc<Int64>();
    try {
      dataPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle =
          swStreamOpen(lib, dataPtr, bytes.length, chPtr, ratePtr, totalPtr);
      if (handle == nullptr) return null;
      return SwAudioStreamDecoder._(
        lib,
        handle,
        chPtr.value,
        ratePtr.value,
        totalPtr.value,
      );
    } finally {
      malloc.free(dataPtr);
      malloc.free(chPtr);
      malloc.free(ratePtr);
      malloc.free(totalPtr);
    }
  }

  /// Decode up to [frames] frames from the current position, returning a fresh
  /// interleaved-f32 list (length `framesRead * channels`). Empty at EOF.
  Float32List read(int frames) {
    final got = _readScratch(frames);
    if (got <= 0) return Float32List(0);
    return Float32List.fromList(_scratch.asTypedList(got * channels));
  }

  /// Like [read] but decodes into [out] (interleaved; capacity at least
  /// `frames * channels`), returning frames read — no per-call allocation.
  int readInto(Float32List out, int frames) {
    final got = _readScratch(frames);
    if (got <= 0) return 0;
    out.setRange(0, got * channels, _scratch.asTypedList(got * channels));
    return got;
  }

  int _readScratch(int frames) {
    if (_closed || frames <= 0 || channels <= 0) return 0;
    if (_scratchFrames < frames) {
      if (_scratch != nullptr) malloc.free(_scratch);
      _scratch = malloc<Float>(frames * channels);
      _scratchFrames = frames;
    }
    return swStreamRead(_lib, _handle, _scratch, frames);
  }

  /// Seek so the next [read] starts at PCM [frame]. Returns true on success.
  bool seekToFrame(int frame) {
    if (_closed) return false;
    return swStreamSeek(_lib, _handle, frame < 0 ? 0 : frame);
  }

  /// Release the native decoder + scratch.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_handle != nullptr) {
      swStreamClose(_lib, _handle);
      _handle = nullptr;
    }
    if (_scratch != nullptr) {
      malloc.free(_scratch);
      _scratch = nullptr;
      _scratchFrames = 0;
    }
  }
}
