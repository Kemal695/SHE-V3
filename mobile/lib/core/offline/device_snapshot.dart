// =============================================================================
// SHE V3 — Cached device snapshot
// =============================================================================
// The Devices tab snapshots its resolved rows into Hive (`she_cache`) so the tab
// survives an outage. Other screens need the SAME list — the automation wizard's
// device picker in particular: without it the picker is EMPTY offline, so
// "create an automation while offline" is impossible no matter how good the
// device-local schedule support is.
//
// The key names live here so the writer (devices_screen) and the readers
// (scene_service, the offline automation service) cannot drift apart.
// =============================================================================

import 'package:hive/hive.dart';

/// Box that holds the snapshot. Opened in main().
const String deviceSnapshotBox = 'she_cache';

/// The last NON-EMPTY snapshot, from whichever home it came from. Used when the
/// per-home key misses — e.g. while the real home id is still being resolved and
/// the placeholder id (which IS the tenant id) returns an empty home.
const String deviceSnapshotLatestKey = 'devices_flat_latest';

String deviceSnapshotKey(String homeId) => 'devices_flat_$homeId';

/// The cached rows for [homeId], falling back to the last snapshot from any home.
/// Null when nothing has been cached yet.
///
/// Each row is the Devices-tab `_DeviceRow.toJson()` shape:
/// `{nodeId, deviceId, name, kind, isOnline, isOn, raw}` — where `raw` is the
/// server's device map (so `device_name`, `device_type`, `display_name` are all
/// available).
List<Map<String, dynamic>>? readDeviceSnapshot(String homeId) {
  final box = Hive.box(deviceSnapshotBox);
  for (final key in [deviceSnapshotKey(homeId), deviceSnapshotLatestKey]) {
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

/// Persist a snapshot under both keys.
///
/// Deliberately ignores an empty list: an empty result (unresolved home id, or a
/// genuinely empty home) must never wipe the last good snapshot.
Future<void> writeDeviceSnapshot(
  String homeId,
  List<Map<String, dynamic>> rows,
) async {
  if (rows.isEmpty) return;
  final box = Hive.box(deviceSnapshotBox);
  await box.put(deviceSnapshotKey(homeId), rows);
  await box.put(deviceSnapshotLatestKey, rows);
}
