// Smoke test: load the shim via @Native + @DefaultAsset and report the
// ABI / avcodec versions. Triggers the build hook on `dart run`.
import 'package:miniav_tools_ffmpeg/src/ffmpeg_bindings.dart' as bindings;
import 'package:miniav_tools_ffmpeg/src/ffmpeg_shim.dart';

void main() async {
  // Pre-load avcodec/avutil so the shim's import resolution succeeds.
  await bindings.ensureFFmpegLoaded();

  final s = FfmpegShim.tryLoad();
  if (s == null) {
    print('FAIL: shim not loaded');
    return;
  }
  final v = s.avcodecVersion();
  final major = (v >> 16) & 0xFF;
  final minor = (v >> 8) & 0xFF;
  final micro = v & 0xFF;
  print('OK: shim loaded via native asset');
  print('  abi=${s.abiVersion()}');
  print('  avcodec=$major.$minor.$micro (0x${v.toRadixString(16)})');
}
