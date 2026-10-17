// =============================================================================
// SHE V3 — Register Screen
// =============================================================================
// Premium, keyboard-safe, no overflow, Ethiopian phone validation.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/utils/validators.dart';
import '../auth/auth_service.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authServiceProvider).register(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
            fullName: _nameCtrl.text.trim(),
            phoneNumber: _phoneCtrl.text.trim().isNotEmpty
                ? _phoneCtrl.text.trim()
                : null,
          );
      if (mounted) context.go('/dashboard');
    } catch (e) {
      setState(() {
        if (e.toString().contains('409')) {
          _errorMessage = 'Email already registered. Try logging in.';
        } else if (e.toString().contains('SocketException')) {
          _errorMessage = 'Cannot reach server. Check your connection.';
        } else {
          _errorMessage = 'Registration failed. Please try again.';
        }
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: IconButton(
            icon:  Icon(Icons.arrow_back, color: V3Colors.textPrimary),
            onPressed: () => context.go('/login'),
          ),
          title: const Text('Create Account'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: V3Spacing.lg),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: V3Spacing.xl),

                  // ---- Header ----
                  // Official SHE logo (transparent PNG). Align keeps it at its
                  // intrinsic size inside the stretch column.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Image.asset(
                      // Dark surfaces use the white-window mark; light surfaces
                      // use the navy-window variant so the panes stay visible.
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/branding/she_logo.png'
                          : 'assets/branding/she_logo_light.png',
                      width: 72,
                      height: 72,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                  const SizedBox(height: V3Spacing.lg),
                  Text('Join Smart Home Ethiopia',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: V3Spacing.sm),
                  Text('Create your account to start controlling your home',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: V3Spacing.xl),

                  // ---- Full Name (single field — Ethiopian naming convention) ----
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      prefixIcon: Icon(Icons.person_outline, size: 20),
                    ),
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        v == null || v.trim().length < 2 ? 'Name is too short' : null,
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: V3Spacing.md),

                  // ---- Email ----
                  TextFormField(
                    controller: _emailCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined, size: 20),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    validator: Validators.validateEmail,
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: V3Spacing.md),

                  // ---- Phone (Ethiopian: (+251|0)?9XXXXXXXX) ----
                  TextFormField(
                    controller: _phoneCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Phone (optional)',
                      prefixIcon: Icon(Icons.phone_outlined, size: 20),
                      hintText: '+2519XXXXXXXX or 09XXXXXXXX',
                    ),
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    validator: Validators.validatePhone,
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: V3Spacing.md),

                  // ---- Password ----
                  TextFormField(
                    controller: _passwordCtrl,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                      helperText: 'Min 12 chars: 1 upper, 1 lower, 1 digit, 1 special',
                      helperStyle: TextStyle(
                        color: V3Colors.textSecondary.withValues(alpha: 0.5),
                        fontSize: V3Typography.captionSize,
                      ),
                    ),
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    validator: Validators.validatePassword,
                    enabled: !_isLoading,
                  ),
                  const SizedBox(height: V3Spacing.lg),

                  // ---- Error ----
                  if (_errorMessage != null)
                    Container(
                      padding: const EdgeInsets.all(V3Spacing.md),
                      margin: const EdgeInsets.only(bottom: V3Spacing.md),
                      decoration: BoxDecoration(
                        color: V3Colors.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(V3Radius.md),
                        border: Border.all(color: V3Colors.error.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                           Icon(Icons.error_outline, color: V3Colors.error, size: 20),
                          const SizedBox(width: V3Spacing.sm),
                          Expanded(
                            child: Text(_errorMessage!,
                                style:  TextStyle(color: V3Colors.error, fontSize: V3Typography.captionSize)),
                          ),
                        ],
                      ),
                    ),

                  // ---- Register button ----
                  ElevatedButton(
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const SizedBox(
                            height: 22, width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Create Account'),
                  ),
                  const SizedBox(height: V3Spacing.md),

                  // ---- Login link ----
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Already have an account? ', style: Theme.of(context).textTheme.bodyMedium),
                      TextButton(
                        onPressed: _isLoading ? null : () => context.go('/login'),
                        child: const Text('Login'),
                      ),
                    ],
                  ),
                  const SizedBox(height: V3Spacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
