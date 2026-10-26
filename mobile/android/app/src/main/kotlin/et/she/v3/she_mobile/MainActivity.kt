package et.she.v3.she_mobile

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> Robi wake-word bridge (Phase 4).
 *
 * `she/robi`        - start / stop / isRunning / modelInstalled
 * `she/robi/events` - "ready" | "model_missing" | "error" | "stopped" | "hey_robi"
 *
 * The detector reports only that the phrase was said; command interpretation
 * stays in the Dart engine (see docs/robi-phase4-wake-word.md section 3).
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** Intent extra set by Robi's notification to open the mic directly. */
        const val EXTRA_ROBI_ACTION = "robi_action"
    }

    private val methodChannel = "she/robi"
    private val eventChannel = "she/robi/events"

    /** Recognition with domain biasing — see [RobiSpeech]. */
    private val speechChannelName = "she/robi/speech"

    private val eventListeners =
        mutableMapOf<EventChannel.EventSink?, (String, String?) -> Unit>()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold start from a notification tap: Flutter has not subscribed yet, so
        // post the event once the engine is up rather than dropping it.
        if (intent?.getStringExtra(EXTRA_ROBI_ACTION) == "voice") {
            Handler(Looper.getMainLooper()).postDelayed(
                { RobiWakeService.postEvent(RobiWakeService.EVENT_OPEN_VOICE, null) },
                1500,
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra(EXTRA_ROBI_ACTION) == "voice") {
            RobiWakeService.postEvent(RobiWakeService.EVENT_OPEN_VOICE, null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // `continuous` decides whether the service opens the
                        // microphone. Default false: holding the mic blocks the
                        // normal in-app voice commands.
                        val continuous = call.argument<Boolean>("continuous") == true
                        val intent = Intent(this, RobiWakeService::class.java)
                            .putExtra(RobiWakeService.EXTRA_CONTINUOUS, continuous)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success("started")
                    }

                    "stop" -> {
                        stopService(Intent(this, RobiWakeService::class.java))
                        result.success("stopped")
                    }

                    // The voice session owns the microphone while it is open.
                    "pause" -> {
                        startService(
                            Intent(this, RobiWakeService::class.java)
                                .putExtra(
                                    RobiWakeService.EXTRA_ACTION,
                                    RobiWakeService.ACTION_PAUSE,
                                ),
                        )
                        result.success(null)
                    }

                    "resume" -> {
                        startService(
                            Intent(this, RobiWakeService::class.java)
                                .putExtra(
                                    RobiWakeService.EXTRA_ACTION,
                                    RobiWakeService.ACTION_RESUME,
                                ),
                        )
                        result.success(null)
                    }

                    // Live feedback in the notification while a headless command
                    // runs (lock screen / another app in front).
                    "notify" -> {
                        startService(
                            Intent(this, RobiWakeService::class.java)
                                .putExtra(
                                    RobiWakeService.EXTRA_ACTION,
                                    RobiWakeService.ACTION_NOTIFY,
                                )
                                .putExtra(
                                    RobiWakeService.EXTRA_TEXT,
                                    call.argument<String>("text") ?: "",
                                ),
                        )
                        result.success(null)
                    }

                    "isRunning" -> result.success(RobiWakeService.running)

                    // Whether the detector currently holds the microphone
                    // (continuous "Hey Robi"). The Settings tile reads this so it
                    // never shows "armed" while the service is really listening.
                    "isContinuous" -> result.success(RobiWakeService.continuous)

                    "modelInstalled" -> result.success(RobiKws.isInstalled(this))

                    // Voice diagnostics. Log.e because Log.d/i/v are removed
                    // from release builds by this project's R8 config, and
                    // Dart's debugPrint does not reliably reach logcat.
                    "log" -> {
                        val msg = call.argument<String>("msg") ?: ""
                        Log.e("RobiVoice", msg)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // ---- Recognition with domain biasing (see RobiSpeech) ----------------
        // Own SpeechRecognizer instead of the speech_to_text plugin: only the
        // platform API exposes EXTRA_BIASING_STRINGS, which is what makes
        // "socket two" recognisable at all on this device.
        val speechChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            speechChannelName,
        )
        val robiSpeech = RobiSpeech(this, speechChannel)
        speechChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(RobiSpeech.isAvailable(this))

                "start" -> {
                    val locale = call.argument<String>("locale") ?: "en-US"
                    val phrases = call.argument<List<String>>("phrases") ?: emptyList()
                    val silenceMs = call.argument<Int>("silenceMs") ?: 6000
                    robiSpeech.start(locale, phrases, silenceMs)
                    result.success(null)
                }

                "stop" -> {
                    robiSpeech.stop()
                    result.success(null)
                }

                "cancel" -> {
                    robiSpeech.cancel()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    val cb: (String, String?) -> Unit = { event, detail ->
                        // Always deliver on the platform thread.
                        runOnUiThread {
                            sink?.success(mapOf("event" to event, "detail" to detail))
                        }
                    }
                    eventListeners[sink] = cb
                    RobiWakeService.addListener(cb)
                }

                override fun onCancel(arguments: Any?) {
                    // Drop whichever listeners we still hold; the channel is going
                    // away, so none of them can be delivered to any more.
                    for ((_, cb) in eventListeners) {
                        RobiWakeService.removeListener(cb)
                    }
                    eventListeners.clear()
                }
            })
    }
}
