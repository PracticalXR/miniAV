/// screen_mic_loopback_chunked.dart
///
/// Records 1 display + 1 microphone + 1 system-loopback into an MKV
/// file AND simultaneously emits per-track chunks via a callback —
/// demonstrating the dual file + stream sink pattern.
///
/// Usage:
///   dart run bin/screen_mic_loopback_chunked.dart [seconds] [out.mkv]
///       [--display=ID] [--mic=ID] [--loop=ID] [--list]
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
  String? loopId;
  for (final a in args) {
    if (a.startsWith('--display='))
      displayId = a.substring('--display='.length);
    if (a.startsWith('--mic=')) micId = a.substring('--mic='.length);
    if (a.startsWith('--loop=')) loopId = a.substring('--loop='.length);
  }

  final secs = positional.isNotEmpty ? int.tryParse(positional[0]) ?? 5 : 5;
  final out = positional.length >= 2 ? positional[1] : 'screen_mic_loop.mkv';

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  final displays = await MiniScreen.enumerateDisplays();
  final mics = await MiniAudioInput.enumerateDevices();
  final loops = await MiniLoopback.enumerateDevices();

  if (listOnly) {
    print('Displays:');
    for (final d in displays) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    print('Microphones:');
    for (final d in mics) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    print('Loopback:');
    for (final d in loops) {
      print('  ${d.isDefault ? "*" : " "} ${d.deviceId}  —  ${d.name}');
    }
    exit(0);
  }

  if (displays.isEmpty || mics.isEmpty || loops.isEmpty) {
    stderr.writeln(
      '[error] need at least one display, mic, and loopback device.',
    );
    exit(1);
  }

  final display = displayId != null
      ? displays.firstWhere((d) => d.deviceId == displayId)
      : displays.firstWhere((d) => d.isDefault, orElse: () => displays.first);
  final mic = micId != null
      ? mics.firstWhere((d) => d.deviceId == micId)
      : mics.firstWhere((d) => d.isDefault, orElse: () => mics.first);
  final loop = loopId != null
      ? loops.firstWhere((d) => d.deviceId == loopId)
      : loops.firstWhere((d) => d.isDefault, orElse: () => loops.first);

  print('━━━ recorder: screen + mic + loopback → $out  (${secs}s) ━━━');
  print('  Display  : ${display.name}');
  print('  Mic      : ${mic.name}');
  print('  Loopback : ${loop.name}');

  // Per-track packet counters for the chunked sink.
  final perTrack = <int, ({int count, int bytes, TrackKind kind})>{};

  final b = RecorderBuilder();
  b.addScreen(displayId: display.deviceId, codec: VideoCodec.h264);
  b.addMic(deviceId: mic.deviceId, codec: AudioCodec.opus);
  b.addLoopback(deviceId: loop.deviceId, codec: AudioCodec.opus);
  b.addFileOutput(out, container: Container.mkv);
  b.addStreamOutput((chunk) {
    if (chunk is! TrackChunk) return;
    final prev = perTrack[chunk.trackIndex];
    perTrack[chunk.trackIndex] = (
      count: (prev?.count ?? 0) + 1,
      bytes: (prev?.bytes ?? 0) + chunk.bytes.length,
      kind: chunk.kind,
    );
    if (chunk.extraData != null) {
      print(
        '  [chunk] track=${chunk.trackIndex} extraData=${chunk.extraData!.length}B',
      );
    }
  });
  final rec = b.build();

  await rec.start();
  print('  recording ...');
  await Future.delayed(Duration(seconds: secs));
  await rec.stop();

  print('  done. wrote $out');
  print('  per-track chunk stats:');
  perTrack.forEach((idx, stats) {
    print(
      '    track $idx (${stats.kind.name}): ${stats.count} chunks, ${stats.bytes}B',
    );
  });
}
