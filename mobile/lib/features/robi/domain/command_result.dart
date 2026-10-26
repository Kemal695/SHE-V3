// =============================================================================
// SHE V3 — Structured command result (Plan §4.1)
// =============================================================================
// Distinguishes "command accepted", "command sent", and "device state
// confirmed" so the UI and diagnostics never collapse the three (spec §11.7).
// =============================================================================

import 'voice_command.dart';

/// Where a command is in its lifecycle.
enum CommandStatus {
  /// Parsed and understood, but not yet dispatched.
  accepted,

  /// Dispatched to an existing SHE service (online request sent).
  sent,

  /// Could not dispatch now; placed on the offline queue.
  queued,

  /// Device-state evidence (or the /she/info echo) confirms the physical change.
  confirmed,

  /// Policy or parser refused to act.
  rejected,

  /// The user cancelled before execution.
  cancelled,
}

/// The outcome of executing a [VoiceIntent].
class CommandResult {
  final CommandStatus status;
  final VoiceIntent intent;
  final String message;

  /// The transaction id that authorised this execution, when available.
  final String? transactionId;

  const CommandResult({
    required this.status,
    required this.intent,
    required this.message,
    this.transactionId,
  });
}
