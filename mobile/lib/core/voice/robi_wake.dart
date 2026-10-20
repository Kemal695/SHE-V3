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

  /// Model present, microphone open, waiting for the phrase.
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

  /// Ask for the permissions the service needs, then start it.
  ///
  /// Returns false only when a permission was refused — a missing model is not
  /// a failure any more: the service downloads it and reports progress.
  Future<bool> start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;

    // `Permission.notification` is a no-op below API 33.
    final notifications = await Permission.notification.request();
    if (notifications.isPermanentlyDenied) return false;

    try {
      await _method.invokeMethod<String>('start');
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

  Future<bool> isRunning() async {
    try {
      return await _method.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Raw (event, detail) pairs from the service.
  Stream<({String event, String? detail})> events() =>
      _events.receiveBroadcastStream().map((e) {
        final map = (e as Map).cast<Object?, Object?>();
        return (
          event: map['event']?.toString() ?? '',
          detail: map['detail']?.toString(),
        );
      });
}

const robiWake = RobiWake();
