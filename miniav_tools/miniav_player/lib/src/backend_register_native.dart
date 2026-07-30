/// Native backend registration (default): FFmpeg via `miniav_tools_ffmpeg`.
///
/// Selected on the VM/native by the conditional import in `player.dart`. Not
/// compiled on web (it pulls `dart:ffi`).
library;

import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show
        registerMfDecodeBackend,
        registerOpusBackend,
        registerPcmBackend,
        registerContainerFramingBackend,
        registerSwAudioBackend,
        registerAacBackend;
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show registerFfmpegBackend;

/// Register the platform's codec backend(s) with the tools registry
/// (idempotent).
///
/// The first-party, **FFmpeg-free** backends live in `miniav_tools_codecs`:
///   - Media Foundation hardware video decode (Windows) → the negotiator picks
///     it (→ D3D11 texture) over software decode.
///   - libopus audio decode + encode (all platforms) → picked over FFmpeg for Opus.
///   - raw PCM (pcmS16le/pcmF32le) decode + encode (all platforms).
///   - WAV / Ogg / ADTS container framing (all platforms) → `.wav`/`.opus`
///     files demux/mux with no libavformat.
///
/// FFmpeg remains the cross-platform software floor + the fallback for other
/// codecs/containers — so a packet-streaming H.264/HEVC-video + Opus-audio
/// player, and `.wav`/`.opus` file playback, run with zero FFmpeg in the
/// process on Windows.
void registerPlayerBackends() {
  registerMfDecodeBackend(); // FFmpeg-free HW video (Windows)
  registerOpusBackend(); // FFmpeg-free Opus audio (decode + encode)
  registerPcmBackend(); // FFmpeg-free raw PCM
  registerSwAudioBackend(); // FFmpeg-free MP3 / FLAC / Vorbis decode
  registerAacBackend(); // FFmpeg-free OS AAC decode+encode (Windows; MTA)
  registerContainerFramingBackend(); // FFmpeg-free WAV/Ogg/ADTS/MP4 demux+mux
  registerFfmpegBackend(); // software floor + fallback (MKV, SW video, STA AAC)
}
