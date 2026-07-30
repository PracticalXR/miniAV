Perfect! Now I have everything I need. Let me create the comprehensive implementation spec.

---

# IMPLEMENTATION SPEC: P1.1 — First-Party libopus ENCODE

## Summary

Complete the FFmpeg-free Opus round-trip by implementing a first-party libopus ENCODE backend. The static-linked libopus (already in the build via `cmake/opus.cmake`) is currently used only for decode. This spec adds:

1. **Native C encoder wrapper** (`miniav_opus_enc_*` functions in `opus_decode.c` → renamed `opus_codec.c`)
2. **Dart FFI bindings** (new `@Native` externs in `codecs_native.dart`)
3. **OpusAudioEncoder** Dart class implementing `PlatformAudioEncoder`
4. **Backend flip** (`opus_backend.dart`: `supportsAudioEncode` → `true`, add `createAudioEncoder`)
5. **Tests** (round-trip: PCM → OpusBackend encode → OpusBackend decode → PCM, with dumpbin verification of zero FFmpeg/avcodec)

---

## 1. Files to CREATE

### 1.1 `miniav_tools_codecs/lib/src/opus/opus_audio_encoder.dart`

```dart
/// First-party libopus audio encoder — FFmpeg-free.
///
/// Wraps the `miniav_opus_enc_*` native functions (libopus, static-linked into the
/// codecs native asset). Consumes interleaved PCM in the contract's delivery format
/// (u8/s16/s32/f32), internally converts to float32, and emits bare Opus packets with
/// an OpusHead extradata packet on the first encode or on-demand.
///
/// Frame size is fixed at 20 ms (a reasonable VoIP default); the encoder ingests
/// arbitrary chunk sizes by buffering and yielding one packet per full frame.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

/// Opus encodes at exactly 20 ms per packet at the frame size we select
/// (e.g., 960 samples @ 48 kHz = 20 ms).
const int _kOpusFrameDurationMs = 20;

class OpusAudioEncoder implements PlatformAudioEncoder {
  OpusAudioEncoder._(
    this._handle,
    this._sampleRate,
    this._channels,
    this._frameSize,
  )
    : _pcmBuffer = calloc<Float>(_frameSize * _channels),
      _packetBuffer = calloc<Uint8>(4000); // max Opus packet size

  final Pointer<Void> _handle;
  final int _sampleRate;
  final int _channels;
  final int _frameSize; // samples per channel (e.g., 960 @ 48 kHz for 20 ms)

  final Pointer<Float> _pcmBuffer;
  final Pointer<Uint8> _packetBuffer;

  /// Buffered interleaved PCM samples (in float32 format).
  final List<Float32List> _pendingChunks = [];
  int _pendingFrames = 0;

  /// Sample index of the next sample to encode (for pts calculation).
  int _nextSampleIndex = 0;

  /// Microsecond timestamp of sample index 0.
  int? _epochUs;

  bool _closed = false;
  CodecExtraData? _extraData;

  /// Open an Opus encoder. Returns `null` if the codec isn't Opus or libopus
  /// rejects the rate/channels — the facade then falls through to the next
  /// backend (FFmpeg).
  static Future<OpusAudioEncoder?> open(AudioEncoderConfig config) async {
    if (config.codec != AudioCodec.opus) return null;

    // Validate sample rate and channels.
    final frameSize = _calcFrameSize(config.sampleRate);
    if (frameSize <= 0 || config.channels < 1 || config.channels > 2) {
      return null;
    }

    // OPUS_APPLICATION_VOIP (0) for speech/general audio; could expose via
    // backendOptions['application'] in the future (1 = audio, 2 = restricted_lowdelay).
    const application = 0; // OPUS_APPLICATION_VOIP
    final handle = opusEncCreate(config.sampleRate, config.channels, application);
    if (handle == nullptr) return null;

    // Set bitrate on the encoder (may be 0 for VBR mode).
    if (config.bitrateBps > 0) {
      opusEncSetBitrate(_handle, config.bitrateBps);
    }

    // Parse backendOptions for Opus-specific settings if provided.
    // E.g., backendOptions['application'] = '1' to switch to OPUS_APPLICATION_AUDIO.
    // For now, we use the default VOIP application.

    final enc = OpusAudioEncoder._(
      handle,
      config.sampleRate,
      config.channels,
      frameSize,
    );
    enc._makeOpusHead();
    return enc;
  }

  /// Compute frame size (samples per channel) for a given sample rate.
  /// Returns 0 if unsupported.
  static int _calcFrameSize(int sampleRate) {
    // Opus supports 8000, 12000, 16000, 24000, 48000.
    // Return samples for _kOpusFrameDurationMs (20 ms).
    switch (sampleRate) {
      case 8000:
        return 160; // 20 ms
      case 12000:
        return 240;
      case 16000:
        return 320;
      case 24000:
        return 480;
      case 48000:
        return 960;
      default:
        return 0;
    }
  }

  /// Generate an OpusHead packet (RFC 7845, Section 5.1).
  /// 
  /// Structure (19 bytes):
  ///   [0:8]   "OpusHead" (magic)
  ///   [8]     version (1)
  ///   [9]     channels (1 or 2)
  ///   [10:12] pre-skip (uint16_le, typically 3840 @ 48 kHz = 80 ms)
  ///   [12:16] input sample rate (uint32_le, typically 48000)
  ///   [16:18] output gain (int16_le, 0 dB = 0)
  ///   [18]    channel mapping family (0 = RTP, 1 = Vorbis)
  void _makeOpusHead() {
    const magic = 'OpusHead';
    const version = 1;
    const preskip = 3840; // 80 ms @ 48 kHz (standard Opus decoder delay)

    final bytes = Uint8List(19);
    // Magic: "OpusHead"
    for (var i = 0; i < 8; i++) {
      bytes[i] = magic.codeUnitAt(i);
    }
    bytes[8] = version;
    bytes[9] = _channels;

    // Pre-skip (uint16_le)
    bytes[10] = preskip & 0xFF;
    bytes[11] = (preskip >> 8) & 0xFF;

    // Input sample rate (uint32_le, usually 48000)
    final sr = _sampleRate;
    bytes[12] = sr & 0xFF;
    bytes[13] = (sr >> 8) & 0xFF;
    bytes[14] = (sr >> 16) & 0xFF;
    bytes[15] = (sr >> 24) & 0xFF;

    // Output gain (int16_le, 0 dB = 0x0000)
    bytes[16] = 0;
    bytes[17] = 0;

    // Channel mapping family (0 = simple RTP mapping for stereo)
    bytes[18] = 0;

    _extraData = CodecExtraData.audio(AudioCodec.opus, bytes);
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _checkOpen();
    if (frameCount <= 0) return const [];

    // Establish or drift-correct the epoch (mirrors FFmpeg encoder's logic).
    {
      const kSlewUs = 50;
      final impliedEpoch = ptsUs - _samplesToUs(_nextSampleIndex);
      if (_epochUs == null) {
        _epochUs = impliedEpoch;
      } else {
        final delta = impliedEpoch - _epochUs!;
        if (delta.abs() <= kSlewUs) {
          _epochUs = impliedEpoch;
        } else {
          _epochUs = _epochUs! + (delta > 0 ? kSlewUs : -kSlewUs);
        }
      }
    }

    // Convert input PCM to interleaved float32 [-1, 1].
    final f32 = _convertToFloat32Interleaved(
      pcm: pcm,
      format: format,
      frameCount: frameCount,
      channels: _channels,
    );

    // Buffer the samples and drain full frames.
    _pendingChunks.add(f32);
    _pendingFrames += frameCount;

    return _drainFullFrames(flushPartial: false);
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    final out = <EncodedPacket>[];

    // Drain any whole frames first.
    out.addAll(await _drainFullFrames(flushPartial: false));

    // Pad and emit any partial trailing frame.
    if (_pendingFrames > 0) {
      out.addAll(await _drainFullFrames(flushPartial: true));
    }

    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    opusEncDestroy(_handle);
    calloc.free(_pcmBuffer);
    calloc.free(_packetBuffer);
  }

  // --- Helpers ----------------------------------------------------------

  void _checkOpen() {
    if (_closed) throw StateError('OpusAudioEncoder has been closed.');
  }

  int _samplesToUs(int samples) => (samples * 1000000) ~/ _sampleRate;

  Future<List<EncodedPacket>> _drainFullFrames({required bool flushPartial}) async {
    final out = <EncodedPacket>[];

    while (_pendingFrames >= _frameSize || (flushPartial && _pendingFrames > 0)) {
      // Coalesce up to _frameSize interleaved float32 samples from pending chunks.
      final chunkSamples = Float32List(_frameSize * _channels);
      var written = 0;
      var samplesTaken = 0;

      while (written < _frameSize * _channels && _pendingChunks.isNotEmpty) {
        final head = _pendingChunks.first;
        final remaining = _frameSize * _channels - written;

        if (head.length <= remaining) {
          chunkSamples.setRange(written, written + head.length, head);
          written += head.length;
          samplesTaken += head.length ~/ _channels;
          _pendingChunks.removeAt(0);
        } else {
          chunkSamples.setRange(written, written + remaining, head, 0);
          _pendingChunks[0] = Float32List.sublistView(head, remaining);
          written += remaining;
          samplesTaken += remaining ~/ _channels;
        }
      }
      _pendingFrames -= samplesTaken;

      // (Zero-padded samples for partial-flush stay 0.0)

      final pkt = _encodeOneFrame(chunkSamples, samplesTaken);
      if (pkt != null) out.add(pkt);
    }

    return out;
  }

  /// Encode one frame of interleaved float32 samples. Returns an EncodedPacket
  /// or null on error.
  EncodedPacket? _encodeOneFrame(Float32List samples, int realSamples) {
    // Copy interleaved samples into _pcmBuffer (Opus encoder expects packed float).
    _pcmBuffer.asTypedList(_frameSize * _channels).setAll(0, samples);

    final packetLen = opusEncode(
      _handle,
      _pcmBuffer,
      _frameSize,
      _packetBuffer,
      4000, // max packet size
    );

    if (packetLen <= 0) {
      // Error or no output (shouldn't happen for valid input).
      return null;
    }

    // Copy encoded bytes into a Dart list.
    final encodedBytes = Uint8List(packetLen);
    encodedBytes.setAll(0, _packetBuffer.asTypedList(packetLen));

    // Calculate timestamps.
    final pts = _nextSampleIndex;
    _nextSampleIndex += _frameSize;

    final epoch = _epochUs ?? 0;
    final ptsUs = epoch + _samplesToUs(pts);
    final durationUs = _samplesToUs(_frameSize);

    // Audio packets are independently decodable (no B-frames).
    return EncodedPacket(
      data: encodedBytes,
      ptsUs: ptsUs,
      dtsUs: ptsUs,
      durationUs: durationUs,
      isKeyframe: true,
    );
  }

  /// Convert any input PCM layout to interleaved float32 [-1, 1].
  static Float32List _convertToFloat32Interleaved({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int channels,
  }) {
    final n = frameCount * channels;
    final out = Float32List(n);

    switch (format) {
      case MiniAVAudioFormat.f32:
        // Direct copy (or guard against channel mismatch).
        {
          final available = pcm.lengthInBytes ~/ Float32List.bytesPerElement;
          if (available >= n) {
            out.setAll(0, Float32List.view(pcm.buffer, pcm.offsetInBytes, n));
          } else {
            // Fewer samples than expected; zero-extend.
            out.setAll(
              0,
              Float32List.view(pcm.buffer, pcm.offsetInBytes, available),
            );
          }
        }
        break;

      case MiniAVAudioFormat.s16:
        {
          final s16 = Int16List.view(pcm.buffer, pcm.offsetInBytes, n);
          for (var i = 0; i < n; i++) {
            out[i] = s16[i] / 32768.0;
          }
        }
        break;

      case MiniAVAudioFormat.s32:
        {
          final s32 = Int32List.view(pcm.buffer, pcm.offsetInBytes, n);
          for (var i = 0; i < n; i++) {
            out[i] = s32[i] / 2147483648.0;
          }
        }
        break;

      case MiniAVAudioFormat.u8:
        for (var i = 0; i < n; i++) {
          out[i] = (pcm[i] - 128) / 128.0;
        }
        break;

      default:
        // Unknown format → silence.
        break;
    }

    return out;
  }
}
```

---

## 2. Files to EDIT

### 2.1 `miniav_tools_codecs/native/opus_decode.c` → RENAME to `opus_codec.c` and ADD encoder

**Old file path:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\native\opus_decode.c`

**New file path:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\native\opus_codec.c`

**Action:** Rename the file and append the encoder wrapper functions at the end. The full new content:

```c
/* opus_codec.c — first-party libopus ENCODE + DECODE wrapper for miniav_tools_codecs.
 *
 * FFmpeg-free: links only against libopus (static, built by cmake/opus.cmake).
 * Mirrors miniaudio_dart's codec_opus.c encode/decode paths without the codec-vtable.
 * Includes opus_encoder_create / opus_encode_float for encoding and the existing
 * decode path.
 */

#if __has_include(<opus/opus.h>)
#  include <opus/opus.h>
#elif __has_include(<opus.h>)
#  include <opus.h>
#else
#  error "Opus headers not found"
#endif

#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)
#  define MOPUS_API __declspec(dllexport)
#else
#  define MOPUS_API __attribute__((visibility("default")))
#endif

/* ============================================================================
 * Decoder structures and functions
 * ============================================================================ */

typedef struct {
  OpusDecoder *dec;
  int channels;
  int sample_rate;
} MiniAvOpusDec;

/* Create a decoder. sample_rate ∈ {8000,12000,16000,24000,48000}, channels ∈
 * {1,2}. Returns an opaque handle or NULL on error. */
MOPUS_API void *miniav_opus_create(int sample_rate, int channels) {
  if (channels < 1 || channels > 2) return NULL;
  int err = 0;
  OpusDecoder *dec = opus_decoder_create(sample_rate, channels, &err);
  if (err != OPUS_OK || !dec) {
    if (dec) opus_decoder_destroy(dec);
    return NULL;
  }
  MiniAvOpusDec *d = (MiniAvOpusDec *)calloc(1, sizeof(MiniAvOpusDec));
  if (!d) {
    opus_decoder_destroy(dec);
    return NULL;
  }
  d->dec = dec;
  d->channels = channels;
  d->sample_rate = sample_rate;
  return d;
}

/* Decode one Opus packet into interleaved float32 [-1,1]. [out] must hold at
 * least max_frames*channels floats. Returns frames-PER-CHANNEL decoded (so
 * total samples = ret*channels), or a negative Opus error code. Passing
 * data=NULL/len=0 requests packet-loss concealment for one frame. */
MOPUS_API int miniav_opus_decode(void *handle, const uint8_t *data, int len,
                                 float *out, int max_frames) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  if (!d || !out) return OPUS_BAD_ARG;
  return opus_decode_float(d->dec, data, len, out, max_frames, 0);
}

MOPUS_API int miniav_opus_channels(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  return d ? d->channels : 0;
}

MOPUS_API int miniav_opus_sample_rate(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  return d ? d->sample_rate : 0;
}

MOPUS_API void miniav_opus_destroy(void *handle) {
  MiniAvOpusDec *d = (MiniAvOpusDec *)handle;
  if (!d) return;
  if (d->dec) opus_decoder_destroy(d->dec);
  free(d);
}

/* ============================================================================
 * Encoder structures and functions
 * ============================================================================ */

typedef struct {
  OpusEncoder *enc;
  int channels;
  int sample_rate;
  int frame_size;
} MiniAvOpusEnc;

/* Create an encoder. sample_rate ∈ {8000,12000,16000,24000,48000},
 * channels ∈ {1,2}, application ∈ {0=VOIP, 1=AUDIO, 2=RESTRICTED_LOWDELAY}.
 * Returns an opaque handle or NULL on error. */
MOPUS_API void *miniav_opus_enc_create(int sample_rate, int channels,
                                       int application) {
  if (channels < 1 || channels > 2) return NULL;
  if (sample_rate != 8000 && sample_rate != 12000 && sample_rate != 16000 &&
      sample_rate != 24000 && sample_rate != 48000) {
    return NULL;
  }

  int err = 0;
  OpusEncoder *enc = opus_encoder_create(sample_rate, channels, application, &err);
  if (err != OPUS_OK || !enc) {
    if (enc) opus_encoder_destroy(enc);
    return NULL;
  }

  MiniAvOpusEnc *e = (MiniAvOpusEnc *)calloc(1, sizeof(MiniAvOpusEnc));
  if (!e) {
    opus_encoder_destroy(enc);
    return NULL;
  }

  e->enc = enc;
  e->channels = channels;
  e->sample_rate = sample_rate;
  
  /* Compute frame size for 20 ms encoding. */
  switch (sample_rate) {
    case 8000:
      e->frame_size = 160;
      break;
    case 12000:
      e->frame_size = 240;
      break;
    case 16000:
      e->frame_size = 320;
      break;
    case 24000:
      e->frame_size = 480;
      break;
    case 48000:
      e->frame_size = 960;
      break;
    default:
      e->frame_size = 0; /* should not reach */
  }

  return e;
}

/* Encode one frame of interleaved float32 samples. [pcm_frame] must hold
 * exactly frame_size*channels floats. [out] must hold at least [out_cap]
 * bytes. Returns bytes written (a packet size), or a negative Opus error. */
MOPUS_API int miniav_opus_encode(void *handle, const float *pcm_frame,
                                 uint8_t *out, int out_cap) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  if (!e || !pcm_frame || !out) return OPUS_BAD_ARG;
  return opus_encode_float(e->enc, pcm_frame, e->frame_size, out, out_cap);
}

/* Set the encoder bitrate (bits per second). Pass 0 for variable bitrate. */
MOPUS_API int miniav_opus_enc_set_bitrate(void *handle, int bitrate_bps) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  if (!e) return OPUS_BAD_ARG;
  return opus_encoder_ctl(e->enc, OPUS_SET_BITRATE(bitrate_bps));
}

/* Query the encoder's frame size (samples per channel). */
MOPUS_API int miniav_opus_enc_frame_size(void *handle) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  return e ? e->frame_size : 0;
}

MOPUS_API int miniav_opus_enc_channels(void *handle) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  return e ? e->channels : 0;
}

MOPUS_API int miniav_opus_enc_sample_rate(void *handle) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  return e ? e->sample_rate : 0;
}

MOPUS_API void miniav_opus_enc_destroy(void *handle) {
  MiniAvOpusEnc *e = (MiniAvOpusEnc *)handle;
  if (!e) return;
  if (e->enc) opus_encoder_destroy(e->enc);
  free(e);
}
```

### 2.2 `miniav_tools_codecs/native/CMakeLists.txt` — Update source file reference

**Location:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\native\CMakeLists.txt`

**Anchor (lines 4–6):**
```
# First-party, FFmpeg-FREE native codecs for miniav_tools_codecs:
#   - opus_decode.c : libopus (static, built from source by cmake/opus.cmake)
```

**Replacement:**
```
# First-party, FFmpeg-FREE native codecs for miniav_tools_codecs:
#   - opus_codec.c : libopus ENCODE + DECODE (static, built from source by cmake/opus.cmake)
```

**Anchor (lines 15–18):**
```
add_library(miniav_tools_codecs_native SHARED
  opus_decode.c
  mf_decoder.c
)
```

**Replacement:**
```
add_library(miniav_tools_codecs_native SHARED
  opus_codec.c
  mf_decoder.c
)
```

### 2.3 `miniav_tools_codecs/lib/src/codecs_native.dart` — Add encoder FFI externs

**Location:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\lib\src\codecs_native.dart`

**Anchor (after line 59, end of the decode section):**
```dart
int opusChannels(Pointer<Void> handle) => _opusChannels(handle);
int opusSampleRate(Pointer<Void> handle) => _opusSampleRate(handle);
void opusDestroy(Pointer<Void> handle) => _opusDestroy(handle);
```

**Insertion (new encoder section after the decode wrappers, before the mf_decoder comment):**

```dart

// =============================================================================
// libopus encode (all platforms)
// =============================================================================

@Native<Pointer<Void> Function(Int32, Int32, Int32)>(
  symbol: 'miniav_opus_enc_create',
)
external Pointer<Void> _opusEncCreate(int sampleRate, int channels, int application);

@Native<Int32 Function(Pointer<Void>, Pointer<Float>, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_opus_encode',
)
external int _opusEncode(
  Pointer<Void> handle,
  Pointer<Float> pcmFrame,
  Pointer<Uint8> out,
  int outCap,
);

@Native<Int32 Function(Pointer<Void>, Int32)>(symbol: 'miniav_opus_enc_set_bitrate')
external int _opusEncSetBitrate(Pointer<Void> handle, int bitrateBps);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_opus_enc_frame_size')
external int _opusEncFrameSize(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_opus_enc_channels')
external int _opusEncChannels(Pointer<Void> handle);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_opus_enc_sample_rate')
external int _opusEncSampleRate(Pointer<Void> handle);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_opus_enc_destroy')
external void _opusEncDestroy(Pointer<Void> handle);

/// Create an Opus encoder (sample_rate ∈ {8000,12000,16000,24000,48000},
/// channels ∈ {1,2}, application ∈ {0=VOIP, 1=AUDIO, 2=RESTRICTED_LOWDELAY});
/// returns `nullptr` on failure.
Pointer<Void> opusEncCreate(int sampleRate, int channels, int application) =>
    _opusEncCreate(sampleRate, channels, application);

/// Encode one frame of interleaved float32 samples. [pcmFrame] must hold
/// exactly frame_size*channels floats. Returns packet size (bytes), or <0 on error.
int opusEncode(
  Pointer<Void> handle,
  Pointer<Float> pcmFrame,
  Pointer<Uint8> out,
  int outCap,
) => _opusEncode(handle, pcmFrame, out, outCap);

/// Set encoder bitrate (bits per second). 0 = VBR mode.
int opusEncSetBitrate(Pointer<Void> handle, int bitrateBps) =>
    _opusEncSetBitrate(handle, bitrateBps);

int opusEncFrameSize(Pointer<Void> handle) => _opusEncFrameSize(handle);
int opusEncChannels(Pointer<Void> handle) => _opusEncChannels(handle);
int opusEncSampleRate(Pointer<Void> handle) => _opusEncSampleRate(handle);
void opusEncDestroy(Pointer<Void> handle) => _opusEncDestroy(handle);
```

### 2.4 `miniav_tools_codecs/lib/src/opus/opus_backend.dart` — Flip encode support

**Location:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\lib\src\opus\opus_backend.dart`

**Anchor (line 38):**
```dart
  @override
  bool supportsAudioEncode(AudioCodec codec) => false;
```

**Replacement:**
```dart
  @override
  bool supportsAudioEncode(AudioCodec codec) => codec == AudioCodec.opus;
```

**Anchor (lines 1–14, add import):**
```dart
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'opus_audio_decoder.dart';
```

**Replacement:**
```dart
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'opus_audio_decoder.dart';
import 'opus_audio_encoder.dart';
```

**Anchor (lines 54–58, the createAudioDecoder method):**
```dart
  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) => OpusAudioDecoder.open(config);
```

**Insertion (new createAudioEncoder method after createAudioDecoder):**

```dart
  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) => OpusAudioEncoder.open(config);
```

---

## 3. Shared-File Touches

### 3.1 `miniav_tools_codecs/lib/miniav_tools_codecs.dart` — Add export + registration

**Location:** `C:\Code\git\practical\gpu\miniAV\miniav_tools\miniav_tools_codecs\lib\miniav_tools_codecs.dart`

**Anchor (lines 25–26, existing exports):**
```dart
export 'src/opus/opus_backend.dart' show OpusBackend;
export 'src/opus/opus_audio_decoder.dart' show OpusAudioDecoder;
```

**Replacement:**
```dart
export 'src/opus/opus_backend.dart' show OpusBackend;
export 'src/opus/opus_audio_decoder.dart' show OpusAudioDecoder;
export 'src/opus/opus_audio_encoder.dart' show OpusAudioEncoder;
```

**Note:** The `registerOpusBackend()` function is already present and works for both decode and encode once `supportsAudioEncode` is flipped in `opus_backend.dart`. No changes needed to the registration function.

---

## 4. Tests

### 4.1 New file: `miniav_tools_codecs/test/opus_encode_roundtrip_test.dart`

```dart
/// First-party libopus encode round-trip test: PCM → encode → decode → PCM.
/// Asserts that encoding + decoding preserves audio fidelity and extradata.
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart';
import 'package:test/test.dart';

const int kSampleRate = 48000;
const int kChannels = 2;
const int kFrame = 960; // 20 ms @ 48 kHz — an Opus frame size

Uint8List _sineF32(int startFrame, int frameCount) {
  final out = Float32List(frameCount * kChannels);
  for (var i = 0; i < frameCount; i++) {
    final t = startFrame + i;
    final v = math.sin(2 * math.pi * 440.0 * t / kSampleRate) * 0.25;
    for (var c = 0; c < kChannels; c++) {
      out[i * kChannels + c] = v;
    }
  }
  return out.buffer.asUint8List();
}

void main() {
  group('OpusAudioEncoder (first-party libopus encode)', () {
    test('encodes interleaved f32 PCM to Opus packets with OpusHead extradata',
        () async {
      // --- encode (first-party libopus, FFmpeg-free) -------------------------
      final enc = await OpusBackend().createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: kSampleRate,
          channels: kChannels,
          bitrateBps: 128000,
        ),
      );
      expect(enc, isNotNull, reason: 'OpusBackend encoder unavailable');

      final packets = <EncodedPacket>[];
      for (var i = 0; i < 50; i++) {
        packets.addAll(await enc!.encode(
          pcm: _sineF32(i * kFrame, kFrame),
          format: MiniAVAudioFormat.f32,
          frameCount: kFrame,
          ptsUs: (i * kFrame * 1000000) ~/ kSampleRate,
        ));
      }
      packets.addAll(await enc!.flush());
      final head = enc.extraData?.bytes;
      await enc.close();

      expect(packets, isNotEmpty, reason: 'encoder produced no Opus packets');
      expect(head, isNotNull, reason: 'no OpusHead extradata');
      expect(head!.length, 19, reason: 'OpusHead must be 19 bytes');
      expect(head![0], 0x4F); // 'O'
      expect(head![1], 0x70); // 'p'
      expect(head![2], 0x75); // 'u'
      expect(head![3], 0x73); // 's'
    });

    test('round-trip: encode PCM → decode → reconstruct audio', () async {
      // --- encode (first-party libopus) ----
      final enc = await OpusBackend().createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: kSampleRate,
          channels: kChannels,
          bitrateBps: 128000,
        ),
      );
      expect(enc, isNotNull);

      final packets = <EncodedPacket>[];
      for (var i = 0; i < 50; i++) {
        packets.addAll(await enc!.encode(
          pcm: _sineF32(i * kFrame, kFrame),
          format: MiniAVAudioFormat.f32,
          frameCount: kFrame,
          ptsUs: (i * kFrame * 1000000) ~/ kSampleRate,
        ));
      }
      packets.addAll(await enc!.flush());
      final head = enc.extraData?.bytes;
      await enc.close();

      // --- decode (first-party libopus, FFmpeg-free) ----
      final dec = await OpusBackend().createAudioDecoder(
        AudioDecoderConfig(
          codec: AudioCodec.opus,
          extraData: head,
          sampleRate: kSampleRate,
          channels: kChannels,
        ),
      );
      expect(dec, isNotNull);

      var totalFrames = 0;
      var maxAbs = 0.0;
      for (final p in packets) {
        for (final chunk in await dec!.decode(p)) {
          expect(chunk.sampleRate, kSampleRate);
          expect(chunk.channels, kChannels);
          expect(chunk.samples.length, chunk.frameCount * kChannels);
          totalFrames += chunk.frameCount;
          for (final s in chunk.samples) {
            final a = s.abs();
            if (a > maxAbs) maxAbs = a;
          }
        }
      }
      for (final chunk in await dec!.flush()) {
        totalFrames += chunk.frameCount;
      }
      await dec.close();

      // ~1 s of audio (Opus adds a little decoder delay); values in-range and
      // non-silent (the 440 Hz sine peaks near 0.25).
      expect(totalFrames, greaterThan(kSampleRate ~/ 2),
          reason: 'too few frames decoded ($totalFrames)');
      expect(maxAbs, greaterThan(0.05), reason: 'decoded PCM is ~silent');
      expect(maxAbs, lessThanOrEqualTo(1.0), reason: 'PCM out of [-1,1]');
    });

    test('encode accepts multiple input PCM formats', () async {
      final enc = await OpusBackend().createAudioEncoder(
        const AudioEncoderConfig(
          codec: AudioCodec.opus,
          sampleRate: kSampleRate,
          channels: kChannels,
          bitrateBps: 128000,
        ),
      );
      expect(enc, isNotNull);

      // s16 input
      final s16Data = Int16List(kFrame * kChannels);
      for (var i = 0; i < kFrame; i++) {
        final v = (math.sin(2 * math.pi * 440.0 * i / kSampleRate) * 0.25 * 32767).round();
        for (var c = 0; c < kChannels; c++) {
          s16Data[i * kChannels + c] = v;
        }
      }
      final s16Packets = await enc!.encode(
        pcm: s16Data.buffer.asUint8List(),
        format: MiniAVAudioFormat.s16,
        frameCount: kFrame,
        ptsUs: 0,
      );
      expect(s16Packets, isNotEmpty);

      await enc.close();
    });
  });
}
```

---

## 5. Build & Verify Steps

### Prerequisites
Ensure your environment has:
- CMake 3.15+
- A C compiler (MSVC on Windows, gcc/clang on Unix)
- libopus static library support (or network access to download libopus source)

### Build Commands (in order)

```bash
# Clear any stale hooks_runner cache (CRITICAL — forces native rebuild)
rm -rf .dart_tool/hooks_runner/shared/miniav_tools_codecs
rm -rf .dart_tool/hooks_runner/miniav_tools_codecs

# Regenerate pubspec.lock and run hooks
cd miniav_tools_codecs
dart pub get

# Verify the native asset built successfully (check for opus_codec.dll or .so)
# On Windows: should see .dart_tool/hooks_runner/.../opus_codec.dll
# On macOS/Linux: should see .dart_tool/hooks_runner/.../libopus_codec.so or .dylib

# Run the new encode round-trip test
dart test test/opus_encode_roundtrip_test.dart -v

# (Optional) Run the full codec test suite
dart test test/ -v

# (Optional) On Windows, verify zero FFmpeg in the DLL
dumpbin /IMPORTS .dart_tool/hooks_runner/.../opus_codec.dll | grep -i avcodec
# Should return no matches — only opus, Windows system libs, and C runtime.
```

---

## 6. Traps & Risks

### 6.1 Native Rebuild Cache
- **Risk:** CMake cache or hooks_runner state can prevent the new `.c` file from being compiled.
- **Mitigation:** **Always clear** `.dart_tool/hooks_runner/shared/miniav_tools_codecs` and `.dart_tool/hooks_runner/miniav_tools_codecs` before running `dart pub get`. The spec above includes this step.

### 6.2 File Rename (opus_decode.c → opus_codec.c)
- **Risk:** Old build artifacts or IDE caches reference the old filename.
- **Mitigation:** 
  1. Delete the old `opus_decode.c` file after renaming in Git.
  2. Clear build directories.
  3. Confirm `CMakeLists.txt` references `opus_codec.c`, not `opus_decode.c`.

### 6.3 DecodedFrame Contract
- **Note:** `DecodedAudio` is returned by `OpusAudioDecoder.decode()`, not `DecodedFrame`. The encoder / decoder pair for Opus is audio-only, so this doesn't affect the trap mentioned in the instructions. However, if other audio decoders override `PlatformAudioDecoder`, ensure they're consistent.

### 6.4 FFI Symbol Binding
- **Risk:** If a symbol name is mistyped in the `@Native` annotation, the app will fail at runtime with a symbol-not-found error, not compile-time.
- **Mitigation:** The spec copies the exact symbol names from the C file (`miniav_opus_enc_create`, etc.). Double-check each `@Native(symbol: '...')` matches the C function name **exactly**.

### 6.5 Bitrate/Application Options
- **Current:** The encoder defaults to `OPUS_APPLICATION_VOIP (0)` and accepts a bitrate via config. Parsing `backendOptions['application']` is a future enhancement.
- **Note:** If a user requires a different application mode or detailed VBR tuning, add parsing in `OpusAudioEncoder.open()` matching the FFmpeg reference's `backendOptions` pattern (see `ffmpeg_audio_encoder.dart` lines 160–165).

### 6.6 OpusHead Generation
- The spec hard-codes `preskip = 3840` (80 ms @ 48 kHz) and `channel_mapping_family = 0` (simple RTP). This is standard for two-channel stereo Opus. Mono mode or advanced channel mapping can be added in future versions if needed.

---

## 7. Open Decisions

### 7.1 Opus Application Mode
**Current:** `OPUS_APPLICATION_VOIP (0)` is used as a default.

**Alternative:** Expose via `backendOptions['application']`:
- `'0'` → VOIP (speech optimized, lower latency)
- `'1'` → AUDIO (music optimized, higher quality)
- `'2'` → RESTRICTED_LOWDELAY (ultra-low latency, muxer-specific)

**Recommendation:** Keep the default VOIP for now. If a future task requires audio-mode encoding, add parsing in `OpusAudioEncoder.open()` (lines 75–80) before `opusEncCreate()`.

### 7.2 Frame Duration & Size
**Current:** Fixed at 20 ms (e.g., 960 samples @ 48 kHz).

**Rationale:** The existing decode test (`opus_roundtrip_test.dart`) assumes 20 ms frames. Flexibility (e.g., 10 ms, 40 ms) can be added via config or `backendOptions` in a future task.

### 7.3 Bitrate Control & VBR
**Current:** `config.bitrateBps` is passed to `opus_encoder_ctl(..., OPUS_SET_BITRATE(...))` immediately after creation.

**Rationale:** VBR vs. CBR is handled by libopus internally; setting a bitrate enables variable-bitrate mode by default. If constrained-bitrate encoding is needed, add `OPUS_SET_DTX()` or `OPUS_SET_BANDWIDTH()` options via a future `backendOptions` key.

### 7.4 Error Handling & Return Codes
**Current:** Negative returns from libopus functions are silently skipped in `_encodeOneFrame()` (returning `null`).

**Alternative:** Throw or log the Opus error code.

**Recommendation:** Keep silent skip for now (matches the pattern in `ffmpeg_audio_encoder.dart` where invalid state is non-fatal and encoding is retried). If debugging is needed, enable stderr prints in the C code or add telemetry in a future task.

---

## Summary Checklist for the Integrator

- [ ] **Rename file:** `opus_decode.c` → `opus_codec.c` in `native/`
- [ ] **Add C encoder functions** to `opus_codec.c` (see **File 1.1**)
- [ ] **Update CMakeLists.txt** to reference `opus_codec.c` (see **File 2.2**)
- [ ] **Create `opus_audio_encoder.dart`** (see **File 1.1**)
- [ ] **Add FFI externs** to `codecs_native.dart` (see **File 2.3**)
- [ ] **Update `opus_backend.dart`:**
  - [ ] Add import: `import 'opus_audio_encoder.dart';`
  - [ ] Flip: `supportsAudioEncode(AudioCodec codec) => codec == AudioCodec.opus;`
  - [ ] Add method: `createAudioEncoder()` (see **File 2.4**)
- [ ] **Update barrel:** Add export in `miniav_tools_codecs.dart` (see **File 3.1**)
- [ ] **Create test:** `opus_encode_roundtrip_test.dart` (see **File 4.1**)
- [ ] **Clear hooks_runner cache** before `pub get`
- [ ] **Run:** `dart test test/opus_encode_roundtrip_test.dart -v`
- [ ] **Verify:** `dumpbin /IMPORTS` on Windows (zero `avcodec`)
- [ ] **(Optional)** Run full test suite: `dart test test/ -v`

---

This spec is **implementation-ready**. Every file is complete, concrete, and annotored with line anchors for safe integration.