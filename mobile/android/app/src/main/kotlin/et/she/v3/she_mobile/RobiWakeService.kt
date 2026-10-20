package et.she.v3.she_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer

/**
 * Robi wake word — foreground service (Phase 4, Stage 2).
 *
 * See docs/robi-phase4-wake-word.md.
 *
 * Lifecycle:
 *   start -> notification -> model installed?  no -> download (progress events)
 *                                              yes -> AudioRecord + Vosk loop
 *   "hey robi" heard -> emit `hey_robi`, RELEASE THE MICROPHONE (the command
 *   session needs it — two AudioRecords would fight), resume after 15 s.
 *
 * The recognizer is grammar-restricted to two entries, so it is a keyword
 * detector rather than an open transcriber: `["hey robi", "[unk]"]`. That is
 * what keeps the CPU cost down; it still costs far more than a purpose-built
 * KWS, which is why sherpa-onnx remains the documented upgrade path.
 *
 * Android constraints this cannot escape (also stated in the UI):
 *   - force-stop kills it and it does not return until the app is opened again
 *   - the mic is exclusive; a call or another assistant takes it away
 *   - the microphone privacy indicator and this notification are always visible
 */
class RobiWakeService : Service() {

    companion object {
        private const val TAG = "RobiWake"
        private const val CHANNEL_ID = "robi_wake"
        private const val NOTIFICATION_ID = 4201

        /** Grammar: the phrase, plus [unk] so non-phrase speech is discarded. */
        private const val GRAMMAR = "[\"hey robi\", \"[unk]\"]"

        /** How long the detector stays off after a wake, so the command can use the mic. */
        private const val RESUME_AFTER_MS = 15_000L

        @Volatile
        var sink: ((String, String?) -> Unit)? = null

        @Volatile
        var running: Boolean = false
            private set

        fun modelDir(context: android.content.Context) = RobiModel.dir(context)
    }

    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null

    @Volatile
    private var listening = false

    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!hasMicrophonePermission()) {
            emit("error", "microphone_permission")
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startInForeground("Starting…")
            running = true

            if (RobiModel.isInstalled(this)) {
                startDetector()
            } else {
                // First enable: fetch the model, then start. Runs off the main
                // thread; progress goes to the UI through the event channel.
                emit("downloading", "0")
                Thread {
                    val error = RobiModel.install(this) { pct ->
                        emit("downloading", pct.toString())
                        if (pct % 20 == 0) updateNotification("Downloading speech model… $pct%")
                    }
                    if (error == null) {
                        main.post {
                            updateNotification("Listening for \"Hey Robi\"")
                            startDetector()
                        }
                    } else {
                        emit("error", "model_download_failed: $error")
                        main.post { stopSelf() }
                    }
                }.start()
            }

            START_NOT_STICKY
        } catch (e: Exception) {
            Log.e(TAG, "could not start foreground service", e)
            emit("error", e.message)
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        stopDetector()
        try {
            recognizer?.close()
        } catch (_: Exception) {
        }
        try {
            model?.close()
        } catch (_: Exception) {
        }
        recognizer = null
        model = null
        running = false
        emit("stopped", null)
        super.onDestroy()
    }

    // ---- detection ---------------------------------------------------------

    private fun startDetector() {
        if (listening) return
        if (!RobiModel.isInstalled(this)) {
            emit("model_missing", null)
            return
        }

        try {
            val m = model ?: Model(RobiModel.dir(this).absolutePath).also { model = it }
            val r = Recognizer(m, 16000.0f, GRAMMAR)
            recognizer = r

            val minBuf = AudioRecord.getMinBufferSize(
                16000,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufSize = if (minBuf > 0) minBuf * 2 else 8192

            val rec = AudioRecord(
                // VOICE_RECOGNITION enables the platform's speech pre-processing
                // (noise suppression / AGC) where the device supports it.
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                16000,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize,
            )

            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                // Another app (a call, another assistant) owns the microphone.
                emit("error", "microphone_busy")
                return
            }

            recorder = rec
            rec.startRecording()
            listening = true

            worker = Thread {
                val buf = ShortArray(4096)
                try {
                    while (listening) {
                        val n = rec.read(buf, 0, buf.size)
                        if (n > 0 && r.acceptWaveForm(buf, n)) {
                            val text = JSONObject(r.result).optString("text")
                            if (text.contains("hey robi", ignoreCase = true)) {
                                onWake()
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "audio loop stopped", e)
                }
            }.also { it.start() }

            emit("ready", null)
        } catch (e: Exception) {
            Log.e(TAG, "detector failed", e)
            emit("error", e.message)
        }
    }

    private fun onWake() {
        emit("hey_robi", null)
        // Release the microphone: the command session is about to need it, and
        // Android will not let two AudioRecords share it cleanly.
        stopDetector()
        updateNotification("Heard \"Hey Robi\" — listening for your command")
        main.postDelayed(
            {
                if (running) {
                    updateNotification("Listening for \"Hey Robi\"")
                    startDetector()
                }
            },
            RESUME_AFTER_MS,
        )
    }

    private fun stopDetector() {
        listening = false
        try {
            worker?.join(400)
        } catch (_: InterruptedException) {
        }
        worker = null
        try {
            recorder?.stop()
        } catch (_: Exception) {
        }
        try {
            recorder?.release()
        } catch (_: Exception) {
        }
        recorder = null
        try {
            recognizer?.close()
        } catch (_: Exception) {
        }
        recognizer = null
    }

    // ---- notification ------------------------------------------------------

    private fun hasMicrophonePermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun startInForeground(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Robi wake word",
                    NotificationManager.IMPORTANCE_LOW, // silent, no heads-up
                ).apply {
                    description = "Keeps Robi listening for \"Hey Robi\"."
                    setShowBadge(false)
                }
            )
        }

        val notification = buildNotification(text)
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

    private fun updateNotification(text: String) {
        try {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(text))
        } catch (e: Exception) {
            Log.w(TAG, "could not update notification", e)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Robi")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    private fun emit(event: String, detail: String?) {
        sink?.invoke(event, detail)
    }
}
