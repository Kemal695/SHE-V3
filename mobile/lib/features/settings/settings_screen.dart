// =============================================================================
// SHE V3 — Settings Screen
// =============================================================================
// Premium, no overflow (ListView), proper sections.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/network/base_url_provider.dart';
import '../auth/auth_service.dart';
import 'server_settings_dialog.dart';
import '../../routing/app_router.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: V3Colors.textPrimary),
            onPressed: () => context.go('/dashboard'),
          ),
          title: const Text('Settings'),
        ),
        body: SafeArea(
          child: ListView(
            children: [
              const SizedBox(height: V3Spacing.sm),

              // ---- Account section ----
              _sectionHeader(context, 'Account'),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.person, color: V3Colors.primary, size: 20),
                ),
                title: const Text('Profile'),
                subtitle: const Text('View your account info'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () {},
              ),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.warning.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.workspace_premium, color: V3Colors.warning, size: 20),
                ),
                title: const Text('Subscription'),
                subtitle: const Text('Free plan — upgrade to Premium'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () => context.push('/payments/B2C_PREMIUM'),
              ),
              const Divider(indent: 16, endIndent: 16),

              // ---- Preferences section ----
              _sectionHeader(context, 'Preferences'),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.language, color: V3Colors.primary, size: 20),
                ),
                title: const Text('Language'),
                subtitle: Text(ref.watch(localeProvider).languageCode == 'am'
                    ? 'አማርኛ (Amharic)' : 'English'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () => _showLanguageDialog(context, ref),
              ),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.secondary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.dark_mode, color: V3Colors.secondary, size: 20),
                ),
                title: const Text('Theme'),
                subtitle: const Text('Dark mode (default)'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () {},
              ),
              // ---- Server / endpoint override ----
              // Also reachable from the login screen, so a bad URL can be fixed
              // even when you cannot authenticate.
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.secondary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.dns, color: V3Colors.secondary, size: 20),
                ),
                title: const Text('Server'),
                subtitle: Text(
                  ref.watch(apiBaseUrlProvider),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () => showServerSettingsDialog(context, ref),
              ),
              const Divider(indent: 16, endIndent: 16),

              // ---- Security section ----
              _sectionHeader(context, 'Security'),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.success.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.security, color: V3Colors.success, size: 20),
                ),
                title: const Text('Two-Factor Authentication'),
                subtitle: const Text('Enable MFA (coming in Phase 5B)'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                enabled: false,
                onTap: null,
              ),
              const Divider(indent: 16, endIndent: 16),

              // ---- About section ----
              _sectionHeader(context, 'About'),
              ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: V3Colors.textSecondary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: const Icon(Icons.info_outline, color: V3Colors.textSecondary, size: 20),
                ),
                title: const Text('Version'),
                subtitle: const Text('SHE V3 — 3.0.0'),
                trailing: const Icon(Icons.chevron_right, color: V3Colors.textSecondary),
                onTap: () {},
              ),
              const Divider(indent: 16, endIndent: 16),

              // ---- Logout ----
              const SizedBox(height: V3Spacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: V3Spacing.lg),
                child: ElevatedButton(
                  onPressed: () async {
                    await ref.read(authServiceProvider).logout();
                    if (context.mounted) context.go('/login');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: V3Colors.error.withValues(alpha: 0.15),
                    foregroundColor: V3Colors.error,
                  ),
                  child: const Text('Logout'),
                ),
              ),
              const SizedBox(height: V3Spacing.xl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: V3Spacing.lg, top: V3Spacing.md, bottom: V3Spacing.xs),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: V3Colors.textSecondary,
          fontSize: V3Typography.overlineSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
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
              leading: ref.watch(localeProvider).languageCode == 'am'
                  ? const Icon(Icons.check, color: V3Colors.primary)
                  : null,
              onTap: () async {
                ref.read(localeProvider.notifier).state = const Locale('am');
                await SecureStorage.saveLocale('am');
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('English'),
              leading: ref.watch(localeProvider).languageCode == 'en'
                  ? const Icon(Icons.check, color: V3Colors.primary)
                  : null,
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
