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
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Vibrator
import android.util.Log
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.OnlineStream

/**
 * Robi wake word — foreground service (Phase 4, sherpa-onnx KWS; Phase 5 route
 * decision lives in RobiWakeListener.kt).
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
        /**
         * v2: Android IGNORES an importance change on an existing channel, so the
         * old `IMPORTANCE_LOW` channel could never be made visible on the lock
         * screen. A fresh id is the only way to apply the new DEFAULT importance.
         */
        private const val CHANNEL_ID = "robi_wake_v2"
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

        /**
         * True when the detector is (or was last started) holding the
         * microphone. The Settings tile reads this so its switch reflects the
         * SERVICE, not a widget-local flag that resets to false whenever the
         * screen is reopened — which made the tile show "armed" while the
         * detector was actually listening, and made the next toggle silently
         * switch continuous detection off.
         */
        val continuous: Boolean
            get() = continuousMode

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

    /** Reused beeper for the "heard you" cue; released in onDestroy(). */
    private var tone: ToneGenerator? = null

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
        // Release the reused KeywordSpotter (Plan §D.11 step 2) on the way out.
        try {
            spotter?.release()
        } catch (_: Throwable) {
        }
        spotter = null
        try {
            tone?.release()
        } catch (_: Throwable) {
        }
        tone = null
        running = false
        emit("stopped", null)
        super.onDestroy()
    }

    // ---- detection ---------------------------------------------------------

    private fun startDetector() {
        if (listening) return

        try {
            // Reuse the loaded KeywordSpotter across wake cycles (Plan §D.11 step
            // 2) so the ~5 MB model is not reloaded and re-initialised on every
            // wake. Only the per-session stream is recreated.
            val s = spotter ?: RobiKws.create(this).also { spotter = it }
            val st = s.createStream() // keywords come from keywords.txt
            stream = st

            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufSize = if (minBuf > 0) minBuf * 2 else 8192

            // RAW microphone, NOT VOICE_RECOGNITION. The platform's speech
            // pre-processing (AGC + noise suppression) on VOICE_RECOGNITION made
            // the capture level swing with the room: in a quiet room its gain sat
            // low and "Hey Robi" was recorded too quietly to spot (missed wake);
            // in a noisy room it cranked the gain up and the same phrase fired.
            // We capture raw and normalise the level ourselves (the AGC in the
            // worker loop) so the keyword spotter sees a consistent signal in
            // EVERY condition — quiet room, noise, or echo.
            val rec = createRawRecorder(bufSize) ?: run {
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
                // Our own level normalisation (AGC) — replaces the platform AGC we
                // just removed. Brings every frame to a fixed RMS so the keyword
                // score is independent of room loudness, mic distance, or noise.
                var agcGain = 3.0f
                val AGC_TARGET = 0.10f
                val AGC_MIN = 1.0f
                val AGC_MAX = 14.0f
                var frameCount = 0
                try {
                    while (listening) {
                        val n = rec.read(pcm, 0, pcm.size)
                        if (n <= 0) continue
                        var sumSq = 0.0f
                        for (i in 0 until n) {
                            val raw = pcm[i] / 32768.0f
                            sumSq += raw * raw
                        }
                        val rms = kotlin.math.sqrt(sumSq / n)
                        // Desired gain to drive this frame to the target RMS,
                        // clamped so we never wildly amplify silence or deafen
                        // on loud input.
                        val desired = if (rms > 1e-4f) {
                            (AGC_TARGET / rms).coerceIn(AGC_MIN, AGC_MAX)
                        } else {
                            AGC_MIN
                        }
                        // Smooth so the gain does not jump between 100 ms frames.
                        agcGain = agcGain * 0.6f + desired * 0.4f
                        for (i in 0 until n) {
                            var v = (pcm[i] / 32768.0f) * agcGain
                            if (v > 1.0f) v = 1.0f else if (v < -1.0f) v = -1.0f
                            samples[i] = v
                        }
                        // ~1 Hz level report — confirms we feed the spotter a sane,
                        // steady signal (and are not amplifying silence).
                        if (++frameCount % 10 == 0) {
                            Log.e(
                                TAG,
                                "kws level rms=" +
                                    String.format("%.4f", rms) +
                                    " gain=" + String.format("%.2f", agcGain),
                            )
                        }
                        st.acceptWaveform(samples.copyOf(n), SAMPLE_RATE)
                        while (s.isReady(st)) {
                            s.decode(st)
                        }
                        val keyword = s.getResult(st).keyword
                        if (keyword.isNotBlank()) {
                            // Log.e, not Log.d: R8 deletes Log.v/d/i in release.
                            Log.e(
                                TAG,
                                "kws matched: '$keyword' rms=" +
                                    String.format("%.4f", rms) +
                                    " gain=" + String.format("%.2f", agcGain),
                            )
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

    /**
     * Open a RAW microphone recorder with no platform AGC / noise suppression, so
     * the wake-word capture level is predictable across rooms. Tries UNPROCESSED
     * (cleanest, API 29+) first, then falls back to MIC. Returns null if neither
     * could be initialised — i.e. the microphone is owned by a call / another app.
     */
    private fun createRawRecorder(bufSize: Int): AudioRecord? {
        val candidates = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            arrayOf(
                MediaRecorder.AudioSource.UNPROCESSED,
                MediaRecorder.AudioSource.MIC,
            )
        } else {
            arrayOf(MediaRecorder.AudioSource.MIC)
        }
        for (src in candidates) {
            val rec = try {
                AudioRecord(
                    src,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufSize,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "createRawRecorder src=$src failed", t)
                null
            }
            if (rec != null && rec.state == AudioRecord.STATE_INITIALIZED) return rec
            rec?.release()
        }
        return null
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
            // Immediate "I heard you" cue — ONLY when no window can be shown
            // (locked / another app in front). In the foreground the voice screen
            // itself is the cue, and a beep there could be captured by the
            // recognizer that is about to open the mic.
            if (!RobiWakeListener.isAppForeground(this)) cueHeard()
            // Route the wake natively (Plan §D.11 / §F.1): foreground -> open the
            // voice screen, background -> let Dart run headless. The Dart
            // RobiWakeListener still re-checks visibility as a safety net.
            RobiWakeListener.routeWake(this)
            updateNotification("Heard \"Hey Robi\" — listening for your command")
            // NO timer here. The session resumes the detector when it closes
            // (ACTION_RESUME). Re-arming on a timer is what stole the mic back
            // mid-command and left the screen stuck on "Listening…".
        }
    }

    /**
     * Audible + tactile acknowledgement that "Hey Robi" was heard.
     *
     * Beep on the notification stream (muted in silent mode), plus a brief
     * vibration that still fires when the phone is silenced — so there is a sign
     * the assistant is working even with the screen locked and dark.
     */
    private fun cueHeard() {
        try {
            val t = tone ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90)
                .also { tone = it }
            t.startTone(ToneGenerator.TONE_PROP_BEEP, 180)
        } catch (t: Throwable) {
            Log.w(TAG, "beep failed", t)
        }
        try {
            @Suppress("DEPRECATION")
            val v = getSystemService(android.content.Context.VIBRATOR_SERVICE) as? Vibrator
            if (v != null && v.hasVibrator()) {
                @Suppress("DEPRECATION")
                v.vibrate(140)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "vibrate failed", t)
        }
    }

    private fun stopDetector() {
        listening = false
        // 200 ms, not 400: the worker reads in 100 ms chunks and exits on the
        // next loop, so 200 ms is plenty — and every millisecond here is wake
        // latency the user feels.
        try {
            worker?.join(200)
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
        // Do NOT release the KeywordSpotter here: it is reused across detector
        // cycles (Plan §D.11 step 2). It is released once in onDestroy().
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
                    // DEFAULT, not LOW: LOW is hidden on many lock screens, which
                    // is exactly why the user saw "no sign". The channel is still
                    // silent (no per-update sound); the one-time "heard you" cue
                    // is played explicitly in cueHeard().
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Keeps Robi available for voice commands."
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    // Show the actual text on the lock screen instead of
                    // "Contents hidden".
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
            )
            // Retire the old silent channel so it does not linger in Settings.
            try {
                manager.deleteNotificationChannel("robi_wake")
            } catch (_: Throwable) {
            }
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
            // Make the status text readable on the lock screen — the only
            // feedback available when no window can be shown.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_DEFAULT)
            .build()
    }

    internal fun emit(event: String, detail: String?) {
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
