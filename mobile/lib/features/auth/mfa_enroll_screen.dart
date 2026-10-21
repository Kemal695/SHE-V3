import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/voice/voice_log.dart';
import 'auth_service.dart';

/// Two-factor authentication (TOTP) enrolment and management.
///
/// Flow, which matches the backend and V3-SECURITY-MODEL §6:
///   1. [AuthService.mfaEnroll]  — generates a secret, returns an otpauth:// URI
///   2. user scans the QR (or types the secret) into Google Authenticator /
///      Authy / Aegis / 1Password
///   3. [AuthService.mfaConfirm] — verifies one code, enables MFA and returns
///      8 recovery codes, shown ONCE
///
/// The QR is rendered from the otpauth URI by any authenticator app; we show the
/// secret as text too, because the phone may not have a second screen to scan
/// with, and a typo'd secret is a locked-out account.
class MfaEnrollScreen extends ConsumerStatefulWidget {
  const MfaEnrollScreen({super.key});

  @override
  ConsumerState<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

enum _Stage { loading, off, enrolling, enabled }

class _MfaEnrollScreenState extends ConsumerState<MfaEnrollScreen> {
  _Stage _stage = _Stage.loading;

  String? _secret;
  String? _otpAuthUri;
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();

  List<String> _recoveryCodes = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _stage = _Stage.loading);
    try {
      final enabled = await ref.read(authServiceProvider).mfaStatus();
      if (!mounted) return;
      setState(() => _stage = enabled ? _Stage.enabled : _Stage.off);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.off;
        _error = 'Could not read 2FA status: $e';
      });
    }
  }

  Future<void> _startEnroll() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await ref.read(authServiceProvider).mfaEnroll();
      if (!mounted) return;
      setState(() {
        _secret = data['secret'] as String?;
        _otpAuthUri = data['otp_auth_uri'] as String?;
        _stage = _Stage.enrolling;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your authenticator app');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final codes = await ref.read(authServiceProvider).mfaConfirm(code);
      if (!mounted) return;
      setState(() {
        _stage = _Stage.enabled;
        _recoveryCodes = codes;
      });
    } catch (e) {
      // Logged as well as shown: a hang and a rejection look identical on
      // screen, and logcat is the only way to tell them apart.
      debugPrint('MfaEnrollScreen._confirm failed: $e');
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Turns a DioException into something a user can act on.
  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('AUTH_MFA_INVALID') ||
        text.contains('did not match')) {
      return 'That code did not match. Check your phone\'s clock, then try the '
          'next code.';
    }
    if (text.contains('MFA_NOT_ENROLLED') || text.contains('Start enrolment')) {
      return 'Start the setup again — the setup key expired.';
    }
    if (text.contains('MFA_ALREADY_ENABLED')) {
      return 'Two-factor authentication is already on.';
    }
    if (text.contains('TimeoutException') ||
        text.contains('timeout') ||
        text.contains('taking too long')) {
      return 'The server did not respond in time. Check that the backend is '
          'running, then try again.';
    }
    return text;
  }

  Future<void> _disable() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your password to turn 2FA off');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).mfaDisable(password);
      if (!mounted) return;
      setState(() {
        _stage = _Stage.off;
        _recoveryCodes = const [];
        _passwordController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-Factor Authentication')),
      body: ListView(
        padding: const EdgeInsets.all(V3Spacing.lg),
        children: [
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(V3Spacing.md),
              decoration: BoxDecoration(
                color: V3Colors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(V3Radius.md),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: V3Colors.error, fontSize: 13),
              ),
            ),
            const SizedBox(height: V3Spacing.md),
          ],

          if (_stage == _Stage.loading)
            const Padding(
              padding: EdgeInsets.all(V3Spacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),

          if (_stage == _Stage.off) _offBody(),
          if (_stage == _Stage.enrolling) _enrollBody(),
          if (_stage == _Stage.enabled) _enabledBody(),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------

  Widget _offBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Add a second step when you sign in',
          style: TextStyle(
            color: V3Colors.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
        Text(
          'You will be asked for a 6-digit code from an authenticator app '
          '(Google Authenticator, Authy, Aegis or 1Password) in addition to '
          'your password.',
          style: TextStyle(color: V3Colors.textSecondary, height: 1.5),
        ),
        const SizedBox(height: V3Spacing.lg),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : _startEnroll,
            child: const Text('Set up two-factor authentication'),
          ),
        ),
      ],
    );
  }

  Widget _enrollBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1. Add the secret to your authenticator app',
          style: TextStyle(
            color: V3Colors.ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
        Text(
          'Scan the QR code, or type this setup key manually:',
          style: TextStyle(color: V3Colors.textSecondary, height: 1.5),
        ),
        const SizedBox(height: V3Spacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            color: V3Colors.surface,
            borderRadius: BorderRadius.circular(V3Radius.md),
          ),
          child: SelectableText(
            _secret ?? '',
            style: TextStyle(
              color: V3Colors.ink,
              fontSize: 15,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _secret ?? ''));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Setup key copied')),
              );
            },
            icon:  Icon(Icons.copy, size: 16),
            label: const Text('Copy setup key'),
          ),
        ),

        const SizedBox(height: V3Spacing.md),
        Text(
          '2. Enter the 6-digit code it now shows',
          style: TextStyle(
            color: V3Colors.ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: '6-digit code',
            counterText: '',
          ),
        ),
        const SizedBox(height: V3Spacing.md),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            // The spinner matters: without it a slow request looks identical to
            // a dead button, and "pressed Verify and it hangs" is what the user
            // reports either way.
            onPressed: _busy ? null : _confirm,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify and turn on'),
          ),
        ),
      ],
    );
  }

  Widget _enabledBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.verified_user, color: V3Colors.success),
            const SizedBox(width: V3Spacing.sm),
            Text(
              'Two-factor authentication is ON',
              style: TextStyle(
                color: V3Colors.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),

        // Recovery codes are shown exactly once, here.
        if (_recoveryCodes.isNotEmpty) ...[
          const SizedBox(height: V3Spacing.lg),
          Container(
            padding: const EdgeInsets.all(V3Spacing.md),
            decoration: BoxDecoration(
              color: V3Colors.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(V3Radius.md),
              border: Border.all(
                color: V3Colors.warning.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Save these recovery codes now',
                  style: TextStyle(
                    color: V3Colors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'They are the only way back in if you lose your phone. '
                  'They will not be shown again.',
                  style: TextStyle(
                    color: V3Colors.textSecondary,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: V3Spacing.sm),
                ..._recoveryCodes.map(
                  (c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      c,
                      style: TextStyle(
                        color: V3Colors.ink,
                        fontFamily: 'monospace',
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: V3Spacing.xl),
        Text(
          'Turn off two-factor authentication',
          style: TextStyle(
            color: V3Colors.ink,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
        Text(
          'Your password is required, so a stolen unlocked phone cannot '
          'quietly remove the second factor.',
          style: TextStyle(color: V3Colors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: V3Spacing.sm),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: V3Spacing.md),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _busy ? null : _disable,
            child: const Text('Turn off'),
          ),
        ),
      ],
    );
  }
}
