package et.she.v3.she_mobile

import android.app.ActivityManager
import android.content.Context

/**
 * Robi wake word — native route decision (Phase 5, Plan §D.11 / §F.1).
 *
 * The plan moves the "open the voice screen vs. run headless" decision out of the
 * Dart [RobiWakeListener] widget and into native code, so the service that owns
 * the microphone also owns the hand-off. Command *interpretation* stays in Dart —
 * see the plan's §F.1 and MainActivity.kt's own header: only the route decision
 * moves here.
 *
 * What it decides, on every wake:
 *   - App in the foreground  -> emit EVENT_OPEN_VOICE. The Flutter UI is on
 *     screen, so Dart can open the voice screen and the user sees a card.
 *   - App backgrounded / locked / another app in front -> emit "hey_robi". Android
 *     will not show a window there, so Dart runs the whole command headless
 *     (recognize -> parse -> execute) with no UI. The command still works; only
 *     the visible card is omitted.
 *
 * By the time this runs, RobiWakeService.onWake() has already released the
 * detector's microphone, so whichever route Dart takes can claim the mic
 * immediately.
 *
 * The Dart side still re-checks visibility as a safety net; this object is the
 * authoritative decision point and keeps the microphone hand-off in one place.
 */
object RobiWakeListener {

    /**
     * True when our own process is currently a foreground process — an activity of
     * ours is what the user is looking at, so a screen can be shown.
     *
     * getRunningAppProcesses() is restricted to the caller's process on modern
     * Android, which is exactly what we need: we only ever care about our own
     * importance, never other apps'.
     */
    fun isAppForeground(context: Context): Boolean {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        val myPid = android.os.Process.myPid()
        val processes = am.runningAppProcesses ?: return false
        for (info in processes) {
            if (info.pid == myPid) {
                return info.importance ==
                    ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            }
        }
        return false
    }

    /**
     * Decide the route for a wake and emit the matching event on [service].
     * Called from [RobiWakeService.onWake] after the detector releases the mic.
     */
    fun routeWake(service: RobiWakeService) {
        if (isAppForeground(service)) {
            service.emit(RobiWakeService.EVENT_OPEN_VOICE, null)
        } else {
            service.emit("hey_robi", null)
        }
    }
}
