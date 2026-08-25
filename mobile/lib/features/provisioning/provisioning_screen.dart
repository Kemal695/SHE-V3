// =============================================================================
// SHE V3 — Provisioning screen (BLE)
// =============================================================================
// V3-MOBILE-APP §6. V3-FIRMWARE §5.
// P0-1: BLE does NOT issue certs — cert is factory-issued.
// P1-2: BLE Service UUID = 0000ffff-0000-1000-8000-00805f9b34fb.
// P1-26: PoP = 9-digit numeric (scanned from QR code).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_theme.dart';
import '../device_detail/node_service.dart';

class ProvisioningScreen extends ConsumerStatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  ConsumerState<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends ConsumerState<ProvisioningScreen> {
  final _macCtrl = TextEditingController();
  final _popCtrl = TextEditingController();
  final _ssidCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _macCtrl.dispose();
    _popCtrl.dispose();
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _startProvisioning() async {
    if (_macCtrl.text.isEmpty || _popCtrl.text.isEmpty) {
      setState(() => _error = 'MAC + PoP required (scan QR code on device)');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _status = 'Scanning for BLE device...';
    });

    try {
      // P0-1: BLE does NOT issue certs — cert is factory-issued.
      // Flow:
      //   1. Scan BLE → find "SHE-R8-AABBCC" (advertised name = node_id)
      //   2. Connect (BLE Security 1, PoP = 9-digit from QR)
      //   3. Send {wifi_ssid, wifi_password, tenant_id, claim_token, api_base_url} via GATT
      //   4. ESP32 connects to Wi-Fi + POSTs to /api/v3/nodes/claim
      //   5. WebSocket push "device_provisioned" → device appears in dashboard

      // For Phase 1: call the claim endpoint directly (simulated BLE flow)
      // In production, use flutter_blue_plus to scan + connect + write GATT characteristic
      setState(() => _status = 'Connecting to device via BLE...');

      // TODO: implement actual BLE scan + connect via flutter_blue_plus
      // For now: simulate the claim call
      final result = await ref.read(nodeServiceProvider).claim(
        mac: _macCtrl.text,
        claimToken: 'phase1-test-claim-token',
        sku: 'SHE-R8',
        config: {
          'wifi_ssid': _ssidCtrl.text,
          'wifi_password': _passwordCtrl.text,
        },
      );

      setState(() => _status = 'Device provisioned: ${result['node_id']}');

      // Return to dashboard after 2s
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) context.go('/dashboard');
    } catch (e) {
      setState(() {
        _error = e.toString();
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Device')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Instructions ----
              const Icon(Icons.qr_code_scanner, size: 64, color: SheTheme.brightSkyBlue),
              const SizedBox(height: 16),
              Text(
                'Scan the QR code on your device to get the MAC + PoP',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              // ---- MAC (from QR) ----
              TextFormField(
                controller: _macCtrl,
                decoration: const InputDecoration(
                  labelText: 'MAC Address',
                  hintText: 'AA:BB:CC:DD:EE:FF',
                ),
              ),
              const SizedBox(height: 16),

              // ---- PoP (9-digit from QR — P1-26) ----
              TextFormField(
                controller: _popCtrl,
                decoration: const InputDecoration(
                  labelText: 'PoP (9-digit)',
                  hintText: '482917305',
                ),
                keyboardType: TextInputType.number,
                maxLength: 9,
              ),
              const SizedBox(height: 16),

              // ---- Wi-Fi SSID ----
              TextFormField(
                controller: _ssidCtrl,
                decoration: const InputDecoration(labelText: 'Wi-Fi Network'),
              ),
              const SizedBox(height: 16),

              // ---- Wi-Fi password ----
              TextFormField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(labelText: 'Wi-Fi Password'),
                obscureText: true,
              ),
              const SizedBox(height: 24),

              // ---- Status ----
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_status!)),
                    ],
                  ),
                ),

              // ---- Error ----
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!, style: const TextStyle(color: SheTheme.error)),
                ),

              // ---- Start button ----
              ElevatedButton(
                onPressed: _isLoading ? null : _startProvisioning,
                child: _isLoading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Start Provisioning'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
