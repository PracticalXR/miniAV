// iOS AVAudioSession shim for the shared miniaudio mic-input module.
//
// miniaudio's CoreAudio backend works on iOS, but capture silently records
// silence (or fails) unless the app's audio session has a record-capable
// category active. audio_context.c calls these seams around device
// start/stop; on every other platform they compile to no-ops.
//
// Category: PlayAndRecord + MixWithOthers + DefaultToSpeaker — capture
// without silencing other audio, and route playback sensibly. Deactivation
// notifies other apps so their audio resumes.
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>

#include "../../common/miniav_logging.h"

#if !TARGET_OS_IPHONE
#error "miniav_avaudiosession_ios.m must only be compiled for iOS targets"
#endif

int miniav_ios_audio_session_begin(void) {
  @autoreleasepool {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    BOOL ok = [session
        setCategory:AVAudioSessionCategoryPlayAndRecord
        withOptions:(AVAudioSessionCategoryOptionMixWithOthers |
                     AVAudioSessionCategoryOptionDefaultToSpeaker)
              error:&error];
    if (!ok) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "AVAudioSession: setCategory failed: %s",
                 error ? error.localizedDescription.UTF8String : "?");
      return -1;
    }
    ok = [session setActive:YES error:&error];
    if (!ok) {
      miniav_log(MINIAV_LOG_LEVEL_ERROR,
                 "AVAudioSession: setActive(YES) failed: %s",
                 error ? error.localizedDescription.UTF8String : "?");
      return -1;
    }
    miniav_log(MINIAV_LOG_LEVEL_DEBUG,
               "AVAudioSession: PlayAndRecord active (mix, speaker).");
    return 0;
  }
}

void miniav_ios_audio_session_end(void) {
  @autoreleasepool {
    NSError *error = nil;
    // Best-effort; other miniAV contexts or the app itself may still be
    // using the session — deactivation failure is logged, not fatal.
    if (![[AVAudioSession sharedInstance]
            setActive:NO
          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                error:&error]) {
      miniav_log(MINIAV_LOG_LEVEL_DEBUG,
                 "AVAudioSession: setActive(NO) failed (non-fatal): %s",
                 error ? error.localizedDescription.UTF8String : "?");
    }
  }
}
