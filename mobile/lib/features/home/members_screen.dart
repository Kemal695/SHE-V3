// =============================================================================
// SHE V3 — Home members screen
// =============================================================================
// V3-MOBILE-APP §5 (home sharing), V3-API-SPECIFICATION §4.
//
// Shows who can control a home, lets an admin invite by email, change a
// member's role, or remove them.
//
// The backend owns authorisation: it rejects roles outside
// OWNER|ADMIN|MEMBER|GUEST with 400, and refuses to grant OWNER to anyone who
// is not already an OWNER. So this screen never decides what is allowed —
// it renders whatever the server accepted and surfaces the server's message
// on failure.
//
// Note: AppLocalizations.of(context) is nullable (it returns null before the
// Localizations widget is mounted). Existing screens handle that with
// `l10n?.key ?? 'fallback'`, so this one does the same.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/she_theme.dart';
import '../../l10n/app_localizations.dart';
import 'home_members_service.dart';

/// Members of a single home. Invalidated after any mutation.
final homeMembersProvider = FutureProvider.family
    .autoDispose<List<Map<String, dynamic>>, String>((ref, homeId) async {
  return ref.watch(homeMembersServiceProvider).listMembers(homeId);
});

/// Localised label for a server role.
String roleLabel(AppLocalizations? l10n, String role) {
  switch (role) {
    case 'OWNER':
      return l10n?.roleOwner ?? 'Owner';
    case 'ADMIN':
      return l10n?.roleAdmin ?? 'Admin';
    case 'GUEST':
      return l10n?.roleGuest ?? 'Guest';
    default:
      return l10n?.roleMember ?? 'Member';
  }
}

class MembersScreen extends ConsumerStatefulWidget {
  final String homeId;

  const MembersScreen({super.key, required this.homeId});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  bool _busy = false;

  void _reload() => ref.invalidate(homeMembersProvider(widget.homeId));

  /// Pull the most useful message out of a Dio error.
  String _errorMessage(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final msg = data['message'] ?? data['error'];
        if (msg != null) return msg.toString();
      }
      return e.message ?? e.type.toString();
    }
    return e.toString();
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? SheTheme.error : SheTheme.success,
      ),
    );
  }

  Future<void> _addMember() async {
    final l10n = AppLocalizations.of(context);
    final emailController = TextEditingController();
    String role = 'MEMBER';
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setLocal) => AlertDialog(
              backgroundColor: SheTheme.lighterNavy,
              title: Text(l10n?.addMember ?? 'Add Member',
                  style: const TextStyle(color: SheTheme.textPrimary)),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: SheTheme.textPrimary),
                      decoration: InputDecoration(
                        labelText: l10n?.email ?? 'Email',
                        hintText: l10n?.memberEmailHint ?? 'member@example.com',
                        labelStyle:
                            const TextStyle(color: SheTheme.textSecondary),
                      ),
                      validator: (v) {
                        final value = v?.trim() ?? '';
                        if (value.isEmpty) {
                          return l10n?.emailRequired ?? 'Email is required';
                        }
                        if (!value.contains('@') || !value.contains('.')) {
                          return l10n?.emailInvalid ??
                              'Enter a valid email address';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: role,
                      dropdownColor: SheTheme.lighterNavy,
                      style: const TextStyle(color: SheTheme.textPrimary),
                      decoration: InputDecoration(
                        labelText: l10n?.role ?? 'Role',
                        labelStyle:
                            const TextStyle(color: SheTheme.textSecondary),
                      ),
                      // OWNER is deliberately not offered: the server only lets
                      // an existing OWNER grant it, so exposing it here would
                      // just produce 400s.
                      items: kHomeRoles
                          .where((r) => r != 'OWNER')
                          .map((r) => DropdownMenuItem(
                                value: r,
                                child: Text(roleLabel(l10n, r)),
                              ))
                          .toList(),
                      onChanged: (v) => setLocal(() => role = v ?? 'MEMBER'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l10n?.cancel ?? 'Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (formKey.currentState?.validate() ?? false) {
                      Navigator.pop(ctx, true);
                    }
                  },
                  child: Text(l10n?.addMember ?? 'Add Member'),
                ),
              ],
            ),
          ),
        ) ??
        false;

    if (!confirmed) return;
    final email = emailController.text.trim();

    setState(() => _busy = true);
    try {
      await ref.read(homeMembersServiceProvider).addMember(
            widget.homeId,
            email: email,
            role: role,
          );
      _reload();
      _snack(l10n?.memberAdded(email) ?? '$email added');
    } catch (e) {
      _snack(_errorMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeRole(Map<String, dynamic> member, String newRole) async {
    final l10n = AppLocalizations.of(context);
    final userId = member['user_id']?.toString() ?? '';
    if (userId.isEmpty) return;
    try {
      await ref.read(homeMembersServiceProvider).updateMemberRole(
            widget.homeId,
            userId,
            role: newRole,
          );
      _reload();
      _snack(l10n?.memberRoleUpdated ?? 'Role updated');
    } catch (e) {
      _snack(_errorMessage(e), isError: true);
      _reload(); // resync — the server may have a different view than we do
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final l10n = AppLocalizations.of(context);
    final userId = member['user_id']?.toString() ?? '';
    final email = member['email']?.toString() ?? userId;
    if (userId.isEmpty) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: SheTheme.lighterNavy,
            title: Text(l10n?.removeMemberTitle ?? 'Remove member',
                style: const TextStyle(color: SheTheme.textPrimary)),
            content: Text(
              l10n?.removeMemberConfirm(email) ?? 'Remove $email from this home?',
              style: const TextStyle(color: SheTheme.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n?.cancel ?? 'Cancel'),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: SheTheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n?.remove ?? 'Remove'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    try {
      await ref
          .read(homeMembersServiceProvider)
          .removeMember(widget.homeId, userId);
      _reload();
      _snack(l10n?.memberRemoved ?? 'Member removed');
    } catch (e) {
      _snack(_errorMessage(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final membersAsync = ref.watch(homeMembersProvider(widget.homeId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.members ?? 'Members'),
        backgroundColor: SheTheme.deepNavy,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : _addMember,
        backgroundColor: SheTheme.brightSkyBlue,
        child: const Icon(Icons.person_add),
      ),
      body: membersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: SheTheme.error, size: 48),
                const SizedBox(height: 12),
                Text(
                  '${l10n?.error ?? 'Error'}: ${_errorMessage(e)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: SheTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          ),
        ),
        data: (members) {
          if (members.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.group_outlined,
                        size: 56, color: SheTheme.textMuted),
                    const SizedBox(height: 12),
                    Text(l10n?.noMembers ?? 'No members yet',
                        style:
                            const TextStyle(color: SheTheme.textPrimary)),
                    const SizedBox(height: 6),
                    Text(
                      l10n?.noMembersHint ??
                          'Invite someone by email to share control of this home.',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: SheTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: members.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final member = members[i];
              final currentRole =
                  (member['role']?.toString() ?? 'MEMBER').toUpperCase();
              return _MemberTile(
                member: member,
                currentRole: currentRole,
                onRoleChanged: (r) => _changeRole(member, r),
                onRemove: () => _removeMember(member),
              );
            },
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final Map<String, dynamic> member;
  final String currentRole;
  final void Function(String) onRoleChanged;
  final VoidCallback onRemove;

  const _MemberTile({
    required this.member,
    required this.currentRole,
    required this.onRoleChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = member['full_name']?.toString() ?? '';
    final email = member['email']?.toString() ?? '';
    final initial =
        (name.isNotEmpty ? name[0] : (email.isNotEmpty ? email[0] : '?'))
            .toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: SheTheme.lighterNavy,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: SheTheme.brightSkyBlue.withValues(alpha: 0.18),
            child: Text(initial,
                style: const TextStyle(color: SheTheme.brightSkyBlue)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : email,
                  style: const TextStyle(
                      color: SheTheme.textPrimary,
                      fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                if (name.isNotEmpty && email.isNotEmpty)
                  Text(
                    email,
                    style: const TextStyle(
                        color: SheTheme.textSecondary, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: currentRole,
            dropdownColor: SheTheme.lighterNavy,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: SheTheme.brightSkyBlue, fontSize: 13),
            items: kHomeRoles
                .map((r) => DropdownMenuItem(
                      value: r,
                      child: Text(roleLabel(l10n, r)),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null && v != currentRole) onRoleChanged(v);
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_remove_outlined,
                color: SheTheme.textMuted),
            tooltip: l10n?.remove ?? 'Remove',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
