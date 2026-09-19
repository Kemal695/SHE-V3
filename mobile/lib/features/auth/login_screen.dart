// =============================================================================
// SHE V3 — Login Screen
// =============================================================================
// Premium dark-mode login. Keyboard-safe (resizeToAvoidBottomInset + ScrollView).
// No overflow. Animated logo. Proper error display. No back-to-login issue.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/network/base_url_provider.dart';
import '../settings/server_settings_dialog.dart';
import '../auth/auth_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // Dismiss keyboard
    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authServiceProvider).login(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
          );
      if (mounted) {
        // Use go (not push) so back button from dashboard exits app
        context.go('/dashboard');
      }
    } catch (e) {
      setState(() {
        _errorMessage = _parseError(e.toString());
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _parseError(String error) {
    if (error.contains('401')) return 'Invalid email or password';
    if (error.contains('429')) return 'Too many attempts. Try again later.';
    if (error.contains('SocketException') || error.contains('HandshakeException')) {
      return 'Cannot reach server. Check your connection.';
    }
    return 'Login failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // On login screen, back button exits the app
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Prevent navigating back — stay on login
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  // Always scrollable — prevents overflow when keyboard appears
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: V3Spacing.lg),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Spacer(flex: 2),

                            // ---- Logo ----
                            _buildLogo(),
                            const SizedBox(height: V3Spacing.xl),

                            // ---- Title ----
                            Text(
                              'Smart Home Ethiopia',
                              style: Theme.of(context).textTheme.headlineMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: V3Spacing.sm),
                            Text(
                              'Control your home from anywhere',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: V3Spacing.xxl),

                            // ---- Form ----
                            Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Email
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

                                  // Password
                                  TextFormField(
                                    controller: _passwordCtrl,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      prefixIcon: const Icon(Icons.lock_outline, size: 20),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_off_outlined
                                              : Icons.visibility_outlined,
                                          size: 20,
                                        ),
                                        onPressed: () => setState(() =>
                                            _obscurePassword = !_obscurePassword),
                                      ),
                                    ),
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _submit(),
                                    validator: (v) =>
                                        v == null || v.isEmpty ? 'Password required' : null,
                                    enabled: !_isLoading,
                                  ),
                                  const SizedBox(height: V3Spacing.lg),

                                  // Error message
                                  if (_errorMessage != null)
                                    Container(
                                      padding: const EdgeInsets.all(V3Spacing.md),
                                      margin: const EdgeInsets.only(bottom: V3Spacing.md),
                                      decoration: BoxDecoration(
                                        color: V3Colors.error.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(V3Radius.md),
                                        border: Border.all(
                                            color: V3Colors.error.withValues(alpha: 0.3)),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.error_outline,
                                              color: V3Colors.error, size: 20),
                                          const SizedBox(width: V3Spacing.sm),
                                          Expanded(
                                            child: Text(
                                              _errorMessage!,
                                              style: const TextStyle(
                                                color: V3Colors.error,
                                                fontSize: V3Typography.captionSize,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                  // Login button
                                  ElevatedButton(
                                    onPressed: _isLoading ? null : _submit,
                                    child: _isLoading
                                        ? const SizedBox(
                                            height: 22,
                                            width: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text('Login'),
                                  ),
                                ],
                              ),
                            ),

                            const Spacer(flex: 1),

                            // ---- Register link ----
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "Don't have an account? ",
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                TextButton(
                                  onPressed: _isLoading
                                      ? null
                                      : () => context.go('/register'),
                                  child: const Text('Register'),
                                ),
                              ],
                            ),
                            const SizedBox(height: V3Spacing.lg),

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
                            const SizedBox(height: V3Spacing.sm),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [V3Colors.primary, V3Colors.secondary],
        ),
        borderRadius: BorderRadius.circular(V3Radius.xl),
        boxShadow: [
          BoxShadow(
            color: V3Colors.primary.withValues(alpha: 0.3),
            blurRadius: 24,
            spreadRadius: 4,
          ),
        ],
      ),
      child: const Icon(
        Icons.home,
        size: 40,
        color: Colors.white,
      ),
    );
  }
}
