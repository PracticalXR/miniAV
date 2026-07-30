/* mf_aac.c — Windows Media Foundation AAC decode + encode (audio, CPU PCM).
 *
 * Mirrors mf_decoder.c's MFT session model but for audio: no D3D11, CPU PCM
 * in/out, sync MFTs. Zero FFmpeg — the OS AAC MFTs are license-clean (the
 * banned option is libfdk-aac/GPL).
 *
 *   Decoder: raw AAC (+ AudioSpecificConfig) -> interleaved float32 PCM.
 *   Encoder: interleaved float32 PCM -> raw AAC (+ the encoder's ASC).
 *
 * ADTS framing (7/9-byte headers) is added/stripped in Dart (AdtsMuxer /
 * AdtsDemuxer); this layer speaks raw AAC access units + a 2-byte ASC, which is
 * exactly what MP4 (esds) and the negotiator want.
 *
 * Gotchas handled here that a naive port gets wrong:
 *   - The MS AAC *decoder* input MF_MT_USER_DATA is NOT the bare ASC: it is the
 *     12-byte tail of HEAACWAVEINFO (wPayloadType..wReserved2) followed by the
 *     ASC. wPayloadType = 0 (raw AAC access units).
 *   - The MS AAC *encoder* input is 16-bit PCM ONLY (not float); we convert
 *     f32 -> s16 before ProcessInput.
 *   - The encoder's ASC is read back from the output type's MF_MT_USER_DATA
 *     (same 12-byte-tail + ASC layout).
 */

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MFAAC_API __declspec(dllexport)

/* Set MFAAC_DEBUG=1 in the env to trace the MF flow. */
static int mfaac_dbg(void) {
  static int v = -1;
  if (v < 0) {
    char b[8] = {0};
    DWORD n = GetEnvironmentVariableA("MFAAC_DEBUG", b, sizeof(b));
    v = (n > 0 && b[0] == '1') ? 1 : 0;
  }
  return v;
}
#define DBG(...) \
  do {          \
    if (mfaac_dbg()) fprintf(stderr, __VA_ARGS__); \
  } while (0)

/* HEAACWAVEINFO tail (the bytes after WAVEFORMATEX): wPayloadType(2) +
 * wAudioProfileLevelIndication(2) + wStructType(2) + wReserved1(2) +
 * wReserved2(4) = 12 bytes. */
#define HEAAC_TAIL 12

typedef struct {
  uint8_t *pcm_data; /* malloc'd interleaved f32; caller frees */
  int pcm_size;      /* bytes */
  int sample_count;  /* per-channel */
  int sample_rate;
  int channels;
  int sample_fmt; /* always 0 = f32 */
  int64_t pts_us;
} MiniAVMfAacDecFrame;

typedef struct {
  uint8_t *aac_data; /* malloc'd raw AAC AU; caller frees */
  int aac_size;
  int64_t pts_us;
} MiniAVMfAacEncFrame;

typedef struct {
  IMFTransform *mft;
  int sample_rate;
  int channels;
} MfAacDec;

typedef struct {
  IMFTransform *mft;
  int sample_rate;
  int channels;
  uint8_t asc[64];
  int asc_len;
} MfAacEnc;

/* ===== helpers ============================================================ */

static int mfaac_started; /* refcount-ish: keep MF up while any session lives */

static int mf_up(void) {
  HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (co == RPC_E_CHANGED_MODE) return -1; /* STA — needs the MTA isolate */
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return -1;
  mfaac_started++;
  return 0;
}

static void mf_down(void) {
  if (mfaac_started > 0) {
    mfaac_started--;
    MFShutdown();
  }
}

static IMFTransform *enum_first_mft(const GUID *category, const GUID *inSub,
                                    const GUID *outSub) {
  MFT_REGISTER_TYPE_INFO in = {MFMediaType_Audio, *inSub};
  MFT_REGISTER_TYPE_INFO out = {MFMediaType_Audio, *outSub};
  UINT32 flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
                 MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER;
  IMFActivate **acts = NULL;
  UINT32 count = 0;
  if (FAILED(MFTEnumEx(*category, flags, &in, &out, &acts, &count)) ||
      count == 0) {
    if (acts) CoTaskMemFree(acts);
    return NULL;
  }
  IMFTransform *mft = NULL;
  for (UINT32 i = 0; i < count; i++) {
    if (!mft &&
        FAILED(IMFActivate_ActivateObject(acts[i], &IID_IMFTransform,
                                          (void **)&mft)))
      mft = NULL;
    IMFActivate_Release(acts[i]);
  }
  CoTaskMemFree(acts);
  return mft;
}

/* ===== decoder ============================================================ */

MFAAC_API int miniav_shim_mfaac_dec_has_mft(void) {
  if (mf_up() != 0) return 0;
  IMFTransform *m = enum_first_mft(&MFT_CATEGORY_AUDIO_DECODER,
                                   &MFAudioFormat_AAC, &MFAudioFormat_Float);
  int ok = m != NULL;
  if (m) IMFTransform_Release(m);
  mf_down();
  return ok;
}

MFAAC_API void *miniav_shim_mfaac_dec_create(const uint8_t *asc, int asc_len,
                                             int sample_rate, int channels) {
  if (!asc || asc_len < 2 || channels < 1 || channels > 8) return NULL;
  if (mf_up() != 0) return NULL;

  MfAacDec *s = (MfAacDec *)calloc(1, sizeof(MfAacDec));
  if (!s) {
    mf_down();
    return NULL;
  }
  s->mft = enum_first_mft(&MFT_CATEGORY_AUDIO_DECODER, &MFAudioFormat_AAC,
                          &MFAudioFormat_Float);
  if (!s->mft) goto fail;

  /* Input type: AAC + HEAACWAVEINFO-tail(12) + ASC as MF_MT_USER_DATA. */
  {
    IMFMediaType *it = NULL;
    if (FAILED(MFCreateMediaType(&it))) goto fail;
    IMFMediaType_SetGUID(it, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(it, &MF_MT_SUBTYPE, &MFAudioFormat_AAC);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_SAMPLES_PER_SECOND,
                           (UINT32)sample_rate);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    IMFMediaType_SetUINT32(it, &MF_MT_AAC_PAYLOAD_TYPE, 0); /* raw AAC */

    UINT32 udlen = (UINT32)(HEAAC_TAIL + asc_len);
    uint8_t *ud = (uint8_t *)calloc(1, udlen);
    if (!ud) {
      IMFMediaType_Release(it);
      goto fail;
    }
    /* 12 zero bytes (wPayloadType=0 raw) then the ASC. */
    memcpy(ud + HEAAC_TAIL, asc, (size_t)asc_len);
    HRESULT hr = IMFMediaType_SetBlob(it, &MF_MT_USER_DATA, ud, udlen);
    free(ud);
    if (SUCCEEDED(hr)) hr = IMFTransform_SetInputType(s->mft, 0, it, 0);
    IMFMediaType_Release(it);
    DBG("[mfaac_dec] SetInputType hr=0x%08lX asc_len=%d\n", (unsigned long)hr, asc_len);
    if (FAILED(hr)) goto fail;
  }

  /* Output type: pick the first Float PCM the MFT offers. */
  {
    int done = 0;
    for (DWORD i = 0;; i++) {
      IMFMediaType *ot = NULL;
      HRESULT hr = IMFTransform_GetOutputAvailableType(s->mft, 0, i, &ot);
      if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) break;
      GUID sub = {0};
      IMFMediaType_GetGUID(ot, &MF_MT_SUBTYPE, &sub);
      if (IsEqualGUID(&sub, &MFAudioFormat_Float) &&
          SUCCEEDED(IMFTransform_SetOutputType(s->mft, 0, ot, 0))) {
        UINT32 sr = 0, ch = 0;
        IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
        IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_NUM_CHANNELS, &ch);
        s->sample_rate = sr ? (int)sr : sample_rate;
        s->channels = ch ? (int)ch : channels;
        done = 1;
        IMFMediaType_Release(ot);
        break;
      }
      IMFMediaType_Release(ot);
    }
    DBG("[mfaac_dec] output done=%d sr=%d ch=%d\n", done, s->sample_rate, s->channels);
    if (!done) goto fail;
  }

  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return s;

fail:
  if (s->mft) IMFTransform_Release(s->mft);
  free(s);
  mf_down();
  return NULL;
}

MFAAC_API int miniav_shim_mfaac_dec_send(void *session, const uint8_t *aac,
                                         int aac_size, int64_t pts_us) {
  MfAacDec *s = (MfAacDec *)session;
  if (!s || !aac || aac_size <= 0) return -1;
  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer((DWORD)aac_size, &buf))) return -1;
  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  memcpy(dst, aac, (size_t)aac_size);
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, (DWORD)aac_size);
  IMFSample *smp = NULL;
  if (FAILED(MFCreateSample(&smp))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(smp, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(smp, (LONGLONG)pts_us * 10);
  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, smp, 0);
  IMFSample_Release(smp);
  DBG("[mfaac_dec] ProcessInput hr=0x%08lX size=%d\n", (unsigned long)hr, aac_size);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) return -1;
  return (hr == MF_E_NOTACCEPTING) ? 1 : 0; /* 1 = drain before re-send */
}

/* Pull one PCM chunk. 1 = frame ready, 0 = need more input, -1 = error. */
MFAAC_API int miniav_shim_mfaac_dec_receive(void *session,
                                            MiniAVMfAacDecFrame *out) {
  MfAacDec *s = (MfAacDec *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  /* The MS AAC decoder does NOT allocate its own output samples, so we must
   * provide the PCM buffer (else ProcessOutput returns E_INVALIDARG). */
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
    DWORD cb = si.cbSize > 0 ? si.cbSize : 65536;
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
  DBG("[mfaac_dec] ProcessOutput hr=0x%08lX pSample=%p\n", (unsigned long)hr, (void*)odb.pSample);
  if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (pre) IMFSample_Release(pre);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0;
  }
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    /* The decoder announces its real output format here. Re-select a Float
     * output type (GetOutputCurrentType is not valid mid-change), refresh
     * rate/channels, and signal "retry" (2) so the caller keeps draining — the
     * pending PCM arrives on the NEXT ProcessOutput. */
    for (DWORD i = 0;; i++) {
      IMFMediaType *ot = NULL;
      HRESULT gh = IMFTransform_GetOutputAvailableType(s->mft, 0, i, &ot);
      if (gh == MF_E_NO_MORE_TYPES || FAILED(gh)) break;
      GUID sub = {0};
      IMFMediaType_GetGUID(ot, &MF_MT_SUBTYPE, &sub);
      if (IsEqualGUID(&sub, &MFAudioFormat_Float) &&
          SUCCEEDED(IMFTransform_SetOutputType(s->mft, 0, ot, 0))) {
        UINT32 sr = 0, ch = 0;
        IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
        IMFMediaType_GetUINT32(ot, &MF_MT_AUDIO_NUM_CHANNELS, &ch);
        if (sr) s->sample_rate = (int)sr;
        if (ch) s->channels = (int)ch;
        IMFMediaType_Release(ot);
        break;
      }
      IMFMediaType_Release(ot);
    }
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (pre) IMFSample_Release(pre);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 2; /* reconfigured — keep draining */
  }
  if (FAILED(hr) || !odb.pSample) {
    if (preBuf) IMFMediaBuffer_Release(preBuf);
    if (odb.pSample) IMFSample_Release(odb.pSample);
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return 0; /* treat as "no output yet" */
  }

  IMFMediaBuffer *mb = NULL;
  if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(odb.pSample, &mb)) && mb) {
    BYTE *p = NULL;
    DWORD len = 0;
    if (SUCCEEDED(IMFMediaBuffer_Lock(mb, &p, NULL, &len)) && len > 0) {
      out->pcm_data = (uint8_t *)malloc(len);
      if (out->pcm_data) {
        memcpy(out->pcm_data, p, len);
        out->pcm_size = (int)len;
        out->sample_rate = s->sample_rate;
        out->channels = s->channels;
        out->sample_fmt = 0;
        out->sample_count = (int)(len / (4 * (s->channels ? s->channels : 1)));
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
  return out->pcm_data ? 1 : 0;
}

MFAAC_API int miniav_shim_mfaac_dec_drain(void *session) {
  MfAacDec *s = (MfAacDec *)session;
  if (!s) return -1;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
  return 0;
}

MFAAC_API void miniav_shim_mfaac_dec_destroy(void *session) {
  MfAacDec *s = (MfAacDec *)session;
  if (!s) return;
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  free(s);
  mf_down();
}

/* ===== encoder ============================================================ */

MFAAC_API int miniav_shim_mfaac_enc_has_mft(void) {
  if (mf_up() != 0) return 0;
  IMFTransform *m = enum_first_mft(&MFT_CATEGORY_AUDIO_ENCODER,
                                   &MFAudioFormat_PCM, &MFAudioFormat_AAC);
  int ok = m != NULL;
  if (m) IMFTransform_Release(m);
  mf_down();
  return ok;
}

MFAAC_API void *miniav_shim_mfaac_enc_create(int sample_rate, int channels,
                                             int bitrate_bps) {
  if (channels < 1 || channels > 2) return NULL;
  if (bitrate_bps <= 0) bitrate_bps = 128000;
  if (mf_up() != 0) return NULL;

  MfAacEnc *s = (MfAacEnc *)calloc(1, sizeof(MfAacEnc));
  if (!s) {
    mf_down();
    return NULL;
  }
  s->sample_rate = sample_rate;
  s->channels = channels;
  s->mft = enum_first_mft(&MFT_CATEGORY_AUDIO_ENCODER, &MFAudioFormat_PCM,
                          &MFAudioFormat_AAC);
  if (!s->mft) goto fail;

  /* MS AAC encoder wants 16-bit PCM input; set OUTPUT (AAC) first per MF rules
   * for encoders is not required, but input-before-output works for this MFT. */
  {
    IMFMediaType *it = NULL;
    if (FAILED(MFCreateMediaType(&it))) goto fail;
    IMFMediaType_SetGUID(it, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(it, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_SAMPLES_PER_SECOND,
                           (UINT32)sample_rate);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_BLOCK_ALIGNMENT,
                           (UINT32)(2 * channels));
    IMFMediaType_SetUINT32(it, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                           (UINT32)(sample_rate * 2 * channels));
    HRESULT hr = IMFTransform_SetInputType(s->mft, 0, it, 0);
    IMFMediaType_Release(it);
    if (FAILED(hr)) goto fail;
  }
  {
    IMFMediaType *ot = NULL;
    if (FAILED(MFCreateMediaType(&ot))) goto fail;
    IMFMediaType_SetGUID(ot, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(ot, &MF_MT_SUBTYPE, &MFAudioFormat_AAC);
    IMFMediaType_SetUINT32(ot, &MF_MT_AUDIO_SAMPLES_PER_SECOND,
                           (UINT32)sample_rate);
    IMFMediaType_SetUINT32(ot, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels);
    IMFMediaType_SetUINT32(ot, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    IMFMediaType_SetUINT32(ot, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                           (UINT32)(bitrate_bps / 8));
    IMFMediaType_SetUINT32(ot, &MF_MT_AAC_PAYLOAD_TYPE, 0); /* raw AAC */
    HRESULT hr = IMFTransform_SetOutputType(s->mft, 0, ot, 0);
    if (SUCCEEDED(hr)) {
      /* Read the ASC back from the output type's user data (tail + ASC). */
      UINT32 udlen = 0;
      IMFMediaType_GetBlobSize(ot, &MF_MT_USER_DATA, &udlen);
      if (udlen > HEAAC_TAIL && udlen - HEAAC_TAIL <= (UINT32)sizeof(s->asc)) {
        uint8_t tmp[64 + HEAAC_TAIL];
        if (udlen <= sizeof(tmp) &&
            SUCCEEDED(IMFMediaType_GetBlob(ot, &MF_MT_USER_DATA, tmp, udlen,
                                           NULL))) {
          s->asc_len = (int)(udlen - HEAAC_TAIL);
          memcpy(s->asc, tmp + HEAAC_TAIL, (size_t)s->asc_len);
        }
      }
    }
    IMFMediaType_Release(ot);
    if (FAILED(hr)) goto fail;
  }

  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return s;

fail:
  if (s->mft) IMFTransform_Release(s->mft);
  free(s);
  mf_down();
  return NULL;
}

/* Copy the encoder's AudioSpecificConfig into out (cap bytes). Returns length,
 * or -1. */
MFAAC_API int miniav_shim_mfaac_enc_get_asc(void *session, uint8_t *out,
                                            int cap) {
  MfAacEnc *s = (MfAacEnc *)session;
  if (!s || s->asc_len <= 0) return -1;
  if (!out) return s->asc_len;
  if (cap < s->asc_len) return -1;
  memcpy(out, s->asc, (size_t)s->asc_len);
  return s->asc_len;
}

/* Feed one PCM chunk (interleaved f32). Converts to s16 internally. */
MFAAC_API int miniav_shim_mfaac_enc_send(void *session, const float *pcm,
                                         int sample_count, int64_t pts_us) {
  MfAacEnc *s = (MfAacEnc *)session;
  if (!s || !pcm || sample_count <= 0) return -1;
  int n = sample_count * s->channels;
  DWORD bytes = (DWORD)(n * 2);
  IMFMediaBuffer *buf = NULL;
  if (FAILED(MFCreateMemoryBuffer(bytes, &buf))) return -1;
  BYTE *dst = NULL;
  if (FAILED(IMFMediaBuffer_Lock(buf, &dst, NULL, NULL))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  int16_t *s16 = (int16_t *)dst;
  for (int i = 0; i < n; i++) {
    float v = pcm[i];
    if (v > 1.0f) v = 1.0f;
    else if (v < -1.0f) v = -1.0f;
    s16[i] = (int16_t)(v * 32767.0f);
  }
  IMFMediaBuffer_Unlock(buf);
  IMFMediaBuffer_SetCurrentLength(buf, bytes);
  IMFSample *smp = NULL;
  if (FAILED(MFCreateSample(&smp))) {
    IMFMediaBuffer_Release(buf);
    return -1;
  }
  IMFSample_AddBuffer(smp, buf);
  IMFMediaBuffer_Release(buf);
  IMFSample_SetSampleTime(smp, (LONGLONG)pts_us * 10);
  IMFSample_SetSampleDuration(
      smp, (LONGLONG)sample_count * 10000000 / s->sample_rate);
  HRESULT hr = IMFTransform_ProcessInput(s->mft, 0, smp, 0);
  IMFSample_Release(smp);
  if (FAILED(hr) && hr != MF_E_NOTACCEPTING) return -1;
  return (hr == MF_E_NOTACCEPTING) ? 1 : 0;
}

MFAAC_API int miniav_shim_mfaac_enc_receive(void *session,
                                            MiniAVMfAacEncFrame *out) {
  MfAacEnc *s = (MfAacEnc *)session;
  if (!s || !out) return -1;
  memset(out, 0, sizeof(*out));

  /* The AAC encoder MFT provides its own output samples (dwFlags 0). */
  MFT_OUTPUT_STREAM_INFO si;
  memset(&si, 0, sizeof(si));
  IMFTransform_GetOutputStreamInfo(s->mft, 0, &si);

  MFT_OUTPUT_DATA_BUFFER odb;
  memset(&odb, 0, sizeof(odb));
  IMFSample *pre = NULL;
  IMFMediaBuffer *preBuf = NULL;
  int providesOwn = (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                                   MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
  if (!providesOwn) {
    DWORD cb = si.cbSize > 0 ? si.cbSize : 8192;
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
      out->aac_data = (uint8_t *)malloc(len);
      if (out->aac_data) {
        memcpy(out->aac_data, p, len);
        out->aac_size = (int)len;
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
  return out->aac_data ? 1 : 0;
}

MFAAC_API int miniav_shim_mfaac_enc_drain(void *session) {
  MfAacEnc *s = (MfAacEnc *)session;
  if (!s) return -1;
  IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
  return 0;
}

MFAAC_API void miniav_shim_mfaac_enc_destroy(void *session) {
  MfAacEnc *s = (MfAacEnc *)session;
  if (!s) return;
  if (s->mft) {
    IMFTransform_ProcessMessage(s->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    IMFTransform_Release(s->mft);
  }
  free(s);
  mf_down();
}

/* Free a decoder/encoder frame's malloc'd data buffer. */
MFAAC_API void miniav_shim_mfaac_free(void *p) { free(p); }

#endif /* _WIN32 */
