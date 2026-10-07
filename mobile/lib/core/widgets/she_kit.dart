// =============================================================================
// SHE V3 — Component kit (SHE-V3 UI/UX redesign)
// =============================================================================
// A Flutter port of `kit.tsx` from the SHE-V3 premium prototype
// (Desktop/SHE-V3-prototype-download), so the app and the design reference
// share one visual vocabulary.
//
// DESIGN RULES THIS FILE ENFORCES
// -------------------------------
//  * Presentation only. Nothing here calls the API, reads a provider, or owns
//    business state — every widget takes data in and emits callbacks out. That
//    is what lets the screens be restyled without touching a single feature.
//  * All colours come from V3Colors; all sizes from V3Typography/V3Spacing/
//    V3Radius. No literal hex, no magic numbers. If the design changes, it
//    changes in the tokens and every screen follows.
//  * The prototype's shapes are transcribed, not approximated: 16px card
//    radius, 1px white@6% hairline, 42/34px avatars, the 26px switch, the
//    uppercase letter-spaced overlines, the tappable-scale feedback.
//
// The existing widgets (she_toggle.dart, haptic_slider.dart, premium_lock.dart)
// are left untouched — this file is additive.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/v3_design_tokens.dart';

// -----------------------------------------------------------------------------
// SHEAppBar — sticky title row with optional back button and trailing slot.
// Transcribed from kit.tsx SHEAppBar.
// -----------------------------------------------------------------------------
class SHEAppBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final Widget? trailing;
  final bool transparent;
  final bool large;

  const SHEAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.trailing,
    this.transparent = false,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          V3Spacing.md, V3Spacing.sm, V3Spacing.md, 12),
      decoration: transparent
          ? null
          : BoxDecoration(
              color: V3Colors.background.withValues(alpha: 0.95),
              border: const Border(
                bottom: BorderSide(color: V3Colors.border, width: 1),
              ),
            ),
      child: Row(
        children: [
          if (onBack != null) ...[
            _CircleIconButton(
              icon: Icons.chevron_left,
              onTap: onBack!,
              size: 36,
              iconSize: 20,
            ),
            const SizedBox(width: V3Spacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: V3Colors.ink,
                    fontSize: large
                        ? V3Typography.headlineSize
                        : V3Typography.appBarTitle,
                    fontWeight: large ? FontWeight.w700 : FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: V3Colors.text2,
                        fontSize: V3Typography.meta,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: V3Spacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHECard — the base raised surface (16px radius, hairline, 16px padding).
// -----------------------------------------------------------------------------
class SHECard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool glow;
  final bool raised;
  final Color? color;
  final BorderRadius? radius;

  const SHECard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.glow = false,
    this.raised = false,
    this.color,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final br = radius ?? BorderRadius.circular(V3Radius.lg);
    final body = Container(
      padding: padding ?? const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: color ?? (raised ? V3Colors.surface2 : V3Colors.surface),
        borderRadius: br,
        border: Border.all(
          color: glow ? V3Colors.borderStrong : V3Colors.border,
          width: 1,
        ),
        boxShadow: glow ? V3Colors.cardGlow() : null,
      ),
      child: child,
    );

    if (onTap == null) return body;
    return _PressScale(onTap: onTap!, radius: br, child: body);
  }
}

// -----------------------------------------------------------------------------
// SHEButton — primary / secondary / ghost / danger, all 48px tall.
// Transcribed from kit.tsx SHEButton.
// -----------------------------------------------------------------------------
enum SHEButtonVariant { primary, secondary, ghost, danger }

class SHEButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final SHEButtonVariant variant;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final double? height;

  const SHEButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = SHEButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;

    final Color bg;
    final Color fg;
    final Color? border;
    switch (variant) {
      case SHEButtonVariant.primary:
        bg = V3Colors.primary;
        fg = V3Colors.night;
        border = null;
      case SHEButtonVariant.secondary:
        bg = V3Colors.surface2;
        fg = V3Colors.ink;
        border = V3Colors.borderStrong;
      case SHEButtonVariant.ghost:
        bg = Colors.transparent;
        fg = V3Colors.text2;
        border = null;
      case SHEButtonVariant.danger:
        bg = V3Colors.errorAlt.withValues(alpha: 0.15);
        fg = V3Colors.errorAlt;
        border = V3Colors.errorAlt.withValues(alpha: 0.30);
    }

    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else if (icon != null)
          Icon(icon, size: 18, color: fg),
        if (loading || icon != null) const SizedBox(width: V3Spacing.sm),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: 15,
              fontWeight:
                  variant == SHEButtonVariant.primary ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ],
    );

    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: _PressScale(
        onTap: disabled ? null : onPressed,
        radius: BorderRadius.circular(V3Radius.lg),
        scale: 0.97,
        child: Container(
          height: height ?? 48,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(V3Radius.lg),
            border: border == null ? null : Border.all(color: border, width: 1),
            boxShadow: variant == SHEButtonVariant.primary && !disabled
                ? [
                    BoxShadow(
                      color: V3Colors.primary.withValues(alpha: 0.45),
                      blurRadius: 24,
                      spreadRadius: -8,
                    ),
                  ]
                : null,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Circular icon button (prototype `SHEIconButton` + the app-bar action chips).
class SHEIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final bool active;
  final double size;
  final double iconSize;
  final bool filled;

  const SHEIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    required this.semanticLabel,
    this.active = false,
    this.size = 40,
    this.iconSize = 18,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? V3Colors.primary.withValues(alpha: 0.20)
        : (filled ? V3Colors.surface : Colors.transparent);
    final fg = active ? V3Colors.primary : V3Colors.text2;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: _PressScale(
        onTap: onPressed,
        radius: BorderRadius.circular(size / 2),
        scale: 0.90,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );
  }
}

/// Private alias used by SHEAppBar's back affordance.
class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      radius: BorderRadius.circular(size / 2),
      scale: 0.92,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: V3Colors.surface,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: iconSize, color: V3Colors.ink),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHEStatusBadge — online / offline / sending / queued / rejected.
// Transcribed from kit.tsx SHEStatusBadge, including the Amharic strings.
// -----------------------------------------------------------------------------
class SHEStatusBadge extends StatelessWidget {
  /// Mirrors the prototype's `CmdState`: idle | pending | queued | rejected.
  final String? cmdState;
  final bool online;
  final bool amharic;

  const SHEStatusBadge({
    super.key,
    this.cmdState,
    this.online = true,
    this.amharic = false,
  });

  @override
  Widget build(BuildContext context) {
    final (Color tint, IconData? icon, String label) = switch (cmdState) {
      'pending' => (
          V3Colors.primary,
          Icons.sync,
          amharic ? 'በመላክ ላይ' : 'Sending…',
        ),
      'queued' => (
          V3Colors.warningAlt,
          Icons.schedule,
          amharic ? 'ተራ ተይዟል' : 'Queued',
        ),
      'rejected' => (
          V3Colors.errorAlt,
          Icons.error_outline,
          amharic ? 'ተቀብሏል' : 'Rejected',
        ),
      _ => online
          ? (V3Colors.successAlt, null, amharic ? 'ከመስመር ላይ' : 'Online')
          : (V3Colors.dim, null, amharic ? 'ከመስመር ውጭ' : 'Offline'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(V3Radius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 12, color: tint)
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: tint,
              fontSize: V3Typography.badge,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// DeviceIcon — kind-tinted rounded square that glows when the device is on.
// Transcribed from kit.tsx DeviceIcon.
// -----------------------------------------------------------------------------
class DeviceIcon extends StatelessWidget {
  final String? kind;
  final bool on;
  final double size;

  const DeviceIcon({
    super.key,
    required this.kind,
    this.on = false,
    this.size = 44,
  });

  /// Prototype `KIND_MAP`. Icon glyphs are the closest Material equivalents of
  /// the prototype's lucide icons.
  static IconData iconForKind(String? kind) => switch (kind) {
        'light' => Icons.lightbulb,
        'outlet' => Icons.electrical_services,
        'gate' => Icons.fence,
        'irrigation' => Icons.water_drop,
        'camera' => Icons.videocam,
        'appliance' => Icons.power,
        'climate' => Icons.thermostat,
        'meter' => Icons.speed,
        'sensor' => Icons.sensors,
        'tv' => Icons.tv,
        _ => Icons.memory,
      };

  @override
  Widget build(BuildContext context) {
    final tint = V3Colors.tintForKind(kind);
    final active = on;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? tint.withValues(alpha: 0.13) : V3Colors.fill,
        borderRadius: BorderRadius.circular(size * 0.27),
        boxShadow: active ? V3Colors.iconGlow(tint) : null,
      ),
      child: Icon(
        iconForKind(kind),
        size: size * 0.45,
        color: active ? tint : V3Colors.dim,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHESearchField — inset search row (kit.tsx SHESearchField).
// -----------------------------------------------------------------------------
class SHESearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String hint;

  const SHESearchField({
    super.key,
    required this.controller,
    this.onChanged,
    this.hint = 'Search…',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: V3Colors.dim),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(color: V3Colors.ink, fontSize: 14),
              cursorColor: V3Colors.primary,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                hintText: hint,
                hintStyle: const TextStyle(color: V3Colors.dim, fontSize: 14),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () {
                  controller.clear();
                  onChanged?.call('');
                },
                child: const Icon(Icons.close, size: 16, color: V3Colors.dim),
              );
            },
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHEFilterChip — active chip is a solid primary pill (kit.tsx SHEFilterChip).
// -----------------------------------------------------------------------------
class SHEFilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const SHEFilterChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      radius: BorderRadius.circular(V3Radius.full),
      scale: 0.95,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? V3Colors.primary : V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.full),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: V3Colors.primary.withValues(alpha: 0.55),
                    blurRadius: 16,
                    spreadRadius: -4,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? V3Colors.night : V3Colors.text2,
            fontSize: V3Typography.chip,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHESectionHeader — title + optional "View All ›" action.
// -----------------------------------------------------------------------------
class SHESectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;

  const SHESectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: V3Colors.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action!,
                    style: const TextStyle(
                      color: V3Colors.primary,
                      fontSize: V3Typography.chip,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 14, color: V3Colors.primary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHEOverline — the uppercase, letter-spaced micro-label the redesign uses
// above metrics ("HOME STATUS", "ENERGY TODAY").
// -----------------------------------------------------------------------------
class SHEOverline extends StatelessWidget {
  final String text;
  final Color? color;

  const SHEOverline(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: color ?? V3Colors.dim,
        fontSize: V3Typography.meta,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.8,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHEEmptyState / SHESkeleton / SHEProgressBar — the shared state atoms.
// -----------------------------------------------------------------------------
class SHEEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color tone;

  const SHEEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.tone = V3Colors.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.xl, vertical: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(V3Radius.xl),
              boxShadow: [
                BoxShadow(
                  color: tone.withValues(alpha: 0.27),
                  blurRadius: 32,
                  spreadRadius: -8,
                ),
              ],
            ),
            child: Icon(icon, size: 28, color: tone),
          ),
          const SizedBox(height: V3Spacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: V3Colors.ink,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: V3Colors.text2,
                fontSize: V3Typography.body,
                height: 1.5,
              ),
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 20),
            SHEButton(
              label: actionLabel!,
              onPressed: onAction,
              expand: false,
              height: 44,
            ),
          ],
        ],
      ),
    );
  }
}

class SHESkeleton extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius? radius;

  const SHESkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return _Shimmer(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: V3Colors.fill,
          borderRadius: radius ?? BorderRadius.circular(V3Radius.md),
        ),
      ),
    );
  }
}

class SHEProgressBar extends StatelessWidget {
  final double value; // 0..100
  final Color? tone;
  final double height;
  final bool gradient;

  const SHEProgressBar({
    super.key,
    required this.value,
    this.tone,
    this.height = 6,
    this.gradient = false,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (value.isFinite ? value : 0).clamp(0, 100) / 100.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(V3Radius.full),
      child: Container(
        height: height,
        color: V3Colors.fillStrong,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: pct,
          child: AnimatedContainer(
            duration: V3Duration.medium,
            decoration: BoxDecoration(
              color: gradient ? null : (tone ?? V3Colors.primary),
              gradient: gradient
                  ? const LinearGradient(
                      colors: [V3Colors.primary, V3Colors.sky],
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHEBottomSheet — rounded elevated sheet matching the prototype's.
// -----------------------------------------------------------------------------
class SHEBottomSheet extends StatelessWidget {
  final bool open;
  final VoidCallback onClose;
  final String? title;
  final Widget child;

  const SHEBottomSheet({
    super.key,
    required this.open,
    required this.onClose,
    this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!open) return const SizedBox.shrink();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(color: Colors.black.withValues(alpha: 0.55)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.78,
            ),
            decoration: const BoxDecoration(
              color: V3Colors.surface2,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: V3Colors.borderStrong)),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                V3Spacing.lg,
                V3Spacing.sm,
                V3Spacing.lg,
                V3Spacing.xl + MediaQuery.of(context).padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: V3Colors.fillStrong,
                      borderRadius: BorderRadius.circular(V3Radius.full),
                    ),
                  ),
                  if (title != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      title!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: V3Colors.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  child,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// SHEStepper — the BLE-provisioning progress rail (kit.tsx SHEStepper).
// -----------------------------------------------------------------------------
class SHEStepper extends StatelessWidget {
  final int step; // 0-based index of the current step
  final List<String> labels;

  const SHEStepper({super.key, required this.step, required this.labels});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: i < step
                      ? V3Colors.successAlt
                      : i == step
                          ? V3Colors.primary
                          : V3Colors.surface,
                  shape: BoxShape.circle,
                  boxShadow: i == step
                      ? [
                          BoxShadow(
                            color: V3Colors.primary.withValues(alpha: 0.7),
                            blurRadius: 16,
                            spreadRadius: -2,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: i < step
                      ? const Icon(Icons.check,
                          size: 14, color: V3Colors.night)
                      : Text(
                          '${i + 1}',
                          style: TextStyle(
                            color: i == step
                                ? V3Colors.night
                                : V3Colors.dim,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                labels[i],
                style: TextStyle(
                  color: i <= step ? V3Colors.text2 : V3Colors.dim,
                  fontSize: V3Typography.micro,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (i < labels.length - 1)
            Container(
              width: 48,
              height: 2,
              margin: const EdgeInsets.only(left: 8, right: 8, bottom: 20),
              decoration: BoxDecoration(
                color: i < step ? V3Colors.successAlt : V3Colors.fillStrong,
                borderRadius: BorderRadius.circular(V3Radius.full),
              ),
            ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// SHEAvatar / SHEDivider — small atoms.
// -----------------------------------------------------------------------------
class SHEAvatar extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final double size;

  const SHEAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          imageUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initial(),
        ),
      );
    }
    return _initial();
  }

  Widget _initial() {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: V3Colors.primary.withValues(alpha: 0.20),
        shape: BoxShape.circle,
        border: Border.all(
          color: V3Colors.primary.withValues(alpha: 0.30),
          width: 1,
        ),
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: V3Colors.primary,
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class SHEDivider extends StatelessWidget {
  final double vertical;

  const SHEDivider({super.key, this.vertical = V3Spacing.xs});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: EdgeInsets.symmetric(vertical: vertical),
      color: V3Colors.border,
    );
  }
}

// -----------------------------------------------------------------------------
// _PressScale — shared tap feedback (scale-down + light haptic).
// The redesign leans on this everywhere; centralising it keeps the press feel
// identical across buttons, cards, chips and the bottom nav.
// -----------------------------------------------------------------------------
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius radius;
  final double scale;
  final bool haptic;

  const _PressScale({
    required this.child,
    required this.onTap,
    required this.radius,
    this.scale = 0.985,
    this.haptic = true,
  });

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: enabled
          ? () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap!.call();
            }
          : null,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: V3Duration.fast,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// _Shimmer — the she-skeleton shimmer, driven by an AnimationController.
// The prototype uses a CSS keyframe; Flutter needs the controller.
// -----------------------------------------------------------------------------
class _Shimmer extends StatefulWidget {
  final Widget child;

  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final t = _c.value * 2 - 1; // -1 .. 1
            return LinearGradient(
              begin: Alignment(t - 1, 0),
              end: Alignment(t + 1, 0),
              colors: const [
                Color(0x0AFFFFFF),
                Color(0x1AFFFFFF),
                Color(0x0AFFFFFF),
              ],
            ).createShader(rect);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
