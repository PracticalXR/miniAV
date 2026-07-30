package com.practicalxr.miniav_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener

/**
 * miniav_flutter Android plugin: MediaProjection consent helper.
 *
 * Implements the one thing that genuinely cannot be done from native code — the
 * Android screen-capture consent Activity round-trip — and hands the resulting
 * [MediaProjection] to the pure-FFI native layer (miniav_c) via a small JNI
 * shim (see src/main/cpp/miniav_flutter_jni.c). See
 * miniav_ffi/miniav_c/MOBILE_PLATFORM_SPEC.md §3 (A.3) / §6.
 *
 * MethodChannel: `miniav_flutter`
 *   - `requestMediaProjection()` -> `{"granted": Boolean}`
 *   - `stopMediaProjection()`    -> `null`
 * Emitted call (native -> Dart): `onProjectionStop` (no args).
 */
class MiniavFlutterPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler,
    ActivityResultListener {

    companion object {
        private const val CHANNEL_NAME = "miniav_flutter"
        private const val REQUEST_CODE_MEDIA_PROJECTION = 0x4D50 // 'MP'

        init {
            // The JNI shim library that bridges to libminiav_c.so.
            System.loadLibrary("miniav_flutter_jni")
        }

        /**
         * Hands the [MediaProjection] (or `null` to clear) to the native
         * miniav_c layer. Implemented in miniav_flutter_jni.c: it wraps the
         * projection in a JNI global ref, grabs the process JavaVM*, and calls
         * `MiniAV_Screen_SetAndroidMediaProjection`.
         */
        @JvmStatic
        external fun nativeSetMediaProjection(projection: MediaProjection?)
    }

    private lateinit var channel: MethodChannel
    private lateinit var applicationContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null

    /** Non-null only between requestMediaProjection() and its result. */
    private var pendingResult: Result? = null

    /** The live projection, if consent has been granted and not yet stopped. */
    private var mediaProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null

    // --- FlutterPlugin ---

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Best-effort teardown so a live projection can't outlive the engine.
        teardownProjection()
        channel.setMethodCallHandler(null)
    }

    // --- ActivityAware ---

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        bindActivity(binding)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        bindActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unbindActivity()
    }

    override fun onDetachedFromActivity() {
        unbindActivity()
    }

    private fun bindActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    private fun unbindActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        // If a request was in flight when the activity detached, fail it rather
        // than leak the pending Result.
        pendingResult?.let {
            it.success(mapOf("granted" to false))
        }
        pendingResult = null
    }

    // --- MethodCallHandler ---

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "requestMediaProjection" -> requestMediaProjection(result)
            "stopMediaProjection" -> {
                teardownProjection()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestMediaProjection(result: Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error(
                "no_activity",
                "requestMediaProjection requires a foreground Activity.",
                null,
            )
            return
        }
        if (pendingResult != null) {
            result.error(
                "in_progress",
                "A MediaProjection consent request is already in progress.",
                null,
            )
            return
        }
        // Already have a live projection: report success without re-prompting.
        if (mediaProjection != null) {
            result.success(mapOf("granted" to true))
            return
        }

        pendingResult = result
        val manager = currentActivity
            .getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val intent = manager.createScreenCaptureIntent()
        try {
            currentActivity.startActivityForResult(intent, REQUEST_CODE_MEDIA_PROJECTION)
        } catch (e: Exception) {
            pendingResult = null
            result.error(
                "start_intent_failed",
                "Failed to launch the screen-capture consent Intent: ${e.message}",
                null,
            )
        }
    }

    // --- ActivityResultListener ---

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_MEDIA_PROJECTION) {
            return false
        }
        val result = pendingResult
        pendingResult = null
        if (result == null) {
            // No pending request: still consumed our request code.
            return true
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            // User cancelled (RESULT_CANCELED) or malformed result.
            result.success(mapOf("granted" to false))
            return true
        }

        // Android 14 (API 34) requires the mediaProjection-typed FGS to be
        // RUNNING before getMediaProjection(). Start it, then obtain the
        // projection once onStartCommand has promoted it to the foreground.
        startForegroundServiceThenGetProjection(resultCode, data, result)
        return true
    }

    private fun startForegroundServiceThenGetProjection(
        resultCode: Int,
        data: Intent,
        result: Result,
    ) {
        val serviceIntent = Intent(applicationContext, MiniavScreenCaptureService::class.java)
            .setAction(MiniavScreenCaptureService.ACTION_START)

        // Register the "FGS reached foreground" one-shot BEFORE starting it so we
        // never miss the signal. The callback arrives on the service's thread
        // (main thread for a local service); re-post to main to be safe. It fires
        // exactly once with success=true (foreground reached) or success=false
        // (startForeground threw) — the latter must fail the pending flow rather
        // than leave the Dart await hanging.
        MiniavScreenCaptureService.setOnStartedCallback { success, reason ->
            mainHandler.post {
                if (success) {
                    onForegroundServiceStarted(resultCode, data, result)
                } else {
                    onForegroundServiceStartFailed(reason, result)
                }
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(serviceIntent)
            } else {
                applicationContext.startService(serviceIntent)
            }
        } catch (e: Exception) {
            MiniavScreenCaptureService.setOnStartedCallback(null)
            result.error(
                "fgs_start_failed",
                "Failed to start the mediaProjection foreground service: ${e.message}",
                null,
            )
        }
    }

    private fun onForegroundServiceStarted(
        resultCode: Int,
        data: Intent,
        result: Result,
    ) {
        val currentActivity = activity
        val contextForManager: Context = currentActivity ?: applicationContext
        val manager = contextForManager
            .getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        val projection: MediaProjection? = try {
            manager.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            null
        }

        if (projection == null) {
            stopForegroundService()
            result.success(mapOf("granted" to false))
            return
        }

        mediaProjection = projection

        // Register the authoritative stop signal Java-side: native cannot hook
        // MediaProjection.Callback. onStop fires on user-revoke / system stop.
        val callback = object : MediaProjection.Callback() {
            override fun onStop() {
                onProjectionStopped()
            }
        }
        projectionCallback = callback
        // A handler is required on API 34+; harmless on older APIs.
        projection.registerCallback(callback, mainHandler)

        // Hand the projection to native (JNI shim -> MiniAV_Screen_SetAndroidMediaProjection).
        try {
            nativeSetMediaProjection(projection)
        } catch (e: Throwable) {
            // Native handoff failed: don't report success we can't back up.
            teardownProjection()
            result.error(
                "native_handoff_failed",
                "Failed to hand the MediaProjection to native: ${e.message}",
                null,
            )
            return
        }

        result.success(mapOf("granted" to true))
    }

    /**
     * Invoked when the foreground service failed to reach the foreground (i.e.
     * startForeground() threw inside the service). We never obtained a
     * projection, so tear down any projection state (idempotent), stop the FGS,
     * and fail the pending consent flow so the Dart await cannot hang forever.
     */
    private fun onForegroundServiceStartFailed(reason: String?, result: Result) {
        teardownProjection()
        result.error(
            "fgs_start_failed",
            "The mediaProjection foreground service failed to start: ${reason ?: "unknown"}",
            null,
        )
    }

    /**
     * Invoked from [MediaProjection.Callback.onStop] (user revoked / system
     * stop). Clears native state, stops the FGS, and notifies Dart. This is the
     * authoritative stop signal.
     */
    private fun onProjectionStopped() {
        // Clear native pointers first so no further native use touches a dead
        // projection.
        safeClearNative()
        mediaProjection?.let { proj ->
            projectionCallback?.let { proj.unregisterCallback(it) }
        }
        projectionCallback = null
        mediaProjection = null
        stopForegroundService()
        mainHandler.post {
            // channel may already be torn down during engine detach.
            runCatching { channel.invokeMethod("onProjectionStop", null) }
        }
    }

    /**
     * Explicit stop (stopMediaProjection / engine detach): stop the projection
     * (which will also fire onStop, but we defensively clear here too), clear
     * native state, and stop the FGS.
     */
    private fun teardownProjection() {
        MiniavScreenCaptureService.setOnStartedCallback(null)
        val proj = mediaProjection
        if (proj != null) {
            projectionCallback?.let { proj.unregisterCallback(it) }
            projectionCallback = null
            mediaProjection = null
            safeClearNative()
            runCatching { proj.stop() }
        } else {
            // Clear native even if we hold no projection (idempotent NULLs).
            safeClearNative()
        }
        stopForegroundService()
    }

    private fun safeClearNative() {
        // Passing null clears native state (JNI shim forwards NULLs).
        runCatching { nativeSetMediaProjection(null) }
    }

    private fun stopForegroundService() {
        val serviceIntent = Intent(applicationContext, MiniavScreenCaptureService::class.java)
            .setAction(MiniavScreenCaptureService.ACTION_STOP)
        runCatching { applicationContext.startService(serviceIntent) }
    }
}
