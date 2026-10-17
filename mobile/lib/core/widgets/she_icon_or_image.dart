// =============================================================================
// SHE V3 — Icon that can also be a user's uploaded photo
// =============================================================================
// A scene/group stores a short icon key ('moon', 'lights', …) OR, once the user
// uploads their own picture, an `/api/v3/media/<uuid>` path. This widget renders
// whichever it is, so every card can stop caring which.
// =============================================================================

import 'package:flutter/material.dart';

import '../media/media_service.dart';

class SheIconOrImage extends StatelessWidget {
  const SheIconOrImage({
    super.key,
    required this.value,
    required this.fallbackIcon,
    this.size = 22,
    this.color,
    this.borderRadius,
  });

  /// The stored icon value: a key, an uploaded media path, or null.
  final String? value;

  /// Glyph used when [value] is a key (or empty).
  final IconData fallbackIcon;

  final double size;

  /// Icon colour; ignored when an image is rendered.
  final Color? color;

  /// Rounded corners for the image; defaults to a circle-free square.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v != null && MediaUrls.isUploaded(v)) {
      return ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(size * 0.22),
        child: Image.network(
          MediaUrls.resolve(v),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // A broken/offline image must not blow up a whole card.
          errorBuilder: (_, __, ___) => Icon(fallbackIcon, size: size, color: color),
        ),
      );
    }
    return Icon(fallbackIcon, size: size, color: color);
  }
}
