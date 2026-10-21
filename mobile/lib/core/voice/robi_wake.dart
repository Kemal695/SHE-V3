// =============================================================================
// SHE V3 — Robi wake word bridge (Phase 4, Stage 2)
// =============================================================================
// Talks to RobiWakeService.kt. See docs/robi-phase4-wake-word.md.
//
// The detector is grammar-restricted to "hey robi", runs entirely on the phone,
// and reports only that the phrase was heard. Command interpretation stays in
// the Dart engine — this file never decides what a command means.
//
// Events: downloading (percent) | ready | hey_robi | error | stopped
// =============================================================================

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// What the wake-word service is doing, as far as the UI can honestly tell.
enum RobiWakePhase {
  /// Not enabled.
  off,

  /// Service starting; no event yet.
  starting,

  /// Fetching the ~39 MB speech model for the first time.
  downloading,

  /// Notification is up and tapping it opens the mic. **The microphone is NOT
  /// held**, so normal in-app voice commands keep working.
  armed,

  /// Continuous detection: microphone open, waiting for the phrase. This BLOCKS
  /// the normal in-app voice commands, because the mic is exclusive.
  listening,

  /// Something failed — [RobiWakeState.detail] says what.
  error,
}

class RobiWakeState {
  final RobiWakePhase phase;

  /// 0-100 while downloading; an error message while in [RobiWakePhase.error].
  final String? detail;

  const RobiWakeState(this.phase, {this.detail});

  static const off = RobiWakeState(RobiWakePhase.off);
}

class RobiWake {
  const RobiWake();

  static const _method = MethodChannel('she/robi');
  static const _events = EventChannel('she/robi/events');

  /// Start Robi.
  ///
  /// [continuous] = false (default) shows the notification and takes NO
  /// microphone, so the normal in-app voice commands keep working.
  /// [continuous] = true opens the microphone and runs the detector — it makes
  /// the mic exclusive, which stops normal voice commands from working.
  Future<bool> start({bool continuous = false}) async {
    // The microphone is only needed for continuous detection. Arming the
    // notification does not require it, so do not ask for it then.
    if (continuous) {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) return false;
    }

    // `Permission.notification` is a no-op below API 33. Required either way:
    // Android will not let the service run without showing a notification.
    final notifications = await Permission.notification.request();
    if (notifications.isPermanentlyDenied) return false;

    try {
      await _method.invokeMethod<String>('start', {'continuous': continuous});
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<String>('stop');
    } on PlatformException {
      // The UI re-reads the real state anyway.
    }
  }

  /// Hand the microphone to the voice session.
  ///
  /// Called when a session opens. The detector releases the mic and stays off
  /// until [resume] — a timer-based re-arm is what used to steal the mic back
  /// mid-command and leave the screen stuck on "Listening…".
  Future<void> pause() async {
    try {
      await _method.invokeMethod<void>('pause');
    } on PlatformException {
      // The service may not be running; nothing to pause.
    }
  }

  /// Give the microphone back to the detector after the session closes.
  Future<void> resume() async {
    try {
      await _method.invokeMethod<void>('resume');
    } on PlatformException {
      // The service may not be running; nothing to resume.
    }
  }

  Future<bool> isRunning() async {
    try {
      return await _method.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// True once the speech model is unpacked on the device.
  Future<bool> modelInstalled() async {
    try {
      return await _method.invokeMethod<bool>('modelInstalled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Raw (event, detail) pairs from the service.
  ///
  /// The mapped stream is CACHED on purpose. `receiveBroadcastStream()` creates a
  /// new channel subscription per call, and the native side pairs onListen /
  /// onCancel with those subscriptions — so two callers meant two subscriptions,
  /// and cancelling either one (the Settings tile being disposed) tore down the
  /// other (the app-level listener). The symptom was exact: the wake word fired
  /// in the native log, but nothing in the UI ever happened after visiting
  /// Settings once. One cached broadcast stream = one subscription.
  static Stream<({String event, String? detail})>? _cached;

  Stream<({String event, String? detail})> events() => _cached ??=
      _events.receiveBroadcastStream().map((e) {
        final map = (e as Map).cast<Object?, Object?>();
        return (
          event: map['event']?.toString() ?? '',
          detail: map['detail']?.toString(),
        );
      });
}

const robiWake = RobiWake();
