// =============================================================================
// SHE V3 — Scenes management (list / create / edit / delete / activate)
// =============================================================================
// Backend: SceneController (V3-API-SPECIFICATION §8.1).
//
// Until now there was no way to author a scene from the app: the dashboard could
// only list and activate, and the backend had no controller at all. This screen
// closes that gap — pick a device, choose on/off, save.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import 'scene_service.dart';

class ScenesScreen extends ConsumerStatefulWidget {
  final String homeId;

  const ScenesScreen({super.key, required this.homeId});

  @override
  ConsumerState<ScenesScreen> createState() => _ScenesScreenState();
}

class _ScenesScreenState extends ConsumerState<ScenesScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(homeScenesProvider(widget.homeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(apiErrorMessage(e)),
          backgroundColor: V3Colors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(Scene scene) async {
    final result = await ref.read(sceneServiceProvider).activate(scene.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isFullSuccess
              ? '${scene.name} on · ${result.acceptedCount} device(s) updated'
              : '${scene.name} partly applied · ${result.acceptedCount} ok, '
                  '${result.failed.length} failed',
        ),
        backgroundColor: result.isFullSuccess ? V3Colors.success : V3Colors.warning,
      ),
    );
  }

  Future<void> _confirmDelete(Scene scene) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: V3Colors.surface,
            title: const Text('Delete scene?',
                style: TextStyle(color: V3Colors.textPrimary)),
            content: Text('This removes "${scene.name}". Devices are not changed.',
                style: const TextStyle(color: V3Colors.textSecondary)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete',
                    style: TextStyle(color: V3Colors.error)),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;
    await _run(() => ref.read(sceneServiceProvider).deleteScene(scene.id));
  }

  @override
  Widget build(BuildContext context) {
    final scenesAsync = ref.watch(homeScenesProvider(widget.homeId));

    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        backgroundColor: V3Colors.background,
        title: const Text('Scenes',
            style: TextStyle(color: V3Colors.textPrimary)),
        iconTheme: const IconThemeData(color: V3Colors.textSecondary),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: V3Colors.primary,
        onPressed: _busy ? null : () => _openEditor(context, null),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: scenesAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: V3Colors.primary),
        ),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Text('Could not load scenes: $err',
                style: const TextStyle(color: V3Colors.textSecondary)),
          ),
        ),
        data: (scenes) {
          if (scenes.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(V3Spacing.xl),
                child: Text(
                  'No scenes yet.\nTap + to create one — pick a device and choose on or off.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: V3Colors.textSecondary),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: scenes.length,
            itemBuilder: (context, i) {
              final scene = scenes[i];
              // Expandable — collapsed shows the summary, expanding reveals
              // the action row (Activate / Edit / Delete) hidden per the user's
              // request. Same surface card so it reads identically to the
              // dashboard device cards.
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: V3Spacing.md, vertical: V3Spacing.xs),
                child: Material(
                  color: V3Colors.surface,
                  borderRadius:
                      BorderRadius.circular(V3Radius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    iconColor: V3Colors.textSecondary,
                    collapsedIconColor: V3Colors.textSecondary,
                    tilePadding: const EdgeInsets.symmetric(
                        horizontal: V3Spacing.md),
                    leading: const Icon(Icons.auto_awesome,
                        color: V3Colors.primary),
                    title: Text(scene.name,
                        style: const TextStyle(
                            color: V3Colors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text('${scene.actionCount} action(s)',
                        style: const TextStyle(
                            color: V3Colors.textSecondary, fontSize: 12)),
                    childrenPadding: const EdgeInsets.fromLTRB(
                        V3Spacing.md, 0, V3Spacing.sm, V3Spacing.sm),
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.play_arrow,
                                color: V3Colors.success),
                            tooltip: 'Activate',
                            onPressed:
                                _busy ? null : () => _activate(scene),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined,
                                color: V3Colors.textSecondary),
                            tooltip: 'Edit',
                            onPressed: _busy
                                ? null
                                : () => _openEditor(context, scene),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: V3Colors.error),
                            tooltip: 'Delete',
                            onPressed: _busy
                                ? null
                                : () => _confirmDelete(scene),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, Scene? existing) async {
    final result = await showDialog<_EditorResult>(
      context: context,
      builder: (ctx) => _SceneEditorDialog(homeId: widget.homeId, existing: existing),
    );
    if (result == null || !mounted) return;

    await _run(() async {
      if (existing == null) {
        await ref.read(sceneServiceProvider).createScene(
              widget.homeId,
              name: result.name,
              icon: result.icon,
              actions: result.actions,
            );
      } else {
        await ref.read(sceneServiceProvider).updateScene(
              existing.id,
              name: result.name,
              icon: result.icon,
              actions: result.actions,
            );
      }
    });
  }
}

class _EditorResult {
  final String name;
  final String? icon;
  final List<SceneActionDraft> actions;

  _EditorResult({
    required this.name,
    this.icon,
    required this.actions,
  });
}

/// Create/edit a scene: name + one on/off choice per device.
class _SceneEditorDialog extends ConsumerStatefulWidget {
  final String homeId;
  final Scene? existing;

  const _SceneEditorDialog({required this.homeId, this.existing});

  @override
  ConsumerState<_SceneEditorDialog> createState() => _SceneEditorDialogState();
}

class _SceneEditorDialogState extends ConsumerState<_SceneEditorDialog> {
  late final TextEditingController _nameCtrl;
  // device key (nodeId|deviceName) -> desired Power value. Absent = not part of the scene.
  final Map<String, bool> _selected = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String _key(SceneDeviceOption d) => '${d.nodeId}|${d.deviceName}';

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(homeDevicesProvider(widget.homeId));

    return AlertDialog(
      backgroundColor: V3Colors.surface,
      title: Text(
        widget.existing == null ? 'New scene' : 'Edit scene',
        style: const TextStyle(color: V3Colors.textPrimary),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: V3Colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Scene name',
                  labelStyle:
                      const TextStyle(color: V3Colors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    borderSide:
                        const BorderSide(color: V3Colors.textSecondary),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    borderSide: const BorderSide(
                        color: V3Colors.primary, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: V3Spacing.md),
              const Text(
                'Devices',
                style: TextStyle(
                    color: V3Colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: V3Spacing.xs),
              devicesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(V3Spacing.md),
                  child:
                      CircularProgressIndicator(color: V3Colors.primary),
                ),
                error: (e, _) => Text('Could not load devices: $e',
                    style: const TextStyle(color: V3Colors.error)),
                data: (devices) {
                  if (devices.isEmpty) {
                    return const Text('No devices found in this home.',
                        style: TextStyle(color: V3Colors.textSecondary));
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: devices.map((d) {
                      final k = _key(d);
                      final included = _selected.containsKey(k);
                      return CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(d.label,
                            style: const TextStyle(
                                color: V3Colors.textPrimary,
                                fontSize: 14)),
                        value: included,
                        activeColor: V3Colors.primary,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected[k] = true; // default to "on"
                          } else {
                            _selected.remove(k);
                          }
                        }),
                        secondary: included
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Off',
                                      style: TextStyle(
                                          color: V3Colors.textSecondary,
                                          fontSize: 11)),
                                  Switch(
                                    value: _selected[k] ?? true,
                                    activeColor: V3Colors.primary,
                                    onChanged: (v) => setState(
                                        () => _selected[k] = v),
                                  ),
                                  const Text('On',
                                      style: TextStyle(
                                          color: V3Colors.textSecondary,
                                          fontSize: 11)),
                                ],
                              )
                            : null,
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: V3Colors.textSecondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: V3Colors.primary),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Save',
                  style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please give the scene a name')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final devices = await ref.read(homeDevicesProvider(widget.homeId).future);
      final byKey = {for (final d in devices) _key(d): d};

      final actions = _selected.entries.map((e) {
        final d = byKey[e.key]!;
        return SceneActionDraft(
          nodeId: d.nodeId,
          deviceName: d.deviceName,
          params: {'Power': e.value},
        );
      }).toList();

      if (!mounted) return;
      Navigator.pop(
        context,
        _EditorResult(
          name: name,
          icon: widget.existing?.icon ?? 'scene',
          actions: actions,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
