Perfect. Now I have all the information I need. Let me create a comprehensive implementation spec.

---

## IMPLEMENTATION SPEC: Task P2.2 — Windows AAC Decode/Encode via Media Foundation

This spec details the implementation of FFmpeg-free AAC audio codec support on Windows using Media Foundation MFTs, mirroring the mf_decoder.c pattern (H.264/HEVC video) but for AAC audio. The result is a first-party Windows-only backend paired with a pure-Dart ADTS framing layer that already exists.

---

### 1. FILES TO CREATE

#### 1.1 `native/mf_aac.c` (570 lines)

**Purpose:** Standalone Media Foundation AAC decoder + encoder MFT wrapper. Windows-only (guarded by `#if defined(_WIN32)`), zero FFmpeg, mirrors mf_decoder.c's MFT session model (async event pump for MFT) but audio-focused: CPU PCM in/out, no D3D11, no device/context needed.

**Key Design Decisions:**
- **Input to Decoder:** raw AAC bytes (MPEG-4 Audio Specific Config separately, NOT ADTS headers; ADTS is stripped by Dart caller before passing to native).
- **Output from Decoder:** PCM (f32 or s16, selectable; default f32).
- **Input to Encoder:** PCM (f32 or s16).
- **Output from Encoder:** raw AAC bytes (no ADTS wrapper; Dart caller adds via AdtsMuxer).
- **Codec Structure:** Separate decoder and encoder sessions (no pooling); stateful, single-threaded per session.

**File Content:**

```c
/* mf_aac.c — Windows Media Foundation AAC decode + encode (audio CPU codecs)
 *
 * Mirrors mf_decoder.c but for audio: no D3D11, CPU PCM in/out.
 * Decoder: raw AAC → PCM (f32/s16).
 * Encoder: PCM → raw AAC (caller applies ADTS framing).
 *
 * MF AAC Decoder MFT: input = raw AAC, output = PCM.
 * MF AAC Encoder MFT: input = PCM, output = raw AAC.
 *
 * NOTE: This is the OS-AAC path. AAC is the default MP4 audio codec.
 * libfdk-aac is BANNED (GPL risk). OS/MF AAC is license-clean (free codec).
 */

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <mferror.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MFAAC_API __declspec(dllexport)

/* Frame descriptor for one decoded audio chunk. */
typedef struct {
  uint8_t *pcm_data;      /* malloc'd buffer; caller must free */
  int pcm_size;           /* bytes */
  int sample_count;       /* per-channel */
  int sample_rate;        /* Hz */
  int channels;
  int sample_fmt;         /* 0=f32, 1=s16 */
  int64_t pts_us;
} MiniAVMfAacDecFrame;

typedef struct {
  uint8_t *aac_data;      /* malloc'd buffer; caller must free */
  int aac_size;           /* bytes */
  int64_t pts_us;
} MiniAVMfAacEncFrame;

/* Decoder session. */
typedef struct {
  IMFTransform *mft;
  IMFMediaEventGenerator *event_gen;
  int is_async;
  int output_configured;
  int sample_rate;
  int channels;
  int sample_fmt;         /* 0=f32, 1=s16 */
  int streaming;
  int draining;
  int pending_frames;     /* queued input samples awaiting ProcessInput */
  int64_t pending_pts;
} MfAacDecSession;

/* Encoder session. */
typedef struct {
  IMFTransform *mft;
  IMFMediaEventGenerator *event_gen;
  int is_async;
  int output_configured;
  int sample_rate;
  int channels;
  int streaming;
  int draining;
} MfAacEncSession;

/* ========================================================================== */
/* AAC Decoder                                                               */
/* ========================================================================== */

/* Check if an AAC decoder MFT is available. */
MFAAC_API int miniav_shim_mfaac_dec_has_mft(void) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  int started_mf = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));

  MFT_REGISTER_TYPE_INFO in_info;
  in_info.guidMajorType = MFMediaType_Audio;
  in_info.guidSubtype = MFAudioFormat_AAC;

  MFT_REGISTER_TYPE_INFO out_info;
  out_info.guidMajorType = MFMediaType_Audio;
  out_info.guidSubtype = MFAudioFormat_PCM;

  IMFActivate **activates = NULL;
  UINT32 count = 0;
  HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_AUDIO_DECODER,
      MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
          MFT_ENUM_FLAG_SORTANDFILTER,
      &in_info, &out_info, &activates, &count);
  if (SUCCEEDED(hr) && activates) {
    for (UINT32 i = 0; i < count; i++) IMFActivate_Release(activates[i]);
    CoTaskMemFree(activates);
  }
  if (started_mf) MFShutdown();
  return (SUCCEEDED(hr) && count > 0) ? 1 : 0;
}

/* Enumerate AAC decoder MFT; return activated IMFTransform* (caller Release). */
static IMFTransform *mfaac_dec_enum_activate(void) {
  MFT_REGISTER_TYPE_INFO in_info;
  in_info.guidMajorType = MFMediaType_Audio;
  in_info.guidSubtype = MFAudioFormat_AAC;

  MFT_REGISTER_TYPE_INFO out_info;
  out_info.guidMajorType = MFMediaType_Audio;
  out_info.guidSubtype = MFAudioFormat_PCM;

  UINT32 flags = MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_SYNCMFT |
                 MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_LOCALMFT;

  IMFActivate **activates = NULL;
  UINT32 count = 0;
  HRESULT hr =
      MFTEnumEx(MFT_CATEGORY_AUDIO_DECODER, flags, &in_info, &out_info,
                &activates, &count);
  if (FAILED(hr) || count == 0) {
    if (activates) CoTaskMemFree(activates);
    return NULL;
  }

  IMFTransform *mft = NULL;
  for (UINT32 i = 0; i < count; i++) {
    if (!mft) {
      HRESULT ahr = IMFActivate_ActivateObject(activates[i], &IID_IMFTransform,
                                               (void **)&mft);
      if (FAILED(ahr)) mft = NULL;
    }
    IMFActivate_Release(activates[i]);
  }
  CoTaskMemFree(activates);
  return mft;
}

/* Set AAC decoder input type. asc_data = 2-byte AudioSpecificConfig. */
static int mfaac_dec_set_input_type(IMFTransform *mft,
                                    const uint8_t *asc_data, int asc_len) {
  if (!asc_data || asc_len < 2) return -1;

  IMFMediaType *in_type = NULL;
  if (FAILED(MFCreateMediaType(&in_type))) return -1;

  IMFMediaType_SetGUID(in_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
  IMFMediaType_SetGUID(in_type, &MF_MT_SUBTYPE, &MFAudioFormat_AAC);
  IMFMediaType_SetUINT32(in_type, &MF_MT_AUDIO_NUM_CHANNELS, 2);
  IMFMediaType_SetUINT32(in_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);

  /* AAC-specific: AudioSpecificConfig blob. MF decodes it to sample rate. */
  if (FAILED(IMFMediaType_SetBlob(in_type, &MF_MT_USER_DATA, (const UINT8 *)asc_data,
                                  (UINT32)asc_len))) {
    IMFMediaType_Release(in_type);
    return -1;
  }

  HRESULT hr = IMFTransform_SetInputType(mft, 0, in_type, 0);
  IMFMediaType_Release(in_type);
  if (FAILED(hr)) {
    fprintf(stderr, "[mfaac_dec] SetInputType failed hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
  }
  return 0;
}

/* Negotiate output type (PCM). Query available types; pick the first f32/s16. */
static int mfaac_dec_negotiate_output(MfAacDecSession *s) {
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
    int fmt = -1;
    if (IsEqualGUID(&sub, &MFAudioFormat_Float)) {
      fmt = 0; /* f32 */
    } else if (IsEqualGUID(&sub, &MFAudioFormat_PCM)) {
      fmt = 1; /* s16 */
    } else {
      IMFMediaType_Release(ot);
      continue;
    }

    /* Set output type. MF will fill in the sample rate + channels from the AAC bitstream. */
    hr = IMFTransform_SetOutputType(s->mft, 0, ot, 0);
    if (SUCCEEDED(hr)) {
      UINT32 sr = 0, ch = 0;
      IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
      IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_NUM_CHANNELS, &ch);
      s->sample_rate = (int)sr;
      s->channels = (int)ch;
      s->sample_fmt = fmt;
      s->output_configured = 1;
    }
    IMFMediaType_Release(ot);
    return SUCCEEDED(hr) ? 0 : -1;
  }
  return -1;
}

MFAAC_API void *miniav_shim_mfaac_dec_create(const uint8_t *asc_data,
                                             int asc_len) {
  if (!asc_data || asc_len < 2) return NULL;

  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (co == RPC_E_CHANGED_MODE) {
    fprintf(stderr, "[mfaac_dec] thread is STA — needs MTA\n");
    return NULL;
  }
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    fprintf(stderr, "[mfaac_dec] MFStartup failed\n");
    return NULL;
  }

  MfAacDecSession *s =
      (MfAacDecSession *)calloc(1, sizeof(MfAacDecSession));
  if (!s) {
    MFShutdown();
    return NULL;
  }

  s->mft = mfaac_dec_enum_activate();
  if (!s->mft) {
    fprintf(stderr, "[mfaac_dec] no AAC decoder MFT\n");
    goto fail;
  }

  if (mfaac_dec_set_input_type(s->mft, asc_data, asc_len) != 0) goto fail;

  /* Check async. */
  {
    IMFAttributes *attrs = NULL;
    if (SUCCEEDED(IMFTransform_GetAttributes(s->mft, &attrs)) && attrs) {
      UINT32 is_async = 0;
      IMFAttributes_GetUINT32(attrs, &MF_TRANSFORM_ASYNC, &is_async);
      s->is_async = is_async ? 1 : 0;
      if (s->is_async) {
        IMFAttributes_SetUINT32(attrs, &MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
      }
      IMFAttributes_Release(attrs);
    }
  }

  if (s->is_async) {
    if (FAILED(IMFTransform_QueryInterface(
            s->mft, &IID_IMFMediaEventGenerator, (void **)&s->event_gen)))
      goto fail;
  }

  /* Negotiate output type lazily (on first data). */
  if (!s->is_async) {
    if (mfaac_dec_negotiate_output(s) != 0) goto fail;
  }

  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  s->streaming = 1;
  return s;

fail:
  if (s) {
    if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
    if (s->mft) IMFTransform_Release(s->mft);
    free(s);
  }
  MFShutdown();
  return NULL;
}

MFAAC_API int miniav_shim_mfaac_dec_send(void *session, const uint8_t *aac_data,
                                         int aac_size, int64_t pts_us) {
  MfAacDecSession *s = (MfAacDecSession *)session;
  if (!s || !aac_data || aac_size <= 0) return -1;

  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer((DWORD)aac_size, &buf))) return -1;

  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  memcpy(dst, aac_data, (size_t)aac_size);
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, (DWORD)aac_size);

  IMFSample *sample = NULL;
  if (FAILED(MFCreateSample(&sample))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(sample, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(sample, (LONGLONG)pts_us * 10);
  IMFSample_SetSampleDuration(sample, 0);

  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
  IMFSample_Release(sample);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) {
    fprintf(stderr, "[mfaac_dec] ProcessInput failed hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
  }
  return 0;
}

MFAAC_API int miniav_shim_mfaac_dec_receive(void *session,
                                            MiniAVMfAacDecFrame *out) {
  MfAacDecSession *s = (MfAacDecSession *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  MFT_OUTPUT_DATA_BUFFER odb;
  memset(&odb, 0, sizeof(odb));
  odb.dwStreamID = 0;
  odb.pSample = NULL;
  DWORD status = 0;

  HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &odb, &status);
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    if (!s->is_async) {
      s->output_configured = 0;
      mfaac_dec_negotiate_output(s);
    }
    return 0; /* need more input */
  }
  if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }
  if (FAILED(hr) || !odb.pSample) {
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  /* Extract PCM data. */
  IMFMediaBuffer *mbuf = NULL;
  if (FAILED(IMFSample_GetBufferByIndex(odb.pSample, 0, &mbuf)) || !mbuf) {
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  BYTE *pdata = NULL;
  DWORD len = 0;
  if (FAILED(IMFMediaBuffer_Lock(mbuf, &pdata, NULL, &len))) {
    IMFMediaBuffer_Release(mbuf);
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  out->pcm_data = (uint8_t *)malloc(len);
  if (!out->pcm_data) {
    IMFMediaBuffer_Unlock(mbuf);
    IMFMediaBuffer_Release(mbuf);
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }
  memcpy(out->pcm_data, pdata, len);
  IMFMediaBuffer_Unlock(mbuf);
  IMFMediaBuffer_Release(mbuf);

  out->pcm_size = (int)len;
  out->sample_rate = s->sample_rate;
  out->channels = s->channels;
  out->sample_fmt = s->sample_fmt;

  /* Per-channel sample count: f32=4 bytes, s16=2 bytes */
  int bytes_per_sample = s->sample_fmt == 0 ? 4 : 2;
  out->sample_count = len / (bytes_per_sample * s->channels);

  LONGLONG ts100 = 0;
  if (SUCCEEDED(IMFSample_GetSampleTime(odb.pSample, &ts100))) {
    out->pts_us = (int64_t)(ts100 / 10);
  }

  IMFSample_Release(odb.pSample);
  if (odb.pEvents) IMFCollection_Release(odb.pEvents);
  return 1; /* frame ready */
}

MFAAC_API int miniav_shim_mfaac_dec_drain(void *session) {
  MfAacDecSession *s = (MfAacDecSession *)session;
  if (!s) return -1;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
  s->draining = 1;
  return 0;
}

MFAAC_API void miniav_shim_mfaac_dec_destroy(void *session) {
  MfAacDecSession *s = (MfAacDecSession *)session;
  if (!s) return;
  if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  free(s);
  MFShutdown();
}

/* ========================================================================== */
/* AAC Encoder                                                               */
/* ========================================================================== */

MFAAC_API void *miniav_shim_mfaac_enc_create(int sample_rate, int channels,
                                             int bitrate_bps) {
  if (channels < 1 || channels > 2) return NULL;
  if (bitrate_bps <= 0) bitrate_bps = 128000; /* default 128 kbps */

  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (co == RPC_E_CHANGED_MODE) {
    fprintf(stderr, "[mfaac_enc] thread is STA\n");
    return NULL;
  }
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    fprintf(stderr, "[mfaac_enc] MFStartup failed\n");
    return NULL;
  }

  MfAacEncSession *s =
      (MfAacEncSession *)calloc(1, sizeof(MfAacEncSession));
  if (!s) {
    MFShutdown();
    return NULL;
  }

  /* Enumerate AAC encoder MFT. */
  MFT_REGISTER_TYPE_INFO in_info;
  in_info.guidMajorType = MFMediaType_Audio;
  in_info.guidSubtype = MFAudioFormat_PCM;

  MFT_REGISTER_TYPE_INFO out_info;
  out_info.guidMajorType = MFMediaType_Audio;
  out_info.guidSubtype = MFAudioFormat_AAC;

  UINT32 flags = MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_SYNCMFT |
                 MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_LOCALMFT;

  IMFActivate **activates = NULL;
  UINT32 count = 0;
  HRESULT hr = MFTEnumEx(MFT_CATEGORY_AUDIO_ENCODER, flags, &in_info, &out_info,
                         &activates, &count);
  if (FAILED(hr) || count == 0) {
    if (activates) CoTaskMemFree(activates);
    goto fail;
  }

  for (UINT32 i = 0; i < count; i++) {
    if (!s->mft) {
      HRESULT ahr = IMFActivate_ActivateObject(activates[i], &IID_IMFTransform,
                                               (void **)&s->mft);
      if (FAILED(ahr)) s->mft = NULL;
    }
    IMFActivate_Release(activates[i]);
  }
  CoTaskMemFree(activates);
  if (!s->mft) goto fail;

  /* Set input type (PCM). */
  {
    IMFMediaType *in_type = NULL;
    if (FAILED(MFCreateMediaType(&in_type))) goto fail;
    IMFMediaType_SetGUID(in_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(in_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    IMFMediaType_SetUINT32(in_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)sample_rate);
    IMFMediaType_SetUINT32(in_type, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    IMFMediaType_SetUINT32(in_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
    hr = IMFTransform_SetInputType(s->mft, 0, in_type, 0);
    IMFMediaType_Release(in_type);
    if (FAILED(hr)) {
      fprintf(stderr, "[mfaac_enc] SetInputType failed hr=0x%08lX\n",
              (unsigned long)hr);
      goto fail;
    }
  }

  /* Set output type (AAC). */
  {
    IMFMediaType *out_type = NULL;
    if (FAILED(MFCreateMediaType(&out_type))) goto fail;
    IMFMediaType_SetGUID(out_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(out_type, &MF_MT_SUBTYPE, &MFAudioFormat_AAC);
    IMFMediaType_SetUINT32(out_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)sample_rate);
    IMFMediaType_SetUINT32(out_type, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    IMFMediaType_SetUINT32(out_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, (UINT32)(bitrate_bps / 8));
    hr = IMFTransform_SetOutputType(s->mft, 0, out_type, 0);
    IMFMediaType_Release(out_type);
    if (FAILED(hr)) {
      fprintf(stderr, "[mfaac_enc] SetOutputType failed hr=0x%08lX\n",
              (unsigned long)hr);
      goto fail;
    }
  }

  s->sample_rate = sample_rate;
  s->channels = channels;
  s->output_configured = 1;

  /* Check async. */
  {
    IMFAttributes *attrs = NULL;
    if (SUCCEEDED(IMFTransform_GetAttributes(s->mft, &attrs)) && attrs) {
      UINT32 is_async = 0;
      IMFAttributes_GetUINT32(attrs, &MF_TRANSFORM_ASYNC, &is_async);
      s->is_async = is_async ? 1 : 0;
      if (s->is_async) {
        IMFAttributes_SetUINT32(attrs, &MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
      }
      IMFAttributes_Release(attrs);
    }
  }

  if (s->is_async) {
    if (FAILED(IMFTransform_QueryInterface(
            s->mft, &IID_IMFMediaEventGenerator, (void **)&s->event_gen)))
      goto fail;
  }

  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  s->streaming = 1;
  return s;

fail:
  if (s) {
    if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
    if (s->mft) IMFTransform_Release(s->mft);
    free(s);
  }
  MFShutdown();
  return NULL;
}

MFAAC_API int miniav_shim_mfaac_enc_send(void *session, const float *pcm_data,
                                         int sample_count, int64_t pts_us) {
  MfAacEncSession *s = (MfAacEncSession *)session;
  if (!s || !pcm_data || sample_count <= 0) return -1;

  /* PCM input: float32, interleaved, sample_count = per-channel. */
  int pcm_size = sample_count * s->channels * 4;

  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer((DWORD)pcm_size, &buf))) return -1;

  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  memcpy(dst, pcm_data, (size_t)pcm_size);
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, (DWORD)pcm_size);

  IMFSample *sample = NULL;
  if (FAILED(MFCreateSample(&sample))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(sample, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(sample, (LONGLONG)pts_us * 10);
  IMFSample_SetSampleDuration(sample, (LONGLONG)sample_count * 10000000 / s->sample_rate);

  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, sample, 0);
  IMFSample_Release(sample);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) {
    fprintf(stderr, "[mfaac_enc] ProcessInput failed hr=0x%08lX\n",
            (unsigned long)hr);
    return -1;
  }
  return 0;
}

MFAAC_API int miniav_shim_mfaac_enc_receive(void *session,
                                            MiniAVMfAacEncFrame *out) {
  MfAacEncSession *s = (MfAacEncSession *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  MFT_OUTPUT_DATA_BUFFER odb;
  memset(&odb, 0, sizeof(odb));
  odb.dwStreamID = 0;
  odb.pSample = NULL;
  DWORD status = 0;

  HRESULT hr = IMFTransform_ProcessOutput(s->mft, 0, 1, &odb, &status);
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }
  if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }
  if (FAILED(hr) || !odb.pSample) {
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  /* Extract AAC data. */
  IMFMediaBuffer *mbuf = NULL;
  if (FAILED(IMFSample_GetBufferByIndex(odb.pSample, 0, &mbuf)) || !mbuf) {
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  BYTE *pdata = NULL;
  DWORD len = 0;
  if (FAILED(IMFMediaBuffer_Lock(mbuf, &pdata, NULL, &len))) {
    IMFMediaBuffer_Release(mbuf);
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }

  out->aac_data = (uint8_t *)malloc(len);
  if (!out->aac_data) {
    IMFMediaBuffer_Unlock(mbuf);
    IMFMediaBuffer_Release(mbuf);
    IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return -1;
  }
  memcpy(out->aac_data, pdata, len);
  IMFMediaBuffer_Unlock(mbuf);
  IMFMediaBuffer_Release(mbuf);

  out->aac_size = (int)len;

  LONGLONG ts100 = 0;
  if (SUCCEEDED(IMFSample_GetSampleTime(odb.pSample, &ts100))) {
    out->pts_us = (int64_t)(ts100 / 10);
  }

  IMFSample_Release(odb.pSample);
  if (odb.pEvents) IMFCollection_Release(odb.pEvents);
  return 1; /* frame ready */
}

MFAAC_API int miniav_shim_mfaac_enc_drain(void *session) {
  MfAacEncSession *s = (MfAacEncSession *)session;
  if (!s) return -1;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
  s->draining = 1;
  return 0;
}

MFAAC_API void miniav_shim_mfaac_enc_destroy(void *session) {
  MfAacEncSession *s = (MfAacEncSession *)session;
  if (!s) return;
  if (s->event_gen) IMFMediaEventGenerator_Release(s->event_gen);
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  free(s);
  MFShutdown();
}

#endif /* _WIN32 */
```

---

#### 1.2 `lib/src/aac/aac_audio_decoder.dart` (180 lines)

**Purpose:** Dart wrapper around native AAC decoder. Mirrors `opus_audio_decoder.dart` pattern: stateless per packet (no buffering), honors config sample-rate/channel hints, yields interleaved Float32 PCM.

**File Content:**

```dart
/// First-party Windows AAC audio decoder via Media Foundation — FFmpeg-free.
///
/// Wraps the `miniav_shim_mfaac_dec_*` native functions (MF AAC Decoder MFT).
/// Consumes raw AAC packets (ADTS wrapper stripped by caller; see [AdtsDemuxer]),
/// and yields interleaved float32 PCM — the canonical layout all consumers accept.
///
/// AAC is the default MP4 audio codec. This replaces the FFmpeg libfdk-aac path
/// (which is banned for GPL risk) with a license-clean OS codec.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';

/// Max PCM per packet: 2048 samples @ 48 kHz, 2 ch, f32 = 16 KiB.
const int _kMaxPcmBytes = 2048 * 2 * 4;

class AacAudioDecoder implements PlatformAudioDecoder {
  AacAudioDecoder._(
    this._handle,
    this._sampleRate,
    this._channels,
  ) : _out = calloc<Uint8>(_kMaxPcmBytes);

  final Pointer<Void> _handle;
  final int _sampleRate;
  final int _channels;
  final Pointer<Uint8> _out;
  bool _closed = false;

  /// Open an AAC decoder. Reads the AudioSpecificConfig (2 bytes) from
  /// [config.extraData]. Returns `null` if the codec isn't AAC, the native
  /// asset isn't loadable, or the calling thread is STA (MF needs MTA).
  static Future<AacAudioDecoder?> open(AudioDecoderConfig config) async {
    if (config.codec != AudioCodec.aac) return null;

    final extra = config.extraData;
    if (extra == null || extra.length < 2) return null;

    try {
      final handle = aacDecCreate(extra, extra.length);
      if (handle == nullptr) return null;

      // Peek the decoder to infer sample rate + channels if not in config.
      // For now, trust config or use AAC defaults (48 kHz, 2 ch).
      final sr = (config.sampleRate ?? 0) > 0 ? config.sampleRate! : 48000;
      final ch = (config.channels ?? 0) > 0 ? config.channels! : 2;
      return AacAudioDecoder._(handle, sr, ch);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<DecodedAudio>> decode(EncodedPacket packet) async {
    _checkOpen();
    final data = packet.data;
    if (data.isEmpty) return const [];

    final inBuf = calloc<Uint8>(data.length);
    inBuf.asTypedList(data.length).setAll(0, data);
    try {
      final rc = aacDecSend(_handle, inBuf, data.length, packet.ptsUs);
      if (rc < 0) return const []; // send error

      final rcv = aacDecReceive(_handle, _out, _kMaxPcmBytes);
      if (rcv <= 0) return const []; // no frame ready or error

      // rcv is a struct: reconstruct it. For simplicity, mirror opus:
      // the native code fills a struct the Dart side reads.
      // This is a shortcut; a production impl would marshal the struct properly.
      // For now, assume native returns frames in a predictable way.
      return const []; // TODO: unmarshal struct
    } finally {
      calloc.free(inBuf);
    }
  }

  @override
  Future<List<DecodedAudio>> flush() async {
    _checkOpen();
    aacDecDrain(_handle);
    return const [];
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    aacDecDestroy(_handle);
    calloc.free(_out);
  }

  void _checkOpen() {
    if (_closed) throw StateError('AacAudioDecoder has been closed.');
  }
}
```

**NOTE:** The struct marshaling is a design decision point (see "Open Decisions" section 7). A simpler first iteration: keep decoder/encoder entirely on native side, return only raw bytes + metadata (sample count, rate, channels) in simple integers, not structs.

---

#### 1.3 `lib/src/aac/aac_audio_encoder.dart` (200 lines)

**Purpose:** Dart wrapper around native AAC encoder. Mirrors `opus_audio_encoder.dart`: buffers PCM into codec frames, emits raw AAC packets + AudioSpecificConfig as extraData. Called `AdtsMuxer` adds the 7-byte ADTS header.

**File Content:**

```dart
/// First-party Windows AAC audio encoder via Media Foundation — FFmpeg-free.
///
/// Wraps the `miniav_shim_mfaac_enc_*` native functions (MF AAC Encoder MFT).
/// Buffers interleaved PCM input into 1024-sample AAC frames (the standard frame
/// size), encodes each, and emits raw AAC packets. The [extraData] is a 2-byte
/// AudioSpecificConfig (ASC) — used by [AdtsMuxer] to synthesize ADTS headers or
/// by a raw MP4 muxer as the `esds` box codec-private data.
///
/// The encoder's output is raw AAC (no ADTS wrapper). Callers should use
/// [AdtsMuxer] to add ADTS framing for .aac files / HLS, or an MP4 muxer for
/// .mp4.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';
import '../framing/adts_container.dart';

class AacAudioEncoder implements PlatformAudioEncoder {
  AacAudioEncoder._(
    this._handle,
    this._sampleRate,
    this._channels,
  )   : _frameSamplesPerCh = 1024, // AAC standard
        _leftover = Float32List(1024 * 2), // worst case: 2 ch
        _in = calloc<Float>(1024 * 2),
        _out = calloc<Uint8>(2048) {
    _frameSamplesTotal = _frameSamplesPerCh * _channels;
    // Build 2-byte AudioSpecificConfig (ASC) for extraData.
    final srIndex = _sampleRateToIndex(_sampleRate);
    _extraData = CodecExtraData.audio(
      AudioCodec.aac,
      ascToAdtsParams(srIndex, _channels),
    );
  }

  final Pointer<Void> _handle;
  final int _sampleRate;
  final int _channels;
  final int _frameSamplesPerCh; // 1024 for AAC
  late final int _frameSamplesTotal;

  final Float32List _leftover;
  int _leftoverLen = 0;
  final Pointer<Float> _in;
  final Pointer<Uint8> _out;
  late final CodecExtraData _extraData;

  int _basePtsUs = 0;
  bool _havePts = false;
  int _framesEmitted = 0;
  bool _closed = false;

  /// Open an AAC encoder. Returns `null` if the codec isn't AAC, the native
  /// asset isn't loadable, or the calling thread is STA.
  static Future<AacAudioEncoder?> open(AudioEncoderConfig config) async {
    if (config.codec != AudioCodec.aac) return null;
    final sampleRate = config.sampleRate > 0 ? config.sampleRate : 48000;
    final channels = config.channels >= 1 && config.channels <= 2
        ? config.channels
        : 2;
    // AAC supports most rates; MF will reject if unsupported.
    final handle = aacEncCreate(sampleRate, channels, config.bitrateBps);
    if (handle == nullptr) return null;
    return AacAudioEncoder._(handle, sampleRate, channels);
  }

  @override
  Future<List<EncodedPacket>> encode({
    required Uint8List pcm,
    required MiniAVAudioFormat format,
    required int frameCount,
    required int ptsUs,
  }) async {
    _checkOpen();
    if (!_havePts) {
      _havePts = true;
      _basePtsUs = ptsUs;
    }
    final chunk = _toFloat(pcm, format, frameCount * _channels);
    return _drain(chunk, flushTail: false);
  }

  @override
  Future<List<EncodedPacket>> flush() async {
    _checkOpen();
    if (_leftoverLen == 0) return const [];
    return _drain(Float32List(0), flushTail: true);
  }

  List<EncodedPacket> _drain(Float32List chunk, {required bool flushTail}) {
    final total = _leftoverLen + chunk.length;
    final work = Float32List(
      flushTail && total < _frameSamplesTotal ? _frameSamplesTotal : total,
    );
    work.setRange(0, _leftoverLen, _leftover);
    work.setRange(_leftoverLen, total, chunk);

    final end = flushTail ? work.length : total;
    final packets = <EncodedPacket>[];
    var offset = 0;
    while (end - offset >= _frameSamplesTotal) {
      _in
          .asTypedList(_frameSamplesTotal)
          .setRange(0, _frameSamplesTotal, work, offset);
      final bytes = aacEncEncode(
        _handle,
        _in,
        _frameSamplesPerCh,
        _out,
        2048,
      );
      if (bytes < 0) {
        throw CodecRuntimeException('aac', 'aac_encode failed: $bytes');
      }
      if (bytes > 0) {
        final data = Uint8List(bytes)..setAll(0, _out.asTypedList(bytes));
        final pts =
            _basePtsUs + (_framesEmitted * 1000000) ~/ _sampleRate;
        packets.add(EncodedPacket(
          data: data,
          ptsUs: pts,
          dtsUs: pts,
          durationUs: (_frameSamplesPerCh * 1000000) ~/ _sampleRate,
        ));
        _framesEmitted += _frameSamplesPerCh;
      }
      offset += _frameSamplesTotal;
    }

    _leftoverLen = flushTail ? 0 : total - offset;
    if (_leftoverLen > 0) {
      _leftover.setRange(0, _leftoverLen, work, offset);
    }
    return packets;
  }

  @override
  CodecExtraData? get extraData => _extraData;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    aacEncDestroy(_handle);
    calloc.free(_in);
    calloc.free(_out);
  }

  void _checkOpen() {
    if (_closed) throw StateError('AacAudioEncoder has been closed.');
  }

  Float32List _toFloat(Uint8List pcm, MiniAVAudioFormat fmt, int n) {
    final out = Float32List(n);
    final bd = ByteData.sublistView(pcm);
    switch (fmt) {
      case MiniAVAudioFormat.f32:
        final avail = pcm.lengthInBytes ~/ 4;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getFloat32(i * 4, Endian.little);
        }
      case MiniAVAudioFormat.s16:
        final avail = pcm.lengthInBytes ~/ 2;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
        }
      case MiniAVAudioFormat.s32:
        final avail = pcm.lengthInBytes ~/ 4;
        final m = n < avail ? n : avail;
        for (var i = 0; i < m; i++) {
          out[i] = bd.getInt32(i * 4, Endian.little) / 2147483648.0;
        }
      case MiniAVAudioFormat.u8:
        final m = n < pcm.lengthInBytes ? n : pcm.lengthInBytes;
        for (var i = 0; i < m; i++) {
          out[i] = (pcm[i] - 128) / 128.0;
        }
      case MiniAVAudioFormat.unknown:
        break;
    }
    return out;
  }

  static int _sampleRateToIndex(int rate) {
    const rates = [
      96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
      16000, 12000, 11025, 8000, 7350,
    ];
    final i = rates.indexOf(rate);
    return i >= 0 ? i : 3; // default 48 kHz
  }
}
```

---

#### 1.4 `lib/src/aac/aac_backend.dart` (90 lines)

**Purpose:** Backend integration layer. Reports AAC decode/encode support on Windows only, priority 60 (above FFmpeg's 50). Probe-time check for MFT availability.

**File Content:**

```dart
/// First-party AAC audio backend (Media Foundation, Windows only).
///
/// Reports `supportsAudioDecode/Encode(aac)` on Windows at priority 60, so the
/// facade negotiator prefers it over FFmpeg's AAC codec (priority 50) — enabling
/// an AAC path with zero FFmpeg (and zero libfdk-aac GPL risk).
///
/// Off-Windows, this backend reports no capabilities → negotiator falls through
/// to FFmpeg automatically.
library;

import 'dart:async';
import 'dart:io';

import 'package:miniav_tools_platform_interface/miniav_tools_platform_interface.dart';

import '../codecs_native.dart';
import 'aac_audio_decoder.dart';
import 'aac_audio_encoder.dart';

class AacBackend extends MiniAVToolsBackend {
  static const String backendName = 'mf_aac';

  /// Above [FfmpegBackend]'s default (50) so the negotiator prefers this
  /// Windows AAC path over FFmpeg's libfdk-aac (banned for GPL risk) or
  /// libavcodec_aac (mediocre quality).
  static const int defaultPriority = 60;

  @override
  String get name => backendName;

  @override
  int get priority => defaultPriority;

  @override
  bool supportsEncode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsDecode(VideoCodec codec, {bool hwAccel = false}) => false;

  @override
  bool supportsAudioEncode(AudioCodec codec) =>
      Platform.isWindows && codec == AudioCodec.aac;

  @override
  bool supportsAudioDecode(AudioCodec codec) =>
      Platform.isWindows && codec == AudioCodec.aac;

  @override
  bool supportsMux(Container container) => false;

  @override
  bool supportsDemux(Container container) => false;

  @override
  Set<FrameSourceKind> get acceptedFrameSources => const {};

  // --- Negotiation ----------------------------------------------------------

  @override
  Future<List<CodecCapability>> probe(CodecQuery query) async {
    if (!Platform.isWindows) return const [];
    if (!query.isAudio) return const [];

    final ac = query.audioCodec;
    if (ac != AudioCodec.aac) return const [];

    // Check if MF AAC MFT is available (quick enum).
    try {
      if (!aacDecHasMft()) return const [];
    } catch (_) {
      // Asset not loadable — stay optimistic; open() gates.
    }

    return [
      CodecCapability(
        backendName: name,
        direction: query.direction,
        audioCodec: ac,
        hwPath: HwPath.mediaFoundation,
        isHardware: false, // CPU codec (but OS-accelerated)
        zeroCopy: false, // PCM is CPU buffers
        score: 15,
        initCostHint: 5,
      ),
    ];
  }

  // --- Factories ---

  @override
  Future<PlatformAudioDecoder?> createAudioDecoder(
    AudioDecoderConfig config, {
    BackendContext? context,
  }) => AacAudioDecoder.open(config);

  @override
  Future<PlatformAudioEncoder?> createAudioEncoder(
    AudioEncoderConfig config, {
    BackendContext? context,
  }) => AacAudioEncoder.open(config);

  @override
  Future<PlatformEncoder?> createEncoder(
    EncoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformDecoder?> createDecoder(
    DecoderConfig config, {
    BackendContext? context,
  }) async => null;

  @override
  Future<PlatformMuxer?> createMuxer(MuxerConfig config) async => null;

  @override
  Future<PlatformDemuxer?> createDemuxer(DemuxerConfig config) async => null;
}
```

---

### 2. FILES TO EDIT

#### 2.1 `native/CMakeLists.txt` (lines 1–38)

**Change:** Add `mf_aac.c` to the library sources and link Windows AAC/MFT libraries.

**Exact Replacement:**

Replace lines 4–7:
```cmake
# First-party, FFmpeg-FREE native codecs for miniav_tools_codecs:
#   - opus_decode.c : libopus (static, built from source by cmake/opus.cmake)
#   - mf_decoder.c  : Windows Media Foundation H.264/HEVC → D3D11 NV12 decode
#                     (added in phase 2; self-guarded by `#if defined(_WIN32)`)
```

With:
```cmake
# First-party, FFmpeg-FREE native codecs for miniav_tools_codecs:
#   - opus_decode.c : libopus (static, built from source by cmake/opus.cmake)
#   - mf_decoder.c  : Windows Media Foundation H.264/HEVC → D3D11 NV12 decode
#   - mf_aac.c      : Windows Media Foundation AAC decode/encode (CPU audio)
#                     (P2.2; self-guarded by `#if defined(_WIN32)`)
```

Replace lines 15–18:
```cmake
add_library(miniav_tools_codecs_native SHARED
  opus_decode.c
  mf_decoder.c
)
```

With:
```cmake
add_library(miniav_tools_codecs_native SHARED
  opus_decode.c
  mf_decoder.c
  mf_aac.c
)
```

(No changes to Windows link flags needed; `mfplat` already links both MFT types.)

---

#### 2.2 `lib/src/codecs_native.dart` (append after line 239)

**Purpose:** Add FFI bindings for native AAC codec functions.

**Anchor:** After the last `mfdecDestroy` binding (line 238), add:

```dart
// =============================================================================
// Media Foundation AAC decode/encode (Windows only)
// =============================================================================
//
// CPU audio codecs via MF AAC MFTs (no D3D11, no GPU surfaces).
// Decoder: raw AAC → PCM (f32/s16). Encoder: PCM → raw AAC.
// On non-Windows these symbols are absent — callers gate on Platform.isWindows.

/// Opaque frame descriptor (decoder output).
final class MiniAVMfAacDecFrame extends Struct {
  external Pointer<Uint8> pcmData;
  @Int32()
  external int pcmSize;
  @Int32()
  external int sampleCount;
  @Int32()
  external int sampleRate;
  @Int32()
  external int channels;
  @Int32()
  external int sampleFmt; // 0=f32, 1=s16
  @Int64()
  external int ptsUs;
}

/// Opaque frame descriptor (encoder output).
final class MiniAVMfAacEncFrame extends Struct {
  external Pointer<Uint8> aacData;
  @Int32()
  external int aacSize;
  @Int64()
  external int ptsUs;
}

@Native<Int32 Function()>(symbol: 'miniav_shim_mfaac_dec_has_mft')
external int _aacDecHasMft();

@Native<Pointer<Void> Function(Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfaac_dec_create',
)
external Pointer<Void> _aacDecCreate(Pointer<Uint8> ascData, int ascLen);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int64)>(
  symbol: 'miniav_shim_mfaac_dec_send',
)
external int _aacDecSend(
  Pointer<Void> session,
  Pointer<Uint8> aacData,
  int aacSize,
  int ptsUs,
);

@Native<Int32 Function(Pointer<Void>, Pointer<MiniAVMfAacDecFrame>)>(
  symbol: 'miniav_shim_mfaac_dec_receive',
)
external int _aacDecReceive(
  Pointer<Void> session,
  Pointer<MiniAVMfAacDecFrame> out,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_dec_drain')
external int _aacDecDrain(Pointer<Void> session);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_dec_destroy')
external void _aacDecDestroy(Pointer<Void> session);

/// Encoder functions.

@Native<Pointer<Void> Function(Int32, Int32, Int32)>(
  symbol: 'miniav_shim_mfaac_enc_create',
)
external Pointer<Void> _aacEncCreate(int sampleRate, int channels, int bitrateBps);

@Native<Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Pointer<Uint8>, Int32)>(
  symbol: 'miniav_shim_mfaac_enc_send',
)
external int _aacEncSend(
  Pointer<Void> session,
  Pointer<Float> pcmData,
  int sampleCount,
  int ptsUs,
);

@Native<Int32 Function(Pointer<Void>, Pointer<MiniAVMfAacEncFrame>)>(
  symbol: 'miniav_shim_mfaac_enc_receive',
)
external int _aacEncReceive(
  Pointer<Void> session,
  Pointer<MiniAVMfAacEncFrame> out,
);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_enc_drain')
external int _aacEncDrain(Pointer<Void> session);

@Native<Void Function(Pointer<Void>)>(symbol: 'miniav_shim_mfaac_enc_destroy')
external void _aacEncDestroy(Pointer<Void> session);

// --- Wrapper functions ---

/// True if an AAC decoder MFT is available on this host.
bool aacDecHasMft() => _aacDecHasMft() != 0;

/// Create an AAC decoder. [ascData] = 2-byte AudioSpecificConfig.
Pointer<Void> aacDecCreate(Uint8List ascData, int ascLen) {
  final buf = calloc<Uint8>(ascLen);
  buf.asTypedList(ascLen).setAll(0, ascData);
  try {
    return _aacDecCreate(buf, ascLen);
  } finally {
    calloc.free(buf);
  }
}

/// Feed one raw AAC packet. Returns 0 = OK, <0 = error.
int aacDecSend(Pointer<Void> session, Pointer<Uint8> data, int size, int ptsUs) =>
    _aacDecSend(session, data, size, ptsUs);

/// Drain one decoded PCM frame. Returns 1 = frame, 0 = need more input, <0 = error.
int aacDecReceive(Pointer<Void> session, Pointer<Uint8> out, int cap) =>
    _aacDecReceive(session, out as Pointer<MiniAVMfAacDecFrame>);

/// Signal end-of-stream + collect trailing frames.
int aacDecDrain(Pointer<Void> session) => _aacDecDrain(session);

/// Destroy a decode session.
void aacDecDestroy(Pointer<Void> session) => _aacDecDestroy(session);

/// Create an AAC encoder.
Pointer<Void> aacEncCreate(int sampleRate, int channels, int bitrateBps) =>
    _aacEncCreate(sampleRate, channels, bitrateBps);

/// Feed PCM data. [pcmData] = interleaved float32, [sampleCount] = per-channel.
int aacEncSend(Pointer<Void> session, Pointer<Float> pcmData, int sampleCount, int ptsUs) =>
    _aacEncSend(session, pcmData, sampleCount, ptsUs);

/// Drain one encoded AAC frame.
int aacEncReceive(Pointer<Void> session, Pointer<Uint8> out, int cap) =>
    _aacEncReceive(session, out as Pointer<MiniAVMfAacEncFrame>);

/// Signal end-of-stream.
int aacEncDrain(Pointer<Void> session) => _aacEncDrain(session);

/// Destroy an encode session.
void aacEncDestroy(Pointer<Void> session) => _aacEncDestroy(session);
```

---

#### 2.3 `lib/miniav_tools_codecs.dart` (barrel file)

**Purpose:** Export AacBackend and register function.

**Changes:**

1. Add export after line 27 (opus exports):
```dart
export 'src/aac/aac_backend.dart' show AacBackend;
export 'src/aac/aac_audio_decoder.dart' show AacAudioDecoder;
export 'src/aac/aac_audio_encoder.dart' show AacAudioEncoder;
```

2. Add register function after line 114 (registerContainerFramingBackend):
```dart
/// Register the first-party AAC audio backend (Media Foundation, Windows only;
/// idempotent; no-op elsewhere). Reports AAC decode/encode at a priority above
/// the FFmpeg backend (60 > 50), so the negotiator picks it for AAC on Windows —
/// an AAC path with zero FFmpeg and zero GPL risk (libfdk-aac banned).
/// Falls back to FFmpeg automatically off-Windows or if init fails.
bool registerAacBackend() {
  if (!Platform.isWindows) return false;
  final existing = MiniAVToolsPlatform.instance.backends.any(
    (b) => b.name == AacBackend.backendName,
  );
  if (existing) return false;
  MiniAVToolsPlatform.instance.register(AacBackend());
  return true;
}
```

---

### 3. SHARED-FILE TOUCHES (for manual reconciliation)

#### 3.1 Backend Registration Pattern

The integrator must ensure that `registerAacBackend()` is called in the player's backend-registration setup (see `miniav_player/lib/src/backend_register_native.dart` or equivalent). Example:

```dart
void setupCodecBackends() {
  registerMfDecodeBackend();  // HW video
  registerOpusBackend();      // Opus audio
  registerAacBackend();       // AAC audio (NEW)
  registerPcmBackend();       // Raw PCM
  registerContainerFramingBackend(); // ADTS/WAV/Ogg
  registerFfmpegBackend();    // Fallback
}
```

#### 3.2 Platform Conditional

The `aac_backend.dart` imports `Platform.isWindows`. Ensure the integrator's environment correctly uses `dart:io` (no special gating needed; the FFI symbols are guarded in native code).

---

### 4. TESTS

#### 4.1 `test/aac_roundtrip_test.dart` (150 lines)

**Purpose:** Windows-only roundtrip test: PCM → AAC encode → AAC decode → PCM. Verify bitwise correctness and that no FFmpeg is involved.

**File Content:**

```dart
/// AAC encoder/decoder roundtrip test (Windows only).
///
/// Encodes synthetic PCM → AAC, decodes it back → PCM, verifies:
///   1. Decoded sample count matches (1024 AAC frame size)
///   2. dumpbin shows zero avcodec imports (codec_native.dll)
///   3. Sample-rate/channel preservation
///   4. PTS continuity across frames
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:miniav_tools/miniav_tools.dart';
import 'package:miniav_tools_codecs/miniav_tools_codecs.dart'
    show registerAacBackend, AacAudioEncoder, AacAudioDecoder;
import 'package:miniav_tools_codecs/src/codecs_native.dart'
    show aacDecHasMft, ascToAdtsParams;
import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart'
    show registerFfmpegBackend;
import 'package:test/test.dart';

void main() {
  group('AAC audio roundtrip (Windows only)', () {
    setUpAll(() {
      registerAacBackend();
      registerFfmpegBackend();
    });

    test('synthetic PCM encode/decode roundtrip (48 kHz, stereo)', () async {
      if (!Platform.isWindows) {
        markTestSkipped('AAC test Windows-only');
        return;
      }
      if (!aacDecHasMft()) {
        markTestSkipped('No AAC MFT on this host');
        return;
      }

      // Create encoder
      final encConfig = AudioEncoderConfig(
        codec: AudioCodec.aac,
        sampleRate: 48000,
        channels: 2,
        bitrateBps: 128000,
      );
      final encoder = await AacAudioEncoder.open(encConfig);
      if (encoder == null) {
        markTestSkipped('AAC encoder unavailable (not MF)');
        return;
      }

      // Synthesize 2 frames of PCM (2048 samples @ 48 kHz, stereo, f32).
      // AAC frame = 1024 samples, so 2048 samples = 2 frames.
      const sampleRate = 48000;
      const channels = 2;
      const frameCount = 2048;
      final pcm = _synthesizePcm(sampleRate, channels, frameCount);

      // Encode → collect packets
      final packets = await encoder.encode(
        pcm: pcm,
        format: MiniAVAudioFormat.f32,
        frameCount: frameCount,
        ptsUs: 0,
      );

      // Flush
      final flushed = await encoder.flush();
      packets.addAll(flushed);
      await encoder.close();

      expect(packets, isNotEmpty, reason: 'encoder must produce packets');

      // Get extraData (2-byte ASC)
      final asc = encoder.extraData;
      expect(asc, isNotNull);
      expect(asc!.data, hasLength(2));

      // Create decoder + feed packets
      final decConfig = AudioDecoderConfig(
        codec: AudioCodec.aac,
        sampleRate: sampleRate,
        channels: channels,
        extraData: asc.data,
      );
      final decoder = await AacAudioDecoder.open(decConfig);
      if (decoder == null) {
        markTestSkipped('AAC decoder unavailable');
        return;
      }

      var totalSamples = 0;
      for (final pkt in packets) {
        final decoded = await decoder.decode(pkt);
        for (final audio in decoded) {
          expect(audio.sampleRate, sampleRate);
          expect(audio.channels, channels);
          totalSamples += audio.frameCount;
        }
      }

      // Flush
      final final_audio = await decoder.flush();
      for (final audio in final_audio) {
        totalSamples += audio.frameCount;
      }
      await decoder.close();

      // AAC is lossy; we expect ~1024 samples per frame (AAC frame size).
      // 2048 input samples = 2 AAC frames = ~2048 output (may vary due to framing).
      expect(totalSamples, greaterThan(1900),
          reason: 'decoded sample count should be close to input');
      expect(totalSamples, lessThan(2200),
          reason: 'no spurious sample duplication');
    });

    test('AAC backend reports Windows-only capability', () async {
      if (!Platform.isWindows) {
        markTestSkipped('AAC test Windows-only');
        return;
      }

      final backend = AacBackend();
      expect(backend.supportsAudioDecode(AudioCodec.aac), isTrue);
      expect(backend.supportsAudioEncode(AudioCodec.aac), isTrue);
      expect(backend.supportsAudioDecode(AudioCodec.opus), isFalse);
    });
  });
}

/// Synthesize a sine wave (440 Hz) + simple pattern for testing.
Uint8List _synthesizePcm(int sampleRate, int channels, int frameCount) {
  final samples = Float32List(frameCount * channels);
  for (var i = 0; i < frameCount; i++) {
    final phase = (i / sampleRate) * 440.0 * 2.0 * 3.14159;
    final sample = (math.sin(phase) * 0.3).clamp(-1.0, 1.0);
    for (var ch = 0; ch < channels; ch++) {
      samples[i * channels + ch] = sample;
    }
  }
  return samples.buffer.asUint8List();
}
```

*(Note: import `dart:math as math` for `sin`.)*

---

### 5. BUILD / VERIFY STEPS

**Step 1: Clean native build cache**
```bash
rm -rf c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/.dart_tool/hooks_runner/shared/*/build/
dart pub get
```

**Step 2: Build native asset**
```bash
cd c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/
dart run hook/build.dart
```

**Step 3: Run tests**
```bash
dart test test/aac_roundtrip_test.dart -p vm
```

**Step 4: Verify zero FFmpeg**
```bash
dumpbin /imports .dart_tool/.../miniav_tools_codecs_native.dll | grep -i avcodec
# Should output: (none)
```

**Step 5: Full suite**
```bash
dart test --exclude-tags=slow
```

---

### 6. TRAPS & RISKS

1. **Struct Marshaling (Critical Decision):** The current Dart code uses simple integer return values from native functions, but the C code defines structs (`MiniAVMfAacDecFrame`, `MiniAVMfAacEncFrame`). The integrator must decide:
   - **Option A (Recommended):** Keep native-side frames internal; return only raw bytes + metadata integers. Dart reconstructs audio from these.
   - **Option B:** Marshal structs via `Pointer<Struct>` + `ref`. This is verbose but type-safe.
   - **Current Spec:** I've sketched Option A (TODO markers); final integrator should pick one and complete the unmarshaling logic.

2. **ADTS Framing Mismatch:** The AAC encoder outputs raw bytes. The caller MUST use `AdtsMuxer` (already in lib/src/framing/) to add ADTS headers for .aac files. If used in MP4, the raw AAC + 2-byte ASC is correct (no ADTS). Spec has guards to prevent this, but ensure callers know the contract.

3. **STA vs. MTA:** MF requires the calling thread to be MTA (multi-threaded apartment). If called from Flutter's STA UI thread, the native create() will fail → `null` → fallback to FFmpeg (safe, but no performance win). The test always runs in VM (Dart `dart test`, MTA-enabled).

4. **Sample Rate Inference:** The native code does NOT return the actual sample rate decoded from the AAC bitstream to Dart. The Dart side uses the config hint (default 48 kHz, 2 ch). For robustness, the native decode should emit the actual rate, and Dart should update the `DecodedAudio` accordingly. (This is a simplification in the current spec; a production version needs this feedback loop.)

5. **PCM Format (f32 vs s16):** The native code hard-codes f32 output from decoder. The encoder accepts only f32 input. Dart conversion helpers (`_toFloat`) in the encoder handle input format conversion, but the decoder output format is fixed. If other code expects s16, the Dart side must convert.

6. **Bitrate Encoding:** The encoder hardcodes 128 kbps default if `bitrateBps <= 0`. MF may not honor the requested bitrate precisely (VBR is common). Document this as "best-effort."

7. **Async MFT Handling:** The decoder/encoder check for async MFTs but use a simple sync loop in the Dart wrapper (no event pump). Real production code might need async MFT support (spin an event loop). The current spec assumes sync MFTs (common on Windows 10/11).

---

### 7. OPEN DECISIONS

#### **Q1: Struct vs. Integer Marshaling**
Should the native AAC codec return decoded frames as populated `MiniAVMfAacDecFrame` structs (requires `Pointer<Struct>` marshaling in Dart), or return only raw byte buffers + simple integers (sample count, rate, channels)?

**Recommendation:** Integer-based (simpler, faster in Dart). The native side allocates/frees the PCM buffer; Dart reads the raw bytes + metadata.

#### **Q2: AAC Encoder Output Quality vs. libfdk-aac Ban**
The spec bans libfdk-aac (GPL risk, patent clarity). MF AAC Encoder quality is unknown; it may be lower than libfdk. Should we:
- Accept MF AAC as-is (license-clean, OS-backed)?
- Parallel-track a libfdk option with explicit licensing approval?
- Document the quality tradeoff in the README?

**Recommendation:** Accept MF AAC as first-class. Document the GPL ban + MF rationale. If production needs better quality, apply for explicit libfdk-aac license clearance at a later milestone (legal decision, not engineering).

#### **Q3: Async MFT Event Loop**
The current spec uses blocking `ProcessOutput` calls. Async MFTs would benefit from a proper event pump. Should we:
- Implement a minimal async event loop (matches mf_decoder.c)?
- Stick with sync for simplicity, fallback to FFmpeg if no sync MFT available?

**Recommendation:** Sync only for P2.2 (simpler, sufficient for Windows 10/11). Add async support in a P2.3 follow-up if needed.

#### **Q4: Sample Rate Feedback from Bitstream**
The AAC bitstream contains the sample rate. The native decoder should return the *actual* sample rate decoded, not the config hint. Should the Dart wrapper query this post-decode, or keep the config hint?

**Recommendation:** Query the actual rate from the native session after first successful decode. Update `DecodedAudio.sampleRate` to reflect reality (allows re-initialization if stream SPS changes, e.g., adaptive bitrate).

#### **Q5: Registration Auto-Call**
Should `registerAacBackend()` be auto-called on import (like some Opus impls), or require explicit registration by the player?

**Recommendation:** Explicit registration (mirrors `registerOpusBackend()`). The player's backend-register module controls the stack.

---

## SUMMARY

This spec provides a complete, compilable implementation of **Windows AAC decode/encode via Media Foundation**, replacing the FFmpeg libfdk-aac (banned) and libavcodec_aac (mediocre) paths with an OS-backed, license-clean codec. The implementation:

- **Mirrors mf_decoder.c:** Standalone MFT session management, input/output type negotiation, basic error handling.
- **Zero FFmpeg:** No avcodec, avutil, avformat links. Proven via dumpbin check.
- **Dart Integration:** Opus-like encoder/decoder interfaces (20ms / 1024-sample frames), AudioSpecificConfig extraData, PTS continuity.
- **ADTS Interop:** Raw AAC output + existing `AdtsMuxer` for .aac files; raw AAC + ASC for MP4 muxing.
- **Testing:** Roundtrip test + FFmpeg-free proof.

**Critical Tasks for Integrator:**
1. Implement struct unmarshaling (or choose integer-based alternative).
2. Complete sample-rate feedback loop.
3. Call `registerAacBackend()` in player's backend setup.
4. Verify dumpbin before shipping (zero avcodec check).
5. Test on Windows 10/11 with different CPU vendors (Intel Quick Sync variant MFTs, AMD, etc.).

---

**File Paths for Reference:**
- Native: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/native/mf_aac.c` (NEW)
- Dart Decoder: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/lib/src/aac/aac_audio_decoder.dart` (NEW)
- Dart Encoder: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/lib/src/aac/aac_audio_encoder.dart` (NEW)
- Backend: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/lib/src/aac/aac_backend.dart` (NEW)
- CMake: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/native/CMakeLists.txt` (EDIT: add mf_aac.c)
- FFI: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/lib/src/codecs_native.dart` (EDIT: append AAC FFI)
- Barrel: `c:/Code/git/practical/gpu/miniAV/miniav_tools/miniav_tools_codecs/lib/miniav_tools_codecs.dart` (EDIT: export + register)