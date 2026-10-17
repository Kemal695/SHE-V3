// =============================================================================
// SHE V3 — Foreground geofence for LOCATION automations
// =============================================================================
// A LOCATION automation ("when I arrive / leave home") stores
//   {type: 'LOCATION', mode: 'arrive'|'leave', radius_m: 200}
// on the automation, and the home's point lives on `homes.latitude/longitude`.
//
// WHO EVALUATES IT: the PHONE, in the foreground. The server never learns where
// the device is — it only receives the existing POST /automations/{id}/trigger
// when the fence is crossed. That keeps location data on the device, and it is
// why no background-location permission is needed: the position stream simply
// stops when the app is not in the foreground (documented limitation).
//
// Crossing detection: the FIRST fix only records which side of the fence we are
// on (no trigger). A later fix on the other side fires. Without that baseline
// every app start inside the house would immediately "arrive".
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../features/automations/automation_service.dart';
import '../../features/device_detail/node_service.dart';

/// Starts/stops the geofence watcher. Created once, kept alive by a widget high
/// in the tree (`GeofenceWatcher` in app_shell).
class GeofenceService {
  GeofenceService(this._ref);

  final Ref _ref;

  StreamSubscription<Position>? _sub;
  Timer? _refreshTimer;
  String? _homeId;
  bool _running = false;
  /// Fence state per automation id: true = currently inside the radius.
  final Map<String, bool> _inside = {};

  /// Automation definitions we are watching, refreshed periodically.
  List<Automation> _watched = const [];
  double? _homeLat;
  double? _homeLng;

  bool get isRunning => _running;

  /// Re-read the automation list + home point, then (re)start the stream.
  ///
  /// [homeId] is resolved by the caller (the watcher widget has a WidgetRef;
  /// `resolveActiveHomeId` needs one). Safe to call repeatedly — an automation
  /// can be created or enabled at any time.
  Future<void> refresh(String homeId) async {
    _homeId = homeId;
    try {
      final automations =
          await _ref.read(homeAutomationsProvider(homeId).future);
      _watched = automations
          .where((a) => a.enabled && a.trigger['type'] == 'LOCATION')
          .toList();

      // The home's point: null until the user captures it.
      final homes = await _ref.read(nodeServiceProvider).listHomes();
      final home = homes.firstWhere(
        (h) => h['id']?.toString() == homeId,
        orElse: () => const <String, dynamic>{},
      );
      _homeLat = (home['latitude'] as num?)?.toDouble();
      _homeLng = (home['longitude'] as num?)?.toDouble();

      final usable = _watched.isNotEmpty && _homeLat != null && _homeLng != null;
      if (!usable) {
        await _stop();
        return;
      }
      await _start();
    } catch (e) {
      debugPrint('Geofence refresh failed: $e');
    }
  }

  Future<void> _start() async {
    if (_running) return;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    // Foreground scope: `whileInUse` is enough; `deniedForever` is not.
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _inside.clear();
    _running = true;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        // 25 m of movement between fixes — enough for a 200 m fence and far
        // cheaper on battery than a per-second stream.
        distanceFilter: 25,
      ),
    ).listen(_onPosition, onError: (Object e) {
      debugPrint('Geofence stream error: $e');
    });

    // A new automation may be added while the app stays open.
    _refreshTimer ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        final id = _homeId;
        if (id != null) refresh(id);
      },
    );
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _running = false;
  }

  void _onPosition(Position p) {
    final lat = _homeLat;
    final lng = _homeLng;
    if (lat == null || lng == null) return;

    final distance = Geolocator.distanceBetween(lat, lng, p.latitude, p.longitude);

    for (final a in _watched) {
      final radius =
          (a.trigger['radius_m'] as num?)?.toDouble() ?? 200.0;
      final inside = distance <= radius;
      final was = _inside[a.id];
      _inside[a.id] = inside;

      // First fix is the baseline only — no trigger.
      if (was == null) continue;
      if (was == inside) continue;

      final mode = (a.trigger['mode'] as String?) ?? 'arrive';
      final shouldFire = (mode == 'arrive' && inside) ||
          (mode == 'leave' && !inside);
      if (!shouldFire) continue;

      debugPrint('Geofence: ${a.name} ($mode) at ${distance.round()} m');
      _ref.read(automationServiceProvider).trigger(a.id).catchError((Object e) {
        debugPrint('Geofence trigger failed for ${a.name}: $e');
        return const AutomationTriggerResult(executed: 0, failed: []);
      });
    }
  }

  Future<void> dispose() async {
    await _stop();
    _watched = const [];
    _inside.clear();
  }
}

final geofenceServiceProvider = Provider<GeofenceService>((ref) {
  final service = GeofenceService(ref);
  ref.onDispose(service.dispose);
  return service;
});
