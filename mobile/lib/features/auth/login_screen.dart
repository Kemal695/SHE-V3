// =============================================================================
// SHE V3 — Login screen
// =============================================================================
// V3-MOBILE-APP §3 + §11 (Amharic first). ADR-009 (dark-mode first).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/base_url_provider.dart';
import '../../core/theme/she_theme.dart';
import '../../core/utils/validators.dart';
import '../../l10n/app_localizations.dart';
import '../settings/server_settings_dialog.dart';
import 'auth_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ref.read(authServiceProvider).login(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
          );
      if (mounted) context.go('/dashboard');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ---- Logo + title ----
                Icon(Icons.home, size: 64, color: SheTheme.brightSkyBlue),
                const SizedBox(height: 16),
                Text(
                  l10n?.appTitle ?? 'Smart Home Ethiopia',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),

                // ---- Email ----
                TextFormField(
                  controller: _emailCtrl,
                  decoration: InputDecoration(labelText: l10n?.email ?? 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  validator: Validators.validateEmail,
                ),
                const SizedBox(height: 16),

                // ---- Password ----
                TextFormField(
                  controller: _passwordCtrl,
                  decoration: InputDecoration(labelText: l10n?.password ?? 'Password'),
                  obscureText: true,
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Password required' : null,
                ),
                const SizedBox(height: 24),

                // ---- Error ----
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_error!, style: const TextStyle(color: SheTheme.error)),
                  ),

                // ---- Login button ----
                ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(l10n?.login ?? 'Login'),
                ),
                const SizedBox(height: 16),

                // ---- Register link ----
                TextButton(
                  onPressed: () => context.go('/register'),
                  child: const Text("Don't have an account? Register"),
                ),

                const SizedBox(height: 8),

                // ---- Server settings ----
                // Reachable WITHOUT a session on purpose: if the server URL is
                // wrong you cannot log in, and the Settings screen is behind the
                // auth redirect — so this is the only way to recover.
                TextButton.icon(
                  onPressed: () => showServerSettingsDialog(context, ref),
                  icon: const Icon(Icons.dns, size: 18),
                  label: Text(
                    'Server: ${ref.watch(apiBaseUrlProvider)}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
