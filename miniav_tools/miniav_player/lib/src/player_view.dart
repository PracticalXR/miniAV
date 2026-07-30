/// Convenience widget: shows a [MiniavPlayer]'s video via minigpu_view, with a
/// transparent CPU-fallback path for platforms that have no zero-copy present.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:minigpu_view/minigpu_view.dart';

import 'mse/mse_view.dart';
import 'player.dart';

/// Renders [player]'s video track. On platforms with a zero-copy present this
/// is a `Texture` (via `MiniavGpuPreview`); on platforms without one the player
/// converts frames on the CPU and this paints them via [RawImage] — the switch
/// is automatic (driven by [MiniavPlayer.videoFallbackImage]). Apps that manage
/// their own [MinigpuPreviewController] can use `MiniavGpuPreview` directly, but
/// then must handle the fallback themselves.
class MiniavPlayerView extends StatelessWidget {
  const MiniavPlayerView({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
    this.placeholder,
  });

  final MiniavPlayer player;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final Widget? placeholder;

  Widget _gpuPreview(MinigpuPreviewController controller) => MiniavGpuPreview(
        controller: controller,
        fit: fit,
        alignment: alignment,
        filterQuality: filterQuality,
        placeholder: placeholder,
      );

  /// Container-declared display rotation (MP4 tkhd): frames are presented in
  /// coded orientation, so the view applies the quarter-turns. The MSE branch
  /// is exempt — the browser honors the matrix natively.
  Widget _rotated(Widget child) {
    final turns = (player.rotationDegrees ~/ 90) & 3;
    return turns == 0 ? child : RotatedBox(quarterTurns: turns, child: child);
  }

  @override
  Widget build(BuildContext context) {
    // Web MSE fallback: the browser renders into its own <video> element.
    final mse = player.mseController;
    if (player.usingMse && mse != null) {
      return MseVideoView(controller: mse, placeholder: placeholder);
    }
    final controller = player.previewController;
    if (controller == null) {
      // Audio-only player.
      return placeholder ?? const SizedBox.shrink();
    }
    final fallback = player.videoFallbackImage;
    if (fallback == null) {
      // Web / zero-copy platforms: no CPU-fallback presenter exists.
      return _rotated(_gpuPreview(controller));
    }
    // The fallback may or may not engage (decided lazily on the first frame):
    // until a CPU image is published, show the GPU preview (which itself shows
    // the placeholder until it presents); once one arrives, paint it.
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: fallback,
      builder: (context, image, _) {
        if (image == null) return _rotated(_gpuPreview(controller));
        // Mirror the GPU preview's FittedBox layout: give the image a FINITE
        // intrinsic size and let FittedBox scale it per [fit]. Wrapping a
        // self-sizing RawImage in SizedBox.expand instead would force infinite
        // constraints (crash in any unbounded-axis parent — Column/ListView)
        // and defeat [fit]/[alignment].
        return _rotated(FittedBox(
          fit: fit,
          alignment: alignment,
          child: SizedBox(
            width: image.width.toDouble(),
            height: image.height.toDouble(),
            child: RawImage(image: image, filterQuality: filterQuality),
          ),
        ));
      },
    );
  }
}
