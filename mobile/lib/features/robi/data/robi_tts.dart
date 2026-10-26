// =============================================================================
// SHE V3 — Robi spoken feedback (text-to-speech)
// =============================================================================
// The user hears a short confirmation when Robi wakes ("Yes?") and the outcome
// when a command fails or executes. One shared engine for the whole app.
//
// Design notes (why it looks the way it does):
//
//  * AWAIT-BEFORE-MIC. The microphone is exclusive, so the wake confirmation is
//    awaited BEFORE the recognizer opens — otherwise Robi's own "Yes?" is
//    captured and transcribed. `awaitSpeakCompletion(true)` is what makes
//    speak() resolve when the utterance has actually finished, not when queued.
//
//  * NEWEST WINS. Two overlapping messages must not interleave their stop()/
//    speak() and cut each other off. A generation counter makes a newer speak()
//    cancel an older in-flight one, so the latest feedback always plays whole.
//
//  * NEVER BLOCKS FOREVER. A stuck TTS engine must not stop the recognizer from
//    opening, so each utterance has a length-aware timeout.
//
//  * NEVER THROWS. No engine / no language data just means silence; the beep,
//    vibration and notification remain the feedback.
//
// English is forced because every message Robi speaks today is English (see
// HandleUtterance / CommandExecutor). If the phone has no en-US data, we fall
// back to the device default rather than staying mute.
// =============================================================================

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tts/flutter_tts.dart';

class RobiTts {
  RobiTts._();

  static final RobiTts instance = RobiTts._();

  final FlutterTts _tts = FlutterTts();

  /// Ensures the (async) engine setup runs exactly once.
  Future<void>? _initFuture;

  /// Bumped by every speak()/stop(); an older in-flight speak() sees the change
  /// and bows out, so only the newest message is spoken to completion.
  int _gen = 0;

  /// Initialise the engine early (call at app start) so the first "Yes?" is not
  /// delayed by TextToSpeech start-up.
  Future<void> warmUp() => _init();

  Future<void> _init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      // awaitSpeakCompletion(true) is deliberately OFF.
      //
      // With it on, speak() only resolves when the engine fires its completion
      // callback — and on the TECNO LE6 that callback never arrives. Measured:
      //   RobiTts: speak failed — TimeoutException after 0:00:15.000000
      //   RobiTts: speak failed — TimeoutException after 0:00:04.620000
      // i.e. Robi never said "Yes?" and never read a result back. Nothing needs
      // the completion any more: the wake cue is spoken concurrently with the
      // microphone opening, so "say it, THEN listen" is no longer the design.
      await _tts.awaitSpeakCompletion(false);
      // Prefer en-US; if the engine has no en-US data, keep the device default
      // rather than going silent.
      final ok = await _tts.setLanguage('en-US');
      if (ok != 1) {
        debugPrint('RobiTts: en-US unavailable — using the device default voice');
      }
      // 0.5 was painfully slow: "Yes?" took over a second, so the cue was still
      // playing when the microphone opened and it got transcribed as the command.
      // QUEUE_FLUSH (0) makes every speak() cancel the previous utterance
      // atomically. Calling stop() right before speak() instead — the previous
      // implementation — dropped the new utterance on Android: measured, the
      // "Yes?" cue produced NO AudioPlaybackConfiguration at all and the user
      // heard nothing, so they never knew when to speak.
      await _tts.setQueueMode(0);
      // 0.5 read as painfully slow, 0.75 as rushed, 0.6 still a touch fast — the
      // user asked for "a little bit" slower, so 0.55 splits the difference.
      await _tts.setSpeechRate(0.55);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
    } catch (e) {
      // No TTS engine / unsupported language: stay silent, never throw.
      debugPrint('RobiTts: init failed — $e');
    }
  }

  /// Speak [text] and complete when it finishes (or on timeout). Never throws.
  Future<void> speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;

    final myGen = ++_gen;
    try {
      await _init();
      // A newer message arrived while we were initialising — let it win.
      if (myGen != _gen) return;

      // No stop() here — QUEUE_FLUSH in _doInit already supersedes the previous
      // utterance. stop()+speak() in one tick is what silenced the cue.

      // Length-aware safety timeout: a long result must not be cut at a fixed
      // 5 s, but a stuck engine must not block the caller forever.
      final ms = (3000 + t.length * 60).clamp(3000, 15000).toInt();
      // Logged so "the user heard nothing" is diagnosable: no line here means the
      // call never ran, a line with no audio means the engine dropped it.
      debugPrint('RobiTts: speak "$t"');
      await _tts.speak(t).timeout(Duration(milliseconds: ms));
    } catch (e) {
      debugPrint('RobiTts: speak failed — $e');
    }
  }

  /// Stop speaking and cancel any in-flight utterance.
  Future<void> stop() async {
    _gen++;
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing playing / engine gone.
    }
  }
}
