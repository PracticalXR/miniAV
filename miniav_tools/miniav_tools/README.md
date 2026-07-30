# miniav_tools

User-facing facade for the miniav_tools codec & container library.

Add a backend package (`miniav_tools_ffmpeg`, `miniav_tools_web`, etc.) to your dependencies — importing it auto-registers the backend with this facade.

```dart
import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'; // self-registers

final encoder = await MiniAVTools.createEncoder(EncoderConfig(
  codec: VideoCodec.h264,
  width: 1920, height: 1080,
  bitrateBps: 8_000_000,
  hwAccel: HwAccelPreference.preferred,
));
```

See the [repo README](../README.md) and [design doc](../miniav_tools_design.MD).
