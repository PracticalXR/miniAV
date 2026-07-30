/*
 * miniav_tools_ffmpeg shim — exposes AVCodecContext fields that FFmpeg's
 * AVOption system does not surface (`hw_device_ctx`, `hw_frames_ctx`) plus
 * a few struct field setters we need from Dart but cannot reach via FFI
 * pointer arithmetic safely.
 *
 * Built once per machine by `dart run miniav_tools_ffmpeg:build_shim`
 * against the FFmpeg dev distribution that the package's auto-downloader
 * already cached. The compiled shim DLL/so/dylib is dropped next to the
 * cached FFmpeg shared libraries so it loads transparently.
 *
 * ABI: stable across FFmpeg majors 7 and 8 (same struct layouts for the
 * fields we touch). If FFmpeg breaks one of these structs in a future
 * major bump, miniav_shim_abi_version() lets the Dart side detect it.
 */

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/buffer.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/log.h>
#include <libavutil/pixfmt.h>
#include <libavutil/samplefmt.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
  #include <pthread.h>
#endif

#ifdef _WIN32
  #define COBJMACROS
  #include <initguid.h>
  #include <d3d11.h>
  #include <d3d11_1.h>
  #include <dxgi1_2.h>
  #include <libavutil/hwcontext_d3d11va.h>
  #include <windows.h>
  #define MIO_API __declspec(dllexport)
#else
  #define MIO_API __attribute__((visibility("default")))
#endif

#if defined(__APPLE__)
  #include <CoreFoundation/CoreFoundation.h>
  #include <CoreVideo/CoreVideo.h>
  #include <IOSurface/IOSurfaceRef.h>
  #include <libavutil/hwcontext_videotoolbox.h>
#endif

#if defined(__linux__) && !defined(__ANDROID__)
  /* hwcontext_vaapi.h is present in any FFmpeg build that enabled --enable-vaapi.
   * The BtbN lgpl-shared Linux build does. We also pull hwcontext_drm.h for the
   * DRM_PRIME frame descriptor used by dmabuf import. */
  #include <libavutil/hwcontext_drm.h>
  #include <libavutil/hwcontext_vaapi.h>
  #include <stdint.h>
  #include <unistd.h>
#endif

#if defined(__ANDROID__)
  #include <android/hardware_buffer.h>
  #include <stdint.h>
  #if __ANDROID_API__ >= 26
    #define MIO_HAS_AHARDWAREBUFFER 1
  #endif
#endif

/* --- AVCodecContext field setters ------------------------------------- */

MIO_API void miniav_shim_set_hw_device_ctx(AVCodecContext* ctx,
                                           AVBufferRef* ref) {
    if (!ctx) return;
    if (ctx->hw_device_ctx) av_buffer_unref(&ctx->hw_device_ctx);
    ctx->hw_device_ctx = ref ? av_buffer_ref(ref) : NULL;
}

MIO_API void miniav_shim_set_hw_frames_ctx(AVCodecContext* ctx,
                                           AVBufferRef* ref) {
    if (!ctx) return;
    if (ctx->hw_frames_ctx) av_buffer_unref(&ctx->hw_frames_ctx);
    ctx->hw_frames_ctx = ref ? av_buffer_ref(ref) : NULL;
}

/* Set hw_frames_ctx on an AVFrame (used for QSV hwframe mapping).
 * Refs the provided buffer; NULL clears any existing ref. */
MIO_API void miniav_shim_av_frame_set_hw_frames_ctx(AVFrame* frame,
                                                    AVBufferRef* ref) {
    if (!frame) return;
    av_buffer_unref(&frame->hw_frames_ctx);
    frame->hw_frames_ctx = ref ? av_buffer_ref(ref) : NULL;
}

/* --- AVHWFramesContext access ----------------------------------------- */

MIO_API AVHWFramesContext* miniav_shim_hwframes_data(AVBufferRef* ref) {
    if (!ref) return NULL;
    return (AVHWFramesContext*)ref->data;
}

MIO_API void miniav_shim_hwframes_set_params(AVHWFramesContext* ctx,
                                             int format, int sw_format,
                                             int width, int height,
                                             int initial_pool_size) {
    if (!ctx) return;
    ctx->format = (enum AVPixelFormat)format;
    ctx->sw_format = (enum AVPixelFormat)sw_format;
    ctx->width = width;
    ctx->height = height;
    ctx->initial_pool_size = initial_pool_size;
}

/* --- AVHWDeviceContext access ----------------------------------------- */

MIO_API AVHWDeviceContext* miniav_shim_hwdev_data(AVBufferRef* ref) {
    if (!ref) return NULL;
    return (AVHWDeviceContext*)ref->data;
}

#ifdef _WIN32
/* Ensure the calling thread's COM apartment is MTA (multi-threaded).
 *
 * Several FFmpeg encoders on Windows require MTA:
 *   - h264_mf / hevc_mf  (Media Foundation IMFTransform)
 *   - h264_qsv / hevc_qsv (oneVPL / libmfx session)
 * Flutter's UI isolate initialises COM as STA on the platform thread; any
 * Dart async callback that ends up calling avcodec_open2() inherits that
 * apartment and the encoder init then fails with "COM must not be in STA
 * mode" or MFX_ERR_DEVICE_FAILED (-9).
 *
 * Returns:
 *    0  COM apartment is MTA on this thread (newly initialised, already MTA,
 *       or already initialised as MTA).
 *   -1  COM is already initialised as STA on this thread and cannot be
 *       changed (RPC_E_CHANGED_MODE).  The caller must not proceed with
 *       MFX/MF encoder init.
 *
 * Safe to call repeatedly; CoUninitialize is intentionally NOT paired —
 * the COM apartment lives for the lifetime of the thread, which matches
 * what the encoder runtime expects. */
MIO_API int miniav_shim_ensure_mta(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) return 0;          /* now MTA / already MTA */
    if (hr == RPC_E_CHANGED_MODE) {
        fprintf(stderr,
                "[shim] miniav_shim_ensure_mta: thread is already STA "
                "(RPC_E_CHANGED_MODE) — MFX/MF encoders will fail.  "
                "The caller should run encoder init on a worker thread.\n");
        return -1;
    }
    fprintf(stderr,
            "[shim] miniav_shim_ensure_mta: CoInitializeEx FAILED hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
}

/* Helper: AVBufferRef -> AVHWDeviceContext -> AVD3D11VADeviceContext.
 * Returns NULL if any link is missing. */
static AVD3D11VADeviceContext* _miniav_d3d11_ctx_from_ref(AVBufferRef* ref) {
    if (!ref || !ref->data) return NULL;
    AVHWDeviceContext* hwdev_ctx = (AVHWDeviceContext*)ref->data;
    if (!hwdev_ctx->hwctx) return NULL;
    return (AVD3D11VADeviceContext*)hwdev_ctx->hwctx;
}

/* Set the ID3D11Device pointer on a D3D11VA device context allocated by
 * av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA). The caller must NOT
 * have called av_hwdevice_ctx_init() yet. Pass the AVBufferRef* returned
 * by alloc; the shim dereferences to the inner AVD3D11VADeviceContext.
 *
 * The device is AddRef'd here so that FFmpeg's eventual Release (via
 * av_buffer_unref) does not consume the caller's reference. This matches
 * the contract of FFmpeg's own helpers and lets the caller safely retry
 * on multiple vendors with the same device pointer. */
MIO_API void miniav_shim_d3d11_dev_set_device(AVBufferRef* ref,
                                              void* id3d11device) {
    AVD3D11VADeviceContext* d = _miniav_d3d11_ctx_from_ref(ref);
    if (!d || !id3d11device) return;
    ID3D11Device* dev = (ID3D11Device*)id3d11device;
    dev->lpVtbl->AddRef(dev);
    d->device = dev;
}

/* Read back the ID3D11Device that FFmpeg either accepted via the setter
 * above OR allocated itself when av_hwdevice_ctx_init() was called with
 * a NULL device. Stage B uses the second mode (let FFmpeg pick adapter 0)
 * and then fetches the device here so we can open shared NT handles on it. */
MIO_API void* miniav_shim_d3d11_dev_get_device(AVBufferRef* ref) {
    AVD3D11VADeviceContext* d = _miniav_d3d11_ctx_from_ref(ref);
    return d ? (void*)d->device : NULL;
}

MIO_API void* miniav_shim_d3d11_dev_get_context(AVBufferRef* ref) {
    AVD3D11VADeviceContext* d = _miniav_d3d11_ctx_from_ref(ref);
    return d ? (void*)d->device_context : NULL;
}

/* Open a process-shared DXGI NT HANDLE on the supplied D3D11 device. The
 * returned ID3D11Texture2D* must be released by the caller. Returns NULL
 * on failure. Stage B per-frame: open the handle miniav placed in
 * MiniAVBuffer.nativeHandles[0], CopyResource into a hwframe pool tex,
 * release the opened texture. */
MIO_API void* miniav_shim_d3d11_open_shared_handle(void* id3d11device,
                                                   void* nt_handle) {
    if (!id3d11device || !nt_handle) return NULL;
    ID3D11Device1* dev1 = NULL;
    HRESULT hr = ((ID3D11Device*)id3d11device)->lpVtbl->QueryInterface(
        (ID3D11Device*)id3d11device, &IID_ID3D11Device1, (void**)&dev1);
    if (FAILED(hr) || !dev1) {
        fprintf(stderr,
            "[shim] QueryInterface(IID_ID3D11Device1) FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        return NULL;
    }
    /* Diagnostic: report the D3D11 device's DXGI adapter LUID and whether
     * the NT handle is still valid, before attempting the open. */
    {
        IDXGIDevice* dxgiDev = NULL;
        LUID luid = {0, 0};
        if (SUCCEEDED(((ID3D11Device*)id3d11device)->lpVtbl->QueryInterface(
                (ID3D11Device*)id3d11device, &IID_IDXGIDevice, (void**)&dxgiDev))) {
            IDXGIAdapter* ada = NULL;
            if (SUCCEEDED(dxgiDev->lpVtbl->GetAdapter(dxgiDev, &ada))) {
                DXGI_ADAPTER_DESC adesc;
                if (SUCCEEDED(ada->lpVtbl->GetDesc(ada, &adesc)))
                    luid = adesc.AdapterLuid;
                ada->lpVtbl->Release(ada);
            }
            dxgiDev->lpVtbl->Release(dxgiDev);
        }
        DWORD hflags = 0;
        BOOL hvalid = GetHandleInformation((HANDLE)nt_handle, &hflags);
        fprintf(stderr,
            "[shim] OpenSharedResource1: device=%p luid=%08lX:%08lX "
            "handle=%p valid=%d\n",
            id3d11device,
            (unsigned long)luid.HighPart, (unsigned long)luid.LowPart,
            nt_handle, (int)hvalid);
    }
    ID3D11Texture2D* tex = NULL;
    hr = dev1->lpVtbl->OpenSharedResource1(dev1, (HANDLE)nt_handle,
                                           &IID_ID3D11Texture2D, (void**)&tex);
    dev1->lpVtbl->Release(dev1);
    if (FAILED(hr)) {
        fprintf(stderr,
            "[shim] OpenSharedResource1 FAILED hr=0x%08lX handle=%p\n",
            (unsigned long)hr, nt_handle);
        return NULL;
    }
    return (void*)tex;
}

/* GPU-only copy from one D3D11 texture into another, both bound to the
 * same device (the destination's device, which is the FFmpeg-owned one).
 * No CPU staging \u2014 this is a single CopyResource on the immediate context.
 *
 * After the copy we insert a D3D11_QUERY_EVENT fence, Flush() the queue,
 * and poll until the GPU signals completion. This is REQUIRED because
 * NVENC / AMF / QSV all consume the destination texture through their
 * own engines (NVENC via NvEncRegisterResource + DirectX interop, etc.)
 * which do NOT serialise with the calling immediate context. Skipping the
 * fence yields black / undefined frames on the encoder.
 *
 * Cost: ~0.5\u20132ms per frame; with the producer pipelined this still
 * sustains 60fps at 5K on a discrete GPU. */
MIO_API void miniav_shim_d3d11_copy_resource(void* id3d11_device,
                                             void* id3d11_immediate_context,
                                             void* dst_tex,
                                             unsigned dst_subresource,
                                             void* src_tex,
                                             unsigned src_subresource) {
    if (!id3d11_device || !id3d11_immediate_context || !dst_tex || !src_tex) {
        return;
    }
    ID3D11Device* dev = (ID3D11Device*)id3d11_device;
    ID3D11DeviceContext* ctx = (ID3D11DeviceContext*)id3d11_immediate_context;

    /* If the source texture was created with D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX
     * (e.g. minigpu's SharedOutputTexture so Dawn can synchronise its D3D12
     * compute submission with us), we MUST AcquireSync(0) before reading and
     * ReleaseSync(0) after — otherwise the D3D11 read races Dawn's D3D12
     * queue and we get undefined contents (typically all-zero / black).
     *
     * Dawn signals key 0 on EndAccess after its queue has consumed the
     * compute work, so AcquireSync(0, INFINITE) blocks until the GPU side
     * is genuinely done. We re-release with key 0 so Dawn can re-acquire
     * for the next frame. */
    IDXGIKeyedMutex* km = NULL;
    HRESULT khr = ((ID3D11Resource*)src_tex)->lpVtbl->QueryInterface(
        (ID3D11Resource*)src_tex, &IID_IDXGIKeyedMutex, (void**)&km);
    if (SUCCEEDED(khr) && km) {
        HRESULT ahr = km->lpVtbl->AcquireSync(km, 0, INFINITE);
        if (FAILED(ahr)) {
            fprintf(stderr,
                "[shim] IDXGIKeyedMutex::AcquireSync(0) FAILED hr=0x%08lX\n",
                (unsigned long)ahr);
            km->lpVtbl->Release(km);
            km = NULL;
        }
    } else {
        km = NULL; /* not a keyed-mutex texture; nothing to sync via mutex */
    }

    /* CopySubresourceRegion with NULL source box copies the entire
     * subresource. This is mandatory because FFmpeg's D3D11VA hwframes
     * pool is a single Texture2DArray with ArraySize == pool size, and
     * `frame->data[0]` + `(intptr_t)frame->data[1]` give the array slice.
     * Plain CopyResource would no-op (different array sizes / descs). */
    ctx->lpVtbl->CopySubresourceRegion(
        ctx,
        (ID3D11Resource*)dst_tex, dst_subresource,
        0, 0, 0,
        (ID3D11Resource*)src_tex, src_subresource,
        NULL);

    D3D11_QUERY_DESC qd;
    qd.Query = D3D11_QUERY_EVENT;
    qd.MiscFlags = 0;
    ID3D11Query* fence = NULL;
    HRESULT hr = dev->lpVtbl->CreateQuery(dev, &qd, &fence);
    if (SUCCEEDED(hr) && fence) {
        ctx->lpVtbl->End(ctx, (ID3D11Asynchronous*)fence);
        ctx->lpVtbl->Flush(ctx);
        ULONGLONG t0 = GetTickCount64();
        for (;;) {
            HRESULT gd = ctx->lpVtbl->GetData(
                ctx, (ID3D11Asynchronous*)fence, NULL, 0, 0);
            if (gd == S_OK) break;
            if (gd != S_FALSE) break;
            if (GetTickCount64() - t0 > 50) break; /* 50ms watchdog */
            YieldProcessor();
        }
        fence->lpVtbl->Release(fence);
    } else {
        /* Best effort: at least submit the queue. */
        ctx->lpVtbl->Flush(ctx);
    }

    /* Release the keyed mutex (if any) so the producer can re-acquire it
     * for the next frame. We do this AFTER the fence so that Dawn won't
     * start writing again until the GPU has actually finished the read. */
    if (km) {
        km->lpVtbl->ReleaseSync(km, 0);
        km->lpVtbl->Release(km);
    }
}

/* Release any IUnknown-derived COM object (ID3D11Texture2D*, etc.). */
MIO_API void miniav_shim_d3d11_release(void* iunknown) {
    if (!iunknown) return;
    ((IUnknown*)iunknown)->lpVtbl->Release((IUnknown*)iunknown);
}

/* Create a sibling ID3D11Device on the same DXGI adapter as `existing_device`
 * but with D3D11_CREATE_DEVICE_VIDEO_SUPPORT enabled.
 *
 * MediaFoundation MFTs require the D3D11 device they use to have been created
 * with VIDEO_SUPPORT; Dawn (WebGPU) does not set that flag because it is
 * unnecessary for graphics/compute work and slightly increases driver overhead.
 * Since both devices are on the same adapter, process-shared NT handles open
 * successfully (OpenSharedResource1 is adapter-scoped, not device-scoped).
 *
 * The caller is responsible for calling IUnknown::Release on the returned
 * ID3D11Device* when it is no longer needed. Returns NULL on failure. */
MIO_API void* miniav_shim_d3d11_create_video_device_for(void* existing_device) {
    if (!existing_device) return NULL;

    /* Obtain the IDXGIAdapter the existing device is bound to. */
    IDXGIDevice* dxgiDev = NULL;
    HRESULT hr = ((ID3D11Device*)existing_device)->lpVtbl->QueryInterface(
        (ID3D11Device*)existing_device, &IID_IDXGIDevice, (void**)&dxgiDev);
    if (FAILED(hr) || !dxgiDev) {
        fprintf(stderr, "[shim] d3d11CreateVideoDeviceFor: QueryInterface(IDXGIDevice) FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        return NULL;
    }
    IDXGIAdapter* adapter = NULL;
    hr = dxgiDev->lpVtbl->GetAdapter(dxgiDev, &adapter);
    dxgiDev->lpVtbl->Release(dxgiDev);
    if (FAILED(hr) || !adapter) {
        fprintf(stderr, "[shim] d3d11CreateVideoDeviceFor: GetAdapter FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        return NULL;
    }

    /* Create a new D3D11 device on the SAME adapter with VIDEO_SUPPORT. */
    static const D3D_FEATURE_LEVEL fls[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
    };
    ID3D11Device* newDev = NULL;
    D3D_FEATURE_LEVEL gotLevel = (D3D_FEATURE_LEVEL)0;
    hr = D3D11CreateDevice(
        adapter,
        D3D_DRIVER_TYPE_UNKNOWN,   /* must be UNKNOWN when adapter != NULL */
        NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        fls, (UINT)(sizeof(fls) / sizeof(fls[0])),
        D3D11_SDK_VERSION,
        &newDev, &gotLevel, NULL);
    adapter->lpVtbl->Release(adapter);
    if (FAILED(hr) || !newDev) {
        fprintf(stderr, "[shim] d3d11CreateVideoDeviceFor: D3D11CreateDevice(VIDEO_SUPPORT) FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        return NULL;
    }

    /* Log LUID for cross-referencing with the existing device's LUID. */
    {
        IDXGIDevice* d2 = NULL;
        if (SUCCEEDED(newDev->lpVtbl->QueryInterface(newDev, &IID_IDXGIDevice, (void**)&d2))) {
            IDXGIAdapter* a2 = NULL;
            if (SUCCEEDED(d2->lpVtbl->GetAdapter(d2, &a2))) {
                DXGI_ADAPTER_DESC adesc;
                if (SUCCEEDED(a2->lpVtbl->GetDesc(a2, &adesc))) {
                    fprintf(stderr,
                        "[shim] d3d11CreateVideoDeviceFor: sibling device=%p luid=%08lX:%08lX (VIDEO_SUPPORT)\n",
                        (void*)newDev,
                        (unsigned long)adesc.AdapterLuid.HighPart,
                        (unsigned long)adesc.AdapterLuid.LowPart);
                }
                a2->lpVtbl->Release(a2);
            }
            d2->lpVtbl->Release(d2);
        }
    }
    return (void*)newDev;
}

/* --- Test-only helpers ----------------------------------------------------
 *
 * The functions below let unit tests synthesise an NT-shared BGRA texture
 * without depending on miniav (or any capture pipeline). They allocate an
 * independent producer ID3D11Device, create a 1-slice BGRA texture with
 * D3D11_RESOURCE_MISC_SHARED_NTHANDLE, fill it via Map/memcpy, and return
 * the duplicated NT HANDLE that the encoder side can OpenSharedResource1.
 *
 * Keep these compiled in: they're cheap and very useful for debugging the
 * Stage B pipeline on a developer machine. They are NOT used by the
 * production code path.
 */

typedef struct MiniavTestTexture {
    ID3D11Device*        device;
    ID3D11DeviceContext* context;
    ID3D11Texture2D*     texture;
    void*                shared_handle; /* NT HANDLE */
    unsigned             width;
    unsigned             height;
} MiniavTestTexture;

/* Create an independent D3D11 device + a BGRA NT-shareable texture. The
 * texture content is undefined; call miniav_shim_test_fill_bgra to write
 * a pattern. Returns NULL on failure. */
MIO_API MiniavTestTexture* miniav_shim_test_create_shared_bgra(unsigned width,
                                                               unsigned height) {
    if (width == 0 || height == 0) return NULL;
    MiniavTestTexture* t = (MiniavTestTexture*)calloc(1, sizeof(*t));
    if (!t) return NULL;

    D3D_FEATURE_LEVEL got = (D3D_FEATURE_LEVEL)0;
    static const D3D_FEATURE_LEVEL fls[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
    };
    HRESULT hr = D3D11CreateDevice(
        NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        fls, (UINT)(sizeof(fls)/sizeof(fls[0])),
        D3D11_SDK_VERSION,
        &t->device, &got, &t->context);
    if (FAILED(hr) || !t->device || !t->context) {
        free(t);
        return NULL;
    }

    D3D11_TEXTURE2D_DESC td;
    ZeroMemory(&td, sizeof(td));
    td.Width = width;
    td.Height = height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.SampleDesc.Quality = 0;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = 0;
    /* NT HANDLE share, no keyed mutex (matches miniav DXGI capture). */
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE
                 | D3D11_RESOURCE_MISC_SHARED;
    hr = t->device->lpVtbl->CreateTexture2D(t->device, &td, NULL, &t->texture);
    if (FAILED(hr) || !t->texture) {
        if (t->context) t->context->lpVtbl->Release(t->context);
        if (t->device)  t->device->lpVtbl->Release(t->device);
        free(t);
        return NULL;
    }

    /* Acquire NT shared handle. */
    IDXGIResource1* res1 = NULL;
    hr = t->texture->lpVtbl->QueryInterface(t->texture, &IID_IDXGIResource1,
                                            (void**)&res1);
    if (SUCCEEDED(hr) && res1) {
        HANDLE h = NULL;
        hr = res1->lpVtbl->CreateSharedHandle(
            res1, NULL,
            DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
            NULL, &h);
        res1->lpVtbl->Release(res1);
        if (SUCCEEDED(hr)) t->shared_handle = (void*)h;
    }
    if (!t->shared_handle) {
        t->texture->lpVtbl->Release(t->texture);
        t->context->lpVtbl->Release(t->context);
        t->device->lpVtbl->Release(t->device);
        free(t);
        return NULL;
    }

    t->width = width;
    t->height = height;
    return t;
}

/* Field accessors so Dart doesn't need to mirror the struct layout. */
MIO_API void* miniav_shim_test_texture_handle(MiniavTestTexture* t) {
    return t ? t->shared_handle : NULL;
}

/* Fill the texture with a BGRA pattern via UpdateSubresource. Pattern:
 * 32x32 checker of (R=tag, G=x*4, B=y*4) over white. */
MIO_API int miniav_shim_test_fill_bgra(MiniavTestTexture* t, unsigned tag) {
    if (!t || !t->texture || !t->context) return -1;
    /* Build the pattern in CPU memory then UpdateSubresource into the
     * default-usage texture. UpdateSubresource is a real GPU upload; we
     * follow with a fence/Flush so the encoder's OpenSharedResource1
     * sees committed pixels (the texture is backed by the same VRAM
     * across processes/devices via the NT handle). */
    const unsigned w = t->width, h = t->height;
    const unsigned stride = w * 4;
    unsigned char* buf = (unsigned char*)malloc((size_t)stride * h);
    if (!buf) return -2;
    for (unsigned y = 0; y < h; ++y) {
        for (unsigned x = 0; x < w; ++x) {
            unsigned char* p = buf + y * stride + x * 4;
            int checker = ((x >> 5) ^ (y >> 5)) & 1;
            if (checker) {
                p[0] = (unsigned char)(y & 0xff); /* B */
                p[1] = (unsigned char)(x & 0xff); /* G */
                p[2] = (unsigned char)(tag & 0xff); /* R */
                p[3] = 0xff;
            } else {
                p[0] = 0xff; p[1] = 0xff; p[2] = 0xff; p[3] = 0xff;
            }
        }
    }
    t->context->lpVtbl->UpdateSubresource(
        t->context, (ID3D11Resource*)t->texture, 0, NULL, buf, stride, 0);
    free(buf);

    /* Fence so cross-device readers see the result. */
    D3D11_QUERY_DESC qd; qd.Query = D3D11_QUERY_EVENT; qd.MiscFlags = 0;
    ID3D11Query* fence = NULL;
    if (SUCCEEDED(t->device->lpVtbl->CreateQuery(t->device, &qd, &fence))
            && fence) {
        t->context->lpVtbl->End(t->context, (ID3D11Asynchronous*)fence);
        t->context->lpVtbl->Flush(t->context);
        ULONGLONG t0 = GetTickCount64();
        for (;;) {
            HRESULT gd = t->context->lpVtbl->GetData(
                t->context, (ID3D11Asynchronous*)fence, NULL, 0, 0);
            if (gd == S_OK) break;
            if (gd != S_FALSE) break;
            if (GetTickCount64() - t0 > 50) break;
            YieldProcessor();
        }
        fence->lpVtbl->Release(fence);
    } else {
        t->context->lpVtbl->Flush(t->context);
    }
    return 0;
}

MIO_API void miniav_shim_test_destroy(MiniavTestTexture* t) {
    if (!t) return;
    if (t->shared_handle) CloseHandle((HANDLE)t->shared_handle);
    if (t->texture) t->texture->lpVtbl->Release(t->texture);
    if (t->context) t->context->lpVtbl->Release(t->context);
    if (t->device)  t->device->lpVtbl->Release(t->device);
    free(t);
}
#endif

/* ====================================================================== *
 *  macOS / iOS \u2014 VideoToolbox zero-copy interop
 * ====================================================================== *
 *
 * VideoToolbox encoders consume AVFrames whose:
 *   - frame->format    == AV_PIX_FMT_VIDEOTOOLBOX
 *   - frame->data[3]   == CVPixelBufferRef (NOT retained by FFmpeg \u2014 the
 *                         AVFrame's buf[0] must own a reference and release
 *                         it via av_buffer_unref).
 *
 * miniAV's macOS screen / camera capture wraps an IOSurface inside a
 * CVPixelBuffer (the IOSurface lives inside a CVMetalTexture). For true
 * zero-copy we either:
 *   (a) take the existing CVPixelBufferRef directly (preferred \u2014 single
 *       CFRetain), or
 *   (b) build a fresh CVPixelBuffer that wraps the same IOSurface (one
 *       extra CV object, still zero-copy at the GPU level).
 *
 * These helpers cover both modes and the AVFrame attachment.
 */
#if defined(__APPLE__)

/* Free callback for the AVBufferRef that owns the CVPixelBuffer reference.
 * Called by FFmpeg when the AVFrame is unreffed. */
static void _miniav_vt_pixbuf_free(void* opaque, uint8_t* data) {
    (void)opaque;
    if (data) {
        CVPixelBufferRef pb = (CVPixelBufferRef)(void*)data;
        CFRelease(pb);
    }
}

/* Attach a CVPixelBufferRef to an AVFrame as an AV_PIX_FMT_VIDEOTOOLBOX
 * payload. The frame takes ownership of one retain; the caller can
 * CFRelease their copy after this call. Returns 0 on success. */
MIO_API int miniav_shim_vt_attach_pixelbuffer(AVFrame* frame,
                                              void* cvpixelbuf,
                                              int width,
                                              int height) {
    if (!frame || !cvpixelbuf) return -1;
    /* Drop any previous payload. */
    av_frame_unref(frame);
    frame->format = AV_PIX_FMT_VIDEOTOOLBOX;
    frame->width  = width;
    frame->height = height;

    /* Retain so the frame owns its own ref. */
    CFRetain((CVPixelBufferRef)cvpixelbuf);

    AVBufferRef* bref = av_buffer_create(
        (uint8_t*)cvpixelbuf, sizeof(void*),
        _miniav_vt_pixbuf_free, NULL, 0);
    if (!bref) {
        CFRelease((CVPixelBufferRef)cvpixelbuf);
        return -2;
    }
    frame->buf[0]  = bref;
    frame->data[3] = (uint8_t*)cvpixelbuf;
    return 0;
}

/* Wrap an existing IOSurfaceRef in a fresh CVPixelBufferRef without
 * copying pixels. Returns NULL on failure. Caller owns one retain and
 * must CFRelease (or hand to attach_pixelbuffer above which retains). */
MIO_API void* miniav_shim_vt_pixbuf_from_iosurface(void* iosurface,
                                                   unsigned os_type_pixfmt) {
    if (!iosurface) return NULL;
    CVPixelBufferRef pb = NULL;
    /* Empty attribs dict \u2014 inherit IOSurface size + format. */
    OSStatus s = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        (IOSurfaceRef)iosurface,
        NULL,
        &pb);
    (void)os_type_pixfmt; /* OSType is read from the IOSurface itself. */
    if (s != kCVReturnSuccess || !pb) return NULL;
    return (void*)pb;
}

MIO_API void miniav_shim_vt_pixbuf_release(void* cvpixelbuf) {
    if (cvpixelbuf) CFRelease((CVPixelBufferRef)cvpixelbuf);
}

MIO_API unsigned miniav_shim_vt_pixbuf_width(void* cvpixelbuf) {
    if (!cvpixelbuf) return 0;
    return (unsigned)CVPixelBufferGetWidth((CVPixelBufferRef)cvpixelbuf);
}

MIO_API unsigned miniav_shim_vt_pixbuf_height(void* cvpixelbuf) {
    if (!cvpixelbuf) return 0;
    return (unsigned)CVPixelBufferGetHeight((CVPixelBufferRef)cvpixelbuf);
}

MIO_API unsigned miniav_shim_vt_pixbuf_pixel_format(void* cvpixelbuf) {
    if (!cvpixelbuf) return 0;
    return (unsigned)CVPixelBufferGetPixelFormatType((CVPixelBufferRef)cvpixelbuf);
}

#endif /* __APPLE__ */

/* ====================================================================== *
 *  Linux \u2014 VAAPI / DRM-PRIME zero-copy interop
 * ====================================================================== *
 *
 * VAAPI encoders consume AVFrames bound to an AV_HWFRAMES_CTX whose
 * format is AV_PIX_FMT_VAAPI. The fast path on Linux is:
 *
 *   miniAV capture \u2192 dmabuf FD(s)
 *     \u2193  build AV_PIX_FMT_DRM_PRIME frame descriptor
 *     \u2193  av_hwframe_map(vaapi_frame, drm_frame, AV_HWFRAME_MAP_DIRECT)
 *   VAAPI frame ready for avcodec_send_frame
 *
 * No GPU copy, no CPU staging \u2014 the dmabuf is imported into VAAPI as a
 * surface alias.
 */
#if defined(__linux__) && !defined(__ANDROID__)

/* Build a DRM_PRIME AVFrame from up to 4 dmabuf FDs and hand it to
 * av_hwframe_map for VAAPI import. On success [out_vaapi_frame] is
 * populated and owns a reference into the VAAPI hwframes pool.
 *
 * Inputs:
 *   vaapi_hwframes_ref : AVBufferRef* of the destination VAAPI hwframes ctx
 *   fds[]              : up to 4 dmabuf file descriptors
 *   nb_fds             : number of FDs (1..4)
 *   sizes[],
 *   offsets[],
 *   pitches[]          : per-FD plane geometry
 *   width, height      : frame geometry
 *   drm_fourcc         : DRM_FORMAT_* code (e.g. DRM_FORMAT_NV12)
 *   modifier           : DRM format modifier (DRM_FORMAT_MOD_LINEAR for the
 *                        common case, DRM_FORMAT_MOD_INVALID to leave it
 *                        unset)
 *   out_vaapi_frame    : caller-allocated AVFrame to populate
 *
 * Returns 0 on success, negative AVERROR on failure. The caller retains
 * ownership of the dmabuf FDs (they are dup'd by the kernel during
 * VA-API import). */
MIO_API int miniav_shim_vaapi_map_dmabuf(AVBufferRef* vaapi_hwframes_ref,
                                         int* fds, int nb_fds,
                                         int64_t* sizes,
                                         int64_t* offsets,
                                         int64_t* pitches,
                                         int width, int height,
                                         uint32_t drm_fourcc,
                                         uint64_t modifier,
                                         AVFrame* out_vaapi_frame) {
    if (!vaapi_hwframes_ref || !fds || nb_fds <= 0 || nb_fds > 4
        || !sizes || !offsets || !pitches || !out_vaapi_frame) {
        return AVERROR(EINVAL);
    }

    /* Build a transient DRM_PRIME source frame on the stack. */
    AVDRMFrameDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.nb_objects = nb_fds;
    for (int i = 0; i < nb_fds; ++i) {
        desc.objects[i].fd = fds[i];
        desc.objects[i].size = (size_t)sizes[i];
        desc.objects[i].format_modifier = modifier;
    }
    desc.nb_layers = 1;
    desc.layers[0].format = drm_fourcc;
    desc.layers[0].nb_planes = nb_fds;
    for (int i = 0; i < nb_fds; ++i) {
        desc.layers[0].planes[i].object_index = i;
        desc.layers[0].planes[i].offset = (ptrdiff_t)offsets[i];
        desc.layers[0].planes[i].pitch  = (ptrdiff_t)pitches[i];
    }

    AVFrame* src = av_frame_alloc();
    if (!src) return AVERROR(ENOMEM);
    src->format = AV_PIX_FMT_DRM_PRIME;
    src->width  = width;
    src->height = height;
    src->data[0] = (uint8_t*)&desc;

    /* Allocate destination VAAPI frame from the pool. */
    av_frame_unref(out_vaapi_frame);
    out_vaapi_frame->format = AV_PIX_FMT_VAAPI;
    out_vaapi_frame->width  = width;
    out_vaapi_frame->height = height;
    int err = av_hwframe_get_buffer(vaapi_hwframes_ref, out_vaapi_frame, 0);
    if (err < 0) {
        av_frame_free(&src);
        return err;
    }

    /* Direct map: VAAPI imports the dmabuf as a surface alias. */
    err = av_hwframe_map(out_vaapi_frame, src, AV_HWFRAME_MAP_DIRECT);
    av_frame_free(&src);
    if (err < 0) {
        av_frame_unref(out_vaapi_frame);
        return err;
    }
    return 0;
}

#endif /* __linux__ && !__ANDROID__ */

/* ====================================================================== *
 *  Android \u2014 AHardwareBuffer interop
 * ====================================================================== *
 *
 * Android's MediaCodec encoders accept either:
 *   - an InputSurface (Surface texture) for GPU producers, or
 *   - raw YUV byte buffers for CPU producers.
 *
 * FFmpeg's `*_mediacodec` codecs are decoders; for encoding on Android
 * the recommended path goes through the AMediaCodec NDK API. While we
 * wire that into a future Stage B, the shim provides the common helper
 * needed by both paths: lock an AHardwareBuffer for read and return the
 * mapped CPU pointer + stride so callers can either upload via
 * MediaCodec input buffer or fall back to FFmpeg software encoding.
 */
#if defined(__ANDROID__) && defined(MIO_HAS_AHARDWAREBUFFER)

typedef struct MiniavAhbLock {
    AHardwareBuffer* buffer;
    void* virtual_address;
    uint32_t stride_pixels;
    uint32_t width;
    uint32_t height;
    uint32_t format;
} MiniavAhbLock;

/* Lock an AHardwareBuffer for CPU read and return a small descriptor.
 * Caller must invoke miniav_shim_ahb_unlock to release. Returns NULL on
 * failure. */
MIO_API MiniavAhbLock* miniav_shim_ahb_lock_read(void* ahardware_buffer) {
    if (!ahardware_buffer) return NULL;
    AHardwareBuffer* hb = (AHardwareBuffer*)ahardware_buffer;
    AHardwareBuffer_Desc desc;
    AHardwareBuffer_describe(hb, &desc);
    MiniavAhbLock* lk = (MiniavAhbLock*)calloc(1, sizeof(*lk));
    if (!lk) return NULL;
    int rc = AHardwareBuffer_lock(
        hb, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN,
        -1, NULL, &lk->virtual_address);
    if (rc != 0 || !lk->virtual_address) {
        free(lk);
        return NULL;
    }
    lk->buffer = hb;
    lk->stride_pixels = desc.stride;
    lk->width = desc.width;
    lk->height = desc.height;
    lk->format = desc.format;
    AHardwareBuffer_acquire(hb);
    return lk;
}

MIO_API void* miniav_shim_ahb_lock_address(MiniavAhbLock* lk) {
    return lk ? lk->virtual_address : NULL;
}
MIO_API unsigned miniav_shim_ahb_lock_stride(MiniavAhbLock* lk) {
    return lk ? lk->stride_pixels : 0;
}
MIO_API unsigned miniav_shim_ahb_lock_width(MiniavAhbLock* lk) {
    return lk ? lk->width : 0;
}
MIO_API unsigned miniav_shim_ahb_lock_height(MiniavAhbLock* lk) {
    return lk ? lk->height : 0;
}
MIO_API unsigned miniav_shim_ahb_lock_format(MiniavAhbLock* lk) {
    return lk ? lk->format : 0;
}

MIO_API void miniav_shim_ahb_unlock(MiniavAhbLock* lk) {
    if (!lk) return;
    if (lk->buffer) {
        AHardwareBuffer_unlock(lk->buffer, NULL);
        AHardwareBuffer_release(lk->buffer);
    }
    free(lk);
}

#endif /* __ANDROID__ */

/* ====================================================================== *
 *  Audio encoder helpers (cross-platform)
 * ====================================================================== *
 *
 * AVChannelLayout is an opaque struct introduced in FFmpeg 5.x that lives
 * deep inside both AVCodecContext and AVFrame at offsets that shift
 * across libavutil minors. Rather than mirror the surrounding fields in
 * Dart FFI, the shim exposes thin setters/getters that touch them on
 * the C side where layout is known to the compiler.
 */

/* Set sample_fmt, sample_rate, ch_layout (default mask for `channels`)
 * and bit_rate on an AVCodecContext via AVOptions where possible and
 * direct field assignment for AVChannelLayout (which has no AVOption
 * accessor in FFmpeg 7/8). Returns 0 on success, negative AVERROR on
 * failure. */
MIO_API int miniav_shim_codec_set_audio_params(AVCodecContext* ctx,
                                               int sample_fmt,
                                               int sample_rate,
                                               int channels,
                                               int64_t bit_rate) {
    if (!ctx || channels <= 0 || sample_rate <= 0) return AVERROR(EINVAL);
    ctx->sample_fmt = (enum AVSampleFormat)sample_fmt;
    ctx->sample_rate = sample_rate;
    ctx->bit_rate = bit_rate;
    av_channel_layout_uninit(&ctx->ch_layout);
    av_channel_layout_default(&ctx->ch_layout, channels);
    return 0;
}

/* Number of samples-per-channel the opened encoder expects per AVFrame.
 * Returns 0 if the codec has no fixed frame size (the caller may then
 * pick any chunk size). */
MIO_API int miniav_shim_codec_get_frame_size(const AVCodecContext* ctx) {
    return ctx ? ctx->frame_size : 0;
}

/* Pick the first sample format from `codec->sample_fmts` (the first
 * entry is conventionally the native/preferred format). Returns -1 if
 * the codec exposes no list (rare for audio encoders). */
MIO_API int miniav_shim_codec_pick_sample_fmt(const AVCodec* codec) {
    if (!codec || !codec->sample_fmts) return -1;
    return (int)codec->sample_fmts[0];
}

/* Returns 1 if `codec` supports `sample_fmt` (as listed in its
 * sample_fmts table), 0 otherwise. */
MIO_API int miniav_shim_codec_supports_sample_fmt(const AVCodec* codec,
                                                  int sample_fmt) {
    if (!codec || !codec->sample_fmts) return 0;
    for (const enum AVSampleFormat* p = codec->sample_fmts;
         *p != AV_SAMPLE_FMT_NONE; ++p) {
        if ((int)*p == sample_fmt) return 1;
    }
    return 0;
}

/* Configure an audio AVFrame (format, sample_rate, ch_layout, nb_samples)
 * and allocate its data buffers via av_frame_get_buffer. Returns 0 on
 * success, negative AVERROR on failure. */
MIO_API int miniav_shim_audio_frame_setup(AVFrame* f,
                                          int sample_fmt,
                                          int sample_rate,
                                          int channels,
                                          int nb_samples) {
    if (!f || channels <= 0 || sample_rate <= 0 || nb_samples <= 0) {
        return AVERROR(EINVAL);
    }
    f->format = sample_fmt;
    f->sample_rate = sample_rate;
    f->nb_samples = nb_samples;
    av_channel_layout_uninit(&f->ch_layout);
    av_channel_layout_default(&f->ch_layout, channels);
    int err = av_frame_get_buffer(f, 0);
    if (err < 0) return err;
    return 0;
}

/* Set just the AVFrame's pts (used by the encoder driver between
 * make_writable + send_frame). Helps avoid mirroring AVFrame's later
 * fields when the caller only needs pts. */
MIO_API void miniav_shim_audio_frame_set_pts(AVFrame* f, int64_t pts) {
    if (f) f->pts = pts;
}

/* Copy [size] bytes of codec-private data (H.264 avcC, AAC ASC, OpusHead,
 * …) into ctx->extradata, av_mallocz'd with the decode-side padding
 * libavcodec requires. The context owns the allocation —
 * avcodec_free_context() frees it. Call BEFORE avcodec_open2(). */
MIO_API int miniav_shim_codec_set_extradata(AVCodecContext* ctx,
                                            const uint8_t* data,
                                            int size) {
    if (!ctx || !data || size <= 0) return AVERROR(EINVAL);
    uint8_t* buf =
        (uint8_t*)av_mallocz((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf) return AVERROR(ENOMEM);
    memcpy(buf, data, (size_t)size);
    av_freep(&ctx->extradata);
    ctx->extradata = buf;
    ctx->extradata_size = size;
    return 0;
}

/* Audio field readers for decoded AVFrames. The Dart-side AVFrame struct
 * mapping stops at pkt_dts; sample_rate / ch_layout live beyond it, so
 * read them here where the compiler knows the real layout. */
MIO_API int miniav_shim_frame_sample_rate(const AVFrame* f) {
    return f ? f->sample_rate : 0;
}

MIO_API int miniav_shim_frame_nb_channels(const AVFrame* f) {
    return f ? f->ch_layout.nb_channels : 0;
}

/* Colour metadata for decoded VIDEO AVFrames (same beyond-pkt_dts reasoning
 * as the audio readers above). Returns the raw AVColorSpace / AVColorRange
 * enum values (stable public API ints: colorspace BT709=1, UNSPECIFIED=2,
 * BT470BG=5, SMPTE170M=6, BT2020_NCL=9/CL=10; range MPEG/limited=1,
 * JPEG/full=2) so the Dart side can pick the matching YUV->RGB matrix. */
MIO_API int miniav_shim_frame_colorspace(const AVFrame* f) {
    return f ? (int)f->colorspace : 2 /* AVCOL_SPC_UNSPECIFIED */;
}

MIO_API int miniav_shim_frame_color_range(const AVFrame* f) {
    return f ? (int)f->color_range : 0 /* AVCOL_RANGE_UNSPECIFIED */;
}

/* --- Demux: blocking byte pipe + custom-IO open helpers (ABI v15) --------
 *
 * The pipe feeds libavformat from a live byte stream (progressive fMP4/MKV
 * from the network, a recorder chunk stream, …). The FEED side (any thread /
 * the Dart main isolate via FFI) writes without blocking — a full ring
 * returns a short count. The READ side is `mio_pipe_read_cb`, called by
 * libavformat inside `av_read_frame` on the demuxer's worker isolate; it
 * BLOCKS until bytes arrive or the pipe is closed (→ AVERROR_EOF). Closing
 * the pipe is therefore also the way to unblock a starved worker before
 * shutting the demuxer down.
 */

typedef struct MioBytePipe {
    uint8_t* buf;
    size_t cap;
    size_t head;   /* read position */
    size_t count;  /* bytes buffered */
    int closed;
#ifdef _WIN32
    CRITICAL_SECTION lock;
    CONDITION_VARIABLE cv;
#else
    pthread_mutex_t lock;
    pthread_cond_t cv;
#endif
} MioBytePipe;

static void mio_pipe_lock(MioBytePipe* p) {
#ifdef _WIN32
    EnterCriticalSection(&p->lock);
#else
    pthread_mutex_lock(&p->lock);
#endif
}

static void mio_pipe_unlock(MioBytePipe* p) {
#ifdef _WIN32
    LeaveCriticalSection(&p->lock);
#else
    pthread_mutex_unlock(&p->lock);
#endif
}

static void mio_pipe_wait(MioBytePipe* p) {
#ifdef _WIN32
    SleepConditionVariableCS(&p->cv, &p->lock, INFINITE);
#else
    pthread_cond_wait(&p->cv, &p->lock);
#endif
}

static void mio_pipe_signal(MioBytePipe* p) {
#ifdef _WIN32
    WakeAllConditionVariable(&p->cv);
#else
    pthread_cond_broadcast(&p->cv);
#endif
}

MIO_API void* miniav_shim_bytepipe_create(int64_t capacity) {
    if (capacity <= 0) capacity = 16LL * 1024 * 1024;
    MioBytePipe* p = (MioBytePipe*)calloc(1, sizeof(MioBytePipe));
    if (!p) return NULL;
    p->buf = (uint8_t*)malloc((size_t)capacity);
    if (!p->buf) {
        free(p);
        return NULL;
    }
    p->cap = (size_t)capacity;
#ifdef _WIN32
    InitializeCriticalSection(&p->lock);
    InitializeConditionVariable(&p->cv);
#else
    pthread_mutex_init(&p->lock, NULL);
    pthread_cond_init(&p->cv, NULL);
#endif
    return p;
}

/* Copy up to [len] bytes in; returns bytes accepted (0 = ring full — retry
 * later), or -1 if the pipe was already closed. Never blocks. */
MIO_API int32_t miniav_shim_bytepipe_write(void* pipe,
                                           const uint8_t* data,
                                           int32_t len) {
    MioBytePipe* p = (MioBytePipe*)pipe;
    if (!p || !data || len < 0) return -1;
    mio_pipe_lock(p);
    if (p->closed) {
        mio_pipe_unlock(p);
        return -1;
    }
    size_t space = p->cap - p->count;
    size_t n = ((size_t)len < space) ? (size_t)len : space;
    if (n > 0) {
        size_t wpos = (p->head + p->count) % p->cap;
        size_t first = p->cap - wpos;
        if (first > n) first = n;
        memcpy(p->buf + wpos, data, first);
        if (n > first) memcpy(p->buf, data + first, n - first);
        p->count += n;
        mio_pipe_signal(p);
    }
    mio_pipe_unlock(p);
    return (int32_t)n;
}

MIO_API int64_t miniav_shim_bytepipe_buffered(void* pipe) {
    MioBytePipe* p = (MioBytePipe*)pipe;
    if (!p) return 0;
    mio_pipe_lock(p);
    int64_t v = (int64_t)p->count;
    mio_pipe_unlock(p);
    return v;
}

/* End-of-stream: the reader drains what is buffered, then sees EOF. Also
 * unblocks a reader currently waiting for data. Idempotent. */
MIO_API void miniav_shim_bytepipe_close(void* pipe) {
    MioBytePipe* p = (MioBytePipe*)pipe;
    if (!p) return;
    mio_pipe_lock(p);
    p->closed = 1;
    mio_pipe_signal(p);
    mio_pipe_unlock(p);
}

/* Free the pipe. Only call after the demuxer using it has been closed
 * (no reader can be blocked inside the pipe). */
MIO_API void miniav_shim_bytepipe_destroy(void* pipe) {
    MioBytePipe* p = (MioBytePipe*)pipe;
    if (!p) return;
#ifdef _WIN32
    DeleteCriticalSection(&p->lock);
#else
    pthread_mutex_destroy(&p->lock);
    pthread_cond_destroy(&p->cv);
#endif
    free(p->buf);
    free(p);
}

/* Non-blocking read (drain side of an OUTPUT pipe — the muxer's write
 * callback fills the ring, Dart drains it after every muxer call).
 * Returns bytes copied (0 when empty), or -1 on bad args. */
MIO_API int32_t miniav_shim_bytepipe_read(void* pipe,
                                          uint8_t* dst,
                                          int32_t max_len) {
    MioBytePipe* p = (MioBytePipe*)pipe;
    if (!p || !dst || max_len <= 0) return -1;
    mio_pipe_lock(p);
    size_t n = ((size_t)max_len < p->count) ? (size_t)max_len : p->count;
    if (n > 0) {
        size_t first = p->cap - p->head;
        if (first > n) first = n;
        memcpy(dst, p->buf + p->head, first);
        if (n > first) memcpy(dst + first, p->buf, n - first);
        p->head = (p->head + n) % p->cap;
        p->count -= n;
    }
    mio_pipe_unlock(p);
    return (int32_t)n;
}

/* AVIO read callback over a MioBytePipe. Blocks until ≥1 byte or EOF. */
static int mio_pipe_read_cb(void* opaque, uint8_t* dst, int dst_size) {
    MioBytePipe* p = (MioBytePipe*)opaque;
    if (!p || !dst || dst_size <= 0) return AVERROR(EINVAL);
    mio_pipe_lock(p);
    while (p->count == 0 && !p->closed) {
        mio_pipe_wait(p);
    }
    if (p->count == 0) { /* closed + drained */
        mio_pipe_unlock(p);
        return AVERROR_EOF;
    }
    size_t n = ((size_t)dst_size < p->count) ? (size_t)dst_size : p->count;
    size_t first = p->cap - p->head;
    if (first > n) first = n;
    memcpy(dst, p->buf + p->head, first);
    if (n > first) memcpy(dst + first, p->buf, n - first);
    p->head = (p->head + n) % p->cap;
    p->count -= n;
    mio_pipe_unlock(p);
    return (int)n;
}

/* AVIO write callback over a MioBytePipe (muxer → pipe → Dart drain).
 * All-or-error: a full ring means the drain cadence / capacity is wrong —
 * surface ENOSPC rather than silently truncating the container. */
#if LIBAVFORMAT_VERSION_MAJOR >= 61
static int mio_pipe_write_cb(void* opaque, const uint8_t* buf, int buf_size) {
#else
static int mio_pipe_write_cb(void* opaque, uint8_t* buf, int buf_size) {
#endif
    if (buf_size <= 0) return 0;
    int32_t w = miniav_shim_bytepipe_write(opaque, buf, buf_size);
    if (w < 0) return AVERROR_EOF;
    if (w != buf_size) return AVERROR(ENOSPC);
    return buf_size;
}

/* --- Seekable in-memory output sink (BytesMuxerOutput) -------------------
 * Plain MP4 (moov rewrite / +faststart) requires a SEEKABLE output; a whole
 * in-memory file is naturally seekable, so bytes outputs mux into this
 * growable buffer instead of the streaming ring. */

typedef struct MioMemSink {
    uint8_t* buf;
    size_t size; /* high-water mark = file size */
    size_t cap;
    size_t pos;  /* current write position */
} MioMemSink;

MIO_API void* miniav_shim_memsink_create(void) {
    MioMemSink* s = (MioMemSink*)calloc(1, sizeof(MioMemSink));
    return s;
}

static int mio_memsink_ensure(MioMemSink* s, size_t need) {
    if (need <= s->cap) return 0;
    size_t cap = s->cap ? s->cap : (256 * 1024);
    while (cap < need) cap *= 2;
    uint8_t* nb = (uint8_t*)realloc(s->buf, cap);
    if (!nb) return -1;
    /* zero the gap so sparse seeks past EOF read as zeros */
    memset(nb + s->cap, 0, cap - s->cap);
    s->buf = nb;
    s->cap = cap;
    return 0;
}

#if LIBAVFORMAT_VERSION_MAJOR >= 61
static int mio_memsink_write_cb(void* opaque, const uint8_t* buf, int n) {
#else
static int mio_memsink_write_cb(void* opaque, uint8_t* buf, int n) {
#endif
    MioMemSink* s = (MioMemSink*)opaque;
    if (n <= 0) return 0;
    if (mio_memsink_ensure(s, s->pos + (size_t)n) != 0) {
        return AVERROR(ENOMEM);
    }
    memcpy(s->buf + s->pos, buf, (size_t)n);
    s->pos += (size_t)n;
    if (s->pos > s->size) s->size = s->pos;
    return n;
}

static int64_t mio_memsink_seek_cb(void* opaque, int64_t offset, int whence) {
    MioMemSink* s = (MioMemSink*)opaque;
    if (whence & AVSEEK_SIZE) return (int64_t)s->size;
    whence &= ~AVSEEK_FORCE;
    int64_t next;
    switch (whence) {
        case SEEK_SET: next = offset; break;
        case SEEK_CUR: next = (int64_t)s->pos + offset; break;
        case SEEK_END: next = (int64_t)s->size + offset; break;
        default: return AVERROR(EINVAL);
    }
    if (next < 0) return AVERROR(EINVAL);
    s->pos = (size_t)next;
    return next;
}

/* mov's +faststart pass reads back what it just wrote (shift_data), so the
 * sink AVIO must be readable too. */
static int mio_memsink_read_cb(void* opaque, uint8_t* dst, int dst_size) {
    MioMemSink* s = (MioMemSink*)opaque;
    if (!s || !dst || dst_size <= 0) return AVERROR(EINVAL);
    if (s->pos >= s->size) return AVERROR_EOF;
    size_t n = s->size - s->pos;
    if (n > (size_t)dst_size) n = (size_t)dst_size;
    memcpy(dst, s->buf + s->pos, n);
    s->pos += n;
    return (int)n;
}

MIO_API AVIOContext* miniav_shim_avio_out_memsink_create(void* sink) {
    const int kIoBufSize = 64 * 1024;
    if (!sink) return NULL;
    uint8_t* iobuf = (uint8_t*)av_malloc(kIoBufSize);
    if (!iobuf) return NULL;
    AVIOContext* avio = avio_alloc_context(iobuf, kIoBufSize, /*write*/ 1,
                                           sink, mio_memsink_read_cb,
                                           mio_memsink_write_cb,
                                           mio_memsink_seek_cb);
    if (!avio) {
        av_free(iobuf);
        return NULL;
    }
    return avio;
}

/* --- Seekable in-memory INPUT (bytes demuxing) ----------------------------
 * A fully-buffered container must be SEEKABLE (a moov-at-end MP4 cannot be
 * probed through a forward-only pipe), so bytes inputs demux from a C-owned
 * copy with read+seek callbacks. */

typedef struct MioMemSrc {
    uint8_t* buf;
    size_t size;
    size_t pos;
} MioMemSrc;

static int mio_memsrc_read_cb(void* opaque, uint8_t* dst, int dst_size) {
    MioMemSrc* s = (MioMemSrc*)opaque;
    if (!s || !dst || dst_size <= 0) return AVERROR(EINVAL);
    if (s->pos >= s->size) return AVERROR_EOF;
    size_t n = s->size - s->pos;
    if (n > (size_t)dst_size) n = (size_t)dst_size;
    memcpy(dst, s->buf + s->pos, n);
    s->pos += n;
    return (int)n;
}

static int64_t mio_memsrc_seek_cb(void* opaque, int64_t offset, int whence) {
    MioMemSrc* s = (MioMemSrc*)opaque;
    if (whence & AVSEEK_SIZE) return (int64_t)s->size;
    whence &= ~AVSEEK_FORCE;
    int64_t next;
    switch (whence) {
        case SEEK_SET: next = offset; break;
        case SEEK_CUR: next = (int64_t)s->pos + offset; break;
        case SEEK_END: next = (int64_t)s->size + offset; break;
        default: return AVERROR(EINVAL);
    }
    if (next < 0 || (size_t)next > s->size) return AVERROR(EINVAL);
    s->pos = (size_t)next;
    return next;
}

/* Open + probe a demuxer over a C-owned COPY of [data]. Close with
 * miniav_shim_close_input_bytes (frees the copy). */
MIO_API AVFormatContext* miniav_shim_open_input_bytes(const uint8_t* data,
                                                      int64_t len,
                                                      int32_t* err_out) {
    const int kIoBufSize = 64 * 1024;
    if (err_out) *err_out = AVERROR(EINVAL);
    if (!data || len <= 0) return NULL;
    MioMemSrc* src = (MioMemSrc*)calloc(1, sizeof(MioMemSrc));
    if (!src) {
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    src->buf = (uint8_t*)malloc((size_t)len);
    if (!src->buf) {
        free(src);
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    memcpy(src->buf, data, (size_t)len);
    src->size = (size_t)len;

    uint8_t* iobuf = (uint8_t*)av_malloc(kIoBufSize);
    AVIOContext* avio = iobuf
        ? avio_alloc_context(iobuf, kIoBufSize, 0, src, mio_memsrc_read_cb,
                             NULL, mio_memsrc_seek_cb)
        : NULL;
    AVFormatContext* fmt = avio ? avformat_alloc_context() : NULL;
    if (!fmt) {
        if (avio) {
            av_freep(&avio->buffer);
            avio_context_free(&avio);
        } else if (iobuf) {
            av_free(iobuf);
        }
        free(src->buf);
        free(src);
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    fmt->pb = avio;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    int ret = avformat_open_input(&fmt, NULL, NULL, NULL);
    if (ret < 0) {
        av_freep(&avio->buffer);
        avio_context_free(&avio);
        free(src->buf);
        free(src);
        if (err_out) *err_out = ret;
        return NULL;
    }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        AVIOContext* pb = fmt->pb;
        avformat_close_input(&fmt);
        av_freep(&pb->buffer);
        avio_context_free(&pb);
        free(src->buf);
        free(src);
        if (err_out) *err_out = ret;
        return NULL;
    }
    if (err_out) *err_out = 0;
    return fmt;
}

/* Close a bytes-opened input: also frees the C-owned data copy. */
MIO_API void miniav_shim_close_input_bytes(AVFormatContext* fmt) {
    if (!fmt) return;
    AVIOContext* pb = (fmt->flags & AVFMT_FLAG_CUSTOM_IO) ? fmt->pb : NULL;
    MioMemSrc* src = pb ? (MioMemSrc*)pb->opaque : NULL;
    avformat_close_input(&fmt);
    if (pb) {
        av_freep(&pb->buffer);
        avio_context_free(&pb);
    }
    if (src) {
        free(src->buf);
        free(src);
    }
}

MIO_API int64_t miniav_shim_memsink_size(void* sink) {
    MioMemSink* s = (MioMemSink*)sink;
    return s ? (int64_t)s->size : 0;
}

MIO_API int32_t miniav_shim_memsink_read(void* sink,
                                         int64_t offset,
                                         uint8_t* dst,
                                         int32_t max_len) {
    MioMemSink* s = (MioMemSink*)sink;
    if (!s || !dst || offset < 0 || max_len <= 0) return -1;
    if ((size_t)offset >= s->size) return 0;
    size_t n = s->size - (size_t)offset;
    if (n > (size_t)max_len) n = (size_t)max_len;
    memcpy(dst, s->buf + offset, n);
    return (int32_t)n;
}

MIO_API void miniav_shim_memsink_destroy(void* sink) {
    MioMemSink* s = (MioMemSink*)sink;
    if (!s) return;
    free(s->buf);
    free(s);
}

/* Writable AVIOContext over a byte pipe, for muxing to bytes/callback
 * outputs. Wire into AVFormatContext.pb; free with
 * miniav_shim_avio_out_free (never avio_closep — we own the buffer). */
MIO_API AVIOContext* miniav_shim_avio_out_pipe_create(void* pipe) {
    const int kIoBufSize = 64 * 1024;
    if (!pipe) return NULL;
    uint8_t* iobuf = (uint8_t*)av_malloc(kIoBufSize);
    if (!iobuf) return NULL;
    AVIOContext* avio = avio_alloc_context(iobuf, kIoBufSize, /*write*/ 1,
                                           pipe, NULL, mio_pipe_write_cb,
                                           NULL);
    if (!avio) {
        av_free(iobuf);
        return NULL;
    }
    return avio;
}

MIO_API void miniav_shim_avio_out_free(AVIOContext* avio) {
    if (!avio) return;
    av_freep(&avio->buffer);
    avio_context_free(&avio);
}

/* Open a demuxer over a byte pipe (custom AVIO, non-seekable) and probe
 * streams. Returns NULL with *err_out set on failure. */
MIO_API AVFormatContext* miniav_shim_open_input_pipe(void* pipe,
                                                     int32_t* err_out) {
    const int kIoBufSize = 64 * 1024;
    if (err_out) *err_out = AVERROR(EINVAL);
    if (!pipe) return NULL;
    uint8_t* iobuf = (uint8_t*)av_malloc(kIoBufSize);
    if (!iobuf) {
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    AVIOContext* avio = avio_alloc_context(iobuf, kIoBufSize, 0, pipe,
                                           mio_pipe_read_cb, NULL, NULL);
    if (!avio) {
        av_free(iobuf);
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    AVFormatContext* fmt = avformat_alloc_context();
    if (!fmt) {
        av_freep(&avio->buffer);
        avio_context_free(&avio);
        if (err_out) *err_out = AVERROR(ENOMEM);
        return NULL;
    }
    fmt->pb = avio;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    int ret = avformat_open_input(&fmt, NULL, NULL, NULL);
    if (ret < 0) {
        /* avformat_open_input frees fmt on failure; the avio is ours. */
        av_freep(&avio->buffer);
        avio_context_free(&avio);
        if (err_out) *err_out = ret;
        return NULL;
    }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        AVIOContext* pb = fmt->pb;
        avformat_close_input(&fmt);
        av_freep(&pb->buffer);
        avio_context_free(&pb);
        if (err_out) *err_out = ret;
        return NULL;
    }
    if (err_out) *err_out = 0;
    return fmt;
}

/* Open a demuxer over a URL/file path and probe streams. */
MIO_API AVFormatContext* miniav_shim_open_input_url(const char* url,
                                                    int32_t* err_out) {
    if (err_out) *err_out = AVERROR(EINVAL);
    if (!url) return NULL;
    AVFormatContext* fmt = NULL;
    int ret = avformat_open_input(&fmt, url, NULL, NULL);
    if (ret < 0) {
        if (err_out) *err_out = ret;
        return NULL;
    }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        avformat_close_input(&fmt);
        if (err_out) *err_out = ret;
        return NULL;
    }
    if (err_out) *err_out = 0;
    return fmt;
}

/* Close either flavour. Frees the custom AVIO for pipe inputs (with
 * AVFMT_FLAG_CUSTOM_IO, avformat_close_input leaves pb to the caller). */
MIO_API void miniav_shim_close_input(AVFormatContext* fmt) {
    if (!fmt) return;
    AVIOContext* pb = (fmt->flags & AVFMT_FLAG_CUSTOM_IO) ? fmt->pb : NULL;
    avformat_close_input(&fmt);
    if (pb) {
        av_freep(&pb->buffer);
        avio_context_free(&pb);
    }
}

/* Field readers beyond the Dart-mapped AVFormatContext prefix. */
MIO_API int32_t miniav_shim_fmt_nb_streams(const AVFormatContext* f) {
    return f ? (int32_t)f->nb_streams : 0;
}

MIO_API AVStream* miniav_shim_fmt_stream(const AVFormatContext* f, int32_t i) {
    if (!f || i < 0 || (unsigned)i >= f->nb_streams) return NULL;
    return f->streams[i];
}

/* Container duration in µs (AV_TIME_BASE == 1e6), or -1 if unknown
 * (typical for live pipe inputs). */
MIO_API int64_t miniav_shim_fmt_duration_us(const AVFormatContext* f) {
    return (f && f->duration > 0) ? f->duration : -1;
}

MIO_API int32_t miniav_shim_fmt_is_seekable(const AVFormatContext* f) {
    return (f && f->pb && f->pb->seekable) ? 1 : 0;
}

/* AVCodecParameters audio fields — beyond the Dart-mapped prefix. */
MIO_API int32_t miniav_shim_par_sample_rate(const AVCodecParameters* p) {
    return p ? p->sample_rate : 0;
}

MIO_API int32_t miniav_shim_par_nb_channels(const AVCodecParameters* p) {
    return p ? p->ch_layout.nb_channels : 0;
}

/* --- Sanity / version ------------------------------------------------- */

MIO_API unsigned miniav_shim_avcodec_version(void) {
    return avcodec_version();
}

/* Bumped when this shim's exported function set or struct expectations
 * change. The Dart loader rejects mismatches.
 *
 * v3: miniav_shim_d3d11_copy_resource gained a leading `device` argument
 *     and now does CopyResource + fence + flush + wait internally.
 * v4: miniav_shim_d3d11_copy_resource takes explicit (dst_subresource,
 *     src_subresource) and uses CopySubresourceRegion. Required because
 *     FFmpeg's D3D11VA hwframes pool is a Texture2DArray.
 * v5: added test-only helpers (miniav_shim_test_create_shared_bgra,
 *     miniav_shim_test_fill_bgra, miniav_shim_test_texture_handle,
 *     miniav_shim_test_destroy) for unit-test synthesis of NT-shared
 *     D3D11 textures. Linked against dxgi.lib for IDXGIResource1 GUID.
 * v6: cross-platform expansion. Added VideoToolbox helpers on macOS/iOS
 *     (vt_attach_pixelbuffer, vt_pixbuf_from_iosurface, vt_pixbuf_release,
 *     vt_pixbuf_{width,height,pixel_format}); VAAPI helpers on Linux
 *     (vaapi_map_dmabuf for DRM-PRIME zero-copy import); AHardwareBuffer
 *     helpers on Android (ahb_lock_read / ahb_unlock + accessors). All
 *     gated behind platform #ifdefs; absent symbols are the contract on
 *     the wrong host.
 * v7: audio encoder helpers (codec_set_audio_params,
 *     codec_get_frame_size, codec_pick_sample_fmt,
 *     codec_supports_sample_fmt, audio_frame_setup,
 *     audio_frame_set_pts). Encapsulate AVChannelLayout writes that
 *     have no AVOption accessor in FFmpeg 7/8.
 * v8: FFmpeg log forwarding helpers (set_ffmpeg_log_level,
 *     set_ffmpeg_log_callback). Allow Dart to control av_log level and
 *     route FFmpeg log output to a Dart-side callback.
 * v9: free_log_message. Log callback now passes a heap-allocated copy so
 *     the NativeCallable.listener async dispatch is safe. Dart must call
 *     miniav_shim_free_log_message() after consuming each message.
 * v10: d3d11_create_video_device_for. Creates a sibling D3D11 device on the
 *     same adapter as an injected device but with VIDEO_SUPPORT enabled,
 *     allowing MediaFoundation MFTs to accept it as an encoding device.
 * v11: av_frame_set_hw_frames_ctx. Sets hw_frames_ctx on an AVFrame so that
 *     av_hwframe_map can map a D3D11VA frame to a derived QSV frame.
 * v12: (internal fixes — no new exports)
 * v13: d3d11_vp_create / d3d11_vp_destroy / d3d11_vp_bgra_to_nv12.
 *      D3D11 VideoProcessor-based BGRA→NV12 conversion for Intel QSV/MF
 *      GPU zero-copy path.  Also d3d11va_frames_set_bind_flags so callers
 *      can include D3D11_BIND_RENDER_TARGET on the NV12 hwframes pool
 *      (required for VideoProcessor output views).
 *      Also d3d11_get_vendor_id: returns DXGI_ADAPTER_DESC.VendorId for an
 *      ID3D11Device so callers can filter to only compatible encoder vendors
 *      (e.g. skip h264_nvenc / h264_amf probes on an Intel iGPU device). */

#ifdef _WIN32
/* =========================================================================
 * d3d11_get_vendor_id — query DXGI adapter vendor from an ID3D11Device
 *
 * Returns DXGI_ADAPTER_DESC.VendorId (e.g. 0x8086 Intel, 0x10DE NVIDIA,
 * 0x1002 AMD) or 0 on failure.  Used by the Dart encoder layer to restrict
 * the vendor probe order to only the IHV that matches the injected device,
 * avoiding wasted NVENC/AMF open attempts on Intel iGPU devices and vice
 * versa.
 * ========================================================================= */
MIO_API unsigned miniav_shim_d3d11_get_vendor_id(void* id3d11_device) {
    if (!id3d11_device) return 0;
    IDXGIDevice* dxgi_dev = NULL;
    HRESULT hr = ((ID3D11Device*)id3d11_device)->lpVtbl->QueryInterface(
        (ID3D11Device*)id3d11_device, &IID_IDXGIDevice, (void**)&dxgi_dev);
    if (FAILED(hr) || !dxgi_dev) return 0;
    IDXGIAdapter* adapter = NULL;
    hr = dxgi_dev->lpVtbl->GetAdapter(dxgi_dev, &adapter);
    dxgi_dev->lpVtbl->Release(dxgi_dev);
    if (FAILED(hr) || !adapter) return 0;
    DXGI_ADAPTER_DESC desc;
    ZeroMemory(&desc, sizeof(desc));
    hr = adapter->lpVtbl->GetDesc(adapter, &desc);
    adapter->lpVtbl->Release(adapter);
    if (FAILED(hr)) return 0;
    return (unsigned)desc.VendorId;
}

/* =========================================================================
 * D3D11 VideoProcessor — BGRA → NV12 GPU color-space conversion
 *
 * Intel QSV (h264_qsv) and MediaFoundation (h264_mf) require NV12 input.
 * Our minigpu SharedOutputTexture is BGRA.  The D3D11 VideoProcessor API
 * converts BGRA → NV12 in GPU memory using the driver's built-in CSC unit
 * (the same hardware Intel's iGPU uses for video decode/encode internally).
 *
 * The VIDEO_SUPPORT sibling device is used — Dawn's device cannot be used
 * for VideoProcessor because it lacks D3D11_CREATE_DEVICE_VIDEO_SUPPORT.
 *
 * Cross-device source import: The BGRA SharedOutputTexture was created on
 * Dawn's ID3D11Device with D3D11_RESOURCE_MISC_SHARED, so it supports
 * IDXGIResource::GetSharedHandle + ID3D11Device::OpenSharedResource for
 * within-process, same-adapter access.  When cross_device=1 the shim
 * performs the import internally; when cross_device=0 the caller has
 * already opened the texture on the VP device (MiniAVBufferSource path).
 * ========================================================================= */

typedef struct MiniavD3d11Vp {
    ID3D11VideoDevice*              video_device;
    ID3D11VideoContext*             video_context;
    ID3D11VideoProcessorEnumerator* enumerator;
    ID3D11VideoProcessor*           processor;
    UINT                            width;
    UINT                            height;
} MiniavD3d11Vp;

/* Create a VideoProcessor context for BGRA→NV12 conversion at [width]x[height].
 * [id3d11_device] must have D3D11_CREATE_DEVICE_VIDEO_SUPPORT (the sibling
 * device created by miniav_shim_d3d11_create_video_device_for).
 * Returns an opaque MiniavD3d11Vp* or NULL on failure.
 * The caller must pair every successful call with miniav_shim_d3d11_vp_destroy. */
MIO_API void* miniav_shim_d3d11_vp_create(void*    id3d11_device,
                                           void*    id3d11_context,
                                           unsigned width,
                                           unsigned height) {
    if (!id3d11_device || !id3d11_context || width == 0 || height == 0)
        return NULL;
    ID3D11Device*        dev = (ID3D11Device*)id3d11_device;
    ID3D11DeviceContext* ctx = (ID3D11DeviceContext*)id3d11_context;

    MiniavD3d11Vp* vp = (MiniavD3d11Vp*)calloc(1, sizeof(*vp));
    if (!vp) return NULL;

    HRESULT hr = dev->lpVtbl->QueryInterface(
        dev, &IID_ID3D11VideoDevice, (void**)&vp->video_device);
    if (FAILED(hr) || !vp->video_device) {
        fprintf(stderr,
            "[shim] vp_create: QueryInterface(IID_ID3D11VideoDevice) FAILED "
            "hr=0x%08lX — device may lack D3D11_CREATE_DEVICE_VIDEO_SUPPORT\n",
            (unsigned long)hr);
        free(vp);
        return NULL;
    }

    hr = ctx->lpVtbl->QueryInterface(
        ctx, &IID_ID3D11VideoContext, (void**)&vp->video_context);
    if (FAILED(hr) || !vp->video_context) {
        fprintf(stderr,
            "[shim] vp_create: QueryInterface(IID_ID3D11VideoContext) FAILED "
            "hr=0x%08lX\n", (unsigned long)hr);
        vp->video_device->lpVtbl->Release(vp->video_device);
        free(vp);
        return NULL;
    }

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc;
    ZeroMemory(&desc, sizeof(desc));
    desc.InputFrameFormat            = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    desc.InputFrameRate.Numerator    = 60;
    desc.InputFrameRate.Denominator  = 1;
    desc.InputWidth                  = width;
    desc.InputHeight                 = height;
    desc.OutputFrameRate.Numerator   = 60;
    desc.OutputFrameRate.Denominator = 1;
    desc.OutputWidth                 = width;
    desc.OutputHeight                = height;
    desc.Usage                       = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;

    hr = vp->video_device->lpVtbl->CreateVideoProcessorEnumerator(
        vp->video_device, &desc, &vp->enumerator);
    if (FAILED(hr) || !vp->enumerator) {
        fprintf(stderr,
            "[shim] vp_create: CreateVideoProcessorEnumerator FAILED "
            "hr=0x%08lX\n", (unsigned long)hr);
        vp->video_context->lpVtbl->Release(vp->video_context);
        vp->video_device->lpVtbl->Release(vp->video_device);
        free(vp);
        return NULL;
    }

    hr = vp->video_device->lpVtbl->CreateVideoProcessor(
        vp->video_device, vp->enumerator, 0, &vp->processor);
    if (FAILED(hr) || !vp->processor) {
        fprintf(stderr,
            "[shim] vp_create: CreateVideoProcessor FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        vp->enumerator->lpVtbl->Release(vp->enumerator);
        vp->video_context->lpVtbl->Release(vp->video_context);
        vp->video_device->lpVtbl->Release(vp->video_device);
        free(vp);
        return NULL;
    }

    vp->width  = width;
    vp->height = height;
    fprintf(stderr, "[shim] vp_create: VideoProcessor ready for BGRA→NV12 "
        "%ux%u device=%p\n", width, height, id3d11_device);
    return (void*)vp;
}

MIO_API void miniav_shim_d3d11_vp_destroy(void* vp_ctx) {
    if (!vp_ctx) return;
    MiniavD3d11Vp* vp = (MiniavD3d11Vp*)vp_ctx;
    if (vp->processor)     vp->processor->lpVtbl->Release(vp->processor);
    if (vp->enumerator)    vp->enumerator->lpVtbl->Release(vp->enumerator);
    if (vp->video_context) vp->video_context->lpVtbl->Release(vp->video_context);
    if (vp->video_device)  vp->video_device->lpVtbl->Release(vp->video_device);
    free(vp);
}

/* Convert one BGRA frame to an NV12 slice in a Texture2DArray via
 * D3D11 VideoProcessor.
 *
 * [cross_device]:
 *   1 — src_bgra_tex is an ID3D11Texture2D* on a DIFFERENT device
 *       (e.g. Dawn's device).  The shim opens it on vp_device internally
 *       via IDXGIResource::GetSharedHandle + OpenSharedResource (legacy,
 *       within-process, same-adapter). Requires D3D11_RESOURCE_MISC_SHARED
 *       on the source texture.
 *   0 — src_bgra_tex is already on vp_device (e.g. opened via
 *       OpenSharedResource1 in the MiniAVBufferSource path).  Used directly
 *       without an additional cross-device import.
 *
 * [dst_subresource]: Texture2DArray slice index from av_hwframe_get_buffer
 *   (AVFrame::data[1] cast through intptr_t).
 * [dst_nv12_tex]: The Texture2DArray from AVFrame::data[0] (NV12 pool).
 *
 * Returns 0 on success, negative on failure. */
MIO_API int miniav_shim_d3d11_vp_bgra_to_nv12(void* vp_ctx,
                                               void* vp_device,
                                               void* vp_context,
                                               void* src_bgra_tex,
                                               int   cross_device,
                                               int   dst_subresource,
                                               void* dst_nv12_tex) {
    if (!vp_ctx || !vp_device || !vp_context || !src_bgra_tex || !dst_nv12_tex)
        return -1;

    MiniavD3d11Vp*       vp  = (MiniavD3d11Vp*)vp_ctx;
    ID3D11Device*        dev = (ID3D11Device*)vp_device;
    ID3D11DeviceContext* ctx = (ID3D11DeviceContext*)vp_context;

    /* ---------- cross-device import (D3D11_RESOURCE_MISC_SHARED) --------- */
    ID3D11Texture2D* src_on_vp = NULL;
    if (cross_device) {
        IDXGIResource* dxgi_res = NULL;
        HRESULT hr = ((ID3D11Resource*)src_bgra_tex)->lpVtbl->QueryInterface(
            (ID3D11Resource*)src_bgra_tex, &IID_IDXGIResource,
            (void**)&dxgi_res);
        if (FAILED(hr) || !dxgi_res) {
            fprintf(stderr,
                "[shim] vp_bgra_to_nv12: QueryInterface(IDXGIResource) FAILED "
                "hr=0x%08lX\n", (unsigned long)hr);
            return -2;
        }
        HANDLE legacy_handle = NULL;
        hr = dxgi_res->lpVtbl->GetSharedHandle(dxgi_res, &legacy_handle);
        dxgi_res->lpVtbl->Release(dxgi_res);
        if (FAILED(hr) || !legacy_handle) {
            fprintf(stderr,
                "[shim] vp_bgra_to_nv12: GetSharedHandle FAILED hr=0x%08lX "
                "(texture may lack D3D11_RESOURCE_MISC_SHARED)\n",
                (unsigned long)hr);
            return -3;
        }
        hr = dev->lpVtbl->OpenSharedResource(
            dev, legacy_handle, &IID_ID3D11Texture2D, (void**)&src_on_vp);
        if (FAILED(hr) || !src_on_vp) {
            fprintf(stderr,
                "[shim] vp_bgra_to_nv12: OpenSharedResource FAILED "
                "hr=0x%08lX handle=%p\n",
                (unsigned long)hr, (void*)legacy_handle);
            return -4;
        }
    } else {
        src_on_vp = (ID3D11Texture2D*)src_bgra_tex;
    }

    /* ---------- optional keyed-mutex sync --------------------------------- */
    IDXGIKeyedMutex* km = NULL;
    ((ID3D11Resource*)src_on_vp)->lpVtbl->QueryInterface(
        (ID3D11Resource*)src_on_vp, &IID_IDXGIKeyedMutex, (void**)&km);
    if (km) {
        HRESULT ahr = km->lpVtbl->AcquireSync(km, 0, INFINITE);
        if (FAILED(ahr)) { km->lpVtbl->Release(km); km = NULL; }
    }

    /* ---------- input view on BGRA source --------------------------------- */
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd;
    ZeroMemory(&ivd, sizeof(ivd));
    ivd.FourCC           = 0; /* infer from texture format */
    ivd.ViewDimension    = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.MipSlice = 0;
    ID3D11VideoProcessorInputView* input_view = NULL;
    HRESULT hr = vp->video_device->lpVtbl->CreateVideoProcessorInputView(
        vp->video_device, (ID3D11Resource*)src_on_vp,
        vp->enumerator, &ivd, &input_view);
    if (FAILED(hr) || !input_view) {
        fprintf(stderr,
            "[shim] vp_bgra_to_nv12: CreateVideoProcessorInputView FAILED "
            "hr=0x%08lX\n", (unsigned long)hr);
        if (km) { km->lpVtbl->ReleaseSync(km, 0); km->lpVtbl->Release(km); }
        if (cross_device) src_on_vp->lpVtbl->Release(src_on_vp);
        return -5;
    }

    /* ---------- output view on NV12 Texture2DArray slice ------------------ */
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd;
    ZeroMemory(&ovd, sizeof(ovd));
    ovd.ViewDimension                    = D3D11_VPOV_DIMENSION_TEXTURE2DARRAY;
    ovd.Texture2DArray.MipSlice          = 0;
    ovd.Texture2DArray.FirstArraySlice   = (UINT)dst_subresource;
    ovd.Texture2DArray.ArraySize         = 1;
    ID3D11VideoProcessorOutputView* output_view = NULL;
    hr = vp->video_device->lpVtbl->CreateVideoProcessorOutputView(
        vp->video_device, (ID3D11Resource*)dst_nv12_tex,
        vp->enumerator, &ovd, &output_view);
    if (FAILED(hr) || !output_view) {
        fprintf(stderr,
            "[shim] vp_bgra_to_nv12: CreateVideoProcessorOutputView FAILED "
            "hr=0x%08lX (dst texture may need D3D11_BIND_RENDER_TARGET)\n",
            (unsigned long)hr);
        input_view->lpVtbl->Release(input_view);
        if (km) { km->lpVtbl->ReleaseSync(km, 0); km->lpVtbl->Release(km); }
        if (cross_device) src_on_vp->lpVtbl->Release(src_on_vp);
        return -6;
    }

    /* ---------- color-space hints (RGB full → YCbCr BT.709 limited) ------- */
    {
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE cs;
        ZeroMemory(&cs, sizeof(cs));
        /* Input: full-range RGB (BGRA screen capture / compute output) */
        cs.RGB_Range     = 0; /* 0 = full range 0-255 */
        cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
        vp->video_context->lpVtbl->VideoProcessorSetStreamColorSpace(
            vp->video_context, vp->processor, 0, &cs);

        ZeroMemory(&cs, sizeof(cs));
        /* Output: limited-range YCbCr BT.709 (standard for H.264 encode) */
        cs.Usage         = 1;  /* video/encoder output */
        cs.YCbCr_Matrix  = 1;  /* BT.709 */
        cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
        vp->video_context->lpVtbl->VideoProcessorSetOutputColorSpace(
            vp->video_context, vp->processor, &cs);
    }

    /* ---------- execute blt ----------------------------------------------- */
    D3D11_VIDEO_PROCESSOR_STREAM stream;
    ZeroMemory(&stream, sizeof(stream));
    stream.Enable            = TRUE;
    stream.OutputIndex       = 0;
    stream.InputFrameOrField = 0;
    stream.pInputSurface     = input_view;
    hr = vp->video_context->lpVtbl->VideoProcessorBlt(
        vp->video_context, vp->processor, output_view, 0, 1, &stream);

    output_view->lpVtbl->Release(output_view);
    input_view->lpVtbl->Release(input_view);
    if (km) { km->lpVtbl->ReleaseSync(km, 0); km->lpVtbl->Release(km); }
    if (cross_device) src_on_vp->lpVtbl->Release(src_on_vp);

    if (FAILED(hr)) {
        fprintf(stderr,
            "[shim] vp_bgra_to_nv12: VideoProcessorBlt FAILED hr=0x%08lX\n",
            (unsigned long)hr);
        return -7;
    }

    /* GPU fence: ensure VP blt completes before the QSV/MF encoder reads. */
    {
        D3D11_QUERY_DESC qd; qd.Query = D3D11_QUERY_EVENT; qd.MiscFlags = 0;
        ID3D11Query* fence = NULL;
        if (SUCCEEDED(dev->lpVtbl->CreateQuery(dev, &qd, &fence)) && fence) {
            ctx->lpVtbl->End(ctx, (ID3D11Asynchronous*)fence);
            ctx->lpVtbl->Flush(ctx);
            ULONGLONG t0 = GetTickCount64();
            for (;;) {
                HRESULT gd = ctx->lpVtbl->GetData(
                    ctx, (ID3D11Asynchronous*)fence, NULL, 0, 0);
                if (gd == S_OK || gd != S_FALSE) break;
                if (GetTickCount64() - t0 > 50) break;
                YieldProcessor();
            }
            fence->lpVtbl->Release(fence);
        } else {
            ctx->lpVtbl->Flush(ctx);
        }
    }
    return 0;
}

/* Set BindFlags on an AVD3D11VAFramesContext before av_hwframe_ctx_init.
 * For VideoProcessor output, include D3D11_BIND_RENDER_TARGET (0x20).
 * For QSV/MF encode input, also include D3D11_BIND_VIDEO_ENCODER (0x400).
 * AVD3D11VAFramesContext::BindFlags defaults to 0, which makes FFmpeg use
 * D3D11_BIND_DECODER | D3D11_BIND_SHADER_RESOURCE — those don't allow VP
 * output views.  Must be called BEFORE av_hwframe_ctx_init(). */
MIO_API void miniav_shim_d3d11va_frames_set_bind_flags(AVBufferRef* ref,
                                                       unsigned     bind_flags) {
    if (!ref || !ref->data) return;
    AVHWFramesContext*      ctx     = (AVHWFramesContext*)ref->data;
    AVD3D11VAFramesContext* d3d_ctx = (AVD3D11VAFramesContext*)ctx->hwctx;
    if (!d3d_ctx) return;
    d3d_ctx->BindFlags = (UINT)bind_flags;
}
#endif /* _WIN32 (VP section) */

MIO_API unsigned miniav_shim_abi_version(void) {
    /* v17: the mf_decoder.c hardware H.264/HEVC → D3D11 NV12 decode session
     * (miniav_shim_mfdec_*) MOVED to the standalone, FFmpeg-free
     * miniav_tools_codecs_native asset — this shim no longer exports it. */
    /* v18: miniav_shim_frame_colorspace / _color_range (AVFrame colour
     * metadata readers for the BT.601/709 + limited/full matrix selection). */
    return 18u;
}

/* --- FFmpeg log forwarding ------------------------------------------------
 *
 * FFmpeg's av_log_set_callback takes a va_list which is not bindable
 * directly from Dart FFI. This shim bridges the gap: Dart installs a
 * simple  (int level, const char* message)  callback here, and we set up
 * our own av_log callback that formats the message with vsnprintf and
 * forwards it.
 *
 * Thread safety: the global function pointer is written under the lock
 * that av_log_set_callback provides on its own end. We do not provide
 * additional synchronisation — reads happen only inside the av_log
 * callback which is serialised by FFmpeg's internal mutex.
 */

typedef void (*MiniavDartFfmpegLogCb)(int level, const char* message);
static MiniavDartFfmpegLogCb _dart_ffmpeg_log_cb = NULL;

static void _ffmpeg_dart_log_bridge(void* avcl, int level, const char* fmt, va_list vl) {
    (void)avcl;
    MiniavDartFfmpegLogCb cb = _dart_ffmpeg_log_cb;
    if (!cb) return;
    if (level > av_log_get_level()) return; /* respect the current level */
    char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    /* NativeCallable.listener dispatches asynchronously on the Dart event
     * loop.  By the time Dart runs, this stack frame has returned and buf[]
     * is gone.  Heap-copy so the pointer stays valid; Dart must call
     * miniav_shim_free_log_message() after reading. */
    size_t len = strlen(buf);
    char* heap = (char*)malloc(len + 1);
    if (!heap) return;
    memcpy(heap, buf, len + 1);
    cb(level, heap);
}

/* Set (or clear) the Dart log callback. Pass NULL to restore FFmpeg's
 * default logger. */
MIO_API void miniav_shim_set_ffmpeg_log_callback(MiniavDartFfmpegLogCb cb) {
    _dart_ffmpeg_log_cb = cb;
    if (cb) {
        av_log_set_callback(_ffmpeg_dart_log_bridge);
    } else {
        av_log_set_callback(av_log_default_callback);
    }
}

/* Free a heap-allocated log message returned via the log callback.
 * Dart MUST call this after consuming each message. */
MIO_API void miniav_shim_free_log_message(const char* msg) {
    free((void*)msg);
}

/* Set the FFmpeg log level (AV_LOG_* constants: QUIET=-8, ERROR=16,
 * WARNING=24, INFO=32, VERBOSE=40, DEBUG=48). */
MIO_API void miniav_shim_set_ffmpeg_log_level(int level) {
    av_log_set_level(level);
}
