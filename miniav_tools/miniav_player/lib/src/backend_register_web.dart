/// Web backend registration: WebCodecs via `miniav_tools_codecs/web.dart`.
///
/// Selected on web by the conditional import in `player.dart`. Not compiled on
/// native (it pulls `dart:js_interop`). The `web.dart` entry registers only the
/// WebCodecs backend — it does not pull the minigpu GPU-compute codecs.
library;

import 'package:miniav_tools_codecs/web.dart' as web;

/// Register the platform's codec backend with the tools registry (idempotent).
void registerPlayerBackends() => web.ensureInitialized();
