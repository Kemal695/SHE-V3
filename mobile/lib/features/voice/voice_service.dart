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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/network/dio_client.dart';
import '../device_detail/device_detail_screen.dart' show nodeDeviceParamsProvider;
import '../device_detail/node_service.dart';
import '../scenes/scene_service.dart';
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
final voiceAvailabilityProvider = FutureProvider<VoiceAvailability>((ref) async {
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

  Future<void> startListening({
    required void Function(String transcript, bool isFinal) onResult,
    required void Function() onDone,
  }) async {
    await _speech.listen(
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
        localeId: _localeId,
        listenFor: const Duration(seconds: 12),
        // Stop after 3 s of silence so a finished sentence does not hold the
        // mic open until listenFor expires.
        pauseFor: const Duration(seconds: 3),
        // Partial results let the user watch the words land as they speak,
        // which is what makes a misheard command obvious immediately.
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
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
    final nodeService = ref.read(nodeServiceProvider);
    final nodes = await nodeService.listNodesByHome(homeId);

    final devices = <VoiceDevice>[];
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
          displayName: (display != null && display.trim().isNotEmpty) ? display : null,
        ));
      }
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
        await nodeService.writeParams(device.nodeId, device.deviceId, {'Power': on});
        // Keep every surface consistent with the write, exactly as the manual
        // toggle does — otherwise the card still shows the old state.
        ref.invalidate(nodeDeviceParamsProvider('${device.nodeId}|${device.deviceId}'));
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
