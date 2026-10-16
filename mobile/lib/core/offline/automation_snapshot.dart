// =============================================================================
// SHE V3 — Cached automation snapshot
// =============================================================================
// The Automations tab had NO offline cache: with the cloud down it showed a bare
// "Could not load automations" error — and, worse, that error branch replaced the
// WHOLE body including the "Create Automation" pill, so there was no way to
// create anything at all. That is what made "I can't save an automation" happen
// even though the device-local schedule support was already in place.
//
// Works on raw JSON maps so this module has no dependency on the Automation
// model (which would make automation_service <-> this file a cycle).
// =============================================================================

import 'package:hive/hive.dart';

const String automationSnapshotBox = 'she_cache';

/// Last NON-EMPTY snapshot, from whichever home it came from.
const String automationSnapshotLatestKey = 'automations_latest';

String automationSnapshotKey(String homeId) => 'automations_$homeId';

/// Cached automations for [homeId], falling back to the last snapshot from any
/// home. Null when nothing has been cached yet.
List<Map<String, dynamic>>? readAutomationSnapshot(String homeId) {
  final box = Hive.box(automationSnapshotBox);
  for (final key in [automationSnapshotKey(homeId), automationSnapshotLatestKey]) {
    final cached = box.get(key);
    if (cached is List && cached.isNotEmpty) {
      final out = <Map<String, dynamic>>[];
      for (final j in cached) {
        if (j is Map) out.add(j.cast<String, dynamic>());
      }
      if (out.isNotEmpty) return out;
    }
  }
  return null;
}

/// Persist a snapshot under both keys. Ignores an empty list so a failed or empty
/// fetch can never wipe the last good one.
Future<void> writeAutomationSnapshot(
  String homeId,
  List<Map<String, dynamic>> rows,
) async {
  if (rows.isEmpty) return;
  final box = Hive.box(automationSnapshotBox);
  await box.put(automationSnapshotKey(homeId), rows);
  await box.put(automationSnapshotLatestKey, rows);
}
