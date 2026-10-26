// =============================================================================
// SHE V3 — Speech recognition with DOMAIN BIASING
// =============================================================================
// Why this exists, in one paragraph: the assistant's vocabulary is tiny and
// fixed — "socket one".."socket eight", "light one".."light sixteen", "turn
// on/off" — but a general recogniser has no reason to prefer those words. On the
// TECNO LE6 the sentence "turn on socket 1 socket 2 and light 1" came back as
//
//     "turn on socket one it's okay to in the light one"
//
// because Google's language model replaced the uncommon phrase with ordinary
// English. Android 13+ exposes `EXTRA_BIASING_STRINGS` for exactly this, and it
// is how Amazon/Google make device names and skill vocabularies recognisable.
// The speech_to_text plugin does not expose it, so the app calls the platform
// recogniser itself (see RobiSpeech.kt) and this file is the Dart half.
//
// Everything else — parsing, safety, execution — is unchanged: this provider
// only produces a transcript plus the full hypothesis list, exactly like the
// plugin-backed provider it replaces.
// =============================================================================

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/storage/secure_storage.dart';
import 'android_speech_provider.dart';
import 'speech_recognition_provider.dart';
import 'voice_diagnostics.dart';

/// Number words the recogniser must be able to produce for a device name.
const List<String> _numberWords = [
  'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen',
];

/// Phrases the recogniser is told to favour.
///
/// Built from the firmware's own channel names (device_profiles.c: channels 0-7
/// Light 1-8, 8-15 Socket 1-8, 16-23 Light 9-16) so it needs no runtime data.
/// Renamed devices can be added with [addBiasPhrases].
List<String> biasPhrases() => [
      for (final n in _numberWords) 'socket $n',
      for (final n in _numberWords) 'light $n',
      'turn on',
      'turn off',
      'switch on',
      'switch off',
      'all lights',
      'all sockets',
      ..._extra,
    ];

final Set<String> _extra = <String>{};

/// Add user-defined names (renamed devices, groups) to the bias list.
///
/// Called from the command context loader, which is the only place that knows
/// what the user called their devices ("bedroom light", "Tv soket").
void addBiasPhrases(Iterable<String> names) {
  for (final n in names) {
    final t = n.trim();
    if (t.length >= 3 && t.length <= 40) _extra.add(t);
  }
}

/// Recognition through the app's own platform recogniser, with biasing.
///
/// Falls back to [AndroidSpeechProvider] (the speech_to_text plugin) when the
/// platform channel is missing — an old APK, or a device that reports no
/// recogniser. Voice must never be dead because of a wiring problem.
class NativeSpeechProvider implements SpeechRecognitionProvider {
  NativeSpeechProvider({AndroidSpeechProvider? fallback})
      : _fallback = fallback ?? AndroidSpeechProvider();

  static const MethodChannel _channel = MethodChannel('she/robi/speech');

  final AndroidSpeechProvider _fallback;

  String _localeId = 'en-US';
  bool _amharic = false;
  bool _listening = false;
  bool _available = false;
  bool _usingFallback = false;

  void Function(String transcript, bool isFinal, List<String> hypotheses)?
      _onResult;
  void Function()? _onDone;
  bool _doneFired = false;

  bool get usingFallback => _usingFallback;

  @override
  bool get isListening => _usingFallback ? _fallback.isListening : _listening;

  @override
  bool get isAmharic => _usingFallback ? _fallback.isAmharic : _amharic;

  @override
  Future<bool> init() async {
    if (_available) return true;
    try {
      _available = await _channel.invokeMethod<bool>('available') ?? false;
    } catch (e) {
      VoiceLog.log('native speech: channel unavailable — $e');
      _available = false;
    }
    if (!_available) {
      _usingFallback = true;
      return _fallback.init();
    }
    _channel.setMethodCallHandler(_handleEvent);
    return true;
  }

  @override
  Future<List<SpeechLocale>> locales() async {
    if (_usingFallback) return _fallback.locales();
    return const [SpeechLocale('en-US'), SpeechLocale('am-ET')];
  }

  @override
  Future<VoiceAvailability> probe({bool? wantsAmharic}) async {
    if (!await init()) return _fallback.probe(wantsAmharic: wantsAmharic);
    if (_usingFallback) return _fallback.probe(wantsAmharic: wantsAmharic);

    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        return const VoiceAvailability.unavailable(
          'Microphone permission denied. Enable it in Settings to use voice.',
        );
      }
    } catch (_) {
      // Permission plugin unavailable — the recogniser will report it instead.
    }

    // Same precedence as before: explicit call > user's voice-language setting >
    // the app's UI language. Someone may read Amharic but speak English.
    final pref = wantsAmharic == null
        ? await SecureStorage.getVoiceLocale()
        : (wantsAmharic ? 'am' : 'en');
    final wants = pref == 'am';
    _localeId = wants ? 'am-ET' : 'en-US';
    _amharic = wants;
    VoiceLog.log('native speech: locale=$_localeId (pref=$pref)');
    return VoiceAvailability(
      available: true,
      // Recognition may use the network; we never force offline.
      onDevice: false,
      localeId: _localeId,
      amharic: wants,
      amharicUnsupported: false,
      reason: null,
    );
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
    if (_usingFallback) {
      return _fallback.listen(
        onResult: onResult,
        onDone: onDone,
        pushToTalk: pushToTalk,
        fromWake: fromWake,
      );
    }

    _onResult = onResult;
    _onDone = onDone;
    _doneFired = false;
    _listening = true;

    // Silence that ends an utterance once the user has spoken. This is the
    // engine's own endpointing (`EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS`),
    // which — unlike the plugin's pauseFor — is actually honoured here.
    final silenceMs = pushToTalk ? 3000 : (fromWake ? 4000 : 2500);
    try {
      await _channel.invokeMethod('start', {
        'locale': _localeId,
        'phrases': biasPhrases(),
        'silenceMs': silenceMs,
      });
      VoiceLog.log('native speech: listening ($_localeId, '
          '${biasPhrases().length} bias phrases)');
    } catch (e) {
      VoiceLog.log('native speech: start failed — $e');
      _fireDone();
    }
  }

  @override
  Future<void> stop() async {
    if (_usingFallback) return _fallback.stop();
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    if (_usingFallback) return _fallback.cancel();
    _listening = false;
    _onResult = null;
    _onDone = null;
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  Future<dynamic> _handleEvent(MethodCall call) async {
    if (call.method != 'event') return null;
    final args = (call.arguments as Map?)?.cast<String, dynamic>();
    if (args == null) return null;

    switch (args['event'] as String?) {
      case 'partial':
        final text = (args['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) return null;
        _onResult?.call(text, false, [text]);
        break;

      case 'final':
        final list = ((args['hypotheses'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (list.isEmpty) return null;
        _listening = false;
        _onResult?.call(list.first, true, list);
        break;

      case 'error':
        VoiceLog.log('native speech: error ${args['message']} (${args['code']})');
        _listening = false;
        _fireDone();
        break;

      case 'done':
        _listening = false;
        _fireDone();
        break;
    }
    return null;
  }

  void _fireDone() {
    if (_doneFired) return;
    _doneFired = true;
    final done = _onDone;
    _onDone = null;
    done?.call();
  }
}
