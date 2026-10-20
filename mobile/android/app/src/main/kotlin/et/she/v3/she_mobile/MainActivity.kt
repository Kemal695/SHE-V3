package et.she.v3.she_mobile

import android.content.Intent
import android.os.Build
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

    private val methodChannel = "she/robi"
    private val eventChannel = "she/robi/events"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // The service installs the model on first run, so it is
                        // always safe to start; it reports progress via events.
                        val intent = Intent(this, RobiWakeService::class.java)
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

                    "isRunning" -> result.success(RobiWakeService.running)

                    "modelInstalled" -> result.success(RobiModel.isInstalled(this))

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

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    RobiWakeService.sink = { event, detail ->
                        // Always deliver on the platform thread.
                        runOnUiThread {
                            sink?.success(mapOf("event" to event, "detail" to detail))
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    RobiWakeService.sink = null
                }
            })
    }
}
