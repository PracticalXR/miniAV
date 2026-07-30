// miniAV iOS Broadcast Upload Extension — PRODUCER side transport.
//
// This is a small, SELF-CONTAINED static library the app developer compiles
// DIRECTLY INTO their Broadcast Upload Extension target (alongside the pinned
// protocol header). It has NO dependency on the rest of miniav_c — only
// CoreVideo + POSIX. The consuming code is the extension's
// RPBroadcastSampleHandler subclass (see broadcast_extension/SampleHandler.swift).
//
// ROLE (see MOBILE_PLATFORM_SPEC.md §B.3b and miniav_broadcast_protocol.h):
//   - Creates + sizes the shared-memory ring file in the App Group container,
//     mmaps it, and connects a unix-domain socket to the host app's listener.
//   - Per video frame: claims a ring slot (drop-oldest, never stalls), performs
//     the pipeline's ONLY pixel copy (CVPixelBuffer NV12 planes -> slot), and
//     posts a tiny FRAME descriptor over the socket.
//   - Audio rides the socket inline (small payloads).
//
// DEPLOYMENT: ONE extension per developer team serves ALL same-team apps that
// share the App Group (App Groups are team-scoped). See SETUP.md.
//
// THREADING: designed to be driven from ReplayKit's processSampleBuffer:
// callback thread (a single serial context). The handle is NOT internally
// synchronized for concurrent mbs_send_* calls; call from one thread (as the
// reference SampleHandler does). Reconnect bookkeeping is lock-free/best-effort.
//
// MEMORY: the RPBroadcastSampleHandler process has a ~50 MB ceiling. This lib
// keeps exactly ONE heap allocation (the handle struct) plus the ring mmap in
// steady state — there are NO per-frame heap allocations.

#ifndef MINIAV_BROADCAST_SENDER_H
#define MINIAV_BROADCAST_SENDER_H

#include <stdint.h>

#ifdef __OBJC__
#include <CoreVideo/CoreVideo.h>
#else
// Allow inclusion from plain C/C++ TUs (e.g. a bridging header pulls the ObjC
// path; a pure-C caller still gets a usable, if opaque, CVPixelBufferRef type).
typedef struct __CVBuffer *CVPixelBufferRef;
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Opaque producer handle. One per broadcast session.
typedef struct mbs_handle mbs_handle;

// Sample formats for mbs_send_audio's sample_format_1s16_2f32 argument. These
// mirror the protocol's MiniAVBcastAudioMsg.sample_format field exactly.
#define MBS_AUDIO_FMT_S16 1u // interleaved signed 16-bit PCM
#define MBS_AUDIO_FMT_F32 2u // interleaved 32-bit float PCM

// --------------------------------------------------------------------------
// Lifecycle
// --------------------------------------------------------------------------

// Create + size the ring, mmap it, connect the socket, send HELLO.
//
//   app_group_id : the App Group identifier shared by host app + extension,
//                  e.g. "group.com.example.miniav". Used to resolve the group
//                  container directory (containerURLForSecurityApplicationGroupIdentifier
//                  on the Swift side is NOT used here; we resolve the container
//                  via the group id — see the .m for how the path is derived).
//   width,height : the negotiated frame geometry (pixels). Slots are sized to
//                  exactly these dimensions (the protocol's MAX_* are ceilings).
//                  Both must be > 0 and <= MINIAV_BCAST_MAX_WIDTH/HEIGHT.
//
// Ring creation ordering guarantees a half-created file NEVER validates on the
// host: the file is ftruncate'd to full size, the header body (geometry, slot
// tables zeroed to FREE) is written, an msync barrier is issued, and the MAGIC
// field is written LAST. The host only proceeds once magic + version + geometry
// all check out.
//
// The host may not be listening yet. mbs_open retries the socket connect a few
// times with a short backoff; if it still fails it returns a VALID handle in
// "no consumer" mode — frames are dropped cheaply and the connection is retried
// periodically from within mbs_send_video. So a non-NULL return does NOT imply a
// live consumer; it implies a valid ring the producer can keep filling.
//
// Returns NULL only on unrecoverable setup failure (bad args, cannot create /
// map the ring file). Log is emitted on failure.
mbs_handle *mbs_open(const char *app_group_id, uint32_t width, uint32_t height);

// Copy one NV12 CVPixelBuffer into a ring slot and post a FRAME descriptor.
//
//   pb    : a 420YpCbCr8BiPlanar (NV12) CVPixelBuffer. Both video-range
//           ('420v', kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) and
//           full-range ('420f', ...FullRange) are accepted (identical byte
//           layout; range is a colorimetry note, not a layout difference).
//           BGRA or any non-NV12 format, or dimensions differing from mbs_open,
//           are DROPPED with a once-only log (v1 pins NV12 @ fixed geometry).
//   ts_us : presentation timestamp in microseconds (producer clock; the host
//           rebases onto its own timeline).
//
// Slot claim policy (drop-oldest, never overwrite a LEASED slot, never stall):
//   1. Prefer a FREE slot.
//   2. Else reclaim the OLDEST un-leased READY slot via CAS READY->WRITING with
//      a bumped seq (the host detects the stale seq at lease time and skips).
//   3. If every slot is LEASED (host holding all of them), drop this frame.
//
// Returns 0 on success (frame copied + descriptor sent, OR intentionally
// dropped due to backpressure / no consumer — both are normal, non-error
// steady states). Returns non-zero only on a genuine fault (e.g. failed to lock
// the pixel buffer). A socket send failure is NOT a hard error: the slot is
// still published READY, the handle is flagged disconnected, and a background
// reconnect is attempted on subsequent calls.
int mbs_send_video(mbs_handle *h, CVPixelBufferRef pb, uint64_t ts_us);

// Send an interleaved PCM audio buffer inline over the socket.
//
//   pcm          : interleaved samples. Size in bytes must be
//                  frame_count * channels * (sample_format==S16 ? 2 : 4).
//   frame_count  : samples PER CHANNEL.
//   sample_rate  : Hz.
//   channels     : channel count.
//   sample_format_1s16_2f32 : MBS_AUDIO_FMT_S16 (1) or MBS_AUDIO_FMT_F32 (2).
//   ts_us        : presentation timestamp in microseconds (producer clock).
//
// Audio is fire-and-forget: with no consumer / on socket error it is dropped
// cheaply and reconnect is left to the video path. Returns 0 on success or
// intentional drop, non-zero on a bad-argument fault.
int mbs_send_audio(mbs_handle *h, const void *pcm, uint32_t frame_count,
                   uint32_t sample_rate, uint16_t channels,
                   uint16_t sample_format_1s16_2f32, uint64_t ts_us);

// Best-effort clean shutdown: send BYE, close the socket, munmap the ring,
// free the handle. Safe to call with a "no consumer" handle. Passing NULL is a
// no-op. After this call the handle pointer is invalid.
void mbs_close(mbs_handle *h);

#ifdef __cplusplus
}
#endif

#endif // MINIAV_BROADCAST_SENDER_H
