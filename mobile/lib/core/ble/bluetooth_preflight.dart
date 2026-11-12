// =============================================================================
// SHE V3 — Bluetooth preflight for BLE provisioning
// =============================================================================
// V3-MOBILE-APP §6.
//
// The ESP RainMaker classic app opens its provisioning landing screen by
// switching Bluetooth on and asking for the runtime permissions, and only then
// starts scanning. The vendored flutter_esp_ble_prov plugin asks for the
// permissions as a side effect of the first method call instead — and on a
// denial the Espressif library used to fail on a callback thread and take the
// process down (see the `TODO()` stubs in BleScanManager, now removed).
//
// So the app does the preflight itself, before it touches the BLE stack:
//   1. the phone must have Bluetooth LE at all,
//   2. the runtime permissions must be granted (the plugin picks the right set
//      for the Android version — BLUETOOTH_SCAN/CONNECT on 12+, location
//      before that),
//   3. the adapter must actually be on; if it is off we raise Android's own
//      "Turn on Bluetooth?" dialog.
//
// Every failure returns a message the UI can show verbatim, so nothing throws
// across the provisioning screen.
// =============================================================================

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_esp_ble_prov/flutter_esp_ble_prov.dart';
import 'package:geolocator/geolocator.dart';

/// Android permission name for the QR scanner (V3-FACTORY-OPS §4).
const String kAndroidCameraPermission = 'android.permission.CAMERA';

/// Which settings page (if any) would actually fix a failed preflight.
///
/// The distinction matters: a denied permission is fixed in the APP's settings,
/// while Location being switched off is fixed in the SYSTEM location settings.
/// Sending the user to the wrong one is a dead end — it is exactly what made
/// the empty scan feel like a broken device.
enum PreflightFix { none, appSettings, locationSettings }

/// Outcome of [ensureBluetoothReady].
class BluetoothPreflight {
  const BluetoothPreflight.ready({this.locationServicesOff = false})
      : ok = true,
        message = null,
        fix = PreflightFix.none;

  const BluetoothPreflight.failed(String this.message)
      : ok = false,
        fix = PreflightFix.appSettings,
        locationServicesOff = false;

  /// True when the BLE stack is usable and a scan may be started.
  final bool ok;

  /// A user-facing explanation, only set when [ok] is false.
  final String? message;

  /// Which settings page the user should be taken to, if any.
  final PreflightFix fix;

  /// Advisory, NOT a failure.
  ///
  /// With BLUETOOTH_SCAN declared as `neverForLocation` (see the manifest),
  /// Android 12+ scans fine with Location switched off — so blocking here would
  /// be wrong. It stays a hint: if a scan then comes back empty, Location being
  /// off is the most likely reason and worth saying out loud.
  final bool locationServicesOff;
}

/// Makes sure a BLE scan can actually run. Never throws.
///
/// Deliberately Bluetooth-only. The camera permission is a *separate* request
/// (see `provisioning_screen.dart`): the platform side tracks one permission
/// dialog at a time, and a camera refusal must not block the Bluetooth flow.
Future<BluetoothPreflight> ensureBluetoothReady(FlutterEspBleProv prov) async {
  // ---- 1. hardware ----
  bool supported = true;
  try {
    supported = await FlutterBluePlus.isSupported;
  } catch (_) {
    // Platform channel unavailable — let the scan itself report the problem
    // rather than blocking the user on a check we could not run.
  }
  if (!supported) {
    return const BluetoothPreflight.failed(
      'This phone does not support Bluetooth LE, so it cannot set up a SHE '
      'device over Bluetooth.',
    );
  }

  // ---- 2. runtime permissions ----
  // The plugin picks the right set for the Android version (BLUETOOTH_SCAN /
  // BLUETOOTH_CONNECT on 12+, ACCESS_FINE_LOCATION before that) and re-checks
  // the grant, so a refusal really does come back false.
  bool granted = false;
  try {
    granted = await prov.requestPermissions();
  } catch (e) {
    return BluetoothPreflight.failed(
      'Android would not report the Bluetooth permission state.\n\n$e',
    );
  }
  if (!granted) {
    return const BluetoothPreflight.failed(
      'SHE needs the "Nearby devices" permission to find your device over '
      'Bluetooth. Allow it for this app in Android Settings, then tap Scan '
      'again.',
    );
  }

  // ---- 2b. location services: ADVISORY ONLY ----
  // With BLUETOOTH_SCAN declared `neverForLocation`, Android 12+ does not need
  // Location switched on to scan, so this must NOT block the flow. It is
  // reported so that an empty scan can be explained instead of just being an
  // empty list. (On Android 11 and below the scan really does need it, and the
  // empty-scan hint covers that case too.)
  bool locationOn = true;
  try {
    locationOn = await Geolocator.isLocationServiceEnabled();
  } catch (_) {
    // Cannot determine it — treat as on, so nothing is blocked.
  }

  // ---- 3. adapter ----
  var state = await _adapterState();
  if (state == BluetoothAdapterState.unavailable) {
    return const BluetoothPreflight.failed(
      'Bluetooth is not available on this phone.',
    );
  }
  if (state == BluetoothAdapterState.unauthorized) {
    return const BluetoothPreflight.failed(
      'Android has blocked Bluetooth for this app. Allow Bluetooth for SHE in '
      'Android Settings, then tap Scan again.',
    );
  }

  if (state != BluetoothAdapterState.on) {
    try {
      // Raises Android's "Turn on Bluetooth?" dialog, the same thing the
      // RainMaker app does when its landing screen opens.
      await FlutterBluePlus.turnOn();
    } catch (_) {
      return const BluetoothPreflight.failed(
        'Bluetooth is off. Turn it on, then tap Scan again.',
      );
    }
  }

  // turnOn() resolves as soon as the user accepts, which can be before the
  // adapter reports itself as on — so give it a bounded moment to settle
  // rather than failing on a race.
  for (var i = 0; i < 10 && state != BluetoothAdapterState.on; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    state = await _adapterState();
  }

  if (state != BluetoothAdapterState.on) {
    return const BluetoothPreflight.failed(
      'Bluetooth is still off. Turn it on, then tap Scan again.',
    );
  }

  return BluetoothPreflight.ready(locationServicesOff: !locationOn);
}

/// Asks the platform for the real adapter state.
///
/// [FlutterBluePlus.adapterStateNow] is `unknown` until the first platform
/// call has happened, so read the stream (which triggers that call) and fall
/// back to the cached value if it does not answer in time.
Future<BluetoothAdapterState> _adapterState() async {
  try {
    return await FlutterBluePlus.adapterState
        .first
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    return FlutterBluePlus.adapterStateNow;
  }
}
