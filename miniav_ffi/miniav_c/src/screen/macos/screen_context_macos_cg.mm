#include "screen_context_macos_cg.h"
#include "../../common/miniav_logging.h"
#include "../../common/miniav_time.h"
#include "../../common/miniav_utils.h"
#include "../../../include/miniav_buffer.h"
#include <mach/mach_time.h>
#include <atomic>  // Add this for std::atomic

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

// ScreenCaptureKit is available on macOS 12.3+
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 120300
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#define HAS_SCREEN_CAPTURE_KIT 1
#else
#define HAS_SCREEN_CAPTURE_KIT 0
#endif

// Queue-specific tag for same-queue reentrancy detection on captureQueue.
static const void* kMiniAVScreenQueueKey = &kMiniAVScreenQueueKey;

// Forward declare the enum outside struct
typedef enum {
    CG_TARGET_NONE,
    CG_TARGET_DISPLAY,
    CG_TARGET_WINDOW
} CGCaptureTargetType;

// --- Platform Specific Context ---
typedef struct CGScreenPlatformContext {
    MiniAVScreenContext* parent_ctx;
    dispatch_queue_t captureQueue;
    std::atomic<bool> is_streaming;
    
    // Metal for GPU path
    id<MTLDevice> metalDevice;
    CVMetalTextureCacheRef textureCache;
    
    // Legacy Core Graphics capture (fallback)
    CGDirectDisplayID displayID;
    dispatch_source_t captureTimer;

    // Region capture: when captureRegion is true, the SCStream is cropped to
    // regionRect (points, top-left origin) via SCStreamConfiguration.sourceRect.
    bool captureRegion;
    CGRect regionRect;
    
    // Timing
    mach_timebase_info_data_t timebase;
    // Rebases SCK sample PTS (session clock) onto the shared
    // miniav_get_time_us() epoch (reset at start_capture).
    MiniAVTimebase ts_rebase;
    // One-shot guard so didStopWithError fires lost_cb exactly once per run.
    std::atomic<bool> lost_cb_fired;

    // Async start-chain coordination. The SCK setup chain signals
    // startChainSem exactly once when it reaches a terminal state. A bumped
    // startGeneration abandons an in-flight chain: its blocks bail (and stop
    // any stream they just started) instead of touching a context the caller
    // has moved past. startChainPending tracks an unconsumed terminal signal
    // so stop/destroy/a later start can drain it — destroy MUST NOT free the
    // context while a chain is pending (the blocks dereference it).
    dispatch_semaphore_t startChainSem;
    std::atomic<uint32_t> startGeneration;
    std::atomic<bool> startChainPending;

    // Callback info (following WGC pattern)
    MiniAVBufferCallback app_callback_internal;
    void* app_callback_user_data_internal;
    
    // Configuration (following WGC pattern)
    MiniAVVideoInfo configured_video_format;
    char selected_item_id[MINIAV_DEVICE_ID_MAX_LEN];
    
    // Target type - use the enum we declared above
    CGCaptureTargetType current_target_type;
    
    uint32_t frame_width;
    uint32_t frame_height;
    uint32_t target_fps;
    
#if HAS_SCREEN_CAPTURE_KIT
    // Modern ScreenCaptureKit capture (macOS 12.3+)
    SCStream* scStream API_AVAILABLE(macos(12.3));
    SCStreamConfiguration* scStreamConfig API_AVAILABLE(macos(12.3));
    id<SCStreamDelegate> scDelegate API_AVAILABLE(macos(12.3));
#endif
} CGScreenPlatformContext;

// --- Helper Functions ---
static MiniAVPixelFormat CGBitmapInfoToMiniAVPixelFormat(CGBitmapInfo bitmapInfo) {
    CGImageAlphaInfo alphaInfo = (CGImageAlphaInfo)(bitmapInfo & kCGBitmapAlphaInfoMask);
    CGBitmapInfo byteOrder = bitmapInfo & kCGBitmapByteOrderMask;
    
    if (byteOrder == kCGBitmapByteOrder32Little) {
        if (alphaInfo == kCGImageAlphaPremultipliedFirst) {
            return MINIAV_PIXEL_FORMAT_BGRA32;
        } else if (alphaInfo == kCGImageAlphaFirst || alphaInfo == kCGImageAlphaNoneSkipFirst) {
            return MINIAV_PIXEL_FORMAT_BGRA32;
        }
    }
    
    if (byteOrder == kCGBitmapByteOrder32Big || byteOrder == kCGBitmapByteOrderDefault) {
        if (alphaInfo == kCGImageAlphaPremultipliedLast || alphaInfo == kCGImageAlphaLast) {
            return MINIAV_PIXEL_FORMAT_RGBA32;
        } else if (alphaInfo == kCGImageAlphaNoneSkipLast) {
            return MINIAV_PIXEL_FORMAT_RGBA32;
        }
    }
    
    return MINIAV_PIXEL_FORMAT_BGRA32;
}

#if HAS_SCREEN_CAPTURE_KIT
// --- ScreenCaptureKit Delegate ---
@interface MiniAVScreenCaptureDelegate : NSObject <SCStreamDelegate, SCStreamOutput>
{
    CGScreenPlatformContext* _cgCtx;
}
- (instancetype)initWithCGContext:(CGScreenPlatformContext*)ctx;
@end

@implementation MiniAVScreenCaptureDelegate

- (instancetype)initWithCGContext:(CGScreenPlatformContext*)ctx {
    self = [super init];
    if (self) {
        _cgCtx = ctx;
    }
    return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!_cgCtx || !_cgCtx->is_streaming || !_cgCtx->app_callback_internal) {
        return;
    }
    
    if (type == SCStreamOutputTypeScreen) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get image buffer from sample buffer.");
            return;
        }
        
        [self processVideoFrame:imageBuffer withTimestamp:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
    } 
    // **ADD: Handle audio output**
    else if (type == SCStreamOutputTypeAudio) {
        [self processAudioBuffer:sampleBuffer];
    }
}

- (void)processAudioBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_cgCtx->parent_ctx->capture_audio_requested) {
        return; // Audio not requested
    }
    
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get audio format description");
        return;
    }
    
    const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (!asbd) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get audio stream description");
        return;
    }
    
    // Get audio data first to check validity
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get audio data buffer");
        return;
    }
    
    size_t totalLength = 0;
    char* dataPtr = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPtr);
    if (status != noErr || !dataPtr || totalLength == 0) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get audio data pointer (status: %d, length: %zu)", status, totalLength);
        return;
    }
    
    void* audioCopy = miniav_malloc(totalLength);
    if (!audioCopy) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to allocate audio data copy");
        return;
    }
    memcpy(audioCopy, dataPtr, totalLength);
    
    // Allocate audio buffer on heap
    MiniAVBuffer* buffer = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
    if (!buffer) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to allocate audio MiniAVBuffer");
        miniav_free(audioCopy);
        return;
    }
    
    MiniAVNativeBufferInternalPayload* payload = (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
    if (!payload) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to allocate audio payload");
        miniav_free(buffer);
        miniav_free(audioCopy);
        return;
    }
    
    payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_AUDIO;
    payload->context_owner = _cgCtx->parent_ctx;
    payload->parent_miniav_buffer_ptr = buffer;
    buffer->internal_handle = payload;
    
    payload->native_singular_resource_ptr = audioCopy;
    
    // Calculate frame count
    CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
    
    // Set up MiniAV audio buffer
    buffer->type = MINIAV_BUFFER_TYPE_AUDIO;
    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    buffer->timestamp_us = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000000;
    buffer->data_size_bytes = totalLength;
    
    // Map Core Audio format to MiniAV format
    MiniAVAudioFormat miniavFormat = MINIAV_AUDIO_FORMAT_UNKNOWN;
    if (asbd->mFormatID == kAudioFormatLinearPCM) {
        if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
            if (asbd->mBitsPerChannel == 32) {
                miniavFormat = MINIAV_AUDIO_FORMAT_F32;
            } else if (asbd->mBitsPerChannel == 64) {
                miniavFormat = MINIAV_AUDIO_FORMAT_F64;
            }
        } else {
            if (asbd->mBitsPerChannel == 16) {
                miniavFormat = MINIAV_AUDIO_FORMAT_S16;
            } else if (asbd->mBitsPerChannel == 32) {
                miniavFormat = MINIAV_AUDIO_FORMAT_S32;
            }
        }
    }
    
    buffer->data.audio.info.format = miniavFormat;
    buffer->data.audio.info.channels = asbd->mChannelsPerFrame;
    buffer->data.audio.info.sample_rate = (uint32_t)asbd->mSampleRate;
    buffer->data.audio.info.num_frames = (uint32_t)frameCount;
    
    // **FIX: Use the copied data**
    buffer->data.audio.data = audioCopy;
    buffer->user_data = _cgCtx->app_callback_user_data_internal;
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, 
              "SCK: Delivering audio buffer: %u frames, %u channels, %u Hz, format=%d, %zu bytes", 
              buffer->data.audio.info.num_frames, buffer->data.audio.info.channels, 
              buffer->data.audio.info.sample_rate, buffer->data.audio.info.format, buffer->data_size_bytes);
    
    _cgCtx->app_callback_internal(buffer, _cgCtx->app_callback_user_data_internal);
}

- (void)processVideoFrame:(CVImageBufferRef)imageBuffer withTimestamp:(CMTime)timestamp {
    MiniAVBuffer* buffer = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
    if (!buffer) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to allocate MiniAVBuffer");
        return;
    }
    
    MiniAVNativeBufferInternalPayload* payload = (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
    if (!payload) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to allocate payload");
        miniav_free(buffer);
        return;
    }
    
    payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
    payload->context_owner = _cgCtx->parent_ctx;
    payload->parent_miniav_buffer_ptr = buffer;
    buffer->internal_handle = payload;
    
    bool use_gpu_path = (_cgCtx->configured_video_format.output_preference == MINIAV_OUTPUT_PREFERENCE_GPU);
    bool gpu_path_successful = false;
    
    // Try GPU path with Metal texture
    if (use_gpu_path && _cgCtx->metalDevice && _cgCtx->textureCache) {
        IOSurfaceRef ioSurface = CVPixelBufferGetIOSurface(imageBuffer);
        if (ioSurface) {
            CVMetalTextureRef metalTextureRef = NULL;
            CVReturn err = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, _cgCtx->textureCache, imageBuffer, NULL,
                MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(imageBuffer), 
                CVPixelBufferGetHeight(imageBuffer), 0, &metalTextureRef);
                
            if (err == kCVReturnSuccess && metalTextureRef) {
                id<MTLTexture> texture = CVMetalTextureGetTexture(metalTextureRef);
                if (texture) {
                    CFRetain(metalTextureRef);
                    payload->native_singular_resource_ptr = metalTextureRef;
                    
                    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_GPU_METAL_TEXTURE;
                    buffer->data.video.info.width = [texture width];
                    buffer->data.video.info.height = [texture height];
                    buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_BGRA32;
                    
                    buffer->data.video.num_planes = 1;
                    buffer->data.video.planes[0].data_ptr = (void*)texture;
                    buffer->data.video.planes[0].width = [texture width];
                    buffer->data.video.planes[0].height = [texture height];
                    buffer->data.video.planes[0].stride_bytes = 0;
                    buffer->data.video.planes[0].offset_bytes = 0;
                    buffer->data.video.planes[0].subresource_index = 0;
                    buffer->data_size_bytes = [texture width] * [texture height] * 4;
                    
                    gpu_path_successful = true;
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: GPU Path - Metal texture created from IOSurface.");
                } else {
                    if (metalTextureRef) CFRelease(metalTextureRef);
                }
            }
        }
    }
    
    // Fallback to CPU path
    if (!gpu_path_successful) {
        CVBufferRetain(imageBuffer);
        payload->native_singular_resource_ptr = (void*)imageBuffer;
        
        if (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
            miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: CPU Path - Failed to lock pixel buffer.");
            CVBufferRelease(imageBuffer);
            miniav_free(buffer);
            miniav_free(payload);
            return;
        }
        
        buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
        buffer->data.video.info.width = (uint32_t)CVPixelBufferGetWidth(imageBuffer);
        buffer->data.video.info.height = (uint32_t)CVPixelBufferGetHeight(imageBuffer);
        buffer->data.video.info.pixel_format = MINIAV_PIXEL_FORMAT_BGRA32;
        
        buffer->data.video.num_planes = 1;
        buffer->data.video.planes[0].data_ptr = CVPixelBufferGetBaseAddress(imageBuffer);
        buffer->data.video.planes[0].width = (uint32_t)CVPixelBufferGetWidth(imageBuffer);
        buffer->data.video.planes[0].height = (uint32_t)CVPixelBufferGetHeight(imageBuffer);
        buffer->data.video.planes[0].stride_bytes = (uint32_t)CVPixelBufferGetBytesPerRow(imageBuffer);
        buffer->data.video.planes[0].offset_bytes = 0;
        buffer->data.video.planes[0].subresource_index = 0;
        buffer->data_size_bytes = CVPixelBufferGetDataSize(imageBuffer);
        
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    }
    
    // Set common video properties
    buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
    // Rebase the SCK sample PTS (session clock, own epoch) onto the shared
    // miniav_get_time_us() timeline with integer math so screen timestamps
    // are comparable with the other tracks.
    if (CMTIME_IS_NUMERIC(timestamp)) {
        CMTime tsUs = CMTimeConvertScale(timestamp, 1000000, kCMTimeRoundingMethod_Default);
        buffer->timestamp_us = miniav_rebase_time_us(&_cgCtx->ts_rebase, (uint64_t)tsUs.value);
    } else {
        buffer->timestamp_us = miniav_get_time_us();
    }
    buffer->data.video.info.frame_rate_numerator = _cgCtx->configured_video_format.frame_rate_numerator;
    buffer->data.video.info.frame_rate_denominator = _cgCtx->configured_video_format.frame_rate_denominator;
    buffer->data.video.info.output_preference = _cgCtx->configured_video_format.output_preference;
    buffer->user_data = _cgCtx->app_callback_user_data_internal;
    
    _cgCtx->app_callback_internal(buffer, _cgCtx->app_callback_user_data_internal);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Stream stopped with error: %s", [[error localizedDescription] UTF8String]);
        // Out-of-band stop (display disconnect, permission revoked,
        // sleep/wake): mark capture dead and tell the app — previously this
        // only logged, leaving is_streaming true and the app waiting for
        // frames that never come.
        if (_cgCtx && _cgCtx->is_streaming.exchange(false)) {
            if (!_cgCtx->lost_cb_fired.exchange(true)) {
                MiniAVScreenContext* parent = _cgCtx->parent_ctx;
                if (parent) {
                    parent->is_running = false;
                    if (parent->lost_cb) {
                        parent->lost_cb((int)MINIAV_ERROR_DEVICE_LOST, parent->lost_cb_user_data);
                    }
                }
            }
        }
    } else {
        miniav_log(MINIAV_LOG_LEVEL_INFO, "SCK: Stream stopped normally.");
    }
}

@end
#endif // HAS_SCREEN_CAPTURE_KIT

// --- Legacy Core Graphics Implementation ---
static void legacy_capture_timer_callback(void* info) {
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)info;
    if (!cgCtx || !cgCtx->is_streaming || !cgCtx->app_callback_internal) {
        return;
    }
    
    // Skip legacy capture entirely on macOS 15+ at compile time
    #if __MAC_OS_X_VERSION_MIN_REQUIRED >= 150000
        miniav_log(MINIAV_LOG_LEVEL_WARN, "CG: Legacy capture not available - compiled for macOS 15+");
        return;
    #else
        if (@available(macOS 15.0, *)) {
            miniav_log(MINIAV_LOG_LEVEL_WARN, "CG: Legacy capture not supported on macOS 15+");
            return;
        }
    
    CGImageRef screenImage = NULL;

    // The legacy CGDisplayCreateImage path always produces a cursor-LESS image;
    // there is no cursor-compositing here, so MiniAV_Screen_SetCaptureCursor
    // (ctx->capture_cursor) cannot be honored on this fallback. It only runs on
    // pre-macOS-15 systems where ScreenCaptureKit (which does honor showsCursor)
    // was unavailable; use the SCK path when you need the cursor.
    if (cgCtx->parent_ctx && cgCtx->parent_ctx->capture_cursor) {
        miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                   "CG: Legacy CGDisplayCreateImage cannot draw the cursor; "
                   "capturing cursor-less despite capture_cursor=true.");
    }

    screenImage = CGDisplayCreateImage(cgCtx->displayID);
    if (!screenImage) {
        miniav_log(MINIAV_LOG_LEVEL_ERROR, "CG: Failed to create screen image.");
        return;
    }
    
    // Convert CGImage to buffer
    size_t width = CGImageGetWidth(screenImage);
    size_t height = CGImageGetHeight(screenImage);
    size_t bytesPerRow = CGImageGetBytesPerRow(screenImage);
    
    MiniAVBuffer* buffer = (MiniAVBuffer*)miniav_calloc(1, sizeof(MiniAVBuffer));
    MiniAVNativeBufferInternalPayload* payload = (MiniAVNativeBufferInternalPayload*)miniav_calloc(1, sizeof(MiniAVNativeBufferInternalPayload));
    
    if (!payload || !buffer) {
        CGImageRelease(screenImage);
        miniav_free(payload);
        miniav_free(buffer);
        return;
    }
    
    payload->handle_type = MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN;
    payload->context_owner = cgCtx->parent_ctx;
    payload->parent_miniav_buffer_ptr = buffer;
    payload->native_singular_resource_ptr = (void*)screenImage;
    buffer->internal_handle = payload;
    
    // Legacy path is always CPU
    buffer->type = MINIAV_BUFFER_TYPE_VIDEO;
    buffer->content_type = MINIAV_BUFFER_CONTENT_TYPE_CPU;
    
    // Fix timing calculation
    uint64_t timestamp = mach_absolute_time();
    buffer->timestamp_us = (timestamp * cgCtx->timebase.numer) / (cgCtx->timebase.denom * 1000);
    
    buffer->data.video.info.width = (uint32_t)width;
    buffer->data.video.info.height = (uint32_t)height;
    buffer->data.video.info.pixel_format = CGBitmapInfoToMiniAVPixelFormat(CGImageGetBitmapInfo(screenImage));
    buffer->data.video.info.frame_rate_numerator = cgCtx->configured_video_format.frame_rate_numerator;
    buffer->data.video.info.frame_rate_denominator = cgCtx->configured_video_format.frame_rate_denominator;
    buffer->data.video.info.output_preference = MINIAV_OUTPUT_PREFERENCE_CPU;
    
    buffer->data.video.num_planes = 1;
    buffer->data.video.planes[0].data_ptr = (void*)CGDataProviderCopyData(CGImageGetDataProvider(screenImage));
    buffer->data.video.planes[0].width = (uint32_t)width;
    buffer->data.video.planes[0].height = (uint32_t)height;
    buffer->data.video.planes[0].stride_bytes = (uint32_t)bytesPerRow;
    buffer->data.video.planes[0].offset_bytes = 0;
    buffer->data.video.planes[0].subresource_index = 0;
    buffer->data_size_bytes = (uint32_t)(bytesPerRow * height);
    
    buffer->user_data = cgCtx->app_callback_user_data_internal;
    
    cgCtx->app_callback_internal(buffer, cgCtx->app_callback_user_data_internal);
    #endif
}

// --- Platform Ops Implementation (following WGC pattern) ---

static MiniAVResultCode cg_get_default_formats(const char* device_id_utf8,
                                               MiniAVVideoInfo* video_format_out,
                                               MiniAVAudioInfo* audio_format_out) {
    if (!device_id_utf8 || !video_format_out) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
    if (audio_format_out) {
        memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
    }
    
    // Parse device ID - use sscanf instead of sscanf_s
    if (strncmp(device_id_utf8, "display_", 8) == 0) {
        CGDirectDisplayID displayID;
        if (sscanf(device_id_utf8, "display_%u", &displayID) == 1) {
            CGRect bounds = CGDisplayBounds(displayID);
            video_format_out->width = (uint32_t)bounds.size.width;
            video_format_out->height = (uint32_t)bounds.size.height;
        } else {
            video_format_out->width = 1920;
            video_format_out->height = 1080;
        }
    } else {
        video_format_out->width = 1920;
        video_format_out->height = 1080;
    }
    
    video_format_out->pixel_format = MINIAV_PIXEL_FORMAT_BGRA32;
    video_format_out->frame_rate_numerator = 60;
    video_format_out->frame_rate_denominator = 1;
    video_format_out->output_preference = MINIAV_OUTPUT_PREFERENCE_GPU;
    
    // Audio format (if requested)
    if (audio_format_out) {
        audio_format_out->format = MINIAV_AUDIO_FORMAT_F32;
        audio_format_out->channels = 2;
        audio_format_out->sample_rate = 48000;
        audio_format_out->num_frames = 1024;
    }
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_get_configured_video_formats(MiniAVScreenContext* ctx,
                                                        MiniAVVideoInfo* video_format_out,
                                                        MiniAVAudioInfo* audio_format_out) {
    if (!ctx || !ctx->platform_ctx || !video_format_out) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    memset(video_format_out, 0, sizeof(MiniAVVideoInfo));
    if (audio_format_out) {
        memset(audio_format_out, 0, sizeof(MiniAVAudioInfo));
    }
    
    if (!ctx->is_configured) {
        return MINIAV_ERROR_NOT_INITIALIZED;
    }
    
    *video_format_out = ctx->configured_video_format;
    
    // Audio format would come from loopback system (not implemented here)
    if (audio_format_out && ctx->capture_audio_requested) {
        audio_format_out->format = MINIAV_AUDIO_FORMAT_F32;
        audio_format_out->channels = 2;
        audio_format_out->sample_rate = 48000;
        audio_format_out->num_frames = 1024;
    }
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_init_platform(MiniAVScreenContext* ctx) {
    if (!ctx) return MINIAV_ERROR_INVALID_ARG;
    
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)miniav_calloc(1, sizeof(CGScreenPlatformContext));
    if (!cgCtx) {
        return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    
    ctx->platform_ctx = cgCtx;
    cgCtx->parent_ctx = ctx;
    cgCtx->is_streaming = false;
    cgCtx->startChainSem = dispatch_semaphore_create(0);

    // Initialize timing
    if (mach_timebase_info(&cgCtx->timebase) != KERN_SUCCESS) {
        cgCtx->timebase.numer = 1;
        cgCtx->timebase.denom = 1;
    }

    @autoreleasepool {
        cgCtx->captureQueue = dispatch_queue_create("com.miniav.screen.captureQueue", DISPATCH_QUEUE_SERIAL);
        // Tag the queue so stop/destroy drains can detect same-queue
        // reentrancy (an app stopping from inside its own frame callback).
        dispatch_queue_set_specific(cgCtx->captureQueue, kMiniAVScreenQueueKey,
                                    (void*)1, NULL);
        
        // Initialize Metal for GPU path
        cgCtx->metalDevice = MTLCreateSystemDefaultDevice();
        if (cgCtx->metalDevice) {
            CVReturn err = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, cgCtx->metalDevice, NULL, &cgCtx->textureCache);
            if (err != kCVReturnSuccess) {
                miniav_log(MINIAV_LOG_LEVEL_WARN, "CG: Failed to create Metal texture cache. GPU path unavailable.");
                cgCtx->textureCache = NULL;
            }
        }
        
        cgCtx->displayID = CGMainDisplayID();
    }
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CG: Platform context initialized.");
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_destroy_platform(MiniAVScreenContext* ctx) {
    if (!ctx || !ctx->platform_ctx) return MINIAV_SUCCESS;
    
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)ctx->platform_ctx;

    // Abandon any in-flight async start chain and WAIT for its terminal
    // signal: the chain's blocks dereference cgCtx, so freeing it while a
    // chain is pending is a use-after-free. If the chain does not terminate
    // in time (e.g. an unanswered Screen Recording permission prompt keeping
    // SCShareableContent pending), deliberately LEAK the platform context —
    // a bounded leak beats freed memory an SCK block will still touch.
    cgCtx->startGeneration.fetch_add(1);
    if (cgCtx->startChainPending.load()) {
        if (dispatch_semaphore_wait(
                cgCtx->startChainSem,
                dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0) {
            cgCtx->startChainPending = false;
        } else {
            // MINIAV_ERROR_TIMEOUT tells MiniAV_Screen_DestroyContext to
            // also leak the parent context (uniform leak protocol).
            miniav_log(MINIAV_LOG_LEVEL_ERROR,
                       "SCK: async start chain still pending at destroy — "
                       "leaking the context to avoid a use-after-free (the "
                       "abandoned chain will stop any stream it started).");
            ctx->platform_ctx = NULL;
            return MINIAV_ERROR_TIMEOUT;
        }
    }

    @autoreleasepool {
        if (cgCtx->is_streaming) {
            // Stop any ongoing capture
            cgCtx->is_streaming = false;
        }

        // Clean up ScreenCaptureKit resources
#if HAS_SCREEN_CAPTURE_KIT
        if (@available(macOS 12.3, *)) {
            if (cgCtx->scStream) {
                // Bounded wait (same as cg_stop_capture) — the old
                // fire-and-forget stop let SCK teardown race the frees below.
                dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
                [cgCtx->scStream stopCaptureWithCompletionHandler:^(NSError* error) {
                    (void)error;
                    dispatch_semaphore_signal(stopSem);
                }];
                if (dispatch_semaphore_wait(
                        stopSem,
                        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
                    miniav_log(MINIAV_LOG_LEVEL_WARN,
                               "SCK: stopCapture completion timed out during destroy.");
                }
                dispatch_release(stopSem); // MRC: balance the create
                cgCtx->scStream = nil;
            }
            cgCtx->scDelegate = nil;
            cgCtx->scStreamConfig = nil;
        }
#endif
        
        // Clean up legacy timer
        if (cgCtx->captureTimer) {
            dispatch_source_cancel(cgCtx->captureTimer);
            cgCtx->captureTimer = NULL;
        }

        // Clean up Metal resources
        if (cgCtx->textureCache) {
            CVMetalTextureCacheFlush(cgCtx->textureCache, 0);
            CFRelease(cgCtx->textureCache);
            cgCtx->textureCache = NULL;
        }

        if (cgCtx->captureQueue) {
            // Drain in-flight sample/timer blocks before freeing the context
            // they dereference — releasing the queue while a block still runs
            // was a use-after-free on shutdown. (Same-queue reentrancy guard
            // as in stop_capture.)
            if (dispatch_get_specific(kMiniAVScreenQueueKey) == NULL) {
                dispatch_sync(cgCtx->captureQueue, ^{});
            }
            dispatch_release(cgCtx->captureQueue);
            cgCtx->captureQueue = nil;
        }
        if (cgCtx->startChainSem) {
            dispatch_release(cgCtx->startChainSem);
            cgCtx->startChainSem = NULL;
        }
    }

    miniav_free(cgCtx);
    ctx->platform_ctx = NULL;
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_enumerate_displays(MiniAVDeviceInfo** displays_out, uint32_t* count_out) {
    if (!displays_out || !count_out) return MINIAV_ERROR_INVALID_ARG;
    
    *displays_out = NULL;
    *count_out = 0;
    
    uint32_t displayCount;
    CGDirectDisplayID* displays = NULL;
    
    if (CGGetActiveDisplayList(0, NULL, &displayCount) != kCGErrorSuccess) {
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    
    if (displayCount == 0) {
        return MINIAV_SUCCESS;
    }
    
    displays = (CGDirectDisplayID*)miniav_calloc(displayCount, sizeof(CGDirectDisplayID));
    if (!displays) {
        return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    
    if (CGGetActiveDisplayList(displayCount, displays, &displayCount) != kCGErrorSuccess) {
        miniav_free(displays);
        return MINIAV_ERROR_SYSTEM_CALL_FAILED;
    }
    
    *displays_out = (MiniAVDeviceInfo*)miniav_calloc(displayCount, sizeof(MiniAVDeviceInfo));
    if (!*displays_out) {
        miniav_free(displays);
        return MINIAV_ERROR_OUT_OF_MEMORY;
    }
    
    for (uint32_t i = 0; i < displayCount; i++) {
        MiniAVDeviceInfo* info = &(*displays_out)[i];
        snprintf(info->device_id, MINIAV_DEVICE_ID_MAX_LEN, "display_%u", displays[i]);
        snprintf(info->name, MINIAV_DEVICE_NAME_MAX_LEN, "Display %u", displays[i]);
        info->is_default = (displays[i] == CGMainDisplayID());
    }
    
    *count_out = displayCount;
    miniav_free(displays);
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_enumerate_windows(MiniAVDeviceInfo** windows_out, uint32_t* count_out) {
    if (!windows_out || !count_out) return MINIAV_ERROR_INVALID_ARG;
    
    *windows_out = NULL;
    *count_out = 0;
    
    // For now, return empty list (window enumeration is complex on macOS)
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_configure_display(MiniAVScreenContext* ctx, const char* display_id, const MiniAVVideoInfo* format) {
    if (!ctx || !ctx->platform_ctx || !display_id || !format) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)ctx->platform_ctx;
    
    if (cgCtx->is_streaming) {
        return MINIAV_ERROR_ALREADY_RUNNING;
    }
    
    // Parse display ID - use sscanf instead of sscanf_s
    CGDirectDisplayID displayID;
    if (sscanf(display_id, "display_%u", &displayID) != 1) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    cgCtx->displayID = displayID;
    cgCtx->configured_video_format = *format;
    cgCtx->current_target_type = CG_TARGET_DISPLAY;
    miniav_strlcpy(cgCtx->selected_item_id, display_id, MINIAV_DEVICE_ID_MAX_LEN);
    
    // Update parent context
    ctx->configured_video_format = *format;
    ctx->is_configured = true;
    
    // Calculate FPS
    if (format->frame_rate_denominator > 0 && format->frame_rate_numerator > 0) {
        cgCtx->target_fps = format->frame_rate_numerator / format->frame_rate_denominator;
    } else {
        cgCtx->target_fps = 60;
    }
    
    CGRect bounds = CGDisplayBounds(displayID);
    cgCtx->frame_width = (uint32_t)bounds.size.width;
    cgCtx->frame_height = (uint32_t)bounds.size.height;
    
    // Update parent context with actual size
    ctx->configured_video_format.width = cgCtx->frame_width;
    ctx->configured_video_format.height = cgCtx->frame_height;
    
    miniav_log(MINIAV_LOG_LEVEL_INFO, "CG: Configured display %u (%ux%u)", displayID, cgCtx->frame_width, cgCtx->frame_height);
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_configure_window(MiniAVScreenContext* ctx, const char* window_id, const MiniAVVideoInfo* format) {
    MINIAV_UNUSED(ctx);
    MINIAV_UNUSED(window_id);
    MINIAV_UNUSED(format);
    return MINIAV_ERROR_NOT_SUPPORTED;
}

static MiniAVResultCode cg_configure_region(MiniAVScreenContext* ctx, const char* target_id, int x, int y, int width, int height, const MiniAVVideoInfo* format) {
    if (!ctx || !ctx->platform_ctx) return MINIAV_ERROR_INVALID_ARG;
    if (width <= 0 || height <= 0) return MINIAV_ERROR_INVALID_ARG;
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)ctx->platform_ctx;

    // Region = a sub-rectangle of a display. Resolve the target display the
    // same way cg_configure_display does — enumerated ids are "display_%u"
    // (parsing as bare %u would fail and silently fall back to the main
    // display, capturing the wrong monitor).
    CGDirectDisplayID displayID = CGMainDisplayID();
    if (target_id && target_id[0] != '\0') {
        unsigned int parsed = 0;
        if (sscanf(target_id, "display_%u", &parsed) == 1 && parsed != 0) {
            displayID = (CGDirectDisplayID)parsed;
        } else if (sscanf(target_id, "%u", &parsed) == 1 && parsed != 0) {
            displayID = (CGDirectDisplayID)parsed; // tolerate a bare id too
        }
    }
    cgCtx->displayID = displayID;
    cgCtx->current_target_type = CG_TARGET_DISPLAY;
    cgCtx->captureRegion = true;
    // SCStreamConfiguration.sourceRect is in POINTS with a top-left origin,
    // which matches the (x,y,width,height) the caller passes.
    cgCtx->regionRect = CGRectMake((CGFloat)x, (CGFloat)y,
                                   (CGFloat)width, (CGFloat)height);

    // Adopt the caller's format (frame rate, pixel format) the way
    // configure_display does, THEN override the size with the region — the
    // frame rate feeds minimumFrameInterval at start, and 0/0 would make an
    // invalid CMTime and report 0 fps on every delivered buffer.
    if (format) {
        cgCtx->configured_video_format = *format;
    }
    cgCtx->configured_video_format.width = (uint32_t)width;
    cgCtx->configured_video_format.height = (uint32_t)height;
    if (cgCtx->configured_video_format.frame_rate_numerator == 0 ||
        cgCtx->configured_video_format.frame_rate_denominator == 0) {
        cgCtx->configured_video_format.frame_rate_numerator = 60;
        cgCtx->configured_video_format.frame_rate_denominator = 1;
    }

    ctx->is_configured = true;
    ctx->configured_video_format = cgCtx->configured_video_format;

    miniav_log(MINIAV_LOG_LEVEL_INFO,
               "SCK: Region capture configured on display %u: %d,%d %dx%d @ %u/%u fps.",
               (unsigned)displayID, x, y, width, height,
               cgCtx->configured_video_format.frame_rate_numerator,
               cgCtx->configured_video_format.frame_rate_denominator);
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_start_capture(MiniAVScreenContext* ctx, MiniAVBufferCallback callback, void* user_data) {
    if (!ctx || !ctx->platform_ctx || !callback) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)ctx->platform_ctx;
    
    if (cgCtx->is_streaming) {
        return MINIAV_ERROR_ALREADY_RUNNING;
    }
    
    if (!ctx->is_configured) {
        return MINIAV_ERROR_NOT_INITIALIZED;
    }
    
    cgCtx->app_callback_internal = callback;
    cgCtx->app_callback_user_data_internal = user_data;
    
    @autoreleasepool {
#if HAS_SCREEN_CAPTURE_KIT
        if (@available(macOS 12.3, *)) {
            // The SCK setup chain is asynchronous, but StartCapture must
            // report a REAL result: previously this function returned
            // MINIAV_SUCCESS unconditionally, so permission/setup failures
            // were invisible (is_running true, zero frames forever). The
            // completion handlers run on SCK's own queues, so blocking the
            // calling thread here cannot deadlock them.
            //
            // Abandonment protocol: on timeout we bump startGeneration and
            // return an error — the still-running chain sees the stale
            // generation, undoes anything it started, and signals
            // startChainSem exactly once. stop/destroy (and any later start)
            // consume that signal; destroy refuses to free the context while
            // a chain is pending (the blocks dereference it).
            if (cgCtx->startChainPending.load()) {
                if (dispatch_semaphore_wait(
                        cgCtx->startChainSem,
                        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0) {
                    cgCtx->startChainPending = false;
                } else {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR,
                               "SCK: A previous start attempt is still pending — "
                               "refusing to start another.");
                    return MINIAV_ERROR_TIMEOUT;
                }
            }
            const uint32_t startGen = cgCtx->startGeneration.fetch_add(1) + 1;
            cgCtx->startChainPending = true;
            __block MiniAVResultCode startResult = MINIAV_ERROR_SYSTEM_CALL_FAILED;
            memset(&cgCtx->ts_rebase, 0, sizeof(cgCtx->ts_rebase));
            cgCtx->lost_cb_fired = false;
            [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError* error) {
                if (cgCtx->startGeneration.load() != startGen) {
                    // Abandoned (timeout/stop/destroy) — do not touch setup
                    // state; just deliver the terminal signal.
                    dispatch_semaphore_signal(cgCtx->startChainSem);
                    return;
                }
                if (error || !content) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to get shareable content%s%s",
                               error ? ": " : "",
                               error ? [[error localizedDescription] UTF8String] : "");
                    dispatch_semaphore_signal(cgCtx->startChainSem);
                    return;
                }
                
                SCDisplay* targetDisplay = nil;
                for (SCDisplay* display in content.displays) {
                    if (display.displayID == cgCtx->displayID) {
                        targetDisplay = display;
                        break;
                    }
                }
                
                if (!targetDisplay) {
                    targetDisplay = content.displays.firstObject;
                }
                
                if (!targetDisplay) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: No displays available for capture");
                    dispatch_semaphore_signal(cgCtx->startChainSem);
                    return;
                }
                
                SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
                
                cgCtx->scStreamConfig = [[SCStreamConfiguration alloc] init];
                if (cgCtx->captureRegion) {
                    // Crop to the configured sub-rectangle. sourceRect is in
                    // points (top-left origin); output buffers are the region
                    // size.
                    cgCtx->scStreamConfig.sourceRect = cgCtx->regionRect;
                    cgCtx->scStreamConfig.width = (size_t)cgCtx->regionRect.size.width;
                    cgCtx->scStreamConfig.height = (size_t)cgCtx->regionRect.size.height;
                } else {
                    cgCtx->scStreamConfig.width = targetDisplay.width;
                    cgCtx->scStreamConfig.height = targetDisplay.height;
                }
                cgCtx->scStreamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
                cgCtx->scStreamConfig.minimumFrameInterval = CMTimeMake(cgCtx->configured_video_format.frame_rate_denominator,
                                                                       cgCtx->configured_video_format.frame_rate_numerator);
                cgCtx->scStreamConfig.queueDepth = 3;
                // Draw the mouse cursor into captured frames when requested via
                // MiniAV_Screen_SetCaptureCursor (default false -> cursor-less,
                // unchanged behavior). showsCursor exists on
                // SCStreamConfiguration since macOS 12.3, i.e. it is always
                // valid inside this @available(macos 12.3) block.
                cgCtx->scStreamConfig.showsCursor = ctx->capture_cursor ? YES : NO;
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: showsCursor=%s",
                           ctx->capture_cursor ? "YES" : "NO");
                
                if (ctx->capture_audio_requested) {
                    cgCtx->scStreamConfig.capturesAudio = YES;
                    cgCtx->scStreamConfig.sampleRate = 48000; // Standard sample rate
                    cgCtx->scStreamConfig.channelCount = 2;   // Stereo
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Audio capture enabled - 48kHz stereo");
                } else {
                    cgCtx->scStreamConfig.capturesAudio = NO;
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Audio capture disabled");
                }
                
                cgCtx->scDelegate = [[MiniAVScreenCaptureDelegate alloc] initWithCGContext:cgCtx];
                cgCtx->scStream = [[SCStream alloc] initWithFilter:filter configuration:cgCtx->scStreamConfig delegate:cgCtx->scDelegate];
                
                // **ADD: Video output**
                NSError* addVideoOutputError = nil;
                BOOL videoSuccess = [cgCtx->scStream addStreamOutput:(id<SCStreamOutput>)cgCtx->scDelegate 
                                                                 type:SCStreamOutputTypeScreen 
                                                     sampleHandlerQueue:cgCtx->captureQueue 
                                                                  error:&addVideoOutputError];
                if (!videoSuccess) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to add video output: %s",
                              addVideoOutputError ? [[addVideoOutputError localizedDescription] UTF8String] : "Unknown error");
                    [filter release];
                    dispatch_semaphore_signal(cgCtx->startChainSem);
                    return;
                }
                
                if (ctx->capture_audio_requested) {
                    NSError* addAudioOutputError = nil;
                    BOOL audioSuccess = [cgCtx->scStream addStreamOutput:(id<SCStreamOutput>)cgCtx->scDelegate 
                                                                     type:SCStreamOutputTypeAudio 
                                                         sampleHandlerQueue:cgCtx->captureQueue 
                                                                      error:&addAudioOutputError];
                    if (!audioSuccess) {
                        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to add audio output: %s", 
                                  addAudioOutputError ? [[addAudioOutputError localizedDescription] UTF8String] : "Unknown error");
                        // Continue with video-only capture
                    } else {
                        miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Audio output added successfully");
                    }
                }
                
                [cgCtx->scStream startCaptureWithCompletionHandler:^(NSError* error) {
                    if (cgCtx->startGeneration.load() != startGen) {
                        // Abandoned while starting: don't leave a headless
                        // stream running (nobody will ever stop it) and
                        // don't publish is_streaming/startResult.
                        if (!error && cgCtx->scStream) {
                            [cgCtx->scStream stopCaptureWithCompletionHandler:nil];
                        }
                        dispatch_semaphore_signal(cgCtx->startChainSem);
                        return;
                    }
                    if (error) {
                        miniav_log(MINIAV_LOG_LEVEL_ERROR, "SCK: Failed to start stream: %s",
                                  [[error localizedDescription] UTF8String]);
                    } else {
                        cgCtx->is_streaming = true;
                        startResult = MINIAV_SUCCESS;
                        miniav_log(MINIAV_LOG_LEVEL_INFO, "SCK: Screen capture started (video:%s, audio:%s)",
                                  "YES", ctx->capture_audio_requested ? "YES" : "NO");
                    }
                    dispatch_semaphore_signal(cgCtx->startChainSem);
                }];

                [filter release];
            }];
            // Bounded wait for the async chain to reach a definitive state.
            if (dispatch_semaphore_wait(
                    cgCtx->startChainSem,
                    dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
                miniav_log(MINIAV_LOG_LEVEL_ERROR,
                           "SCK: StartCapture timed out waiting for setup — "
                           "abandoning the attempt (the chain will clean up "
                           "after itself).");
                // Abandon: the chain sees the stale generation, undoes any
                // started stream, and signals; startChainPending stays true
                // until stop/destroy/a later start consumes that signal.
                cgCtx->startGeneration.fetch_add(1);
                return MINIAV_ERROR_TIMEOUT;
            }
            cgCtx->startChainPending = false;
            if (startResult != MINIAV_SUCCESS) {
                return startResult;
            }
        } else {
#endif
            // Fallback to legacy Core Graphics capture
            #if __MAC_OS_X_VERSION_MIN_REQUIRED >= 150000
                miniav_log(MINIAV_LOG_LEVEL_ERROR, "CG: Legacy capture not available - compiled for macOS 15+");
                return MINIAV_ERROR_NOT_SUPPORTED;
            #else
                // Check at runtime too
                if (@available(macOS 15.0, *)) {
                    miniav_log(MINIAV_LOG_LEVEL_ERROR, "CG: Legacy capture not supported on macOS 15+");
                    return MINIAV_ERROR_NOT_SUPPORTED;
                }
                
                double fps = (double)cgCtx->configured_video_format.frame_rate_numerator / cgCtx->configured_video_format.frame_rate_denominator;
                uint64_t interval_ns = (uint64_t)(1000000000.0 / fps);
                
                cgCtx->captureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cgCtx->captureQueue);
                dispatch_source_set_timer(cgCtx->captureTimer, DISPATCH_TIME_NOW, interval_ns, interval_ns / 10);
                dispatch_source_set_event_handler_f(cgCtx->captureTimer, legacy_capture_timer_callback);
                dispatch_set_context(cgCtx->captureTimer, cgCtx);
                dispatch_resume(cgCtx->captureTimer);
                
                cgCtx->is_streaming = true;
                miniav_log(MINIAV_LOG_LEVEL_INFO, "CG: Legacy screen capture started");
            #endif
#if HAS_SCREEN_CAPTURE_KIT
        }
#endif
    }
    
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_stop_capture(MiniAVScreenContext* ctx) {
    if (!ctx || !ctx->platform_ctx) {
        return MINIAV_ERROR_INVALID_ARG;
    }
    
    CGScreenPlatformContext* cgCtx = (CGScreenPlatformContext*)ctx->platform_ctx;

    // Abandon any in-flight async start chain (from a timed-out start) and
    // consume its terminal signal, BEFORE the is_streaming early-out — a
    // pending chain can exist while is_streaming is still false.
    cgCtx->startGeneration.fetch_add(1);
    if (cgCtx->startChainPending.load()) {
        if (dispatch_semaphore_wait(
                cgCtx->startChainSem,
                dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0) {
            cgCtx->startChainPending = false;
        }
    }

    if (!cgCtx->is_streaming) {
        return MINIAV_SUCCESS;
    }

    cgCtx->is_streaming = false;

    @autoreleasepool {
#if HAS_SCREEN_CAPTURE_KIT
        if (@available(macOS 12.3, *)) {
            if (cgCtx->scStream) {
                // Bounded wait for the stream to actually stop (the old
                // fire-and-forget nil handler let teardown race in-flight
                // sample callbacks).
                dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
                [cgCtx->scStream stopCaptureWithCompletionHandler:^(NSError* error) {
                    if (error) {
                        miniav_log(MINIAV_LOG_LEVEL_WARN, "SCK: stopCapture error: %s",
                                  [[error localizedDescription] UTF8String]);
                    }
                    dispatch_semaphore_signal(stopSem);
                }];
                if (dispatch_semaphore_wait(
                        stopSem,
                        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
                    miniav_log(MINIAV_LOG_LEVEL_WARN,
                               "SCK: stopCapture completion timed out.");
                }
                dispatch_release(stopSem); // MRC: balance the create
                cgCtx->scStream = nil;
            }
            cgCtx->scDelegate = nil;
            cgCtx->scStreamConfig = nil;
        } else {
#endif
            if (cgCtx->captureTimer) {
                dispatch_source_cancel(cgCtx->captureTimer);
                cgCtx->captureTimer = NULL;
            }
#if HAS_SCREEN_CAPTURE_KIT
        }
#endif
        // Drain any in-flight sample-handler block before returning — the
        // caller may clear callbacks or free the context right after. Skip
        // when already ON captureQueue (stop called from a frame callback):
        // dispatch_sync onto the current serial queue would self-deadlock.
        if (cgCtx->captureQueue &&
            dispatch_get_specific(kMiniAVScreenQueueKey) == NULL) {
            dispatch_sync(cgCtx->captureQueue, ^{});
        }
    }

    miniav_log(MINIAV_LOG_LEVEL_INFO, "CG: Screen capture stopped");
    return MINIAV_SUCCESS;
}

static MiniAVResultCode cg_release_buffer(MiniAVScreenContext* ctx, void* internal_handle_ptr) {
    MINIAV_UNUSED(ctx);
    
    if (!internal_handle_ptr) {
        return MINIAV_SUCCESS;
    }
    
    MiniAVNativeBufferInternalPayload* payload = (MiniAVNativeBufferInternalPayload*)internal_handle_ptr;
    
    @autoreleasepool {
        if (payload->native_singular_resource_ptr) {
            if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_VIDEO_SCREEN) {
                CFTypeID typeID = CFGetTypeID(payload->native_singular_resource_ptr);
                
                if (typeID == CGImageGetTypeID()) {
                    // Legacy CGImageRef
                    CGImageRef image = (CGImageRef)payload->native_singular_resource_ptr;
                    if (payload->parent_miniav_buffer_ptr && payload->parent_miniav_buffer_ptr->data.video.planes[0].data_ptr) {
                        CFDataRef data = (CFDataRef)payload->parent_miniav_buffer_ptr->data.video.planes[0].data_ptr;
                        CFRelease(data);
                    }
                    CGImageRelease(image);
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Released CGImageRef");
                } else if (typeID == CVPixelBufferGetTypeID()) {
                    // CVPixelBufferRef
                    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)payload->native_singular_resource_ptr;
                    CVBufferRelease(pixelBuffer);
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Released CVPixelBufferRef");
                } else {
                    // Metal texture
                    CVMetalTextureRef metalTextureRef = (CVMetalTextureRef)payload->native_singular_resource_ptr;
                    CFRelease(metalTextureRef);
                    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Released CVMetalTextureRef");
                }
            } 
            else if (payload->handle_type == MINIAV_NATIVE_HANDLE_TYPE_AUDIO) {
                void* audioData = payload->native_singular_resource_ptr;
                miniav_free(audioData);
                miniav_log(MINIAV_LOG_LEVEL_DEBUG, "SCK: Released copied audio data");
            }
            payload->native_singular_resource_ptr = NULL;
        }
    }
    
    if (payload->parent_miniav_buffer_ptr) {
        miniav_free(payload->parent_miniav_buffer_ptr);
        payload->parent_miniav_buffer_ptr = NULL;
    }
    
    miniav_free(payload);
    return MINIAV_SUCCESS;
}

// --- Global Ops Table ---
const ScreenContextInternalOps g_screen_ops_macos_cg = {
    .init_platform = cg_init_platform,
    .destroy_platform = cg_destroy_platform,
    .enumerate_displays = cg_enumerate_displays,
    .enumerate_windows = cg_enumerate_windows,
    .configure_display = cg_configure_display,
    .configure_window = cg_configure_window,
    .configure_region = cg_configure_region,
    .start_capture = cg_start_capture,
    .stop_capture = cg_stop_capture,
    .release_buffer = cg_release_buffer,
    .get_default_formats = cg_get_default_formats,
    .get_configured_video_formats = cg_get_configured_video_formats,
};

// --- Platform Init for Selection ---
MiniAVResultCode miniav_screen_context_platform_init_macos_cg(MiniAVScreenContext* ctx) {
    if (!ctx) return MINIAV_ERROR_INVALID_ARG;
    
    ctx->ops = &g_screen_ops_macos_cg;
    
    miniav_log(MINIAV_LOG_LEVEL_DEBUG, "CG: Screen capture platform selected.");
    return MINIAV_SUCCESS;
}