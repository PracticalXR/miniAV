/// Native stub for the MSE support probes — nothing is available off web.
/// Keeps `dart:js_interop` / `package:web` out of native builds.
library;

import 'package:miniav_tools/miniav_tools.dart';

bool webCodecsVideoAvailable() => false;

bool mseAvailable() => false;

bool mseFallbackRecommended() => false;

String? blobMimeForBytes(List<int> b, {bool hasVideo = true}) => null;

String? mp4MimeForTracks(VideoTrackInfo? v, AudioTrackInfo? a) => null;
