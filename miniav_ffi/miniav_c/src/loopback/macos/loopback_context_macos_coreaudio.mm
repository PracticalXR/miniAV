#include "loopback_context_macos_coreaudio.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_utils.h"
#include "../../../include/miniav_buffer.h"

#ifdef __APPLE__

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <AudioUnit/AudioUnit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach.h>
#include <pthread.h>
#include <Foundation/Foundation.h>
#include <CoreMedia/CoreMedia.h>
#include <sys/sysctl.h>

// Audio Tap APIs (macOS 10.10+) - use the correct headers
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101000
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AppKit/NSRunningApplication.h>
#define HAS_AUDIO_TAP_API 1
#else
#define HAS_AUDIO_TAP_API 0
#endif

// ScreenCaptureKit system-audio capture. SCStream audio output is available on
// macOS 13.0+ and needs no third-party virtual device, so it is the preferred
// system-audio fallback below the 14.2+ private Audio Tap API and ahead of the
// BlackHole/Loopback virtual-device requirement.
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#define HAS_SCK_AUDIO_API 1
#else
#define HAS_SCK_AUDIO_API 0
#endif

// --- Forward Declarations ---
static MiniAVResultCode coreaudio_stop_capture(MiniAVLoopbackContext* ctx);
struct CoreAudioLoopbackPlatformContext;
#if HAS_SCK_AUDIO_API
API_AVAILABLE(macos(13.0))
static void coreaudio_sck_teardown(struct CoreAudioLoopbackPlatformContext* platCtx);
#endif

// --- Capture Mode Enum ---
typedef enum {
    CAPTURE_MODE_NONE,
    CAPTURE_MODE_VIRTUAL_DEVICE,         // Virtual audio device (BlackHole, etc.)
    CAPTURE_MODE_SYSTEM_TAP,             // System-wide audio tap
    CAPTURE_MODE_PROCESS_TAP,            // Process-specific audio tap
    CAPTURE_MODE_SCK_AUDIO               // ScreenCaptureKit system-audio (macOS 13.0+)
} CoreAudioCaptureMode;

// Forward declaration of the SCK audio delegate (defined below, guarded).
#if HAS_SCK_AUDIO_API
@class MiniAVLoopbackSCKAudioDelegate;
// Queue-specific tag for same-queue reentrancy detection on the SCK audio
// queue (an app stopping from inside its own audio callback) — mirrors the
// screen backend's captureQueue guard so the teardown drain does not
// self-deadlock.
static const void* kMiniAVLoopbackSCKQueueKey = &kMiniAVLoopbackSCKQueueKey;
#endif

// --- Platform Specific Context ---
typedef struct CoreAudioLoopbackPlatformContext {
    MiniAVLoopbackContext* parent_ctx;
    
    // Virtual device capture (primary method for system audio)
    AudioDeviceID virtual_device_id;
    AudioUnit input_unit;
    bool is_capturing;
    
    // Audio Tap for process/system capture
    #if HAS_AUDIO_TAP_API
    AudioObjectID tap_id;
    AudioDeviceID aggregated_id;
    AudioDeviceIOProcID io_proc_id;
    pid_t target_pid;
    #endif
    
    // Audio format info
    AudioStreamBasicDescription stream_format;
    AudioBufferList* audio_buffer_list;
    
    // Capture thread
    pthread_t capture_thread;
    dispatch_queue_t capture_queue;
    
    // Synchronization
    pthread_mutex_t capture_mutex;
    bool should_stop_capture;

    // Capture mode
    CoreAudioCaptureMode capture_mode;

    // Device-lost detection: DeviceIsAlive listener on the device driving
    // capture (aggregate/tap device or the virtual device).
    AudioDeviceID alive_monitored_device;
    bool alive_listener_installed;
    bool lost_cb_fired; // one-shot per capture run

    // --- ScreenCaptureKit system-audio capture (macOS 13.0+) ---------------
#if HAS_SCK_AUDIO_API
    SCStream* sck_stream API_AVAILABLE(macos(13.0));
    SCStreamConfiguration* sck_config API_AVAILABLE(macos(13.0));
    MiniAVLoopbackSCKAudioDelegate* sck_delegate API_AVAILABLE(macos(13.0));
    dispatch_queue_t sck_audio_queue; // dedicated serial queue for audio output

    // Async start-chain coordination (mirrors the screen backend's hardened
    // cg_start_capture). The SCK setup chain signals sck_start_sem exactly
    // once when it reaches a terminal state; a bumped sck_start_generation
    // abandons an in-flight chain so a timed-out start does not UAF the
    // context; sck_start_pending tracks an unconsumed terminal signal so
    // stop/destroy can drain it before freeing anything.
    dispatch_semaphore_t sck_start_sem;
    volatile int32_t sck_start_generation;
    volatile bool sck_start_pending;
    volatile bool sck_is_streaming; // set true only once SCK actually started
#endif

} CoreAudioLoopbackPlatformContext;

// --- Helper Functions ---
#if HAS_AUDIO_TAP_API
// Helper function to convert PID to Audio Process Object ID
static bool PIDToAudioProcessObjectID(pid_t pid, AudioObjectID* outProcessObjectID) {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = sizeof(AudioObjectID);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 
                                                sizeof(pid), &pid, &dataSize, outProcessObjectID);
    
    if (status != noErr) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Failed to translate PID %d to process object ID: %d", pid, status);
        return false;
    }
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: PID %d -> Process Object ID %u", pid, *outProcessObjectID);
    return true;
}

// Helper function to check if a process has active audio
static bool ProcessHasActiveAudio(pid_t pid) {
    // Get list of all audio processes
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyProcessObjectList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize);
    if (status != noErr || dataSize == 0) {
        return false;
    }
    
    int count = dataSize / sizeof(AudioObjectID);
    AudioObjectID* processObjects = (AudioObjectID*)miniav_calloc(count, sizeof(AudioObjectID));
    if (!processObjects) {
        return false;
    }
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize, processObjects);
    if (status != noErr) {
        miniav_free(processObjects);
        return false;
    }
    
    // Check if our PID is in the list
    addr.mSelector = kAudioProcessPropertyPID;
    for (int i = 0; i < count; i++) {
        pid_t processPID = -1;
        UInt32 pidSize = sizeof(pid_t);
        status = AudioObjectGetPropertyData(processObjects[i], &addr, 0, NULL, &pidSize, &processPID);
        if (status == noErr && processPID == pid) {
            miniav_free(processObjects);
            return true;
        }
    }
    
    miniav_free(processObjects);
    return false;
}

// Helper function to get all processes with active audio
static uint32_t GetProcessesWithActiveAudio(pid_t** audio_pids_out, uint32_t* count_out) {
    *audio_pids_out = NULL;
    *count_out = 0;
    
    // Get list of all audio processes
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyProcessObjectList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize);
    if (status != noErr || dataSize == 0) {
        return 0;
    }
    
    int count = dataSize / sizeof(AudioObjectID);
    AudioObjectID* processObjects = (AudioObjectID*)miniav_calloc(count, sizeof(AudioObjectID));
    if (!processObjects) {
        return 0;
    }
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize, processObjects);
    if (status != noErr) {
        miniav_free(processObjects);
        return 0;
    }
    
    // Extract PIDs from process objects
    pid_t* audio_pids = (pid_t*)miniav_calloc(count, sizeof(pid_t));
    if (!audio_pids) {
        miniav_free(processObjects);
        return 0;
    }
    
    uint32_t valid_count = 0;
    addr.mSelector = kAudioProcessPropertyPID;
    for (int i = 0; i < count; i++) {
        pid_t pid = -1;
        UInt32 pidSize = sizeof(pid_t);
        status = AudioObjectGetPropertyData(processObjects[i], &addr, 0, NULL, &pidSize, &pid);
        if (status == noErr && pid > 0) {
            audio_pids[valid_count] = pid;
            valid_count++;
        }
    }
    
    miniav_free(processObjects);
    
    if (valid_count > 0) {
        *audio_pids_out = audio_pids;
        *count_out = valid_count;
        return valid_count;
    } else {
        miniav_free(audio_pids);
        return 0;
    }
}

// Helper function to check if PID is in active audio list
static bool IsProcessInActiveAudioList(pid_t target_pid, pid_t* audio_pids, uint32_t audio_count) {
    for (uint32_t i = 0; i < audio_count; i++) {
        if (audio_pids[i] == target_pid) {
            return true;
        }
    }
    return false;
}
#endif

static MiniAVAudioFormat CoreAudioFormatToMiniAV(const AudioStreamBasicDescription* asbd) {
    if (asbd->mFormatID == kAudioFormatLinearPCM) {
        if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
            if (asbd->mBitsPerChannel == 32) {
                return MINIAV_AUDIO_FORMAT_F32;
            }
        } else { // Integer PCM
            if (asbd->mBitsPerChannel == 16) {
                return MINIAV_AUDIO_FORMAT_S16;
            } else if (asbd->mBitsPerChannel == 32) {
                return MINIAV_AUDIO_FORMAT_S32;
            } else if (asbd->mBitsPerChannel == 8) {
                return MINIAV_AUDIO_FORMAT_U8;
            }
        }
    }
    return MINIAV_AUDIO_FORMAT_UNKNOWN;
}

static void MiniAVFormatToCoreAudio(const MiniAVAudioInfo* miniav_format, AudioStreamBasicDescription* asbd) {
    memset(asbd, 0, sizeof(AudioStreamBasicDescription));
    asbd->mSampleRate = miniav_format->sample_rate;
    asbd->mChannelsPerFrame = miniav_format->channels;
    asbd->mFormatID = kAudioFormatLinearPCM;
    
    switch (miniav_format->format) {
        case MINIAV_AUDIO_FORMAT_F32:
            asbd->mBitsPerChannel = 32;
            asbd->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            break;
        case MINIAV_AUDIO_FORMAT_S16:
            asbd->mBitsPerChannel = 16;
            asbd->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            break;
        case MINIAV_AUDIO_FORMAT_S32:
            asbd->mBitsPerChannel = 32;
            asbd->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            break;
        case MINIAV_AUDIO_FORMAT_U8:
            asbd->mBitsPerChannel = 8;
            asbd->mFormatFlags = kAudioFormatFlagIsPacked;
            break;
        default:
            asbd->mBitsPerChannel = 32;
            asbd->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            break;
    }
    
    asbd->mBytesPerFrame = (asbd->mBitsPerChannel / 8) * asbd->mChannelsPerFrame;
    asbd->mFramesPerPacket = 1;
    asbd->mBytesPerPacket = asbd->mBytesPerFrame * asbd->mFramesPerPacket;
    
    if (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        asbd->mFormatFlags |= kAudioFormatFlagsNativeEndian;
    }
}

// Get process name by PID
static bool GetProcessNameByPID(pid_t pid, char* name_buffer, size_t buffer_size) {
    struct proc_bsdinfo proc_info;
    int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &proc_info, sizeof(proc_info));
    if (result == sizeof(proc_info)) {
        strncpy(name_buffer, proc_info.pbi_name, buffer_size - 1);
        name_buffer[buffer_size - 1] = '\0';
        return true;
    }
    return false;
}

static AudioObjectPropertyAddress GetPropertyAddress(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    return address;
}

// Check if a device is a virtual audio device (like BlackHole)
static bool IsVirtualAudioDevice(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress prop_addr = GetPropertyAddress(kAudioObjectPropertyManufacturer);
    CFStringRef manufacturer = NULL;
    UInt32 data_size = sizeof(CFStringRef);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &prop_addr, 0, NULL, &data_size, &manufacturer);
    
    if (status == noErr && manufacturer) {
        bool is_virtual = false;
        
        if (CFStringCompare(manufacturer, CFSTR("ExistentialAudio Inc."), 0) == kCFCompareEqualTo) {
            is_virtual = true;
        }
        else if (CFStringCompare(manufacturer, CFSTR("Rogue Amoeba"), 0) == kCFCompareEqualTo) {
            is_virtual = true;
        }
        else if (CFStringCompare(manufacturer, CFSTR("ma++ ingalls"), 0) == kCFCompareEqualTo) {
            is_virtual = true;
        }
        
        CFRelease(manufacturer);
        return is_virtual;
    }
    
    return false;
}

#if HAS_AUDIO_TAP_API
// Audio IOProc callback for process audio tap
static OSStatus AudioTapIOProc(AudioObjectID          objID,
                               const AudioTimeStamp*  inNow,
                               const AudioBufferList* inInputData,
                               const AudioTimeStamp*  inInputTime,
                               AudioBufferList*       outOutputData,
                               const AudioTimeStamp*  outOutputTime,
                               void*                  inClientData) {
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)inClientData;
    MiniAVLoopbackContext* ctx = platCtx->parent_ctx;
    
    if (!ctx || !ctx->app_callback || !platCtx->is_capturing || !inInputData) {
        return kAudioHardwareNoError;
    }
    
    // Process the captured audio
    if (inInputData->mNumberBuffers > 0) {
        MiniAVNativeBufferInternalPayload* payload = 
            (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
        MiniAVBuffer* mavBuffer_ptr = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
        
        if (!payload || !mavBuffer_ptr) {
            miniav_free(payload);
            miniav_free(mavBuffer_ptr);
            return kAudioHardwareNoError;
        }
        
        payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
        payload->context_owner = ctx;
        payload->parent_miniav_buffer_ptr = mavBuffer_ptr;
        mavBuffer_ptr->internal_handle = payload;
        
        // Copy audio data from the first buffer
        const AudioBuffer* sourceBuffer = &inInputData->mBuffers[0];
        void* audioCopy = miniav_calloc(sourceBuffer->mDataByteSize, 1);
        if (audioCopy) {
            memcpy(audioCopy, sourceBuffer->mData, sourceBuffer->mDataByteSize);
            payload->native_singular_resource_ptr = audioCopy;
            
            mavBuffer_ptr->type = MINIAV_BUFFER_TYPE_AUDIO;
            mavBuffer_ptr->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
            mavBuffer_ptr->timestamp_us = AudioConvertHostTimeToNanos(inNow->mHostTime) / 1000;
            
            // Calculate frame count from buffer size and format (guard the
            // divisor: a zeroed/unnegotiated ASBD would fault here).
            uint32_t frame_count =
                platCtx->stream_format.mBytesPerFrame
                    ? sourceBuffer->mDataByteSize / platCtx->stream_format.mBytesPerFrame
                    : 0;
            
            mavBuffer_ptr->data.audio.frame_count = frame_count;
            mavBuffer_ptr->data.audio.info.sample_rate = (uint32_t)platCtx->stream_format.mSampleRate;
            mavBuffer_ptr->data.audio.info.channels = platCtx->stream_format.mChannelsPerFrame;
            mavBuffer_ptr->data.audio.info.format = CoreAudioFormatToMiniAV(&platCtx->stream_format);
            mavBuffer_ptr->data.audio.info.num_frames = frame_count;
            mavBuffer_ptr->data.audio.data = audioCopy;
            
            mavBuffer_ptr->data_size_bytes = sourceBuffer->mDataByteSize;
            mavBuffer_ptr->user_data = ctx->app_callback_user_data;
            
            ctx->app_callback(mavBuffer_ptr, ctx->app_callback_user_data);
        } else {
            miniav_free(payload);
            miniav_free(mavBuffer_ptr);
        }
    }
    
    return kAudioHardwareNoError;
}
#endif

// AudioUnit input callback for virtual device capture
static OSStatus AudioInputCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags,
                                 const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber,
                                 UInt32 inNumberFrames, AudioBufferList* ioData) {
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)inRefCon;
    MiniAVLoopbackContext* ctx = platCtx->parent_ctx;
    
    if (!ctx || !ctx->app_callback || !platCtx->is_capturing) {
        return noErr;
    }
    
    // Render audio from the input unit
    OSStatus status = AudioUnitRender(platCtx->input_unit, ioActionFlags, inTimeStamp, 
                                     inBusNumber, inNumberFrames, platCtx->audio_buffer_list);
    if (status != noErr) {
        miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: AudioUnitRender failed: %d", status);
        return status;
    }
    
    // Process the captured audio
    if (platCtx->audio_buffer_list && platCtx->audio_buffer_list->mNumberBuffers > 0) {
        MiniAVNativeBufferInternalPayload* payload = 
            (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
        MiniAVBuffer* mavBuffer_ptr = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
        
        if (!payload || !mavBuffer_ptr) {
            miniav_free(payload);
            miniav_free(mavBuffer_ptr);
            return noErr;
        }
        
        payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
        payload->context_owner = ctx;
        payload->parent_miniav_buffer_ptr = mavBuffer_ptr;
        mavBuffer_ptr->internal_handle = payload;
        
        // Copy audio data
        AudioBuffer* sourceBuffer = &platCtx->audio_buffer_list->mBuffers[0];
        void* audioCopy = miniav_calloc(sourceBuffer->mDataByteSize, 1);
        if (audioCopy) {
            memcpy(audioCopy, sourceBuffer->mData, sourceBuffer->mDataByteSize);
            payload->native_singular_resource_ptr = audioCopy;
            
            mavBuffer_ptr->type = MINIAV_BUFFER_TYPE_AUDIO;
            mavBuffer_ptr->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
            mavBuffer_ptr->timestamp_us = AudioConvertHostTimeToNanos(inTimeStamp->mHostTime) / 1000;
            
            mavBuffer_ptr->data.audio.frame_count = inNumberFrames;
            mavBuffer_ptr->data.audio.info.sample_rate = (uint32_t)platCtx->stream_format.mSampleRate;
            mavBuffer_ptr->data.audio.info.channels = platCtx->stream_format.mChannelsPerFrame;
            mavBuffer_ptr->data.audio.info.format = CoreAudioFormatToMiniAV(&platCtx->stream_format);
            mavBuffer_ptr->data.audio.info.num_frames = inNumberFrames;
            mavBuffer_ptr->data.audio.data = audioCopy;
            
            mavBuffer_ptr->data_size_bytes = sourceBuffer->mDataByteSize;
            mavBuffer_ptr->user_data = ctx->app_callback_user_data;
            
            ctx->app_callback(mavBuffer_ptr, ctx->app_callback_user_data);
        } else {
            miniav_free(payload);
            miniav_free(mavBuffer_ptr);
        }
    }

    return noErr;
}

// --- ScreenCaptureKit system-audio delegate (macOS 13.0+) -----------------
// Delivers system loopback audio via SCStream on stock macOS 13.x machines
// with no third-party virtual driver. The audio sample-buffer path mirrors
// AudioTapIOProc's exact buffer-building contract: payload +
// MiniAVBuffer + PCM copy + MINIAV_NATIVE_HANDLE_TYPE_AUDIO + timestamp +
// app_callback. Manual retain/release (no ARC).
#if HAS_SCK_AUDIO_API
API_AVAILABLE(macos(13.0))
@interface MiniAVLoopbackSCKAudioDelegate : NSObject <SCStreamDelegate, SCStreamOutput>
{
    CoreAudioLoopbackPlatformContext* _platCtx;
}
- (instancetype)initWithPlatformContext:(CoreAudioLoopbackPlatformContext*)platCtx;
@end

@implementation MiniAVLoopbackSCKAudioDelegate

- (instancetype)initWithPlatformContext:(CoreAudioLoopbackPlatformContext*)platCtx {
    self = [super init];
    if (self) {
        _platCtx = platCtx;
    }
    return self;
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeAudio) {
        return;
    }
    CoreAudioLoopbackPlatformContext* platCtx = _platCtx;
    if (!platCtx || !platCtx->is_capturing) {
        return;
    }
    MiniAVLoopbackContext* ctx = platCtx->parent_ctx;
    if (!ctx || !ctx->app_callback) {
        return;
    }
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }

    // Describe the real delivered format from the sample's ASBD.
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc) {
        return;
    }
    const AudioStreamBasicDescription* asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (!asbd) {
        return;
    }

    // Pull the interleaved PCM bytes out of the sample's block buffer. SCK
    // delivers linear PCM; a contiguous data pointer is the common case.
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return;
    }
    size_t totalLength = 0;
    char* dataPtr = NULL;
    OSStatus st = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPtr);
    if (st != noErr || !dataPtr || totalLength == 0) {
        return;
    }

    MiniAVNativeBufferInternalPayload* payload =
        (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
    MiniAVBuffer* mavBuffer_ptr = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
    if (!payload || !mavBuffer_ptr) {
        miniav_free(payload);
        miniav_free(mavBuffer_ptr);
        return;
    }

    payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
    payload->context_owner = ctx;
    payload->parent_miniav_buffer_ptr = mavBuffer_ptr;
    mavBuffer_ptr->internal_handle = payload;

    void* audioCopy = miniav_calloc(totalLength, 1);
    if (!audioCopy) {
        miniav_free(payload);
        miniav_free(mavBuffer_ptr);
        return;
    }
    memcpy(audioCopy, dataPtr, totalLength);
    payload->native_singular_resource_ptr = audioCopy;

    CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);

    mavBuffer_ptr->type = MINIAV_BUFFER_TYPE_AUDIO;
    mavBuffer_ptr->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    // NOTE: this file does not include miniav_time.h and the tap/virtual-device
    // paths stamp via AudioConvertHostTimeToNanos (host clock, not rebased).
    // Match the SCREEN backend's SCK audio path exactly (CMTimeGetSeconds)
    // rather than introduce a rebase state field with new thread ownership.
    mavBuffer_ptr->timestamp_us =
        (uint64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000000.0);

    mavBuffer_ptr->data.audio.frame_count = (uint32_t)frameCount;
    mavBuffer_ptr->data.audio.info.sample_rate = (uint32_t)asbd->mSampleRate;
    mavBuffer_ptr->data.audio.info.channels = asbd->mChannelsPerFrame;
    mavBuffer_ptr->data.audio.info.format = CoreAudioFormatToMiniAV(asbd);
    mavBuffer_ptr->data.audio.info.num_frames = (uint32_t)frameCount;
    mavBuffer_ptr->data.audio.data = audioCopy;

    mavBuffer_ptr->data_size_bytes = totalLength;
    mavBuffer_ptr->user_data = ctx->app_callback_user_data;

    ctx->app_callback(mavBuffer_ptr, ctx->app_callback_user_data);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    CoreAudioLoopbackPlatformContext* platCtx = _platCtx;
    if (!platCtx) {
        return;
    }
    if (error) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR,
                   "CoreAudio: SCK audio stream stopped with error: %s",
                   [[error localizedDescription] UTF8String]);
    } else {
        miniav_log(MINIAV_LOG_LEVEL_INFO,
                   "CoreAudio: SCK audio stream stopped normally.");
    }
    // Out-of-band stop (permission revoked, display gone): mark capture dead
    // and notify the app exactly once — mirrors the screen backend.
    if (platCtx->is_capturing && !platCtx->lost_cb_fired) {
        platCtx->lost_cb_fired = true;
        platCtx->is_capturing = false;
        MiniAVLoopbackContext* parent = platCtx->parent_ctx;
        if (parent) {
            parent->is_running = false;
            if (parent->lost_cb) {
                parent->lost_cb((int)MINIAV_ERROR_DEVICE_LOST,
                                parent->lost_cb_user_data);
            }
        }
    }
}

@end
#endif // HAS_SCK_AUDIO_API

// Find the best virtual audio device for system capture
// --- Device-lost detection ------------------------------------------------
// Previously nothing observed the capture device's liveness: if the tapped
// process exited, the virtual device (e.g. BlackHole) was removed, or the
// aggregate device died, the app saw silent callback starvation with no
// diagnostic. A DeviceIsAlive property listener now fires lost_cb once.

static const AudioObjectPropertyAddress kMiniAVDeviceAliveAddr = {
    kAudioDevicePropertyDeviceIsAlive,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

static OSStatus coreaudio_device_alive_listener(
    AudioObjectID inObjectID, UInt32 inNumberAddresses,
    const AudioObjectPropertyAddress* inAddresses, void* inClientData) {
    (void)inNumberAddresses;
    (void)inAddresses;
    CoreAudioLoopbackPlatformContext* platCtx =
        (CoreAudioLoopbackPlatformContext*)inClientData;
    if (!platCtx) return noErr;
    UInt32 alive = 1;
    UInt32 size = sizeof(alive);
    OSStatus st = AudioObjectGetPropertyData(
        inObjectID, &kMiniAVDeviceAliveAddr, 0, NULL, &size, &alive);
    if (st != noErr || alive == 0) {
        if (platCtx->is_capturing && !platCtx->lost_cb_fired) {
            platCtx->lost_cb_fired = true;
            miniav_log(MINIAV_LOG_LEVEL_WARN,
                       "CoreAudio: Capture device %u is gone — notifying app.",
                       (unsigned int)inObjectID);
            MiniAVLoopbackContext* parent = platCtx->parent_ctx;
            if (parent && parent->lost_cb) {
                // Runs on CoreAudio's notification thread — per the
                // MiniAVContextLostCallback contract the app must not
                // synchronously Stop/Destroy from inside the callback
                // (StopCapture removes THIS listener, which synchronizes
                // with in-flight invocations → self-deadlock).
                parent->lost_cb((int)MINIAV_ERROR_DEVICE_LOST,
                                parent->lost_cb_user_data);
            }
        }
    }
    return noErr;
}

static void coreaudio_install_alive_listener(
    CoreAudioLoopbackPlatformContext* platCtx, AudioDeviceID device) {
    if (platCtx->alive_listener_installed || device == kAudioObjectUnknown) {
        return;
    }
    OSStatus st = AudioObjectAddPropertyListener(
        device, &kMiniAVDeviceAliveAddr, coreaudio_device_alive_listener,
        platCtx);
    if (st == noErr) {
        platCtx->alive_monitored_device = device;
        platCtx->alive_listener_installed = true;
    } else {
        miniav_log(MINIAV_LOG_LEVEL_WARN,
                   "CoreAudio: Failed to install device-alive listener: %d",
                   (int)st);
    }
}

static void coreaudio_remove_alive_listener(
    CoreAudioLoopbackPlatformContext* platCtx) {
    if (!platCtx->alive_listener_installed) {
        return;
    }
    AudioObjectRemovePropertyListener(platCtx->alive_monitored_device,
                                      &kMiniAVDeviceAliveAddr,
                                      coreaudio_device_alive_listener, platCtx);
    platCtx->alive_monitored_device = kAudioObjectUnknown;
    platCtx->alive_listener_installed = false;
}

// Reads the device's current stream format (the format IO callbacks will
// actually deliver). Returns true and fills out on success.
// kAudioDevicePropertyStreamFormat is deprecated in modern SDKs (superseded
// by stream-level kAudioStreamPropertyVirtualFormat) but remains functional;
// silenced locally so downstream -Werror=deprecated-declarations builds
// don't break. TODO(P2): migrate to the stream-object query.
static bool coreaudio_read_device_format(AudioObjectID device,
                                         AudioObjectPropertyScope scope,
                                         AudioStreamBasicDescription* out) {
    if (device == kAudioObjectUnknown || !out) {
        return false;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamFormat,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*out);
    OSStatus st = AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, out);
#pragma clang diagnostic pop
    return st == noErr && out->mSampleRate > 0 && out->mBytesPerFrame > 0;
}

static AudioDeviceID FindVirtualAudioDevice(void) {
    AudioObjectPropertyAddress prop_addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &prop_addr, 0, NULL, &data_size);
    if (status != noErr || data_size == 0) {
        return kAudioObjectUnknown;
    }
    
    UInt32 device_count = data_size / sizeof(AudioDeviceID);
    AudioDeviceID* devices = (AudioDeviceID*)miniav_calloc(device_count, sizeof(AudioDeviceID));
    if (!devices) {
        return kAudioObjectUnknown;
    }
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop_addr, 0, NULL, &data_size, devices);
    if (status != noErr) {
        miniav_free(devices);
        return kAudioObjectUnknown;
    }
    
    AudioDeviceID virtual_device = kAudioObjectUnknown;
    
    for (UInt32 i = 0; i < device_count; i++) {
        // Check if device has input streams
        prop_addr.mSelector = kAudioDevicePropertyStreams;
        prop_addr.mScope = kAudioDevicePropertyScopeInput;
        data_size = 0;
        status = AudioObjectGetPropertyDataSize(devices[i], &prop_addr, 0, NULL, &data_size);
        if (status != noErr || data_size == 0) {
            continue; // No input streams
        }
        
        // Check if it's a virtual device
        if (IsVirtualAudioDevice(devices[i])) {
            virtual_device = devices[i];
            break; // Use the first virtual device we find
        }
    }
    
    miniav_free(devices);
    return virtual_device;
}

// --- Platform Ops Implementation ---

static MiniAVResultCode coreaudio_init_platform(MiniAVLoopbackContext* ctx) {
    if (!ctx || !ctx->platform_ctx) return MINIAV_ERROR_INVALID_ARG;
    
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;
    platCtx->parent_ctx = ctx;
    platCtx->is_capturing = false;
    platCtx->should_stop_capture = false;
    platCtx->capture_mode = CAPTURE_MODE_NONE;
    platCtx->virtual_device_id = kAudioObjectUnknown;
    
    #if HAS_AUDIO_TAP_API
    platCtx->tap_id = kAudioObjectUnknown;
    platCtx->aggregated_id = kAudioObjectUnknown;
    platCtx->io_proc_id = NULL;
    platCtx->target_pid = 0;
    #endif
    
    // Initialize mutex
    if (pthread_mutex_init(&platCtx->capture_mutex, NULL) != 0) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to initialize mutex");
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    
    // Create capture queue
    platCtx->capture_queue = dispatch_queue_create("com.miniav.loopback.capture", DISPATCH_QUEUE_SERIAL);
    if (!platCtx->capture_queue) {
        pthread_mutex_destroy(&platCtx->capture_mutex);
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Platform context initialized.");
    return MINIAV_SUCCESS;
}

static MiniAVResultCode coreaudio_destroy_platform(MiniAVLoopbackContext* ctx) {
    if (!ctx || !ctx->platform_ctx) return MINIAV_SUCCESS;
    
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;

    // Stop capture if running
    if (platCtx->is_capturing) {
        coreaudio_stop_capture(ctx);
    }

#if HAS_SCK_AUDIO_API
    // Unconditionally tear down SCK: a timed-out start can leave a pending
    // chain / allocated stream while is_capturing is false, so the
    // is_capturing-gated stop above would skip it. coreaudio_sck_teardown
    // drains the abandoned chain and releases the stream/config/delegate/queue
    // (each exactly once — idempotent if stop already ran). Then free the
    // start semaphore created lazily in coreaudio_sck_start.
    if (@available(macOS 13.0, *)) {
        coreaudio_sck_teardown(platCtx);
        if (platCtx->sck_start_sem) {
            dispatch_release(platCtx->sck_start_sem);
            platCtx->sck_start_sem = NULL;
        }
    }
#endif

    // Clean up AudioUnit
    if (platCtx->input_unit) {
        AudioUnitUninitialize(platCtx->input_unit);
        AudioComponentInstanceDispose(platCtx->input_unit);
        platCtx->input_unit = NULL;
    }
    
    #if HAS_AUDIO_TAP_API
    // Clean up Audio Tap
    if (platCtx->io_proc_id && platCtx->aggregated_id != kAudioObjectUnknown) {
        AudioDeviceDestroyIOProcID(platCtx->aggregated_id, platCtx->io_proc_id);
        platCtx->io_proc_id = NULL;
    }
    
    if (platCtx->aggregated_id != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(platCtx->aggregated_id);
        platCtx->aggregated_id = kAudioObjectUnknown;
    }
    
    if (platCtx->tap_id != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(platCtx->tap_id);
        platCtx->tap_id = kAudioObjectUnknown;
    }
    #endif
    
    // Clean up audio buffer
    if (platCtx->audio_buffer_list) {
        if (platCtx->audio_buffer_list->mBuffers[0].mData) {
            miniav_free(platCtx->audio_buffer_list->mBuffers[0].mData);
        }
        miniav_free(platCtx->audio_buffer_list);
        platCtx->audio_buffer_list = NULL;
    }
    
    // Clean up dispatch queue
    if (platCtx->capture_queue) {
        dispatch_release(platCtx->capture_queue);
        platCtx->capture_queue = NULL;
    }
    
    // Destroy mutex
    pthread_mutex_destroy(&platCtx->capture_mutex);
    
    miniav_free(platCtx);
    ctx->platform_ctx = NULL;
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Platform context destroyed.");
    return MINIAV_SUCCESS;
}

// Helper function to enumerate running processes (filtered for active audio)
static uint32_t EnumerateRunningProcesses(MiniAVDeviceInfo* devices, uint32_t max_devices) {
    uint32_t found_count = 0;
    
    #if HAS_AUDIO_TAP_API
    // Get list of processes with active audio first
    pid_t* audio_pids = NULL;
    uint32_t audio_count = 0;
    GetProcessesWithActiveAudio(&audio_pids, &audio_count);
    
    if (audio_count == 0) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: No processes with active audio found");
        return 0;
    }
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Found %u processes with active audio", audio_count);
    
    // Get detailed info for each process with active audio
    for (uint32_t i = 0; i < audio_count && found_count < max_devices; i++) {
        pid_t pid = audio_pids[i];
        
        // Skip system processes
        if (pid <= 1) continue;
        
        // Get process name
        char process_name[256] = {0};
        bool got_name = GetProcessNameByPID(pid, process_name, sizeof(process_name));
        
        if (got_name && strlen(process_name) > 0) {
            // Skip obvious system processes
            if (strncmp(process_name, "kernel", 6) == 0) continue;
            if (strncmp(process_name, "launchd", 7) == 0) continue;
            if (strncmp(process_name, "coreaudiod", 10) == 0) continue;
            if (strncmp(process_name, "AudioComponentRegistrar", 23) == 0) continue;
            
            MiniAVDeviceInfo* info = &devices[found_count];
            snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "pid:%d", pid);
            snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "%s (PID: %d) 🎵", 
                     process_name, pid);
            info->is_default = false;
            found_count++;
            
            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Added audio process: %s (PID: %d)", process_name, pid);
        }
    }
    
    miniav_free(audio_pids);
    
    #else
    // Fallback: show all processes but warn about functionality
    miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Audio Tap API not available - showing all processes (audio filtering not possible)");
    
    // Get list of all processes
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    
    // Get size needed
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) {
        return 0;
    }
    
    struct kinfo_proc* processes = (struct kinfo_proc*)miniav_calloc(size, 1);
    if (!processes) {
        return 0;
    }
    
    // Get actual process list
    if (sysctl(mib, 4, processes, &size, NULL, 0) != 0) {
        miniav_free(processes);
        return 0;
    }
    
    size_t process_count = size / sizeof(struct kinfo_proc);
    
    for (size_t i = 0; i < process_count && found_count < max_devices; i++) {
        struct kinfo_proc* proc = &processes[i];
        
        // Skip kernel processes and system processes
        if (proc->kp_proc.p_pid <= 1) continue;
        if (strlen(proc->kp_proc.p_comm) == 0) continue;
        
        // Skip obvious system processes
        if (strncmp(proc->kp_proc.p_comm, "kernel", 6) == 0) continue;
        if (strncmp(proc->kp_proc.p_comm, "launchd", 7) == 0) continue;
        
        // Get more detailed process info
        char process_name[256] = {0};
        if (GetProcessNameByPID(proc->kp_proc.p_pid, process_name, sizeof(process_name))) {
            MiniAVDeviceInfo* info = &devices[found_count];
            snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "pid:%d", proc->kp_proc.p_pid);
            snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "%s (PID: %d) ⚠️", 
                     process_name, proc->kp_proc.p_pid);
            info->is_default = false;
            found_count++;
        }
    }
    
    miniav_free(processes);
    #endif
    
    return found_count;
}

// Helper function to enumerate windows (filtered for processes with active audio)
static uint32_t EnumerateWindows(MiniAVDeviceInfo* devices, uint32_t max_devices) {
    uint32_t found_count = 0;
    
    #if HAS_AUDIO_TAP_API
    // Get list of processes with active audio first
    pid_t* audio_pids = NULL;
    uint32_t audio_count = 0;
    GetProcessesWithActiveAudio(&audio_pids, &audio_count);
    
    if (audio_count == 0) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: No processes with active audio found for window enumeration");
        return 0;
    }
    #endif
    
    // Get list of all windows
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    
    if (!windowList) {
        #if HAS_AUDIO_TAP_API
        miniav_free(audio_pids);
        #endif
        return 0;
    }
    
    CFIndex windowCount = CFArrayGetCount(windowList);
    
    for (CFIndex i = 0; i < windowCount && found_count < max_devices; i++) {
        CFDictionaryRef windowInfo = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
        
        // Get window ID
        CFNumberRef windowNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowNumber);
        if (!windowNumber) continue;
        
        CGWindowID windowID;
        CFNumberGetValue(windowNumber, kCFNumberSInt32Type, &windowID);
        
        // Get PID
        CFNumberRef pidNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerPID);
        pid_t pid = 0;
        if (pidNumber) {
            CFNumberGetValue(pidNumber, kCFNumberIntType, &pid);
        }
        
        #if HAS_AUDIO_TAP_API
        // Only include windows from processes with active audio
        if (!IsProcessInActiveAudioList(pid, audio_pids, audio_count)) {
            continue;
        }
        #endif
        
        // Get window name
        CFStringRef windowName = (CFStringRef)CFDictionaryGetValue(windowInfo, kCGWindowName);
        char windowNameStr[256] = "Unnamed Window";
        if (windowName) {
            CFStringGetCString(windowName, windowNameStr, sizeof(windowNameStr), kCFStringEncodingUTF8);
        }
        
        // Get owner name
        CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerName);
        char ownerNameStr[256] = "Unknown";
        if (ownerName) {
            CFStringGetCString(ownerName, ownerNameStr, sizeof(ownerNameStr), kCFStringEncodingUTF8);
        }
        
        // Skip windows without proper names or from system processes
        if (strlen(windowNameStr) == 0 || strcmp(windowNameStr, "Unnamed Window") == 0) {
            continue;
        }
        
        // Skip system windows
        if (strcmp(ownerNameStr, "Window Server") == 0 || 
            strcmp(ownerNameStr, "Dock") == 0 ||
            strcmp(ownerNameStr, "SystemUIServer") == 0) {
            continue;
        }
        
        MiniAVDeviceInfo* info = &devices[found_count];
        snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "window:%u", windowID);
        
        #if HAS_AUDIO_TAP_API
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "%s - %s 🎵 (Window ID: %u, PID: %d)", 
                 windowNameStr, ownerNameStr, windowID, pid);
        #else
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "%s - %s ⚠️ (Window ID: %u, PID: %d)", 
                 windowNameStr, ownerNameStr, windowID, pid);
        #endif
        
        info->is_default = false;
        found_count++;
        
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Added audio window: %s - %s (PID: %d)", 
                   windowNameStr, ownerNameStr, pid);
    }
    
    CFRelease(windowList);
    
    #if HAS_AUDIO_TAP_API
    miniav_free(audio_pids);
    #endif
    
    return found_count;
}

static MiniAVResultCode coreaudio_enumerate_targets(MiniAVLoopbackTargetType target_type_filter,
                                                   MiniAVDeviceInfo** targets_out, uint32_t* count_out) {
    if (!targets_out || !count_out) return MINIAV_ERROR_INVALID_ARG;
    *targets_out = NULL;
    *count_out = 0;
    
    const uint32_t MAX_TARGETS = 512; // Increased for process/window enumeration
    MiniAVDeviceInfo* temp_devices = (MiniAVDeviceInfo*)miniav_calloc(MAX_TARGETS, sizeof(MiniAVDeviceInfo));
    if (!temp_devices) {
        return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    
    uint32_t found_count = 0;
    
    // System audio capture options
    if (target_type_filter == MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO || target_type_filter == MINIAV_LOOPBACK_TARGET_NONE) {
        #if HAS_AUDIO_TAP_API
        // System-wide audio tap (preferred method)
        MiniAVDeviceInfo* info = &temp_devices[found_count];
        snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "system_tap");
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "System Audio (Audio Tap)");
        info->is_default = true;
        found_count++;
        #endif
        
        // Virtual audio devices as fallback method
        AudioDeviceID virtual_device = FindVirtualAudioDevice();
        if (virtual_device != kAudioObjectUnknown) {
            AudioObjectPropertyAddress prop_addr = GetPropertyAddress(kAudioObjectPropertyName);
            CFStringRef device_name = NULL;
            UInt32 data_size = sizeof(CFStringRef);
            OSStatus status = AudioObjectGetPropertyData(virtual_device, &prop_addr, 0, NULL, &data_size, &device_name);
            
            if (status == noErr && device_name) {
                MiniAVDeviceInfo* info = &temp_devices[found_count];
                snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "virtual_device:%u", virtual_device);
                
                char device_name_str[256];
                CFStringGetCString(device_name, device_name_str, sizeof(device_name_str), kCFStringEncodingUTF8);
                snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "%s (Virtual Device)", device_name_str);
                #if !HAS_AUDIO_TAP_API
                info->is_default = true;
                #else
                info->is_default = false; // Audio Tap is preferred
                #endif
                
                CFRelease(device_name);
                found_count++;
            }
        }
    }
    
    // Process-specific capture - enumerate all running processes
    if (target_type_filter == MINIAV_LOOPBACK_TARGET_PROCESS || target_type_filter == MINIAV_LOOPBACK_TARGET_NONE) {
        #if HAS_AUDIO_TAP_API
        uint32_t process_count = EnumerateRunningProcesses(&temp_devices[found_count], MAX_TARGETS - found_count);
        found_count += process_count;
        #else
        MiniAVDeviceInfo* info = &temp_devices[found_count];
        snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "process_not_supported");
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "Process capture requires macOS 10.10+ and Audio Tap API");
        info->is_default = false;
        found_count++;
        #endif
    }

    // Window-specific capture - enumerate all visible windows
    if (target_type_filter == MINIAV_LOOPBACK_TARGET_WINDOW || target_type_filter == MINIAV_LOOPBACK_TARGET_NONE) {
        #if HAS_AUDIO_TAP_API
        uint32_t window_count = EnumerateWindows(&temp_devices[found_count], MAX_TARGETS - found_count);
        found_count += window_count;
        #else
        MiniAVDeviceInfo* info = &temp_devices[found_count];
        snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "window_not_supported");
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "Window capture requires macOS 10.10+ and Audio Tap API");
        info->is_default = false;
        found_count++;
        #endif
    }
    
    // Copy results
    if (found_count > 0) {
        *targets_out = (MiniAVDeviceInfo*)miniav_calloc(found_count, sizeof(MiniAVDeviceInfo));
        if (*targets_out) {
            memcpy(*targets_out, temp_devices, found_count * sizeof(MiniAVDeviceInfo));
            *count_out = found_count;
        } else {
            miniav_free(temp_devices);
            return MINIAV_ERROR_OUT_OF_MEMORY;
        }
    }
    
    miniav_free(temp_devices);
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Enumerated %u loopback targets", found_count);
    return MINIAV_SUCCESS;
}

// Resolves the AudioDeviceID whose format best describes what capture will
// deliver for the given loopback target: an explicit virtual device when
// named, otherwise the system default OUTPUT device (loopback captures what
// is being played). pid:/window:/system_tap targets mix through the default
// output device's format.
static AudioObjectID coreaudio_format_query_device(const char* target_device_id) {
    if (target_device_id &&
        strncmp(target_device_id, "virtual_device:", 15) == 0) {
        unsigned dev = 0;
        if (sscanf(target_device_id + 15, "%u", &dev) == 1) {
            return (AudioObjectID)dev;
        }
    }
    AudioObjectID dev = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL,
                                   &size, &dev) != noErr) {
        return kAudioObjectUnknown;
    }
    return dev;
}

static MiniAVResultCode coreaudio_get_default_format(const char* target_device_id, MiniAVAudioInfo* format_out) {
    if (!format_out) return MINIAV_ERROR_INVALID_ARG;
    memset(format_out, 0, sizeof(MiniAVAudioInfo));

    // Query the real device instead of returning a hardcoded 44.1kHz/2ch
    // constant that ignored target_device_id entirely.
    AudioObjectID dev = coreaudio_format_query_device(target_device_id);
    AudioStreamBasicDescription asbd;
    if (coreaudio_read_device_format(dev, kAudioObjectPropertyScopeOutput, &asbd) ||
        coreaudio_read_device_format(dev, kAudioObjectPropertyScopeInput, &asbd)) {
        format_out->format = CoreAudioFormatToMiniAV(&asbd);
        format_out->sample_rate = (uint32_t)asbd.mSampleRate;
        format_out->channels = asbd.mChannelsPerFrame;
        format_out->num_frames = 1024;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "CoreAudio: Default loopback format from device %u: %uHz %uch (format %d).",
                   (unsigned)dev, format_out->sample_rate, format_out->channels,
                   format_out->format);
        return MINIAV_SUCCESS;
    }

    format_out->sample_rate = 44100;
    format_out->channels = 2;
    format_out->format = MINIAV_AUDIO_FORMAT_F32;
    format_out->num_frames = 1024;
    miniav_log(MINIAV_LOG_LEVEL_WARN,
               "CoreAudio: Could not query device format for '%s' — returning "
               "fallback 44.1kHz/2ch/F32.",
               target_device_id ? target_device_id : "(default)");
    return MINIAV_SUCCESS;
}

static MiniAVResultCode coreaudio_get_supported_formats(const char* target_device_id,
                                                        MiniAVAudioInfo** formats_out,
                                                        uint32_t* count_out) {
    if (!formats_out || !count_out) return MINIAV_ERROR_INVALID_ARG;
    *formats_out = NULL;
    *count_out = 0;

    // Minimal but honest implementation (this op used to be a NULL pointer,
    // making MiniAV_Loopback_GetSupportedFormats fail unconditionally on
    // macOS): report the device's current format — the one capture will
    // actually deliver.
    MiniAVAudioInfo current;
    MiniAVResultCode res = coreaudio_get_default_format(target_device_id, &current);
    if (res != MINIAV_SUCCESS) return res;

    *formats_out = (MiniAVAudioInfo*)miniav_calloc(1, sizeof(MiniAVAudioInfo));
    if (!*formats_out) return MINIAV_ERROR_OUT_OF_MEMORY;
    (*formats_out)[0] = current;
    *count_out = 1;
    return MINIAV_SUCCESS;
}

// Picks the system-audio capture mode with the required preference order:
//   Audio Tap (14.2+) -> SCK audio (13.0+) -> virtual device -> error.
// The Audio Tap private API only actually works on macOS 14.2+; below that the
// AudioHardwareCreateProcessTap path fails at start, so when the SDK is present
// but we are on an older OS we prefer SCK (no third-party driver needed) and
// only fall through to a virtual device if neither is available. Sets
// platCtx->capture_mode (and virtual_device_id for the VD case) and returns
// MINIAV_SUCCESS, or MINIAV_ERROR_NOT_SUPPORTED when nothing is available.
static MiniAVResultCode coreaudio_choose_system_audio_mode(
    CoreAudioLoopbackPlatformContext* platCtx) {
#if HAS_AUDIO_TAP_API
    if (@available(macOS 14.2, *)) {
        platCtx->capture_mode = CAPTURE_MODE_SYSTEM_TAP;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "CoreAudio: Configured for system audio capture (Audio Tap, macOS 14.2+).");
        return MINIAV_SUCCESS;
    }
#endif
#if HAS_SCK_AUDIO_API
    if (@available(macOS 13.0, *)) {
        platCtx->capture_mode = CAPTURE_MODE_SCK_AUDIO;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "CoreAudio: Configured for system audio capture (ScreenCaptureKit, macOS 13.0+).");
        return MINIAV_SUCCESS;
    }
#endif
    platCtx->virtual_device_id = FindVirtualAudioDevice();
    if (platCtx->virtual_device_id != kAudioObjectUnknown) {
        platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "CoreAudio: Configured for system audio capture (Virtual Device).");
        return MINIAV_SUCCESS;
    }
    miniav_log(MINIAV_LOG_LEVEL_ERROR,
               "CoreAudio: No system audio capture method available.");
    return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode coreaudio_configure_loopback(MiniAVLoopbackContext* ctx,
                                                     const MiniAVLoopbackTargetInfo* target_info,
                                                     const char* target_device_id,
                                                     const MiniAVAudioInfo* requested_format) {
    if (!ctx || !ctx->platform_ctx || !requested_format) return MINIAV_ERROR_INVALID_ARG;
    
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;
    
    // Store requested format
    MiniAVFormatToCoreAudio(requested_format, &platCtx->stream_format);
    
    // Determine capture method based on target
    if (target_info && target_info->type == MINIAV_LOOPBACK_TARGET_PROCESS) {
        #if HAS_AUDIO_TAP_API
        platCtx->target_pid = target_info->TARGETHANDLE.process_id;
        platCtx->capture_mode = CAPTURE_MODE_PROCESS_TAP;
        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for process audio capture (PID: %d)", platCtx->target_pid);
        #else
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Process capture not supported in this build");
        return MINIAV_ERROR_NOT_SUPPORTED;
        #endif
    } else if (target_info && target_info->type == MINIAV_LOOPBACK_TARGET_WINDOW) {
        #if HAS_AUDIO_TAP_API
        // For window targets, we need to get the process ID from the window handle
        // On macOS, window handles are typically CGWindowID
        CGWindowID windowID = (CGWindowID)(uintptr_t)target_info->TARGETHANDLE.window_handle;
        
        // Get window info to find the owning process
        CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
        if (windowList && CFArrayGetCount(windowList) > 0) {
            CFDictionaryRef windowInfo = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, 0);
            CFNumberRef pidNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerPID);
            
            if (pidNumber) {
                CFNumberGetValue(pidNumber, kCFNumberIntType, &platCtx->target_pid);
                platCtx->capture_mode = CAPTURE_MODE_PROCESS_TAP;
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for window audio capture (Window ID: %u, PID: %d)", 
                           windowID, platCtx->target_pid);
            } else {
                miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to get process ID for window %u", windowID);
                if (windowList) CFRelease(windowList);
                return MINIAV_ERROR_INVALID_ARG;
            }
            CFRelease(windowList);
        } else {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to get info for window %u", windowID);
            if (windowList) CFRelease(windowList);
            return MINIAV_ERROR_INVALID_ARG;
        }
        #else
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Window capture not supported in this build");
        return MINIAV_ERROR_NOT_SUPPORTED;
        #endif
    } else if (target_info && target_info->type == MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO) {
        // Order: Audio Tap (14.2+) -> SCK audio (13.0+) -> virtual device.
        MiniAVResultCode mode_res = coreaudio_choose_system_audio_mode(platCtx);
        if (mode_res != MINIAV_SUCCESS) {
            return mode_res;
        }
    } else if (target_device_id) {
        if (strncmp(target_device_id, "pid:", 4) == 0) {
            #if HAS_AUDIO_TAP_API
            sscanf(target_device_id + 4, "%d", &platCtx->target_pid);
            platCtx->capture_mode = CAPTURE_MODE_PROCESS_TAP;
            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for process capture (PID: %d)", platCtx->target_pid);
            #else
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Process capture not supported in this build");
            return MINIAV_ERROR_NOT_SUPPORTED;
            #endif
        } else if (strncmp(target_device_id, "window:", 7) == 0) {
            #if HAS_AUDIO_TAP_API
            CGWindowID windowID;
            sscanf(target_device_id + 7, "%u", &windowID);
            
            // Get window info to find the owning process
            CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
            if (windowList && CFArrayGetCount(windowList) > 0) {
                CFDictionaryRef windowInfo = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, 0);
                CFNumberRef pidNumber = (CFNumberRef)CFDictionaryGetValue(windowInfo, kCGWindowOwnerPID);
                
                if (pidNumber) {
                    CFNumberGetValue(pidNumber, kCFNumberIntType, &platCtx->target_pid);
                    platCtx->capture_mode = CAPTURE_MODE_PROCESS_TAP;
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for window capture (Window ID: %u, PID: %d)", 
                               windowID, platCtx->target_pid);
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to get process ID for window %u", windowID);
                    if (windowList) CFRelease(windowList);
                    return MINIAV_ERROR_INVALID_ARG;
                }
                CFRelease(windowList);
            } else {
                miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to get info for window %u", windowID);
                if (windowList) CFRelease(windowList);
                return MINIAV_ERROR_INVALID_ARG;
            }
            #else
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Window capture not supported in this build");
            return MINIAV_ERROR_NOT_SUPPORTED;
            #endif
        } else if (strcmp(target_device_id, "system_tap") == 0 ||
                   strcmp(target_device_id, "system_audio_capture") == 0) {
            // System-audio device id: apply the same preference order as the
            // MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO branch so a stock macOS 13.x
            // machine with no virtual driver gets SCK audio instead of failing.
            // Order: Audio Tap (14.2+) -> SCK audio (13.0+) -> virtual device.
            MiniAVResultCode mode_res = coreaudio_choose_system_audio_mode(platCtx);
            if (mode_res != MINIAV_SUCCESS) {
                return mode_res;
            }
        } else if (strcmp(target_device_id, "process_tap") == 0) {
            #if HAS_AUDIO_TAP_API
            platCtx->capture_mode = CAPTURE_MODE_PROCESS_TAP;
            platCtx->target_pid = 0; // Will target current process or be set later
            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for process audio tap");
            #else
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Process tap not supported in this build");
            return MINIAV_ERROR_NOT_SUPPORTED;
            #endif
        } else if (strncmp(target_device_id, "virtual_device:", 15) == 0) {
            sscanf(target_device_id + 15, "%u", &platCtx->virtual_device_id);
            platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Configured for virtual device capture (ID: %u)", 
                       platCtx->virtual_device_id);
        } else if (strcmp(target_device_id, "no_virtual_device") == 0) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: No virtual audio device available");
            return MINIAV_ERROR_DEVICE_NOT_FOUND;
        } else {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Unknown device target: %s", target_device_id);
            return MINIAV_ERROR_DEVICE_NOT_FOUND;
        }
    } else {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: No target specified");
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    ctx->is_configured = true;
    return MINIAV_SUCCESS;
}

static MiniAVResultCode coreaudio_get_configured_format(MiniAVLoopbackContext* ctx, MiniAVAudioInfo* format_out) {
    if (!ctx || !ctx->platform_ctx || !format_out) return MINIAV_ERROR_INVALID_ARG;
    
    if (!ctx->is_configured) {
        return MINIAV_ERROR_NOT_INITIALIZED;
    }
    
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;
    
    format_out->sample_rate = (uint32_t)platCtx->stream_format.mSampleRate;
    format_out->channels = platCtx->stream_format.mChannelsPerFrame;
    format_out->format = CoreAudioFormatToMiniAV(&platCtx->stream_format);
    format_out->num_frames = 1024; // Default frame count

    return MINIAV_SUCCESS;
}

#if HAS_SCK_AUDIO_API
// Tears down the SCStream audio path with the same bounded-completion +
// queue-drain protocol the screen backend uses. Safe to call whether or not a
// stream was ever created. MUST be balanced against coreaudio_sck_start (every
// alloc'd stream/config/delegate released exactly once). Runs under the SDK
// availability guard supplied by the caller.
API_AVAILABLE(macos(13.0))
static void coreaudio_sck_teardown(CoreAudioLoopbackPlatformContext* platCtx) {
    @autoreleasepool {
        // Abandon any in-flight async start chain and consume its terminal
        // signal so a timed-out start's block cannot touch freed state.
        __sync_fetch_and_add(&platCtx->sck_start_generation, 1);
        if (platCtx->sck_start_pending && platCtx->sck_start_sem) {
            if (dispatch_semaphore_wait(
                    platCtx->sck_start_sem,
                    dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0) {
                platCtx->sck_start_pending = false;
            } else {
                miniav_log(MINIAV_LOG_LEVEL_WARN,
                           "CoreAudio: SCK start chain still pending at teardown.");
            }
        }

        if (platCtx->sck_stream) {
            // Bounded wait for the stream to actually stop so teardown does
            // not race in-flight audio sample callbacks.
            dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
            [platCtx->sck_stream stopCaptureWithCompletionHandler:^(NSError* error) {
                if (error) {
                    miniav_log(MINIAV_LOG_LEVEL_WARN,
                               "CoreAudio: SCK stopCapture error: %s",
                               [[error localizedDescription] UTF8String]);
                }
                dispatch_semaphore_signal(stopSem);
            }];
            if (dispatch_semaphore_wait(
                    stopSem,
                    dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
                miniav_log(MINIAV_LOG_LEVEL_WARN,
                           "CoreAudio: SCK stopCapture completion timed out.");
            }
            dispatch_release(stopSem); // MRC: balance the create
            [platCtx->sck_stream release];
            platCtx->sck_stream = nil;
        }
        if (platCtx->sck_config) {
            [platCtx->sck_config release];
            platCtx->sck_config = nil;
        }
        if (platCtx->sck_delegate) {
            [platCtx->sck_delegate release];
            platCtx->sck_delegate = nil;
        }
        // Drain any in-flight audio sample-handler block before returning so
        // the caller may clear callbacks or free the context right after. Skip
        // when already ON the audio queue (stop called from inside a sample
        // callback): dispatch_sync onto the current serial queue would
        // self-deadlock.
        if (platCtx->sck_audio_queue) {
            if (dispatch_get_specific(kMiniAVLoopbackSCKQueueKey) == NULL) {
                dispatch_sync(platCtx->sck_audio_queue, ^{});
            }
            dispatch_release(platCtx->sck_audio_queue);
            platCtx->sck_audio_queue = nil;
        }
        platCtx->sck_is_streaming = false;
    }
}

// Starts SCStream system-audio capture. Mirrors the hardened bounded-semaphore
// start pattern from screen_context_macos_cg.mm's cg_start_capture: block on an
// async getShareableContent->configure->startCapture chain with a 10s timeout
// (MINIAV_ERROR_TIMEOUT), every failure branch signals the semaphore exactly
// once, and a generation guard abandons a timed-out chain so its blocks bail
// instead of using freed state. Returns MINIAV_SUCCESS only once SCK actually
// started. Must be called with the capture_mutex HELD by the caller (matches
// the tap/virtual-device paths). Runs under the caller's availability guard.
API_AVAILABLE(macos(13.0))
static MiniAVResultCode coreaudio_sck_start(MiniAVLoopbackContext* ctx,
                                            CoreAudioLoopbackPlatformContext* platCtx) {
    @autoreleasepool {
        if (!platCtx->sck_start_sem) {
            platCtx->sck_start_sem = dispatch_semaphore_create(0);
            if (!platCtx->sck_start_sem) {
                return MINIAV_ERROR_OUT_OF_MEMORY;
            }
        }
        // Dedicated serial queue for the audio SCStreamOutput.
        platCtx->sck_audio_queue =
            dispatch_queue_create("com.miniav.loopback.sck.audio", DISPATCH_QUEUE_SERIAL);
        if (!platCtx->sck_audio_queue) {
            return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }
        // Tag the queue so teardown can detect same-queue reentrancy (an app
        // stopping from inside its own audio callback) and skip the drain.
        dispatch_queue_set_specific(platCtx->sck_audio_queue,
                                    kMiniAVLoopbackSCKQueueKey, (void*)1, NULL);

        const int32_t startGen = __sync_add_and_fetch(&platCtx->sck_start_generation, 1);
        platCtx->sck_start_pending = true;
        __block MiniAVResultCode startResult = MINIAV_ERROR_SYSTEM_CALL_FAILED;

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError* error) {
            if (platCtx->sck_start_generation != startGen) {
                // Abandoned (timeout/stop/destroy) — deliver terminal signal
                // only; do not touch setup state.
                dispatch_semaphore_signal(platCtx->sck_start_sem);
                return;
            }
            if (error || !content) {
                miniav_log(MINIAV_LOG_LEVEL_ERROR,
                           "CoreAudio: SCK failed to get shareable content%s%s",
                           error ? ": " : "",
                           error ? [[error localizedDescription] UTF8String] : "");
                dispatch_semaphore_signal(platCtx->sck_start_sem);
                return;
            }

            // Audio is display-independent but SCK requires a content filter;
            // use the first display and exclude no windows.
            SCDisplay* targetDisplay = content.displays.firstObject;
            if (!targetDisplay) {
                miniav_log(MINIAV_LOG_LEVEL_ERROR,
                           "CoreAudio: SCK has no displays available for the audio filter.");
                dispatch_semaphore_signal(platCtx->sck_start_sem);
                return;
            }

            SCContentFilter* filter =
                [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];

            platCtx->sck_config = [[SCStreamConfiguration alloc] init];
            platCtx->sck_config.capturesAudio = YES;
            platCtx->sck_config.sampleRate = 48000;
            platCtx->sck_config.channelCount = 2;
            // Do not capture our own process's audio into the loopback.
            platCtx->sck_config.excludesCurrentProcessAudio = YES;

            platCtx->sck_delegate =
                [[MiniAVLoopbackSCKAudioDelegate alloc] initWithPlatformContext:platCtx];
            platCtx->sck_stream = [[SCStream alloc] initWithFilter:filter
                                                     configuration:platCtx->sck_config
                                                          delegate:platCtx->sck_delegate];

            NSError* addAudioError = nil;
            BOOL audioOK = [platCtx->sck_stream addStreamOutput:(id<SCStreamOutput>)platCtx->sck_delegate
                                                           type:SCStreamOutputTypeAudio
                                             sampleHandlerQueue:platCtx->sck_audio_queue
                                                          error:&addAudioError];
            [filter release];
            if (!audioOK) {
                miniav_log(MINIAV_LOG_LEVEL_ERROR,
                           "CoreAudio: SCK failed to add audio output: %s",
                           addAudioError ? [[addAudioError localizedDescription] UTF8String]
                                         : "Unknown error");
                dispatch_semaphore_signal(platCtx->sck_start_sem);
                return;
            }

            [platCtx->sck_stream startCaptureWithCompletionHandler:^(NSError* startErr) {
                if (platCtx->sck_start_generation != startGen) {
                    // Abandoned while starting: do not leave a headless stream
                    // running (nobody would ever stop it).
                    if (!startErr && platCtx->sck_stream) {
                        [platCtx->sck_stream stopCaptureWithCompletionHandler:nil];
                    }
                    dispatch_semaphore_signal(platCtx->sck_start_sem);
                    return;
                }
                if (startErr) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR,
                               "CoreAudio: SCK failed to start audio stream: %s",
                               [[startErr localizedDescription] UTF8String]);
                } else {
                    platCtx->sck_is_streaming = true;
                    startResult = MINIAV_SUCCESS;
                    miniav_log(MINIAV_LOG_LEVEL_INFO,
                               "CoreAudio: SCK system-audio capture started (48kHz stereo).");
                }
                dispatch_semaphore_signal(platCtx->sck_start_sem);
            }];
        }];

        // Bounded wait for the async chain to reach a definitive state.
        if (dispatch_semaphore_wait(
                platCtx->sck_start_sem,
                dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR,
                       "CoreAudio: SCK StartCapture timed out — abandoning the "
                       "attempt (the chain cleans up after itself).");
            // Abandon: the chain sees the stale generation, undoes any started
            // stream, and signals; sck_start_pending stays true until
            // stop/destroy consumes that signal.
            __sync_fetch_and_add(&platCtx->sck_start_generation, 1);
            return MINIAV_ERROR_TIMEOUT;
        }
        platCtx->sck_start_pending = false;

        if (startResult != MINIAV_SUCCESS) {
            // Setup failed cleanly (not a timeout): release what we built so a
            // later start / destroy is not left with dangling objects.
            if (platCtx->sck_stream) {
                [platCtx->sck_stream release];
                platCtx->sck_stream = nil;
            }
            if (platCtx->sck_config) {
                [platCtx->sck_config release];
                platCtx->sck_config = nil;
            }
            if (platCtx->sck_delegate) {
                [platCtx->sck_delegate release];
                platCtx->sck_delegate = nil;
            }
            if (platCtx->sck_audio_queue) {
                dispatch_release(platCtx->sck_audio_queue);
                platCtx->sck_audio_queue = nil;
            }
        }
        return startResult;
    }
}
#endif // HAS_SCK_AUDIO_API


static MiniAVResultCode coreaudio_start_capture(MiniAVLoopbackContext* ctx, MiniAVBufferCallback callback, void* user_data) {
    if (!ctx || !ctx->platform_ctx || !callback) return MINIAV_ERROR_INVALID_ARG;
    
    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;

    // Set the callback and user_data on the main context for use by IOProcs/AudioUnit callbacks
    ctx->app_callback = callback;
    ctx->app_callback_user_data = user_data;
    
    if (platCtx->is_capturing) {
        miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Capture already running");
        return MINIAV_ERROR_ALREADY_RUNNING;
    }
    
    if (platCtx->capture_mode == CAPTURE_MODE_NONE) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Not configured");
        return MINIAV_ERROR_NOT_INITIALIZED;
    }
    
    pthread_mutex_lock(&platCtx->capture_mutex);
    platCtx->should_stop_capture = false;
    platCtx->lost_cb_fired = false; // fresh loss-notification guard per run

    OSStatus status = noErr;
    
#if HAS_AUDIO_TAP_API
    if (platCtx->capture_mode == CAPTURE_MODE_SYSTEM_TAP || platCtx->capture_mode == CAPTURE_MODE_PROCESS_TAP) {
        miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Attempting to start Audio Tap capture (mode: %d)", platCtx->capture_mode);
        
        @autoreleasepool {
            NSProcessInfo *processInfo = [NSProcessInfo processInfo];
            int currentProcessID = [processInfo processIdentifier];
            NSUUID* tapUUID = [NSUUID UUID];
            CATapDescription *desc = nil;
            
            if (platCtx->capture_mode == CAPTURE_MODE_PROCESS_TAP && platCtx->target_pid > 0) {
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Creating process-specific tap for PID: %d", platCtx->target_pid);
                
                // Check if the target process exists and get more info about it
                char process_name[256] = {0};
                bool process_exists = GetProcessNameByPID(platCtx->target_pid, process_name, sizeof(process_name));
                
                if (!process_exists) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Target process PID %d does not exist or is not accessible", platCtx->target_pid);
                    status = kAudioHardwareIllegalOperationError;
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Target process: %s (PID: %d)", process_name, platCtx->target_pid);
                    
                    // Check if process has active audio
                    if (!ProcessHasActiveAudio(platCtx->target_pid)) {
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Process %d (%s) does not have active audio streams", platCtx->target_pid, process_name);
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Process tap may fail - try starting audio in the target application first");
                    }
                    
                    // Convert PID to Audio Process Object ID
                    AudioObjectID processObjectID = kAudioObjectUnknown;
                    if (!PIDToAudioProcessObjectID(platCtx->target_pid, &processObjectID)) {
                        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to get process object ID for PID %d", platCtx->target_pid);
                        status = kAudioHardwareIllegalOperationError;
                    } else {
                        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Using process object ID %u for tap creation", processObjectID);
                        
                        // Use the process object ID instead of PID
                        NSArray* processArray = [NSArray arrayWithObject:[NSNumber numberWithUnsignedInt:processObjectID]];
                        
                        // Try the most common method first
                        if ([CATapDescription instancesRespondToSelector:@selector(initStereoMixdownOfProcesses:)]) {
                            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Using initStereoMixdownOfProcesses method");
                            desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processArray];
                        }
                        
                        // If that didn't work, try other methods
                        if (!desc && [CATapDescription instancesRespondToSelector:@selector(initWithProcesses:andDeviceUID:)]) {
                            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Trying initWithProcesses:andDeviceUID method");
                            desc = [[CATapDescription alloc] initWithProcesses:processArray andDeviceUID:nil];
                        }
                        
                        // As a last resort, try mono mixdown
                        if (!desc && [CATapDescription instancesRespondToSelector:@selector(initMonoMixdownOfProcesses:)]) {
                            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Trying initMonoMixdownOfProcesses method");
                            desc = [[CATapDescription alloc] initMonoMixdownOfProcesses:processArray];
                        }
                        
                        if (!desc) {
                            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to init CATapDescription for process object ID %u using any available method", processObjectID);
                            status = kAudioHardwareIllegalOperationError;
                        } else {
                            miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Successfully created CATapDescription for process tap");
                        }
                    }
                }
            } else if (platCtx->capture_mode == CAPTURE_MODE_SYSTEM_TAP) {
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Creating system-wide audio tap");
                
                // Try different initialization methods based on macOS version
                if (@available(macOS 10.15, *)) {
                    if ([CATapDescription instancesRespondToSelector:@selector(initStereoGlobalTapButExcludeProcesses:)]) {
                        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Using initStereoGlobalTapButExcludeProcesses method");
                        desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
                    }
                }
                
                if (!desc && [CATapDescription instancesRespondToSelector:@selector(initStereoGlobalTap)]) {
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Using initStereoGlobalTap method");
                    desc = [[CATapDescription alloc] initStereoGlobalTap];
                }
                
                if (!desc) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to init CATapDescription for system output");
                    status = kAudioHardwareIllegalOperationError;
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Successfully created CATapDescription for system tap");
                }
            }

            if (desc && status == noErr) {
                // Configure the tap description
                desc.name = [NSString stringWithFormat:@"miniav-tap-%d-%d", currentProcessID, (int)platCtx->capture_mode];
                desc.UUID = tapUUID;
                desc.privateTap = true;
                desc.muteBehavior = CATapUnmuted;
                desc.exclusive = false;
                desc.mixdown = true;
                
                // Log tap configuration for debugging
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Tap config - Name: %s, Private: %s, Exclusive: %s, Mixdown: %s", 
                          [desc.name UTF8String],
                          desc.privateTap ? "YES" : "NO",
                          desc.exclusive ? "YES" : "NO", 
                          desc.mixdown ? "YES" : "NO");
                
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Attempting to create process tap with description");
                status = AudioHardwareCreateProcessTap(desc, &platCtx->tap_id);
                
                // Log the specific error with more detail
                if (status != noErr) {
                    const char* error_name = "Unknown";
                    switch (status) {
                        case kAudioHardwareNotRunningError:
                            error_name = "Audio Hardware Not Running";
                            break;
                        case kAudioHardwareUnspecifiedError:
                            error_name = "Unspecified Hardware Error";
                            break;
                        case kAudioHardwareIllegalOperationError:
                            error_name = "Illegal Operation (Permission Denied)";
                            break;
                        case kAudioHardwareBadPropertySizeError:
                            error_name = "Bad Property Size";
                            break;
                        case kAudioHardwareUnsupportedOperationError:
                            error_name = "Unsupported Operation";
                            break;
                        case 560947818: // The specific error you mentioned
                            error_name = "Audio Tap Creation Failed (Process may not have audio output)";
                            break;
                        default:
                            break;
                    }
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: AudioHardwareCreateProcessTap failed with status %d (0x%X): %s", 
                               status, status, error_name);
                    
                    // For process taps specifically, provide more targeted guidance
                    if (platCtx->capture_mode == CAPTURE_MODE_PROCESS_TAP) {
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Process tap creation failed. This may be because:");
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "  1. The target process (PID: %d) is not currently producing audio output", platCtx->target_pid);
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "  2. The process doesn't have audio units or streams active");
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "  3. The process is a system process that doesn't allow tapping");
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "  4. Try playing audio in the target process first, then start capture");
                    }
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Process tap created successfully (ID: %u)", (unsigned int)platCtx->tap_id);
                }
            } else if (!desc) {
                status = kAudioHardwareIllegalOperationError;
                miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Could not create CATapDescription");
            }
            
            // Rest of the aggregated device creation logic...
            if (status != noErr) { 
                miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Audio Tap creation failed, falling back to virtual device capture");
                platCtx->virtual_device_id = FindVirtualAudioDevice();
                if (platCtx->virtual_device_id != kAudioObjectUnknown) {
                    platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
                    miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Successfully found virtual device ID %u for fallback", platCtx->virtual_device_id);
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: No virtual audio device found for fallback");
                    miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Consider installing BlackHole (https://github.com/ExistentialAudio/BlackHole) for system audio capture");
                    pthread_mutex_unlock(&platCtx->capture_mutex);
                    return MINIAV_ERROR_DEVICE_NOT_FOUND;
                }
            } else {
                // Successfully created tap, continue with aggregated device creation
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Process tap created successfully, creating aggregated device");
                
                NSString *deviceName = [NSString stringWithFormat:@"miniav-aggregated-%d", currentProcessID];
                NSNumber *isPrivateKey = [NSNumber numberWithBool:true];
                
                NSArray* tapConf = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithBool:true], [NSString stringWithUTF8String:kAudioSubTapDriftCompensationKey],
                                    tapUUID.UUIDString, [NSString stringWithUTF8String:kAudioSubTapUIDKey],
                                    nil]];
                
                NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                                      deviceName, [NSString stringWithUTF8String:kAudioAggregateDeviceNameKey],
                                      [[NSUUID UUID] UUIDString], [NSString stringWithUTF8String:kAudioAggregateDeviceUIDKey],
                                      isPrivateKey, [NSString stringWithUTF8String:kAudioAggregateDeviceIsPrivateKey],
                                      tapConf, [NSString stringWithUTF8String:kAudioAggregateDeviceTapListKey],
                                      nil];
                
                CFDictionaryRef dictBridge = (__bridge CFDictionaryRef)dict;
                status = AudioHardwareCreateAggregateDevice(dictBridge, &platCtx->aggregated_id);
                
                if (status != noErr) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to create aggregate device: %d (0x%X)", status, status);
                    AudioHardwareDestroyProcessTap(platCtx->tap_id);
                    platCtx->tap_id = kAudioObjectUnknown;
                    
                    // Fallback to virtual device
                    platCtx->virtual_device_id = FindVirtualAudioDevice();
                    if (platCtx->virtual_device_id != kAudioObjectUnknown) {
                        platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
                    } else {
                        pthread_mutex_unlock(&platCtx->capture_mutex);
                        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
                    }
                } else {
                    status = AudioDeviceCreateIOProcID(platCtx->aggregated_id, AudioTapIOProc, platCtx, &platCtx->io_proc_id);
                    if (status != noErr) {
                        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to create IOProc: %d (0x%X)", status, status);
                        AudioHardwareDestroyAggregateDevice(platCtx->aggregated_id);
                        AudioHardwareDestroyProcessTap(platCtx->tap_id);
                        platCtx->aggregated_id = kAudioObjectUnknown;
                        platCtx->tap_id = kAudioObjectUnknown;
                        
                        // Fallback to virtual device
                        platCtx->virtual_device_id = FindVirtualAudioDevice();
                        if (platCtx->virtual_device_id != kAudioObjectUnknown) {
                            platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
                        } else {
                            pthread_mutex_unlock(&platCtx->capture_mutex);
                            return MINIAV_ERROR_SYSTEM_CALL_FAILED;
                        }
                    } else {
                        // Read back the aggregate device's ACTUAL stream
                        // format BEFORE starting IO: the IOProc computes
                        // frame counts from stream_format, and publishing it
                        // after start would race the realtime thread (and
                        // the requested format previously stood in for the
                        // negotiated one entirely).
                        {
                            AudioStreamBasicDescription negotiated;
                            if (coreaudio_read_device_format(platCtx->aggregated_id,
                                                             kAudioObjectPropertyScopeInput,
                                                             &negotiated)) {
                                platCtx->stream_format = negotiated;
                                miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                                           "CoreAudio: Tap negotiated format %.0fHz %uch %ubytes/frame.",
                                           negotiated.mSampleRate,
                                           (unsigned)negotiated.mChannelsPerFrame,
                                           (unsigned)negotiated.mBytesPerFrame);
                            } else {
                                miniav_log(MINIAV_LOG_LEVEL_WARN,
                                           "CoreAudio: Could not read aggregate device format — "
                                           "using the requested format.");
                            }
                        }
                        status = AudioDeviceStart(platCtx->aggregated_id, platCtx->io_proc_id);
                        if (status != noErr) {
                            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to start audio device: %d (0x%X)", status, status);
                            AudioDeviceDestroyIOProcID(platCtx->aggregated_id, platCtx->io_proc_id);
                            AudioHardwareDestroyAggregateDevice(platCtx->aggregated_id);
                            AudioHardwareDestroyProcessTap(platCtx->tap_id);
                            platCtx->io_proc_id = NULL;
                            platCtx->aggregated_id = kAudioObjectUnknown;
                            platCtx->tap_id = kAudioObjectUnknown;
                            
                            // Fallback to virtual device
                            platCtx->virtual_device_id = FindVirtualAudioDevice();
                            if (platCtx->virtual_device_id != kAudioObjectUnknown) {
                                platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
                            } else {
                                pthread_mutex_unlock(&platCtx->capture_mutex);
                                return MINIAV_ERROR_SYSTEM_CALL_FAILED;
                            }
                        } else {
                            // Successfully started tap (the negotiated
                            // format was read back before AudioDeviceStart).
                            platCtx->is_capturing = true;
                            ctx->is_running = true;
                            pthread_mutex_unlock(&platCtx->capture_mutex);
                            // Outside the mutex: registration talks to
                            // coreaudiod and must not extend the critical
                            // section.
                            coreaudio_install_alive_listener(platCtx, platCtx->aggregated_id);
                            miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Audio Tap capture started successfully");
                            return MINIAV_SUCCESS;
                        }
                    }
                }
            }
        } // @autoreleasepool
    }
#endif // HAS_AUDIO_TAP_API

#if HAS_SCK_AUDIO_API
    // ScreenCaptureKit system-audio capture (preferred fallback below 14.2,
    // ahead of the virtual-device requirement).
    if (platCtx->capture_mode == CAPTURE_MODE_SCK_AUDIO) {
        if (@available(macOS 13.0, *)) {
            miniav_log(MINIAV_LOG_LEVEL_INFO,
                       "CoreAudio: Starting ScreenCaptureKit system-audio capture.");
            // Mark capturing BEFORE the stream starts so the delegate's audio
            // sample callbacks are honoured (the mutex is held; the async
            // start chain blocks the caller until it resolves).
            platCtx->is_capturing = true;
            MiniAVResultCode sck_res = coreaudio_sck_start(ctx, platCtx);
            if (sck_res == MINIAV_SUCCESS) {
                // SCK delivers 48kHz/2ch/F32 (the config we set); make
                // get_configured_format report that rather than the caller's
                // original request, so a downstream encoder is sized correctly.
                platCtx->stream_format.mSampleRate = 48000;
                platCtx->stream_format.mChannelsPerFrame = 2;
                platCtx->stream_format.mFormatID = kAudioFormatLinearPCM;
                platCtx->stream_format.mFormatFlags =
                    kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                platCtx->stream_format.mBitsPerChannel = 32;
                platCtx->stream_format.mFramesPerPacket = 1;
                platCtx->stream_format.mBytesPerFrame = 8;  // 2ch * 4 bytes
                platCtx->stream_format.mBytesPerPacket = 8;
                ctx->is_running = true;
                pthread_mutex_unlock(&platCtx->capture_mutex);
                miniav_log(MINIAV_LOG_LEVEL_INFO,
                           "CoreAudio: ScreenCaptureKit system-audio capture started successfully.");
                return MINIAV_SUCCESS;
            }
            // SCK failed — undo the optimistic flag and try a virtual device as
            // a last resort (mirrors the tap path's fallback). Tear down any
            // abandoned SCK chain FIRST: on a timeout coreaudio_sck_start
            // leaves the stream/delegate live (to be drained by teardown), and
            // if we switch to a virtual device without draining it, (a) stop
            // would mistake the leftover state for an SCK capture and never
            // stop the virtual device, and (b) the orphaned stream's
            // didStopWithError could fire a spurious lost_cb against the live
            // virtual-device capture.
            platCtx->is_capturing = false;
            coreaudio_sck_teardown(platCtx);
            platCtx->capture_mode = CAPTURE_MODE_NONE;
            miniav_log(MINIAV_LOG_LEVEL_WARN,
                       "CoreAudio: SCK system-audio start failed (%d), trying virtual device.",
                       (int)sck_res);
            platCtx->virtual_device_id = FindVirtualAudioDevice();
            if (platCtx->virtual_device_id != kAudioObjectUnknown) {
                platCtx->capture_mode = CAPTURE_MODE_VIRTUAL_DEVICE;
            } else {
                pthread_mutex_unlock(&platCtx->capture_mutex);
                return sck_res;
            }
        }
    }
#endif // HAS_SCK_AUDIO_API

    // Virtual device capture (primary if tap not available/supported, or fallback if tap failed)
    if (platCtx->capture_mode == CAPTURE_MODE_VIRTUAL_DEVICE) {
        miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Starting virtual device capture.");
        if (platCtx->virtual_device_id == kAudioObjectUnknown) {
            // Attempt to find one last time if not already set by a failed tap attempt
            platCtx->virtual_device_id = FindVirtualAudioDevice();
            if (platCtx->virtual_device_id == kAudioObjectUnknown) {
                miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: No virtual device ID available for virtual device capture mode.");
                pthread_mutex_unlock(&platCtx->capture_mutex);
                return MINIAV_ERROR_DEVICE_NOT_FOUND;
            }
        }

        AudioComponentDescription compDesc;
        compDesc.componentType = kAudioUnitType_Output;
        compDesc.componentSubType = kAudioUnitSubType_HALOutput;
        compDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
        compDesc.componentFlags = 0;
        compDesc.componentFlagsMask = 0;

        AudioComponent inputComponent = AudioComponentFindNext(NULL, &compDesc);
        if (!inputComponent) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to find input component for virtual device.");
            pthread_mutex_unlock(&platCtx->capture_mutex);
            return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        status = AudioComponentInstanceNew(inputComponent, &platCtx->input_unit);
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to create AudioUnit instance: %d", status);
            pthread_mutex_unlock(&platCtx->capture_mutex);
            return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        UInt32 enableFlag = 1;
        status = AudioUnitSetProperty(platCtx->input_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableFlag, sizeof(enableFlag));
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to enable input on AudioUnit: %d", status);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        enableFlag = 0;
        status = AudioUnitSetProperty(platCtx->input_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableFlag, sizeof(enableFlag));
         if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_WARN, "CoreAudio: Failed to disable output on AudioUnit: %d (continuing)", status);
        }

        status = AudioUnitSetProperty(platCtx->input_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &platCtx->virtual_device_id, sizeof(platCtx->virtual_device_id));
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to set current device on AudioUnit: %d", status);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }
        
        status = AudioUnitSetProperty(platCtx->input_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &platCtx->stream_format, sizeof(platCtx->stream_format));
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to set stream format on AudioUnit: %d", status);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        AURenderCallbackStruct callbackStruct;
        callbackStruct.inputProc = AudioInputCallback;
        callbackStruct.inputProcRefCon = platCtx;
        status = AudioUnitSetProperty(platCtx->input_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, sizeof(callbackStruct));
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to set input callback on AudioUnit: %d", status);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        // Initialize FIRST so the unit commits its real client format, then
        // read that format back BEFORE sizing the render buffer and BEFORE
        // the callback can run — sizing from the requested format risked an
        // undersized buffer if AUHAL coerced the format, and publishing
        // stream_format after start raced the realtime callback.
        status = AudioUnitInitialize(platCtx->input_unit);
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to initialize AudioUnit: %d", status);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        // Read back the format the AudioUnit will actually deliver into the
        // render callback (output scope of the input element) so reported
        // buffers — and the buffer allocation below — describe reality
        // rather than the request.
        {
            AudioStreamBasicDescription unit_fmt = {0};
            UInt32 fmt_size = sizeof(unit_fmt);
            if (AudioUnitGetProperty(platCtx->input_unit, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output, 1, &unit_fmt, &fmt_size) == noErr &&
                unit_fmt.mSampleRate > 0 && unit_fmt.mBytesPerFrame > 0) {
                platCtx->stream_format = unit_fmt;
                miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                           "CoreAudio: Virtual-device negotiated format %.0fHz %uch %ubytes/frame.",
                           unit_fmt.mSampleRate,
                           (unsigned)unit_fmt.mChannelsPerFrame,
                           (unsigned)unit_fmt.mBytesPerFrame);
            }
        }

        MiniAVAudioInfo configured_format;
        coreaudio_get_configured_format(ctx, &configured_format); // Get currently configured format for num_frames
        UInt32 bufferSizeFrames = configured_format.num_frames > 0 ? configured_format.num_frames : 1024;
        UInt32 bufferSizeBytes = bufferSizeFrames * platCtx->stream_format.mBytesPerFrame;

        platCtx->audio_buffer_list = (AudioBufferList*)miniav_calloc(1, offsetof(AudioBufferList, mBuffers) + (sizeof(AudioBuffer) * 1));
        if (!platCtx->audio_buffer_list) {
             miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to allocate audio buffer list.");
             AudioUnitUninitialize(platCtx->input_unit);
             AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
             pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_OUT_OF_MEMORY;
        }
        platCtx->audio_buffer_list->mNumberBuffers = 1;
        platCtx->audio_buffer_list->mBuffers[0].mNumberChannels = platCtx->stream_format.mChannelsPerFrame;
        platCtx->audio_buffer_list->mBuffers[0].mDataByteSize = bufferSizeBytes;
        platCtx->audio_buffer_list->mBuffers[0].mData = miniav_calloc(bufferSizeBytes, 1);

        if (!platCtx->audio_buffer_list->mBuffers[0].mData) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to allocate audio buffer data.");
            miniav_free(platCtx->audio_buffer_list); platCtx->audio_buffer_list = NULL;
            AudioUnitUninitialize(platCtx->input_unit);
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_OUT_OF_MEMORY;
        }

        status = AudioOutputUnitStart(platCtx->input_unit);
        if (status != noErr) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to start AudioUnit: %d", status);
            AudioUnitUninitialize(platCtx->input_unit);
            miniav_free(platCtx->audio_buffer_list->mBuffers[0].mData);
            miniav_free(platCtx->audio_buffer_list); platCtx->audio_buffer_list = NULL;
            AudioComponentInstanceDispose(platCtx->input_unit); platCtx->input_unit = NULL;
            pthread_mutex_unlock(&platCtx->capture_mutex); return MINIAV_ERROR_SYSTEM_CALL_FAILED;
        }

        platCtx->is_capturing = true;
        ctx->is_running = true;
        pthread_mutex_unlock(&platCtx->capture_mutex);
        // Outside the mutex: registration talks to coreaudiod and must not
        // extend the critical section.
        coreaudio_install_alive_listener(platCtx, platCtx->virtual_device_id);
        miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Virtual device capture started successfully.");
        return MINIAV_SUCCESS;
    }
    
    // If we reach here, it means neither tap nor virtual device capture was successful or applicable
    pthread_mutex_unlock(&platCtx->capture_mutex);
    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to start capture. No suitable method (Tap or Virtual Device) succeeded for mode %d.", platCtx->capture_mode);
    return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode coreaudio_stop_capture(MiniAVLoopbackContext* ctx) {
    if (!ctx || !ctx->platform_ctx) return MINIAV_ERROR_INVALID_ARG;

    CoreAudioLoopbackPlatformContext* platCtx = (CoreAudioLoopbackPlatformContext*)ctx->platform_ctx;

#if HAS_SCK_AUDIO_API
    // Tear down SCK BEFORE the is_capturing early-out: a timed-out start can
    // leave sck_start_pending true while is_capturing is still false, and the
    // teardown must drain that abandoned chain. coreaudio_sck_teardown runs
    // outside the capture_mutex (it stops the stream and drains its own audio
    // queue). Guarded by @available since it touches SCK objects.
    if (@available(macOS 13.0, *)) {
        // Drain ANY abandoned SCK chain (e.g. a timed-out start that fell back
        // to a virtual device leaves stream/pending/queue live) unconditionally
        // — but only RETURN early when SCK is the ACTUAL active capture. Falling
        // back to a virtual device with leftover SCK state must NOT skip the
        // virtual-device stop below.
        bool sck_is_active = (platCtx->capture_mode == CAPTURE_MODE_SCK_AUDIO);
        bool has_sck_state = platCtx->sck_stream || platCtx->sck_start_pending ||
                             platCtx->sck_audio_queue;
        if (sck_is_active || has_sck_state) {
            coreaudio_sck_teardown(platCtx);
        }
        if (sck_is_active) {
            platCtx->is_capturing = false;
            ctx->is_running = false;
            miniav_log(MINIAV_LOG_LEVEL_INFO,
                       "CoreAudio: SCK system-audio capture stopped.");
            return MINIAV_SUCCESS;
        }
    }
#endif

    if (!platCtx->is_capturing) {
        return MINIAV_SUCCESS;
    }

    pthread_mutex_lock(&platCtx->capture_mutex);
    platCtx->should_stop_capture = true;
    platCtx->is_capturing = false;
    ctx->is_running = false;

    coreaudio_remove_alive_listener(platCtx);

    #if HAS_AUDIO_TAP_API
    // Stop Audio Tap
    if (platCtx->io_proc_id && platCtx->aggregated_id != kAudioObjectUnknown) {
        AudioDeviceStop(platCtx->aggregated_id, platCtx->io_proc_id);
    }
    #endif

    // Stop AudioUnit
    if (platCtx->input_unit) {
        AudioOutputUnitStop(platCtx->input_unit);
        AudioUnitUninitialize(platCtx->input_unit);
    }

    pthread_mutex_unlock(&platCtx->capture_mutex);

    miniav_log(MINIAV_LOG_LEVEL_INFO, "CoreAudio: Loopback capture stopped");
    return MINIAV_SUCCESS;
}

static MiniAVResultCode coreaudio_release_buffer(MiniAVLoopbackContext* ctx, void* native_buffer_payload_ptr) {
    MINIAV_UNUSED(ctx);
    if (!native_buffer_payload_ptr) return MINIAV_ERROR_INVALID_ARG;
    
    MiniAVNativeBufferInternalPayload* payload = (MiniAVNativeBufferInternalPayload*)native_buffer_payload_ptr;
    
    if (payload->native_singular_resource_ptr) {
        miniav_free(payload->native_singular_resource_ptr);
        payload->native_singular_resource_ptr = NULL;
    }
    
    if (payload->parent_miniav_buffer_ptr) {
        miniav_free(payload->parent_miniav_buffer_ptr);
        payload->parent_miniav_buffer_ptr = NULL;
    }
    
    miniav_free(payload);
    return MINIAV_SUCCESS;
}

// --- Global Ops Table ---
const LoopbackContextInternalOps g_loopback_ops_macos_coreaudio = {
    .init_platform = coreaudio_init_platform,
    .destroy_platform = coreaudio_destroy_platform,
    .enumerate_targets_platform = coreaudio_enumerate_targets,
    .get_supported_formats = coreaudio_get_supported_formats,
    .get_default_format = coreaudio_get_default_format,
    .get_default_format_platform = coreaudio_get_default_format,
    .configure_loopback = coreaudio_configure_loopback,
    .start_capture = coreaudio_start_capture,
    .stop_capture = coreaudio_stop_capture,
    .release_buffer_platform = coreaudio_release_buffer,
    .get_configured_video_format = coreaudio_get_configured_format,
};

// --- Platform Init for Selection ---
MiniAVResultCode miniav_loopback_context_platform_init_macos_coreaudio(MiniAVLoopbackContext* ctx) {
    if (!ctx) return MINIAV_ERROR_INVALID_ARG;
    
    ctx->ops = &g_loopback_ops_macos_coreaudio;
    ctx->platform_ctx = miniav_calloc(1, sizeof(CoreAudioLoopbackPlatformContext));
    if (!ctx->platform_ctx) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CoreAudio: Failed to allocate platform context");
        ctx->ops = NULL;
        return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CoreAudio: Loopback platform selected");
    return MINIAV_SUCCESS;
}

#endif // __APPLE__