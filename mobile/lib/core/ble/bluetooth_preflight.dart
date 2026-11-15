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

import 'dart:io' show Platform;

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

  /// A failure the user can only clear on the SYSTEM location settings page.
  ///
  /// Used on Android 11 and older, where a BLE scan with Location switched off
  /// returns zero devices and raises no error at all. `fix` points at the
  /// location settings rather than the app's own page, which on modern Android
  /// has no Location toggle and is therefore a dead end.
  const BluetoothPreflight.failedLocation(String this.message)
      : ok = false,
        fix = PreflightFix.locationSettings,
        locationServicesOff = true;

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

  // ---- 2b. location services ----
  // Android 12+ does NOT need Location switched on to scan once BLUETOOTH_SCAN
  // is declared with usesPermissionFlags="neverForLocation" — which this app
  // does. But BLUETOOTH_SCAN does not exist before API 31, so on Android 11 and
  // below the scan runs on the legacy path, where Location OFF returns ZERO
  // devices and reports NO error.
  //
  // Treating this as advisory everywhere (the previous version of this file)
  // was wrong: on an Android 11 phone the scan runs into the void and the user
  // simply sees "no devices", with nothing to act on. The rule is therefore
  // version-dependent, not blanket.
  bool locationOn = true;
  try {
    locationOn = await Geolocator.isLocationServiceEnabled();
  } catch (_) {
    // Cannot determine it — do not block the flow on a check that failed.
  }

  final sdk = _androidSdkInt();
  final locationIsRequired = sdk != null && sdk <= 30;
  if (!locationOn && locationIsRequired) {
    return const BluetoothPreflight.failedLocation(
      'Turn on Location to find your device.\n\n'
      'This phone runs Android 11 or older, where Android returns no Bluetooth '
      'scan results at all while Location is switched off — the scan finds '
      'nothing and reports no error, so the device list just looks empty.\n\n'
      'Tap the button below — it opens the right settings page.',
    );
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

/// Android API level, parsed out of [Platform.operatingSystemVersion].
///
/// Flutter reports that string on Android as e.g. `"Android 11 (SDK 30)"`, so
/// the level can be read without adding `device_info_plus` as a dependency.
/// Returns null on iOS or if the string does not match — callers must then
/// assume the modern (API 31+) behaviour rather than blocking the user.
int? _androidSdkInt() {
  if (!Platform.isAndroid) return null;
  final match =
      RegExp(r'SDK (\d+)').firstMatch(Platform.operatingSystemVersion);
  return match == null ? null : int.tryParse(match.group(1)!);
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
