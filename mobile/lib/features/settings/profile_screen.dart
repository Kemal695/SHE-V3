// =============================================================================
// SHE V3 — Profile screen
// =============================================================================
// Replaces the Settings row that was `enabled: false` with the subtitle
// "Not available yet". Everything shown here comes from GET /api/v3/auth/me —
// there is no invented data:
//
//   user:   id, email, full_name, phone_number, preferred_language,
//           platform_role, tenant_role, mfa_enabled, created_at
//   tenant: id, name, subdomain, plan, status
//
// The avatar is a generated monogram (there is no avatar column on the server
// and no image-picker dependency), and its accent colour is a local preference.
// "Change password" calls the real POST /api/v3/auth/change-password.
//
// Ported from the desktop repo. The desktop addresses colours through
// `context.v3` (V3Palette); this build bridges that via v3_palette_shim.dart
// onto the working app's V3Colors getters, so the screen is otherwise verbatim.
// =============================================================================

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers/profile_provider.dart';
import '../../core/storage/settings_store.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/theme/v3_palette_shim.dart';
import '../auth/auth_service.dart';

// ---- Avatar accent (local-only preference) ----

/// Swatches offered for the monogram. Deliberately none of the forbidden
/// indigo/violet hues from V3-DESIGN-SYSTEM §1.
const List<Color> _avatarPalette = [
  Color(0xFF1D70B8), // royal blue (brand)
  Color(0xFF0E7490), // teal
  Color(0xFF047857), // emerald
  Color(0xFFB45309), // amber
  Color(0xFFBE123C), // rose
  Color(0xFF475569), // slate
];

final avatarColorIndexProvider =
    NotifierProvider<AvatarColorController, int>(AvatarColorController.new);

class AvatarColorController extends Notifier<int> {
  @override
  int build() => SettingsStore.avatarColorIndex;

  Future<void> select(int index) async {
    if (state != index) state = index;
    await SettingsStore.setAvatarColorIndex(index);
  }
}

// =============================================================================

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.v3;
    final meAsync = ref.watch(meProvider);

    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: c.textPrimary),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/dashboard'),
        ),
        title: const Text('Profile'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(meProvider.future),
          color: c.primary,
          child: meAsync.when(
            loading: () => _loading(c),
            error: (err, _) => _error(context, ref, c, err),
            data: (data) => _content(context, ref, c, data),
          ),
        ),
      ),
    );
  }

  Widget _loading(V3PaletteShim c) => ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                CircularProgressIndicator(color: c.primary, strokeWidth: 3),
                const SizedBox(height: V3Spacing.lg),
                Text('Loading your profile...',
                    style: TextStyle(color: c.textSecondary)),
              ],
            ),
          ),
        ],
      );

  Widget _error(BuildContext context, WidgetRef ref, V3PaletteShim c, Object err) {
    return ListView(
      padding: const EdgeInsets.all(V3Spacing.lg),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.cloud_off_outlined, size: 48, color: c.textSecondary),
        const SizedBox(height: V3Spacing.md),
        Text(
          'Could not load your profile',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: c.textPrimary,
              fontSize: V3Typography.titleSize,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: V3Spacing.sm),
        Text(
          err is AuthException ? err.message : err.toString(),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textSecondary, fontSize: V3Typography.labelSize),
        ),
        const SizedBox(height: V3Spacing.lg),
        Center(
          child: TextButton.icon(
            onPressed: () => ref.invalidate(meProvider),
            icon: Icon(Icons.refresh, color: c.primary),
            label: Text('Retry', style: TextStyle(color: c.primary)),
          ),
        ),
      ],
    );
  }

  Widget _content(
    BuildContext context,
    WidgetRef ref,
    V3PaletteShim c,
    Map<String, dynamic> data,
  ) {
    final user = _map(data['user']);
    final tenant = _map(data['tenant']);

    final fullName = _str(user['full_name']);
    final email = _str(user['email']);
    final avatarIndex = ref.watch(avatarColorIndexProvider);
    final accent = _avatarPalette[avatarIndex % _avatarPalette.length];

    return ListView(
      padding: const EdgeInsets.only(bottom: V3Spacing.xl),
      children: [
        _header(context, ref, c, fullName, email, tenant, accent),

        _sectionHeader(c, 'Account'),
        _InfoRow(
          icon: Icons.badge_outlined,
          label: 'Username',
          value: fullName ?? '—',
          hint: fullName == null ? 'Not set on this account' : null,
        ),
        _InfoRow(
          icon: Icons.alternate_email,
          label: 'Email',
          value: email ?? '—',
        ),
        _InfoRow(
          icon: Icons.phone_outlined,
          label: 'Phone number',
          value: _str(user['phone_number']) ?? '—',
        ),
        _InfoRow(
          icon: Icons.translate,
          label: 'Preferred language',
          value: _language(_str(user['preferred_language'])),
        ),
        _InfoRow(
          icon: Icons.event_outlined,
          label: 'Member since',
          value: _formatDate(_str(user['created_at'])),
        ),
        _InfoRow(
          icon: Icons.fingerprint,
          label: 'User ID',
          value: _str(user['id']) ?? '—',
          monospace: true,
        ),

        _sectionHeader(c, 'Security'),
        _InfoRow(
          icon: Icons.security,
          label: 'Two-factor authentication',
          value: user['mfa_enabled'] == true ? 'Enabled' : 'Disabled',
          valueColor: user['mfa_enabled'] == true ? c.success : c.textSecondary,
          hint: user['mfa_enabled'] == true
              ? null
              : 'Available in a later release',
        ),
        ListTile(
          leading: _iconBubble(c, Icons.lock_outline, c.primary),
          title: Text('Change password',
              style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w500)),
          subtitle: Text('Update the password used to sign in',
              style: TextStyle(
                  color: c.textSecondary, fontSize: V3Typography.captionSize)),
          trailing: Icon(Icons.chevron_right, color: c.textSecondary),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const ChangePasswordDialog(),
          ),
        ),

        _sectionHeader(c, 'Organisation'),
        _InfoRow(
          icon: Icons.apartment_outlined,
          label: 'Tenant',
          value: _str(tenant['name']) ?? '—',
        ),
        _InfoRow(
          icon: Icons.workspace_premium_outlined,
          label: 'Plan',
          value: _prettify(_str(tenant['plan'])),
        ),
        _InfoRow(
          icon: Icons.verified_outlined,
          label: 'Tenant status',
          value: _prettify(_str(tenant['status'])),
          valueColor: (_str(tenant['status']) ?? '').toUpperCase() == 'ACTIVE'
              ? c.success
              : null,
        ),
        _InfoRow(
          icon: Icons.admin_panel_settings_outlined,
          label: 'Your role',
          value: _prettify(_str(user['tenant_role']) ?? _str(user['platform_role'])),
        ),

        const Divider(indent: 16, endIndent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              V3Spacing.lg, V3Spacing.md, V3Spacing.lg, 0),
          child: Text(
            'Account details are managed by your home administrator and cannot '
            'be edited from this screen.',
            style: TextStyle(
                color: c.textSecondary,
                fontSize: V3Typography.captionSize,
                height: 1.5),
          ),
        ),
      ],
    );
  }

  // ---- Header: monogram avatar + identity ----

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    V3PaletteShim c,
    String? fullName,
    String? email,
    Map<String, dynamic> tenant,
    Color accent,
  ) {
    final initials = _initials(fullName, email);
    final image = ref.watch(profileImageProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          V3Spacing.lg, V3Spacing.lg, V3Spacing.lg, V3Spacing.sm),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => _showAvatarSheet(context, ref, c),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (image != null)
                  ClipOval(
                    child: Image.memory(
                      image!,
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [accent, Color.lerp(accent, Colors.black, 0.28)!],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: c.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.background, width: 2),
                    ),
                    child: Icon(Icons.camera_alt_outlined, size: 15, color: c.primary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: V3Spacing.md),
          Text(
            fullName ?? _localPart(email) ?? 'Signed in',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: c.textPrimary,
                fontSize: V3Typography.titleSize,
                fontWeight: FontWeight.w600),
          ),
          if (email != null && fullName != null) ...[
            const SizedBox(height: V3Spacing.xs),
            Text(
              email,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: c.textSecondary, fontSize: V3Typography.labelSize),
            ),
          ],
          const SizedBox(height: V3Spacing.md),
          Wrap(
            spacing: V3Spacing.sm,
            runSpacing: V3Spacing.xs,
            alignment: WrapAlignment.center,
            children: [
              if (_str(tenant['plan']) != null)
                _chip(c, Icons.workspace_premium_outlined,
                    '${_prettify(_str(tenant['plan']))} plan', c.primary),
              if (_str(tenant['subdomain']) != null)
                _chip(c, Icons.dns_outlined, _str(tenant['subdomain'])!, c.secondary),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndCrop(
    BuildContext context,
    WidgetRef ref,
    ImageSource source,
  ) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;
    if (!context.mounted) return;
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => ProfileCropScreen(path: picked.path),
      ),
    );
    if (bytes == null) return;
    await SettingsStore.setProfileImage(bytes);
    ref.read(profileImageProvider.notifier).state = bytes;
  }

  void _showAvatarSheet(BuildContext context, WidgetRef ref, V3PaletteShim c) {
    final hasImage = ref.read(profileImageProvider) != null;
    showModalBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(sheet);
                _pickAndCrop(context, ref, ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(sheet);
                _pickAndCrop(context, ref, ImageSource.camera);
              },
            ),
            if (hasImage)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove photo'),
                onTap: () async {
                  await SettingsStore.setProfileImage(null);
                  ref.read(profileImageProvider.notifier).state = null;
                  if (context.mounted) Navigator.pop(sheet);
                },
              ),
            ListTile(
              leading: Icon(Icons.palette_outlined, color: c.primary),
              title: const Text('Avatar colour'),
              onTap: () {
                Navigator.pop(sheet);
                _pickAvatarColor(context, ref, c);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _pickAvatarColor(BuildContext context, WidgetRef ref, V3PaletteShim c) {
    final current = ref.read(avatarColorIndexProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(V3Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Avatar colour',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: V3Typography.titleSize,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: V3Spacing.xs),
              Text(
                'Your initials are shown on a colour of your choice. This is '
                'stored on this device.',
                style: TextStyle(
                    color: c.textSecondary, fontSize: V3Typography.captionSize),
              ),
              const SizedBox(height: V3Spacing.lg),
              Wrap(
                spacing: V3Spacing.md,
                runSpacing: V3Spacing.md,
                children: [
                  for (var i = 0; i < _avatarPalette.length; i++)
                    GestureDetector(
                      onTap: () {
                        ref.read(avatarColorIndexProvider.notifier).select(i);
                        Navigator.of(sheetContext).pop();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _avatarPalette[i],
                          shape: BoxShape.circle,
                          border: i == current
                              ? Border.all(color: c.textPrimary, width: 3)
                              : null,
                        ),
                        child: i == current
                            ? const Icon(Icons.check, color: Colors.white, size: 20)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Small builders ----

  Widget _sectionHeader(V3PaletteShim c, String title) {
    return Padding(
      padding: const EdgeInsets.only(
          left: V3Spacing.lg, top: V3Spacing.lg, bottom: V3Spacing.xs),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: c.textSecondary,
          fontSize: V3Typography.overlineSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _iconBubble(V3PaletteShim c, IconData icon, Color color) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(V3Radius.full),
        ),
        child: Icon(icon, color: color, size: 20),
      );

  Widget _chip(V3PaletteShim c, IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(V3Radius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: V3Typography.captionSize,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// =============================================================================
// Change password
// =============================================================================

class ChangePasswordDialog extends ConsumerStatefulWidget {
  const ChangePasswordDialog({super.key});

  @override
  ConsumerState<ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _busy = false;
  bool _showCurrent = false;
  bool _showNew = false;
  String? _serverError;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      await ref.read(authServiceProvider).changePassword(
            currentPassword: _currentCtrl.text,
            newPassword: _newCtrl.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Password changed'),
          backgroundColor: context.v3.success,
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverError = 'Could not change the password: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.v3;
    return AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                c,
                controller: _currentCtrl,
                label: 'Current password',
                visible: _showCurrent,
                onToggle: () => setState(() => _showCurrent = !_showCurrent),
                validator: (v) => (v == null || v.isEmpty)
                    ? 'Enter your current password'
                    : null,
              ),
              const SizedBox(height: V3Spacing.md),
              _field(
                c,
                controller: _newCtrl,
                label: 'New password',
                visible: _showNew,
                onToggle: () => setState(() => _showNew = !_showNew),
                validator: _validateNewPassword,
              ),
              const SizedBox(height: V3Spacing.xs),
              Text(
                'At least 12 characters, with an uppercase letter, a lowercase '
                'letter, a digit and a symbol.',
                style: TextStyle(
                    color: c.textSecondary, fontSize: V3Typography.captionSize),
              ),
              const SizedBox(height: V3Spacing.md),
              _field(
                c,
                controller: _confirmCtrl,
                label: 'Confirm new password',
                visible: _showNew,
                onToggle: () => setState(() => _showNew = !_showNew),
                validator: (v) => v != _newCtrl.text
                    ? 'Passwords do not match'
                    : null,
              ),
              if (_serverError != null) ...[
                const SizedBox(height: V3Spacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(V3Spacing.sm),
                  decoration: BoxDecoration(
                    color: c.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(V3Radius.sm),
                  ),
                  child: Text(
                    _serverError!,
                    style: TextStyle(color: c.error, fontSize: V3Typography.captionSize),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(96, 44),
            backgroundColor: c.primary,
            foregroundColor: c.onPrimary,
          ),
          child: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.onPrimary),
                )
              : const Text('Update'),
        ),
      ],
    );
  }

  Widget _field(
    V3PaletteShim c, {
    required TextEditingController controller,
    required String label,
    required bool visible,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: !visible,
      enabled: !_busy,
      style: TextStyle(color: c.textPrimary),
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(visible ? Icons.visibility_off : Icons.visibility,
              color: c.textSecondary, size: 20),
          onPressed: onToggle,
        ),
      ),
    );
  }

  /// Mirrors the server's policy (min 12, upper, lower, digit, symbol) so the
  /// user is not told about a rule only after a round-trip. Character classes
  /// are checked by code unit rather than by RegExp.
  String? _validateNewPassword(String? value) {
    final v = value ?? '';
    if (v.length < 12) return 'Use at least 12 characters';
    if (!v.codeUnits.any((ch) => ch >= 65 && ch <= 90)) {
      return 'Add an uppercase letter';
    }
    if (!v.codeUnits.any((ch) => ch >= 97 && ch <= 122)) {
      return 'Add a lowercase letter';
    }
    if (!v.codeUnits.any((ch) => ch >= 48 && ch <= 57)) return 'Add a digit';
    final hasSymbol = v.codeUnits.any((ch) =>
        !((ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)));
    if (!hasSymbol) return 'Add a symbol';
    if (v == _currentCtrl.text) {
      return 'New password must differ from the current one';
    }
    return null;
  }
}

// =============================================================================
// Profile photo cropper
// =============================================================================
// After picking an image (gallery/camera) the user lands here to position it
// inside the circular avatar. Pinch to zoom, drag to reposition, then Save.
// The visible circular region is rasterised and returned as PNG bytes — so the
// stored picture is exactly what fits the frame (no "out of frame" surprise).
class ProfileCropScreen extends StatefulWidget {
  final String path;

  const ProfileCropScreen({super.key, required this.path});

  @override
  State<ProfileCropScreen> createState() => _ProfileCropScreenState();
}

class _ProfileCropScreenState extends State<ProfileCropScreen> {
  static const double _view = 280;
  final _boundary = GlobalKey();
  final _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final boundary =
          _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      if (mounted) Navigator.of(context).pop(bytes?.buffer.asUint8List());
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.v3;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.close, color: c.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Position photo'),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('Save', style: TextStyle(color: c.primary)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: RepaintBoundary(
                key: _boundary,
                child: ClipOval(
                  child: SizedBox(
                    width: _view,
                    height: _view,
                    child: InteractiveViewer(
                      transformationController: _controller,
                      minScale: 1,
                      maxScale: 4,
                      boundaryMargin: EdgeInsets.zero,
                      child: Image.file(
                        File(widget.path),
                        width: 360,
                        height: 360,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(V3Spacing.md),
            child: Text(
              'Pinch to zoom and drag to position your photo',
              style: TextStyle(
                  color: c.textSecondary, fontSize: V3Typography.captionSize),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Helpers
// =============================================================================

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

String? _str(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  return s.isEmpty ? null : s;
}

/// `TENANT_ADMIN` → `Tenant admin`, `B2C_PREMIUM` → `B2C premium`.
String _prettify(String? raw) {
  if (raw == null) return '—';
  final words = raw.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return raw;
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    out.add(i == 0
        ? w.substring(0, 1).toUpperCase() + w.substring(1).toLowerCase()
        : w.toLowerCase());
  }
  return out.join(' ');
}

String _language(String? code) {
  switch ((code ?? '').toLowerCase()) {
    case 'am':
      return 'አማርኛ (Amharic)';
    case 'en':
      return 'English';
    default:
      return code ?? '—';
  }
}

/// `2026-03-12T09:41:00Z` → `12 Mar 2026`. Hand-rolled so the profile page does
/// not need `intl`'s locale data initialised just to render one date.
String _formatDate(String? iso) {
  if (iso == null) return '—';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = dt.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

String? _localPart(String? email) {
  if (email == null) return null;
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at) : email;
}

/// `"Kemal Tadesse"` → `KT`, `"Kemal"` → `KE`, else the first letter of the
/// email local part, else `?`.
String _initials(String? fullName, String? email) {
  final name = (fullName ?? '').trim();
  if (name.isNotEmpty) {
    final parts = name.split(' ').where((p) => p.trim().isNotEmpty).toList();
    if (parts.length >= 2) {
      return (_firstLetter(parts.first) + _firstLetter(parts[1])).toUpperCase();
    }
    return name.length >= 2
        ? name.substring(0, 2).toUpperCase()
        : name.toUpperCase();
  }
  final local = _localPart(email);
  if (local != null && local.isNotEmpty) {
    return local.substring(0, 1).toUpperCase();
  }
  return '?';
}

String _firstLetter(String s) => s.isEmpty ? '' : s.substring(0, 1);

/// One label/value row. Long values (a UUID) wrap rather than overflow.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.valueColor,
    this.monospace = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? hint;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final c = context.v3;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(V3Radius.full),
        ),
        child: Icon(icon, color: c.primary, size: 20),
      ),
      title: Text(label,
          style: TextStyle(
              color: c.textSecondary, fontSize: V3Typography.captionSize)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? c.textPrimary,
              fontSize: V3Typography.labelSize,
              fontWeight: FontWeight.w500,
              fontFamily: monospace ? V3FontFamily.mono : null,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(hint!,
                  style: TextStyle(
                      color: c.textSecondary,
                      fontSize: V3Typography.captionSize)),
            ),
        ],
      ),
    );
  }
}
