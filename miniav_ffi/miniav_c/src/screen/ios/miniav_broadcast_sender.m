// miniAV iOS Broadcast Upload Extension — PRODUCER side implementation.
//
// Plain ObjC/C, MANUAL REFERENCE COUNTING (compile WITHOUT -fobjc-arc, matching
// the miniav_c codebase). SELF-CONTAINED: CoreVideo + POSIX + os_log only. NO
// dependency on the rest of miniav_c — this file is compiled ALONE into the
// developer's Broadcast Upload Extension target together with the pinned
// protocol header. It must never #include miniav_utils / miniav_log / etc.
//
// See miniav_broadcast_sender.h for the API contract and
// miniav_broadcast_protocol.h for the wire/ring layout (DO NOT edit that file).

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h> // NSFileManager: resolve App Group container

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h> // only for memory_order_* constants passed to __atomic_*
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "miniav_broadcast_protocol.h"

// --------------------------------------------------------------------------
// Logging — compile-out macro over os_log. NOT miniav_log (unavailable here).
// Define MBS_LOG_SILENT to strip all logging (e.g. size-sensitive builds).
// --------------------------------------------------------------------------
#ifndef MBS_LOG_SILENT
#include <os/log.h>
#define MBS_LOG(fmt, ...)                                                      \
  os_log(OS_LOG_DEFAULT, "[miniav_bcast_sender] " fmt, ##__VA_ARGS__)
#else
#define MBS_LOG(fmt, ...)                                                      \
  do {                                                                         \
  } while (0)
#endif

// --------------------------------------------------------------------------
// Geometry helpers
//
//   align(v, a) rounds v UP to the next multiple of a (a must be a power of 2,
//   which every MINIAV_BCAST_*_ALIGN is).
//
// Layout math (documented per the spec's geometry rules):
//   stride_y   = align(width, ROW_ALIGN)                     [luma: 1 byte/px]
//   stride_uv  = align(width, ROW_ALIGN)                     [NV12 interleaved
//                UV plane is width bytes/row at half height — 2 bytes/chroma-px
//                * (width/2 chroma-px) == width bytes/row]
//   offset_uv  = align(stride_y * height, ROW_ALIGN)         [ROW_ALIGN(256)
//                also satisfies Metal's texture-from-buffer offset alignment on
//                the host, so the UV plane starts on a valid boundary too]
//   chroma_rows= (height + 1) / 2                            [ceil for odd h]
//   slot_size  = align(offset_uv + stride_uv * chroma_rows, SLOT_ALIGN)
//   slot 0 base= first SLOT_ALIGN boundary at/after sizeof(header)
//   slot i     = base + i * slot_size
//   file size  = base + slot_count * slot_size
// --------------------------------------------------------------------------
static inline uint64_t mbs_align_u64(uint64_t v, uint64_t a) {
  return (v + (a - 1)) & ~(a - 1);
}

// Slot count. The protocol caps at MINIAV_BCAST_MAX_SLOTS (4). We use all 4:
// 4 NV12 1080p slots ≈ 12.7 MB, comfortably inside the ~50 MB ceiling, and the
// extra slot gives drop-oldest more slack before it must reclaim READY frames.
#define MBS_SLOT_COUNT MINIAV_BCAST_MAX_SLOTS

// Socket send timeout (ms). FRAME/HELLO/BYE headers are tiny; AUDIO is small.
// A blocked send past this means the host is not draining -> treat as
// disconnect and reconnect in the background.
#define MBS_SEND_TIMEOUT_MS 100

// Reconnect throttle: don't hammer connect() every frame while disconnected.
#define MBS_RECONNECT_INTERVAL_US (1000000ull) // 1 s

// Connect attempts inside mbs_open before falling back to "no consumer" mode.
#define MBS_OPEN_CONNECT_ATTEMPTS 10
#define MBS_OPEN_CONNECT_BACKOFF_US (50000ull) // 50 ms between attempts

// --------------------------------------------------------------------------
// Handle
// --------------------------------------------------------------------------
struct mbs_handle {
  // Ring mapping.
  int ring_fd;
  void *ring_base; // mmap base (whole file)
  size_t ring_size;
  MiniAVBcastRingHeader *hdr; // == ring_base (header at offset 0)
  uint8_t *slot0;             // ring_base + slot0_offset
  uint32_t slot_count;
  uint32_t slot_size; // per-slot bytes
  uint32_t width;
  uint32_t height;
  uint32_t stride_y;
  uint32_t stride_uv;
  uint32_t offset_uv;

  // Socket.
  int sock_fd; // -1 when disconnected / no consumer
  char sock_path[512];
  int connected;             // 0/1 (best-effort flag)
  uint64_t next_reconnect_us; // wall clock (us) of next allowed connect attempt

  // Producer frame sequence — bumped on every claim so the host can detect a
  // slot reclaimed out from under a stale FRAME descriptor.
  uint32_t next_seq;

  // "Log once" latches for repetitive drop reasons.
  int warned_format;
  int warned_dims;
  int warned_alllleased;

  // Paths (kept for logging only).
  char ring_path[512];
};

// --------------------------------------------------------------------------
// Atomic accessors over the shared mapping.
//
// The protocol stores slot_state[]/slot_seq[] as plain uint32_t cells accessed
// via atomic builtins on BOTH sides (same-arch mapping). We use __atomic_*
// (Clang/GCC) so this file needs no C11 _Atomic-qualified declarations against
// the packed struct.
// --------------------------------------------------------------------------
static inline uint32_t mbs_load_state(struct mbs_handle *h, uint32_t i) {
  return __atomic_load_n(&h->hdr->slot_state[i], __ATOMIC_ACQUIRE);
}
static inline uint32_t mbs_load_seq(struct mbs_handle *h, uint32_t i) {
  return __atomic_load_n(&h->hdr->slot_seq[i], __ATOMIC_RELAXED);
}
static inline void mbs_store_seq(struct mbs_handle *h, uint32_t i, uint32_t v) {
  __atomic_store_n(&h->hdr->slot_seq[i], v, __ATOMIC_RELAXED);
}
static inline void mbs_store_state(struct mbs_handle *h, uint32_t i,
                                   uint32_t v, int memorder) {
  __atomic_store_n(&h->hdr->slot_state[i], v, memorder);
}
// CAS expected->desired on a slot state. Returns 1 on success.
static inline int mbs_cas_state(struct mbs_handle *h, uint32_t i,
                                uint32_t expected, uint32_t desired) {
  uint32_t exp = expected;
  return __atomic_compare_exchange_n(&h->hdr->slot_state[i], &exp, desired,
                                     /*weak=*/0, __ATOMIC_ACQ_REL,
                                     __ATOMIC_ACQUIRE);
}

static inline uint64_t mbs_now_us(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000000ull + (uint64_t)tv.tv_usec;
}

// --------------------------------------------------------------------------
// App Group container path resolution.
//
// The extension resolves its App Group container directory through Foundation
// (containerURLForSecurityApplicationGroupIdentifier:) — this is the ONLY
// sanctioned way to get the sandbox-shared directory, and it works identically
// in an extension process. We keep the ObjC dependency minimal (Foundation is
// always linked into an ObjC extension anyway).
//
// Writes "<container>/<filename>" into out (size cap). Returns 0 on success.
// --------------------------------------------------------------------------
static int mbs_group_path(const char *app_group_id, const char *filename,
                          char *out, size_t out_sz) {
  if (!app_group_id || !filename || !out || out_sz == 0)
    return -1;
  @autoreleasepool {
    NSString *gid = [NSString stringWithUTF8String:app_group_id];
    if (!gid)
      return -1;
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:gid];
    if (!url) {
      MBS_LOG("App Group container not found for '%{public}s' — is the App "
              "Group capability added to the extension target?",
              app_group_id);
      return -1;
    }
    NSString *base = [url path];
    if (!base)
      return -1;
    const char *cbase = [base fileSystemRepresentation];
    if (!cbase)
      return -1;
    int n = snprintf(out, out_sz, "%s/%s", cbase, filename);
    if (n < 0 || (size_t)n >= out_sz)
      return -1;
  }
  return 0;
}

// --------------------------------------------------------------------------
// Socket connect / send (EINTR-safe, SIGPIPE-suppressed, timeouts).
// --------------------------------------------------------------------------
static int mbs_socket_connect(struct mbs_handle *h) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    MBS_LOG("socket() failed: %{public}s", strerror(errno));
    return -1;
  }

  // Suppress SIGPIPE on this fd (the host may vanish mid-send). SO_NOSIGPIPE is
  // the BSD/Darwin per-socket option; we ALSO pass MSG_NOSIGNAL-equivalent
  // behavior via this rather than the (Linux-only) flag.
  int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

  // Short send timeout so a stalled host doesn't wedge the sample thread.
  struct timeval to;
  to.tv_sec = MBS_SEND_TIMEOUT_MS / 1000;
  to.tv_usec = (MBS_SEND_TIMEOUT_MS % 1000) * 1000;
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof(to));

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t plen = strlen(h->sock_path);
  if (plen >= sizeof(addr.sun_path)) {
    MBS_LOG("socket path too long (%zu >= %zu)", plen, sizeof(addr.sun_path));
    close(fd);
    return -1;
  }
  memcpy(addr.sun_path, h->sock_path, plen + 1);

  int rc;
  do {
    rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
  } while (rc < 0 && errno == EINTR);

  if (rc < 0) {
    // ENOENT (host not listening yet) / ECONNREFUSED (no accept) are the
    // expected "host not up" cases — caller retries.
    close(fd);
    return -1;
  }

  h->sock_fd = fd;
  h->connected = 1;
  return 0;
}

// Send exactly len bytes; EINTR-safe; short-write loop. A timeout (EAGAIN/
// EWOULDBLOCK) or any other error is treated as disconnect. Returns 0 on full
// send, -1 otherwise (and marks the handle disconnected + closes the fd).
static int mbs_send_all(struct mbs_handle *h, const void *buf, size_t len) {
  if (h->sock_fd < 0)
    return -1;
  const uint8_t *p = (const uint8_t *)buf;
  size_t left = len;
  while (left > 0) {
    ssize_t n = send(h->sock_fd, p, left, 0);
    if (n > 0) {
      p += (size_t)n;
      left -= (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR)
      continue;
    // n == 0 (peer closed) or timeout/error -> disconnect.
    MBS_LOG("send failed (%{public}s) — marking disconnected",
            n < 0 ? strerror(errno) : "peer closed");
    close(h->sock_fd);
    h->sock_fd = -1;
    h->connected = 0;
    h->next_reconnect_us = mbs_now_us() + MBS_RECONNECT_INTERVAL_US;
    return -1;
  }
  return 0;
}

// Try a background reconnect if enough time has passed. Best-effort; on success
// re-sends HELLO so the freshly-attached host can validate + map the ring.
static void mbs_maybe_reconnect(struct mbs_handle *h) {
  if (h->connected)
    return;
  uint64_t now = mbs_now_us();
  if (now < h->next_reconnect_us)
    return;
  h->next_reconnect_us = now + MBS_RECONNECT_INTERVAL_US;
  if (mbs_socket_connect(h) != 0)
    return;

  // Reconnected — resend HELLO.
  MiniAVBcastMsgHeader mh;
  mh.type = MINIAV_BCAST_MSG_HELLO;
  mh.payload_len = (uint32_t)sizeof(MiniAVBcastHello);
  MiniAVBcastHello hello;
  hello.magic = MINIAV_BCAST_MAGIC;
  hello.version = MINIAV_BCAST_PROTO_VERSION;
  hello.width = h->width;
  hello.height = h->height;
  hello.pix_fmt = MINIAV_BCAST_PIXFMT_NV12;
  if (mbs_send_all(h, &mh, sizeof(mh)) == 0)
    mbs_send_all(h, &hello, sizeof(hello));
  if (h->connected)
    MBS_LOG("reconnected to host");
}

// --------------------------------------------------------------------------
// Ring creation
// --------------------------------------------------------------------------
static int mbs_create_ring(struct mbs_handle *h, const char *app_group_id) {
  if (mbs_group_path(app_group_id, MINIAV_BCAST_RING_FILENAME, h->ring_path,
                     sizeof(h->ring_path)) != 0)
    return -1;

  // Compute geometry.
  const uint32_t W = h->width, H = h->height;
  uint32_t stride_y = (uint32_t)mbs_align_u64(W, MINIAV_BCAST_ROW_ALIGN);
  uint32_t stride_uv = (uint32_t)mbs_align_u64(W, MINIAV_BCAST_ROW_ALIGN);
  uint32_t offset_uv =
      (uint32_t)mbs_align_u64((uint64_t)stride_y * H, MINIAV_BCAST_ROW_ALIGN);
  uint32_t chroma_rows = (H + 1u) / 2u;
  uint32_t slot_size = (uint32_t)mbs_align_u64(
      (uint64_t)offset_uv + (uint64_t)stride_uv * chroma_rows,
      MINIAV_BCAST_SLOT_ALIGN);

  uint64_t slot0_off =
      mbs_align_u64(sizeof(MiniAVBcastRingHeader), MINIAV_BCAST_SLOT_ALIGN);
  uint64_t total = slot0_off + (uint64_t)slot_size * MBS_SLOT_COUNT;

  h->stride_y = stride_y;
  h->stride_uv = stride_uv;
  h->offset_uv = offset_uv;
  h->slot_size = slot_size;
  h->slot_count = MBS_SLOT_COUNT;
  h->ring_size = (size_t)total;

  // Remove any stale ring from a prior crashed session (its FREE/READY states
  // and geometry could be inconsistent with ours). O_CREAT|O_TRUNC gives a
  // clean file; the host is required to re-validate MAGIC (written last) so a
  // truncated file it may already have mapped won't be trusted.
  unlink(h->ring_path);

  int fd = open(h->ring_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) {
    MBS_LOG("open(ring) failed: %{public}s (%{public}s)", strerror(errno),
            h->ring_path);
    return -1;
  }
  if (ftruncate(fd, (off_t)total) != 0) {
    MBS_LOG("ftruncate(%llu) failed: %{public}s", (unsigned long long)total,
            strerror(errno));
    close(fd);
    return -1;
  }

  void *base = mmap(NULL, (size_t)total, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                    0);
  if (base == MAP_FAILED) {
    MBS_LOG("mmap failed: %{public}s", strerror(errno));
    close(fd);
    return -1;
  }

  h->ring_fd = fd;
  h->ring_base = base;
  h->hdr = (MiniAVBcastRingHeader *)base;
  h->slot0 = (uint8_t *)base + slot0_off;

  // Write the header body FIRST (everything except magic), zero slot tables to
  // FREE / seq 0, then a barrier, then MAGIC last so a half-created file never
  // validates on the host.
  MiniAVBcastRingHeader *hdr = h->hdr;
  hdr->magic = 0; // NOT the real magic yet
  hdr->version = MINIAV_BCAST_PROTO_VERSION;
  hdr->slot_count = h->slot_count;
  hdr->slot_size_bytes = slot_size;
  hdr->width = W;
  hdr->height = H;
  hdr->pix_fmt = MINIAV_BCAST_PIXFMT_NV12;
  hdr->stride_y = stride_y;
  hdr->stride_uv = stride_uv;
  hdr->offset_uv = offset_uv;
  memset(hdr->reserved, 0, sizeof(hdr->reserved));
  for (uint32_t i = 0; i < MINIAV_BCAST_MAX_SLOTS; i++) {
    // Non-atomic init is fine: no other party may read before MAGIC lands.
    hdr->slot_state[i] = MINIAV_BCAST_SLOT_FREE;
    hdr->slot_seq[i] = 0;
  }

  // Publish the body before the magic. A full msync flushes the pages; the
  // trailing __atomic_store with release ordering on magic guarantees a host
  // that observes the magic also observes the fully-written body.
  msync(base, sizeof(MiniAVBcastRingHeader), MS_SYNC);
  __atomic_store_n(&hdr->magic, MINIAV_BCAST_MAGIC, __ATOMIC_RELEASE);
  msync(base, sizeof(MiniAVBcastRingHeader), MS_SYNC);

  MBS_LOG("ring created: %ux%u stride_y=%u stride_uv=%u off_uv=%u slot=%u "
          "bytes total=%llu (%u slots)",
          W, H, stride_y, stride_uv, offset_uv, slot_size,
          (unsigned long long)total, h->slot_count);
  return 0;
}

// --------------------------------------------------------------------------
// mbs_open
// --------------------------------------------------------------------------
mbs_handle *mbs_open(const char *app_group_id, uint32_t width,
                     uint32_t height) {
  if (!app_group_id || width == 0 || height == 0 ||
      width > MINIAV_BCAST_MAX_WIDTH || height > MINIAV_BCAST_MAX_HEIGHT) {
    MBS_LOG("mbs_open: bad args (group=%{public}s %ux%u)",
            app_group_id ? app_group_id : "(null)", width, height);
    return NULL;
  }

  struct mbs_handle *h = (struct mbs_handle *)calloc(1, sizeof(*h));
  if (!h) {
    MBS_LOG("mbs_open: calloc failed");
    return NULL;
  }
  h->ring_fd = -1;
  h->sock_fd = -1;
  h->width = width;
  h->height = height;
  h->next_seq = 1; // seq 0 is the ring's "never written" sentinel

  if (mbs_create_ring(h, app_group_id) != 0) {
    free(h);
    return NULL;
  }

  if (mbs_group_path(app_group_id, MINIAV_BCAST_SOCK_FILENAME, h->sock_path,
                     sizeof(h->sock_path)) != 0) {
    // Ring is up but we can't even form the socket path — unrecoverable.
    munmap(h->ring_base, h->ring_size);
    close(h->ring_fd);
    free(h);
    return NULL;
  }

  // Try to connect to the host listener with brief retry/backoff. The host may
  // not be listening yet; if we can't connect we still return a valid handle in
  // "no consumer" mode and retry later from mbs_send_video.
  int connected = 0;
  for (int attempt = 0; attempt < MBS_OPEN_CONNECT_ATTEMPTS; attempt++) {
    if (mbs_socket_connect(h) == 0) {
      connected = 1;
      break;
    }
    // EINTR-safe backoff sleep.
    struct timespec ts;
    ts.tv_sec = MBS_OPEN_CONNECT_BACKOFF_US / 1000000ull;
    ts.tv_nsec = (long)((MBS_OPEN_CONNECT_BACKOFF_US % 1000000ull) * 1000ull);
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
  }

  if (connected) {
    // Send HELLO so the host validates + maps the ring.
    MiniAVBcastMsgHeader mh;
    mh.type = MINIAV_BCAST_MSG_HELLO;
    mh.payload_len = (uint32_t)sizeof(MiniAVBcastHello);
    MiniAVBcastHello hello;
    hello.magic = MINIAV_BCAST_MAGIC;
    hello.version = MINIAV_BCAST_PROTO_VERSION;
    hello.width = width;
    hello.height = height;
    hello.pix_fmt = MINIAV_BCAST_PIXFMT_NV12;
    if (mbs_send_all(h, &mh, sizeof(mh)) == 0)
      mbs_send_all(h, &hello, sizeof(hello));
    MBS_LOG("mbs_open: connected to host, HELLO sent");
  } else {
    h->next_reconnect_us = mbs_now_us() + MBS_RECONNECT_INTERVAL_US;
    MBS_LOG("mbs_open: host not listening yet — operating in no-consumer mode, "
            "will retry");
  }

  return h;
}

// --------------------------------------------------------------------------
// Slot claim (drop-oldest, never overwrite LEASED, never stall).
//
// Returns the claimed slot index (state now WRITING, seq bumped + published),
// or -1 if all slots are LEASED (caller drops the frame).
// --------------------------------------------------------------------------
static int mbs_claim_slot(struct mbs_handle *h) {
  // Pass 1: prefer a FREE slot (CAS FREE -> WRITING).
  for (uint32_t i = 0; i < h->slot_count; i++) {
    if (mbs_load_state(h, i) == MINIAV_BCAST_SLOT_FREE) {
      if (mbs_cas_state(h, i, MINIAV_BCAST_SLOT_FREE,
                        MINIAV_BCAST_SLOT_WRITING)) {
        mbs_store_seq(h, i, h->next_seq++);
        return (int)i;
      }
    }
  }

  // Pass 2: reclaim the OLDEST un-leased READY slot (drop-oldest). "Oldest" =
  // smallest seq among READY slots. CAS READY -> WRITING; the seq bump then
  // makes any already-sent FRAME descriptor for that slot stale on the host.
  for (;;) {
    int best = -1;
    uint32_t best_seq = 0;
    for (uint32_t i = 0; i < h->slot_count; i++) {
      if (mbs_load_state(h, i) == MINIAV_BCAST_SLOT_READY) {
        uint32_t s = mbs_load_seq(h, i);
        if (best < 0 || s < best_seq) {
          best = (int)i;
          best_seq = s;
        }
      }
    }
    if (best < 0)
      break; // no READY slots left to reclaim
    if (mbs_cas_state(h, (uint32_t)best, MINIAV_BCAST_SLOT_READY,
                      MINIAV_BCAST_SLOT_WRITING)) {
      mbs_store_seq(h, (uint32_t)best, h->next_seq++);
      return best;
    }
    // Lost the race (host leased it first) — rescan.
  }

  // Every slot is LEASED — the host is holding all of them. Drop.
  return -1;
}

// --------------------------------------------------------------------------
// mbs_send_video
// --------------------------------------------------------------------------
int mbs_send_video(mbs_handle *h, CVPixelBufferRef pb, uint64_t ts_us) {
  if (!h || !pb)
    return -1;

  // Opportunistically try to reconnect if we're in no-consumer mode. Cheap.
  mbs_maybe_reconnect(h);

  // Validate format: v1 pins NV12 (420v / 420f). Anything else is dropped with
  // a once-only log.
  OSType pf = CVPixelBufferGetPixelFormatType(pb);
  if (pf != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
      pf != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    if (!h->warned_format) {
      h->warned_format = 1;
      MBS_LOG("dropping non-NV12 frame (pixfmt 0x%08x) — v1 pins NV12; is your "
              "ReplayKit video config biplanar?",
              (unsigned)pf);
    }
    return 0; // intentional drop, not an error
  }

  uint32_t fw = (uint32_t)CVPixelBufferGetWidth(pb);
  uint32_t fh = (uint32_t)CVPixelBufferGetHeight(pb);
  if (fw != h->width || fh != h->height) {
    if (!h->warned_dims) {
      h->warned_dims = 1;
      MBS_LOG("dropping frame with mismatched dims %ux%u (ring is %ux%u) — v1 "
              "pins geometry at mbs_open",
              fw, fh, h->width, h->height);
    }
    return 0; // intentional drop
  }

  if (CVPixelBufferGetPlaneCount(pb) < 2) {
    if (!h->warned_format) {
      h->warned_format = 1;
      MBS_LOG("dropping frame: expected 2 planes (NV12), got %zu",
              CVPixelBufferGetPlaneCount(pb));
    }
    return 0;
  }

  // Claim a slot. If all LEASED, drop cheaply.
  int slot = mbs_claim_slot(h);
  if (slot < 0) {
    if (!h->warned_alllleased) {
      h->warned_alllleased = 1;
      MBS_LOG("all slots leased by host — dropping (drop-oldest backpressure); "
              "this log fires once");
    }
    return 0; // intentional drop
  }
  uint32_t seq = mbs_load_seq(h, (uint32_t)slot);
  uint8_t *dst = h->slot0 + (uint64_t)slot * h->slot_size;

  // Lock the source for read. On failure, revert the slot to FREE so it isn't
  // stranded in WRITING forever.
  if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) !=
      kCVReturnSuccess) {
    MBS_LOG("CVPixelBufferLockBaseAddress failed — reverting slot %d to FREE",
            slot);
    mbs_store_state(h, (uint32_t)slot, MINIAV_BCAST_SLOT_FREE, __ATOMIC_RELEASE);
    return -1;
  }

  // --- The pipeline's ONLY pixel copy. ---
  // Y plane (plane 0): 1 byte/px, height rows.
  {
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb,
                                                                             0);
    size_t src_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    uint8_t *d = dst; // Y at slot base
    uint32_t copy_bytes = h->width; // valid bytes per row (dst stride padded)
    for (uint32_t row = 0; row < h->height; row++) {
      memcpy(d + (size_t)row * h->stride_y, src + (size_t)row * src_stride,
             copy_bytes);
    }
  }
  // UV plane (plane 1): interleaved, width bytes/row, (height+1)/2 rows.
  {
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb,
                                                                             1);
    size_t src_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint8_t *d = dst + h->offset_uv;
    uint32_t chroma_rows = (h->height + 1u) / 2u;
    uint32_t copy_bytes = h->width; // NV12 UV = width bytes per row
    for (uint32_t row = 0; row < chroma_rows; row++) {
      memcpy(d + (size_t)row * h->stride_uv, src + (size_t)row * src_stride,
             copy_bytes);
    }
  }

  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

  // Publish: WRITING -> READY with release ordering so the host, on acquiring
  // the READY state, sees the fully-copied pixels.
  mbs_store_state(h, (uint32_t)slot, MINIAV_BCAST_SLOT_READY, __ATOMIC_RELEASE);

  // Post the descriptor. A socket failure is NOT a hard error — the slot is
  // already READY; mbs_send_all flags disconnected + schedules reconnect.
  if (h->connected) {
    MiniAVBcastMsgHeader mh;
    mh.type = MINIAV_BCAST_MSG_FRAME;
    mh.payload_len = (uint32_t)sizeof(MiniAVBcastFrameMsg);
    MiniAVBcastFrameMsg fm;
    fm.slot = (uint32_t)slot;
    fm.seq = seq;
    fm.ts_us = ts_us;
    if (mbs_send_all(h, &mh, sizeof(mh)) == 0)
      mbs_send_all(h, &fm, sizeof(fm));
  }
  // If not connected, the slot sits READY and will be reclaimed by drop-oldest
  // on a later frame — harmless (no consumer to serve).

  return 0;
}

// --------------------------------------------------------------------------
// mbs_send_audio
// --------------------------------------------------------------------------
int mbs_send_audio(mbs_handle *h, const void *pcm, uint32_t frame_count,
                   uint32_t sample_rate, uint16_t channels,
                   uint16_t sample_format_1s16_2f32, uint64_t ts_us) {
  if (!h || !pcm || frame_count == 0 || channels == 0)
    return -1;
  if (sample_format_1s16_2f32 != MBS_AUDIO_FMT_S16 &&
      sample_format_1s16_2f32 != MBS_AUDIO_FMT_F32)
    return -1;

  // No consumer -> drop cheaply (video path owns reconnect).
  if (!h->connected)
    return 0;

  uint32_t bytes_per_sample =
      (sample_format_1s16_2f32 == MBS_AUDIO_FMT_S16) ? 2u : 4u;
  uint64_t data_bytes =
      (uint64_t)frame_count * (uint64_t)channels * (uint64_t)bytes_per_sample;

  MiniAVBcastMsgHeader mh;
  mh.type = MINIAV_BCAST_MSG_AUDIO;
  // payload_len = the AUDIO body header + the inline PCM data (per protocol).
  mh.payload_len = (uint32_t)(sizeof(MiniAVBcastAudioMsg) + data_bytes);

  MiniAVBcastAudioMsg am;
  am.sample_rate = sample_rate;
  am.channels = channels;
  am.sample_format = sample_format_1s16_2f32;
  am.frame_count = frame_count;
  am.ts_us = ts_us;

  // Three sends: msg header, audio body header, inline PCM. On any failure the
  // handle is flagged disconnected; audio is fire-and-forget so we just bail.
  if (mbs_send_all(h, &mh, sizeof(mh)) != 0)
    return 0;
  if (mbs_send_all(h, &am, sizeof(am)) != 0)
    return 0;
  if (mbs_send_all(h, pcm, (size_t)data_bytes) != 0)
    return 0;
  return 0;
}

// --------------------------------------------------------------------------
// mbs_close
// --------------------------------------------------------------------------
void mbs_close(mbs_handle *h) {
  if (!h)
    return;

  // Best-effort BYE.
  if (h->connected && h->sock_fd >= 0) {
    MiniAVBcastMsgHeader mh;
    mh.type = MINIAV_BCAST_MSG_BYE;
    mh.payload_len = 0;
    mbs_send_all(h, &mh, sizeof(mh));
  }

  if (h->sock_fd >= 0) {
    close(h->sock_fd);
    h->sock_fd = -1;
  }
  if (h->ring_base && h->ring_base != MAP_FAILED) {
    munmap(h->ring_base, h->ring_size);
    h->ring_base = NULL;
  }
  if (h->ring_fd >= 0) {
    close(h->ring_fd);
    h->ring_fd = -1;
  }
  // Leave the ring FILE in place: the host may still be draining leased slots
  // and mmap keeps the inode alive regardless; the next mbs_open unlinks +
  // recreates it. (Unlinking here would race a still-mapped host.)

  free(h);
}
