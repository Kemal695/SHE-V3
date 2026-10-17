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
// The screen follows the app's light/dark setting:
//   * DARK  -> exactly the approved mockup (Deep Navy #0B1D37, glowing logo with
//             white window panes, white heading, sky-blue Sign In with a glow).
//   * LIGHT -> the light palette with the navy-window logo variant
//             (she_logo_light.png), because white panes vanish on white.
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

  Future<void> _socialSignIn(String provider) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      if (provider == 'Google') {
        await auth.loginWithGoogle();
      } else {
        await auth.loginWithApple();
      }
      if (mounted) context.go('/dashboard');
    } catch (e) {
      setState(() => _errorMessage = _socialError(provider, e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _socialError(String provider, Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('cancel')) return '$provider sign-in cancelled';
    if (s.contains('503') || s.contains('not configured')) {
      return '$provider sign-in is not available on this server';
    }
    if (s.contains('socket') || s.contains('timeout')) {
      return 'Cannot reach server. Check your connection.';
    }
    return '$provider sign-in failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    // Follow the app's light/dark setting so dark mode matches the approved
    // mockup and light mode uses the light palette.
    final p = context.sheColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Prevent navigating back — stay on login.
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // Light status-bar icons on navy, dark icons on the light palette.
        value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
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
                                    height: 54,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: p.primary,
                                        borderRadius:
                                            BorderRadius.circular(14),
                                        boxShadow: [
                                          BoxShadow(
                                            color: p.primary.withValues(
                                                alpha: isDark ? 0.45 : 0.25),
                                            blurRadius: 26,
                                            spreadRadius: -4,
                                            offset: const Offset(0, 6),
                                          ),
                                        ],
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

                            // ---- Google / Apple ----
                            Row(
                              children: [
                                Expanded(
                                  child: _SocialButton(
                                    label: 'Google',
                                    glyph: const _GoogleGlyph(),
                                    onTap: _isLoading
                                        ? null
                                        : () => _socialSignIn('Google'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _SocialButton(
                                    label: 'Apple',
                                    glyph: Icon(Icons.apple,
                                        size: 20, color: p.ink),
                                    onTap: _isLoading
                                        ? null
                                        : () => _socialSignIn('Apple'),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 14),

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF56B4FA)
                .withValues(alpha: isDark ? 0.45 : 0.22),
            blurRadius: 54,
            spreadRadius: -8,
          ),
        ],
      ),
      child: Image.asset(
        // White panes read on navy; navy panes on the light palette.
        isDark
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                      : isDark
                          // The mockup's field outline is a faint blue, not a
                          // white hairline — keeps the fields readable on navy.
                          ? p.primary.withValues(alpha: 0.30)
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

/// Outlined social sign-in button (Google / Apple).
class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.glyph,
    required this.onTap,
  });

  final String label;
  final Widget glyph;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.sheColors;
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          side: BorderSide(color: p.borderStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            glyph,
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Google "G" mark (single-colour, matching the Google brand blue).
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'G',
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w800,
        color: Color(0xFF4285F4),
      ),
    );
  }
}
