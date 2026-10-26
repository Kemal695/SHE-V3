// =============================================================================
// SHE V3 — Custom voice command store (Hive-backed)
// =============================================================================
// Persists the user's own commands in Hive. Follows the same shape as
// CommandQueue: a Notifier that reads on build and writes on every change, with
// the payload stored as a JSON string so schema drift is caught by the try/catch
// rather than crashing the app.
// =============================================================================

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../domain/custom_voice_command.dart';

const String customCommandsBox = 'custom_commands';

final customCommandsProvider =
    NotifierProvider<CustomCommandsNotifier, List<CustomVoiceCommand>>(
  CustomCommandsNotifier.new,
);

class CustomCommandsNotifier extends Notifier<List<CustomVoiceCommand>> {
  static const _key = 'commands';

  @override
  List<CustomVoiceCommand> build() => _read();

  List<CustomVoiceCommand> _read() {
    try {
      final raw = Hive.box(customCommandsBox).get(_key);
      if (raw is String && raw.isNotEmpty) {
        return (jsonDecode(raw) as List<dynamic>)
            .map((e) => CustomVoiceCommand.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // Corrupt/absent store is not fatal — start empty.
    }
    return const [];
  }

  void _persist() {
    try {
      Hive.box(customCommandsBox)
          .put(_key, jsonEncode(state.map((c) => c.toJson()).toList()));
    } catch (_) {
      // A failed write must not take the UI down; the in-memory state stands.
    }
  }

  void add(CustomVoiceCommand command) {
    state = [...state, command];
    _persist();
  }

  void update(CustomVoiceCommand command) {
    state = [for (final c in state) c.id == command.id ? command : c];
    _persist();
  }

  void remove(String id) {
    state = [for (final c in state) if (c.id != id) c];
    _persist();
  }
}
