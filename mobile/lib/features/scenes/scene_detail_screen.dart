// =============================================================================
// SHE V3 — Scene Detail (design sheet screen 16)
// =============================================================================
// Layout ported from the sheet: back + scene name, a hero photo, the scene's
// description, the list of devices it drives (with the value it sets), and a
// full-width Activate button.
//
// DATA NOTE
// ---------
// `SceneAction` carries only a `nodeDeviceId` UUID — the API returns no device
// name with the actions. So the device list resolves names through
// `homeDeviceLookupProvider` and degrades to the raw id if the lookup fails
// (offline, or the device was removed after the scene was authored).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/node_service.dart';
import 'scene_service.dart';

/// Resolves the user's first home — needed to look device names up.
final _sceneHomeIdProvider = FutureProvider<String>((ref) async {
  try {
    final homes = await ref.read(nodeServiceProvider).listHomes();
    if (homes.isEmpty) return '';
    return (homes.first['id'] ?? homes.first['home_id'])?.toString() ?? '';
  } catch (_) {
    return '';
  }
});

class SceneDetailScreen extends ConsumerStatefulWidget {
  const SceneDetailScreen({super.key, required this.sceneId});

  final String sceneId;

  @override
  ConsumerState<SceneDetailScreen> createState() => _SceneDetailScreenState();
}

class _SceneDetailScreenState extends ConsumerState<SceneDetailScreen> {
  bool _busy = false;

  Future<void> _activate(Scene scene) async {
    setState(() => _busy = true);
    try {
      final result = await ref.read(sceneServiceProvider).activate(scene.id);
      if (!mounted) return;
      final msg = result.failed.isEmpty
          ? '${scene.name} activated · ${result.acceptedCount} device(s)'
          : '${result.acceptedCount} ok · ${result.failed.length} failed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor:
              result.failed.isEmpty ? V3Colors.surface2 : V3Colors.errorAlt,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not activate ${scene.name}: $e'),
          backgroundColor: V3Colors.errorAlt,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sceneByIdProvider(widget.sceneId));
    final homeId = ref.watch(_sceneHomeIdProvider).valueOrNull ?? '';
    final devices =
        ref.watch(homeDeviceLookupProvider(homeId)).valueOrNull ?? const {};

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        bottom: false,
        child: async.when(
          loading: () => Column(
            children: [
              SHEAppBar(title: '…', onBack: () => context.pop()),
              const Padding(
                padding: EdgeInsets.all(V3Spacing.md),
                child: SHESkeleton(height: 180),
              ),
            ],
          ),
          error: (e, _) => Column(
            children: [
              SHEAppBar(
                title: l?.scenesRowTitle ?? 'Scene',
                onBack: () => context.pop(),
              ),
              Expanded(
                child: SHEEmptyState(
                  icon: Icons.cloud_off,
                  tone: V3Colors.warningAlt,
                  title: 'Cannot load this scene',
                  body: '$e',
                  actionLabel: 'Retry',
                  onAction: () =>
                      ref.invalidate(sceneByIdProvider(widget.sceneId)),
                ),
              ),
            ],
          ),
          data: (scene) {
            if (scene == null) {
              return Column(
                children: [
                  SHEAppBar(
                    title: l?.scenesRowTitle ?? 'Scene',
                    onBack: () => context.pop(),
                  ),
                  Expanded(
                    child: SHEEmptyState(
                      icon: Icons.auto_awesome_outlined,
                      tone: V3Colors.dim,
                      title: 'Scene not found',
                      body: 'It may have been deleted. Pull back to refresh the list.',
                      actionLabel: 'Back to Scenes',
                      onAction: () => context.pop(),
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                SHEAppBar(
                  title: scene.name,
                  onBack: () => context.pop(),
                ),
                Expanded(
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: V3Spacing.md),
                    children: [
                      _Hero(scene: scene),
                      const SizedBox(height: V3Spacing.lg),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: V3Spacing.md),
                        child: SHESectionHeader(
                          title: l?.device ?? 'Devices',
                          action: '${scene.actionCount}',
                        ),
                      ),
                      const SizedBox(height: V3Spacing.sm),
                      if (scene.actions.isEmpty)
                         Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: V3Spacing.md),
                          child: Text(
                            'This scene has no actions yet. Edit it to add devices.',
                            style: TextStyle(
                              color: V3Colors.dim,
                              fontSize: V3Typography.body,
                            ),
                          ),
                        )
                      else
                        for (final a in scene.actions)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                V3Spacing.md, 0, V3Spacing.md, 10),
                            child: _ActionRow(
                              action: a,
                              device: devices[a.nodeDeviceId],
                            ),
                          ),
                    ],
                  ),
                ),

                // ---- Activate ----
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.md),
                  child: SHEButton(
                    label: l?.activate ?? 'Activate',
                    icon: Icons.play_arrow,
                    loading: _busy,
                    onPressed: _busy ? null : () => _activate(scene),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Hero photo with a navy scrim so the title stays readable on any image.
class _Hero extends StatelessWidget {
  const _Hero({required this.scene});

  final Scene scene;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: SizedBox(
          height: 168,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/img/living-room.png',
                fit: BoxFit.cover,
                // A missing/broken asset must not blank the screen — fall back
                // to the brand gradient so the hero still reads as a hero.
                errorBuilder: (_, __, ___) =>  DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [V3Colors.heroTop, V3Colors.heroBottom],
                    ),
                  ),
                ),
              ),
               DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, V3Colors.night],
                    stops: [0.35, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: V3Spacing.md,
                right: V3Spacing.md,
                bottom: V3Spacing.md,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      scene.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:  TextStyle(
                        color: V3Colors.ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _summary(scene),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:  TextStyle(
                        color: V3Colors.text2,
                        fontSize: V3Typography.body,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Reads like the sheet's caption, e.g. "Turns on 3 devices."
  String _summary(Scene s) {
    if (s.actions.isEmpty) return 'No devices set yet.';
    final turningOn = s.actions
        .where((a) => a.paramName == 'Power' && a.value == true)
        .length;
    final turningOff = s.actions
        .where((a) => a.paramName == 'Power' && a.value == false)
        .length;
    if (turningOn == s.actions.length) {
      return 'Turns on ${s.actions.length} device${s.actions.length == 1 ? '' : 's'}.';
    }
    if (turningOff == s.actions.length) {
      return 'Turns off ${s.actions.length} device${s.actions.length == 1 ? '' : 's'}.';
    }
    return 'Sets ${s.actions.length} device${s.actions.length == 1 ? '' : 's'}.';
  }
}

/// One device the scene drives, with the value it sets.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action, required this.device});

  final SceneAction action;

  /// Null when the device could not be resolved (removed, or offline lookup).
  final DeviceLookup? device;

  @override
  Widget build(BuildContext context) {
    final name = device?.name ?? action.nodeDeviceId;
    // Reuse the same kind vocabulary as the Devices tab so a light shows a
    // lightbulb here too.
    final kind = _kindFrom(device?.kind ?? '', name);
    final isOn = action.paramName == 'Power' && action.value == true;

    return SHECard(
      padding: const EdgeInsets.all(12),
      raised: isOn,
      child: Row(
        children: [
          DeviceIcon(kind: kind, on: isOn, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:  TextStyle(
                color: V3Colors.ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: V3Spacing.sm),
          Text(
            _valueLabel(action),
            style: TextStyle(
              color: isOn ? V3Colors.primary : V3Colors.text2,
              fontSize: V3Typography.meta,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// "On" / "Off" / "100%" / "22°C" — the value the scene writes.
  String _valueLabel(SceneAction a) {
    final v = a.value;
    if (v == true) return 'On';
    if (v == false) return 'Off';
    if (v is num) {
      if (a.paramName.toLowerCase().contains('temp')) return '$v°C';
      if (a.paramName.toLowerCase().contains('bright')) return '$v%';
      return '$v';
    }
    return v?.toString() ?? '—';
  }

  /// Same name-keyword logic the Devices tab and dashboard use.
  ///
  /// The firmware registers every relay channel as `esp.device.switch`, so the
  /// type alone cannot tell a light from a socket — the channel name is what
  /// distinguishes them. Keep in step with `_kindFromDeviceType` in
  /// devices_screen.dart and `_kindFromType` in dashboard_screen.dart.
  static String _kindFrom(String type, String name) {
    if (type.contains('lightbulb')) return 'light';
    if (type.contains('fan')) return 'appliance';
    if (type.contains('temp_sensor')) return 'climate';
    if (type.contains('energy_meter')) return 'meter';

    final n = name.toLowerCase();
    if (n.contains('socket') || n.contains('outlet') || n.contains('plug')) {
      return 'outlet';
    }
    if (n.contains('light') || n.contains('lamp')) return 'light';
    if (n.contains('fan')) return 'appliance';
    if (n.contains('gate') || n.contains('door')) return 'gate';
    if (n.contains('pump') || n.contains('irrigation') || n.contains('water')) {
      return 'irrigation';
    }
    if (n.contains('camera')) return 'camera';
    if (n.contains('tv')) return 'tv';
    if (n.contains('meter')) return 'meter';
    if (type.contains('switch') || type.contains('relay')) return 'outlet';
    if (type.contains('sensor')) return 'sensor';
    return 'generic';
  }
}
