// miniAV iOS broadcast-extension transport protocol — the SHARED CONTRACT
// between the Broadcast Upload Extension (producer, miniav_broadcast_sender)
// and the host app (consumer, screen_context_ios_replaykit.mm).
//
// PINNED IN PHASE 0 — both sides implement exactly this. Bump
// MINIAV_BCAST_PROTO_VERSION on any layout change; sides with mismatched
// versions must refuse to connect (log + drop), never guess.
//
// ARCHITECTURE (see MOBILE_PLATFORM_SPEC.md §B.3b):
//   - No GPU handle can cross the app↔extension boundary on iOS. Instead:
//     a page-aligned SHARED-MEMORY RING (mmap'd file in the App Group
//     container) carries pixel data; a unix-domain socket (also in the App
//     Group) carries tiny frame descriptors + lifecycle messages. Audio
//     rides the socket inline (small).
//   - The extension performs the pipeline's ONLY pixel copy
//     (CVPixelBuffer -> ring slot). The host wraps slot pages zero-copy
//     (newBufferWithBytesNoCopy + texture-from-buffer on unified memory),
//     so slot layout bakes in Metal's linear-texture row alignment.
//   - Backpressure is DROP-OLDEST at the producer: a slot leased by the
//     host is skipped, never overwritten. The extension must never stall
//     (RPBroadcastSampleHandler runs under a ~50 MB / tight-CPU budget).
//
// FILE NAMES inside the App Group container (group container root):
//   ring file:  "miniav_broadcast_ring.bin"
//   socket:     "miniav_broadcast.sock"   (host listens, extension connects)
//
// Same-device transport: no endianness handling (both sides are the same
// arch). All structs are packed, fixed-width, C-layout.

#ifndef MINIAV_BROADCAST_PROTOCOL_H
#define MINIAV_BROADCAST_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MINIAV_BCAST_MAGIC 0x4D424353u /* 'MBCS' */
#define MINIAV_BCAST_PROTO_VERSION 1u

#define MINIAV_BCAST_RING_FILENAME "miniav_broadcast_ring.bin"
#define MINIAV_BCAST_SOCK_FILENAME "miniav_broadcast.sock"

// Ring geometry. 4 slots of NV12 1080p (row-aligned) ≈ 12.7 MB — inside the
// extension's memory budget with headroom. Slots are sized for the ACTUAL
// negotiated dimensions at connect time (ring header), these are ceilings.
#define MINIAV_BCAST_MAX_SLOTS 4u
#define MINIAV_BCAST_MAX_WIDTH 4096u
#define MINIAV_BCAST_MAX_HEIGHT 4096u

// Row stride alignment for every plane: satisfies Metal linear-texture
// bytesPerRow requirements (device minimum is <= 256 on all Apple GPUs) so
// the host can create texture views directly over slot memory.
#define MINIAV_BCAST_ROW_ALIGN 256u
// Each slot begins on a page boundary (16 KiB pages on arm64) so
// newBufferWithBytesNoCopy can wrap a slot exactly.
#define MINIAV_BCAST_SLOT_ALIGN 16384u

// Pixel format carried in the ring. v1 pins NV12 (what ReplayKit delivers as
// 420YpCbCr8BiPlanar); the field exists so a v2 can add more.
typedef enum {
  MINIAV_BCAST_PIXFMT_NV12 = 1,
} MiniAVBcastPixFmt;

// Per-slot lifecycle, stored in the ring header's slot_state[] and driven
// with C11 atomics over the shared mapping:
//   FREE    -> (producer claims)   WRITING
//   WRITING -> (producer finishes) READY     [descriptor sent on socket]
//   READY   -> (host CAS)          LEASED    [host wraps + delivers buffer]
//   LEASED  -> (host ReleaseBuffer) FREE
// The producer may also reclaim READY slots that were never leased when it
// runs out of FREE slots (drop-oldest): CAS READY->WRITING with a bumped seq;
// the host detects the stale seq when it tries to lease and skips.
typedef enum {
  MINIAV_BCAST_SLOT_FREE = 0,
  MINIAV_BCAST_SLOT_WRITING = 1,
  MINIAV_BCAST_SLOT_READY = 2,
  MINIAV_BCAST_SLOT_LEASED = 3,
} MiniAVBcastSlotState;

// Ring header, at offset 0 of the ring file. The producer writes it once
// after ftruncate; the host validates magic/version/geometry before use.
// slot_state/slot_seq are C11 atomic cells (plain uint32_t storage —
// accessed via atomic builtins on both sides; same-arch mapping).
#pragma pack(push, 1)
typedef struct {
  uint32_t magic;   // MINIAV_BCAST_MAGIC
  uint32_t version; // MINIAV_BCAST_PROTO_VERSION
  uint32_t slot_count;
  uint32_t slot_size_bytes; // per-slot payload capacity (page-aligned)
  uint32_t width;           // negotiated frame width  (pixels)
  uint32_t height;          // negotiated frame height (pixels)
  uint32_t pix_fmt;         // MiniAVBcastPixFmt
  uint32_t stride_y;        // luma row stride  (MINIAV_BCAST_ROW_ALIGN-aligned)
  uint32_t stride_uv;       // chroma row stride (same alignment)
  uint32_t offset_uv;       // chroma plane offset within a slot
  uint32_t reserved[6];
  // Atomically-accessed cells (one per slot, MINIAV_BCAST_MAX_SLOTS entries):
  uint32_t slot_state[MINIAV_BCAST_MAX_SLOTS]; // MiniAVBcastSlotState
  uint32_t slot_seq[MINIAV_BCAST_MAX_SLOTS];   // producer frame sequence
} MiniAVBcastRingHeader;
#pragma pack(pop)

// Slot 0 payload begins at the first MINIAV_BCAST_SLOT_ALIGN boundary after
// the header; slot i at that base + i * slot_size_bytes.

// --- Socket messages (fixed-size header, optional inline payload) ---

typedef enum {
  MINIAV_BCAST_MSG_HELLO = 1, // extension -> host, first message
  MINIAV_BCAST_MSG_FRAME = 2, // extension -> host, a slot became READY
  MINIAV_BCAST_MSG_AUDIO = 3, // extension -> host, PCM payload follows inline
  MINIAV_BCAST_MSG_BYE = 4,   // extension -> host, broadcast ended cleanly
} MiniAVBcastMsgType;

#pragma pack(push, 1)
typedef struct {
  uint32_t type;        // MiniAVBcastMsgType
  uint32_t payload_len; // bytes following this header: sizeof(MiniAVBcastHello)
                        // for HELLO, sizeof(MiniAVBcastFrameMsg) for FRAME,
                        // sizeof(MiniAVBcastAudioMsg)+PCM for AUDIO, 0 for BYE
} MiniAVBcastMsgHeader;

// HELLO body (fixed, counted in payload_len): protocol handshake. The host
// validates version before reading the ring; mismatch -> close + log.
typedef struct {
  uint32_t magic;   // MINIAV_BCAST_MAGIC
  uint32_t version; // MINIAV_BCAST_PROTO_VERSION
  uint32_t width;   // matches ring header
  uint32_t height;
  uint32_t pix_fmt;
} MiniAVBcastHello;

// FRAME body: descriptor of a READY slot.
typedef struct {
  uint32_t slot;   // slot index
  uint32_t seq;    // must match ring slot_seq[slot] at lease time, else stale
  uint64_t ts_us;  // producer clock, microseconds (CMTime of the sample)
} MiniAVBcastFrameMsg;

// AUDIO body header; payload_len = sizeof(this) + data_bytes of interleaved
// PCM following immediately. App-audio from ReplayKit (and mic if enabled).
typedef struct {
  uint32_t sample_rate;
  uint16_t channels;
  uint16_t sample_format; // 1 = S16 interleaved, 2 = F32 interleaved
  uint32_t frame_count;
  uint64_t ts_us;
} MiniAVBcastAudioMsg;
#pragma pack(pop)

#ifdef __cplusplus
}
#endif

#endif // MINIAV_BROADCAST_PROTOCOL_H
