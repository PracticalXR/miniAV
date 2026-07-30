/* mf_encoder.c — Windows Media Foundation H.264/HEVC video ENCODE.
 *
 * The encode analogue of mf_decoder.c. This first cut is the verifiable core:
 * a SYNC encoder MFT (the MS software H.264/HEVC encoder) consuming
 * system-memory NV12 and emitting an elementary bitstream + SPS/PPS. Zero
 * FFmpeg. D3D11 zero-copy texture input, async/hardware encoders, and the MTA
 * isolate host are follow-ups (the sync CPU path proves the codec + pipeline).
 *
 * Reuses the lessons from mf_aac.c: output-type-before-input for encoders, and
 * PRE-ALLOCATE the output IMFSample (the MS encoders don't provide their own →
 * ProcessOutput returns E_INVALIDARG otherwise).
 */

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#define COBJMACROS
#include <windows.h>
#include <codecapi.h>
#include <strmif.h> /* ICodecAPI (codecapi.h only declares its property GUIDs) */
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MFENC_API __declspec(dllexport)

/* MF packs FRAME_SIZE / FRAME_RATE / PAR as a UINT64 = (hi << 32) | lo. This
 * avoids linking MFSetAttributeSize/Ratio. */
#define PACK64(hi, lo) (((UINT64)(UINT32)(hi) << 32) | (UINT32)(lo))

typedef struct {
  uint8_t *data; /* malloc'd elementary bitstream; caller frees */
  int size;
  int is_keyframe;
  int64_t pts_us;
} MiniAVMfEncFrame;

typedef struct {
  IMFTransform *mft;
  int width;
  int height;
  int64_t frame_dur_100ns; /* per-frame duration in 100-ns units */
  uint8_t extradata[256];  /* SPS/PPS (MF_MT_MPEG_SEQUENCE_HEADER) */
  int extradata_len;
  int started;
} MfVidEnc;

static int mfenc_started;

/* ICodecAPI + the two encoder-property GUIDs we need, declared locally so we
 * don't have to link strmiids/INITGUID (which would collide with the MF GUIDs
 * the CMake build already pulls from mfuuid.lib). Values are the canonical
 * Windows SDK codecapi.h / strmif.h definitions.
 *   AVLowLatencyMode  — TRUE disables B-frames + lookahead (live, low delay).
 *   AVEncMPVDefaultBPictureCount — belt-and-braces 0 B-frames. */
static const GUID kIID_ICodecAPI = {
    0x901db4c7,
    0x31ce,
    0x41a2,
    {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};
static const GUID kCODECAPI_AVLowLatencyMode = {
    0x9c27891a,
    0xed7a,
    0x40e1,
    {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
static const GUID kCODECAPI_AVEncMPVDefaultBPictureCount = {
    0x8d390aac,
    0xdc5c,
    0x4200,
    {0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2}};

static int mf_up(void) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (co == RPC_E_CHANGED_MODE) return -1;
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return -1;
  mfenc_started++;
  return 0;
}

static void mf_down(void) {
  if (mfenc_started > 0) {
    mfenc_started--;
    MFShutdown();
  }
}

/* Availability: is there a video encoder MFT for this codec? codec 0=H264 1=HEVC */
MFENC_API int miniav_shim_mfenc_has_mft(int codec) {
  if (mf_up() != 0) return 0;
  MFT_REGISTER_TYPE_INFO out = {MFMediaType_Video,
                                codec == 1 ? MFVideoFormat_HEVC
                                           : MFVideoFormat_H264};
  UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
                 MFT_ENUM_FLAG_TRANSCODE_ONLY | MFT_ENUM_FLAG_SORTANDFILTER;
  IMFActivate **acts = NULL;
  UINT32 count = 0;
  HRESULT hr =
      MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, NULL, &out, &acts, &count);
  if (SUCCEEDED(hr) && acts) {
    for (UINT32 i = 0; i < count; i++) IMFActivate_Release(acts[i]);
    CoTaskMemFree(acts);
  }
  mf_down();
  return (SUCCEEDED(hr) && count > 0) ? 1 : 0;
}

MFENC_API void *miniav_shim_mfenc_create(int codec, int width, int height,
                                         int bitrate_bps, int fps_num,
                                         int fps_den, int gop) {
  if (width <= 0 || height <= 0) return NULL;
  if (bitrate_bps <= 0) bitrate_bps = 4000000;
  if (fps_num <= 0) fps_num = 30;
  if (fps_den <= 0) fps_den = 1;
  if (mf_up() != 0) return NULL;

  MfVidEnc *s = (MfVidEnc *)calloc(1, sizeof(MfVidEnc));
  if (!s) {
    mf_down();
    return NULL;
  }
  s->width = width;
  s->height = height;
  s->frame_dur_100ns = (int64_t)10000000 * fps_den / fps_num;

  /* Enumerate a SYNC encoder MFT. */
  {
    MFT_REGISTER_TYPE_INFO out = {MFMediaType_Video,
                                  codec == 1 ? MFVideoFormat_HEVC
                                             : MFVideoFormat_H264};
    UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
                   MFT_ENUM_FLAG_TRANSCODE_ONLY | MFT_ENUM_FLAG_SORTANDFILTER;
    IMFActivate **acts = NULL;
    UINT32 count = 0;
    if (FAILED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, NULL, &out, &acts,
                         &count)) ||
        count == 0) {
      if (acts) CoTaskMemFree(acts);
      goto fail;
    }
    for (UINT32 i = 0; i < count; i++) {
      if (!s->mft && FAILED(IMFActivate_ActivateObject(
                         acts[i], &IID_IMFTransform, (void **)&s->mft)))
        s->mft = NULL;
      IMFActivate_Release(acts[i]);
    }
    CoTaskMemFree(acts);
    if (!s->mft) goto fail;
  }

  /* OUTPUT type first (encoders require it). */
  {
    IMFMediaType *ot = NULL;
    if (FAILED(MFCreateMediaType(&ot))) goto fail;
    IMFMediaType_SetGUID(ot, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(ot, &MF_MT_SUBTYPE,
                         codec == 1 ? &MFVideoFormat_HEVC : &MFVideoFormat_H264);
    IMFMediaType_SetUINT32(ot, &MF_MT_AVG_BITRATE, (UINT32)bitrate_bps);
    IMFMediaType_SetUINT32(ot, &MF_MT_INTERLACE_MODE,
                           MFVideoInterlace_Progressive);
    IMFMediaType_SetUINT64(ot, &MF_MT_FRAME_SIZE, PACK64(width, height));
    IMFMediaType_SetUINT64(ot, &MF_MT_FRAME_RATE, PACK64(fps_num, fps_den));
    IMFMediaType_SetUINT64(ot, &MF_MT_PIXEL_ASPECT_RATIO, PACK64(1, 1));
    IMFMediaType_SetUINT32(
        ot, &MF_MT_MPEG2_PROFILE,
        codec == 1 ? eAVEncH265VProfile_Main_420_8 : eAVEncH264VProfile_Base);
    HRESULT hr = IMFTransform_SetOutputType(s->mft, 0, ot, 0);
    IMFMediaType_Release(ot);
    if (FAILED(hr)) goto fail;
  }

  /* INPUT type (NV12). */
  {
    IMFMediaType *it = NULL;
    if (FAILED(MFCreateMediaType(&it))) goto fail;
    IMFMediaType_SetGUID(it, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(it, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    IMFMediaType_SetUINT32(it, &MF_MT_INTERLACE_MODE,
                           MFVideoInterlace_Progressive);
    IMFMediaType_SetUINT64(it, &MF_MT_FRAME_SIZE, PACK64(width, height));
    IMFMediaType_SetUINT64(it, &MF_MT_FRAME_RATE, PACK64(fps_num, fps_den));
    IMFMediaType_SetUINT64(it, &MF_MT_PIXEL_ASPECT_RATIO, PACK64(1, 1));
    HRESULT hr = IMFTransform_SetInputType(s->mft, 0, it, 0);
    IMFMediaType_Release(it);
    if (FAILED(hr)) goto fail;
  }

  /* Low-latency: the MS H.264 encoder defaults to B-frames + a lookahead that
   * add reorder delay (fine for VOD, wrong for a live preview — this was the
   * "weird latency delay" on h264; the HEVC MFT defaults to 0 B-frames, so it
   * didn't show it). Turn on low-latency mode (disables B-frames) and pin the
   * B-picture count to 0. Best-effort: some encoder MFTs don't expose ICodecAPI
   * or a given property, so ignore failures. Must run before streaming; done
   * here (after the types, before the SPS blob) so the extradata reflects it. */
  {
    ICodecAPI *api = NULL;
    if (SUCCEEDED(IMFTransform_QueryInterface(s->mft, &kIID_ICodecAPI,
                                              (void **)&api)) &&
        api) {
      VARIANT v;
      VariantInit(&v);
      v.vt = VT_BOOL;
      v.boolVal = VARIANT_TRUE;
      ICodecAPI_SetValue(api, &kCODECAPI_AVLowLatencyMode, &v);
      VariantClear(&v);
      v.vt = VT_UI4;
      v.ulVal = 0;
      ICodecAPI_SetValue(api, &kCODECAPI_AVEncMPVDefaultBPictureCount, &v);
      VariantClear(&v);
      ICodecAPI_Release(api);
    }
  }

  /* GOP: left to the encoder default; callers force IDRs via the keyframe flag
   * on send_nv12 (an ICodecAPI GOP knob is a follow-up — its header/lib pull-in
   * isn't worth it for the first cut). */
  (void)gop;

  /* SPS/PPS from the output type's sequence header. */
  {
    IMFMediaType *cur = NULL;
    if (SUCCEEDED(IMFTransform_GetOutputCurrentType(s->mft, 0, &cur)) && cur) {
      UINT32 n = 0;
      IMFMediaType_GetBlobSize(cur, &MF_MT_MPEG_SEQUENCE_HEADER, &n);
      if (n > 0 && n <= sizeof(s->extradata)) {
        if (SUCCEEDED(IMFMediaType_GetBlob(cur, &MF_MT_MPEG_SEQUENCE_HEADER,
                                           s->extradata, n, NULL))) {
          s->extradata_len = (int)n;
        }
      }
      IMFMediaType_Release(cur);
    }
  }

  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  s->started = 1;
  return s;

fail:
  if (s->mft) IMFTransform_Release(s->mft);
  free(s);
  mf_down();
  return NULL;
}

MFENC_API int miniav_shim_mfenc_get_extradata(void *session, uint8_t *out,
                                              int cap) {
  MfVidEnc *s = (MfVidEnc *)session;
  if (!s) return -1;
  if (!out) return s->extradata_len;
  if (cap < s->extradata_len) return -1;
  if (s->extradata_len > 0) memcpy(out, s->extradata, (size_t)s->extradata_len);
  return s->extradata_len;
}

/* Feed one system-memory NV12 frame (size must be width*height*3/2). */
MFENC_API int miniav_shim_mfenc_send_nv12(void *session, const uint8_t *nv12,
                                          int nv12_size, int64_t pts_us,
                                          int force_keyframe) {
  MfVidEnc *s = (MfVidEnc *)session;
  if (!s || !nv12) return -1;
  int need = s->width * s->height * 3 / 2;
  if (nv12_size < need) return -1;

  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer((DWORD)need, &buf))) return -1;
  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  memcpy(dst, nv12, (size_t)need);
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, (DWORD)need);

  IMFSample *smp = NULL;
  if (FAILED(MFCreateSample(&smp))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(smp, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(smp, (LONGLONG)pts_us * 10);
  IMFSample_SetSampleDuration(smp, s->frame_dur_100ns);
  if (force_keyframe) {
    IMFSample_SetUINT32(smp, &MFSampleExtension_CleanPoint, 1);
  }
  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, smp, 0);
  IMFSample_Release(smp);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) return -1;
  return (hr == MF_E_NOTACCEPTING) ? 1 : 0;
}

/* Pull one encoded frame. 1 = frame, 0 = need more input, 2 = stream change. */
MFENC_API int miniav_shim_mfenc_receive(void *session, MiniAVMfEncFrame *out) {
  MfVidEnc *s = (MfVidEnc *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  MFT_OUTPUT_STREAM_INFO si;
  memset(&si, 0, sizeof(si));
  IMFTransform_GetOutputStreamInfo(s->mft, 0, &si);
  int providesOwn = (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                                   MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

  MFT_OUTPUT_DATA_BUFFER odb;
  memset(&odb, 0, sizeof(odb));
  IMFSample *pre = NULL;
  IMFMediaBuffer *preBuf = NULL;
  if (!providesOwn) {
    DWORD cb = si.cbSize > 0 ? si.cbSize
                             : (DWORD)(s->width * s->height * 3 / 2 + 4096);
    if (FAILED(MFCreateSample(&pre)) ||
        FAILED(MFCreateMemoryBuffer(cb, &preBuf))) {
      if (pre) IMFSample_Release(pre);
      if (preBuf) IMFMediaBuffer_Release(preBuf);
      return -1;
    }
    IMFSample_AddBuffer(pre, preBuf);
    odb.pSample = pre;
  }
  DWORD status = 0;
  HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &odb, &status);
  if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (pre) IMFSample_Release(pre);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (pre) IMFSample_Release(pre);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 2;
  }
  if (FAILED(hr) || !odb.pSample) {
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }

  IMFMediaBuffer *mb = NULL;
  if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(odb.pSample, &mb)) && mb) {
    BYTE *p = NULL;
    DWORD len = 0;
    if (SUCCEEDED(IMFMediaBuffer_Lock(mb, &p, NULL, &len)) && len > 0) {
      out->data = (uint8_t *)malloc(len);
      if (out->data) {
        memcpy(out->data, p, len);
        out->size = (int)len;
        UINT32 clean = 0;
        IMFSample_GetUINT32(odb.pSample, &MFSampleExtension_CleanPoint, &clean);
        out->is_keyframe = clean ? 1 : 0;
        LONGLONG t = 0;
        if (SUCCEEDED(IMFSample_GetSampleTime(odb.pSample, &t)))
          out->pts_us = (int64_t)(t / 10);
      }
      IMFMediaBuffer_Unlock(mb);
    }
    IMFMediaBuffer_Release(mb);
  }
  if (preBuf) IMFMediaBuffer_Release(preBuf);
  IMFSample_Release(odb.pSample);
  if (odb.pEvents) IMFCollection_Release(odb.pEvents);
  return out->data ? 1 : 0;
}

MFENC_API int miniav_shim_mfenc_drain(void *session) {
  MfVidEnc *s = (MfVidEnc *)session;
  if (!s) return -1;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
  return 0;
}

MFENC_API void miniav_shim_mfenc_destroy(void *session) {
  MfVidEnc *s = (MfVidEnc *)session;
  if (!s) return;
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  free(s);
  mf_down();
}

MFENC_API void miniav_shim_mfenc_free(void *p) { free(p); }

#endif /* _WIN32 */
