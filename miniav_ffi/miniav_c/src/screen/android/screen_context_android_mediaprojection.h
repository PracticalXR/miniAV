#ifndef SCREEN_CONTEXT_ANDROID_MEDIAPROJECTION_H
#define SCREEN_CONTEXT_ANDROID_MEDIAPROJECTION_H

// Android screen capture via android.media.projection.MediaProjection +
// AImageReader (NDK). Frames are delivered with the SAME payload/release
// contract as the desktop backends; the ONLY Java-touching part is obtaining
// the MediaProjection object and calling MediaProjection.createVirtualDisplay
// through JNI.
//
// ---------------------------------------------------------------------------
// HOW A PROJECTION REACHES miniAV (the consent flow — spec §3 / §A.3)
// ---------------------------------------------------------------------------
// miniAV NEVER prompts. Android's MediaProjection consent is an Activity
// round-trip that only Java/Kotlin can drive:
//   1. The app (the miniav_flutter plugin's Android piece for Flutter apps, or
//      the host app directly) calls
//      MediaProjectionManager.createScreenCaptureIntent(), startActivityForResult,
//      and in onActivityResult builds a MediaProjection via
//      MediaProjectionManager.getMediaProjection(resultCode, data).
//   2. The app hands that MediaProjection (as a JNI GLOBAL ref) and the process
//      JavaVM* to miniAV through
//      MiniAV_Screen_SetAndroidMediaProjection(jvm, media_projection) BEFORE
//      calling MiniAV_Screen_ConfigureDisplay. Ownership of the global ref
//      TRANSFERS to miniAV (miniAV DeleteGlobalRef's it on clear/destroy).
//   3. Configuring a display with no projection set returns
//      MINIAV_ERROR_PERMISSION_DENIED.
//
// ---------------------------------------------------------------------------
// FOREGROUND SERVICE REQUIREMENT (app responsibility — NOT handled here)
// ---------------------------------------------------------------------------
// From Android 10 (API 29) a MediaProjection session requires a running
// foreground service, and from Android 14 (API 34) that service MUST declare
// android:foregroundServiceType="mediaProjection". Without it the platform
// throws when createVirtualDisplay runs (or tears the projection down almost
// immediately). This native library CANNOT start a typed foreground service;
// the miniav_flutter plugin (or the host app) MUST start one before handing
// the projection to miniAV and keep it running for the capture's lifetime.
//
// ---------------------------------------------------------------------------
// STOP DETECTION (spec §A.3)
// ---------------------------------------------------------------------------
// Authoritative "projection stopped" notification (user tapped the cast
// status-bar chip, system revoked it, MediaProjection.stop() from Java, ...)
// arrives on the Java MediaProjection.Callback — which the miniav_flutter
// plugin observes and turns into a StopCapture call. Native code cannot
// register that callback (it needs a dex-loaded Callback subclass). This
// backend fires lost_cb ONE-SHOT on whatever native-visible failure it can
// see instead: createVirtualDisplay returning null, or a JNI exception on a
// projection call. It ALSO fires lost_cb when the app relays the Java-side
// onStop by clearing the projection (see the clear contract below): clearing
// is keyed on the projection being NULL — the jvm argument may be non-NULL and
// is ignored on clear.
//
// ---------------------------------------------------------------------------
// API-LEVEL GATING
// ---------------------------------------------------------------------------
// ANativeWindow_toSurface (wrapping the AImageReader window into a Java
// Surface for createVirtualDisplay) and AImage_getHardwareBuffer are API 26+.
// Below 26 the backend reports MINIAV_ERROR_NOT_SUPPORTED at configure time.

#if defined(__ANDROID__)

#include "../../../include/miniav_buffer.h"
#include "../../../include/miniav_types.h"
#include "../screen_context.h"

#ifdef __cplusplus
extern "C" {
#endif

// Global ops table for the Android MediaProjection screen backend. Referenced
// by screen_api.c's backend table.
extern const ScreenContextInternalOps g_screen_ops_android_mediaprojection;

// platform_init_for_selection: assigns the ops table to the context. The
// generic screen_api.c layer then calls ops->init_platform().
MiniAVResultCode miniav_screen_context_platform_init_android_mediaprojection(
    MiniAVScreenContext *ctx);

// Free function dispatched to by MiniAV_Screen_SetAndroidMediaProjection.
//   jvm               : JavaVM* for the process.
//   media_projection  : a JNI GLOBAL ref to an
//                       android.media.projection.MediaProjection. OWNERSHIP
//                       TRANSFERS to miniAV (DeleteGlobalRef'd on
//                       clear/replace/destroy).
// Clearing is keyed on media_projection being NULL: passing a NULL
// media_projection clears any stored projection (releasing the global ref) and,
// if a capture is active, fires its lost_cb. The jvm argument may be non-NULL
// on a clear (callers relaying the Java onStop often still have a cached JVM)
// and is ignored for the purpose of clear detection. Must be called before
// ConfigureDisplay.
MiniAVResultCode
miniav_screen_android_set_media_projection(void *jvm, void *media_projection);

#ifdef __cplusplus
}
#endif

#endif // __ANDROID__
#endif // SCREEN_CONTEXT_ANDROID_MEDIAPROJECTION_H
