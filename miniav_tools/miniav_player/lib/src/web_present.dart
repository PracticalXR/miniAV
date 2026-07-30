/// Web VideoFrame present helper.
///
/// Wraps a browser WebCodecs `VideoFrame` (delivered as an opaque `Object`
/// via [DecodedFrame.webVideoFrame]) as a [PreviewSource] of kind
/// [PreviewSourceKind.webVideoFrame]. The minigpu_view web plugin draws it
/// straight to the presentation canvas (`copyFromVideoFrame`) — no readback,
/// no YUV→RGBA convert (the browser already decoded it to a display surface).
///
/// A raw JS `VideoFrame` cannot cross the method-channel `StandardMessageCodec`,
/// so the frame is stashed in a shared global registry
/// (`globalThis.miniavVideoFrameRegistry`) and only a codec-safe int handle is
/// sent — the plugin pops it back out. This mirrors the WebGPU `bufferHandle`
/// path already used for the `webGpuTexture` kind.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' show Size;

import 'package:minigpu_view/minigpu_view.dart';

@JS('globalThis')
external JSObject get _globalThis;

int _nextHandle = 1;

/// Stash [frame] in the shared global registry and return its int handle.
int _registerVideoFrame(JSObject frame) {
  var reg = _globalThis.getProperty<JSAny?>('miniavVideoFrameRegistry'.toJS);
  if (reg == null || reg.isUndefined) {
    reg = JSObject();
    _globalThis.setProperty('miniavVideoFrameRegistry'.toJS, reg);
  }
  final handle = _nextHandle++;
  (reg as JSObject).setProperty(handle.toString().toJS, frame);
  return handle;
}

PreviewSource makeWebVideoFramePreviewSource(
  Object frame,
  int width,
  int height,
) {
  final handle = _registerVideoFrame(frame as JSObject);
  return _WebVideoFramePreviewSource(handle, width, height);
}

class _WebVideoFramePreviewSource extends PreviewSource {
  const _WebVideoFramePreviewSource(this._handle, this._width, this._height);

  final int _handle;
  final int _width;
  final int _height;

  @override
  PreviewSourceKind get kind => PreviewSourceKind.webVideoFrame;

  @override
  Size get size => Size(_width.toDouble(), _height.toDouble());

  @override
  Map<String, Object?> toChannelMessage() => {
    'videoFrameHandle': _handle,
    'width': _width,
    'height': _height,
  };
}
