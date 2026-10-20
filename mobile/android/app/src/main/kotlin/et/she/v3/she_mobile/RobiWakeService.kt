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

        /** How long the detector stays off after a wake, so the command can use the mic. */
        private const val RESUME_AFTER_MS = 15_000L

        /**
         * Registered listeners. A LIST, not a single field: the Settings tile and
         * the app-level RobiWakeListener both subscribe to the same EventChannel,
         * and a single field meant whichever subscribed last silently stole every
         * event from the other — which is why the tile sat on "Starting…" while
         * the service was running and logging normally.
         */
        private val listeners = mutableListOf<(String, String?) -> Unit>()

        @Volatile
        var running: Boolean = false
            private set

        fun addListener(l: (String, String?) -> Unit) {
            listeners.add(l)
        }

        fun removeListener(l: (String, String?) -> Unit) {
            listeners.remove(l)
        }

        fun modelDir(context: android.content.Context) = RobiModel.dir(context)

        /** Event name emitted when the user taps the Robi notification. */
        const val EVENT_OPEN_VOICE = "open_voice"

        /** Deliver an event that did not originate in this service (e.g. a tap). */
        fun postEvent(event: String, detail: String?) {
            for (l in listeners.toList()) {
                try {
                    l(event, detail)
                } catch (t: Throwable) {
                    Log.e(TAG, "listener failed", t)
                }
            }
        }
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
                    try {
                        val error = RobiModel.install(this) { pct ->
                            emit("downloading", pct.toString())
                            if (pct % 20 == 0) {
                                updateNotification("Downloading speech model… $pct%")
                            }
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
                    } catch (e: Throwable) {
                        // Unzip can OOM on a low-memory phone; an Error here
                        // would otherwise kill the process from a worker thread.
                        Log.e(TAG, "model install failed", e)
                        emit("error", "${e::class.java.simpleName}: ${e.message}")
                        main.post { stopSelf() }
                    }
                }.start()
            }

            START_NOT_STICKY
        } catch (e: Throwable) {
            // Throwable, not Exception: the failure modes here are ERRORS —
            // UnsatisfiedLinkError (libvosk not loadable), NoClassDefFoundError
            // (JNA stripped by R8), OutOfMemoryError (model too big for the
            // device). `catch (Exception)` let all three escape onStartCommand
            // and killed the whole app instead of showing an error.
            Log.e(TAG, "could not start foreground service", e)
            emit("error", "${e::class.java.simpleName}: ${e.message}")
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
            // NO GRAMMAR. An earlier version restricted recognition to
            // ["hey robi", "[unk]"], which was wrong: that phrase is not in the
            // model's vocabulary, so with a two-choice grammar the recogniser
            // answered "[unk]" to almost everything — measured on the LE6 it
            // returned '[unk]' ~95% of the time and a bare 'hey' once, so the
            // phrase never made it into a result at all. Free transcription
            // costs a little more CPU but produces "hey roby" / "hey robby" /
            // "hey robie", which the fuzzy match in isWakePhrase() accepts.
            val r = Recognizer(m, 16000.0f)
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
                            if (text.isNotBlank()) {
                                // Log.e, not Log.d: this project's R8 config
                                // deletes Log.v/d/i from release builds, so a
                                // debug line here would be invisible exactly
                                // where we need it.
                                Log.e(TAG, "vosk heard: '$text'")
                            }
                            if (isWakePhrase(text)) {
                                onWake()
                            }
                        }
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "audio loop stopped", e)
                }
            }.also { it.start() }

            emit("ready", null)
        } catch (e: Throwable) {
            // See onStartCommand: these are Errors, not Exceptions. Report the
            // class name so the UI can say WHICH failure it is.
            Log.e(TAG, "detector failed", e)
            emit("error", "${e::class.java.simpleName}: ${e.message}")
        }
    }

    /**
     * Does [text] contain the wake phrase?
     *
     * NOT an exact "hey robi" comparison. "Robi" is a coined name that is not in
     * the model's vocabulary, so the recogniser renders it however the nearest
     * English words fall — "hey roby", "hey robby", "hey robie", "hey robe" are
     * all normal outcomes for a non-native pronunciation. Requiring the exact
     * spelling meant the phrase never matched and Robi listened forever.
     *
     * The rule stays narrow on purpose: an explicit "hey" AND a token starting
     * with "rob". "hey" alone would fire on ordinary conversation.
     */
    private fun isWakePhrase(text: String): Boolean {
        val lower = text.lowercase()
        if (!lower.contains("hey")) return false
        return lower.split(' ', '\t', ',', '.', '!', '?').any { it.startsWith("rob") }
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
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                // Tapping Robi's notification opens the mic directly. This is the
                // reliable alternative to the wake word: it works from any app,
                // with the screen locked, and does not depend on the model ever
                // transcribing "Hey Robi" correctly.
                putExtra(MainActivity.EXTRA_ROBI_ACTION, "voice")
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
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
        // Copy before iterating: a listener may unsubscribe while we dispatch.
        for (l in listeners.toList()) {
            try {
                l(event, detail)
            } catch (t: Throwable) {
                Log.e(TAG, "listener failed", t)
            }
        }
    }
}
