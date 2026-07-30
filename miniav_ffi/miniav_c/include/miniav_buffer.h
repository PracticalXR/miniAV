#ifndef MINIAV_BUFFER_H
#define MINIAV_BUFFER_H

#include "miniav_types.h" // Includes the format enums now
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Buffer Type ---
typedef enum {
  MINIAV_BUFFER_TYPE_UNKNOWN = 0,
  MINIAV_BUFFER_TYPE_VIDEO,
  MINIAV_BUFFER_TYPE_AUDIO
} MiniAVBufferType;

typedef enum {
  MINIAV_NATIVE_HANDLE_TYPE_UNKNOWN = 0,
  MINIAV_NATIVE_HANDLE_TYPE_VIDEO_CAMERA,
  MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN,
  MINIAV_NATIVE_HANDLE_TYPE_AUDIO
} MiniAVNativeHandleType;

// content_type is THE discriminator between the CPU and GPU buffer layouts.
// Do NOT probe planes[0].data_ptr to decide: on the GPU paths it is non-NULL
// (it carries the GPU handle) and planes[0].stride_bytes is 0.
typedef enum {
  MINIAV_BUFFER_CONTENT_TYPE_CPU, // CPU-accessible memory. Check
                                  // MiniAVBuffer.type to interpret data.video
                                  // or data.audio.
  // Video (Windows): planes[0].data_ptr is a *shared NT HANDLE* to a D3D11
  // texture (cast to HANDLE), planes[0].stride_bytes is 0, and there is no
  // CPU-readable pixel data.
  //
  // OWNERSHIP: miniav owns the handle and CloseHandle()s it inside
  // MiniAV_ReleaseBuffer. The app must NOT close it. The app must finish
  // importing it (OpenSharedResource1 / minigpu mgpuImportVideoFrame, both of
  // which copy into a consumer-private texture before returning) BEFORE
  // calling MiniAV_ReleaseBuffer; after release the handle is invalid.
  MINIAV_BUFFER_CONTENT_TYPE_GPU_D3D11_HANDLE,
  MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE, // Video:
                                                // data.video.native_gpu_texture_ptr
                                                // is an id<MTLTexture>
  MINIAV_BUFFER_CONTENT_TYPE_GPU_DMABUF_FD, // Video:
                                            // data.video.native_gpu_dmabuf_fd
                                            // is a DMA-BUF file descriptor
  MINIAV_BUFFER_CONTENT_TYPE_GPU_AHARDWAREBUFFER, // Android: planes[0].data_ptr
                                                  // is AHardwareBuffer*
} MiniAVBufferContentType;

typedef struct {
  // Per-plane data (works for both CPU and GPU)
  void *data_ptr;        // CPU: memory pointer, GPU: texture/handle pointer
  uint32_t width;        // Plane width
  uint32_t height;       // Plane height
  uint32_t stride_bytes; // Row stride in bytes
  uint32_t offset_bytes; // Offset within a shared resource (GPU DMA-BUF, D3D11
                         // subresource)
  uint32_t
      subresource_index; // GPU: D3D11 subresource, Vulkan image aspect, etc.
  // Linux DMA-BUF extended info (zero/−1 on other platforms)
  int      dmabuf_fd;            // Per-plane DMA-BUF file descriptor (-1 if n/a)
  uint64_t drm_format_modifier;  // DRM format modifier (DRM_FORMAT_MOD_LINEAR=0)
} MiniAVVideoPlane;

typedef struct {
  MiniAVBufferType type;
  MiniAVBufferContentType content_type; // CPU or GPU type
  int64_t timestamp_us;

  union {
    struct {
      MiniAVVideoInfo
          info; // Overall frame info (total width, height, pixel format)
      // Unified plane data (CPU or GPU)
      uint32_t num_planes; // 1 for BGRA, 2 for NV12, 3 for I420
      MiniAVVideoPlane
          planes[MINIAV_VIDEO_FORMAT_MAX_PLANES]; // Unified plane info
    } video;

    struct {
      uint32_t frame_count;
      MiniAVAudioInfo info;
      void *data;
    } audio;
  } data;

  size_t data_size_bytes;
  void *user_data;
  void *internal_handle;

  // Optional native fence for GPU synchronization (zero-init = no fence).
  // Consumers must wait on this fence before reading the GPU resource.
  //
  // STATUS (0.6.0): NOT IMPLEMENTED BY ANY BACKEND — this struct is always
  // left zero-initialised, so d3d11_fence is always NULL, sync_fd is 0/-1 and
  // metal_shared_event is always NULL. Do not treat a NULL fence as "the GPU
  // is idle".
  //
  // What the Windows backends do instead: before handing out the shared NT
  // handle they insert a D3D11_QUERY_EVENT, Flush(), and CPU busy-poll it for
  // at most ~16 ms. On timeout they log a rate-limited warning and hand the
  // frame over ANYWAY — i.e. under GPU contention a consumer can receive a
  // texture whose producer-side copy has not finished (torn/black frame).
  // Consumers that need a hard guarantee must do their own synchronisation.
  // See NATIVE_AUDIT.md "P2 — Real fences instead of the poll".
  struct {
    int   sync_fd;             // Linux/Android: sync_file fd (-1 if none)
    void *d3d11_fence;         // Windows: ID3D11Fence* — ALWAYS NULL today
    void *metal_shared_event;  // macOS/iOS: id<MTLSharedEvent> bridged (NULL if none)
    uint64_t metal_fence_value;// macOS/iOS: signaled value on metal_shared_event
  } native_fence;
} MiniAVBuffer;

typedef struct MiniAVNativeBufferInternalPayload {
  MiniAVNativeHandleType handle_type;
  void *context_owner;

  // For single resources that need cleanup (CVPixelBuffer, HANDLE, etc.)
  void *native_singular_resource_ptr;

  // For multi-plane resources that need individual cleanup (multiple
  // CVMetalTextureRef)
  void *native_planar_resource_ptrs[MINIAV_VIDEO_FORMAT_MAX_PLANES];
  uint32_t num_planar_resources_to_release;

  MiniAVBuffer *parent_miniav_buffer_ptr;
} MiniAVNativeBufferInternalPayload;

#ifdef __cplusplus
}
#endif

#endif // MINIAV_BUFFER_H