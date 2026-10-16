// =============================================================================
// SHE V3 — Which home should the app act on?
// =============================================================================
// 🔴 WHY THIS EXISTS (root cause, 2026-10-11)
//
// Every screen used to resolve the home with `listHomes().first`. A tenant
// ACCUMULATES homes — this dev tenant has 32, all named "My Home" (one per test
// provisioning run) — so `first` is effectively ARBITRARY. Whichever one it
// landed on:
//   * the Devices tab showed "No devices found", and
//   * the Automations tab showed "0/0 enabled · No automations yet",
// even though the real home has 24 devices and 5 automations. It also looked
// intermittent, because the ordering could differ between launches.
//
// Resolution order:
//   1. the last home that WORKED (cached in Hive), if it is still in the list;
//   2. otherwise the first home that actually HAS nodes;
//   3. otherwise the first home.
// The winner is cached, so later launches are instant and stable.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../features/device_detail/node_service.dart';
import '../offline/device_snapshot.dart' show deviceSnapshotBox;

/// Hive key holding the home id that last resolved successfully.
const String activeHomeIdKey = 'active_home_id';

/// The home the app should act on, or null when the list is empty/unreachable.
///
/// Takes a [WidgetRef] because every caller is a ConsumerState; pass [force] to
/// re-probe even when a cached id exists.
Future<String?> resolveActiveHomeId(WidgetRef ref, {bool force = false}) async {
  Box? box;
  try {
    box = Hive.box(deviceSnapshotBox);
  } catch (_) {
    box = null; // box not open (should not happen) — fall through to probing
  }
  final cached = box?.get(activeHomeIdKey)?.toString();

  List<Map<String, dynamic>> homes;
  try {
    homes = await ref.read(nodeServiceProvider).listHomes();
  } catch (_) {
    return (cached != null && cached.isNotEmpty) ? cached : null;
  }
  if (homes.isEmpty) return null;

  String? idOf(Map<String, dynamic> h) {
    final v = (h['id'] ?? h['home_id'])?.toString();
    return (v == null || v.isEmpty) ? null : v;
  }

  // 1. The home that worked last time, if it still exists.
  if (!force && cached != null && cached.isNotEmpty) {
    for (final h in homes) {
      if (idOf(h) == cached) return cached;
    }
  }

  // 2. The first home that actually has nodes. This is the step that matters:
  //    the other 31 homes are empty husks from earlier provisioning runs.
  final service = ref.read(nodeServiceProvider);
  for (final h in homes) {
    final id = idOf(h);
    if (id == null) continue;
    try {
      final nodes = await service.listNodesByHome(id);
      if (nodes.isNotEmpty) {
        await box?.put(activeHomeIdKey, id);
        return id;
      }
    } catch (_) {
      // Unreachable home — try the next.
    }
  }

  // 3. Nothing has nodes: fall back to the first so the UI still renders.
  final first = idOf(homes.first);
  if (first != null) await box?.put(activeHomeIdKey, first);
  return first;
}
