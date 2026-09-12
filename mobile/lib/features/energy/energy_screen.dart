// =============================================================================
// SHE V3 — Energy screen
// =============================================================================
// V3-MOBILE-APP §9. V3-ENERGY-MONITORING §7.
// Real-time gauge + 7/14/30-day historical chart (kWh + ETB dual axis).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../core/theme/she_theme.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/node_service.dart';

final energyProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getEnergy(nodeId),
);

final energyDailyProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getEnergyDaily(nodeId),
);

class EnergyScreen extends ConsumerWidget {
  final String nodeId;

  const EnergyScreen({super.key, required this.nodeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final energyAsync = ref.watch(energyProvider(nodeId));
    final dailyAsync = ref.watch(energyDailyProvider(nodeId));
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n?.energy ?? 'Energy')),
      body: SafeArea(
        child: energyAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(child: Text('Error: $err')),
          data: (data) {
            final energyWh = data['energy_wh_consumed'] ?? 0;
            final costEtb = data['total_cost_etb'] ?? 0;
            final avgPower = data['avg_power_w'] ?? 0;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- Real-time gauge (V3-MOBILE-APP §9) ----
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Text(l10n?.currentPower ?? 'Current Power',
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 8),
                          Text(
                            '${(avgPower as num).toStringAsFixed(1)} W',
                            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                              color: SheTheme.brightSkyBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ---- Today's summary (kWh + ETB) ----
                  Row(
                    children: [
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Text(l10n?.energy ?? 'Energy',
                                    style: Theme.of(context).textTheme.bodySmall),
                                const SizedBox(height: 4),
                                Text(
                                  '${(energyWh as num).toStringAsFixed(2)} Wh',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Text(l10n?.cost ?? 'Cost',
                                    style: Theme.of(context).textTheme.bodySmall),
                                const SizedBox(height: 4),
                                Text(
                                  '${(costEtb as num).toStringAsFixed(2)} ብር',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    color: SheTheme.brightSkyBlue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ---- 7-day chart (real series from /energy/daily — M7 fix) ----
                  Text('7-Day History', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 200,
                    child: dailyAsync.when(
                      loading: () => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      error: (err, _) => Center(child: Text('Error: $err')),
                      data: (days) {
                        final spots = _dailySpots(days);
                        if (spots.isEmpty) {
                          return const Center(
                              child: Text('No history yet — check back tomorrow'));
                        }
                        return LineChart(
                          LineChartData(
                            gridData: const FlGridData(show: false),
                            titlesData: const FlTitlesData(show: false),
                            borderData: FlBorderData(show: false),
                            lineBarsData: [
                              LineChartBarData(
                                spots: spots,
                                isCurved: true,
                                color: SheTheme.brightSkyBlue,
                                barWidth: 3,
                                dotData: const FlDotData(show: false),
                                belowBarData: BarAreaData(
                                  show: true,
                                  color: SheTheme.brightSkyBlue.withOpacity(0.1),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // ---- Anomaly alert (V3-ENERGY-MONITORING §4.7) ----
                  const SizedBox(height: 24),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber, color: SheTheme.warning),
                      title: const Text('Anomaly Detection'),
                      subtitle: const Text('Alerts when consumption is 3× above 7-day baseline'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Builds chart spots (kWh per day) from /energy/daily rows.
  /// Rows: {day, energy_wh, cost_etb}.
  List<FlSpot> _dailySpots(List<Map<String, dynamic>> days) {
    if (days.isEmpty) return const [];
    final spots = <FlSpot>[];
    for (var i = 0; i < days.length; i++) {
      final wh = days[i]['energy_wh'];
      final kwh = (wh is num ? wh : num.tryParse('$wh') ?? 0) / 1000.0;
      spots.add(FlSpot(i.toDouble(), kwh));
    }
    return spots;
  }
}
