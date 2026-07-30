/// Widget that hosts an [MseController]'s `<video>` element via a platform view.
/// Web-only in effect; on native it renders [placeholder] (the controller there
/// is the unsupported stub).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'mse_controller_stub.dart'
    if (dart.library.js_interop) 'mse_controller.dart';

class MseVideoView extends StatelessWidget {
  const MseVideoView({super.key, required this.controller, this.placeholder});

  final MseController controller;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || !MseController.isSupportedPlatform) {
      return placeholder ?? const SizedBox.shrink();
    }
    return HtmlElementView(viewType: controller.viewType);
  }
}
