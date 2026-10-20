// =============================================================================
// SHE V3 — Voice diagnostics that survive a release build
// =============================================================================
// `debugPrint` does not reliably reach logcat in a release build on this device
// (it was missing from every capture), and Log.d/i are stripped by the project's
// R8 config. So diagnostics route through the Android side, which we know logs:
//
//     adb logcat -s RobiVoice:E
//
// This is intentionally a one-way fire-and-forget helper: if the platform side is
// unavailable (desktop, test), the call is dropped rather than thrown.
// =============================================================================

import 'package:flutter/services.dart';

class VoiceLog {
  static const _channel = MethodChannel('she/robi');

  static void log(String message) {
    try {
      _channel.invokeMethod<void>('log', {'msg': message});
    } on MissingPluginException {
      // Not on Android — nothing to log to.
    } on PlatformException {
      // The native side refused; never let diagnostics break a command.
    }
  }
}
