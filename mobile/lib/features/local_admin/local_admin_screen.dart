// =============================================================================
// SHE V3 — Local admin (local Wi-Fi control settings)
// =============================================================================
// The working app's local-control configuration (API / WebSocket base URLs,
// the 9-digit local-control PoP and the optional manual board IP) used to live
// inside a Settings → Server dialog. It is promoted here to its own page so it
// is distinct from the OTA / Firmware page in the More menu.
//
// The save/reset logic reuses the working app's existing SettingsStore and the
// shared [reconnectWs] helper from server_settings_dialog.dart.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/base_url_provider.dart';
import '../../core/storage/settings_store.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../settings/server_settings_dialog.dart' show reconnectWs;

class LocalAdminScreen extends ConsumerStatefulWidget {
  const LocalAdminScreen({super.key});

  @override
  ConsumerState<LocalAdminScreen> createState() => _LocalAdminScreenState();
}

class _LocalAdminScreenState extends ConsumerState<LocalAdminScreen> {
  final _apiCtrl = TextEditingController();
  final _wsCtrl = TextEditingController();
  final _popCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _apiCtrl.text = ref.read(apiBaseUrlProvider);
    _wsCtrl.text = ref.read(wsBaseUrlProvider);
    _popCtrl.text = SettingsStore.localPop;
    _hostCtrl.text = SettingsStore.localHost;
  }

  @override
  void dispose() {
    _apiCtrl.dispose();
    _wsCtrl.dispose();
    _popCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final api = _apiCtrl.text.trim();
    final ws = _wsCtrl.text.trim();
    final apiOk = Uri.tryParse(api)?.hasScheme == true;
    final wsOk = Uri.tryParse(ws)?.hasScheme == true;
    if (!apiOk || !wsOk) {
      setState(() => _errorText =
          'Both URLs must include a scheme (http:// or ws://)');
      return;
    }
    await SettingsStore.setApiBaseUrl(api);
    await SettingsStore.setWsBaseUrl(ws);
    await SettingsStore.setLocalPop(_popCtrl.text.trim());
    await SettingsStore.setLocalHost(_hostCtrl.text.trim());
    ref.read(apiBaseUrlProvider.notifier).state = api;
    ref.read(wsBaseUrlProvider.notifier).state = ws;
    await reconnectWs(ref);
    if (!mounted) return;
    setState(() => _errorText = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local admin settings saved')),
    );
  }

  Future<void> _reset() async {
    await SettingsStore.resetToDefaults();
    await SettingsStore.setLocalPop('');
    await SettingsStore.setLocalHost('');
    ref.read(apiBaseUrlProvider.notifier).state = SettingsStore.apiBaseUrl;
    ref.read(wsBaseUrlProvider.notifier).state = SettingsStore.wsBaseUrl;
    await reconnectWs(ref);
    if (!mounted) return;
    setState(() {
      _apiCtrl.text = SettingsStore.apiBaseUrl;
      _wsCtrl.text = SettingsStore.wsBaseUrl;
      _popCtrl.text = '';
      _hostCtrl.text = '';
      _errorText = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reset to build defaults')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: V3Colors.ink),
          onPressed: () => context.pop(),
        ),
        title: const Text('Local admin'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(V3Spacing.lg),
          children: [
            Container(
              padding: const EdgeInsets.all(V3Spacing.md),
              decoration: BoxDecoration(
                color: V3Colors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(V3Radius.lg),
              ),
              child: Row(
                children: [
                  Icon(Icons.router_outlined, color: V3Colors.primary),
                  const SizedBox(width: V3Spacing.sm),
                  Expanded(
                    child: Text(
                      'These let the app reach your backend and control '
                      'devices over Wi-Fi when the internet is down.',
                      style: TextStyle(
                        color: V3Colors.text2,
                        fontSize: V3Typography.meta,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: V3Spacing.lg),
            _sectionHeader('Server'),
            _field(
              controller: _apiCtrl,
              label: 'API base URL',
              hint: 'http://192.168.1.7:8080',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: V3Spacing.md),
            _field(
              controller: _wsCtrl,
              label: 'WebSocket base URL',
              hint: 'ws://192.168.1.7:8080',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: V3Spacing.lg),
            _sectionHeader('Local control (offline Wi-Fi)'),
            _field(
              controller: _popCtrl,
              label: 'Local control PoP (9-digit)',
              hint: '123456789',
              keyboardType: TextInputType.number,
              helper: 'On the device label. Lets the app control devices over '
                  'Wi-Fi when the internet is down.',
            ),
            const SizedBox(height: V3Spacing.md),
            _field(
              controller: _hostCtrl,
              label: 'Board IP (optional)',
              hint: '192.168.1.50',
              keyboardType: TextInputType.url,
              helper: 'Only needed if the board is not auto-discovered '
                  '(mDNS). Usually leave blank.',
            ),
            if (_errorText != null) ...[
              const SizedBox(height: V3Spacing.md),
              Text(
                _errorText!,
                style: TextStyle(
                  color: V3Colors.errorAlt,
                  fontSize: V3Typography.meta,
                ),
              ),
            ],
            const SizedBox(height: V3Spacing.lg),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: V3Colors.primary,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: V3Spacing.sm),
            OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset to defaults'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: V3Colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: V3Spacing.sm, top: V3Spacing.xs),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: V3Colors.textSecondary,
            fontSize: V3Typography.overlineSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required TextInputType keyboardType,
    String? helper,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: V3Colors.textPrimary,
              fontSize: V3Typography.labelSize,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: V3Spacing.xs),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: hint,
              helperText: helper,
              helperMaxLines: 2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(V3Radius.md),
              ),
            ),
          ),
        ],
      );
}
