/// screen_mic.dart
///
/// Records 1 display + 1 microphone synchronized into an MKV file using
/// the high-level `miniav_recorder` API.
///
/// Zero-copy GPU path is on by default (RecorderBuilder.preferZeroCopy = true).
/// The h264Friendly scale policy auto-downscales ultrawide / 4K+ captures so
/// H.264 HW stays in range (max dim ≤ 4096), avoiding codec promotion to HEVC.
///
/// Usage:
///   dart run bin/screen_mic.dart [seconds] [out.mkv] [--display=ID] [--mic=ID] [--list]
library;

import 'dart:io';

import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final listOnly = args.contains('--list');
  String? displayId;
  String? micId;
  for (final a in args) {
    if (a.startsWith('--display='))
      displayId = a.substring('--display='.length);
    if (a.startsWith('--mic=')) micId = a.substring('--mic='.length);
  }

  final secs = positional.isNotEmpty ? int.tryParse(positional[0]) ?? 5 : 5;
  final out = positional.length >= 2 ? positional[1] : 'screen_mic.mkv';

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  final displays = await MiniScreen.enumerateDisplays();
  final mics = await MiniAudioInput.enumerateDevices();

  if (listOnly) {
    print('Displays:');
    for (final d in displays) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    print('Microphones:');
    for (final d in mics) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    exit(0);
  }

  if (displays.isEmpty) {
    stderr.writeln('[error] No displays found.');
    exit(1);
  }
  if (mics.isEmpty) {
    stderr.writeln('[error] No microphones found.');
    exit(1);
  }

  final display = displayId != null
      ? displays.firstWhere((d) => d.deviceId == displayId)
      : displays.firstWhere((d) => d.isDefault, orElse: () => displays.first);
  final mic = micId != null
      ? mics.firstWhere((d) => d.deviceId == micId)
      : mics.firstWhere((d) => d.isDefault, orElse: () => mics.first);

  print('━━━ recorder: screen + mic → $out  (${secs}s) ━━━');
  print('  Display : ${display.name} (${display.deviceId})');
  print('  Mic     : ${mic.name} (${mic.deviceId})');

  final b = RecorderBuilder();
  b.addScreen(
    displayId: display.deviceId,
    codec: VideoCodec.h264,
    scale: ScreenScalePolicy.h264Friendly,
  );
  b.addMic(deviceId: mic.deviceId, codec: AudioCodec.aac);
  b.addFileOutput(out, container: Container.mkv);
  final rec = b.build();

  await rec.start();
  print('  recording ...');
  await Future.delayed(Duration(seconds: secs));
  await rec.stop();
  print('  done. wrote $out');
}
