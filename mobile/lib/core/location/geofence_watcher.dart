// =============================================================================
// SHE V3 — Mounts the foreground geofence watcher
// =============================================================================
// Placed in `app.dart`'s builder so it covers every route. It resolves the
// active home, then asks [GeofenceService] to (re)read the LOCATION automations
// and start the position stream.
//
// Re-resolved on every resume: the user may have created a location automation
// (or captured the home point) while the app was in the background.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/active_home.dart';
import 'geofence_service.dart';

class GeofenceWatcher extends ConsumerStatefulWidget {
  const GeofenceWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<GeofenceWatcher> createState() => _GeofenceWatcherState();
}

class _GeofenceWatcherState extends ConsumerState<GeofenceWatcher>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-only by design: resuming re-baselines which side of the fence
    // we are on, so coming back from a trip does not fire a stale "arrive".
    if (state == AppLifecycleState.resumed) _sync();
  }

  Future<void> _sync() async {
    if (!mounted) return;
    try {
      final homeId = await resolveActiveHomeId(ref);
      if (homeId == null || !mounted) return;
      await ref.read(geofenceServiceProvider).refresh(homeId);
    } catch (_) {
      // Location is optional — never let it break the app.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
