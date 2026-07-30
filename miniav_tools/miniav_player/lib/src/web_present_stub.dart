/// Native stub for the web VideoFrame present helper.
///
/// Selected on native by the conditional import in `player.dart`. Never
/// called on native (the player only builds a web PreviewSource when a
/// decoded frame carries a browser `VideoFrame`, which is web-only).
library;

import 'package:minigpu_view/minigpu_view.dart';

/// Wrap a browser `VideoFrame` as a [PreviewSource]. Web-only; throws on
/// native (unreachable — guarded by the caller).
PreviewSource makeWebVideoFramePreviewSource(Object frame, int width, int height) =>
    throw UnsupportedError('web VideoFrame presentation is only available on web');
