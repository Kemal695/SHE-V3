package et.she.v3.she_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File

/**
 * Robi wake word — foreground service (Phase 4).
 *
 * See docs/robi-phase4-wake-word.md. This is STAGE 1: the service, the
 * notification and the permission/lifecycle plumbing. It does NOT listen yet —
 * the on-device speech model is not bundled, so it reports `model_missing` and
 * stays idle rather than claiming to listen. Stage 2 adds the Vosk recognizer.
 *
 * Why a service at all: Android will not keep a microphone open for a background
 * app. A foreground service with `foregroundServiceType="microphone"` is the only
 * supported way, and it is also what makes the microphone privacy indicator and
 * our notification unavoidable — which is the point.
 */
class RobiWakeService : Service() {

    companion object {
        private const val TAG = "RobiWake"
        private const val CHANNEL_ID = "robi_wake"
        private const val NOTIFICATION_ID = 4201

        /** Set by MainActivity; receives ("ready" | "model_missing" | "error"). */
        @Volatile
        var sink: ((String, String?) -> Unit)? = null

        @Volatile
        var running: Boolean = false
            private set

        /** Where the Vosk model must live (Stage 2 unpacks it here). */
        fun modelDir(context: android.content.Context): File =
            File(context.filesDir, "vosk/model")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!hasMicrophonePermission()) {
            // A microphone-type foreground service cannot start without this on
            // API 34+; bail before startForeground rather than throwing.
            emit("error", "microphone_permission")
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startInForeground()
            running = true

            // Stage 1: no model → no listening. Say so instead of pretending.
            val dir = modelDir(this)
            if (dir.isDirectory && (dir.list()?.isNotEmpty() == true)) {
                emit("ready", null)
                // Stage 2 starts the AudioRecord + Vosk loop here.
            } else {
                emit("model_missing", null)
            }

            // START_NOT_STICKY: Android will not resurrect this after a kill, and
            // the spec forbids implying that it survives a force-stop.
            START_NOT_STICKY
        } catch (e: Exception) {
            Log.e(TAG, "could not start foreground service", e)
            emit("error", e.message)
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        running = false
        emit("stopped", null)
        super.onDestroy()
    }

    // ---- internals ---------------------------------------------------------

    private fun hasMicrophonePermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Robi wake word",
                    NotificationManager.IMPORTANCE_LOW, // no sound, no heads-up
                ).apply {
                    description = "Keeps Robi listening for \"Hey Robi\"."
                    setShowBadge(false)
                }
            )
        }

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )

        val text = if (modelDir(this).isDirectory) {
            "Listening for \"Hey Robi\""
        } else {
            "Speech model not installed — wake word inactive"
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification: Notification = builder
            .setContentTitle("Robi")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(open)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun emit(event: String, detail: String?) {
        sink?.invoke(event, detail)
    }
}
