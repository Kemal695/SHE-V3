// =============================================================================
// SHE V3 — My commands (user-defined voice commands)
// =============================================================================
// Create your own phrases: an alias ("socket one" -> turn on Socket 1) or a
// macro ("goodnight" -> turn off all lights).
//
// PRIVACY / LOCK MODEL
//  * The page can be gated by a PIN (Settings-less: the lock icon in the app
//    bar). When set, the list is invisible until the PIN is entered, so someone
//    holding the phone cannot read your phrases.
//  * Per command:
//      - hidden : not shown in the list unless "show hidden" is on.
//      - locked : the voice pipeline always asks "Do you want to run it?" before
//                 executing, even if the phrase matched perfectly.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/active_home.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/v3_design_tokens.dart';
import '../../auth/auth_service.dart';
import '../application/command_executor.dart';
import '../data/custom_voice_store.dart';
import '../domain/custom_voice_command.dart';
import '../domain/voice_command.dart';

class CustomCommandsScreen extends ConsumerStatefulWidget {
  const CustomCommandsScreen({super.key});

  @override
  ConsumerState<CustomCommandsScreen> createState() =>
      _CustomCommandsScreenState();
}

class _CustomCommandsScreenState extends ConsumerState<CustomCommandsScreen> {
  bool _loading = true;
  bool _unlocked = false;
  bool _pinSet = false;
  bool _showHidden = false;
  bool _busy = false;

  List<VoiceDevice> _devices = const [];
  List<VoiceGroup> _groups = const [];
  List<VoiceScene> _scenes = const [];
  List<VoiceAutomation> _automations = const [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final pin = await SecureStorage.getCommandPin();
    final homeId = await resolveActiveHomeId(ref);
    if (homeId != null) {
      try {
        final ctx = await ref.read(commandExecutorProvider).loadContext(homeId);
        _devices = ctx.devices;
        _groups = ctx.groups;
        _scenes = ctx.scenes;
        _automations = ctx.automations;
      } catch (_) {
        // Pickers stay empty; the user can still create class commands.
      }
    }
    if (!mounted) return;
    setState(() {
      _pinSet = pin != null && pin.isNotEmpty;
      _unlocked = !_pinSet;
      _loading = false;
    });
  }

  Future<String?> _askPin(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _unlock() async {
    final pin = await SecureStorage.getCommandPin();
    final entered = await _askPin('Enter PIN');
    if (entered == null) return;
    if (entered == pin) {
      if (mounted) setState(() => _unlocked = true);
    } else {
      _toast('Wrong PIN');
    }
  }

  Future<void> _setPin() async {
    final current = await SecureStorage.getCommandPin();
    if (current != null && current.isNotEmpty) {
      final entered = await _askPin('Current PIN');
      if (entered != current) {
        _toast('Wrong PIN');
        return;
      }
    }
    if (!mounted) return;
    final next = await _askPin('New PIN (empty to remove)');
    if (next == null) return;
    if (next.isEmpty) {
      await SecureStorage.clearCommandPin();
    } else {
      await SecureStorage.saveCommandPin(next);
    }
    if (!mounted) return;
    setState(() {
      _pinSet = next.isNotEmpty;
      _unlocked = true;
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _edit([CustomVoiceCommand? existing]) async {
    final result = await showDialog<CustomVoiceCommand>(
      context: context,
      builder: (_) => _CommandEditorDialog(
        existing: existing,
        devices: _devices,
        groups: _groups,
        scenes: _scenes,
        automations: _automations,
      ),
    );
    if (result == null) return;
    final notifier = ref.read(customCommandsProvider.notifier);
    if (existing == null) {
      notifier.add(result);
    } else {
      notifier.update(result);
    }
  }

  String _summary(CustomVoiceCommand c) {
    switch (c.action) {
      case 'turnOn':
        return 'Turn on ${c.deviceName ?? '?'}';
      case 'turnOff':
        return 'Turn off ${c.deviceName ?? '?'}';
      case 'turnOnGroup':
        return 'Turn on ${c.groupName ?? 'group'}';
      case 'turnOffGroup':
        return 'Turn off ${c.groupName ?? 'group'}';
      case 'turnAllOn':
        return 'Turn on all ${c.group ?? 'devices'}';
      case 'turnAllOff':
        return 'Turn off all ${c.group ?? 'devices'}';
      case 'activateScene':
        return 'Run a scene';
      case 'runAutomation':
        return 'Run an automation';
      case 'enableAutomation':
        return 'Enable an automation';
      case 'disableAutomation':
        return 'Disable an automation';
      default:
        return c.action;
    }
  }

  @override
  Widget build(BuildContext context) {
    final commands = ref.watch(customCommandsProvider);

    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        backgroundColor: V3Colors.background,
        title: const Text('My commands'),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: _pinSet ? 'Change PIN' : 'Set PIN',
            onPressed: _unlocked ? _setPin : null,
          ),
          IconButton(
            icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off),
            tooltip: 'Show hidden',
            onPressed:
                _unlocked ? () => setState(() => _showHidden = !_showHidden) : null,
          ),
        ],
      ),
      floatingActionButton: _unlocked
          ? FloatingActionButton(
              onPressed: () => _edit(),
              child: const Icon(Icons.add),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_unlocked
              ? _lockedBody()
              : _listBody(commands),
    );
  }

  Widget _lockedBody() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, color: V3Colors.primary, size: 48),
          const SizedBox(height: V3Spacing.md),
          Text(_busy ? 'Verifying…' : 'Locked',
              style: TextStyle(color: V3Colors.ink, fontSize: 16)),
          const SizedBox(height: V3Spacing.sm),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: V3Spacing.sm),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else ...[
            FilledButton(onPressed: _unlock, child: const Text('Unlock')),
            TextButton(
              onPressed: _resetPin,
              child: const Text('Forgot PIN? Reset'),
            ),
          ],
        ],
      ),
    );
  }

  /// Reset the PIN, but only after the caller proves they own the account by
  /// entering the account password.
  ///
  /// Uses /auth/verify-password, NOT /auth/login: a wrong password there does not
  /// consume a login attempt, so this can never lock the account out of the login
  /// screen (which is exactly what an earlier version of this flow did).
  Future<void> _resetPin() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _ResetPinDialog(),
    );
    if (password == null || password.isEmpty) return;

    setState(() => _busy = true);
    try {
      await ref.read(authServiceProvider).verifyPassword(password);
      await SecureStorage.clearCommandPin();
      if (!mounted) return;
      setState(() {
        _pinSet = false;
        _unlocked = true;
      });
      _toast('PIN removed');
    } catch (_) {
      _toast('Wrong password — PIN not reset');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _listBody(List<CustomVoiceCommand> commands) {
    final visible = commands.where((c) => _showHidden || !c.hidden).toList();
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(V3Spacing.lg),
          child: Text(
            'No custom commands yet.\nTap + to create one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: V3Colors.text2, fontSize: 13, height: 1.4),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(V3Spacing.md),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final c = visible[i];
        return Card(
          color: V3Colors.surface,
          margin: const EdgeInsets.only(bottom: V3Spacing.sm),
          child: ListTile(
            leading: Icon(
              c.enabled ? Icons.check_circle : Icons.pause_circle,
              color: c.enabled ? V3Colors.success : V3Colors.dim,
            ),
            title: Text(
              '"${c.phrase}"',
              style: TextStyle(
                  color: V3Colors.ink, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${_summary(c)}'
              '${c.hidden ? ' · hidden' : ''}'
              '${c.locked ? ' · locked' : ''}',
              style: TextStyle(color: V3Colors.text2, fontSize: 12.5),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                final n = ref.read(customCommandsProvider.notifier);
                switch (v) {
                  case 'edit':
                    _edit(c);
                    break;
                  case 'toggle':
                    n.update(c.copyWith(enabled: !c.enabled));
                    break;
                  case 'lock':
                    n.update(c.copyWith(locked: !c.locked));
                    break;
                  case 'hide':
                    n.update(c.copyWith(hidden: !c.hidden));
                    break;
                  case 'delete':
                    n.remove(c.id);
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(c.enabled ? 'Disable' : 'Enable'),
                ),
                PopupMenuItem(
                  value: 'lock',
                  child: Text(c.locked ? 'Unlock command' : 'Lock command'),
                ),
                PopupMenuItem(
                  value: 'hide',
                  child:
                      Text(c.hidden ? 'Show in list' : 'Hide from list'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
            onTap: () => _edit(c),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

class _CommandEditorDialog extends StatefulWidget {
  final CustomVoiceCommand? existing;
  final List<VoiceDevice> devices;
  final List<VoiceGroup> groups;
  final List<VoiceScene> scenes;
  final List<VoiceAutomation> automations;

  const _CommandEditorDialog({
    this.existing,
    required this.devices,
    required this.groups,
    required this.scenes,
    required this.automations,
  });

  @override
  State<_CommandEditorDialog> createState() => _CommandEditorDialogState();
}

class _CommandEditorDialogState extends State<_CommandEditorDialog> {
  late final TextEditingController _phrase;
  late String _action;
  String? _deviceName;
  String? _groupId;
  String? _sceneId;
  String? _automationId;
  late String _classGroup;
  late bool _enabled;
  late bool _hidden;
  late bool _locked;

  static const _actions = <String, String>{
    'turnOn': 'Turn ON a device',
    'turnOff': 'Turn OFF a device',
    'turnOnGroup': 'Turn ON a group',
    'turnOffGroup': 'Turn OFF a group',
    'turnAllOn': 'Turn ON all',
    'turnAllOff': 'Turn OFF all',
    'activateScene': 'Run a scene',
    'runAutomation': 'Run an automation',
    'enableAutomation': 'Enable an automation',
    'disableAutomation': 'Disable an automation',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _phrase = TextEditingController(text: e?.phrase ?? '');
    _action = e?.action ?? 'turnOn';
    _deviceName = e?.deviceName;
    _groupId = e?.groupId;
    _sceneId = e?.sceneId;
    _automationId = e?.automationId;
    _classGroup = e?.group ?? 'all';
    _enabled = e?.enabled ?? true;
    _hidden = e?.hidden ?? false;
    _locked = e?.locked ?? false;
  }

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  bool get _needsDevice => _action == 'turnOn' || _action == 'turnOff';
  bool get _needsGroup => _action == 'turnOnGroup' || _action == 'turnOffGroup';
  bool get _needsClass => _action == 'turnAllOn' || _action == 'turnAllOff';
  bool get _needsScene => _action == 'activateScene';
  bool get _needsAutomation =>
      _action == 'runAutomation' ||
      _action == 'enableAutomation' ||
      _action == 'disableAutomation';

  bool get _canSave {
    if (_phrase.text.trim().isEmpty) return false;
    if (_needsDevice) return _deviceName != null;
    if (_needsGroup) return _groupId != null;
    if (_needsScene) return _sceneId != null;
    if (_needsAutomation) return _automationId != null;
    return true;
  }

  void _save() {
    String? groupName;
    for (final g in widget.groups) {
      if (g.id == _groupId) {
        groupName = g.name;
        break;
      }
    }
    final cmd = CustomVoiceCommand(
      id: widget.existing?.id ?? 'cmd-${DateTime.now().microsecondsSinceEpoch}',
      phrase: _phrase.text.trim(),
      action: _action,
      deviceName: _needsDevice ? _deviceName : null,
      groupId: _needsGroup ? _groupId : null,
      groupName: _needsGroup ? groupName : null,
      sceneId: _needsScene ? _sceneId : null,
      automationId: _needsAutomation ? _automationId : null,
      group: _needsClass ? _classGroup : null,
      enabled: _enabled,
      hidden: _hidden,
      locked: _locked,
    );
    Navigator.pop(context, cmd);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New command' : 'Edit command'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _phrase,
              decoration: const InputDecoration(
                labelText: 'Say',
                hintText: 'e.g. goodnight',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: V3Spacing.sm),
            DropdownButtonFormField<String>(
              initialValue: _actions.containsKey(_action) ? _action : 'turnOn',
              decoration: const InputDecoration(labelText: 'Do this'),
              items: [
                for (final e in _actions.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _action = v ?? _action),
            ),
            if (_needsDevice) ...[
              const SizedBox(height: V3Spacing.sm),
              DropdownButtonFormField<String>(
                initialValue: widget.devices
                        .any((d) => d.deviceName == _deviceName)
                    ? _deviceName
                    : null,
                decoration: const InputDecoration(labelText: 'Device'),
                items: [
                  for (final d in widget.devices)
                    DropdownMenuItem(value: d.deviceName, child: Text(d.label)),
                ],
                onChanged: (v) => setState(() => _deviceName = v),
              ),
            ],
            if (_needsGroup) ...[
              const SizedBox(height: V3Spacing.sm),
              DropdownButtonFormField<String>(
                initialValue:
                    widget.groups.any((g) => g.id == _groupId) ? _groupId : null,
                decoration: const InputDecoration(labelText: 'Group'),
                items: [
                  for (final g in widget.groups)
                    DropdownMenuItem(value: g.id, child: Text(g.name)),
                ],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ],
            if (_needsClass) ...[
              const SizedBox(height: V3Spacing.sm),
              DropdownButtonFormField<String>(
                initialValue: _classGroup,
                decoration: const InputDecoration(labelText: 'Scope'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('Everything')),
                  DropdownMenuItem(value: 'lights', child: Text('Lights')),
                  DropdownMenuItem(value: 'sockets', child: Text('Sockets')),
                ],
                onChanged: (v) => setState(() => _classGroup = v ?? 'all'),
              ),
            ],
            if (_needsScene) ...[
              const SizedBox(height: V3Spacing.sm),
              DropdownButtonFormField<String>(
                initialValue:
                    widget.scenes.any((s) => s.id == _sceneId) ? _sceneId : null,
                decoration: const InputDecoration(labelText: 'Scene'),
                items: [
                  for (final s in widget.scenes)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _sceneId = v),
              ),
            ],
            if (_needsAutomation) ...[
              const SizedBox(height: V3Spacing.sm),
              DropdownButtonFormField<String>(
                initialValue: widget.automations
                        .any((a) => a.id == _automationId)
                    ? _automationId
                    : null,
                decoration: const InputDecoration(labelText: 'Automation'),
                items: [
                  for (final a in widget.automations)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _automationId = v),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hidden (not shown in the list)'),
              value: _hidden,
              onChanged: (v) => setState(() => _hidden = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Locked (confirm before running)'),
              value: _locked,
              onChanged: (v) => setState(() => _locked = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// PIN reset — account verification
// ---------------------------------------------------------------------------

/// Asks for the account password to prove ownership before the PIN is cleared.
///
/// The account is identified by the access token, so only the password is needed.
/// Verification goes to /auth/verify-password, which does NOT consume a login
/// attempt — a wrong guess can never lock the account out of the login screen.
class _ResetPinDialog extends StatefulWidget {
  const _ResetPinDialog();

  @override
  State<_ResetPinDialog> createState() => _ResetPinDialogState();
}

class _ResetPinDialogState extends State<_ResetPinDialog> {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  bool get _canSubmit => _password.text.isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm it is you'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter your account password to reset the PIN. A wrong password '
            'will not lock you out.',
          ),
          const SizedBox(height: V3Spacing.sm),
          TextField(
            controller: _password,
            obscureText: _obscure,
            autocorrect: false,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Verify & reset'),
        ),
      ],
    );
  }
}
