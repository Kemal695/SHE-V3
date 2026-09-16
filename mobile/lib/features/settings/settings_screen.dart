// =============================================================================
// SHE V3 — Settings screen
// =============================================================================
// V3-MOBILE-APP §3.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/base_url_provider.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/storage/settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/app_router.dart';
import '../auth/auth_service.dart';
import 'server_settings_dialog.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final apiUrl = ref.watch(apiBaseUrlProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n?.settings ?? 'Settings')),
      body: SafeArea(
        child: ListView(
          children: [
            // ---- Server / API endpoints ----
            ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('Server'),
              subtitle: Text(apiUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: SettingsStore.hasOverride
                  ? const Chip(
                      label: Text('custom'),
                      visualDensity: VisualDensity.compact,
                    )
                  : null,
              onTap: () => showServerSettingsDialog(context, ref),
            ),
            const Divider(),

            // ---- Language ----
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(l10n?.language ?? 'Language'),
              subtitle: const Text('አማርኛ / English'),
              onTap: () => _showLanguageDialog(context, ref),
            ),
            const Divider(),

            // ---- MFA (Phase 5B) ----
            ListTile(
              leading: const Icon(Icons.security),
              title: const Text('Two-Factor Authentication'),
              subtitle: const Text('Enable MFA (coming in Phase 5B)'),
              enabled: false,
              onTap: () {},
            ),
            const Divider(),

            // ---- Logout ----
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: Text(l10n?.logout ?? 'Logout', style: const TextStyle(color: Colors.red)),
              onTap: () async {
                await ref.read(authServiceProvider).logout();
                if (context.mounted) context.go('/login');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Language'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('አማርኛ (Amharic)'),
              onTap: () async {
                ref.read(localeProvider.notifier).state = const Locale('am');
                await SecureStorage.saveLocale('am');
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('English'),
              onTap: () async {
                ref.read(localeProvider.notifier).state = const Locale('en');
                await SecureStorage.saveLocale('en');
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
