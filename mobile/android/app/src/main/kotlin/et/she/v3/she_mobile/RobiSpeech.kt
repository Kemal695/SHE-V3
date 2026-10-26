package et.she.v3.she_mobile

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Robi speech recognition — the app's OWN [SpeechRecognizer].
 *
 * WHY THIS EXISTS (why speech_to_text is no longer used for commands)
 * ------------------------------------------------------------------
 * 1. BIASING. Android 13+ lets the caller pass `EXTRA_BIASING_STRINGS`: phrases
 *    the recogniser should favour. Our vocabulary is tiny and fixed ("socket
 *    one".."socket eight", "light one".."light sixteen", "turn on/off"), and
 *    without biasing Google's language model replaces those with ordinary
 *    English. Measured on the TECNO LE6:
 *
 *      said:  "turn on socket 1 socket 2 and light 1"
 *      got:   "turn on socket one it's okay to in the light one"
 *
 *    The plugin exposes no way to set biasing strings, which is why this class
 *    exists at all. This is the same mechanism Amazon/Google use to make device
 *    names and skill vocabularies recognisable ("speech adaptation").
 *
 * 2. ENDPOINTING. `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS` controls
 *    how much silence ends an utterance, and it is honoured by the engine. The
 *    plugin's `pauseFor` was not honoured in every listen mode: a 4 s window
 *    turned into a 17-minute session that never released the microphone.
 *
 * 3. HYPOTHESES. [onResults] returns up to `EXTRA_MAX_RESULTS` alternatives. The
 *    Dart side parses them all and executes the best one, so a mangled top guess
 *    no longer loses the command.
 *
 * Contract (MethodChannel `she/robi/speech`)
 * ------------------------------------------
 *   Dart -> native: start {locale, phrases[], silenceMs}, stop, cancel, available
 *   native -> Dart: "event" {event: ready|partial|endOfSpeech|final|error|done,
 *                            text?, hypotheses?, code?, message?}
 *
 * Every callback runs on the main thread; [SpeechRecognizer] requires it.
 */
class RobiSpeech(
    private val context: Context,
    private val channel: MethodChannel,
) : RecognitionListener {

    companion object {
        private const val TAG = "RobiSpeech"

        /**
         * Biasing is OFF while we establish a baseline.
         *
         * Measured on the LE6 with 65 fragment phrases ("socket one", "light
         * two", …): the recogniser opened the microphone, ran for 8 s and then
         * returned `final 0 hypothesis(es)` / `ERROR_NO_MATCH` — i.e. it heard
         * audio but produced no text at all. Android's biasing is "speech
         * adaptation" and expects FULL utterances a user would say, not
         * vocabulary fragments, so a fragment list can starve the model.
         *
         * Kept behind this flag so it is one line to re-enable with proper
         * full-sentence phrases once we have a clean baseline.
         */
        private const val BIAS_ENABLED = false

        /** True when this device can recognise speech at all. */
        fun isAvailable(context: Context): Boolean = try {
            SpeechRecognizer.isRecognitionAvailable(context)
        } catch (t: Throwable) {
            Log.e(TAG, "isRecognitionAvailable failed", t)
            false
        }

        /** Human-readable error names — logcat is the only place these surface. */
        private fun errorName(code: Int): String = when (code) {
            SpeechRecognizer.ERROR_AUDIO -> "audio"
            SpeechRecognizer.ERROR_CLIENT -> "client"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "no-permission"
            SpeechRecognizer.ERROR_NETWORK -> "network"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network-timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "no-match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
            SpeechRecognizer.ERROR_SERVER -> "server"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech-timeout"
            else -> "code-$code"
        }
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * A single, long-lived [SpeechRecognizer] reused across every command
     * session.
     *
     * WHY REUSE INSTEAD OF CREATE/DESTROY PER SESSION
     * ----------------------------------------------
     * The previous design built a brand-new recognizer on every `start()` and
     * destroyed it 50 ms after each result. On the LE6 that churn made Robi get
     * progressively worse — "weak after two or three attempts": rapid
     * create/destroy leaves the engine's audio session half-torn-down, so
     * `startListening` starts returning `ERROR_RECOGNIZER_BUSY` and the mic
     * hand-off from the wake-word detector fights a stale instance. Android's
     * own docs say a single instance may be reused after `cancel()`; only
     * `destroy()` forces a fresh one. We therefore keep one instance for the
     * app's life and only `cancel()` between sessions, recreating only if the
     * instance gets stuck (start throws / busy error).
     */
    private var recognizer: SpeechRecognizer? = null

    /** True from start() until a final result, an error, or cancel(). */
    private var active = false

    /** Create (once) and return the shared recognizer, wiring the listener. */
    private fun ensureRecognizer(): SpeechRecognizer? {
        val existing = recognizer
        if (existing != null) return existing
        val r = try {
            SpeechRecognizer.createSpeechRecognizer(context)
        } catch (t: Throwable) {
            Log.e(TAG, "createSpeechRecognizer failed", t)
            return null
        }
        r.setRecognitionListener(this)
        recognizer = r
        return r
    }

    fun start(locale: String, phrases: List<String>, silenceMs: Int) {
        main.post {
            if (!isAvailable(context)) {
                emit("event" to "error", "code" to -1, "message" to "unavailable")
                return@post
            }
            // Reset per-session state before (re)starting.
            peakRms = -100f
            rmsTicks = 0
            lastPartial = null
            active = true
            val r = ensureRecognizer()
            if (r == null) {
                active = false
                emit("event" to "error", "code" to -2, "message" to "create-failed")
                return@post
            }
            try {
                // Abort any in-flight session on the shared instance, then start a
                // fresh one. cancel() (unlike destroy()) leaves the instance
                // reusable, so we never churn the engine's audio session.
                r.cancel()
                r.startListening(buildIntent(locale, phrases, silenceMs))
                Log.e(TAG, "start locale=$locale phrases=${phrases.size} silence=${silenceMs}ms")
            } catch (t: Throwable) {
                Log.e(TAG, "startListening failed — recreating", t)
                // The instance is stuck: tear it down and try exactly once more
                // with a fresh recognizer, so one bad session does not kill voice.
                destroyRecognizer()
                val r2 = ensureRecognizer()
                if (r2 == null) {
                    active = false
                    emit("event" to "error", "code" to -3, "message" to "start-failed")
                    return@post
                }
                try {
                    r2.startListening(buildIntent(locale, phrases, silenceMs))
                    Log.e(TAG, "start (recreated) locale=$locale")
                } catch (t2: Throwable) {
                    Log.e(TAG, "startListening failed after recreate", t2)
                    active = false
                    emit("event" to "error", "code" to -3, "message" to "start-failed")
                }
            }
        }
    }

    /** Flush the utterance: the engine returns a final result for what it heard. */
    fun stop() {
        main.post {
            try {
                recognizer?.stopListening()
            } catch (t: Throwable) {
                Log.e(TAG, "stopListening failed", t)
            }
        }
    }

    /**
     * Abort the current listen. Unlike the old `cancelInternal`, this does NOT
     * destroy the shared recognizer — it only cancels so the instance is ready
     * for the next `start()`. Destroying on every cancel was the source of the
     * "weak after N attempts" degradation.
     */
    fun cancel() = main.post {
        active = false
        try {
            recognizer?.cancel()
        } catch (t: Throwable) {
            Log.e(TAG, "cancel failed", t)
        }
    }

    private fun buildIntent(
        locale: String,
        phrases: List<String>,
        silenceMs: Int,
    ): Intent {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        intent.putExtra(
            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
        )
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        intent.putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 8)
        // Never force offline: the network model is markedly more accurate, and
        // the phone has internet. (Offline is the fallback the engine picks.)
        intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
        // Endpointing. Both the "complete" and "possibly complete" thresholds are
        // set so a short command is not cut off mid-word but the session still
        // ends promptly once the user stops talking.
        intent.putExtra(
            RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
            silenceMs,
        )
        intent.putExtra(
            RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
            silenceMs,
        )
        if (BIAS_ENABLED &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            phrases.isNotEmpty()
        ) {
            intent.putStringArrayListExtra(
                RecognizerIntent.EXTRA_BIASING_STRINGS,
                ArrayList(phrases),
            )
        }
        return intent
    }

    /**
     * Tear down the shared recognizer. Called only on real teardown or to
     * recover a stuck instance — never per command session; destroying on every
     * session is what made Robi degrade after a few attempts.
     */
    private fun destroyRecognizer() {
        val r = recognizer
        recognizer = null
        if (r != null) {
            try {
                r.setRecognitionListener(null)
                r.cancel()
                r.destroy()
                Log.e(TAG, "recognizer destroyed")
            } catch (t: Throwable) {
                Log.e(TAG, "destroy failed", t)
            }
        }
    }

    /** Release the recognizer when the Flutter engine detaches. */
    fun dispose() = main.post { destroyRecognizer() }

    private fun emit(vararg pairs: Pair<String, Any?>) {
        val map = HashMap<String, Any?>()
        for (p in pairs) map[p.first] = p.second
        try {
            channel.invokeMethod("event", map)
        } catch (t: Throwable) {
            Log.e(TAG, "emit failed", t)
        }
    }

    private fun finish(why: String) {
        if (!active) return
        active = false
        emit("event" to "done")
        // The shared recognizer is reused — do NOT destroy it here. The previous
        // 50 ms delayed cancel()/destroy() could race a new session started in
        // that window and kill it, which is the "dead after the second attempt"
        // bug. The instance is cancelled/recreated only in start()/dispose().
    }

    // ---- RecognitionListener ------------------------------------------------

    /** Highest RMS seen this session — proves whether audio ever arrived. */
    private var peakRms = -100f

    /** Callback counter, so RMS is logged at a readable rate. */
    private var rmsTicks = 0

    /**
     * The last non-empty partial transcript.
     *
     * MEASURED, and the reason voice appeared completely dead: the engine streams
     * the words as partials and then returns an EMPTY list in onResults.
     *
     *   13:27:43 partial: turn on
     *   13:27:43 partial: turn on socket 7
     *   13:27:43 final 0 hypothesis(es) peakRms=10.0: null   <- nothing
     *
     * The audio was perfect (peakRms 10) and the sentence was already recognised;
     * only the final delivery failed. So the last partial is used as the
     * transcript whenever the final comes back empty or as no-match.
     */
    private var lastPartial: String? = null

    override fun onReadyForSpeech(params: Bundle?) {
        Log.e(TAG, "ready")
        emit("event" to "ready")
    }

    override fun onBeginningOfSpeech() {
        Log.e(TAG, "speech started")
    }

    override fun onRmsChanged(rmsdB: Float) {
        if (rmsdB > peakRms) peakRms = rmsdB
        // ~1 log line per 40 callbacks: enough to see the level move, quiet
        // enough to keep the buffer usable.
        rmsTicks++
        if (rmsTicks % 40 == 0) Log.e(TAG, "rms=${rmsdB} peak=${peakRms}")
    }

    override fun onBufferReceived(buffer: ByteArray?) = Unit

    override fun onEndOfSpeech() {
        emit("event" to "endOfSpeech")
    }

    override fun onError(error: Int) {
        Log.e(TAG, "error ${errorName(error)}")
        val partial = lastPartial
        if ((error == SpeechRecognizer.ERROR_NO_MATCH ||
                error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) &&
            !partial.isNullOrBlank()
        ) {
            Log.e(TAG, "error ${errorName(error)} — using partial \"$partial\"")
            emit("event" to "final", "hypotheses" to arrayListOf(partial))
            finish("error-with-partial")
            return
        }
        emit("event" to "error", "code" to error, "message" to errorName(error))
        finish("error")
    }

    override fun onResults(results: Bundle?) {
        var list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?: arrayListOf()
        if (list.isEmpty()) {
            // The engine recognised the sentence but delivered no final result.
            // Use what it already told us through partials.
            val partial = lastPartial
            if (!partial.isNullOrBlank()) {
                Log.e(TAG, "final empty — falling back to partial \"$partial\"")
                list = arrayListOf(partial)
            }
        }
        Log.e(
            TAG,
            "final ${list.size} hypothesis(es) peakRms=$peakRms: ${list.firstOrNull()}",
        )
        if (list.isEmpty()) {
            emit("event" to "error", "code" to -4, "message" to "empty-final")
            finish("empty-final")
            return
        }
        emit("event" to "final", "hypotheses" to list)
        finish("results")
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?: return
        val text = list.firstOrNull()?.trim().orEmpty()
        if (text.isEmpty()) return
        lastPartial = text
        Log.e(TAG, "partial: $text")
        emit("event" to "partial", "text" to text)
    }

    override fun onEvent(eventType: Int, params: Bundle?) = Unit
}
