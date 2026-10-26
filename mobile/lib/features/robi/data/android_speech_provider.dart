// =============================================================================
// SHE V3 — Android speech recognition provider (Phase 3, Plan §D.8)
// =============================================================================
// The default implementation of [SpeechRecognitionProvider]. Wraps the
// speech_to_text plugin exactly as VoiceService did before Phase 3 — same
// microphone-permission flow, same locale selection (including the speculative
// am-ET request), same listen timing and same am-ET→English fallback. Extracted
// so the recognizer is swappable without touching the voice service.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../core/storage/secure_storage.dart';
import 'speech_recognition_provider.dart';
import 'voice_diagnostics.dart';

class AndroidSpeechProvider implements SpeechRecognitionProvider {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;

  String _localeId = 'en-US';
  bool _amharic = false;

  /// True when we asked for am-ET speculatively (the phone did not list it) and
  /// the recognizer may still reject it at listen time.
  bool _forcedAmharic = false;

  @override
  bool get isAmharic => _amharic;

  @override
  bool get isListening => _speech.isListening;

  /// The locale the current session is listening in.
  String get localeId => _localeId;

  /// The onDone of the session in progress, so a recognizer ERROR or a status
  /// change can end it.
  ///
  /// speech_to_text reports errors only through `initialize(onError:)` and ends
  /// sessions through `initialize(onStatus:)` — there is no per-session error
  /// callback. Both were `(_) {}`, so an error killed the session silently: the
  /// log showed "headless: listening" and then nothing at all — no result, no
  /// "didn't hear anything", no watchdog. Measured on the LE6 at 11:45: the
  /// recognizer held the mic for 3.8 s, stopped, and the app was never told.
  void Function()? _sessionDone;
  bool _sessionEnded = true;

  void _endSession(String why) {
    if (_sessionEnded) return;
    _sessionEnded = true;
    VoiceLog.log('recognizer ended: $why');
    final done = _sessionDone;
    _sessionDone = null;
    done?.call();
  }

  @override
  Future<bool> init() async {
    if (_initialized) return true;
    _initialized = await _speech.initialize(
      onError: (e) => _endSession('error ${e.errorMsg}'),
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') _endSession('status "$s"');
      },
    );
    return _initialized;
  }

  @override
  Future<List<SpeechLocale>> locales() async {
    await init();
    final list = await _speech.locales();
    return list.map((l) => SpeechLocale(l.localeId)).toList();
  }

  @override
  Future<VoiceAvailability> probe({bool? wantsAmharic}) async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        return const VoiceAvailability.unavailable(
          'Microphone permission denied. Enable it in Settings to use voice.',
        );
      }

      if (!await init()) {
        return const VoiceAvailability.unavailable(
          'No speech recognizer on this device. Install Google app / '
          'Speech Services and try again.',
        );
      }

      final locales = await _speech.locales();
      debugPrint('Voice: recognizer locales = '
          '${locales.map((l) => l.localeId).toList()}');

      // Resolve the language FIRST: explicit call > user's voice-language
      // setting > UI locale. This is what lets someone read Amharic but speak
      // English (the "Robi does not understand my language" case), and it also
      // makes an explicit English choice win even when the phone lists Amharic.
      final savedLocale = await SecureStorage.getLocale();
      final voicePref = await SecureStorage.getVoiceLocale();
      final bool wantAmharic;
      if (wantsAmharic != null) {
        wantAmharic = wantsAmharic;
      } else if (voicePref == 'en') {
        wantAmharic = false;
      } else if (voicePref == 'am') {
        wantAmharic = true;
      } else {
        wantAmharic = savedLocale == null || savedLocale == 'am';
      }

      final hasAmharic = locales.any(
        (l) => l.localeId.toLowerCase().startsWith('am'),
      );

      if (wantAmharic) {
        if (hasAmharic) {
          _localeId = locales
              .firstWhere((l) => l.localeId.toLowerCase().startsWith('am'))
              .localeId;
          _amharic = true;
          return VoiceAvailability(
            available: true,
            // We do not force on-device recognition (SpeechListenOptions.onDevice
            // is left false), so recognition may use the network. Reporting
            // `true` here would claim an offline capability we did not request.
            onDevice: false,
            localeId: _localeId,
            amharic: true,
          );
        }
        // The phone does not LIST an Amharic locale. That list reflects installed
        // language packs, not what the recognizer can accept — Google's cloud
        // recognizer frequently handles am-ET without advertising it. Ask for
        // am-ET anyway rather than quietly switching to English.
        _localeId = 'am-ET';
        _amharic = true;
        _forcedAmharic = true;
        return VoiceAvailability(
          available: true,
          onDevice: false,
          localeId: _localeId,
          amharic: true,
          amharicUnsupported: true,
          reason: 'This phone does not list Amharic, so Robi is asking for '
              'am-ET anyway. If nothing is understood, install an Amharic '
              'speech pack or choose English under Voice language.',
        );
      }

      // English — chosen explicitly, or the UI is English, or Amharic is not
      // available. Only report `amharicUnsupported` when the user did not
      // deliberately choose English.
      final english = locales.where(
        (l) => l.localeId.toLowerCase().startsWith('en'),
      );
      _localeId = english.isNotEmpty
          ? english.first.localeId
          : (locales.isNotEmpty ? locales.first.localeId : 'en-US');
      _amharic = false;
      final chosenEnglish = voicePref == 'en';
      return VoiceAvailability(
        available: true,
        onDevice: false,
        localeId: _localeId,
        amharic: false,
        amharicUnsupported: !hasAmharic && !chosenEnglish,
        reason: chosenEnglish || hasAmharic
            ? null
            : 'Amharic speech recognition is not available on this phone; '
                'listening in English instead.',
      );
    } catch (e) {
      return VoiceAvailability.unavailable('Voice unavailable: $e');
    }
  }

  @override
  Future<void> listen({
    required void Function(
      String transcript,
      bool isFinal,
      List<String> hypotheses,
    ) onResult,
    required void Function() onDone,
    bool pushToTalk = false,
    bool fromWake = false,
  }) async {
    Future<void> listenIn(String locale) => _speech.listen(
          onResult: (SpeechRecognitionResult r) {
            // Every hypothesis Android offers, best first. The caller parses
            // them all and runs the one that makes sense: the top hypothesis is
            // often mangled ("turn on second one socket sock") while a
            // lower-ranked one names real devices ("turn on socket one socket
            // to sock").
            final alts = <String>[
              for (final a in r.alternates)
                if (a.recognizedWords.trim().isNotEmpty) a.recognizedWords,
            ];
            final best = alts.isNotEmpty ? alts.first : r.recognizedWords;
            if (r.finalResult) {
              VoiceLog.log('alternates=$alts');
            }
            onResult(best, r.finalResult, alts.isEmpty ? [best] : alts);
          },
          onSoundLevelChange: null,
          // localeId / listenFor / pauseFor / partialResults / cancelOnError all
          // live on SpeechListenOptions in speech_to_text 7.x — passing them as
          // top-level args is deprecated and warns on every build.
          listenOptions: SpeechListenOptions(
            localeId: locale,
            // Hard caps. Kept tight on purpose: with background noise the
            // recognizer never sees "silence", so only listenFor ends the
            // session — and a 15 s cap reads as Robi hanging on "Listening…".
            listenFor: Duration(
              seconds: pushToTalk ? 30 : 10,
            ),
            // Stop after a silence so a finished sentence does not hold the mic
            // open until listenFor expires — but NOT while a push-to-talk button
            // is still held. Wake sessions get a little more room because the
            // user has just unlocked the phone and needs a moment to start.
            // 4 s after a wake word was too short: the user hears "Yes?", then
            // composes the sentence, and the session ended before they spoke
            // (measured: three attempts in a row with "no speech").
            pauseFor: Duration(
              milliseconds: pushToTalk ? 30000 : (fromWake ? 8000 : 2500),
            ),
            partialResults: true,
            cancelOnError: true,
            // confirmation, NOT dictation. In dictation mode this device ignores
            // listenFor/pauseFor entirely — measured on a TECNO LE6, sessions ran
            // 17 minutes against a 10 s cap and never released the mic, which is
            // the "Robi is stuck on Listening…" bug. `confirmation` is the mode
            // for short commands and honours both timeouts.
            listenMode: ListenMode.confirmation,
          ),
        );

    try {
      // Remember the session's done callback BEFORE starting, so an error that
      // arrives immediately still ends the session instead of hanging.
      _sessionDone = onDone;
      _sessionEnded = false;
      await listenIn(_localeId);
    } catch (e) {
      // We asked for am-ET speculatively (the phone never listed it). If the
      // recognizer refuses it, fall back to English rather than leaving the
      // microphone dead — and say so in the log so this is diagnosable.
      if (!_forcedAmharic) rethrow;
      debugPrint('Voice: am-ET rejected ($e) — falling back to English');
      _localeId = 'en-US';
      _amharic = false;
      _forcedAmharic = false;
      await listenIn(_localeId);
    }
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
