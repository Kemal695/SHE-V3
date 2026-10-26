// =============================================================================
// SHE V3 — Voice diagnostics that survive a release build (Plan §D.12)
// =============================================================================
// Relocated from core/voice/voice_log.dart and extended with the Plan §3
// `VoiceDiagnostics` performance + error categories that feed the §9 release
// gates (local parse p95, wake→capture p95, end-of-speech→result p95, error
// categories).
//
// The original `VoiceLog` is kept verbatim, except its fire-and-forget error
// handling is tightened: invokeMethod reports MissingPluginException /
// PlatformException through its future (not synchronously), so the catch must be
// on the future, not around the synchronous call.
//
// WHY THIS EXISTS: `debugPrint` does not reliably reach logcat in a release build
// on this device, and Log.d/i are stripped by R8. So diagnostics route through
// the Android side:
//
//     adb logcat -s RobiVoice:E
//
// One-way fire-and-forget: if the platform side is unavailable (desktop, test) or
// refuses, the call is dropped rather than thrown.
//
// PRIVACY (Plan §3): this captures latency stages and error categories ONLY. It
// never retains raw audio, waveforms, or transcripts beyond a short one-line log
// string. See voice_diagnostics_test, which asserts no audio container is ever
// sent to the native side.
// =============================================================================

import 'package:flutter/services.dart';

class VoiceLog {
  static const _channel = MethodChannel('she/robi');

  /// Fire-and-forget log to the `RobiVoice` logcat tag. Drops the call silently
  /// when the platform side is unavailable (desktop, test) or refuses.
  static void log(String message) {
    _channel
        .invokeMethod<void>('log', {'msg': message})
        .catchError((_) {
      // Not on Android, or the native side refused. Never let diagnostics break a
      // command. (catchError — not a try/catch — because invokeMethod reports
      // MissingPluginException / PlatformException through its future.)
    });
  }
}

/// Plan §3 `VoiceDiagnostics`: structured performance + error categories that
/// feed the §9 release gates. All timings are fire-and-forget to the same
/// `RobiVoice` logcat tag; nothing is retained in memory.
class VoiceDiagnostics {
  static const _channel = MethodChannel('she/robi');

  /// Record a named pipeline stage and optionally how long it took in
  /// milliseconds.
  ///
  /// [name] is one of the §9 stages, e.g. `'parse'`, `'wake_to_capture'`,
  /// `'eos_to_result'`, `'execute'`. Omit [durationMs] for an instantaneous
  /// marker.
  static void traceStage(String name, {int? durationMs}) {
    final msg = durationMs == null
        ? 'stage: $name'
        : 'stage: $name ${durationMs}ms';
    _channel
        .invokeMethod<void>('log', {'msg': msg})
        .catchError((_) {
      // Not on Android, or the native side refused. Never break a command over
      // diagnostics.
    });
  }

  /// Record a categorised error without retaining any payload.
  static void traceError(String category, String detail) {
    _channel
        .invokeMethod<void>('log', {'msg': 'error[$category]: $detail'})
        .catchError((_) {
      // Not on Android, or the native side refused. Never break a command over
      // diagnostics.
    });
  }
}
