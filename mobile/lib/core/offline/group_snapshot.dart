// =============================================================================
// SHE V3 — Cached device-group snapshot
// =============================================================================
// Voice commands for user-defined groups ("turn on the living room") load the
// group list per utterance. Offline that fetch fails, so the command was
// impossible. This caches the list in Hive (`she_cache`) exactly like the device
// and automation snapshots, so group commands survive an outage.
//
// Works on raw JSON maps so this module has no dependency on the voice models.
// =============================================================================

import 'package:hive/hive.dart';

const String groupSnapshotBox = 'she_cache';

/// Last NON-EMPTY snapshot, from whichever home it came from.
const String groupSnapshotLatestKey = 'device_groups_latest';

String groupSnapshotKey(String homeId) => 'device_groups_$homeId';

/// Cached groups for [homeId], falling back to the last snapshot from any home.
List<Map<String, dynamic>>? readGroupSnapshot(String homeId) {
  final box = Hive.box(groupSnapshotBox);
  for (final key in [groupSnapshotKey(homeId), groupSnapshotLatestKey]) {
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

/// Persist a snapshot under both keys. Ignores an empty list so a failed or
/// empty fetch can never wipe the last good one.
Future<void> writeGroupSnapshot(
  String homeId,
  List<Map<String, dynamic>> rows,
) async {
  if (rows.isEmpty) return;
  final box = Hive.box(groupSnapshotBox);
  await box.put(groupSnapshotKey(homeId), rows);
  await box.put(groupSnapshotLatestKey, rows);
}
