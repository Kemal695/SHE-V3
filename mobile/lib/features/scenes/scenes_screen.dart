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
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../device_detail/node_service.dart' show nodeServiceProvider;
import 'scene_icons.dart';
import 'scene_service.dart';

class ScenesScreen extends ConsumerStatefulWidget {
  final String homeId;

  const ScenesScreen({super.key, required this.homeId});

  @override
  ConsumerState<ScenesScreen> createState() => _ScenesScreenState();
}

class _ScenesScreenState extends ConsumerState<ScenesScreen> {
  bool _busy = false;

  /// The home the API calls use.
  ///
  /// Same trap as the Automations screen: the router feeds `homeId` from
  /// `state.uri.queryParameters['homeId']`, and only some entry points set it.
  /// Reached from anywhere else it is the empty string, the request goes out as
  /// `/api/v3/homes//scenes`, Spring collapses the double slash and binds the
  /// path segment to the literal text `"scenes"` -> `Invalid UUID string` -> 500.
  ///
  /// Resolved here exactly as `_DevicesScreenState` does it, so no entry point
  /// can produce a malformed URL.
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';

  late String _homeId;

  /// The scene most recently activated, so its card can show the "running"
  /// treatment. Local only — the backend has no notion of an active scene, and
  /// pretending otherwise would show a stale highlight after a restart.
  String? _activeId;

  @override
  void initState() {
    super.initState();
    final initial = widget.homeId;
    _homeId = initial.isNotEmpty ? initial : _defaultHomeId;
    if (initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
  }

  Future<void> _resolveHome() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (homes.isNotEmpty && mounted) {
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) setState(() => _homeId = id);
      }
    } catch (_) {
      // Keep the seeded default; the provider degrades to an empty list.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(homeScenesProvider(_homeId));
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
    setState(() => _activeId = scene.id);
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
            title:  Text('Delete scene?',
                style: TextStyle(color: V3Colors.textPrimary)),
            content: Text('This removes "${scene.name}". Devices are not changed.',
                style:  TextStyle(color: V3Colors.textSecondary)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:  Text('Delete',
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
    final scenesAsync = ref.watch(homeScenesProvider(_homeId));

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: scenesAsync.when(
          loading: () =>  Center(
            child: CircularProgressIndicator(color: V3Colors.primary),
          ),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(V3Spacing.xl),
              child: Text('Could not load scenes: $err',
                  textAlign: TextAlign.center,
                  style:  TextStyle(color: V3Colors.text2)),
            ),
          ),
          data: (scenes) => RefreshIndicator(
            color: V3Colors.primary,
            backgroundColor: V3Colors.surface,
            onRefresh: () =>
                ref.refresh(homeScenesProvider(_homeId).future),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const SliverToBoxAdapter(
                  child: SHEAppBar(
                    title: 'Scenes',
                    subtitle: 'One tap sets a whole mood',
                  ),
                ),
                if (_activeId != null)
                  SliverToBoxAdapter(child: _activeBanner(scenes)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                      V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.md),
                  sliver: SliverGrid(
                    // 2-up on phones (design sheet panel 11); 3-up on tablets
                    // and 4-up on foldables/desktop (audit screens #24/#25).
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount:
                          switch (V3Breakpoints.sizeClass(context)) {
                        V3SizeClass.compact => 2,
                        V3SizeClass.medium => 3,
                        V3SizeClass.expanded => 4,
                      },
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.02,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        if (i == scenes.length) return _createCard();
                        final scene = scenes[i];
                        return _sceneCard(scene, _activeId == scene.id);
                      },
                      childCount: scenes.length + 1,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        V3Spacing.lg, 0, V3Spacing.lg, V3Spacing.xxl),
                    child: Text(
                      'Scenes step through their devices 200 ms apart, so a room '
                      'changes gradually instead of all at once.',
                      textAlign: TextAlign.center,
                      style:  TextStyle(
                          color: V3Colors.dim, fontSize: 11, height: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Green "a scene is running" strip, as in the design.
  Widget _activeBanner(List<Scene> scenes) {
    final running = scenes.where((s) => s.id == _activeId).firstOrNull;
    if (running == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(V3Spacing.md, V3Spacing.sm, V3Spacing.md, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: V3Spacing.md, vertical: V3Spacing.sm),
      decoration: BoxDecoration(
        color: V3Colors.successAlt.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.successAlt.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:  BoxDecoration(
                color: V3Colors.successAlt, shape: BoxShape.circle),
          ),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Text(
              '${running.name} is running · ${running.actionCount} steps',
              style:  TextStyle(
                  color: V3Colors.successAlt,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sceneCard(Scene scene, bool active) {
    // Same contrast treatment as the dashboard's group tiles: a raised surface +
    // brand-tinted border + soft shadow when idle (a 6% hairline was invisible),
    // and a solid primary-tinted state when active.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: _busy ? null : () => _activate(scene),
      onLongPress: _busy ? null : () => _showSceneMenu(scene),
      child: Container(
        // Same as the dashboard group tile: the corner bloom sits outside the
        // card (-24/-32) and would otherwise paint a sharp square edge past the
        // rounded top-right corner.
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: active
              ? V3Colors.primary.withValues(alpha: isDark ? 0.22 : 0.13)
              : (isDark ? V3Colors.surface2 : V3Colors.surface),
          borderRadius: BorderRadius.circular(V3Radius.xl),
          border: Border.all(
            color: active
                ? V3Colors.primary.withValues(alpha: 0.75)
                : V3Colors.primary.withValues(alpha: isDark ? 0.18 : 0.22),
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: V3Colors.primary.withValues(alpha: 0.45),
                    blurRadius: 30,
                    spreadRadius: -6,
                  ),
                ]
              : [
                  BoxShadow(
                    color:
                        Colors.black.withValues(alpha: isDark ? 0.30 : 0.06),
                    blurRadius: isDark ? 20 : 14,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Stack(
          children: [
            // Soft radial accent in the corner — the design's glow.
            Positioned(
              right: -24,
              top: -32,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    V3Colors.primary
                        .withValues(alpha: active ? 0.34 : 0.16),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(V3Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: active
                          ? V3Colors.primary
                          : V3Colors.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(V3Radius.md),
                    ),
                    child: Icon(
                      _sceneIcon(scene.icon),
                      size: 22,
                      color: active ? V3Colors.night : V3Colors.primary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    scene.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                      color: V3Colors.ink,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${scene.actionCount} action(s)',
                    style:  TextStyle(
                        color: V3Colors.text2, fontSize: 11),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: PopupMenuButton<String>(
                enabled: !_busy,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert,
                    size: 18,
                    color: active ? V3Colors.primary : V3Colors.dim),
                color: V3Colors.surface2,
                onSelected: (v) {
                  switch (v) {
                    case 'activate':
                      _activate(scene);
                    case 'details':
                      context.push('/scenes/${scene.id}');
                    case 'edit':
                      _openEditor(context, scene);
                    case 'delete':
                      _confirmDelete(scene);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'activate', child: Text('Activate')),
                  PopupMenuItem(value: 'details', child: Text('Details')),
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSceneMenu(Scene scene) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: V3Colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:  Icon(Icons.play_arrow, color: V3Colors.successAlt),
              title: const Text('Activate'),
              onTap: () {
                Navigator.pop(ctx);
                _activate(scene);
              },
            ),
            ListTile(
              leading:  Icon(Icons.info_outline,
                  color: V3Colors.text2),
              title: const Text('Details'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/scenes/${scene.id}');
              },
            ),
            ListTile(
              leading:  Icon(Icons.edit_outlined, color: V3Colors.text2),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                _openEditor(context, scene);
              },
            ),
            ListTile(
              leading:  Icon(Icons.delete_outline,
                  color: V3Colors.errorAlt),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(scene);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _createCard() {
    return GestureDetector(
      onTap: _busy ? null : () => _openEditor(context, null),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(V3Radius.xl),
          border: Border.all(color: V3Colors.borderStrong),
        ),
        child:  Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 24, color: V3Colors.dim),
            SizedBox(height: 8),
            Text('Create Scene',
                style: TextStyle(
                    color: V3Colors.dim,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  /// Maps a stored icon name onto a Material glyph (see [kSceneIconChoices]).
  IconData _sceneIcon(String? name) => sceneIconFor(name);

  Future<void> _openEditor(BuildContext context, Scene? existing) async {
    final result = await showDialog<_EditorResult>(
      context: context,
      builder: (ctx) => _SceneEditorDialog(homeId: _homeId, existing: existing),
    );
    if (result == null || !mounted) return;

    await _run(() async {
      if (existing == null) {
        await ref.read(sceneServiceProvider).createScene(
              _homeId,
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

  /// The icon key being edited. Previously there was no picker and Save echoed
  /// `widget.existing?.icon`, so a scene's icon could never change.
  late String _icon;

  /// The existing actions are seeded once the device list arrives: the map key
  /// is `nodeId|deviceName`, which only a [SceneDeviceOption] knows.
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    final stored = widget.existing?.icon;
    _icon = (stored != null && kSceneIconChoices.containsKey(stored))
        ? stored
        : 'scene';
  }

  /// Seed the checkbox map from the scene being edited.
  ///
  /// Without this, opening "Edit scene" showed every device UNCHECKED and Save
  /// then replaced the scene's actions with an empty list — i.e. editing a
  /// scene silently wiped it.
  void _seedSelection(List<SceneDeviceOption> devices) {
    // Skip an empty list: it may just be the provider's first frame, and
    // marking seeded there would drop the real seeding when devices arrive.
    if (_seeded || devices.isEmpty) return;
    _seeded = true;
    final existing = widget.existing;
    if (existing == null) return;
    final byDeviceId = {for (final d in devices) d.deviceId: d};
    for (final a in existing.actions) {
      if (a.paramName != 'Power') continue;
      final d = byDeviceId[a.nodeDeviceId];
      if (d == null) continue;
      _selected[_key(d)] = a.value == true || a.value?.toString() == 'true';
    }
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
        style:  TextStyle(color: V3Colors.textPrimary),
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
                style:  TextStyle(color: V3Colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Scene name',
                  labelStyle:
                       TextStyle(color: V3Colors.textSecondary),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    borderSide:
                         BorderSide(color: V3Colors.textSecondary),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    borderSide:  BorderSide(
                        color: V3Colors.primary, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: V3Spacing.md),
               Text(
                'Icon',
                style: TextStyle(
                    color: V3Colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: V3Spacing.xs),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final entry in kSceneIconChoices.entries)
                    _IconChoice(
                      icon: entry.value,
                      selected: _icon == entry.key,
                      onTap: () => setState(() => _icon = entry.key),
                    ),
                ],
              ),
              const SizedBox(height: V3Spacing.md),
               Text(
                'Devices',
                style: TextStyle(
                    color: V3Colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: V3Spacing.xs),
              devicesAsync.when(
                loading: () =>  Padding(
                  padding: EdgeInsets.all(V3Spacing.md),
                  child:
                      CircularProgressIndicator(color: V3Colors.primary),
                ),
                error: (e, _) => Text('Could not load devices: $e',
                    style:  TextStyle(color: V3Colors.error)),
                data: (devices) {
                  _seedSelection(devices);
                  if (devices.isEmpty) {
                    return  Text('No devices found in this home.',
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
                            style:  TextStyle(
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
                                   Text('Off',
                                      style: TextStyle(
                                          color: V3Colors.textSecondary,
                                          fontSize: 11)),
                                  Switch(
                                    value: _selected[k] ?? true,
                                    activeColor: V3Colors.primary,
                                    onChanged: (v) => setState(
                                        () => _selected[k] = v),
                                  ),
                                   Text('On',
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
          child:  Text('Cancel',
              style: TextStyle(color: V3Colors.textSecondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: V3Colors.primary,
            // See app.dart: a local backgroundColor also overrides the disabled
            // colours, so a disabled button would still look live.
            disabledBackgroundColor: V3Colors.primary.withValues(alpha: 0.18),
            disabledForegroundColor:
                V3Colors.textSecondary.withValues(alpha: 0.5),
          ),
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
          icon: _icon,
          actions: actions,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// One tappable icon swatch in the scene editor's icon picker.
class _IconChoice extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: selected
              ? V3Colors.primary
              : V3Colors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(V3Radius.md),
          border: Border.all(
            color: selected
                ? V3Colors.primary
                : V3Colors.primary.withValues(alpha: 0.22),
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: selected ? V3Colors.night : V3Colors.primary,
        ),
      ),
    );
  }
}
