// =============================================================================
// SHE V3 — Profile (edit the signed-in user's own account)
// =============================================================================
// Settings -> Profile used to be `onTap: () {}` — a dead tile, and there was no
// endpoint behind it either. This screen edits the three fields the API owns:
// full name, phone number and preferred language. The email is read-only
// (changing it would need a verification flow that does not exist yet).
//
// Backend: PATCH /api/v3/auth/me -> the refreshed /auth/me payload.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../auth/auth_service.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveError;
  String _email = '';
  String _language = 'en';
  String _role = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final me = await ref.read(authServiceProvider).me();
      final user = (me['user'] as Map<String, dynamic>?) ?? const {};
      if (!mounted) return;
      setState(() {
        _email = user['email']?.toString() ?? '';
        _nameCtrl.text = user['full_name']?.toString() ?? '';
        _phoneCtrl.text = user['phone_number']?.toString() ?? '';
        _language = user['preferred_language']?.toString() ?? 'en';
        _role = user['tenant_role']?.toString() ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _friendly(e);
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await ref.read(authServiceProvider).updateProfile(
            fullName: _nameCtrl.text.trim(),
            // Empty string clears it server-side.
            phoneNumber: _phoneCtrl.text.trim(),
            preferredLanguage: _language,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated')),
      );
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = _friendly(e);
      });
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('HandshakeException')) {
      return 'Cannot reach the server. Check your connection.';
    }
    if (s.contains('422')) return 'That value is not valid.';
    if (s.contains('401')) return 'Your session expired. Sign in again.';
    return 'Something went wrong. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _ErrorState(message: _loadError!, onRetry: _load)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(V3Spacing.lg),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              color: V3Colors.primary.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                _initials(),
                                style: TextStyle(
                                  color: V3Colors.primary,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: V3Spacing.sm),
                        Text(
                          _email,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: V3Colors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        if (_role.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            _role,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: V3Colors.dim, fontSize: 11),
                          ),
                        ],
                        const SizedBox(height: V3Spacing.lg),

                        _Field(
                          controller: _nameCtrl,
                          label: 'Full name',
                          icon: Icons.person_outline,
                          enabled: !_saving,
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            final t = (v ?? '').trim();
                            if (t.isEmpty) return 'Name cannot be empty';
                            if (t.length > 120) return 'Max 120 characters';
                            return null;
                          },
                        ),
                        const SizedBox(height: V3Spacing.md),
                        _Field(
                          controller: _phoneCtrl,
                          label: 'Phone number',
                          icon: Icons.phone_outlined,
                          enabled: !_saving,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _save(),
                          validator: (v) {
                            final t = (v ?? '').trim();
                            if (t.isEmpty) return null; // optional
                            if (t.length > 32) return 'Max 32 characters';
                            if (!RegExp(r'^[0-9+()\-\s]+$').hasMatch(t)) {
                              return 'Digits, spaces and + ( ) - only';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: V3Spacing.md),

                        // Email is read-only: changing it needs a verification
                        // flow (confirm the new address) that does not exist.
                        TextFormField(
                          initialValue: _email,
                          enabled: false,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            helperText: 'Email cannot be changed here',
                            prefixIcon: const Icon(Icons.mail_outline),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(V3Radius.md),
                            ),
                          ),
                        ),

                        if (_saveError != null) ...[
                          const SizedBox(height: V3Spacing.md),
                          Text(
                            _saveError!,
                            style: TextStyle(
                                color: V3Colors.errorAlt, fontSize: 12),
                          ),
                        ],

                        const SizedBox(height: V3Spacing.lg),
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              backgroundColor: V3Colors.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(V3Radius.md),
                              ),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Save changes',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }

  String _initials() {
    final name = _nameCtrl.text.trim();
    final source = name.isNotEmpty ? name : _email;
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'[\s@.]+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return source[0].toUpperCase();
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.elementAt(1)[0]).toUpperCase();
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    required this.enabled,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final void Function(String)? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V3Radius.md),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(V3Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: V3Colors.dim),
            const SizedBox(height: V3Spacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: V3Colors.textSecondary),
            ),
            const SizedBox(height: V3Spacing.md),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
