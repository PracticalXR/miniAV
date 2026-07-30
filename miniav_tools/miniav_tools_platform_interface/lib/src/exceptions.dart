/// Exception types thrown by miniav_tools backends and the facade.
library;

import 'codec_types.dart';

/// Base class for all miniav_tools exceptions.
sealed class MiniAVToolsException implements Exception {
  final String message;
  const MiniAVToolsException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// No registered backend can handle the requested codec / container.
class NoBackendForCodecException extends MiniAVToolsException {
  final VideoCodec? videoCodec;
  final AudioCodec? audioCodec;
  final Container? container;

  const NoBackendForCodecException._({
    required String message,
    this.videoCodec,
    this.audioCodec,
    this.container,
  }) : super(message);

  factory NoBackendForCodecException.video(
    VideoCodec c, {
    bool hwAccel = false,
  }) => NoBackendForCodecException._(
    message:
        'No registered backend supports VideoCodec.$c${hwAccel ? " (HW accel)" : ""}.',
    videoCodec: c,
  );

  factory NoBackendForCodecException.audio(AudioCodec c) =>
      NoBackendForCodecException._(
        message: 'No registered backend supports AudioCodec.$c.',
        audioCodec: c,
      );

  factory NoBackendForCodecException.container(Container c) =>
      NoBackendForCodecException._(
        message: 'No registered backend supports Container.$c.',
        container: c,
      );
}

/// A backend was selected but failed to initialise the codec (driver missing,
/// hardware busy, invalid configuration, etc.).
class CodecInitException extends MiniAVToolsException {
  final String backendName;
  final Object? cause;

  const CodecInitException(this.backendName, String message, {this.cause})
    : super(message);

  @override
  String toString() =>
      'CodecInitException[$backendName]: $message'
      '${cause != null ? "\nCause: $cause" : ""}';
}

/// Encoder/decoder is in an error state and must be closed/recreated.
class CodecRuntimeException extends MiniAVToolsException {
  final String backendName;
  final Object? cause;

  const CodecRuntimeException(this.backendName, String message, {this.cause})
    : super(message);

  @override
  String toString() =>
      'CodecRuntimeException[$backendName]: $message'
      '${cause != null ? "\nCause: $cause" : ""}';
}

/// The provided [FrameSource] kind is not accepted by this backend, and no
/// fallback was possible.
class UnsupportedFrameSourceException extends MiniAVToolsException {
  final String backendName;

  const UnsupportedFrameSourceException(this.backendName, String message)
    : super(message);
}
