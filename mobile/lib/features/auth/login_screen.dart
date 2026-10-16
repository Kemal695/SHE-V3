// =============================================================================
// SHE V3 — Login Screen (V3-UI-REDESIGN)
// =============================================================================
// Rebuilt to match the prototype's `Login` panel (screens/auth.tsx):
//   small glowing logo tile -> "Welcome back" + subtitle -> labelled fields ->
//   forgot-password link -> primary button -> "or" divider -> Google/Apple ->
//   register link.
//
// PRESERVED from the previous implementation (do not remove):
//   * _submit() -> authServiceProvider.login(), then context.go('/dashboard').
//   * Validators.validateEmail / the required-password check.
//   * _parseError() mapping (401 / 429 / socket) to human messages.
//   * PopScope(canPop: false) so Back exits instead of popping to splash.
//   * The Server settings entry point — it is the ONLY way to fix a wrong
//     server URL before you have a session, because /settings sits behind the
//     auth redirect.
//   * Keyboard safety: resizeToAvoidBottomInset + a scrollable, min-height
//     body so nothing overflows when the keyboard is up.
//
// The Google/Apple buttons are intentionally INERT placeholders: there is no
// OAuth backend, and pretending otherwise would be a dead end for the user.
// They are styled and labelled exactly as the prototype shows them.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/network/base_url_provider.dart';
import '../../l10n/app_localizations.dart';
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
    final l = AppLocalizations.of(context)!;

    return PopScope(
      // On login screen, back button exits the app
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Prevent navigating back — stay on login
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: V3Colors.background,
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

                          // ---- Logo + wordmark ----
                          const _LoginBrand(),

                          const SizedBox(height: 36),

                          // ---- Heading ----
                          Text(
                            l.welcomeBack,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: V3Colors.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l.signInSubtitle,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: V3Colors.text2,
                            ),
                          ),

                          const SizedBox(height: 28),

                          // ---- Form ----
                          Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Email
                                _FieldLabel(l.emailOrPhone),
                                const SizedBox(height: 6),
                                _LoginField(
                                  controller: _emailCtrl,
                                  icon: Icons.mail_outline,
                                  hint: l.emailHint,
                                  enabled: !_isLoading,
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  validator: Validators.validateEmail,
                                ),
                                const SizedBox(height: 16),

                                // Password
                                _FieldLabel(l.password),
                                const SizedBox(height: 6),
                                _LoginField(
                                  controller: _passwordCtrl,
                                  icon: Icons.lock_outline,
                                  hint: '••••••••',
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
                                    color: V3Colors.dim,
                                    onPressed: () => setState(() =>
                                        _obscurePassword = !_obscurePassword),
                                  ),
                                ),

                                // Error
                                if (_errorMessage != null) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    _errorMessage!,
                                    style:  TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: V3Colors.errorAlt,
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 10),

                                // Forgot password (inert — no reset flow yet)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    l.forgotPassword,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: V3Colors.primary,
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 16),

                                // ---- Primary button ----
                                SizedBox(
                                  height: 50,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: V3Colors.primary,
                                      borderRadius:
                                          BorderRadius.circular(V3Radius.lg),
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(
                                            V3Radius.lg),
                                        onTap: _isLoading ? null : _submit,
                                        child: Center(
                                          child: _isLoading
                                              ?  SizedBox(
                                                  height: 22,
                                                  width: 22,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: V3Colors.night,
                                                  ),
                                                )
                                              : Text(
                                                  l.login,
                                                  style:  TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w600,
                                                    color: V3Colors.night,
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

                          const SizedBox(height: 20),

                          // ---- or divider ----
                          Row(
                            children: [
                              Expanded(
                                child: Divider(
                                  height: 1,
                                  color: V3Colors.border,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  l.or,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: V3Colors.dim,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Divider(
                                  height: 1,
                                  color: V3Colors.border,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // ---- Social (placeholders, no OAuth backend) ----
                          Row(
                            children: [
                              Expanded(
                                child: _SocialButton(
                                  label: l.google,
                                  glyph: const _GoogleGlyph(),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _SocialButton(
                                  label: l.apple,
                                  glyph: const _AppleGlyph(),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 28),

                          // ---- Register ----
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  l.noAccount,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: V3Colors.text2,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: _isLoading
                                      ? null
                                      : () => context.go('/register'),
                                  child: Text(
                                    l.register,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: V3Colors.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // ---- Server settings ----
                          // Reachable WITHOUT a session on purpose: if the server
                          // URL is wrong you cannot log in, and the Settings screen
                          // is behind the auth redirect — so this is the only way
                          // to recover.
                          Center(
                            child: TextButton.icon(
                              onPressed: () =>
                                  showServerSettingsDialog(context, ref),
                              icon: const Icon(Icons.dns, size: 16),
                              style: TextButton.styleFrom(
                                foregroundColor: V3Colors.dim,
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: V3Spacing.sm,
                                  vertical: V3Spacing.xs,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              label: Text(
                                'Server: ${ref.watch(apiBaseUrlProvider)}',
                                style: const TextStyle(fontSize: 12),
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
    );
  }
}

// -----------------------------------------------------------------------------
// Brand block — 64px glowing tile + wordmark (prototype's Login header)
// -----------------------------------------------------------------------------
class _LoginBrand extends StatelessWidget {
  const _LoginBrand();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: V3Colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: V3Colors.primary.withValues(alpha: 0.30),
            ),
            boxShadow: [
              BoxShadow(
                color: V3Colors.primary.withValues(alpha: 0.50),
                blurRadius: 40,
                spreadRadius: -8,
              ),
            ],
          ),
          child:  Icon(
            Icons.wifi_tethering,
            size: 34,
            color: V3Colors.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Smart Home Ethiopia',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: V3Colors.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'SHE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3 * 10,
            color: V3Colors.dim,
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: V3Colors.text2,
      ),
    );
  }
}

/// Rounded, label-less input row matching the prototype's field chrome.
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
    return FormField<String>(
      validator: validator,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      builder: (state) {
        final hasError = state.hasError;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: V3Colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hasError
                      ? V3Colors.errorAlt.withValues(alpha: 0.6)
                      : V3Colors.borderStrong,
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: V3Colors.dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: controller,
                      obscureText: obscure,
                      enabled: enabled,
                      keyboardType: keyboardType,
                      textInputAction: textInputAction,
                      onFieldSubmitted: onSubmitted,
                      onChanged: state.didChange,
                      cursorColor: V3Colors.primary,
                      style: TextStyle(
                        fontSize: 14,
                        color: V3Colors.ink,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: hint,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: V3Colors.dim,
                        ),
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
                style:  TextStyle(
                  fontSize: 12,
                  color: V3Colors.errorAlt,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({required this.label, required this.glyph});

  final String label;
  final Widget glyph;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: V3Colors.borderStrong),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          glyph,
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: V3Colors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Google "G" mark, four-colour paths as drawn in the prototype.
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 16, height: 16, child: CustomPaint(painter: _GooglePainter()));
}

class _GooglePainter extends CustomPainter {
  const _GooglePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Simplified but faithful: four coloured quadrants around a white core.
    final s = size.width;
    final p = Paint()..style = PaintingStyle.fill;
    canvas.drawArc(Rect.fromLTWH(0, 0, s, s), 3.5, 1.1, true,
        p..color = const Color(0xFFEA4335));
    canvas.drawArc(Rect.fromLTWH(0, 0, s, s), 4.6, 1.4, true,
        p..color = const Color(0xFF4285F4));
    canvas.drawArc(Rect.fromLTWH(0, 0, s, s), 6.0, 1.2, true,
        p..color = const Color(0xFFFBBC05));
    canvas.drawArc(Rect.fromLTWH(0, 0, s, s), 0.0, 3.5, true,
        p..color = const Color(0xFF34A853));
    canvas.drawCircle(Offset(s / 2, s / 2), s * 0.26,
        p..color = V3Colors.surface);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AppleGlyph extends StatelessWidget {
  const _AppleGlyph();

  @override
  Widget build(BuildContext context) => Icon(
        Icons.apple,
        size: 17,
        color: V3Colors.ink,
      );
}
