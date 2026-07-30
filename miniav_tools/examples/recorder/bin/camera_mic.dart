/// camera_mic.dart
///
/// Records 1 camera + 1 microphone synchronized into an MP4 file using
/// the high-level `miniav_recorder` API.
///
/// Usage:
///   dart run bin/camera_mic.dart [seconds] [out.mp4] [--camera=ID] [--mic=ID] [--list]
library;

import 'dart:io';

import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final listOnly = args.contains('--list');
  String? camId;
  String? micId;
  for (final a in args) {
    if (a.startsWith('--camera=')) camId = a.substring('--camera='.length);
    if (a.startsWith('--mic=')) micId = a.substring('--mic='.length);
  }

  final secs = positional.isNotEmpty ? int.tryParse(positional[0]) ?? 5 : 5;
  final out = positional.length >= 2 ? positional[1] : 'cam_mic.mp4';

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  final cams = await MiniCamera.enumerateDevices();
  final mics = await MiniAudioInput.enumerateDevices();

  if (listOnly) {
    print('Cameras:');
    for (final d in cams) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    print('Microphones:');
    for (final d in mics) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    exit(0);
  }

  if (cams.isEmpty) {
    stderr.writeln('[error] No camera devices found.');
    exit(1);
  }
  if (mics.isEmpty) {
    stderr.writeln('[error] No microphone devices found.');
    exit(1);
  }

  final cam = camId != null
      ? cams.firstWhere((d) => d.deviceId == camId)
      : cams.firstWhere((d) => d.isDefault, orElse: () => cams.first);
  final mic = micId != null
      ? mics.firstWhere((d) => d.deviceId == micId)
      : mics.firstWhere((d) => d.isDefault, orElse: () => mics.first);

  print('━━━ recorder: camera + mic → $out  (${secs}s) ━━━');
  print('  Camera : ${cam.name} (${cam.deviceId})');
  print('  Mic    : ${mic.name} (${mic.deviceId})');

  final b = RecorderBuilder();
  b.addCamera(deviceId: cam.deviceId, codec: VideoCodec.h264);
  b.addMic(deviceId: mic.deviceId, codec: AudioCodec.aac);
  b.addFileOutput(out, container: Container.mp4);
  final rec = b.build();

  await rec.start();
  print('  recording ...');
  await Future.delayed(Duration(seconds: secs));
  await rec.stop();
  print('  done. wrote $out');
}
