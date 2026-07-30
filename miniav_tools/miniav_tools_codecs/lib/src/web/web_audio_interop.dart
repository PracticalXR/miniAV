/// Hand-rolled `dart:js_interop` bindings for the WebCodecs **audio** API.
///
/// `package:web` (1.1.x) ships only the *video* WebCodecs types
/// (`VideoDecoder`/`VideoEncoder`/`VideoFrame`/`EncodedVideoChunk`), not the
/// audio ones — so `AudioDecoder`, `AudioEncoder`, `AudioData`, and
/// `EncodedAudioChunk` are declared here. Member names track the WebCodecs
/// spec (https://www.w3.org/TR/webcodecs/).
library;

import 'dart:js_interop';

// ---------------------------------------------------------------------------
// AudioDecoder
// ---------------------------------------------------------------------------

@JS('AudioDecoder')
extension type AudioDecoder._(JSObject _) implements JSObject {
  external factory AudioDecoder(AudioDecoderInit init);
  external void configure(AudioDecoderConfig config);
  external void decode(EncodedAudioChunk chunk);
  external JSPromise<JSAny?> flush();
  external void close();
  external int get decodeQueueSize;
  external String get state;
}

extension type AudioDecoderInit._(JSObject _) implements JSObject {
  external factory AudioDecoderInit({JSFunction output, JSFunction error});
}

extension type AudioDecoderConfig._(JSObject _) implements JSObject {
  external factory AudioDecoderConfig({
    required String codec,
    required int sampleRate,
    required int numberOfChannels,
    JSAny? description, // BufferSource (e.g. AAC AudioSpecificConfig)
  });
}

// ---------------------------------------------------------------------------
// AudioEncoder
// ---------------------------------------------------------------------------

@JS('AudioEncoder')
extension type AudioEncoder._(JSObject _) implements JSObject {
  external factory AudioEncoder(AudioEncoderInit init);
  external void configure(AudioEncoderConfig config);
  external void encode(AudioData data);
  external JSPromise<JSAny?> flush();
  external void close();
  external int get encodeQueueSize;
}

extension type AudioEncoderInit._(JSObject _) implements JSObject {
  external factory AudioEncoderInit({JSFunction output, JSFunction error});
}

extension type AudioEncoderConfig._(JSObject _) implements JSObject {
  external factory AudioEncoderConfig({
    required String codec,
    required int sampleRate,
    required int numberOfChannels,
    int? bitrate,
  });
}

// ---------------------------------------------------------------------------
// EncodedAudioChunk
// ---------------------------------------------------------------------------

@JS('EncodedAudioChunk')
extension type EncodedAudioChunk._(JSObject _) implements JSObject {
  external factory EncodedAudioChunk(EncodedAudioChunkInit init);
  external int get byteLength;
  external void copyTo(JSAny destination); // BufferSource
  external String get type; // 'key' | 'delta'
  external num get timestamp;
}

extension type EncodedAudioChunkInit._(JSObject _) implements JSObject {
  external factory EncodedAudioChunkInit({
    required String type,
    required int timestamp,
    required JSAny data, // BufferSource
  });
}

// ---------------------------------------------------------------------------
// AudioData
// ---------------------------------------------------------------------------

@JS('AudioData')
extension type AudioData._(JSObject _) implements JSObject {
  external factory AudioData(AudioDataInit init);
  external int get numberOfFrames;
  external int get numberOfChannels;
  external int get sampleRate;
  external String get format;
  external num get timestamp;
  external int allocationSize(AudioDataCopyToOptions options);
  external void copyTo(JSAny destination, AudioDataCopyToOptions options);
  external void close();
}

extension type AudioDataInit._(JSObject _) implements JSObject {
  external factory AudioDataInit({
    required String format,
    required int sampleRate,
    required int numberOfFrames,
    required int numberOfChannels,
    required int timestamp,
    required JSAny data, // BufferSource
  });
}

extension type AudioDataCopyToOptions._(JSObject _) implements JSObject {
  external factory AudioDataCopyToOptions({
    required int planeIndex,
    int? frameOffset,
    int? frameCount,
    String? format, // request an interleaved/planar sample format
  });
}
