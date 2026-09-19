// =============================================================================
// SHE V3 — Scenes Row (horizontal scrolling at top of dashboard)
// =============================================================================
// V3-DESIGN-SYSTEM §1.9 + V3-MOBILE-APP §4:
// "Scenes row: horizontal scroll at top (Good Morning / Leaving Home / Movie Night / +)"
// Scene activation: cards flash 200ms + stagger 300ms (V3-DESIGN-SYSTEM §1.10).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/v3_design_tokens.dart';

class ScenesRow extends StatefulWidget {
  final List<Map<String, dynamic>> scenes;
  final Function(String sceneId)? onActivate;

  const ScenesRow({
    super.key,
    required this.scenes,
    this.onActivate,
  });

  @override
  State<ScenesRow> createState() => _ScenesRowState();
}

class _ScenesRowState extends State<ScenesRow> {
  String? _activeSceneId;

  void _activate(String sceneId, String name) {
    // V3-DESIGN-SYSTEM §1.10: "Light tap" haptic on scene activate
    HapticFeedback.lightImpact();

    setState(() => _activeSceneId = sceneId);
    widget.onActivate?.call(sceneId);

    // Reset active state after animation
    Future.delayed(V3Duration.sceneStagger, () {
      if (mounted) setState(() => _activeSceneId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.scenes.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
        itemCount: widget.scenes.length + 1,  // +1 for the "+" button
        itemBuilder: (context, index) {
          if (index == widget.scenes.length) {
            return _AddSceneButton();
          }

          final scene = widget.scenes[index];
          final isActive = _activeSceneId == scene['id'];

          return GestureDetector(
            onTap: () => _activate(scene['id'], scene['name'] ?? ''),
            child: AnimatedContainer(
              duration: V3Duration.sceneFlash,
              curve: Curves.easeOut,
              margin: const EdgeInsets.only(right: V3Spacing.sm),
              padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md, vertical: V3Spacing.sm),
              decoration: BoxDecoration(
                color: isActive ? V3Colors.primary : V3Colors.surface,
                borderRadius: BorderRadius.circular(V3Radius.lg),
                border: Border.all(
                  color: isActive ? V3Colors.primary : V3Colors.textSecondary.withValues(alpha: 0.2),
                ),
                boxShadow: isActive ? V3Colors.activeGlow(isOn: true) : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _iconForScene(scene['icon'] ?? scene['name'] ?? ''),
                    size: 24,
                    color: isActive ? V3Colors.textPrimary : V3Colors.textSecondary,
                  ),
                  const SizedBox(width: V3Spacing.sm),
                  Text(
                    scene['name'] ?? 'Scene',
                    style: TextStyle(
                      color: isActive ? V3Colors.textPrimary : V3Colors.textSecondary,
                      fontSize: V3Typography.labelSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _iconForScene(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('morning') || lower.contains('ጥዋት')) return Icons.wb_sunny;
    if (lower.contains('leaving') || lower.contains('መውጣት')) return Icons.logout;
    if (lower.contains('movie') || lower.contains('ፊልም')) return Icons.movie;
    if (lower.contains('sleep') || lower.contains('እንቅልፍ')) return Icons.bedtime;
    if (lower.contains('night') || lower.contains('ሌሊት')) return Icons.nights_stay;
    if (lower.contains('home') || lower.contains('ቤት')) return Icons.home;
    return Icons.star;
  }
}

class _AddSceneButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // TODO: navigate to scene builder
      },
      child: Container(
        margin: const EdgeInsets.only(right: V3Spacing.sm),
        padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md, vertical: V3Spacing.sm),
        decoration: BoxDecoration(
          color: V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.lg),
          border: Border.all(
            color: V3Colors.textSecondary.withValues(alpha: 0.3),
            style: BorderStyle.solid,
          ),
        ),
        child: const Icon(Icons.add, color: V3Colors.textSecondary, size: 24),
      ),
    );
  }
}
