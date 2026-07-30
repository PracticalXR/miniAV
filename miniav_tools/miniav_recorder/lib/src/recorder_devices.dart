/// Static helpers for enumerating capture devices across all source types.
library;

import 'package:miniav/miniav.dart';

export 'package:miniav/miniav.dart' show MiniAVDeviceInfo;

/// Static helpers to enumerate available capture devices.
///
/// Each method returns [MiniAVDeviceInfo] entries whose [MiniAVDeviceInfo.deviceId]
/// can be passed directly to the matching [RecorderBuilder] method:
///
/// ```dart
/// final displays = await RecorderDevices.displays();
/// final mics     = await RecorderDevices.microphones();
///
/// final group = RecorderGroup([
///   RecorderBuilder()
///     ..addScreen(displayId: displays.first.deviceId)
///     ..addFileOutput('screen.mp4'),
///   RecorderBuilder()
///     ..addMic(deviceId: mics.first.deviceId)
///     ..addFileOutput('mic.m4a'),
/// ]);
/// ```
abstract final class RecorderDevices {
  /// Returns all available display / monitor targets.
  ///
  /// Pass [MiniAVDeviceInfo.deviceId] to [RecorderBuilder.addScreen] as
  /// `displayId:`, or pass `null` to let the recorder pick the default.
  static Future<List<MiniAVDeviceInfo>> displays() =>
      MiniScreen.enumerateDisplays();

  /// Returns all available window targets.
  ///
  /// Pass [MiniAVDeviceInfo.deviceId] to [RecorderBuilder.addScreen] as
  /// `windowId:`.
  static Future<List<MiniAVDeviceInfo>> windows() =>
      MiniScreen.enumerateWindows();

  /// Returns all available camera (video input) devices.
  ///
  /// Pass [MiniAVDeviceInfo.deviceId] to [RecorderBuilder.addCamera].
  static Future<List<MiniAVDeviceInfo>> cameras() =>
      MiniCamera.enumerateDevices();

  /// Returns all available microphone (audio input) devices.
  ///
  /// Pass [MiniAVDeviceInfo.deviceId] to [RecorderBuilder.addMic].
  static Future<List<MiniAVDeviceInfo>> microphones() =>
      MiniAudioInput.enumerateDevices();

  /// Returns all available system-loopback (audio output monitor) devices.
  ///
  /// Pass [MiniAVDeviceInfo.deviceId] to [RecorderBuilder.addLoopback].
  static Future<List<MiniAVDeviceInfo>> loopbacks() =>
      MiniLoopback.enumerateDevices();
}
