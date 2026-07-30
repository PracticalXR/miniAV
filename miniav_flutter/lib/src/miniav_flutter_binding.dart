import 'package:flutter/widgets.dart';
import 'package:miniav/miniav.dart';

/// A thin widget that calls [MiniAV.dispose] during Flutter hot reload,
/// preventing "Callback invoked after it has been deleted" fatal crashes.
///
/// Wrap your root widget with [MiniAVBinding]:
///
/// ```dart
/// void main() {
///   runApp(const MiniAVBinding(child: MyApp()));
/// }
/// ```
///
/// During hot reload, Flutter calls [State.reassemble] on all mounted states.
/// [MiniAVBinding] uses this to atomically disable the MiniAV C-layer callback
/// dispatch before the Dart isolate is rebuilt.  When capture is next started,
/// callbacks are automatically re-enabled.
class MiniAVBinding extends StatefulWidget {
  const MiniAVBinding({super.key, required this.child});

  final Widget child;

  @override
  State<MiniAVBinding> createState() => _MiniAVBindingState();
}

class _MiniAVBindingState extends State<MiniAVBinding> {
  @override
  void reassemble() {
    super.reassemble();
    MiniAV.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
