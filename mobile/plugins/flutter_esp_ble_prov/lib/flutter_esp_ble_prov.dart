import 'package:permission_handler/permission_handler.dart' as ph;

import 'src/flutter_esp_ble_prov_platform_interface.dart';

/// Plugin provides core functionality to provision ESP32 devices over BLE
class FlutterEspBleProv {
  /// Requests the runtime permissions BLE provisioning needs.
  ///
  /// Added here rather than at each call site: the vendored plugin is 0.1.7 and
  /// does not expose this, while newer callers expect it. Implemented on top of
  /// permission_handler, which this app already depends on, so there is no
  /// platform-channel work and no Kotlin change.
  ///
  /// Android 12+ splits Bluetooth into SCAN/CONNECT; location is still required
  /// for BLE scanning on Android 10 and below.
  Future<bool> requestPermissions() async {
    final results = await [
      ph.Permission.bluetoothScan,
      ph.Permission.bluetoothConnect,
      ph.Permission.locationWhenInUse,
    ].request();

    // Bluetooth permissions do not exist below Android 12 — those return
    // granted/denied-forever rather than a real answer, so judge on what matters:
    // every permission that is actually applicable must be granted.
    return results.values.every(
      (s) => s.isGranted || s.isLimited || s == ph.PermissionStatus.restricted,
    );
  }

  /// Opens the system settings page for this app.
  ///
  /// Used when a permission was denied permanently, where requesting again is a
  /// no-op and the only way forward is the settings screen.
  Future<void> openAppSettings() async {
    await ph.openAppSettings();
  }

  /// Initiates a scan of BLE devices with the given [prefix].
  ///
  /// ESP32 Arduino demo defaults this value to "PROV_"
  Future<List<String>> scanBleDevices(String prefix) {
    return FlutterEspBleProvPlatform.instance.scanBleDevices(prefix);
  }

  /// Scan the available WiFi networks for the given [deviceName] and
  /// [proofOfPossession] string.

  /// This library uses SECURITY_1 by default which insists on a
  /// [proofOfPossession] string. ESP32 Arduino demo defaults this value to
  /// "abcd1234"
  Future<List<String>> scanWifiNetworks(
      String deviceName, String proofOfPossession) {
    return FlutterEspBleProvPlatform.instance
        .scanWifiNetworks(deviceName, proofOfPossession);
  }

  /// Provision the named WiFi network at [ssid] with the given [passphrase] for
  /// the named device [deviceName] and [proofOfPossession] string.
  Future<bool?> provisionWifi(String deviceName, String proofOfPossession,
      String ssid, String passphrase) {
    return FlutterEspBleProvPlatform.instance
        .provisionWifi(deviceName, proofOfPossession, ssid, passphrase);
  }

  /// Returns the native platform version
  Future<String?> getPlatformVersion() {
    return FlutterEspBleProvPlatform.instance.getPlatformVersion();
  }
}
