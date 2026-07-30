# miniav_player

Network-first zero-copy A/V player for Flutter, built on the miniav_tools codec
stack (FFmpeg decode on worker isolates), minigpu (GPU YUV→RGBA), and
minigpu_view (shared-texture presentation, zero readback).

The player is **packet-driven**: your transport (QUIC/WebTransport/WebSocket/
in-process pipe) delivers `EncodedPacket`s; the player owns everything after
that — decode, GPU convert, present, audio playback, and a/v pacing.

## Hot path

```
network packet ─▶ decode worker isolate (FFmpeg, YUV420P out)
              ─▶ TransferableTypedData hop (zero-copy transfer)
              ─▶ ONE GPU upload (1.5 B/px planes)
              ─▶ WGSL YUV→RGBA (BT.601 limited)
              ─▶ SharedOutputTexture (GPU→GPU copy)
              ─▶ Flutter Texture samples the shared handle — zero readback
```

## Usage

```dart
final player = await MiniavPlayer.open(
  video: VideoStreamSpec(
    config: DecoderConfig(codec: VideoCodec.h264 /*, extraData: avcC */),
  ),
  audio: AudioStreamSpec(
    config: AudioDecoderConfig(codec: AudioCodec.aac, extraData: asc),
  ),
  latency: PlayerLatencyMode.live, // or .paced for VOD-style pts pacing
);

transport.onVideoPacket = player.submitVideoPacket;
transport.onAudioPacket = player.submitAudioPacket;

// Widget tree:
MiniavPlayerView(player: player);

// Lifecycle:
player.pause(); player.resume();
await player.drain();   // end-of-stream
await player.close();
```

Sharing an app GPU context (and controlling adapter binding — call
`Minigpu.preferDisplayAdapter()` before ANY minigpu init if you need it):

```dart
final gpu = Minigpu();
await gpu.init();
final player = await MiniavPlayer.open(video: ..., gpu: gpu);
```

Live-mode behavior: latest-wins presentation (a newer decoded frame supersedes
a queued one), bounded decode input queue with keyframe-resync catch-up
(`stats.videoPacketsDropped` tells your transport when to request a keyframe).

See `../docs/PLAYER_PLAN.md` for the full architecture, drop policies, and the
phase roadmap (file demux/seek, WebCodecs web path, D3D11VA zero-upload).
