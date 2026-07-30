package com.practicalxr.miniav_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Minimal `foregroundServiceType="mediaProjection"` foreground service.
 *
 * Android 14 (API 34) requires this typed FGS to be *running* before
 * [android.media.projection.MediaProjectionManager.getMediaProjection] is
 * called. The plugin starts this service, waits for [onStartCommand] to fire
 * (which promotes it to the foreground), and only then obtains the projection.
 *
 * The service owns no capture logic itself — the actual VirtualDisplay /
 * AImageReader pipeline lives in the pure-native `miniav_c` screen backend. This
 * service exists solely to satisfy the platform's foreground-service contract
 * and to keep the projection session alive while capturing.
 */
class MiniavScreenCaptureService : Service() {

    companion object {
        private const val CHANNEL_ID = "miniav_screen_capture"
        private const val CHANNEL_NAME = "Screen capture"
        private const val NOTIFICATION_ID = 0x4D41 // 'MA'

        const val ACTION_START = "com.practicalxr.miniav_flutter.action.START"
        const val ACTION_STOP = "com.practicalxr.miniav_flutter.action.STOP"

        /**
         * Fires once [onStartCommand] has run for a START intent. `success` is
         * true when the service was promoted to the foreground and it is now safe
         * to call `getMediaProjection`; false (with a `reason`) when
         * [startForeground] threw, so the plugin can fail the pending consent flow
         * instead of hanging forever. Set by the service, consumed exactly once
         * and cleared by the plugin. Guarded by [lock].
         */
        @Volatile
        private var onStartedCallback: ((success: Boolean, reason: String?) -> Unit)? = null

        private val lock = Any()

        /**
         * Registers a one-shot callback invoked when the service reaches the
         * foreground (or fails to). If the service already started before this
         * call, the callback is invoked immediately.
         */
        fun setOnStartedCallback(callback: ((success: Boolean, reason: String?) -> Unit)?) {
            synchronized(lock) {
                onStartedCallback = callback
            }
        }

        private fun notifyStarted() {
            consumeCallback()?.invoke(true, null)
        }

        private fun notifyStartFailed(reason: String?) {
            consumeCallback()?.invoke(false, reason)
        }

        /**
         * Atomically takes and clears the callback so success and failure paths
         * can never both fire (one-shot, single-consumer semantics).
         */
        private fun consumeCallback(): ((success: Boolean, reason: String?) -> Unit)? {
            synchronized(lock) {
                val cb = onStartedCallback
                onStartedCallback = null
                return cb
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                try {
                    startInForeground()
                } catch (t: Throwable) {
                    // startForeground() can throw: a zero/invalid small icon,
                    // Android 14's ForegroundServiceStartNotAllowedException, or a
                    // MediaProjection SecurityException. Fail the pending consent
                    // flow instead of leaving the Dart await hanging forever.
                    notifyStartFailed(t.message ?: t.javaClass.simpleName)
                    stopSelf()
                    return START_NOT_STICKY
                }
                // The FGS is now running in the foreground; unblock the plugin's
                // getMediaProjection() step.
                notifyStarted()
            }
        }
        // Do not auto-restart: the projection cannot survive a process death and
        // must be re-consented anyway.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // Ensure a stale callback never leaks across service instances.
        setOnStartedCallback(null)
        super.onDestroy()
    }

    private fun startInForeground() {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                )
                channel.description = "Active while miniAV is capturing the screen."
                channel.setShowBadge(false)
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        // applicationInfo.icon is 0 when the app declares no launcher icon;
        // setSmallIcon(0) makes startForeground() throw. Fall back to a
        // guaranteed-present framework drawable so the common icon-missing vector
        // cannot fail the FGS start.
        val smallIcon = if (applicationInfo.icon != 0) {
            applicationInfo.icon
        } else {
            android.R.drawable.presence_video_online
        }
        return builder
            .setContentTitle("Screen capture active")
            .setContentText("miniAV is capturing your screen.")
            .setSmallIcon(smallIcon)
            .setOngoing(true)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
