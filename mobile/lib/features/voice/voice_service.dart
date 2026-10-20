// =============================================================================
// SHE V3 — Voice control service (phone-side)
// =============================================================================
// Owns the speech recognizer and executes parsed intents against the SAME REST
// API the rest of the app uses. Nothing here is voice-specific on the backend:
// a spoken "turn off light 1" ends up as the identical PUT that a tap sends.
//
// Why phone-side rather than the firmware Picovoice path (Phase 4C, R16-only):
//   - works on every SKU, including the R24 bench board (no mic on the board)
//   - no Picovoice access key, no trained wake-word model, no SDK to vendor
//   - reuses the existing device/scene endpoints, so nothing new to secure
// The tradeoff, stated plainly: it needs the phone and an internet-backed
// recognizer rather than being truly offline on the device.
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/network/ws_client.dart' show wsConnectedProvider;
import '../../core/offline/command_queue.dart';
import '../../core/offline/device_snapshot.dart';
import '../../core/storage/secure_storage.dart';
import '../device_detail/device_detail_screen.dart' show nodeDeviceParamsProvider;
import '../device_detail/node_service.dart';
import '../scenes/scene_service.dart';
import 'nlu/amharic_normalizer.dart';
import 'nlu/command_nlu.dart';
import 'nlu/control_intents.dart';
import 'nlu/safety_policy.dart';
import 'nlu/voice_session.dart';
import 'voice_intent.dart';

/// Where the voice interaction currently is. Drives the UI honestly: the mic
/// only pulses while we are genuinely capturing audio.
enum VoicePhase {
  /// No recognizer yet — the screen is deciding whether it can listen at all.
  initializing,

  idle,
  listening,

  /// Heard something; resolving and calling the API.
  executing,
  done,

  /// Something failed and the screen needs to say so.
  error,

  /// No usable recognizer (or permission refused) — explain, don't pretend.
  unavailable,
}

class VoiceState {
  final VoicePhase phase;
  final String? transcript;
  final VoiceIntent? intent;
  final String? message;
  final bool onDevice;

  const VoiceState({
    this.phase = VoicePhase.initializing,
    this.transcript,
    this.intent,
    this.message,
    this.onDevice = false,
  });

  VoiceState copyWith({
    VoicePhase? phase,
    String? transcript,
    VoiceIntent? intent,
    String? message,
    bool? onDevice,
    bool clearTranscript = false,
    bool clearIntent = false,
    bool clearMessage = false,
  }) =>
      VoiceState(
        phase: phase ?? this.phase,
        transcript: clearTranscript ? null : (transcript ?? this.transcript),
        intent: clearIntent ? null : (intent ?? this.intent),
        message: clearMessage ? null : (message ?? this.message),
        onDevice: onDevice ?? this.onDevice,
      );
}

final voiceServiceProvider = Provider<VoiceService>((ref) => VoiceService(ref));

/// Whether the phone's recognizer can be used at all. Resolved once per screen
/// open so the UI can show a truthful message instead of a dead mic.
///
/// autoDispose: the answer depends on the app's language (Amharic requests
/// `am-ET` even when it is not listed), so switching language in Settings must
/// re-probe instead of reusing the previous result for the whole app lifetime.
final voiceAvailabilityProvider =
    FutureProvider.autoDispose<VoiceAvailability>((ref) async {
  final service = ref.read(voiceServiceProvider);
  return service.probe();
});

class VoiceAvailability {
  final bool available;
  final bool onDevice;
  final String? reason;

  /// Locale we will ask for, and whether it is Amharic. Both are decided at
  /// probe time because locale support is a device capability, not a constant.
  final String localeId;
  final bool amharic;

  /// True when the app wants Ethiopic but the device can only do Latin. The UI
  /// surfaces this because it changes what the user should say.
  final bool amharicUnsupported;

  const VoiceAvailability({
    required this.available,
    required this.onDevice,
    required this.localeId,
    required this.amharic,
    this.amharicUnsupported = false,
    this.reason,
  });

  const VoiceAvailability.unavailable(this.reason)
      : available = false,
        onDevice = false,
        localeId = 'en-US',
        amharic = false,
        amharicUnsupported = false;
}

class VoiceService {
  final Ref ref;
  VoiceService(this.ref);

  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;

  /// The locale the current session is listening in. Determines whether the
  /// transcript may be expected in Ethiopic or Latin script.
  String _localeId = 'en-US';
  bool _amharic = false;

  /// True when the app asked for Amharic but the phone did not list it, so we
  /// requested `am-ET` speculatively. If the recognizer rejects it, the session
  /// falls back to English instead of leaving the mic dead.
  bool _forcedAmharic = false;

  SpeechToText get recognizer => _speech;

  // ---- Capability probe --------------------------------------------------

  /// Decide whether we can listen, and in which language.
  ///
  /// Amharic is the app's default locale, so we ask for `am-ET` first. Android
  /// exposes no `am` locale *code*, so this often fails — in which case we fall
  /// back to English rather than leaving the feature dead, and report
  /// [VoiceAvailability.amharicUnsupported] so the UI can say so.
  Future<VoiceAvailability> probe() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        return const VoiceAvailability.unavailable(
          'Microphone permission denied. Enable it in Settings to use voice.',
        );
      }

      if (!_initialized) {
        _initialized = await _speech.initialize(
          onError: (_) {},
          onStatus: (status) {
            // 'done'/'notListening' are handled by the screen's own listeners;
            // nothing to do globally.
          },
        );
      }
      if (!_initialized) {
        return const VoiceAvailability.unavailable(
          'No speech recognizer on this device. Install Google app / '
          'Speech Services and try again.',
        );
      }

      final locales = await _speech.locales();
      debugPrint('Voice: recognizer locales = '
          '${locales.map((l) => l.localeId).toList()}');

      final hasAmharic = locales.any(
        (l) => l.localeId.toLowerCase().startsWith('am'),
      );

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
      // recognizer frequently handles am-ET without advertising it. So when the
      // app is in Amharic, ASK FOR am-ET ANYWAY instead of quietly switching to
      // English: falling back to English guarantees the user's Amharic is heard
      // as Latin gibberish, which is the "English works but Amharic doesn't"
      // symptom. We report it as unsupported so the UI stays honest.
      // Same rule as `localeProvider`: no saved choice means Amharic (the app
      // ships Amharic-first). Read from storage rather than the provider so this
      // service does not import the router and create an import cycle.
      final savedLocale = await SecureStorage.getLocale();
      final wantsAmharic = savedLocale == null || savedLocale == 'am';
      if (wantsAmharic) {
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
              'speech pack or switch the app to English.',
        );
      }

      // No Amharic recognizer: fall back to English rather than leaving the
      // feature dead, and say so in the UI. Reported as amharicUnsupported so
      // the screen can tell the user which language to speak.
      final english = locales.where(
        (l) => l.localeId.toLowerCase().startsWith('en'),
      );
      _localeId = english.isNotEmpty
          ? english.first.localeId
          : (locales.isNotEmpty ? locales.first.localeId : 'en-US');
      _amharic = false;
      return VoiceAvailability(
        available: true,
        onDevice: false,
        localeId: _localeId,
        amharic: false,
        amharicUnsupported: true,
        reason: 'Amharic speech recognition is not available on this phone; '
            'listening in English instead.',
      );
    } catch (e) {
      return VoiceAvailability.unavailable('Voice unavailable: $e');
    }
  }

  // ---- Listening ---------------------------------------------------------

  /// [pushToTalk] changes the *stop* conditions to suit a hold-to-record button.
  ///
  /// Default (false) — "listen until the sentence finishes": stop 3 s after the
  /// user goes quiet, and hard-stop at 12 s. Right for a tap-to-start button.
  ///
  /// [pushToTalk] (true) — the RELEASE is the stop. The silence timeout is
  /// deliberately pushed out to 30 s and the cap to 30 s, because a 3 s
  /// `pauseFor` cut the recording off *while the user was still holding the
  /// button*: measured on the TECNO LE6, a 10 s hold produced
  /// `onStartListening` → `onStopListening` exactly **2.99 s** later, i.e. the
  /// user pauses to think for three seconds and the mic closes under their
  /// finger. The 30 s values are only a backstop for a button that is stuck down.
  Future<void> startListening({
    required void Function(String transcript, bool isFinal) onResult,
    required void Function() onDone,
    bool pushToTalk = false,
  }) async {
    Future<void> listenIn(String locale) => _speech.listen(
          onResult: (SpeechRecognitionResult r) {
            final best = r.alternates.isNotEmpty
                ? r.alternates.first.recognizedWords
                : r.recognizedWords;
            onResult(best, r.finalResult);
          },
          onSoundLevelChange: null,
          // localeId / listenFor / pauseFor / partialResults / cancelOnError all
          // live on SpeechListenOptions in speech_to_text 7.x — passing them as
          // top-level args is deprecated and warns on every build.
          listenOptions: SpeechListenOptions(
            localeId: locale,
            listenFor: Duration(seconds: pushToTalk ? 30 : 12),
            // Stop after 3 s of silence so a finished sentence does not hold the
            // mic open until listenFor expires — but NOT while a push-to-talk
            // button is still held (see the doc comment above).
            pauseFor: Duration(seconds: pushToTalk ? 30 : 3),
            // Partial results let the user watch the words land as they speak,
            // which is what makes a misheard command obvious immediately.
            partialResults: true,
            cancelOnError: true,
            listenMode: ListenMode.dictation,
          ),
        );

    try {
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

  Future<void> stopListening() => _speech.stop();

  Future<void> cancel() => _speech.cancel();

  bool get isListening => _speech.isListening;

  /// True when the current recognizer produces Ethiopic script.
  bool get transcriptIsAmharic => _amharic;

  // ---- Execution ---------------------------------------------------------

  /// Load the home's devices and scenes as parser inputs.
  ///
  /// Done fresh per utterance rather than cached: a device renamed in the app a
  /// moment ago must be sayable immediately, and the list is small enough
  /// (24 devices on the R24) that one round trip is not worth caching.
  Future<({List<VoiceDevice> devices, List<VoiceScene> scenes})> _loadContext(
      String homeId) async {
    // The cloud normally supplies the device list — and with it the firmware
    // name <-> id mapping that local control needs. Offline it is unreachable,
    // so fall back to the snapshot the Devices tab caches; without it voice has
    // nothing to match and every spoken command fails.
    final devices = <VoiceDevice>[];
    if (ref.read(wsConnectedProvider)) {
      try {
        final nodeService = ref.read(nodeServiceProvider);
        final nodes = await nodeService.listNodesByHome(homeId);
        for (final n in nodes) {
          final nodeId = n['id']?.toString();
          if (nodeId == null) continue;
          final list = await nodeService.listDevices(nodeId);
          for (final d in list) {
            final deviceId = d['id']?.toString();
            final name = d['device_name']?.toString();
            if (deviceId == null || name == null) continue;
            // Only switch-like devices respond to Power; a sensor would match a
            // name but have nothing to turn on.
            final type = d['device_type']?.toString() ?? '';
            if (type.isNotEmpty && type != 'esp.device.switch') continue;
            final display = d['display_name']?.toString();
            devices.add(VoiceDevice(
              nodeId: nodeId,
              deviceId: deviceId,
              deviceName: name,
              displayName:
                  (display != null && display.trim().isNotEmpty) ? display : null,
            ));
          }
        }
      } catch (_) {
        devices.addAll(_devicesFromSnapshot(homeId));
      }
    } else {
      devices.addAll(_devicesFromSnapshot(homeId));
    }

    final scenes = <VoiceScene>[];
    try {
      for (final s in await ref.read(sceneServiceProvider).listScenes(homeId)) {
        scenes.add(VoiceScene(id: s.id, name: s.name));
      }
    } catch (_) {
      // Scenes are optional; device control still works without them.
    }

    return (devices: devices, scenes: scenes);
  }

  /// Build the voice device list from the cached device snapshot — the offline
  /// substitute for the cloud listing (see core/offline/device_snapshot.dart).
  List<VoiceDevice> _devicesFromSnapshot(String homeId) {
    final out = <VoiceDevice>[];
    final rows = readDeviceSnapshot(homeId) ?? const <Map<String, dynamic>>[];
    for (final row in rows) {
      final raw = (row['raw'] as Map?)?.cast<String, dynamic>();
      final deviceId = row['deviceId']?.toString();
      final name = raw?['device_name']?.toString();
      if (deviceId == null || name == null) continue;
      final type = raw?['device_type']?.toString() ?? '';
      if (type.isNotEmpty && type != 'esp.device.switch') continue;
      final display = raw?['display_name']?.toString();
      out.add(VoiceDevice(
        nodeId: row['nodeId']?.toString() ?? '',
        deviceId: deviceId,
        deviceName: name,
        displayName:
            (display != null && display.trim().isNotEmpty) ? display : null,
      ));
    }
    return out;
  }

  /// Parse [transcript] and perform the resulting action.
  ///
  /// Returns the parsed intent so the UI can show what was understood, and a
  /// human-readable outcome message.
  Future<({VoiceIntent intent, String message})> handle(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
  }) async {
    final ctx = await _loadContext(homeId);
    final intent = parseVoiceIntent(
      transcript,
      devices: ctx.devices,
      scenes: ctx.scenes,
      latinDeviceTokens: latinDeviceTokens,
      amharic: _amharic,
    );

    final nodeService = ref.read(nodeServiceProvider);

    switch (intent.action) {
      case VoiceAction.turnOn:
      case VoiceAction.turnOff:
        final device = intent.device;
        if (device == null) {
          return (intent: intent, message: "I didn't catch which device.");
        }
        final on = intent.action == VoiceAction.turnOn;
        // Same offline-tolerant path a manual toggle uses: with no cloud link
        // this tries LOCAL control over Wi-Fi (a real switch), then queues. Voice
        // is therefore no longer the one control that dies when the internet does.
        final outcome = await ref
            .read(commandQueueProvider.notifier)
            .sendOrQueue(
              nodeId: device.nodeId,
              deviceId: device.deviceId,
              params: {'Power': on},
              label: '${device.label} · ${on ? 'On' : 'Off'}',
              deviceName: device.deviceName,
            );
        if (outcome == SendOutcome.queued) {
          return (
            intent: intent,
            message: '${on ? 'On' : 'Off'}: ${device.label} (queued)',
          );
        }
        // Keep every surface consistent with the write, exactly as the manual
        // toggle does — otherwise the card still shows the old state.
        // Skipped after a LOCAL send: the cloud is unreachable, so this refetch
        // could only fail (and would blank any screen reading it).
        if (ref.read(wsConnectedProvider)) {
          ref.invalidate(
              nodeDeviceParamsProvider('${device.nodeId}|${device.deviceId}'));
        }
        return (
          intent: intent,
          message: '${on ? 'On' : 'Off'}: ${device.label}',
        );

      case VoiceAction.turnAllOn:
      case VoiceAction.turnAllOff:
        final on = intent.action == VoiceAction.turnAllOn;
        final group = intent.group ?? 'all';
        // Resolve the node to command. group_set is a per-node command and the
        // bench has one board; with several we apply it to each board that has
        // a matching device, which is what "all the lights" means to a user.
        final nodes = <String>{};
        for (final d in ctx.devices) {
          if (_inGroup(d, group)) nodes.add(d.nodeId);
        }
        if (nodes.isEmpty) {
          return (intent: intent, message: 'No ${_label(group)} found.');
        }
        if (!ref.read(wsConnectedProvider)) {
          // Offline: there is no group endpoint to call. Command each matching
          // device through the local-first path instead, so "all the lights"
          // still works — locally if the board is on the Wi-Fi, else queued.
          var sent = 0;
          var queued = 0;
          for (final d in ctx.devices) {
            if (!_inGroup(d, group)) continue;
            final outcome = await ref
                .read(commandQueueProvider.notifier)
                .sendOrQueue(
                  nodeId: d.nodeId,
                  deviceId: d.deviceId,
                  params: {'Power': on},
                  label: '${d.label} · ${on ? 'On' : 'Off'}',
                  deviceName: d.deviceName,
                );
            if (outcome == SendOutcome.queued) {
              queued++;
            } else {
              sent++;
            }
          }
          return (
            intent: intent,
            message: '${on ? 'On' : 'Off'}: all ${_label(group)}'
                '${sent > 0 ? ' ($sent)' : ''}'
                '${queued > 0 ? ' · $queued queued' : ''}',
          );
        }
        var total = 0;
        for (final nodeId in nodes) {
          final res = await nodeService.setGroup(nodeId, group, on);
          total += (res['applied'] as int?) ?? (res['count'] as int?) ?? 0;
        }
        return (
          intent: intent,
          message:
              '${on ? 'On' : 'Off'}: all ${_label(group)}${total > 0 ? ' ($total)' : ''}',
        );

      case VoiceAction.activateScene:
        final sceneId = intent.sceneId;
        if (sceneId == null) {
          return (intent: intent, message: "I didn't catch the scene name.");
        }
        final result = await ref.read(sceneServiceProvider).activate(sceneId);
        return (
          intent: intent,
          message: result.isFullSuccess
              ? 'Scene activated (${result.acceptedCount} actions)'
              : 'Scene partly applied — ${result.failed.join(', ')}',
        );

      case VoiceAction.unknown:
        return (
          intent: intent,
          message: "I heard \"$transcript\" but didn't understand it.",
        );
    }
  }

  // =========================================================================
  // Phase 1 orchestration — NLU + safety policy + dialogue session
  // =========================================================================
  // `handle()` above stays exactly as it was: it parses and executes. This
  // layer decides WHETHER to execute, and keeps one clarification/confirmation
  // open across utterances.
  //
  // Both entry points (the FAB and the voice screen) call this method, so they
  // share one brain and one pending dialogue — which is the spec's "shared
  // command brain" requirement.

  VoiceSession? _session;

  /// The utterance a pending confirmation refers to. Re-executing the stored
  /// TEXT (not a cached parse) means the device list is re-read at execution
  /// time, so a rename in between cannot send a command to the wrong channel.
  String? _pendingTranscript;

  /// Expire a dialogue that is no longer waiting for a reply.
  ///
  /// There is no background timer: a session is checked when the next utterance
  /// arrives. That is enough because a stale prompt can only do harm if it is
  /// still open when the user speaks again.
  void _expireIfStale() {
    final s = _session;
    if (s == null) return;
    s.tick();
    if (!s.isOpen) _clearDialogue();
  }

  void _clearDialogue() {
    _session = null;
    _pendingTranscript = null;
  }

  VoiceIntent _toIntent(NluResult r) => VoiceIntent(
        action: r.action,
        device: r.device,
        group: r.group,
        sceneId: r.sceneId,
        confidence: r.confidence,
      );

  /// Interpret [transcript], decide whether it is safe to run, and either run it
  /// or ask a question.
  ///
  /// Returns the same shape as [handle] so the two call sites did not change.
  Future<({VoiceIntent intent, String message})> handleUtterance(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
  }) async {
    _expireIfStale();

    // Diagnostic: the transcript is the one thing we cannot infer from the
    // platform logs (they redact both the locale and the text). Without it,
    // "Amharic doesn't work" is indistinguishable from "the recognizer returned
    // Latin" and from "the parser did not match the words".
    debugPrint('Voice: heard "${transcript.replaceAll("\n", " ")}" '
        '(locale=$_localeId, amharic=$_amharic, forced=$_forcedAmharic)');

    // We asked for Amharic but the recognizer returned Latin — it did not hear
    // Amharic. Do not guess at a device from transliterated text (see the header
    // of voice_intent.dart); say what actually happened.
    if (_amharic &&
        transcript.trim().isNotEmpty &&
        !amharicNormalizer.containsEthiopic(transcript)) {
      return (
        intent: const VoiceIntent.unknown(),
        message: "I didn't catch that in Amharic — try again, or switch the "
            'app to English.',
      );
    }

    // ---- 1. Is this a reply to an open question? -------------------------
    final session = _session;
    final pending = _pendingTranscript;
    if (session != null && pending != null && session.isOpen) {
      final match = controlIntentClassifier.classify(
        transcript,
        expecting: session.expectation,
      );
      final step = session.onControl(
        match,
        transactionId: session.transactionId,
      );

      switch (step) {
        case SessionStep.cancelled:
          _clearDialogue();
          return (
            intent: const VoiceIntent.unknown(),
            message: 'Cancelled — nothing was changed.',
          );

        case SessionStep.execute:
          // The user said yes to the pending command.
          _clearDialogue();
          return handle(
            pending,
            homeId: homeId,
            latinDeviceTokens: latinDeviceTokens,
          );

        case SessionStep.notUnderstood:
          // Not an answer to the question that was asked. Keep it open so the
          // user can try again (the session enforces its own retry limit).
          return (
            intent: const VoiceIntent.unknown(),
            message: session.currentQuestion ?? 'Sorry, can you say that again?',
          );

        case SessionStep.interpret:
          // Either a correction ("no, the living room") or a direct answer to a
          // clarification ("the living room"). Re-interpret that text.
          final text = match.correctionText ?? transcript;
          return _decideAndAct(
            text,
            homeId: homeId,
            latinDeviceTokens: latinDeviceTokens,
          );

        default:
          break;
      }
    }

    // ---- 2. A fresh command ----------------------------------------------
    return _decideAndAct(
      transcript,
      homeId: homeId,
      latinDeviceTokens: latinDeviceTokens,
    );
  }

  Future<({VoiceIntent intent, String message})> _decideAndAct(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
  }) async {
    final ctx = await _loadContext(homeId);
    final result = commandNlu.interpret(
      transcript,
      devices: ctx.devices,
      scenes: ctx.scenes,
      latinDeviceTokens: latinDeviceTokens,
      amharic: _amharic,
    );
    final decision = commandSafetyPolicy.decide(result);

    switch (decision.decision) {
      case Decision.execute:
        _clearDialogue();
        // Delegate to the existing, tested execution path.
        return handle(
          transcript,
          homeId: homeId,
          latinDeviceTokens: latinDeviceTokens,
        );

      case Decision.clarify:
        // Two different questions, deliberately:
        //   ambiguous -> "which one?" (a yes/no cannot resolve it)
        //   uncertain -> "did you mean X?" (yes/no can)
        final session = VoiceSession(
          transactionId: 'tx-${DateTime.now().microsecondsSinceEpoch}',
        );
        session.begin();
        if (result.isAmbiguous) {
          session.askClarification(
            ClarifyField.device,
            decision.question ?? 'Which one?',
          );
        } else {
          session.askConfirmation(
            decision.question ?? 'Did you mean that?',
          );
        }
        _session = session;
        _pendingTranscript = transcript;
        return (
          intent: _toIntent(result),
          message: decision.question ?? 'Did you mean that?',
        );

      case Decision.reject:
        _clearDialogue();
        return (intent: _toIntent(result), message: decision.reason);
    }
  }

  bool _inGroup(VoiceDevice d, String group) {
    // Device classes come from the name prefix the firmware's relay map uses:
    // "Light *" is channels 0-7 + 16-23, "Socket *" is 8-15. Matching by prefix
    // keeps spoken commands aligned with the board's own masking.
    final name = d.deviceName.toLowerCase();
    return switch (group) {
      'lights' => name.startsWith('light'),
      'sockets' => name.startsWith('socket'),
      _ => name.startsWith('light') || name.startsWith('socket'),
    };
  }

  String _label(String group) => switch (group) {
        'lights' => 'lights',
        'sockets' => 'sockets',
        _ => 'devices',
      };
}
