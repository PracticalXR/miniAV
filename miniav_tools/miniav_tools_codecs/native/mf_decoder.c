/* mf_decoder.c — standalone Media Foundation H.264/HEVC → NV12 D3D11 decode
 * session for the miniav_tools_ffmpeg shim (ABI v16+).
 *
 * This is NOT FFmpeg's d3d11va path. It drives a raw hardware decoder MFT
 * (IMFTransform) directly, feeding it EncodedPackets and draining decoded
 * frames as D3D11 NV12 textures. Milestone 1 uses it as:
 *
 *   packet → mfdec_send → (async MFT event pump) → mfdec_receive
 *          → D3D11 NV12 pool slice → CopySubresourceRegion into a fresh
 *            SHARED_NTHANDLE texture (the "unavoidable" GPU-resident copy;
 *            pool slices are recycled) → CreateSharedHandle → out
 *   → mfdec_map_nv12 (staging copy → Map → CPU NV12) for the player's
 *     existing YUV path, until the GPU import/present path lands (Milestone 2).
 *
 * The hardware H.264/HEVC decoder MFT is ASYNCHRONOUS (MFTEnumEx HARDWARE),
 * so we run the IMFMediaEventGenerator model: METransformNeedInput feeds one
 * queued input sample; METransformHaveOutput drains one output sample. A
 * software-only fallback path is intentionally NOT taken here — without a HW
 * MFT there is no D3D11 texture output, so mfdec_has_hardware() lets the Dart
 * backend decline (and the negotiator falls back to the FFmpeg SW decoder).
 *
 * COM: C-style vtable calls (obj->lpVtbl->Method(obj, ...)). GUIDs come from
 * mfuuid.lib / dxguid.lib — we deliberately do NOT include <initguid.h> here
 * (shim.c owns the DirectX GUID definitions in its TU; duplicating them would
 * be a link error).
 */

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <mferror.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MIO_API __declspec(dllexport)

#define MFDEC_CODEC_H264 0
#define MFDEC_CODEC_HEVC 1

/* Public frame descriptor returned to Dart. Keep in lock-step with the Dart
 * struct layout in mf_d3d11_decoder.dart. */
typedef struct MiniAVMfDecFrame {
  intptr_t out_shared_handle; /* NT HANDLE for cross-device present (M2)     */
  intptr_t out_texture_ptr;   /* ID3D11Texture2D* (same-device Dawn import)  */
  int32_t width;
  int32_t height;
  int32_t pixel_format;       /* 0 = NV12                                    */
  int32_t _pad;
  int64_t pts_us;
} MiniAVMfDecFrame;

/* Simple FIFO of pending input IMFSamples awaiting a NeedInput credit. */
typedef struct InSampleNode {
  IMFSample *sample;
  struct InSampleNode *next;
} InSampleNode;

/* Simple FIFO of decoded output frames awaiting mfdec_receive(). */
typedef struct OutFrameNode {
  ID3D11Texture2D *texture; /* shareable NV12 (owned until release_frame)   */
  HANDLE shared_handle;     /* NT handle (owned until release_frame)        */
  int width, height;
  int64_t pts_us;
  struct OutFrameNode *next;
} OutFrameNode;

typedef struct MfDecSession {
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  int owns_device; /* did we create the device (vs. caller-supplied)?       */
  IMFDXGIDeviceManager *dxgi_mgr;
  UINT reset_token;
  IMFTransform *mft;
  IMFMediaEventGenerator *event_gen;
  int codec;
  int is_async;
  int output_configured;
  int width, height;
  int streaming; /* have we sent NOTIFY_BEGIN_STREAMING/START_OF_STREAM      */
  int draining;  /* END_OF_STREAM/DRAIN issued                              */
  int64_t pending_input_pts; /* pts of the next sample to feed (100ns)      */

  InSampleNode *in_head, *in_tail;
  OutFrameNode *out_head, *out_tail;

  /* Reusable staging texture for CPU NV12 map. */
  ID3D11Texture2D *staging;
  int staging_w, staging_h;
} MfDecSession;

/* -------------------------------------------------------------------------- */
/* small helpers                                                              */
/* -------------------------------------------------------------------------- */

/* Env-gated stderr trace (MFDEC_DEBUG=1) — the playbook's MFAAC_DEBUG pattern.
 * Used to localise native faults (e.g. inside vendor MFT activation) that a
 * debugger can't easily reach through the Dart FFI boundary. */
static int mfdec_dbg(void) {
  static int v = -1;
  if (v < 0) {
    const char *e = getenv("MFDEC_DEBUG");
    v = (e && *e == '1') ? 1 : 0;
  }
  return v;
}
#define MFDEC_TRACE(...)                                                       \
  do {                                                                         \
    if (mfdec_dbg()) {                                                         \
      fprintf(stderr, __VA_ARGS__);                                            \
      fflush(stderr);                                                          \
    }                                                                          \
  } while (0)

static const GUID *mfdec_input_subtype(int codec) {
  return (codec == MFDEC_CODEC_HEVC) ? &MFVideoFormat_HEVC : &MFVideoFormat_H264;
}

static void in_push(MfDecSession *s, IMFSample *sample) {
  InSampleNode *n = (InSampleNode *)calloc(1, sizeof(InSampleNode));
  if (!n) return;
  n->sample = sample; /* takes ownership */
  if (s->in_tail) s->in_tail->next = n; else s->in_head = n;
  s->in_tail = n;
}

static IMFSample *in_pop(MfDecSession *s) {
  InSampleNode *n = s->in_head;
  if (!n) return NULL;
  s->in_head = n->next;
  if (!s->in_head) s->in_tail = NULL;
  IMFSample *sample = n->sample;
  free(n);
  return sample;
}

static void out_push(MfDecSession *s, ID3D11Texture2D *tex, HANDLE h,
                     int w, int hgt, int64_t pts_us) {
  OutFrameNode *n = (OutFrameNode *)calloc(1, sizeof(OutFrameNode));
  if (!n) return;
  n->texture = tex;
  n->shared_handle = h;
  n->width = w;
  n->height = hgt;
  n->pts_us = pts_us;
  if (s->out_tail) s->out_tail->next = n; else s->out_head = n;
  s->out_tail = n;
}

static int out_pop(MfDecSession *s, MiniAVMfDecFrame *out) {
  OutFrameNode *n = s->out_head;
  if (!n) return 0;
  s->out_head = n->next;
  if (!s->out_head) s->out_tail = NULL;
  out->out_texture_ptr = (intptr_t)n->texture;
  out->out_shared_handle = (intptr_t)n->shared_handle;
  out->width = n->width;
  out->height = n->height;
  out->pixel_format = 0; /* NV12 */
  out->pts_us = n->pts_us;
  free(n);
  return 1;
}

/* -------------------------------------------------------------------------- */
/* device + MFT setup                                                         */
/* -------------------------------------------------------------------------- */

static ID3D11Device *mfdec_create_device(ID3D11DeviceContext **out_ctx) {
  static const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
  ID3D11Device *dev = NULL;
  ID3D11DeviceContext *ctx = NULL;
  HRESULT hr = D3D11CreateDevice(
      NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
      levels, (UINT)(sizeof(levels) / sizeof(levels[0])), D3D11_SDK_VERSION,
      &dev, NULL, &ctx);
  if (FAILED(hr)) {
    fprintf(stderr, "[mfdec] D3D11CreateDevice failed hr=0x%08lX\n",
            (unsigned long)hr);
    return NULL;
  }
  /* MFTs may call the device/context from their own threads. */
  ID3D10Multithread *mt = NULL;
  if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_ID3D10Multithread,
                                            (void **)&mt)) && mt) {
    ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
    ID3D10Multithread_Release(mt);
  }
  *out_ctx = ctx;
  return dev;
}

/* Enumerate a decoder MFT for `codec`. If `hardware_only`, restrict to HW
 * async MFTs; returns an activated IMFTransform* (caller Releases) or NULL. */
static IMFTransform *mfdec_enum_activate(int codec, int hardware_only) {
  MFT_REGISTER_TYPE_INFO in_info;
  in_info.guidMajorType = MFMediaType_Video;
  in_info.guidSubtype = *mfdec_input_subtype(codec);
  MFT_REGISTER_TYPE_INFO out_info;
  out_info.guidMajorType = MFMediaType_Video;
  out_info.guidSubtype = MFVideoFormat_NV12;

  UINT32 flags = MFT_ENUM_FLAG_SORTANDFILTER;
  flags |= hardware_only ? MFT_ENUM_FLAG_HARDWARE
                         : (MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
                            MFT_ENUM_FLAG_LOCALMFT);

  IMFActivate **activates = NULL;
  UINT32 count = 0;
  HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, flags, &in_info, &out_info,
                         &activates, &count);
  if (FAILED(hr) || count == 0) {
    if (activates) CoTaskMemFree(activates);
    return NULL;
  }
  MFDEC_TRACE("[mfdec] enum codec=%d hw_only=%d -> %u MFTs\n", codec,
              hardware_only, (unsigned)count);
  IMFTransform *mft = NULL;
  for (UINT32 i = 0; i < count; i++) {
    if (!mft) {
      MFDEC_TRACE("[mfdec] activating MFT %u...\n", (unsigned)i);
      HRESULT ahr = IMFActivate_ActivateObject(activates[i], &IID_IMFTransform,
                                               (void **)&mft);
      MFDEC_TRACE("[mfdec] activate %u hr=0x%08lX\n", (unsigned)i,
                  (unsigned long)ahr);
      if (FAILED(ahr)) mft = NULL;
    }
    IMFActivate_Release(activates[i]);
  }
  CoTaskMemFree(activates);
  return mft;
}

static int mfdec_configure_input(MfDecSession *s) {
  IMFMediaType *in_type = NULL;
  if (FAILED(MFCreateMediaType(&in_type))) return -1;
  IMFMediaType_SetGUID(in_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
  IMFMediaType_SetGUID(in_type, &MF_MT_SUBTYPE, mfdec_input_subtype(s->codec));
  IMFMediaType_SetUINT32(in_type, &MF_MT_INTERLACE_MODE,
                         MFVideoInterlace_MixedInterlaceOrProgressive);
  /* Coded-dims hint from the caller. The H.264 decoder MFT doesn't need it,
   * but the HEVC decoder MFT REQUIRES a frame size on the input type: without
   * it, it can't propose an output type and then rejects every ProcessInput
   * with MF_E_TRANSFORM_TYPE_NOT_SET (it never gets to parse the SPS). */
  if (s->width > 0 && s->height > 0) {
    IMFMediaType_SetUINT64(in_type, &MF_MT_FRAME_SIZE,
                           (((UINT64)(UINT32)s->width) << 32) |
                               (UINT32)s->height);
  }
  HRESULT hr = IMFTransform_SetInputType(s->mft, 0, in_type, 0);
  IMFMediaType_Release(in_type);
  if (FAILED(hr)) {
    fprintf(stderr, "[mfdec] SetInputType failed hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
  }
  return 0;
}

/* Choose the NV12 output type after the MFT has parsed enough bitstream to
 * know the frame size (called on stream-change / lazily). */
static int mfdec_configure_output(MfDecSession *s) {
  HRESULT hr = S_OK;
  for (DWORD i = 0;; i++) {
    IMFMediaType *ot = NULL;
    hr = IMFTransform_GetOutputAvailableType(s->mft, 0, i, &ot);
    if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) {
      if (ot) IMFMediaType_Release(ot);
      break;
    }
    GUID sub = {0};
    IMFMediaType_GetGUID(ot, &MF_MT_SUBTYPE, &sub);
    if (IsEqualGUID(&sub, &MFVideoFormat_NV12)) {
      hr = IMFTransform_SetOutputType(s->mft, 0, ot, 0);
      if (SUCCEEDED(hr)) {
        UINT64 fs = 0;
        if (SUCCEEDED(IMFMediaType_GetUINT64(ot, &MF_MT_FRAME_SIZE, &fs))) {
          s->width = (int)(fs >> 32);
          s->height = (int)(fs & 0xFFFFFFFF);
        }
        s->output_configured = 1;
      }
      IMFMediaType_Release(ot);
      return SUCCEEDED(hr) ? 0 : -1;
    }
    IMFMediaType_Release(ot);
  }
  return -1;
}

/* -------------------------------------------------------------------------- */
/* output extraction: MFT sample → shareable NV12 texture + NT handle         */
/* -------------------------------------------------------------------------- */

static int mfdec_extract_frame(MfDecSession *s, IMFSample *sample,
                               int64_t pts_us) {
  IMFMediaBuffer *mbuf = NULL;
  if (FAILED(IMFSample_GetBufferByIndex(sample, 0, &mbuf)) || !mbuf) return -1;

  IMFDXGIBuffer *dxgi = NULL;
  HRESULT hr =
      IMFMediaBuffer_QueryInterface(mbuf, &IID_IMFDXGIBuffer, (void **)&dxgi);
  if (FAILED(hr) || !dxgi) {
    IMFMediaBuffer_Release(mbuf);
    fprintf(stderr, "[mfdec] extract: software sample (no IMFDXGIBuffer, "
                    "hr=0x%08lX) — DXVA not engaged\n", (unsigned long)hr);
    return -1; /* not a D3D-backed sample — HW MFT expected */
  }

  ID3D11Texture2D *pool_tex = NULL;
  UINT subresource = 0;
  hr = IMFDXGIBuffer_GetResource(dxgi, &IID_ID3D11Texture2D,
                                 (void **)&pool_tex);
  if (SUCCEEDED(hr)) IMFDXGIBuffer_GetSubresourceIndex(dxgi, &subresource);
  IMFDXGIBuffer_Release(dxgi);
  IMFMediaBuffer_Release(mbuf);
  if (FAILED(hr) || !pool_tex) return -1;

  D3D11_TEXTURE2D_DESC desc;
  ID3D11Texture2D_GetDesc(pool_tex, &desc);

  /* Fresh single-slice shareable NV12 texture: pool slices are recycled, so
   * we must copy out. NTHANDLE + KEYEDMUTEX for cross-device present in M2. */
  D3D11_TEXTURE2D_DESC sd = desc;
  sd.ArraySize = 1;
  sd.MipLevels = 1;
  sd.Usage = D3D11_USAGE_DEFAULT;
  sd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  sd.CPUAccessFlags = 0;
  /* Plain SHARED | SHARED_NTHANDLE (NO keyed mutex) — matches the proven
   * miniav camera → minigpu/Dawn import path. Dawn's importVideoFrame opens
   * this without a keyed-mutex acquire, so a keyed-mutex texture would be read
   * before this copy is visible → black frames. Cross-device visibility is
   * instead guaranteed by the GPU fence-wait below before CreateSharedHandle. */
  sd.MiscFlags =
      D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

  ID3D11Texture2D *shareable = NULL;
  hr = ID3D11Device_CreateTexture2D(s->device, &sd, NULL, &shareable);
  if (FAILED(hr) || !shareable) {
    ID3D11Texture2D_Release(pool_tex);
    fprintf(stderr, "[mfdec] CreateTexture2D(shareable) hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
  }

  ID3D11DeviceContext_CopySubresourceRegion(
      s->context, (ID3D11Resource *)shareable, 0, 0, 0, 0,
      (ID3D11Resource *)pool_tex, subresource, NULL);

  /* Fence-wait so the copy is COMPLETE (not merely submitted) before the NT
   * handle is opened on the consumer device — otherwise the cross-device read
   * races the copy and yields stale/black data. */
  {
    D3D11_QUERY_DESC qd = {D3D11_QUERY_EVENT, 0};
    ID3D11Query *fence = NULL;
    if (SUCCEEDED(ID3D11Device_CreateQuery(s->device, &qd, &fence)) && fence) {
      ID3D11DeviceContext_End(s->context, (ID3D11Asynchronous *)fence);
      ID3D11DeviceContext_Flush(s->context);
      for (ULONGLONG t0 = GetTickCount64();;) {
        HRESULT gd = ID3D11DeviceContext_GetData(
            s->context, (ID3D11Asynchronous *)fence, NULL, 0, 0);
        if (gd == S_OK || GetTickCount64() - t0 > 100) break;
        YieldProcessor();
      }
      ID3D11Query_Release(fence);
    } else {
      ID3D11DeviceContext_Flush(s->context);
    }
  }
  ID3D11Texture2D_Release(pool_tex);

  HANDLE shared_handle = NULL;
  IDXGIResource1 *res1 = NULL;
  if (SUCCEEDED(ID3D11Texture2D_QueryInterface(
          shareable, &IID_IDXGIResource1, (void **)&res1)) && res1) {
    IDXGIResource1_CreateSharedHandle(res1, NULL, DXGI_SHARED_RESOURCE_READ,
                                      NULL, &shared_handle);
    IDXGIResource1_Release(res1);
  }

  int w = s->width > 0 ? s->width : (int)desc.Width;
  int h = s->height > 0 ? s->height : (int)desc.Height;
  out_push(s, shareable, shared_handle, w, h, pts_us);
  return 0;
}

/* -------------------------------------------------------------------------- */
/* async MFT event pump                                                       */
/* -------------------------------------------------------------------------- */

/* Feed one queued input sample in response to a NeedInput credit. */
static void mfdec_feed_one(MfDecSession *s) {
  IMFSample *sample = in_pop(s);
  if (!sample) return;
  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
  IMFSample_Release(sample);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) {
    fprintf(stderr, "[mfdec] ProcessInput hr=0x%08lX\n", (unsigned long)hr);
  }
}

/* Send the streaming notifications once. For sync MFTs whose output type
 * could not be set at create (the decoder must parse an SPS first — HEVC),
 * this is DEFERRED until the lazy output negotiation succeeds: the Microsoft
 * HEVC decoder MFT (HEVC Video Extensions) hard-crashes (access violation)
 * inside ProcessMessage(NOTIFY_BEGIN_STREAMING) when its output type is
 * still unset, while the H.264 decoder tolerates it. Sync MFTs must not
 * require these notifications before ProcessInput (MF contract), so the
 * deferral is safe; async HW MFTs get them at create as before (their event
 * pump depends on it, and they renegotiate output via STREAM_CHANGE by
 * design). */
static void mfdec_notify_streaming(MfDecSession *s) {
  if (s->streaming) return;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  s->streaming = 1;
  MFDEC_TRACE("[mfdec] streaming notifications sent\n");
}

/* Drain one output sample in response to a HaveOutput event. The output type
 * is negotiated lazily on the first MF_E_TRANSFORM_STREAM_CHANGE (the decoder
 * signals it once it has parsed the SPS), not pre-set. Handles the
 * PROVIDES_SAMPLES (D3D) allocation via pSample = NULL. */
static void mfdec_drain_one(MfDecSession *s) {
  MFT_OUTPUT_DATA_BUFFER odb;
  memset(&odb, 0, sizeof(odb));
  odb.dwStreamID = 0;
  odb.pSample = NULL; /* HW MFT provides its own D3D sample */
  DWORD status = 0;
  HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &odb, &status);
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    s->output_configured = 0;
    int cfg = mfdec_configure_output(s);
    MFDEC_TRACE("[mfdec] drain: STREAM_CHANGE, configure_output=%d\n", cfg);
    if (cfg == 0) mfdec_notify_streaming(s);
    return;
  }
  if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return;
  }
  if (FAILED(hr) || !odb.pSample) {
    MFDEC_TRACE("[mfdec] drain: ProcessOutput hr=0x%08lX sample=%p\n",
                (unsigned long)hr, (void *)odb.pSample);
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return;
  }
  LONGLONG ts100 = 0;
  int64_t pts_us = 0;
  if (SUCCEEDED(IMFSample_GetSampleTime(odb.pSample, &ts100))) {
    pts_us = (int64_t)(ts100 / 10);
  }
  mfdec_extract_frame(s, odb.pSample, pts_us);
  IMFSample_Release(odb.pSample);
  if (odb.pEvents) IMFCollection_Release(odb.pEvents);
}

/* -------------------------------------------------------------------------- */
/* public ABI                                                                 */
/* -------------------------------------------------------------------------- */

/* 1 if a hardware decoder MFT exists for `codec` (H264=0 / HEVC=1). Cheap:
 * enumerate + count, no activation. Used by the Dart probe so the negotiator
 * only prefers MF when HW decode (→ D3D11 texture) is actually available. */
MIO_API int miniav_shim_mfdec_has_hardware(int codec) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  int started_mf = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
  MFT_REGISTER_TYPE_INFO in_info;
  in_info.guidMajorType = MFMediaType_Video;
  in_info.guidSubtype = *mfdec_input_subtype(codec);
  MFT_REGISTER_TYPE_INFO out_info;
  out_info.guidMajorType = MFMediaType_Video;
  out_info.guidSubtype = MFVideoFormat_NV12;
  IMFActivate **activates = NULL;
  UINT32 count = 0;
  /* Any decoder MFT: a vendor hardware (async) MFT if present, else the
   * Microsoft H.264/HEVC decoder MFT, which does DXVA2 GPU decode and outputs
   * D3D11 NV12 textures once a D3D manager is set. Both give us zero-copy. */
  HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_VIDEO_DECODER,
      MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
          MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
      &in_info, &out_info, &activates, &count);
  if (SUCCEEDED(hr) && activates) {
    for (UINT32 i = 0; i < count; i++) IMFActivate_Release(activates[i]);
    CoTaskMemFree(activates);
  }
  if (started_mf) MFShutdown();
  if (co == S_OK || co == S_FALSE) { /* leave COM initialised on this thread */ }
  return (SUCCEEDED(hr) && count > 0) ? 1 : 0;
}

MIO_API void *miniav_shim_mfdec_create(void *d3d11_device, int codec,
                                       const uint8_t *extradata,
                                       int extradata_size, int width,
                                       int height) {
  (void)extradata;
  (void)extradata_size; /* M1: rely on in-band SPS/PPS (Annex-B) */

  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (co == RPC_E_CHANGED_MODE) {
    fprintf(stderr, "[mfdec] thread is STA — MF decode needs MTA (worker "
                    "thread). create failed.\n");
    return NULL;
  }
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    fprintf(stderr, "[mfdec] MFStartup failed\n");
    return NULL;
  }

  MFDEC_TRACE("[mfdec] create codec=%d %dx%d: startup ok\n", codec, width,
              height);
  MfDecSession *s = (MfDecSession *)calloc(1, sizeof(MfDecSession));
  if (!s) { MFShutdown(); return NULL; }
  s->codec = codec;
  /* Coded-dims hint (0 = unknown); overwritten by the negotiated output type
   * once the decoder has parsed the bitstream. */
  s->width = width;
  s->height = height;

  if (d3d11_device) {
    s->device = (ID3D11Device *)d3d11_device;
    ID3D11Device_AddRef(s->device);
    ID3D11Device_GetImmediateContext(s->device, &s->context);
    s->owns_device = 0;
    ID3D10Multithread *mt = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(s->device, &IID_ID3D10Multithread,
                                              (void **)&mt)) && mt) {
      ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
      ID3D10Multithread_Release(mt);
    }
  } else {
    s->device = mfdec_create_device(&s->context);
    s->owns_device = 1;
  }
  if (!s->device) goto fail;
  MFDEC_TRACE("[mfdec] create: device ok\n");

  if (FAILED(MFCreateDXGIDeviceManager(&s->reset_token, &s->dxgi_mgr)))
    goto fail;
  if (FAILED(IMFDXGIDeviceManager_ResetDevice(
          s->dxgi_mgr, (IUnknown *)s->device, s->reset_token)))
    goto fail;
  MFDEC_TRACE("[mfdec] create: dxgi manager ok\n");

  /* Prefer a vendor hardware (async) decoder MFT; fall back to the Microsoft
   * decoder MFT (sync), which does DXVA2 GPU decode → D3D11 NV12 once the D3D
   * manager is set below. */
  s->mft = mfdec_enum_activate(codec, /*hardware_only=*/1);
  if (!s->mft) s->mft = mfdec_enum_activate(codec, /*hardware_only=*/0);
  if (!s->mft) {
    fprintf(stderr, "[mfdec] no decoder MFT for codec %d\n", codec);
    goto fail;
  }

  /* Unlock async if needed. */
  {
    IMFAttributes *attrs = NULL;
    if (SUCCEEDED(IMFTransform_GetAttributes(s->mft, &attrs)) && attrs) {
      UINT32 is_async = 0;
      IMFAttributes_GetUINT32(attrs, &MF_TRANSFORM_ASYNC, &is_async);
      s->is_async = is_async ? 1 : 0;
      if (s->is_async) {
        IMFAttributes_SetUINT32(attrs, &MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
      }
      /* Ask the MFT to allocate its own D3D output samples. */
      IMFAttributes_Release(attrs);
    }
  }

  /* Bind D3D BEFORE setting media types so the MFT allocates a D3D pool. */
  MFDEC_TRACE("[mfdec] create: mft ok (async=%d), binding d3d manager...\n",
              s->is_async);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_SET_D3D_MANAGER,
                              (ULONG_PTR)s->dxgi_mgr);
  MFDEC_TRACE("[mfdec] create: d3d manager bound, setting input type...\n");

  if (mfdec_configure_input(s) != 0) goto fail;
  MFDEC_TRACE("[mfdec] create: input type ok\n");

  if (s->is_async) {
    if (FAILED(IMFTransform_QueryInterface(
            s->mft, &IID_IMFMediaEventGenerator, (void **)&s->event_gen)))
      goto fail;
  }

  /* Sync (Microsoft) decoders want the output type set up front (right after
   * the input type); async HW MFTs renegotiate via STREAM_CHANGE, so a failure
   * here is fine. */
  mfdec_configure_output(s);

  MFDEC_TRACE("[mfdec] create: output type %s\n",
              s->output_configured ? "ok" : "deferred");
  /* See mfdec_notify_streaming: a sync MFT with a still-unset output type
   * (HEVC before its SPS) must not receive the streaming notifications yet —
   * they are sent when the lazy output negotiation completes. */
  if (s->is_async || s->output_configured) {
    mfdec_notify_streaming(s);
  } else {
    MFDEC_TRACE("[mfdec] create: streaming notifications deferred\n");
  }
  MFDEC_TRACE("[mfdec] create: session ready\n");
  return s;

fail:
  /* best-effort cleanup */
  if (s) {
    if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
    if (s->mft) IMFTransform_Release(s->mft);
    if (s->dxgi_mgr) IMFDXGIDeviceManager_Release(s->dxgi_mgr);
    if (s->context) ID3D11DeviceContext_Release(s->context);
    if (s->device) ID3D11Device_Release(s->device);
    free(s);
  }
  MFShutdown();
  return NULL;
}

MIO_API int miniav_shim_mfdec_send(void *session, const uint8_t *data, int size,
                                   int64_t pts_us, int is_keyframe) {
  MfDecSession *s = (MfDecSession *)session;
  if (!s || !data || size <= 0) return -1;

  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer((DWORD)size, &buf))) return -1;
  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  memcpy(dst, data, (size_t)size);
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, (DWORD)size);

  IMFSample *sample = NULL;
  if (FAILED(MFCreateSample(&sample))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(sample, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(sample, (LONGLONG)pts_us * 10);
  IMFSample_SetSampleDuration(sample, 0);
  if (is_keyframe) IMFSample_SetUINT32(sample, &MFSampleExtension_CleanPoint, 1);

  if (s->is_async) {
    in_push(s, sample); /* ownership transferred; fed on NeedInput in receive */
  } else {
    /* Sync MFT: it returns MF_E_NOTACCEPTING while it has output pending —
     * drain it out (queued for receive) and retry so no input is dropped. */
    HRESULT hr = MF_E_NOTACCEPTING;
    for (int guard = 0; guard < 64; guard++) {
      hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
      if (hr != MF_E_NOTACCEPTING) break;
      mfdec_drain_one(s);
    }
    IMFSample_Release(sample);
    if (hr != S_OK) {
      MFDEC_TRACE("[mfdec] send: ProcessInput hr=0x%08lX\n",
                  (unsigned long)hr);
    }
    if (FAILED(hr) && hr != MF_E_NOTACCEPTING) return -1;
  }
  return 0;
}

/* Drive the async MFT event loop until either one output frame is ready
 * (returns 1) or the MFT asks for input we don't have queued (returns 0 —
 * the caller should send more packets, then call receive again). Can't
 * deadlock: an async MFT always eventually emits NeedInput or HaveOutput. */
MIO_API int miniav_shim_mfdec_receive(void *session, MiniAVMfDecFrame *out) {
  MfDecSession *s = (MfDecSession *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  if (out_pop(s, out)) return 1;

  if (!s->is_async) {
    mfdec_drain_one(s);
    return out_pop(s, out) ? 1 : 0;
  }

  for (;;) {
    IMFMediaEvent *ev = NULL;
    HRESULT hr = IMFMediaEventGenerator_GetEvent(s->event_gen, 0, &ev);
    if (FAILED(hr) || !ev) return 0;
    MediaEventType met = 0;
    IMFMediaEvent_GetType(ev, &met);
    IMFMediaEvent_Release(ev);
    if (met == METransformNeedInput) {
      if (s->in_head) {
        mfdec_feed_one(s);
        continue;
      }
      return 0; /* MFT wants input we don't have — caller sends more */
    } else if (met == METransformHaveOutput) {
      mfdec_drain_one(s);
      if (out_pop(s, out)) return 1;
      /* stream-change or empty output — keep pumping */
    } else if (met == METransformDrainComplete) {
      s->draining = 0;
      return out_pop(s, out) ? 1 : 0;
    }
  }
}

/* Copy a shareable NV12 texture to CPU, tightly packed (Y plane then
 * interleaved UV). Returns bytes written, <0 on error. */
MIO_API int miniav_shim_mfdec_map_nv12(void *session, intptr_t texture_ptr,
                                       uint8_t *dst, int dst_cap) {
  MfDecSession *s = (MfDecSession *)session;
  ID3D11Texture2D *tex = (ID3D11Texture2D *)texture_ptr;
  if (!s || !tex || !dst) return -1;

  D3D11_TEXTURE2D_DESC desc;
  ID3D11Texture2D_GetDesc(tex, &desc);
  int w = (int)desc.Width, h = (int)desc.Height;
  int needed = w * h + (w * (h / 2)); /* NV12: Y + interleaved UV */
  if (dst_cap < needed) return -2;

  if (!s->staging || s->staging_w != w || s->staging_h != h) {
    if (s->staging) { ID3D11Texture2D_Release(s->staging); s->staging = NULL; }
    D3D11_TEXTURE2D_DESC sd = desc;
    sd.ArraySize = 1;
    sd.MipLevels = 1;
    sd.BindFlags = 0;
    sd.MiscFlags = 0;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(ID3D11Device_CreateTexture2D(s->device, &sd, NULL,
                                            &s->staging)))
      return -1;
    s->staging_w = w;
    s->staging_h = h;
  }

  ID3D11DeviceContext_CopyResource(s->context, (ID3D11Resource *)s->staging,
                                   (ID3D11Resource *)tex);

  D3D11_MAPPED_SUBRESOURCE map;
  if (FAILED(ID3D11DeviceContext_Map(s->context, (ID3D11Resource *)s->staging,
                                     0, D3D11_MAP_READ, 0, &map)))
    return -1;

  const uint8_t *src = (const uint8_t *)map.pData;
  int pitch = (int)map.RowPitch;
  /* Y plane */
  uint8_t *o = dst;
  for (int y = 0; y < h; y++) {
    memcpy(o, src + (size_t)y * pitch, (size_t)w);
    o += w;
  }
  /* UV plane follows the Y plane in the same texture, at row offset `h`
   * (NV12 in a single texture: UV rows start after Y rows). */
  const uint8_t *uv = src + (size_t)h * pitch;
  for (int y = 0; y < h / 2; y++) {
    memcpy(o, uv + (size_t)y * pitch, (size_t)w);
    o += w;
  }
  ID3D11DeviceContext_Unmap(s->context, (ID3D11Resource *)s->staging, 0);
  return needed;
}

MIO_API int miniav_shim_mfdec_drain(void *session) {
  MfDecSession *s = (MfDecSession *)session;
  if (!s) return -1;
  if (s->is_async) {
    /* Feed any queued input first (respond to pending NeedInput credits). */
    for (int guard = 0; s->in_head && guard < 8192; guard++) {
      IMFMediaEvent *ev = NULL;
      if (FAILED(IMFMediaEventGenerator_GetEvent(s->event_gen, 0, &ev)) || !ev) {
        break;
      }
      MediaEventType met = 0;
      IMFMediaEvent_GetType(ev, &met);
      IMFMediaEvent_Release(ev);
      if (met == METransformNeedInput && s->in_head) {
        mfdec_feed_one(s);
      } else if (met == METransformHaveOutput) {
        mfdec_drain_one(s);
      }
    }
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
    s->draining = 1;
    /* Pump until DrainComplete, collecting trailing frames into out_queue. */
    for (int guard = 0; s->draining && guard < 8192; guard++) {
      IMFMediaEvent *ev = NULL;
      if (FAILED(IMFMediaEventGenerator_GetEvent(s->event_gen, 0, &ev)) || !ev) {
        break;
      }
      MediaEventType met = 0;
      IMFMediaEvent_GetType(ev, &met);
      IMFMediaEvent_Release(ev);
      if (met == METransformHaveOutput) {
        mfdec_drain_one(s);
      } else if (met == METransformDrainComplete) {
        s->draining = 0;
        break;
      }
      /* METransformNeedInput during drain: ignore (no more input coming). */
    }
  } else {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
    s->draining = 1;
    for (int guard = 0; guard < 4096; guard++) {
      DWORD status = 0;
      MFT_OUTPUT_DATA_BUFFER odb;
      memset(&odb, 0, sizeof(odb));
      HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &odb, &status);
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) break;
      if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        if (odb.pSample) IMFSample_Release(odb.pSample);
        s->output_configured = 0;
        if (mfdec_configure_output(s) == 0) mfdec_notify_streaming(s);
        continue;
      }
      if (FAILED(hr) || !odb.pSample) {
        if (odb.pSample) IMFSample_Release(odb.pSample);
        break;
      }
      LONGLONG t = 0;
      IMFSample_GetSampleTime(odb.pSample, &t);
      mfdec_extract_frame(s, odb.pSample, (int64_t)(t / 10));
      IMFSample_Release(odb.pSample);
    }
  }
  return 0;
}

MIO_API void miniav_shim_mfdec_release_frame(void *session,
                                             intptr_t shared_handle,
                                             intptr_t texture_ptr) {
  (void)session;
  if (shared_handle) CloseHandle((HANDLE)shared_handle);
  if (texture_ptr) {
    ID3D11Texture2D *t = (ID3D11Texture2D *)texture_ptr;
    ID3D11Texture2D_Release(t);
  }
}

MIO_API void miniav_shim_mfdec_destroy(void *session) {
  MfDecSession *s = (MfDecSession *)session;
  if (!s) return;
  /* Release any queued input samples. */
  IMFSample *ins;
  while ((ins = in_pop(s)) != NULL) IMFSample_Release(ins);
  /* Release any undelivered output frames. */
  MiniAVMfDecFrame f;
  while (out_pop(s, &f)) {
    if (f.out_shared_handle) CloseHandle((HANDLE)f.out_shared_handle);
    if (f.out_texture_ptr)
      ID3D11Texture2D_Release((ID3D11Texture2D *)f.out_texture_ptr);
  }
  if (s->staging) ID3D11Texture2D_Release(s->staging);
  if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  if (s->dxgi_mgr) IMFDXGIDeviceManager_Release(s->dxgi_mgr);
  if (s->context) ID3D11DeviceContext_Release(s->context);
  if (s->device) ID3D11Device_Release(s->device);
  free(s);
  MFShutdown();
}

#endif /* _WIN32 */
