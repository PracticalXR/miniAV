// iOS ReplayKit screen-capture backend — BOTH tiers.
//
//   "app_screen"              — in-app capture via RPScreenRecorder
//                               startCaptureWithHandler: (B.3a).
//   "system_screen_broadcast" — system-wide capture consumed from a Broadcast
//                               Upload Extension through an App Group shared-
//                               memory ring + unix-domain socket (B.3b). This
//                               file is the CONSUMER/host side of the pinned
//                               contract in miniav_broadcast_protocol.h.
//
// MRC (no ARC): every alloc/retain is balanced by an explicit release, exactly
// like the macOS .mm backends. Atomics over the shared ring mapping use the C11
// __atomic builtins (the header cells are plain uint32_t storage).
//
// See MOBILE_PLATFORM_SPEC.md §B.3 for the architecture.

#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#error "screen_context_ios_replaykit.mm is iOS-only (TARGET_OS_IPHONE)."
#endif

#include "screen_context_ios_replaykit.h"
#include "miniav_broadcast_protocol.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"
#include "../../../include/miniav_buffer.h"

#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <limits.h> // PATH_MAX
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Pseudo-display identifiers (returned from EnumerateDisplays; the configured
// id selects the tier).
// ---------------------------------------------------------------------------
#define IOS_DISPLAY_ID_APP "app_screen"
#define IOS_DISPLAY_ID_BROADCAST "system_screen_broadcast"

// Bounded-teardown budgets (see the destroy/stop leak protocol in screen_api.c).
#define IOS_RK_STOP_TIMEOUT_SEC 5
#define IOS_RK_BROADCAST_JOIN_TIMEOUT_MS 5000u

// Queue-specific tag so stop/destroy called from inside the ReplayKit sample
// handler queue can skip a self-deadlocking dispatch_sync drain.
static const void *kMiniAVIOSScreenQueueKey = &kMiniAVIOSScreenQueueKey;

// ---------------------------------------------------------------------------
// App Group id — set via MiniAV_Screen_SetIOSAppGroup(). Guarded by a mutex
// because it may be set from an arbitrary caller thread while a context reads
// it during Configure. The string is copied (NULL clears).
// ---------------------------------------------------------------------------
static pthread_mutex_t g_app_group_mutex = PTHREAD_MUTEX_INITIALIZER;
static char *g_app_group_id = NULL; // heap copy, or NULL

MiniAVResultCode miniav_screen_ios_set_app_group(const char *app_group_id) {
  pthread_mutex_lock(&g_app_group_mutex);
  if (g_app_group_id) {
    miniav_free(g_app_group_id);
    g_app_group_id = NULL;
  }
  if (app_group_id && app_group_id[0] != '\0') {
    g_app_group_id = miniav_strdup(app_group_id);
    if (!g_app_group_id) {
      pthread_mutex_unlock(&g_app_group_mutex);
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: Failed to copy iOS App Group id (out of memory).");
      return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: iOS App Group set to '%s'.",
               g_app_group_id);
  } else {
    miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: iOS App Group cleared.");
  }
  pthread_mutex_unlock(&g_app_group_mutex);
  return MINIAV_SUCCESS;
}

// Returns a heap copy of the current App Group id (caller frees), or NULL if
// unset. Snapshot under the lock so a concurrent set can't free it mid-read.
static char *ios_copy_app_group(void) {
  pthread_mutex_lock(&g_app_group_mutex);
  char *copy = g_app_group_id ? miniav_strdup(g_app_group_id) : NULL;
  pthread_mutex_unlock(&g_app_group_mutex);
  return copy;
}

// ---------------------------------------------------------------------------
// Tier selection + platform context.
// ---------------------------------------------------------------------------
typedef enum {
  IOS_TIER_NONE = 0,
  IOS_TIER_APP,       // RPScreenRecorder in-app
  IOS_TIER_BROADCAST, // App Group ring consumer
} IOSCaptureTier;

@class MiniAVReplayKitCoordinator;

typedef struct IOSScreenPlatformContext {
  MiniAVScreenContext *parent_ctx;

  IOSCaptureTier tier;
  MiniAVVideoInfo configured_video_format;
  char selected_display_id[MINIAV_DEVICE_ID_MAX_LEN];

  // Delivery queue: serializes buffer construction/callback and lets
  // stop/destroy drain in-flight blocks. Both tiers deliver through it.
  dispatch_queue_t deliveryQueue;

  // Metal (in-app GPU path via CVMetalTextureCache; broadcast GPU path via a
  // single newBufferWithBytesNoCopy over the ring mapping).
  id<MTLDevice> metalDevice;
  CVMetalTextureCacheRef textureCache; // in-app tier only

  // Timestamp rebasing (producer CMTime µs -> shared epoch). Only touched on
  // the single delivery/receiver thread.
  MiniAVTimebase ts_rebase;

  // One-shot lost_cb guard (broadcast disconnect and in-app didStop race).
  std::atomic<bool> lost_cb_fired;

  std::atomic<bool> is_streaming;

  // In-app start-completion coordination (mirrors the macOS SCK abandon
  // protocol). ios_start_app_tier bumps start_pending_count and snapshots
  // start_generation before calling startCaptureWithHandler:. The completion
  // block re-checks the generation: if a timeout has since bumped it, the block
  // is stale — it MUST NOT publish is_streaming/startResult; if the start had
  // actually succeeded it instead undoes the orphan recording (stopCapture).
  // EVERY completion block (stale or fresh) decrements start_pending_count as
  // its final act, so the count tracks how many blocks may still dereference
  // plat (a timed-out start can be retried, leaving several outstanding). It is
  // a count, not a bool, precisely so a fresh block resolving one start doesn't
  // clear the gate while a stale block from an earlier timed-out start is still
  // pending. destroy MUST NOT free plat while the count is nonzero — a late
  // consent block still dereferences plat (bounded leak beats a use-after-free a
  // ReplayKit block will still touch).
  std::atomic<uint32_t> start_generation;
  std::atomic<uint32_t> start_pending_count;

  MiniAVBufferCallback app_callback_internal;
  void *app_callback_user_data_internal;

  // ---- In-app tier (RPScreenRecorder) ----
  MiniAVReplayKitCoordinator *coordinator; // retains delegate glue

  // ---- Broadcast tier (App Group ring consumer) ----
  char *app_group_id; // heap copy captured at Configure

  int listen_fd; // listening unix-domain socket (-1 if none)
  int conn_fd;   // accepted extension connection (-1 if none)
  // Self-pipe: stop writes a byte to wake the receiver out of poll() promptly
  // and portably (closing a socket another thread blocks on is unreliable).
  int wake_pipe[2]; // [0]=read end (polled), [1]=write end; -1 if unset
  char sock_path[PATH_MAX];
  char ring_path[PATH_MAX];

  pthread_t receiver_thread;
  bool receiver_thread_started;
  // Set by stop/destroy to ask the receiver loop to exit; the loop also exits
  // on socket EOF/BYE.
  std::atomic<bool> receiver_should_stop;
  // Signalled by the receiver thread just before it returns, so a bounded join
  // can wait without pthread_timedjoin_np (absent on Bionic/Darwin).
  pthread_mutex_t receiver_exit_mutex;
  pthread_cond_t receiver_exit_cond;
  bool receiver_exited;

  // The ring mapping. Wrapped ONCE by ring_mtl_buffer (newBufferWithBytesNoCopy)
  // at connect time; per-frame textures are views into it. Reference-counted:
  // outstanding leases keep it alive after the connection closes.
  int ring_fd;         // -1 if none
  void *ring_base;     // mmap base (page-aligned), or NULL
  size_t ring_map_len; // mmap length
  MiniAVBcastRingHeader *ring_header; // == ring_base
  id<MTLBuffer> ring_mtl_buffer;      // no-copy MTLBuffer over ring_base
  // Guards the mapping refcount + teardown decision. mapping_refs counts
  // outstanding leased buffers + 1 while the connection is open. munmap and
  // MTLBuffer release happen only when it reaches 0.
  pthread_mutex_t mapping_mutex;
  uint32_t mapping_refs;
  bool connection_open;
} IOSScreenPlatformContext;

// ---------------------------------------------------------------------------
// Payload kinds carried in MiniAVNativeBufferInternalPayload.context_owner-side
// handling. We reuse the standard payload struct; the release op distinguishes
// by handle_type + content_type + a per-payload back-pointer we stash in
// native_planar_resource_ptrs[MINIAV_VIDEO_FORMAT_MAX_PLANES-...] is NOT abused;
// instead broadcast leases carry the platform ctx via context_owner and the
// slot index via a small heap record referenced by native_singular_resource_ptr.
// ---------------------------------------------------------------------------

// Heap record attached to a broadcast video buffer so release can return the
// slot lease and drop the mapping ref. The leading magic lets release confirm
// this really is a lease (belt-and-braces on top of the tier check) before it
// touches slot state.
#define IOS_BCAST_LEASE_MAGIC 0x4C424353u /* 'LBCS' */
typedef struct IOSBroadcastLease {
  uint32_t magic; // IOS_BCAST_LEASE_MAGIC
  IOSScreenPlatformContext *plat;
  uint32_t slot;
} IOSBroadcastLease;

// ---------------------------------------------------------------------------
// Forward declarations.
// ---------------------------------------------------------------------------
static void ios_fire_lost_cb(IOSScreenPlatformContext *plat, const char *why,
                             MiniAVResultCode code);
static void ios_broadcast_close_connection(IOSScreenPlatformContext *plat);
static void ios_mapping_ref_release(IOSScreenPlatformContext *plat);

// ===========================================================================
// Shared helpers
// ===========================================================================

// Rebases a producer CMTime-derived microsecond timestamp onto the shared
// epoch. Called only from the single delivery/receiver thread.
static int64_t ios_rebase_ts_us(IOSScreenPlatformContext *plat, uint64_t ts_us) {
  if (ts_us == 0) {
    return (int64_t)miniav_get_time_us();
  }
  return (int64_t)miniav_rebase_time_us(&plat->ts_rebase, ts_us);
}

// Fires lost_cb exactly once per run and marks the capture dead. Safe to call
// from any thread. Per the MiniAVContextLostCallback contract, the app must not
// synchronously Stop/Destroy from inside the callback.
static void ios_fire_lost_cb(IOSScreenPlatformContext *plat, const char *why,
                             MiniAVResultCode code) {
  if (!plat) {
    return;
  }
  plat->is_streaming.store(false);
  if (plat->lost_cb_fired.exchange(true)) {
    return;
  }
  MiniAVScreenContext *parent = plat->parent_ctx;
  miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: Capture lost (%s) — notifying app.",
             why ? why : "unknown");
  if (parent) {
    parent->is_running = false;
    if (parent->lost_cb) {
      // Guard against a concurrent MiniAV_Dispose() quiescing callbacks.
      if (miniav_dispatch_guard_acquire_if_enabled()) {
        parent->lost_cb((int)code, parent->lost_cb_user_data);
        miniav_dispatch_guard_release();
      }
    }
  }
}

// Builds and delivers an audio MiniAVBuffer from interleaved PCM. Copies the
// PCM (owned by the buffer, freed on release). Used by both tiers.
static void ios_deliver_audio(IOSScreenPlatformContext *plat,
                              const void *pcm, size_t pcm_bytes,
                              MiniAVAudioFormat fmt, uint32_t sample_rate,
                              uint8_t channels, uint32_t frame_count,
                              uint64_t producer_ts_us) {
  if (!plat->parent_ctx || !plat->parent_ctx->capture_audio_requested) {
    return;
  }
  if (!plat->app_callback_internal || !plat->is_streaming.load()) {
    return;
  }
  if (!pcm || pcm_bytes == 0) {
    return;
  }

  void *audioCopy = miniav_malloc(pcm_bytes);
  if (!audioCopy) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: Failed to allocate audio copy.");
    return;
  }
  memcpy(audioCopy, pcm, pcm_bytes);

  MiniAVBuffer *buffer = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  if (!buffer) {
    miniav_free(audioCopy);
    return;
  }
  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  if (!payload) {
    miniav_free(audioCopy);
    miniav_free(buffer);
    return;
  }

  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
  payload->context_owner = plat->parent_ctx;
  payload->parent_miniav_buffer_ptr = buffer;
  payload->native_singular_resource_ptr = audioCopy;
  buffer->internal_handle = payload;

  buffer->type = MINIAV_BUFFER_TYPE_AUDIO;
  buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
  buffer->timestamp_us = ios_rebase_ts_us(plat, producer_ts_us);
  buffer->data_size_bytes = pcm_bytes;
  buffer->data.audio.info.format = fmt;
  buffer->data.audio.info.channels = channels;
  buffer->data.audio.info.sample_rate = sample_rate;
  buffer->data.audio.info.num_frames = frame_count;
  buffer->data.audio.frame_count = frame_count;
  buffer->data.audio.data = audioCopy;
  buffer->user_data = plat->app_callback_user_data_internal;

  MINIAV_SAFE_DISPATCH(plat->app_callback_internal(
      buffer, plat->app_callback_user_data_internal));
}

// ===========================================================================
// In-app tier: RPScreenRecorder
// ===========================================================================

// Translates a CVPixelBuffer pixel format to a truthful MiniAVPixelFormat.
static MiniAVPixelFormat ios_cvfmt_to_miniav(OSType cv) {
  switch (cv) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: // '420v'
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  // '420f'
    return MINIAV_PIXEL_FORMAT_NV12;
  case kCVPixelFormatType_32BGRA:
    return MINIAV_PIXEL_FORMAT_BGRA32;
  default:
    return MINIAV_PIXEL_FORMAT_UNKNOWN;
  }
}

@interface MiniAVReplayKitCoordinator : NSObject {
@public
  IOSScreenPlatformContext *_plat;
}
- (instancetype)initWithPlat:(IOSScreenPlatformContext *)plat;
- (void)handleSample:(CMSampleBufferRef)sampleBuffer
              ofType:(RPSampleBufferType)bufferType;
@end

@implementation MiniAVReplayKitCoordinator

- (instancetype)initWithPlat:(IOSScreenPlatformContext *)plat {
  self = [super init];
  if (self) {
    _plat = plat;
  }
  return self;
}

- (void)handleSample:(CMSampleBufferRef)sampleBuffer
              ofType:(RPSampleBufferType)bufferType {
  IOSScreenPlatformContext *plat = _plat;
  if (!plat || !plat->is_streaming.load() || !plat->app_callback_internal) {
    return;
  }
  if (!CMSampleBufferIsValid(sampleBuffer)) {
    return;
  }

  if (bufferType == RPSampleBufferTypeVideo) {
    [self processVideo:sampleBuffer];
  } else if (bufferType == RPSampleBufferTypeAudioApp) {
    [self processAudio:sampleBuffer];
  } else if (bufferType == RPSampleBufferTypeAudioMic) {
    // Only surface mic when audio capture was requested (mic is opt-in;
    // RPScreenRecorder.microphoneEnabled is set at start based on this flag).
    if (plat->parent_ctx && plat->parent_ctx->capture_audio_requested) {
      [self processAudio:sampleBuffer];
    }
  }
}

- (void)processAudio:(CMSampleBufferRef)sampleBuffer {
  IOSScreenPlatformContext *plat = _plat;
  if (!plat->parent_ctx || !plat->parent_ctx->capture_audio_requested) {
    return;
  }

  CMFormatDescriptionRef formatDesc =
      CMSampleBufferGetFormatDescription(sampleBuffer);
  if (!formatDesc) {
    return;
  }
  const AudioStreamBasicDescription *asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
  if (!asbd) {
    return;
  }

  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (!blockBuffer) {
    return;
  }
  size_t totalLength = 0;
  char *dataPtr = NULL;
  OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL,
                                                &totalLength, &dataPtr);
  if (status != kCMBlockBufferNoErr || !dataPtr || totalLength == 0) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "RK: Failed to get app-audio data pointer (status %d).",
               (int)status);
    return;
  }

  MiniAVAudioFormat fmt = MINIAV_AUDIO_FORMAT_UNKNOWN;
  if (asbd->mFormatID == kAudioFormatLinearPCM) {
    if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
      if (asbd->mBitsPerChannel == 32) {
        fmt = MINIAV_AUDIO_FORMAT_F32;
      } else if (asbd->mBitsPerChannel == 64) {
        fmt = MINIAV_AUDIO_FORMAT_F64;
      }
    } else {
      if (asbd->mBitsPerChannel == 16) {
        fmt = MINIAV_AUDIO_FORMAT_S16;
      } else if (asbd->mBitsPerChannel == 32) {
        fmt = MINIAV_AUDIO_FORMAT_S32;
      }
    }
  }

  CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
  uint64_t ts_us = 0;
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (CMTIME_IS_NUMERIC(pts)) {
    CMTime tsUs =
        CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default);
    ts_us = (uint64_t)tsUs.value;
  }

  ios_deliver_audio(plat, dataPtr, totalLength, fmt,
                    (uint32_t)asbd->mSampleRate,
                    (uint8_t)asbd->mChannelsPerFrame, (uint32_t)frameCount,
                    ts_us);
}

- (void)processVideo:(CMSampleBufferRef)sampleBuffer {
  IOSScreenPlatformContext *plat = _plat;
  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!imageBuffer) {
    return;
  }

  MiniAVBuffer *buffer = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  if (!buffer) {
    return;
  }
  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  if (!payload) {
    miniav_free(buffer);
    return;
  }

  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
  payload->context_owner = plat->parent_ctx;
  payload->parent_miniav_buffer_ptr = buffer;
  buffer->internal_handle = payload;

  OSType cvfmt = CVPixelBufferGetPixelFormatType(imageBuffer);
  MiniAVPixelFormat miniavFmt = ios_cvfmt_to_miniav(cvfmt);
  bool is_nv12 = (cvfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                  cvfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
  bool is_bgra = (cvfmt == kCVPixelFormatType_32BGRA);

  bool use_gpu_path =
      (plat->configured_video_format.output_preference ==
       MINIAV_OUTPUT_PREFERENCE_GPU);
  bool gpu_path_successful = false;

  size_t frame_w = CVPixelBufferGetWidth(imageBuffer);
  size_t frame_h = CVPixelBufferGetHeight(imageBuffer);

  // Total data size (used for CPU and reported for GPU).
  size_t total_data_size = 0;
  if (CVPixelBufferIsPlanar(imageBuffer)) {
    size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
    for (size_t i = 0; i < planeCount; ++i) {
      total_data_size += CVPixelBufferGetHeightOfPlane(imageBuffer, i) *
                         CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, i);
    }
  } else {
    total_data_size =
        frame_h * CVPixelBufferGetBytesPerRow(imageBuffer);
  }

  // -------- GPU path (CVMetalTextureCache) --------
  if (use_gpu_path && plat->metalDevice && plat->textureCache &&
      (is_nv12 || is_bgra)) {
    if (is_bgra) {
      CVMetalTextureRef texRef = NULL;
      CVReturn err = CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, plat->textureCache, imageBuffer, NULL,
          MTLPixelFormatBGRA8Unorm, frame_w, frame_h, 0, &texRef);
      if (err == kCVReturnSuccess && texRef) {
        id<MTLTexture> tex = CVMetalTextureGetTexture(texRef);
        if (tex) {
          CFRetain(texRef);
          payload->native_singular_resource_ptr = texRef;
          buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE;
          buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_BGRA32;
          buffer->data.video.num_planes = 1;
          buffer->data.video.planes[0].data_ptr = (void *)tex;
          buffer->data.video.planes[0].width = (uint32_t)[tex width];
          buffer->data.video.planes[0].height = (uint32_t)[tex height];
          buffer->data.video.planes[0].stride_bytes = 0;
          gpu_path_successful = true;
        } else {
          CFRelease(texRef);
        }
      }
    } else { // is_nv12: two textures (R8 + RG8)
      size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
      CVMetalTextureRef planeRefs[MINIAV_VIDEO_FORMAT_MAX_PLANES] = {0};
      id<MTLTexture> planeTex[MINIAV_VIDEO_FORMAT_MAX_PLANES] = {0};
      bool all_ok = (planeCount == 2);
      for (size_t i = 0; all_ok && i < planeCount; ++i) {
        MTLPixelFormat pf =
            (i == 1) ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm;
        size_t pw = CVPixelBufferGetWidthOfPlane(imageBuffer, i);
        size_t ph = CVPixelBufferGetHeightOfPlane(imageBuffer, i);
        CVMetalTextureRef ref = NULL;
        CVReturn perr = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, plat->textureCache, imageBuffer, NULL, pf, pw,
            ph, i, &ref);
        if (perr == kCVReturnSuccess && ref) {
          id<MTLTexture> t = CVMetalTextureGetTexture(ref);
          if (t) {
            planeRefs[i] = ref;
            planeTex[i] = t;
          } else {
            CFRelease(ref);
            all_ok = false;
          }
        } else {
          all_ok = false;
        }
      }
      if (all_ok) {
        CVBufferRetain(imageBuffer);
        payload->native_singular_resource_ptr = (void *)imageBuffer;
        for (size_t i = 0; i < planeCount; ++i) {
          payload->native_planar_resource_ptrs[i] = planeRefs[i];
        }
        payload->num_planar_resources_to_release = (uint32_t)planeCount;

        buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE;
        buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_NV12;
        buffer->data.video.num_planes = (uint32_t)planeCount;
        for (size_t i = 0; i < planeCount; ++i) {
          buffer->data.video.planes[i].data_ptr = (void *)planeTex[i];
          buffer->data.video.planes[i].width = (uint32_t)[planeTex[i] width];
          buffer->data.video.planes[i].height = (uint32_t)[planeTex[i] height];
          buffer->data.video.planes[i].stride_bytes = 0;
          buffer->data.video.planes[i].subresource_index = (uint32_t)i;
        }
        gpu_path_successful = true;
      } else {
        for (size_t i = 0; i < planeCount; ++i) {
          if (planeRefs[i]) {
            CFRelease(planeRefs[i]);
          }
        }
      }
    }
  }

  // -------- CPU path (lock base address) --------
  if (!gpu_path_successful) {
    CVBufferRetain(imageBuffer);
    payload->native_singular_resource_ptr = (void *)imageBuffer;
    if (CVPixelBufferLockBaseAddress(imageBuffer,
                                     kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: CPU path — failed to lock pixel buffer.");
      CVBufferRelease(imageBuffer);
      miniav_free(buffer);
      miniav_free(payload);
      return;
    }
    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    buffer->data.video.info.pixel_format = miniavFmt;
    if (CVPixelBufferIsPlanar(imageBuffer)) {
      size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
      buffer->data.video.num_planes = (uint32_t)planeCount;
      for (size_t i = 0; i < planeCount && i < MINIAV_VIDEO_FORMAT_MAX_PLANES;
           ++i) {
        buffer->data.video.planes[i].data_ptr =
            CVPixelBufferGetBaseAddressOfPlane(imageBuffer, i);
        buffer->data.video.planes[i].width =
            (uint32_t)CVPixelBufferGetWidthOfPlane(imageBuffer, i);
        buffer->data.video.planes[i].height =
            (uint32_t)CVPixelBufferGetHeightOfPlane(imageBuffer, i);
        buffer->data.video.planes[i].stride_bytes =
            (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, i);
      }
    } else {
      buffer->data.video.num_planes = 1;
      buffer->data.video.planes[0].data_ptr =
          CVPixelBufferGetBaseAddress(imageBuffer);
      buffer->data.video.planes[0].width = (uint32_t)frame_w;
      buffer->data.video.planes[0].height = (uint32_t)frame_h;
      buffer->data.video.planes[0].stride_bytes =
          (uint32_t)CVPixelBufferGetBytesPerRow(imageBuffer);
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
  }

  buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
  buffer->data.video.info.width = (uint32_t)frame_w;
  buffer->data.video.info.height = (uint32_t)frame_h;
  buffer->data_size_bytes = total_data_size;
  buffer->data.video.info.frame_rate_numerator =
      plat->configured_video_format.frame_rate_numerator;
  buffer->data.video.info.frame_rate_denominator =
      plat->configured_video_format.frame_rate_denominator;
  buffer->data.video.info.output_preference =
      plat->configured_video_format.output_preference;

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  uint64_t ts_us = 0;
  if (CMTIME_IS_NUMERIC(pts)) {
    CMTime tsUs =
        CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default);
    ts_us = (uint64_t)tsUs.value;
  }
  buffer->timestamp_us = ios_rebase_ts_us(plat, ts_us);
  buffer->user_data = plat->app_callback_user_data_internal;

  MINIAV_SAFE_DISPATCH(plat->app_callback_internal(
      buffer, plat->app_callback_user_data_internal));
}

@end

// ===========================================================================
// Broadcast tier: App Group ring consumer
// ===========================================================================

// Fully-robust read of exactly `len` bytes from fd into buf. Poll()s on fd AND
// the wake pipe so a stop request unblocks us promptly, and loops over partial
// reads / EINTR. Returns 0 on success, -1 on EOF/error/stop (caller then treats
// the connection as ended). fd is left in blocking mode; poll gates the read so
// it never blocks past data availability.
static int ios_read_full(IOSScreenPlatformContext *plat, int fd, void *buf,
                         size_t len) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < len) {
    if (plat->receiver_should_stop.load()) {
      return -1;
    }
    struct pollfd pfds[2];
    pfds[0].fd = fd;
    pfds[0].events = POLLIN;
    pfds[0].revents = 0;
    int nfds = 1;
    if (plat->wake_pipe[0] >= 0) {
      pfds[1].fd = plat->wake_pipe[0];
      pfds[1].events = POLLIN;
      pfds[1].revents = 0;
      nfds = 2;
    }
    int pr = poll(pfds, nfds, -1);
    if (pr < 0) {
      if (errno == EINTR) {
        continue;
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: poll() error: %s", strerror(errno));
      return -1;
    }
    if (nfds == 2 && (pfds[1].revents & POLLIN)) {
      return -1; // stop requested via wake pipe
    }
    if (!(pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
      continue;
    }
    ssize_t n = read(fd, p + got, len - got);
    if (n > 0) {
      got += (size_t)n;
    } else if (n == 0) {
      return -1; // EOF: producer closed / died
    } else {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: socket read error: %s",
                 strerror(errno));
      return -1;
    }
  }
  return 0;
}

// Validates the ring header against the pinned protocol geometry bounds. Returns
// true if the header is safe to consume.
static bool ios_validate_ring_header(const MiniAVBcastRingHeader *h,
                                     size_t map_len) {
  if (h->magic != MINIAV_BCAST_MAGIC) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: ring magic mismatch (0x%08x).",
               h->magic);
    return false;
  }
  if (h->version != MINIAV_BCAST_PROTO_VERSION) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: ring version %u != expected %u — dropping.", h->version,
               (unsigned)MINIAV_BCAST_PROTO_VERSION);
    return false;
  }
  if (h->slot_count == 0 || h->slot_count > MINIAV_BCAST_MAX_SLOTS) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: bad slot_count %u.", h->slot_count);
    return false;
  }
  if (h->width == 0 || h->width > MINIAV_BCAST_MAX_WIDTH || h->height == 0 ||
      h->height > MINIAV_BCAST_MAX_HEIGHT) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: bad dims %ux%u.", h->width,
               h->height);
    return false;
  }
  if (h->pix_fmt != MINIAV_BCAST_PIXFMT_NV12) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: unsupported pix_fmt %u.",
               h->pix_fmt);
    return false;
  }
  if (h->stride_y < h->width || h->stride_uv < h->width) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: stride below width.");
    return false;
  }
  if (h->slot_size_bytes == 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: zero slot_size_bytes.");
    return false;
  }
  // Plane extents must fit inside a slot. Y plane: stride_y * height at offset
  // 0. UV plane: stride_uv * ceil(height/2) at offset_uv.
  uint64_t y_bytes = (uint64_t)h->stride_y * h->height;
  uint64_t uv_rows = ((uint64_t)h->height + 1u) / 2u;
  uint64_t uv_bytes = (uint64_t)h->stride_uv * uv_rows;
  if (h->offset_uv < y_bytes) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: offset_uv %u overlaps Y plane (%llu bytes).", h->offset_uv,
               (unsigned long long)y_bytes);
    return false;
  }
  if ((uint64_t)h->offset_uv + uv_bytes > h->slot_size_bytes) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: UV plane exceeds slot_size_bytes.");
    return false;
  }
  // The whole ring (header + aligned slot base + slot_count slots) must fit the
  // mapping. Slot 0 begins at the first SLOT_ALIGN boundary after the header.
  uint64_t hdr = (uint64_t)sizeof(MiniAVBcastRingHeader);
  uint64_t slot0 =
      (hdr + (MINIAV_BCAST_SLOT_ALIGN - 1)) & ~((uint64_t)MINIAV_BCAST_SLOT_ALIGN - 1);
  uint64_t need = slot0 + (uint64_t)h->slot_count * h->slot_size_bytes;
  if (need > map_len) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: ring geometry (%llu bytes) exceeds mapping (%zu).",
               (unsigned long long)need, map_len);
    return false;
  }
  return true;
}

// Returns the byte offset of slot i within the mapping.
static size_t ios_slot_offset(const MiniAVBcastRingHeader *h, uint32_t slot) {
  size_t hdr = sizeof(MiniAVBcastRingHeader);
  size_t slot0 = (hdr + (MINIAV_BCAST_SLOT_ALIGN - 1)) &
                 ~((size_t)MINIAV_BCAST_SLOT_ALIGN - 1);
  return slot0 + (size_t)slot * h->slot_size_bytes;
}

// Acquire the mapping ref (for a new lease). Must be called with the mapping
// present. Returns false if the mapping is gone.
static bool ios_mapping_ref_acquire(IOSScreenPlatformContext *plat) {
  bool ok = false;
  pthread_mutex_lock(&plat->mapping_mutex);
  // A live mapping has ring_base set and at least the connection's own ref.
  // ring_mtl_buffer may be nil (CPU-only) — that's still a valid mapping.
  if (plat->ring_base && plat->mapping_refs > 0) {
    plat->mapping_refs++;
    ok = true;
  }
  pthread_mutex_unlock(&plat->mapping_mutex);
  return ok;
}

// Release one mapping ref; tears the mapping down when the last ref (the
// connection's own ref plus any leases) drops.
static void ios_mapping_ref_release(IOSScreenPlatformContext *plat) {
  pthread_mutex_lock(&plat->mapping_mutex);
  bool teardown = false;
  if (plat->mapping_refs > 0) {
    plat->mapping_refs--;
    if (plat->mapping_refs == 0) {
      teardown = true;
    }
  }
  id<MTLBuffer> mtlToRelease = nil;
  void *baseToUnmap = NULL;
  size_t lenToUnmap = 0;
  int fdToClose = -1;
  if (teardown) {
    mtlToRelease = plat->ring_mtl_buffer;
    plat->ring_mtl_buffer = nil;
    baseToUnmap = plat->ring_base;
    lenToUnmap = plat->ring_map_len;
    plat->ring_base = NULL;
    plat->ring_header = NULL;
    plat->ring_map_len = 0;
    fdToClose = plat->ring_fd;
    plat->ring_fd = -1;
  }
  pthread_mutex_unlock(&plat->mapping_mutex);

  if (teardown) {
    if (mtlToRelease) {
      [mtlToRelease release]; // MRC: balance newBufferWithBytesNoCopy
    }
    if (baseToUnmap) {
      munmap(baseToUnmap, lenToUnmap);
    }
    if (fdToClose >= 0) {
      close(fdToClose);
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "RK: ring mapping torn down.");
  }
}

// Opens + mmaps the ring file and wraps it once with a no-copy MTLBuffer (if a
// Metal device is present). On success mapping_refs == 1 (the connection's own
// ref) and connection_open == true. Returns MINIAV_SUCCESS or an error.
static MiniAVResultCode ios_broadcast_map_ring(IOSScreenPlatformContext *plat,
                                               uint32_t hello_w,
                                               uint32_t hello_h) {
  // Refuse to clobber a mapping that is still alive: if a prior broadcast ended
  // but the app still holds leases, ring_base is non-NULL and mapping_refs>0.
  // Overwriting it here would (a) leak the old mapping/MTLBuffer/fd and (b) make
  // stale leases release into the NEW ring — corrupting its slot state and
  // dropping this connection's refs to zero mid-delivery (use-after-free). Wait
  // for the old leases to drain (teardown nulls ring_base) before remapping.
  pthread_mutex_lock(&plat->mapping_mutex);
  bool prior_alive = (plat->ring_base != NULL);
  pthread_mutex_unlock(&plat->mapping_mutex);
  if (prior_alive) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "RK: previous ring mapping still has outstanding leases — "
               "rejecting new broadcast connection until they drain.");
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  int fd = open(plat->ring_path, O_RDWR);
  if (fd < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: open ring '%s' failed: %s",
               plat->ring_path, strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size <= 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: fstat ring failed or empty.");
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if ((uint64_t)st.st_size < sizeof(MiniAVBcastRingHeader)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: ring smaller than header.");
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  size_t map_len = (size_t)st.st_size;
  // mmap guarantees a page-aligned base — required so slot 0 (SLOT_ALIGN) and
  // the whole-mapping MTLBuffer wrap are page-aligned.
  void *base = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (base == MAP_FAILED) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: mmap ring failed: %s",
               strerror(errno));
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  MiniAVBcastRingHeader *hdr = (MiniAVBcastRingHeader *)base;
  if (!ios_validate_ring_header(hdr, map_len)) {
    munmap(base, map_len);
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  // Cross-check the HELLO dims against the ring header (the two must agree).
  if (hello_w != hdr->width || hello_h != hdr->height) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: HELLO dims %ux%u disagree with ring %ux%u.", hello_w,
               hello_h, hdr->width, hdr->height);
    munmap(base, map_len);
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }

  // Wrap the whole mapping ONCE with a no-copy shared MTLBuffer (GPU path).
  // Best-effort: if it fails, the CPU zero-copy path still works.
  id<MTLBuffer> mtlBuf = nil;
  if (plat->metalDevice) {
    mtlBuf = [plat->metalDevice newBufferWithBytesNoCopy:base
                                                  length:map_len
                                                 options:MTLResourceStorageModeShared
                                             deallocator:nil];
    if (!mtlBuf) {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "RK: newBufferWithBytesNoCopy failed — GPU tier unavailable, "
                 "CPU zero-copy still works.");
    }
  }

  pthread_mutex_lock(&plat->mapping_mutex);
  plat->ring_fd = fd;
  plat->ring_base = base;
  plat->ring_map_len = map_len;
  plat->ring_header = hdr;
  plat->ring_mtl_buffer = mtlBuf; // may be nil (CPU-only)
  plat->mapping_refs = 1;         // the connection's own ref
  plat->connection_open = true;
  pthread_mutex_unlock(&plat->mapping_mutex);

  // Reset timestamp rebase for this connection.
  memset(&plat->ts_rebase, 0, sizeof(plat->ts_rebase));

  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "RK: ring mapped %zu bytes, %u slots, %ux%u NV12 (GPU:%s).",
             map_len, hdr->slot_count, hdr->width, hdr->height,
             mtlBuf ? "yes" : "no");
  return MINIAV_SUCCESS;
}

// Attempts to lease slot `slot` (CAS READY->LEASED) and verify seq matches.
// Returns true on a successful lease. On stale seq / not-ready it returns false
// (frame skipped — the producer reclaimed it via drop-oldest).
static bool ios_broadcast_try_lease(MiniAVBcastRingHeader *hdr, uint32_t slot,
                                    uint32_t seq) {
  uint32_t expected = MINIAV_BCAST_SLOT_READY;
  // Acquire on success so the slot pixel writes (producer's release-store of
  // READY) are visible before we read them.
  if (!__atomic_compare_exchange_n(&hdr->slot_state[slot], &expected,
                                   (uint32_t)MINIAV_BCAST_SLOT_LEASED,
                                   /*weak=*/false, __ATOMIC_ACQUIRE,
                                   __ATOMIC_ACQUIRE)) {
    return false; // not READY (already reclaimed / never was)
  }
  uint32_t cur_seq = __atomic_load_n(&hdr->slot_seq[slot], __ATOMIC_ACQUIRE);
  if (cur_seq != seq) {
    // The slot holds a NEWER fully-published frame (its own FRAME descriptor is
    // still queued behind us), not garbage. Restore READY — not FREE — so that
    // queued descriptor can still lease it; storing FREE would discard a valid
    // frame under drop-oldest. We hold LEASED, so no one else can touch the slot
    // until this release-store publishes READY.
    __atomic_store_n(&hdr->slot_state[slot], (uint32_t)MINIAV_BCAST_SLOT_READY,
                     __ATOMIC_RELEASE);
    return false;
  }
  return true;
}

// Delivers a leased broadcast slot as a video MiniAVBuffer (GPU planar textures
// if a no-copy MTLBuffer exists and GPU preferred; else CPU plane pointers into
// the mapping). The slot stays LEASED until MiniAV_ReleaseBuffer. On any failure
// the lease is returned here and the mapping ref is NOT taken.
static void ios_broadcast_deliver_frame(IOSScreenPlatformContext *plat,
                                        uint32_t slot, uint64_t ts_us) {
  MiniAVBcastRingHeader *hdr = plat->ring_header;
  if (!hdr) {
    return;
  }
  uint8_t *slot_base = (uint8_t *)plat->ring_base + ios_slot_offset(hdr, slot);
  size_t slot_off = ios_slot_offset(hdr, slot);

  bool want_gpu = (plat->configured_video_format.output_preference ==
                   MINIAV_OUTPUT_PREFERENCE_GPU) &&
                  (plat->ring_mtl_buffer != nil);

  MiniAVBuffer *buffer = (MiniAVBuffer *)miniav_calloc(1, sizeof(MiniAVBuffer));
  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)miniav_calloc(
          1, sizeof(MiniAVNativeBufferInternalPayload));
  IOSBroadcastLease *lease =
      (IOSBroadcastLease *)miniav_calloc(1, sizeof(IOSBroadcastLease));
  if (!buffer || !payload || !lease) {
    miniav_free(buffer);
    miniav_free(payload);
    miniav_free(lease);
    // Return the lease so the producer can reuse the slot.
    __atomic_store_n(&hdr->slot_state[slot], (uint32_t)MINIAV_BCAST_SLOT_FREE,
                     __ATOMIC_RELEASE);
    return;
  }

  // Take a mapping ref for this lease (kept until release). If the mapping is
  // gone (shouldn't happen mid-loop), bail and return the slot.
  if (!ios_mapping_ref_acquire(plat)) {
    miniav_free(buffer);
    miniav_free(payload);
    miniav_free(lease);
    __atomic_store_n(&hdr->slot_state[slot], (uint32_t)MINIAV_BCAST_SLOT_FREE,
                     __ATOMIC_RELEASE);
    return;
  }

  lease->magic = IOS_BCAST_LEASE_MAGIC;
  lease->plat = plat;
  lease->slot = slot;

  payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
  payload->context_owner = plat->parent_ctx;
  payload->parent_miniav_buffer_ptr = buffer;
  payload->native_singular_resource_ptr = lease; // slot-return record
  buffer->internal_handle = payload;

  buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
  buffer->data.video.info.width = hdr->width;
  buffer->data.video.info.height = hdr->height;
  buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_NV12;
  buffer->data.video.info.frame_rate_numerator =
      plat->configured_video_format.frame_rate_numerator;
  buffer->data.video.info.frame_rate_denominator =
      plat->configured_video_format.frame_rate_denominator;
  buffer->data.video.info.output_preference =
      plat->configured_video_format.output_preference;
  buffer->data.video.num_planes = 2;
  buffer->data_size_bytes =
      (size_t)hdr->stride_y * hdr->height +
      (size_t)hdr->stride_uv * (((size_t)hdr->height + 1) / 2);
  buffer->timestamp_us = ios_rebase_ts_us(plat, ts_us);
  buffer->user_data = plat->app_callback_user_data_internal;

  // NOTE: the caller (receiver pump loop) wraps each message iteration in an
  // @autoreleasepool, so autoreleased temporaries here (MTLTextureDescriptors)
  // are drained per frame. The retained id<MTLTexture> views survive because
  // newTexture... returns an owned (+1) reference, not an autoreleased one.
  bool delivered_gpu = false;
  if (want_gpu) {
    // Per-frame texture VIEWS into the single no-copy MTLBuffer at slot offsets.
    // Y: R8Unorm @ stride_y; UV: RG8Unorm @ stride_uv, offset slot+offset_uv.
    MTLTextureDescriptor *yDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                     width:hdr->width
                                    height:hdr->height
                                 mipmapped:NO];
    yDesc.storageMode = MTLStorageModeShared;
    yDesc.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *uvDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                     width:(hdr->width + 1) / 2
                                    height:(hdr->height + 1) / 2
                                 mipmapped:NO];
    uvDesc.storageMode = MTLStorageModeShared;
    uvDesc.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> yTex =
        [plat->ring_mtl_buffer newTextureWithDescriptor:yDesc
                                                 offset:slot_off
                                            bytesPerRow:hdr->stride_y];
    id<MTLTexture> uvTex =
        [plat->ring_mtl_buffer newTextureWithDescriptor:uvDesc
                                                 offset:slot_off + hdr->offset_uv
                                            bytesPerRow:hdr->stride_uv];
    if (yTex && uvTex) {
      // newTexture... returns a retained ("new") object under MRC; store for
      // release.
      payload->native_planar_resource_ptrs[0] = (void *)yTex;
      payload->native_planar_resource_ptrs[1] = (void *)uvTex;
      payload->num_planar_resources_to_release = 2;

      buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE;
      buffer->data.video.planes[0].data_ptr = (void *)yTex;
      buffer->data.video.planes[0].width = hdr->width;
      buffer->data.video.planes[0].height = hdr->height;
      buffer->data.video.planes[0].stride_bytes = 0;
      buffer->data.video.planes[0].subresource_index = 0;
      buffer->data.video.planes[1].data_ptr = (void *)uvTex;
      buffer->data.video.planes[1].width = (hdr->width + 1) / 2;
      buffer->data.video.planes[1].height = (hdr->height + 1) / 2;
      buffer->data.video.planes[1].stride_bytes = 0;
      buffer->data.video.planes[1].subresource_index = 1;
      delivered_gpu = true;
    } else {
      if (yTex) {
        [yTex release];
      }
      if (uvTex) {
        [uvTex release];
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "RK: broadcast GPU texture view creation failed — CPU path.");
    }
  }

  if (!delivered_gpu) {
    // CPU zero-copy: plane pointers into the mapped slot.
    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    buffer->data.video.planes[0].data_ptr = slot_base;
    buffer->data.video.planes[0].width = hdr->width;
    buffer->data.video.planes[0].height = hdr->height;
    buffer->data.video.planes[0].stride_bytes = hdr->stride_y;
    buffer->data.video.planes[1].data_ptr = slot_base + hdr->offset_uv;
    buffer->data.video.planes[1].width = (hdr->width + 1) / 2;
    buffer->data.video.planes[1].height = (hdr->height + 1) / 2;
    buffer->data.video.planes[1].stride_bytes = hdr->stride_uv;
  }

  MINIAV_SAFE_DISPATCH(plat->app_callback_internal(
      buffer, plat->app_callback_user_data_internal));
}

// Handles one AUDIO message: reads the fixed body then the inline PCM payload.
static int ios_broadcast_handle_audio(IOSScreenPlatformContext *plat, int fd,
                                      uint32_t payload_len) {
  if (payload_len < sizeof(MiniAVBcastAudioMsg)) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: AUDIO payload_len too small.");
    return -1;
  }
  MiniAVBcastAudioMsg amsg;
  if (ios_read_full(plat, fd, &amsg, sizeof(amsg)) != 0) {
    return -1;
  }
  size_t data_bytes = payload_len - sizeof(MiniAVBcastAudioMsg);
  // Sanity cap: reject absurd sizes to avoid a hostile/corrupt producer OOMing
  // us (16 MB is far beyond any single PCM chunk).
  if (data_bytes > (16u * 1024u * 1024u)) {
    miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: AUDIO data_bytes %zu too large.",
               data_bytes);
    return -1;
  }
  void *pcm = NULL;
  if (data_bytes > 0) {
    pcm = miniav_malloc(data_bytes);
    if (!pcm) {
      return -1;
    }
    if (ios_read_full(plat, fd, pcm, data_bytes) != 0) {
      miniav_free(pcm);
      return -1;
    }
  }

  MiniAVAudioFormat fmt = (amsg.sample_format == 2) ? MINIAV_AUDIO_FORMAT_F32
                                                    : MINIAV_AUDIO_FORMAT_S16;
  if (pcm) {
    ios_deliver_audio(plat, pcm, data_bytes, fmt, amsg.sample_rate,
                      (uint8_t)amsg.channels, amsg.frame_count, amsg.ts_us);
    miniav_free(pcm);
  }
  return 0;
}

// Receiver-thread main loop: accept one extension connection, read HELLO, map
// the ring, then pump FRAME/AUDIO/BYE until EOF/BYE/stop. On end, fire lost_cb
// (unless we were asked to stop) and clean up the connection.
static void *ios_broadcast_receiver_thread(void *arg) {
  IOSScreenPlatformContext *plat = (IOSScreenPlatformContext *)arg;

  // Accept loop: one broadcast at a time. If it ends (EOF/BYE) we exit; the app
  // restarts capture to accept a new broadcast (per spec).
  while (!plat->receiver_should_stop.load()) {
    // poll() listen_fd + wake pipe so a stop unblocks us promptly.
    struct pollfd pfds[2];
    pfds[0].fd = plat->listen_fd;
    pfds[0].events = POLLIN;
    pfds[0].revents = 0;
    int nfds = 1;
    if (plat->wake_pipe[0] >= 0) {
      pfds[1].fd = plat->wake_pipe[0];
      pfds[1].events = POLLIN;
      pfds[1].revents = 0;
      nfds = 2;
    }
    int pr = poll(pfds, nfds, -1);
    if (pr < 0) {
      if (errno == EINTR) {
        continue;
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: accept-poll error: %s",
                 strerror(errno));
      break;
    }
    if (plat->receiver_should_stop.load() ||
        (nfds == 2 && (pfds[1].revents & POLLIN))) {
      break; // stop requested
    }
    if (!(pfds[0].revents & POLLIN)) {
      continue;
    }
    int cfd = accept(plat->listen_fd, NULL, NULL);
    if (cfd < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }
      if (plat->receiver_should_stop.load()) {
        break;
      }
      miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: accept() failed: %s",
                 strerror(errno));
      break;
    }
    plat->conn_fd = cfd;
    miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: broadcast extension connected.");

    // ---- HELLO ----
    MiniAVBcastMsgHeader mh;
    bool connection_ok = false;
    if (ios_read_full(plat, cfd, &mh, sizeof(mh)) == 0 &&
        mh.type == MINIAV_BCAST_MSG_HELLO &&
        mh.payload_len == sizeof(MiniAVBcastHello)) {
      MiniAVBcastHello hello;
      if (ios_read_full(plat, cfd, &hello, sizeof(hello)) == 0) {
        if (hello.magic != MINIAV_BCAST_MAGIC ||
            hello.version != MINIAV_BCAST_PROTO_VERSION) {
          miniav_log(MINIAV_LOG_LEVEL_ERROR,
                     "RK: HELLO magic/version mismatch (0x%08x v%u) — dropping "
                     "connection, still listening.",
                     hello.magic, hello.version);
        } else if (ios_broadcast_map_ring(plat, hello.width, hello.height) ==
                   MINIAV_SUCCESS) {
          connection_ok = true;
        }
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: expected HELLO, got type=%u len=%u — dropping.", mh.type,
                 mh.payload_len);
    }

    if (!connection_ok) {
      close(cfd);
      plat->conn_fd = -1;
      // Keep listening for a well-formed connection (unless stopping).
      continue;
    }

    // ---- FRAME/AUDIO/BYE pump ----
    bool ended_by_peer = false;
    while (!plat->receiver_should_stop.load()) {
      // Drain per iteration: the receiver is a bare pthread with no ambient
      // autorelease pool, and each frame/audio message may create autoreleased
      // ObjC temporaries (and the app callback runs synchronously here too).
      @autoreleasepool {
        if (ios_read_full(plat, cfd, &mh, sizeof(mh)) != 0) {
          ended_by_peer = true; // EOF or error = producer gone
          break;
        }
        if (mh.type == MINIAV_BCAST_MSG_FRAME) {
        if (mh.payload_len != sizeof(MiniAVBcastFrameMsg)) {
          miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: bad FRAME payload_len.");
          ended_by_peer = true;
          break;
        }
        MiniAVBcastFrameMsg fm;
        if (ios_read_full(plat, cfd, &fm, sizeof(fm)) != 0) {
          ended_by_peer = true;
          break;
        }
        MiniAVBcastRingHeader *hdr = plat->ring_header;
        if (!hdr || fm.slot >= hdr->slot_count) {
          miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: FRAME slot %u out of range.",
                     fm.slot);
          continue; // ignore bogus descriptor, keep going
        }
        if (ios_broadcast_try_lease(hdr, fm.slot, fm.seq)) {
          ios_broadcast_deliver_frame(plat, fm.slot, fm.ts_us);
        }
        // stale/not-ready → producer reclaimed via drop-oldest; skip silently.
      } else if (mh.type == MINIAV_BCAST_MSG_AUDIO) {
        if (ios_broadcast_handle_audio(plat, cfd, mh.payload_len) != 0) {
          ended_by_peer = true;
          break;
        }
      } else if (mh.type == MINIAV_BCAST_MSG_BYE) {
        miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: broadcast BYE received.");
        ended_by_peer = true;
        break;
      } else {
        // Unknown type: drain its payload if any, then continue.
        if (mh.payload_len > 0) {
          uint8_t scratch[512];
          uint32_t remaining = mh.payload_len;
          bool drain_ok = true;
          while (remaining > 0) {
            uint32_t chunk =
                remaining > sizeof(scratch) ? (uint32_t)sizeof(scratch)
                                            : remaining;
            if (ios_read_full(plat, cfd, scratch, chunk) != 0) {
              drain_ok = false;
              break;
            }
            remaining -= chunk;
          }
          if (!drain_ok) {
            ended_by_peer = true;
            break;
          }
        }
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "RK: ignoring unknown msg type %u.",
                   mh.type);
        }
      } // @autoreleasepool
    }

    // Connection ended. Close the fd + drop the connection's mapping ref (the
    // mapping survives until outstanding leases are also released).
    close(cfd);
    plat->conn_fd = -1;
    ios_broadcast_close_connection(plat);

    if (ended_by_peer && !plat->receiver_should_stop.load()) {
      // Producer stopped/died without our asking → one-shot lost_cb. The app
      // restarts capture to accept a new broadcast.
      ios_fire_lost_cb(plat, "broadcast ended", MINIAV_ERROR_DEVICE_LOST);
      break; // exit the accept loop; a fresh StartCapture re-arms it.
    }
    if (plat->receiver_should_stop.load()) {
      break;
    }
    // else: loop back and accept a new connection.
  }

  // Signal the bounded join.
  pthread_mutex_lock(&plat->receiver_exit_mutex);
  plat->receiver_exited = true;
  pthread_cond_signal(&plat->receiver_exit_cond);
  pthread_mutex_unlock(&plat->receiver_exit_mutex);
  return NULL;
}

// Marks the connection closed and drops its own mapping ref (leases keep the
// mapping alive). Idempotent.
static void ios_broadcast_close_connection(IOSScreenPlatformContext *plat) {
  bool was_open = false;
  pthread_mutex_lock(&plat->mapping_mutex);
  if (plat->connection_open) {
    plat->connection_open = false;
    was_open = true;
  }
  pthread_mutex_unlock(&plat->mapping_mutex);
  if (was_open) {
    ios_mapping_ref_release(plat); // release the connection's own ref
  }
}

// Wakes the receiver thread out of poll() by writing one byte to the self-pipe.
// Safe to call repeatedly; the write is non-blocking.
static void ios_broadcast_wake_receiver(IOSScreenPlatformContext *plat) {
  if (plat->wake_pipe[1] >= 0) {
    const uint8_t b = 1;
    ssize_t w = write(plat->wake_pipe[1], &b, 1);
    (void)w; // best-effort; a full pipe already means "wake pending"
  }
}

// Bounded join of the receiver thread. Returns 0 if joined, nonzero on timeout
// (thread leaked; caller must leak the context per the protocol).
static int ios_broadcast_join_receiver(IOSScreenPlatformContext *plat,
                                       unsigned timeout_ms) {
  if (!plat->receiver_thread_started) {
    return 0;
  }
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  ts.tv_sec += timeout_ms / 1000;
  ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (ts.tv_nsec >= 1000000000L) {
    ts.tv_sec += 1;
    ts.tv_nsec -= 1000000000L;
  }

  int wait_rc = 0;
  pthread_mutex_lock(&plat->receiver_exit_mutex);
  while (!plat->receiver_exited && wait_rc == 0) {
    wait_rc = pthread_cond_timedwait(&plat->receiver_exit_cond,
                                     &plat->receiver_exit_mutex, &ts);
  }
  bool exited = plat->receiver_exited;
  pthread_mutex_unlock(&plat->receiver_exit_mutex);

  if (exited) {
    pthread_join(plat->receiver_thread, NULL);
    plat->receiver_thread_started = false;
    return 0;
  }
  // Timed out: detach so the OS reaps it when it eventually exits; leave state
  // it references leaked (caller returns MINIAV_ERROR_TIMEOUT).
  miniav_log(MINIAV_LOG_LEVEL_ERROR,
             "RK: broadcast receiver thread did not exit in %u ms — leaking it.",
             timeout_ms);
  pthread_detach(plat->receiver_thread);
  return -1;
}

// ===========================================================================
// Ops
// ===========================================================================

static MiniAVResultCode ios_init_platform(MiniAVScreenContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)miniav_calloc(
          1, sizeof(IOSScreenPlatformContext));
  if (!plat) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  ctx->platform_ctx = plat;
  plat->parent_ctx = ctx;
  plat->tier = IOS_TIER_NONE;
  plat->listen_fd = -1;
  plat->conn_fd = -1;
  plat->ring_fd = -1;
  plat->wake_pipe[0] = -1;
  plat->wake_pipe[1] = -1;
  plat->is_streaming.store(false);
  plat->lost_cb_fired.store(false);
  plat->receiver_should_stop.store(false);
  plat->start_generation.store(0);
  plat->start_pending_count.store(0);

  pthread_mutex_init(&plat->mapping_mutex, NULL);
  pthread_mutex_init(&plat->receiver_exit_mutex, NULL);
  pthread_cond_init(&plat->receiver_exit_cond, NULL);

  @autoreleasepool {
    plat->deliveryQueue =
        dispatch_queue_create("com.miniav.screen.ios.delivery",
                              DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(plat->deliveryQueue, kMiniAVIOSScreenQueueKey,
                                (void *)1, NULL);

    plat->metalDevice = MTLCreateSystemDefaultDevice();
    if (plat->metalDevice) {
      CVReturn err = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL,
                                               plat->metalDevice, NULL,
                                               &plat->textureCache);
      if (err != kCVReturnSuccess) {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "RK: CVMetalTextureCacheCreate failed — GPU path limited.");
        plat->textureCache = NULL;
      }
    } else {
      miniav_log(MINIAV_LOG_LEVEL_WARN,
                 "RK: no Metal device — GPU path unavailable.");
    }
  }

  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "RK: platform context initialized.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_destroy_platform(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_SUCCESS;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)ctx->platform_ctx;

  // Stop any capture first (mirrors the API layer's own stop-before-destroy).
  plat->receiver_should_stop.store(true);
  plat->is_streaming.store(false);

  // ---- Broadcast tier teardown ----
  // Wake the receiver out of poll() promptly (self-pipe), and shut the active
  // connection so an in-flight read() returns. Do NOT close listen_fd/wake_pipe
  // yet — the receiver thread still polls them; close only after it joins.
  ios_broadcast_wake_receiver(plat);
  if (plat->conn_fd >= 0) {
    shutdown(plat->conn_fd, SHUT_RDWR);
  }
  if (plat->receiver_thread_started) {
    if (ios_broadcast_join_receiver(plat, IOS_RK_BROADCAST_JOIN_TIMEOUT_MS) !=
        0) {
      // Bounded-leak protocol: the receiver thread still references plat, so we
      // must not free it. Tell MiniAV_Screen_DestroyContext to leak the parent
      // too (it dereferences THIS parent via callbacks/format).
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: destroy timed out joining receiver — leaking context.");
      ctx->platform_ctx = NULL;
      return MINIAV_ERROR_TIMEOUT;
    }
  }
  // Receiver has exited: safe to close listen/wake fds.
  if (plat->listen_fd >= 0) {
    close(plat->listen_fd);
    plat->listen_fd = -1;
  }
  if (plat->wake_pipe[0] >= 0) {
    close(plat->wake_pipe[0]);
    plat->wake_pipe[0] = -1;
  }
  if (plat->wake_pipe[1] >= 0) {
    close(plat->wake_pipe[1]);
    plat->wake_pipe[1] = -1;
  }
  // Drop the connection's mapping ref if still open (no leases can exist once
  // the receiver has joined and no buffers are outstanding — but if the app
  // still holds leases, munmap is deferred to the last ReleaseBuffer).
  ios_broadcast_close_connection(plat);

  // Unlink stale socket file if we created it.
  if (plat->sock_path[0] != '\0') {
    unlink(plat->sock_path);
  }

  // "Cannot free yet" gate (Findings 1/2/5). Two independent things may still
  // dereference plat after this destroy returns:
  //   (a) an outstanding in-app start completion block (start_pending_count>0) —
  //       a late consent tap writes plat and, if stale, stops the orphan
  //       recording;
  //   (b) outstanding broadcast leases (mapping_refs > 0 after the connection's
  //       own ref was dropped by close_connection above) — the app's later
  //       MiniAV_ReleaseBuffer locks mapping_mutex and writes through
  //       ring_header/slot_state.
  // Either alone means we must NOT destroy mapping_mutex / release Metal / free
  // plat. Per the documented shutdown protocol we leak the platform context and
  // return TIMEOUT so the API layer also leaks the parent (keeping the fields a
  // late block/lease touches valid). This is placed AFTER the receiver join and
  // connection close but BEFORE any teardown a late block/lease still needs — a
  // bounded leak beats freed memory a ReplayKit block or lease will still touch.
  bool start_pending = (plat->start_pending_count.load() > 0);
  bool leases_outstanding = false;
  pthread_mutex_lock(&plat->mapping_mutex);
  leases_outstanding = (plat->mapping_refs > 0);
  pthread_mutex_unlock(&plat->mapping_mutex);
  if (start_pending || leases_outstanding) {
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "RK: destroy deferred — %s%s%s still reference the context; "
               "leaking it to avoid a use-after-free.",
               start_pending ? "a pending start completion" : "",
               (start_pending && leases_outstanding) ? " and " : "",
               leases_outstanding ? "outstanding broadcast leases" : "");
    ctx->platform_ctx = NULL;
    return MINIAV_ERROR_TIMEOUT;
  }

  @autoreleasepool {
    // ---- In-app tier teardown ----
    if (plat->tier == IOS_TIER_APP) {
      RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
      if ([recorder isRecording]) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [recorder stopCaptureWithHandler:^(NSError *error) {
          (void)error;
          dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(
                sem, dispatch_time(DISPATCH_TIME_NOW,
                                   IOS_RK_STOP_TIMEOUT_SEC * NSEC_PER_SEC)) !=
            0) {
          miniav_log(MINIAV_LOG_LEVEL_WARN,
                     "RK: stopCapture timed out during destroy.");
        }
        dispatch_release(sem);
      }
    }
    if (plat->coordinator) {
      [plat->coordinator release];
      plat->coordinator = nil;
    }

    // Drain in-flight delivery blocks before freeing the context they touch.
    if (plat->deliveryQueue &&
        dispatch_get_specific(kMiniAVIOSScreenQueueKey) == NULL) {
      dispatch_sync(plat->deliveryQueue, ^{
      });
    }
    if (plat->deliveryQueue) {
      dispatch_release(plat->deliveryQueue);
      plat->deliveryQueue = nil;
    }

    if (plat->textureCache) {
      CVMetalTextureCacheFlush(plat->textureCache, 0);
      CFRelease(plat->textureCache);
      plat->textureCache = NULL;
    }
    if (plat->metalDevice) {
      [plat->metalDevice release];
      plat->metalDevice = nil;
    }
  }

  pthread_mutex_destroy(&plat->mapping_mutex);
  pthread_mutex_destroy(&plat->receiver_exit_mutex);
  pthread_cond_destroy(&plat->receiver_exit_cond);

  if (plat->app_group_id) {
    miniav_free(plat->app_group_id);
    plat->app_group_id = NULL;
  }

  miniav_free(plat);
  ctx->platform_ctx = NULL;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "RK: platform context destroyed.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_enumerate_displays(MiniAVDeviceInfo **displays_out,
                                               uint32_t *count_out) {
  if (!displays_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *displays_out = NULL;
  *count_out = 0;

  MiniAVDeviceInfo *list =
      (MiniAVDeviceInfo *)miniav_calloc(2, sizeof(MiniAVDeviceInfo));
  if (!list) {
    return MINIAV_ERROR_OUT_OF_MEMORY;
  }
  miniav_strlcpy(list[0].device_id, IOS_DISPLAY_ID_APP,
                 MINIAV_DEVICE_ID_MAX_LEN);
  miniav_strlcpy(list[0].name, "In-App Screen (ReplayKit)",
                 MINIAV_DEVICE_NAME_MAX_LEN);
  list[0].is_default = true;

  miniav_strlcpy(list[1].device_id, IOS_DISPLAY_ID_BROADCAST,
                 MINIAV_DEVICE_ID_MAX_LEN);
  miniav_strlcpy(list[1].name, "System Screen (Broadcast)",
                 MINIAV_DEVICE_NAME_MAX_LEN);
  list[1].is_default = false;

  *displays_out = list;
  *count_out = 2;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_enumerate_windows(MiniAVDeviceInfo **windows_out,
                                              uint32_t *count_out) {
  if (!windows_out || !count_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  *windows_out = NULL;
  *count_out = 0;
  return MINIAV_SUCCESS; // iOS has no window capture concept.
}

// Sets up the listening unix-domain socket for the broadcast tier under the App
// Group container. Unlinks a stale socket first. On success listen_fd is armed.
static MiniAVResultCode ios_broadcast_setup_socket(
    IOSScreenPlatformContext *plat) {
  // Resolve the App Group container path via NSFileManager.
  char container[PATH_MAX];
  container[0] = '\0';
  @autoreleasepool {
    NSString *groupId = [NSString stringWithUTF8String:plat->app_group_id];
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:groupId];
    if (!url) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: containerURLForSecurityApplicationGroupIdentifier('%s') "
                 "returned nil — is the App Group entitlement present?",
                 plat->app_group_id);
      return MINIAV_ERROR_NOT_CONFIGURED;
    }
    const char *cpath = [[url path] fileSystemRepresentation];
    if (!cpath) {
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    miniav_strlcpy(container, cpath, sizeof(container));
  }

  int wrote = snprintf(plat->sock_path, sizeof(plat->sock_path), "%s/%s",
                       container, MINIAV_BCAST_SOCK_FILENAME);
  if (wrote <= 0 || (size_t)wrote >= sizeof(plat->sock_path)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: socket path too long.");
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  snprintf(plat->ring_path, sizeof(plat->ring_path), "%s/%s", container,
           MINIAV_BCAST_RING_FILENAME);

  // A sockaddr_un path is length-limited (~104 bytes on Darwin). Fail loudly if
  // the container path pushes us over rather than silently truncating.
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(plat->sock_path) >= sizeof(addr.sun_path)) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: socket path '%s' exceeds sockaddr_un limit (%zu).",
               plat->sock_path, sizeof(addr.sun_path));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  miniav_strlcpy(addr.sun_path, plat->sock_path, sizeof(addr.sun_path));

  // Remove a stale socket from a prior run (bind fails with EADDRINUSE
  // otherwise).
  unlink(plat->sock_path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: socket() failed: %s",
               strerror(errno));
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: bind('%s') failed: %s",
               plat->sock_path, strerror(errno));
    close(fd);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  if (listen(fd, 1) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: listen() failed: %s",
               strerror(errno));
    close(fd);
    unlink(plat->sock_path);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->listen_fd = fd;
  miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: broadcast socket listening at '%s'.",
             plat->sock_path);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_configure_display(MiniAVScreenContext *ctx,
                                              const char *display_id,
                                              const MiniAVVideoInfo *format) {
  if (!ctx || !ctx->platform_ctx || !display_id || !format) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)ctx->platform_ctx;
  if (plat->is_streaming.load()) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  plat->configured_video_format = *format;
  miniav_strlcpy(plat->selected_display_id, display_id,
                 MINIAV_DEVICE_ID_MAX_LEN);
  if (plat->configured_video_format.frame_rate_numerator == 0 ||
      plat->configured_video_format.frame_rate_denominator == 0) {
    plat->configured_video_format.frame_rate_numerator = 60;
    plat->configured_video_format.frame_rate_denominator = 1;
  }
  // Broadcast/ReplayKit deliver NV12 (or BGRA in-app); report NV12 as the
  // nominal pixel format so consumers know the planar layout.
  plat->configured_video_format.pixel_format = MINIAV_PIXEL_FORMAT_NV12;

  if (strcmp(display_id, IOS_DISPLAY_ID_APP) == 0) {
    plat->tier = IOS_TIER_APP;
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "RK: configured in-app tier (app_screen).");
  } else if (strcmp(display_id, IOS_DISPLAY_ID_BROADCAST) == 0) {
    plat->tier = IOS_TIER_BROADCAST;
    char *group = ios_copy_app_group();
    if (!group) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: broadcast tier requires an App Group — call "
                 "MiniAV_Screen_SetIOSAppGroup() before configuring "
                 "'system_screen_broadcast'.");
      return MINIAV_ERROR_NOT_CONFIGURED;
    }
    if (plat->app_group_id) {
      miniav_free(plat->app_group_id);
    }
    plat->app_group_id = group; // owned

    MiniAVResultCode sock_res = ios_broadcast_setup_socket(plat);
    if (sock_res != MINIAV_SUCCESS) {
      return sock_res;
    }
    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "RK: configured broadcast tier (system_screen_broadcast).");
  } else {
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: unknown display id '%s'.",
               display_id);
    return MINIAV_ERROR_DEVICE_NOT_FOUND;
  }

  ctx->configured_video_format = plat->configured_video_format;
  ctx->is_configured = true;
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_configure_window(MiniAVScreenContext *ctx,
                                             const char *window_id,
                                             const MiniAVVideoInfo *format) {
  MINIAV_UNUSED(ctx);
  MINIAV_UNUSED(window_id);
  MINIAV_UNUSED(format);
  return MINIAV_ERROR_NOT_SUPPORTED; // ConfigureWindow → NOT_SUPPORTED (B.3a).
}

static MiniAVResultCode ios_configure_region(MiniAVScreenContext *ctx,
                                             const char *target_id, int x,
                                             int y, int width, int height,
                                             const MiniAVVideoInfo *format) {
  MINIAV_UNUSED(ctx);
  MINIAV_UNUSED(target_id);
  MINIAV_UNUSED(x);
  MINIAV_UNUSED(y);
  MINIAV_UNUSED(width);
  MINIAV_UNUSED(height);
  MINIAV_UNUSED(format);
  return MINIAV_ERROR_NOT_SUPPORTED; // ConfigureRegion → NOT_SUPPORTED.
}

// ---- In-app start ----
static MiniAVResultCode ios_start_app_tier(IOSScreenPlatformContext *plat) {
  __block MiniAVResultCode startResult = MINIAV_ERROR_SYSTEM_CALL_FAILED;

  @autoreleasepool {
    RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
    if (![recorder isAvailable]) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: RPScreenRecorder not available (e.g. AirPlay/mirroring "
                 "active, or unsupported device).");
      return MINIAV_ERROR_NOT_SUPPORTED;
    }

    if (!plat->coordinator) {
      plat->coordinator =
          [[MiniAVReplayKitCoordinator alloc] initWithPlat:plat];
    }

    // Mic only if audio was requested (mic is opt-in).
    BOOL wantMic = (plat->parent_ctx &&
                    plat->parent_ctx->capture_audio_requested)
                       ? YES
                       : NO;
    recorder.microphoneEnabled = wantMic;

    memset(&plat->ts_rebase, 0, sizeof(plat->ts_rebase));
    plat->lost_cb_fired.store(false);

    MiniAVReplayKitCoordinator *coordinator = plat->coordinator; // capture

    // Snapshot the generation the completion block must still match. A 30s
    // timeout below bumps start_generation, marking any late completion stale.
    // start_pending_count gates destroy: while nonzero, plat must not be freed
    // (an outstanding completion block still dereferences it). Bump it before
    // handing the block to ReplayKit; the block decrements it when it runs.
    plat->start_pending_count.fetch_add(1);
    const uint32_t startGen = plat->start_generation.load();

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    // startCaptureWithHandler: sample handler runs on a private queue. We hop
    // onto deliveryQueue so all buffer construction/callback is serialized and
    // drainable by stop/destroy.
    [recorder
        startCaptureWithHandler:^(CMSampleBufferRef _Nonnull sampleBuffer,
                                  RPSampleBufferType bufferType,
                                  NSError *_Nullable sampleError) {
          if (sampleError) {
            // A per-sample error can precede a stop; log at debug and drop.
            return;
          }
          if (!plat->is_streaming.load()) {
            return;
          }
          // Retain across the async hop; release inside.
          CFRetain(sampleBuffer);
          dispatch_async(plat->deliveryQueue, ^{
            [coordinator handleSample:sampleBuffer ofType:bufferType];
            CFRelease(sampleBuffer);
          });
        }
        completionHandler:^(NSError *_Nullable error) {
          // Abandoned while starting (the 30s timeout bumped the generation):
          // the caller has returned TIMEOUT and may have moved on. Do NOT
          // publish is_streaming/startResult — plat may be mid-destroy. If the
          // start actually SUCCEEDED, undo the orphan recording so it isn't
          // left running headless with nobody to stop it (Finding 2). Dropping
          // the pending-count last lets a subsequent destroy free plat once no
          // block remains.
          if (plat->start_generation.load() != startGen) {
            if (!error) {
              [[RPScreenRecorder sharedRecorder] stopCaptureWithHandler:nil];
            }
            plat->start_pending_count.fetch_sub(1);
            dispatch_semaphore_signal(sem);
            return;
          }
          if (error) {
            // Distinguish user-declined consent from other failures.
            if ([error.domain isEqualToString:RPRecordingErrorDomain] &&
                error.code == RPRecordingErrorUserDeclined) {
              miniav_log(MINIAV_LOG_LEVEL_ERROR,
                         "RK: user declined screen recording.");
              startResult = MINIAV_ERROR_PERMISSION_DENIED;
            } else {
              miniav_log(MINIAV_LOG_LEVEL_ERROR,
                         "RK: startCapture failed: %s",
                         [[error localizedDescription] UTF8String]);
              startResult = MINIAV_ERROR_SYSTEM_CALL_FAILED;
            }
          } else {
            plat->is_streaming.store(true);
            startResult = MINIAV_SUCCESS;
            miniav_log(MINIAV_LOG_LEVEL_INFO,
                       "RK: in-app capture started (mic:%s).",
                       wantMic ? "yes" : "no");
          }
          // The block has run to a terminal state and will not be re-invoked;
          // drop its pending-count contribution (releases the destroy gate once
          // no other outstanding start block remains).
          plat->start_pending_count.fetch_sub(1);
          dispatch_semaphore_signal(sem);
        }];

    // The completion handler runs on a private RK queue, so waiting here cannot
    // deadlock it. Bounded wait so a stuck consent dialog can't hang forever.
    if (dispatch_semaphore_wait(
            sem, dispatch_time(DISPATCH_TIME_NOW,
                               30 * NSEC_PER_SEC)) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "RK: startCapture timed out waiting for consent.");
      // Abandon the outstanding completion: bump the generation so a late
      // consent block sees itself stale (it will stop any recording it started
      // and NOT publish is_streaming). start_pending_count stays nonzero until
      // that block finally runs and decrements it, so destroy leaks plat rather
      // than freeing it under the block. sem itself survives — the block retains
      // it (OS_OBJECT_USE_OBJC).
      plat->start_generation.fetch_add(1);
      dispatch_release(sem);
      return MINIAV_ERROR_TIMEOUT;
    }
    dispatch_release(sem);
  }
  return startResult;
}

// ---- Broadcast start ----
static MiniAVResultCode ios_start_broadcast_tier(IOSScreenPlatformContext *plat) {
  if (plat->listen_fd < 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: broadcast socket not set up — Configure first.");
    return MINIAV_ERROR_NOT_CONFIGURED;
  }
  plat->receiver_should_stop.store(false);
  plat->lost_cb_fired.store(false);
  plat->receiver_exited = false;

  // Self-pipe for prompt, portable receiver wakeup on stop.
  if (plat->wake_pipe[0] < 0) {
    if (pipe(plat->wake_pipe) != 0) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR, "RK: pipe() failed: %s",
                 strerror(errno));
      return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    // Non-blocking so a full pipe never stalls the writer in stop.
    fcntl(plat->wake_pipe[0], F_SETFL,
          fcntl(plat->wake_pipe[0], F_GETFL, 0) | O_NONBLOCK);
    fcntl(plat->wake_pipe[1], F_SETFL,
          fcntl(plat->wake_pipe[1], F_GETFL, 0) | O_NONBLOCK);
  }
  plat->is_streaming.store(true);

  if (pthread_create(&plat->receiver_thread, NULL,
                     ios_broadcast_receiver_thread, plat) != 0) {
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "RK: failed to spawn broadcast receiver thread: %s",
               strerror(errno));
    plat->is_streaming.store(false);
    return MINIAV_ERROR_SYSTEM_CALL_FAILED;
  }
  plat->receiver_thread_started = true;
  miniav_log(MINIAV_LOG_LEVEL_INFO,
             "RK: broadcast receiver armed — waiting for extension. Start the "
             "broadcast from the picker / Control Center.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_start_capture(MiniAVScreenContext *ctx,
                                          MiniAVBufferCallback callback,
                                          void *user_data) {
  if (!ctx || !ctx->platform_ctx || !callback) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)ctx->platform_ctx;
  if (!ctx->is_configured) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  if (plat->is_streaming.load()) {
    return MINIAV_ERROR_ALREADY_RUNNING;
  }

  plat->app_callback_internal = callback;
  plat->app_callback_user_data_internal = user_data;

  MiniAVResultCode res;
  if (plat->tier == IOS_TIER_APP) {
    res = ios_start_app_tier(plat);
  } else if (plat->tier == IOS_TIER_BROADCAST) {
    res = ios_start_broadcast_tier(plat);
  } else {
    res = MINIAV_ERROR_NOT_CONFIGURED;
  }

  if (res != MINIAV_SUCCESS) {
    plat->app_callback_internal = NULL;
    plat->app_callback_user_data_internal = NULL;
    plat->is_streaming.store(false);
  }
  return res;
}

static MiniAVResultCode ios_stop_capture(MiniAVScreenContext *ctx) {
  if (!ctx || !ctx->platform_ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)ctx->platform_ctx;

  plat->is_streaming.store(false);
  plat->receiver_should_stop.store(true);

  // ---- Broadcast tier: break the receiver out of accept/read and join. ----
  if (plat->tier == IOS_TIER_BROADCAST) {
    ios_broadcast_wake_receiver(plat); // unblock poll() promptly
    if (plat->conn_fd >= 0) {
      shutdown(plat->conn_fd, SHUT_RDWR);
    }
    if (plat->receiver_thread_started) {
      if (ios_broadcast_join_receiver(plat, IOS_RK_BROADCAST_JOIN_TIMEOUT_MS) !=
          0) {
        // Leave the thread detached-and-leaked; report timeout so a later
        // Destroy also leaks the context. Do NOT close listen_fd/wake_pipe —
        // the leaked thread still references them.
        return MINIAV_ERROR_TIMEOUT;
      }
    }
    // Receiver has exited: safe to close listen/wake fds and the connection.
    if (plat->listen_fd >= 0) {
      close(plat->listen_fd);
      plat->listen_fd = -1;
    }
    if (plat->wake_pipe[0] >= 0) {
      close(plat->wake_pipe[0]);
      plat->wake_pipe[0] = -1;
    }
    if (plat->wake_pipe[1] >= 0) {
      close(plat->wake_pipe[1]);
      plat->wake_pipe[1] = -1;
    }
    ios_broadcast_close_connection(plat);
    if (plat->sock_path[0] != '\0') {
      unlink(plat->sock_path);
    }
  }

  @autoreleasepool {
    // ---- In-app tier: stop RPScreenRecorder. ----
    if (plat->tier == IOS_TIER_APP) {
      RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
      if ([recorder isRecording]) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [recorder stopCaptureWithHandler:^(NSError *error) {
          if (error) {
            miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: stopCapture error: %s",
                       [[error localizedDescription] UTF8String]);
          }
          dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(
                sem, dispatch_time(DISPATCH_TIME_NOW,
                                   IOS_RK_STOP_TIMEOUT_SEC * NSEC_PER_SEC)) !=
            0) {
          miniav_log(MINIAV_LOG_LEVEL_WARN, "RK: stopCapture timed out.");
        }
        dispatch_release(sem);
      }
    }

    // Drain in-flight delivery blocks (skip if called ON deliveryQueue to avoid
    // self-deadlock).
    if (plat->deliveryQueue &&
        dispatch_get_specific(kMiniAVIOSScreenQueueKey) == NULL) {
      dispatch_sync(plat->deliveryQueue, ^{
      });
    }
  }

  miniav_log(MINIAV_LOG_LEVEL_INFO, "RK: screen capture stopped.");
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_release_buffer(MiniAVScreenContext *ctx,
                                           void *internal_handle_ptr) {
  MINIAV_UNUSED(ctx);
  if (!internal_handle_ptr) {
    return MINIAV_SUCCESS;
  }
  MiniAVNativeBufferInternalPayload *payload =
      (MiniAVNativeBufferInternalPayload *)internal_handle_ptr;

  // The tier the payload belongs to is unambiguous from the platform context:
  // a context runs exactly ONE tier per configure (reconfigure is forbidden
  // while running, and stop drains delivery). Broadcast VIDEO_SCREEN payloads
  // carry an IOSBroadcastLease in native_singular_resource_ptr; in-app ones
  // carry a CoreVideo object. We key on tier, then confirm broadcast leases via
  // a leading magic so a cross-tier stray release can never punt a CV object
  // into the slot-return path.
  IOSScreenPlatformContext *plat =
      (ctx && ctx->platform_ctx) ? (IOSScreenPlatformContext *)ctx->platform_ctx
                                 : NULL;

  @autoreleasepool {
    IOSBroadcastLease *lease = NULL;
    if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN && plat &&
        plat->tier == IOS_TIER_BROADCAST &&
        payload->native_singular_resource_ptr) {
      IOSBroadcastLease *maybe =
          (IOSBroadcastLease *)payload->native_singular_resource_ptr;
      if (maybe->magic == IOS_BCAST_LEASE_MAGIC) {
        lease = maybe;
      }
    }

    if (lease) {
      IOSScreenPlatformContext *lplat = lease->plat;
      MiniAVBcastRingHeader *hdr = lplat->ring_header;
      // Release GPU texture views (id<MTLTexture>, retained by newTexture...).
      for (uint32_t i = 0; i < payload->num_planar_resources_to_release; ++i) {
        id<MTLTexture> t =
            (id<MTLTexture>)payload->native_planar_resource_ptrs[i];
        if (t) {
          [t release];
        }
        payload->native_planar_resource_ptrs[i] = NULL;
      }
      payload->num_planar_resources_to_release = 0;

      // Return the slot lease: LEASED -> FREE (producer can reuse). Guard the
      // ring header being torn down under us (it isn't while a lease ref is
      // held, but be defensive).
      if (hdr && lease->slot < hdr->slot_count) {
        __atomic_store_n(&hdr->slot_state[lease->slot],
                         (uint32_t)MINIAV_BCAST_SLOT_FREE, __ATOMIC_RELEASE);
      }
      miniav_free(lease);
      payload->native_singular_resource_ptr = NULL;

      // Drop the mapping ref this lease held (munmaps if this was the last).
      ios_mapping_ref_release(lplat);
    } else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN) {
      // In-app video buffer.
      if (payload->num_planar_resources_to_release > 0) {
        // Planar in-app GPU (NV12): CVMetalTextureRefs + a retained
        // CVPixelBuffer in the singular slot.
        for (uint32_t i = 0; i < payload->num_planar_resources_to_release;
             ++i) {
          if (payload->native_planar_resource_ptrs[i]) {
            CFRelease((CVMetalTextureRef)payload->native_planar_resource_ptrs[i]);
            payload->native_planar_resource_ptrs[i] = NULL;
          }
        }
        payload->num_planar_resources_to_release = 0;
        if (payload->native_singular_resource_ptr) {
          CVBufferRelease(
              (CVImageBufferRef)payload->native_singular_resource_ptr);
          payload->native_singular_resource_ptr = NULL;
        }
      } else if (payload->native_singular_resource_ptr) {
        MiniAVBufferContentType ct = MINIAV_BUFFER_CONTENT_TYPE_CPU;
        if (payload->parent_miniav_buffer_ptr) {
          ct = payload->parent_miniav_buffer_ptr->content_type;
        }
        if (ct == MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE) {
          // Packed-BGRA GPU: singular is a CVMetalTextureRef.
          CFRelease(
              (CVMetalTextureRef)payload->native_singular_resource_ptr);
        } else {
          // CPU: singular is a retained CVPixelBuffer.
          CVBufferRelease(
              (CVImageBufferRef)payload->native_singular_resource_ptr);
        }
        payload->native_singular_resource_ptr = NULL;
      }
    } else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_AUDIO) {
      if (payload->native_singular_resource_ptr) {
        miniav_free(payload->native_singular_resource_ptr);
        payload->native_singular_resource_ptr = NULL;
      }
    }
  }

  if (payload->parent_miniav_buffer_ptr) {
    miniav_free(payload->parent_miniav_buffer_ptr);
    payload->parent_miniav_buffer_ptr = NULL;
  }
  miniav_free(payload);
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_get_default_formats(const char *device_id,
                                                MiniAVVideoInfo *video_out,
                                                MiniAVAudioInfo *audio_out) {
  if (!device_id || !video_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  memset(video_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_out) {
    memset(audio_out, 0, sizeof(MiniAVAudioInfo));
  }
  // Dimensions are device-native and only known once frames arrive; report a
  // sensible default (1080p NV12 @60). The delivered buffers carry the real
  // dims.
  video_out->width = 1920;
  video_out->height = 1080;
  video_out->pixel_format = MINIAV_PIXEL_FORMAT_NV12;
  video_out->frame_rate_numerator = 60;
  video_out->frame_rate_denominator = 1;
  video_out->output_preference = MINIAV_OUTPUT_PREFERENCE_GPU;

  if (audio_out) {
    audio_out->format = MINIAV_AUDIO_FORMAT_F32;
    audio_out->channels = 2;
    audio_out->sample_rate = 48000;
    audio_out->num_frames = 1024;
  }
  return MINIAV_SUCCESS;
}

static MiniAVResultCode ios_get_configured_video_formats(
    MiniAVScreenContext *ctx, MiniAVVideoInfo *video_out,
    MiniAVAudioInfo *audio_out) {
  if (!ctx || !ctx->platform_ctx || !video_out) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  IOSScreenPlatformContext *plat =
      (IOSScreenPlatformContext *)ctx->platform_ctx;
  memset(video_out, 0, sizeof(MiniAVVideoInfo));
  if (audio_out) {
    memset(audio_out, 0, sizeof(MiniAVAudioInfo));
  }
  if (!ctx->is_configured) {
    return MINIAV_ERROR_NOT_INITIALIZED;
  }
  *video_out = plat->configured_video_format;
  if (audio_out && ctx->capture_audio_requested) {
    audio_out->format = MINIAV_AUDIO_FORMAT_F32;
    audio_out->channels = 2;
    audio_out->sample_rate = 48000;
    audio_out->num_frames = 1024;
  }
  return MINIAV_SUCCESS;
}

// ===========================================================================
// Ops table + selection
// ===========================================================================
const ScreenContextInternalOps g_screen_ops_ios_replaykit = {
    .init_platform = ios_init_platform,
    .destroy_platform = ios_destroy_platform,
    .enumerate_displays = ios_enumerate_displays,
    .enumerate_windows = ios_enumerate_windows,
    .configure_display = ios_configure_display,
    .configure_window = ios_configure_window,
    .configure_region = ios_configure_region,
    .start_capture = ios_start_capture,
    .stop_capture = ios_stop_capture,
    .release_buffer = ios_release_buffer,
    .get_default_formats = ios_get_default_formats,
    .get_configured_video_formats = ios_get_configured_video_formats,
};

MiniAVResultCode
miniav_screen_context_platform_init_ios_replaykit(MiniAVScreenContext *ctx) {
  if (!ctx) {
    return MINIAV_ERROR_INVALID_ARG;
  }
  ctx->ops = &g_screen_ops_ios_replaykit;
  miniav_log(MINIAV_LOG_LEVEL_DEBUG, "RK: iOS ReplayKit screen backend selected.");
  return MINIAV_SUCCESS;
}
