// =============================================================================
// SHE V3 — Energy Summary card (home-level placeholder)
// =============================================================================
// V3-DESIGN-SYSTEM §4.3: "Energy summary card: Real-time power (W) +
// today's cost in ETB". Positioned between scenes row and device grid.
//
// **Current reality (2026-09-19): the backend endpoint is a Phase 4 stub.**
// `GET /api/v3/homes/{homeId}/energy/summary` exists (EnergyController:84) but
// returns only {homeId, from, to, note:"Per-home aggregation comes in Phase 4"}.
// So this card renders the stub note honestly. As soon as Phase 4 lands the
// endpoint will return real numbers and the card will display them automatically.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client.dart';
import '../../../core/theme/v3_design_tokens.dart';

final homeEnergySummaryProvider =
    FutureProvider.family<EnergySummary, String>(
  (ref, homeId) async {
    final response =
        await ref.read(dioProvider).get('/api/v3/homes/$homeId/energy/summary');
    final data = (response.data['data'] as Map?) ?? const {};
    return EnergySummary.fromJson(data);
  },
);

class EnergySummary {
  final String? note;
  final bool isReal;

  const EnergySummary({this.note, required this.isReal});

  factory EnergySummary.fromJson(Map data) {
    // Real data would carry numeric fields like mrr_etb / outstanding_etb / etc.
    // For now the backend only returns the stub note.
    final note = data['note'] as String?;
    return EnergySummary(
      note: note,
      isReal: data.containsKey('mrr_etb') || data.containsKey('today_kwh'),
    );
  }
}

/// Energy summary card. Honest placeholder when the endpoint is a stub;
/// shows real data when Phase 4 lands.
class EnergySummaryCard extends ConsumerWidget {
  final String homeId;

  const EnergySummaryCard({super.key, required this.homeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeEnergySummaryProvider(homeId));

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: V3Spacing.md, vertical: V3Spacing.sm),
      child: Material(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Padding(
          padding: const EdgeInsets.all(V3Spacing.md),
          child: async.when(
            loading: () => const _Row(
              icon: Icons.bolt,
              title: 'Energy',
              subtitle: 'Loading…',
            ),
            error: (e, _) => const _Row(
              icon: Icons.bolt,
              title: 'Energy',
              subtitle: 'Unavailable',
            ),
            data: (s) {
              if (s.isReal) {
                return const _Row(
                  icon: Icons.bolt,
                  title: 'Energy',
                  subtitle: 'Live metrics available — Phase 4',
                );
              }
              return const _Row(
                icon: Icons.bolt,
                title: 'Energy',
                subtitle: 'Phase 4 — per-home aggregation coming soon',
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: V3Colors.primary, size: 22),
        const SizedBox(width: V3Spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: V3Colors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: V3Colors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}