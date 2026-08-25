// =============================================================================
// SHE V3 — Bento grid widget
// =============================================================================
// V3-DESIGN-SYSTEM §3. ADR-009.
// 2-col mobile (≤600px), 3-col tablet (600-900px), 4-col desktop (≥900px).
// =============================================================================

import 'package:flutter/widgets.dart';
import '../../../core/theme/she_theme.dart';

class BentoGrid extends StatelessWidget {
  final List<Widget> children;

  const BentoGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount;
        if (constraints.maxWidth <= 600) {
          crossAxisCount = 2;
        } else if (constraints.maxWidth <= 900) {
          crossAxisCount = 3;
        } else {
          crossAxisCount = 4;
        }

        return GridView.builder(
          padding: const EdgeInsets.all(SheTheme.spacingMd),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: SheTheme.spacingSm,
            mainAxisSpacing: SheTheme.spacingSm,
            childAspectRatio: 1.0,
          ),
          itemCount: children.length,
          itemBuilder: (context, index) => children[index],
        );
      },
    );
  }
}
