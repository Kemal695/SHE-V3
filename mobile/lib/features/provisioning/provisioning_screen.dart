// =============================================================================
// SHE V3 — Provisioning screen (BLE) — app-claims flow
// =============================================================================
// V3-MOBILE-APP §6. V3-FIRMWARE §5.
// Real BLE provisioning via Espressif wifi_prov_mgr (BLE scheme, Security 1):
//   1. Scan BLE → find "SHE-XXXXXX" (name prefix "SHE-", service UUID
//      0000ffff-0000-1000-8000-00805f9b34fb per P1-2)
//   2. Connect with PoP (P1-26: 9-digit numeric, Security 1)
//   3. Send {wifi_ssid, wifi_password} via GATT (standard prov-config)
//   4. Device connects to Wi-Fi, marks provisioned, reboots
//   5. App calls POST /api/v3/nodes/claim (P1-3) with {mac, sku, home_id}
//      to bind the factory-pre-registered node to the user's tenant.
// P0-1: BLE does NOT issue certs — cert is factory-issued via
// POST /internal/factory/register-cert before claim.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_esp_ble_prov/flutter_esp_ble_prov.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_theme.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/node_service.dart';

class ProvisioningScreen extends ConsumerStatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  ConsumerState<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends ConsumerState<ProvisioningScreen> {
  final _prov = FlutterEspBleProv();

  final _prefixCtrl = TextEditingController(text: 'SHE-');
  final _popCtrl = TextEditingController(text: '123456789');
  final _passphraseCtrl = TextEditingController();
  final _macCtrl = TextEditingController();
  // Hidden networks are invisible to the ESP32's scan (a hidden AP omits its
  // SSID from the beacon), so the name has to be typed by hand.
  final _manualSsidCtrl = TextEditingController();
  String _selectedSku = 'SHE-R8';

  bool _isLoading = false;
  String? _error;
  String? _status;

  List<String> _devices = [];
  List<String> _networks = [];
  String? _selectedDevice;
  String? _selectedSsid;
  bool _wifiOk = false;

  List<Map<String, dynamic>> _homes = [];
  String? _selectedHomeId;

  @override
  void initState() {
    super.initState();
    _loadHomes();
  }

  Future<void> _loadHomes() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (!mounted) return;
      setState(() {
        _homes = homes;
        if (_homes.isNotEmpty) {
          _selectedHomeId =
              (_homes.first['id'] ?? _homes.first['home_id'])?.toString();
        }
      });
    } catch (_) {
      // Homes load failure is non-fatal — backend falls back to the user's
      // most recent home when home_id is omitted (NodeServiceImpl.claim).
    }
  }

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _popCtrl.dispose();
    _passphraseCtrl.dispose();
    _macCtrl.dispose();
    super.dispose();
  }

  void _setBusy(String status) {
    setState(() {
      _isLoading = true;
      _error = null;
      _status = status;
    });
  }

  void _setIdle() {
    if (mounted) setState(() => _isLoading = false);
  }

  void _fail(Object e) {
    setState(() {
      _isLoading = false;
      _error = e.toString();
      _status = null;
    });
  }

  // ---- Step 1: scan BLE for SHE devices ----
  Future<void> _scanBle() async {
    _setBusy('Scanning for BLE devices...');
    try {
      final devices = await _prov.scanBleDevices(_prefixCtrl.text.trim());
      setState(() {
        _devices = devices;
        _networks = [];
        _selectedDevice = null;
        _selectedSsid = null;
        _status = devices.isEmpty
            ? 'No devices found — is the ESP32 powered and in provisioning mode?'
            : 'Found ${devices.length} device(s) — tap one to scan Wi-Fi networks';
      });
    } catch (e) {
      _fail(e);
      return;
    }
    _setIdle();
  }

  // ---- Step 2: connect + scan Wi-Fi networks via the device ----
  Future<void> _scanWifi(String deviceName) async {
    if (_popCtrl.text.isEmpty) {
      setState(() =>
          _error = 'PoP required (9-digit from device QR / firmware log)');
      return;
    }
    _setBusy('Connecting to $deviceName...');
    try {
      final networks =
          await _prov.scanWifiNetworks(deviceName, _popCtrl.text.trim());
      setState(() {
        _selectedDevice = deviceName;
        _networks = networks;
        _selectedSsid = null;
        _status = networks.isEmpty
            ? 'Connected, but no Wi-Fi networks found'
            : 'Connected — pick a Wi-Fi network below';
      });
    } catch (e) {
      // The plugin now forwards the library's real error code + cause, so keep
      // the hint for session-level rejections (E1) and GATT connect failures
      // (E2) without hiding the underlying message.
      final msg = e.toString().toLowerCase();
      final sessionFailure = msg.contains('session') ||
          msg.contains('create session') ||
          msg.contains('(e1,') ||
          msg.contains('(e2,');
      if (sessionFailure) {
        _fail(
            'Secure session rejected. Check: 1) the PoP matches this device — '
            'DevKit/bring-up boards (CONFIG_SHE_DEVKIT_ESP32) use the dev default '
            '123456789; production units use the 9-digit factory PoP, which can be '
            'recovered from the fctry NVS partition with scripts/read-fctry-pop.py, '
            '2) the phone is next to the device, 3) power-cycle the device for a '
            'clean provisioning session if an earlier attempt failed halfway. '
            'Details: $e');
      } else {
        _fail(e);
      }
      return;
    }
    _setIdle();
  }

  // ---- Step 3: send Wi-Fi creds, device connects + reboots ----
  Future<void> _provision() async {
    // A manually typed SSID wins: a hidden AP never appears in the ESP32's
    // scan (it omits its SSID from the beacon), so the only way to reach it is
    // to type the name exactly.
    final manual = _manualSsidCtrl.text.trim();
    final ssid = manual.isNotEmpty ? manual : _selectedSsid;
    if (_selectedDevice == null || ssid == null || ssid.isEmpty) {
      setState(() => _error =
          'Pick a Wi-Fi network, or type the name of your hidden network');
      return;
    }
    if (_popCtrl.text.trim().length != 9 ||
        int.tryParse(_popCtrl.text.trim()) == null) {
      setState(
          () => _error = 'PoP must be 9-digit numeric (P1-26, from device QR)');
      return;
    }
    _setBusy('Sending Wi-Fi credentials to $_selectedDevice...');
    try {
      final ok = await _prov.provisionWifi(
        _selectedDevice!,
        _popCtrl.text.trim(),
        ssid,
        _passphraseCtrl.text,
      );
      if (ok == true) {
        // Pre-fill MAC from the advertised name when it carries the last
        // 6 hex chars (e.g. "SHE-AABBCC" or "SHE-R8-AABBCC").
        final dev = _selectedDevice ?? '';
        final m = RegExp(r'([0-9A-Fa-f]{6})$').firstMatch(dev);
        if (m != null && _macCtrl.text.isEmpty && _selectedDevice != null) {
          _macCtrl.text = m.group(1)!;
        }
        setState(() {
          _wifiOk = true;
          _status =
              'Wi-Fi sent! $_selectedDevice is connecting to "$ssid" and will reboot. '
              'Now claim the device below so it appears in your dashboard.';
        });
      } else {
        setState(
            () => _error = 'Provisioning failed (device rejected credentials)');
      }
    } catch (e) {
      _fail(e);
      return;
    }
    _setIdle();
  }

  // ---- Step 4 (app-claims): POST /api/v3/nodes/claim (P1-3) ----
  // The device only does Wi-Fi + MQTT (P0-1: no cert issuance over BLE).
  // The app binds the factory-pre-registered node to the user's tenant.
  Future<void> _claim() async {
    final mac = _macCtrl.text.trim();
    if (!RegExp(r'^[0-9a-fA-F:]{12,17}$').hasMatch(mac)) {
      setState(() => _error =
          'MAC required (12 hex chars or AA:BB:CC:DD:EE:FF from device QR)');
      return;
    }
    _setBusy('Claiming device $mac...');
    try {
      final nodeService = ref.read(nodeServiceProvider);
      // Fresh 10-min claim JWT bound to our tenant (POST /auth/claim-token).
      final token = await nodeService.claimToken();
      final result = await nodeService.claim(
            mac: mac,
            claimToken: token,
            sku: _selectedSku,
            homeId: _selectedHomeId,
            config: const {},
          );
      if (!mounted) return;
      setState(() => _status =
          'Device claimed: ${result['node_id'] ?? result['node_db_id']} — opening dashboard…');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) context.go('/dashboard');
    } catch (e) {
      _fail(e);
      return;
    }
    _setIdle();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n?.provisioning ?? 'Add Device')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.bluetooth_searching,
                  size: 64, color: SheTheme.brightSkyBlue),
              const SizedBox(height: 16),

              // ---- Prefix + PoP ----
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _prefixCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Device prefix', hintText: 'SHE-'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _popCtrl,
                      decoration: InputDecoration(
                          labelText: l10n?.pop ?? 'PoP (9-digit)',
                          hintText: '123456789'),
                      keyboardType: TextInputType.number,
                      maxLength: 9,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _scanBle,
                icon: const Icon(Icons.refresh),
                label: const Text('Scan for devices'),
              ),
              const SizedBox(height: 16),

              // ---- Found devices ----
              if (_devices.isNotEmpty) ...[
                Text('Devices', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ..._devices.map((d) => Card(
                      color: _selectedDevice == d
                          ? SheTheme.brightSkyBlue.withOpacity(0.2)
                          : null,
                      child: ListTile(
                        leading: const Icon(Icons.memory),
                        title: Text(d),
                        trailing: _selectedDevice == d
                            ? const Icon(Icons.check,
                                color: SheTheme.brightSkyBlue)
                            : null,
                        onTap: _isLoading ? null : () => _scanWifi(d),
                      ),
                    )),
                const SizedBox(height: 16),
              ],

              // ---- Wi-Fi credentials (once the device is connected) ----
              if (_selectedDevice != null) ...[
                Text('Wi-Fi network (via $_selectedDevice)',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ..._networks.map((n) => Card(
                      color: _selectedSsid == n
                          ? SheTheme.brightSkyBlue.withOpacity(0.2)
                          : null,
                      child: ListTile(
                        leading: const Icon(Icons.wifi),
                        title: Text(n.isEmpty ? '(unnamed)' : n),
                        onTap: _isLoading
                            ? null
                            : () => setState(() {
                                  _selectedSsid = n;
                                  // Choosing from the list clears any typed name.
                                  _manualSsidCtrl.clear();
                                }),
                      ),
                    )),
                const SizedBox(height: 12),
                // A hidden AP omits its SSID from the beacon, so the ESP32's
                // scan cannot see it at all — the name has to be typed here.
                TextFormField(
                  controller: _manualSsidCtrl,
                  decoration: InputDecoration(
                    labelText: 'Network name (SSID)',
                    hintText: 'Type it for a hidden network',
                    helperText: _networks.isEmpty
                        ? 'No broadcast networks found — type your SSID'
                        : 'Leave empty to use the network selected above',
                  ),
                  onChanged: (v) => setState(() {
                    if (v.trim().isNotEmpty) _selectedSsid = null;
                  }),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passphraseCtrl,
                  decoration: InputDecoration(
                      labelText: l10n?.wifiPassword ?? 'Wi-Fi password',
                      hintText: '••••••••'),
                  obscureText: true,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: (_isLoading ||
                          (_selectedSsid == null &&
                              _manualSsidCtrl.text.trim().isEmpty))
                      ? null
                      : _provision,
                  icon: const Icon(Icons.send),
                  label: const Text('Send credentials & provision'),
                ),
                const SizedBox(height: 16),
              ],

              // ---- Step 4: claim (app-claims, P1-3) ----
              // Shown unconditionally. Claiming is just an API call keyed on the
              // MAC (POST /api/v3/nodes/claim), so it must not be gated behind the
              // Wi-Fi step — which reports a false negative when the firmware
              // reboots immediately after getting an IP (see ble_provisioning.c:
              // it sets the provisioned flag then esp_restart()s, dropping the BLE
              // link before the library can read the final status).
              ...[
                Text('Claim device',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _macCtrl,
                  decoration: InputDecoration(
                      labelText: l10n?.macAddress ?? 'MAC Address',
                      hintText: 'AA:BB:CC:DD:EE:FF'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedSku,
                        decoration: const InputDecoration(labelText: 'Model'),
                        items: const [
                          DropdownMenuItem(
                              value: 'SHE-R4', child: Text('SHE-R4')),
                          DropdownMenuItem(
                              value: 'SHE-R8', child: Text('SHE-R8')),
                          DropdownMenuItem(
                              value: 'SHE-R16', child: Text('SHE-R16')),
                        ],
                        onChanged: (v) =>
                            setState(() => _selectedSku = v ?? 'SHE-R8'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedHomeId,
                        decoration: const InputDecoration(labelText: 'Home'),
                        items: _homes
                            .map((h) => DropdownMenuItem(
                                  value:
                                      ((h['id'] ?? h['home_id']))?.toString(),
                                  child: Text((h['name'] ?? 'Home').toString()),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _selectedHomeId = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _claim,
                  icon: const Icon(Icons.verified),
                  label: const Text('Claim device'),
                ),
                const SizedBox(height: 16),
              ],

              // ---- Status ----
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      if (_isLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (_isLoading) const SizedBox(width: 12),
                      Expanded(child: Text(_status!)),
                    ],
                  ),
                ),

              // ---- Error ----
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!,
                      style: const TextStyle(color: SheTheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
