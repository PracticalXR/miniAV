/// WASM libopus audio backend (web only).
///
/// Priority 90 — ABOVE [WebCodecsBackend] (80) — so the negotiator's
/// descending-priority scan picks the WASM libopus encoder/decoder for Opus on
/// web, giving byte-identical interop with the native OpusBackend. The factories
/// return `null` if the wasm module fails to load, so the scan falls through to
/// WebCodecs (80) → native Opus (60), preserving the existing fallback chain.
library;

import 'dart:async';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import 'wasm_opus_audio_decoder.dart';
import 'wasm_opus_audio_encoder.dart';

class WasmOpusBackend extends MiniAVToolsBackend {
  static const String backendName = 'wasmopus';

  /// Above [WebCodecsBackend]'s 80 so WASM libopus is preferred for Opus on web.
  static const int defaultPriority = 90;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) => codec == AudioCodec.opus;

  @override
  bool supportsAudioDecode(AudioCodec codec) => codec == AudioCodec.opus;

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) =>
      WasmOpusAudioDecoder.open(config);

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) =>
      WasmOpusAudioEncoder.open(config);

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async =>
      null;

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async =>
      null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}
