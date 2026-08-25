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
import '../device_detail/node_service.dart';

final energyProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getEnergy(nodeId),
);

class EnergyScreen extends ConsumerWidget {
  final String nodeId;

  const EnergyScreen({super.key, required this.nodeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final energyAsync = ref.watch(energyProvider(nodeId));

    return Scaffold(
      appBar: AppBar(title: const Text('Energy')),
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
                          Text('Current Power', style: Theme.of(context).textTheme.bodyMedium),
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
                                Text('Energy', style: Theme.of(context).textTheme.bodySmall),
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
                                Text('Cost', style: Theme.of(context).textTheme.bodySmall),
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

                  // ---- 7-day chart (placeholder — V3-MOBILE-APP §9) ----
                  Text('7-Day History', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 200,
                    child: LineChart(
                      LineChartData(
                        gridData: const FlGridData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            // Placeholder data — production loads from /nodes/{id}/energy
                            spots: const [
                              FlSpot(0, 1.2),
                              FlSpot(1, 1.5),
                              FlSpot(2, 1.1),
                              FlSpot(3, 2.0),
                              FlSpot(4, 1.8),
                              FlSpot(5, 1.3),
                              FlSpot(6, 1.6),
                            ],
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
}
