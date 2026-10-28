// =============================================================================
// SHE V3 — SKU icon (ported from desktop repo)
// =============================================================================
// One mapping, used by the dashboard, the Parent devices list and the manage
// screen. Three private copies had already appeared (and the device-detail one
// silently lacked SHE-R24, so a 24-relay board rendered as "unknown").
// =============================================================================

import 'package:flutter/material.dart';

/// Icon for a node's advertised SKU.
IconData iconForSku(String sku) => switch (sku) {
      'SHE-R4' => Icons.power,
      'SHE-R8' => Icons.dashboard,
      'SHE-R16' => Icons.developer_board,
      'SHE-R24' => Icons.grid_view,
      _ => Icons.device_unknown,
    };
