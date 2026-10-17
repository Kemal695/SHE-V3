// =============================================================================
// SHE V3 — Login Screen (branded, matches the approved SHE login mockup)
// =============================================================================
// Dark branded auth screen:
//   SHE logo -> "Welcome Home" -> label-less email / password fields ->
//   "Forgot password?" -> "Sign In" -> "or continue with" ->
//   "Create account" outline -> footer.
//
// PRESERVED from the previous implementation (do not remove):
//   * _submit() -> authServiceProvider.login(), then context.go('/dashboard').
//   * Validators.validateEmail / the required-password check.
//   * _parseError() mapping (401 / 429 / socket) to human messages.
//   * PopScope(canPop: false) so Back exits instead of popping to splash.
//   * The Server settings entry point — the ONLY pre-auth way to fix a wrong
//     server URL (Settings sits behind the auth redirect).
//   * Keyboard safety: resizeToAvoidBottomInset + a scrollable min-height body.
//
// This screen deliberately uses the DARK SHE palette (SheColors.dark) whatever
// the app's light/dark setting is: it is the branded entry point and must match
// the approved mockup (Deep Navy + white text).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_colors.dart';
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
    if (error.contains('SocketException') ||
        error.contains('HandshakeException')) {
      return 'Cannot reach server. Check your connection.';
    }
    return 'Login failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    // Follow the app's light/dark setting. In light mode the screen is light and
    // the logo uses the navy-window variant (see _LoginLogo).
    final p = context.sheColors;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Prevent navigating back — stay on login.
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // Light status-bar icons on the navy background.
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          backgroundColor: p.background,
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: V3Spacing.lg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 24),

                            // ---- Logo (wordmark lives in the footer) ----
                            const Center(child: _LoginLogo()),

                            const SizedBox(height: 26),

                            // ---- Heading ----
                            Text(
                              'Welcome Home',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 30,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                color: p.ink,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Sign in to control your home',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: p.text2,
                              ),
                            ),

                            const SizedBox(height: 30),

                            // ---- Form ----
                            Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _LoginField(
                                    controller: _emailCtrl,
                                    icon: Icons.mail_outline,
                                    hint: 'Email address',
                                    enabled: !_isLoading,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.next,
                                    validator: Validators.validateEmail,
                                  ),
                                  const SizedBox(height: 14),
                                  _LoginField(
                                    controller: _passwordCtrl,
                                    icon: Icons.lock_outline,
                                    hint: 'Password',
                                    enabled: !_isLoading,
                                    obscure: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onSubmitted: (_) => _submit(),
                                    validator: (v) => v == null || v.isEmpty
                                        ? 'Password required'
                                        : null,
                                    trailing: IconButton(
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 18,
                                      ),
                                      color: p.dim,
                                      onPressed: () => setState(() =>
                                          _obscurePassword = !_obscurePassword),
                                    ),
                                  ),

                                  // Error
                                  if (_errorMessage != null) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      _errorMessage!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: p.errorAlt,
                                      ),
                                    ),
                                  ],

                                  const SizedBox(height: 10),

                                  // Forgot password (inert — no reset flow yet)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      'Forgot password?',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: p.primary,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 18),

                                  // ---- Primary button ----
                                  SizedBox(
                                    height: 52,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: p.primary,
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          onTap: _isLoading ? null : _submit,
                                          child: Center(
                                            child: _isLoading
                                                ? const SizedBox(
                                                    height: 22,
                                                    width: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                                  )
                                                : const Text(
                                                    'Sign In',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 26),

                            // ---- or continue with ----
                            Row(
                              children: [
                                Expanded(
                                  child: Divider(height: 1, color: p.border),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: Text(
                                    'or continue with',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: p.dim,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(height: 1, color: p.border),
                                ),
                              ],
                            ),

                            const SizedBox(height: 18),

                            // ---- Create account ----
                            SizedBox(
                              height: 52,
                              child: OutlinedButton.icon(
                                onPressed: _isLoading
                                    ? null
                                    : () => context.go('/register'),
                                icon: const Icon(Icons.person_outline,
                                    size: 18),
                                label: const Text(
                                  'Create account',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: p.ink,
                                  side: BorderSide(color: p.borderStrong),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 44),

                            // ---- Footer ----
                            Text(
                              'Smart Home Ethiopia • SHE',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: p.dim,
                              ),
                            ),

                            // Pre-auth server recovery — kept subtle.
                            Center(
                              child: TextButton.icon(
                                onPressed: () =>
                                    showServerSettingsDialog(context, ref),
                                icon: const Icon(Icons.dns, size: 14),
                                style: TextButton.styleFrom(
                                  foregroundColor: p.dim,
                                  minimumSize: Size.zero,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                label: Text(
                                  'Server: ${ref.watch(apiBaseUrlProvider)}',
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Official SHE logo with a soft brand glow.
class _LoginLogo extends StatelessWidget {
  const _LoginLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x6656B4FA), // primary @ 40%
            blurRadius: 52,
            spreadRadius: -10,
          ),
        ],
      ),
      child: Image.asset(
        // White window panes read on dark surfaces; navy panes on light ones.
        Theme.of(context).brightness == Brightness.dark
            ? 'assets/branding/she_logo.png'
            : 'assets/branding/she_logo_light.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

/// Rounded, label-less input row matching the mockup's field chrome.
class _LoginField extends StatelessWidget {
  const _LoginField({
    required this.controller,
    required this.icon,
    required this.hint,
    required this.enabled,
    this.obscure = false,
    this.trailing,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool enabled;
  final bool obscure;
  final Widget? trailing;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final void Function(String)? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.sheColors;
    return FormField<String>(
      validator: validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      builder: (state) {
        final hasError = state.hasError;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasError
                      ? p.errorAlt.withValues(alpha: 0.6)
                      : p.borderStrong,
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 19, color: p.dim),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: controller,
                      obscureText: obscure,
                      enabled: enabled,
                      keyboardType: keyboardType,
                      textInputAction: textInputAction,
                      onFieldSubmitted: onSubmitted,
                      onChanged: state.didChange,
                      cursorColor: p.primary,
                      style: TextStyle(fontSize: 14, color: p.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: hint,
                        hintStyle: TextStyle(fontSize: 14, color: p.dim),
                        // Errors are surfaced below the field by `state`.
                        errorStyle: const TextStyle(
                          fontSize: 0,
                          height: 0,
                          color: Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            if (hasError) ...[
              const SizedBox(height: 5),
              Text(
                state.errorText ?? '',
                style: TextStyle(fontSize: 12, color: p.errorAlt),
              ),
            ],
          ],
        );
      },
    );
  }
}
