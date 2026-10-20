// =============================================================================
// SHE V3 — Robi wake word bridge (Phase 4, Stage 1)
// =============================================================================
// Talks to RobiWakeService.kt. See docs/robi-phase4-wake-word.md.
//
// Stage 1 scope: the service lifecycle, the persistent notification and the
// permission flow. Detection is Stage 2 — the on-device model is not bundled
// yet, so `start()` returns 'model_missing' and nothing pretends to listen.
// =============================================================================

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Outcome of a start attempt. Deliberately explicit: the UI must be able to say
/// why the wake word is not active instead of showing a dead switch.
enum RobiWakeStatus {
  /// Service is running and the model is present.
  listening,

  /// Service is running but there is no speech model — it is NOT listening.
  modelMissing,

  /// Microphone permission was refused.
  permissionDenied,

  /// Notification permission refused on Android 13+ — the service cannot show
  /// its required notification, so it cannot legally run.
  notificationDenied,

  /// Anything else (platform error, service refused to start).
  failed,
}

class RobiWake {
  const RobiWake();

  static const _method = MethodChannel('she/robi');
  static const _events = EventChannel('she/robi/events');

  /// Ask for the permissions the service needs, then start it.
  ///
  /// Order matters: Android requires RECORD_AUDIO for a microphone-type
  /// foreground service, and API 33+ requires POST_NOTIFICATIONS for the
  /// persistent notification that the service must display.
  Future<RobiWakeStatus> start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return RobiWakeStatus.permissionDenied;

    // `Permission.notification` is a no-op below API 33.
    final notifications = await Permission.notification.request();
    if (notifications.isPermanentlyDenied) {
      return RobiWakeStatus.notificationDenied;
    }

    try {
      final result = await _method.invokeMethod<String>('start');
      return switch (result) {
        'started' => RobiWakeStatus.listening,
        'model_missing' => RobiWakeStatus.modelMissing,
        _ => RobiWakeStatus.failed,
      };
    } on PlatformException {
      return RobiWakeStatus.failed;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<String>('stop');
    } on PlatformException {
      // Nothing to do — the switch is about to show the real state anyway.
    }
  }

  Future<bool> isRunning() async {
    try {
      return await _method.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> modelInstalled() async {
    try {
      return await _method.invokeMethod<bool>('modelInstalled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Detection events. Stage 2 emits 'hey_robi'; Stage 1 emits 'model_missing',
  /// 'ready', 'error' and 'stopped'.
  Stream<String> events() => _events.receiveBroadcastStream().map(
        (e) => (e as Map)['event']?.toString() ?? '',
      );
}

const robiWake = RobiWake();
