// =============================================================================
// SHE V3 — Dynamic device widget
// =============================================================================
// V3-MOBILE-APP §5.4. Dynamic UI generation from node config.
// Switch on device.type → render appropriate card.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/she_theme.dart';

class DynamicDeviceWidget extends StatelessWidget {
  final Map<String, dynamic> node;

  const DynamicDeviceWidget({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    final isOnline = node['is_online'] ?? false;
    final name = node['name'] ?? node['node_id'] ?? 'Unknown';
    final sku = node['sku'] ?? 'SHE-R8';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(SheTheme.radiusLg),
        onTap: () => context.push('/node/${node['id']}'),
        child: Container(
          padding: const EdgeInsets.all(SheTheme.spacingMd),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SheTheme.radiusLg),
            // Active glow when device is online (V3-DESIGN-SYSTEM §3)
            boxShadow: isOnline ? SheTheme.activeGlow : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // ---- Top row: icon + online badge ----
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    _iconForSku(sku),
                    size: 32,
                    color: isOnline ? SheTheme.brightSkyBlue : SheTheme.textMuted,
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? SheTheme.success : SheTheme.textMuted,
                    ),
                  ),
                ],
              ),

              // ---- Device name ----
              Text(
                name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              // ---- SKU ----
              Text(
                sku,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForSku(String sku) {
    switch (sku) {
      case 'SHE-R4':
        return Icons.power;
      case 'SHE-R8':
        return Icons.dashboard;
      case 'SHE-R16':
        return Icons.developer_board;
      default:
        return Icons.device_unknown;
    }
  }
}
