/// loopback_mp4.dart
///
/// Records the default display + system-audio loopback into an MP4 file.
/// Prints a per-track packet counter every second so you can confirm audio
/// frames are actually being written (not just captured).
///
/// This exercises the AV_NOPTS_VALUE DTS fix — before that fix, audio
/// packets were silently dropped by av_interleaved_write_frame and the
/// resulting MP4 played back with no audio.
///
/// Usage:
///   dart run bin/loopback_mp4.dart [seconds] [out.mp4]
///       [--display=ID] [--loop=ID] [--list]
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav/miniav.dart';
import 'package:miniav_recorder/miniav_recorder.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final listOnly = args.contains('--list');
  String? displayId;
  String? loopId;
  for (final a in args) {
    if (a.startsWith('--display='))
      displayId = a.substring('--display='.length);
    if (a.startsWith('--loop=')) loopId = a.substring('--loop='.length);
  }

  final secs = positional.isNotEmpty ? int.tryParse(positional[0]) ?? 10 : 10;
  final out = positional.length >= 2 ? positional[1] : 'loopback.mp4';

  MiniAV.setLogLevel(MiniAVLogLevel.warn);

  final displays = await MiniScreen.enumerateDisplays();
  final loops = await MiniLoopback.enumerateDevices();

  if (listOnly) {
    print('Displays:');
    for (final d in displays) {
      print('  ${d.isDefault ? '*' : ' '} ${d.deviceId}  —  ${d.name}');
    }
    print('Loopback devices:');
    for (final d in loops) {
      print('  ${d.isDefault ? '*' : ' '} ${d.deviceId}  —  ${d.name}');
    }
    exit(0);
  }

  if (displays.isEmpty) {
    stderr.writeln('[error] No display found.');
    exit(1);
  }
  if (loops.isEmpty) {
    stderr.writeln('[error] No loopback device found.');
    exit(1);
  }

  final display = displayId != null
      ? displays.firstWhere((d) => d.deviceId == displayId)
      : displays.firstWhere((d) => d.isDefault, orElse: () => displays.first);
  final loop = loopId != null
      ? loops.firstWhere((d) => d.deviceId == loopId)
      : loops.firstWhere((d) => d.isDefault, orElse: () => loops.first);

  print('━━━ loopback_mp4: screen + loopback → $out  (${secs}s) ━━━');
  print('  Display  : ${display.name} (${display.deviceId})');
  print('  Loopback : ${loop.name} (${loop.deviceId})');
  print('  Make sure something is playing audio so the loopback has signal!');
  print('');

  // Per-track live counters updated by the stream sink.
  var videoPackets = 0;
  var audioPackets = 0;
  var audioBytes = 0;

  final b = RecorderBuilder();
  b.addScreen(
    displayId: display.deviceId,
    codec: VideoCodec.h264,
    scale: ScreenScalePolicy.h264Friendly,
  );
  b.addLoopback(deviceId: loop.deviceId, codec: AudioCodec.aac);
  // Extension sniff picks Container.mp4 automatically — no need to pass it.
  b.addFileOutput(out);
  b.addStreamOutput((chunk) {
    if (chunk is! TrackChunk) return;
    if (chunk.kind == TrackKind.video) {
      videoPackets++;
    } else {
      audioPackets++;
      audioBytes += chunk.bytes.length;
    }
  });
  final rec = b.build();

  await rec.start();

  // Print a live counter every second so it's obvious whether audio packets
  // are being produced. Zero audio frames = still broken; non-zero = fixed.
  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    stdout.write(
      '\r  video=${videoPackets}pkts  '
      'audio=${audioPackets}pkts (${(audioBytes / 1024).toStringAsFixed(1)} KB)  '
      '                ',
    );
  });

  await Future.delayed(Duration(seconds: secs));

  ticker.cancel();
  await rec.stop();

  print('');
  print('');
  print('━━━ done ━━━');
  print('  Wrote   : $out');
  print('  Video   : $videoPackets packets');
  print(
    '  Audio   : $audioPackets packets  (${(audioBytes / 1024).toStringAsFixed(1)} KB)',
  );
  if (audioPackets == 0) {
    print('');
    print('  ⚠  No audio packets were encoded.');
    print('     Make sure audio is playing on the system while recording.');
  } else {
    print('');
    print('  Open $out in any player to hear the loopback audio.');
  }
}
