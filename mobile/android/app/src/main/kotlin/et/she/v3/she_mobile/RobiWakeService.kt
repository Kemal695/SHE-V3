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
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.OnlineStream

/**
 * Robi wake word — foreground service (Phase 4, sherpa-onnx KWS).
 *
 * See docs/robi-phase4-wake-word.md.
 *
 * Two modes:
 *   ARMED (default)  — notification only. NO microphone. Tapping it opens the
 *                      voice screen. This exists because holding the mic makes
 *                      it exclusive, which stops the normal in-app voice
 *                      commands from working.
 *   CONTINUOUS       — opens the mic and runs the keyword spotter. Explicit
 *                      opt-in, because it costs the in-app voice commands.
 *
 * The detector matches audio against a keyword model rather than transcribing,
 * so "HEY ROBI" works even though "Robi" is not a word — see RobiKws.kt for why
 * the previous Vosk-based attempt could never work.
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

        /**
         * Safety net only. The voice session resumes the detector itself when it
         * closes; this exists so a crashed or abandoned session cannot leave the
         * wake word dead for the rest of the app's life.
         */
        private const val PAUSE_SAFETY_MS = 120_000L

        private const val SAMPLE_RATE = 16000

        /**
         * Registered listeners. A LIST, not a single field: the Settings tile and
         * the app-level RobiWakeListener both subscribe to the same EventChannel,
         * and a single field meant whichever subscribed last silently stole every
         * event from the other.
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

        fun modelDir(context: android.content.Context) = RobiKws.dir(context)

        /** Intent extra: actually open the microphone and run the detector. */
        const val EXTRA_CONTINUOUS = "continuous"

        /** Event name emitted when the user taps the Robi notification. */
        const val EVENT_OPEN_VOICE = "open_voice"

        /** Event when Robi is armed but NOT holding the microphone. */
        const val EVENT_ARMED = "armed"

        /** Intent extra: "pause" / "resume" the detector around a voice session. */
        const val EXTRA_ACTION = "action"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"

        /**
         * Show a line of text in Robi's notification.
         *
         * This is how the user gets feedback when no window is possible — on the
         * lock screen or with another app in front. A notification can be shown
         * there; an activity cannot.
         */
        const val ACTION_NOTIFY = "notify"
        const val EXTRA_TEXT = "text"

        /**
         * Remembers whether the user chose continuous detection, so a resume
         * after a session knows whether to re-open the microphone.
         */
        @Volatile
        private var continuousMode = false

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

    private var spotter: KeywordSpotter? = null
    private var stream: OnlineStream? = null
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null

    @Volatile
    private var listening = false

    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // ---- Session control -------------------------------------------------
        // The voice session OWNS the microphone from start to finish. It pauses
        // the detector when it opens and resumes it when it closes. This replaces
        // the old timer-based re-arm, which is what made the two fight: the
        // detector grabbed the mic back mid-command and left the recognizer
        // hanging on "Listening…" forever.
        when (intent?.getStringExtra(EXTRA_ACTION)) {
            ACTION_PAUSE -> {
                stopDetector()
                updateNotification("In a conversation…")
                // Safety net: if the session never reports back (crash, force
                // close), re-arm eventually rather than staying dead forever.
                main.removeCallbacksAndMessages(null)
                main.postDelayed(
                    {
                        if (running && continuousMode && !listening) startDetector()
                    },
                    PAUSE_SAFETY_MS,
                )
                return START_NOT_STICKY
            }

            ACTION_RESUME -> {
                main.removeCallbacksAndMessages(null)
                if (continuousMode && running) {
                    startDetector()
                } else {
                    updateNotification("Tap to speak a command")
                }
                return START_NOT_STICKY
            }

            ACTION_NOTIFY -> {
                // Live feedback while a headless command runs (lock screen /
                // another app). Text comes from Dart, which owns the session.
                updateNotification(intent.getStringExtra(EXTRA_TEXT) ?: "")
                return START_NOT_STICKY
            }
        }

        val continuous = intent?.getBooleanExtra(EXTRA_CONTINUOUS, false) == true
        continuousMode = continuous

        // The microphone is only needed for continuous detection. Arming the
        // notification does not touch it, so do not demand the permission then.
        if (continuous && !hasMicrophonePermission()) {
            emit("error", "microphone_permission")
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startInForeground("Starting…")
            running = true

            if (!continuous) {
                // Switching continuous OFF must release the microphone. Doing it
                // here means the caller can simply start the service again with
                // continuous=false, instead of stop-then-start — which raced:
                // stopService is asynchronous, so onDestroy could land AFTER the
                // new start and kill the service the user just enabled.
                stopDetector()
                updateNotification("Tap to speak a command")
                emit(EVENT_ARMED, null)
                return START_NOT_STICKY
            }

            val error = RobiKws.ensureInstalled(this)
            if (error != null) {
                emit("error", "model_install_failed: $error")
                stopSelf()
                return START_NOT_STICKY
            }

            startDetector()
            START_NOT_STICKY
        } catch (e: Throwable) {
            // Throwable, not Exception: the failure modes here are ERRORS —
            // UnsatisfiedLinkError (native lib not loadable), NoClassDefFoundError
            // (stripped by R8), OutOfMemoryError. `catch (Exception)` let all
            // three escape onStartCommand and killed the whole app.
            Log.e(TAG, "could not start foreground service", e)
            emit("error", "${e::class.java.simpleName}: ${e.message}")
            stopSelf()
            START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        stopDetector()
        running = false
        emit("stopped", null)
        super.onDestroy()
    }

    // ---- detection ---------------------------------------------------------

    private fun startDetector() {
        if (listening) return

        try {
            val s = RobiKws.create(this)
            spotter = s
            val st = s.createStream() // keywords come from keywords.txt
            stream = st

            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufSize = if (minBuf > 0) minBuf * 2 else 8192

            val rec = AudioRecord(
                // VOICE_RECOGNITION enables the platform's speech pre-processing
                // (noise suppression / AGC) where the device supports it.
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
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
                val pcm = ShortArray(1600) // 100 ms at 16 kHz
                val samples = FloatArray(pcm.size)
                try {
                    while (listening) {
                        val n = rec.read(pcm, 0, pcm.size)
                        if (n <= 0) continue
                        for (i in 0 until n) {
                            // sherpa-onnx expects normalised floats in [-1, 1].
                            samples[i] = pcm[i] / 32768.0f
                        }
                        st.acceptWaveform(samples.copyOf(n), SAMPLE_RATE)
                        while (s.isReady(st)) {
                            s.decode(st)
                        }
                        val keyword = s.getResult(st).keyword
                        if (keyword.isNotBlank()) {
                            // Log.e, not Log.d: this project's R8 config deletes
                            // Log.v/d/i from release builds.
                            Log.e(TAG, "kws matched: '$keyword'")
                            s.reset(st)
                            onWake()
                        }
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "audio loop stopped", t)
                }
            }.also { it.start() }

            updateNotification("Listening for \"Hey Robi\"")
            emit("ready", null)
        } catch (e: Throwable) {
            Log.e(TAG, "detector failed", e)
            emit("error", "${e::class.java.simpleName}: ${e.message}")
        }
    }

    private fun onWake() {
        // Runs on the main thread: stopDetector() joins the audio worker, and
        // this method is CALLED FROM that worker — joining itself would stall
        // the loop.
        main.post {
            // Release the microphone BEFORE telling Dart. The voice screen opens
            // a recognizer within ~200 ms of the event and the mic is exclusive,
            // so emitting first made the command session race the detector.
            stopDetector()
            emit("hey_robi", null)
            updateNotification("Heard \"Hey Robi\" — listening for your command")
            // NO timer here. The session resumes the detector when it closes
            // (ACTION_RESUME). Re-arming on a timer is what stole the mic back
            // mid-command and left the screen stuck on "Listening…".
        }
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
            stream?.release()
        } catch (_: Throwable) {
        }
        stream = null
        try {
            spotter?.release()
        } catch (_: Throwable) {
        }
        spotter = null
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
                    description = "Keeps Robi available for voice commands."
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
                // reliable path: it works from any app, with the screen locked.
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
