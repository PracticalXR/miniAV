#ifndef AUDIO_OUTPUT_CONTEXT_H
#define AUDIO_OUTPUT_CONTEXT_H

#include "../../include/miniav_types.h"
#include "../common/miniav_context_base.h"

// Use miniaudio as the backend (high-level engine + ring-buffer data source).
#include "miniaudio.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MiniAVAudioOutputContext MiniAVAudioOutputContext;

#ifdef __cplusplus
}
#endif

#endif // AUDIO_OUTPUT_CONTEXT_H
