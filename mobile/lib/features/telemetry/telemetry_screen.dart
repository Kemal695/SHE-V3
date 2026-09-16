// =============================================================================
// SHE V3 — Telemetry screen
// =============================================================================
// Renders GET /api/v3/nodes/{id}/telemetry (V3-API-SPECIFICATION §6).
//
// Until now getTelemetry() existed in node_service.dart but NO screen called it,
// so the Diagnostics telemetry the device publishes was invisible in the app.
// This is that screen: latest Uptime / RSSI / Free_Heap plus a trend chart.
//
// Note the device sends diagnostics two ways and they are easy to confuse:
//   - `params/local`  -> node_params.last_value (the Diagnostics cards in
//                        device_detail) — a single current value
//   - `telemetry`     -> device_telemetry hypertable (this screen) — a time series
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../core/theme/she_theme.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/node_service.dart';

final telemetryProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getTelemetry(nodeId),
);

class TelemetryScreen extends ConsumerStatefulWidget {
  final String nodeId;

  const TelemetryScreen({super.key, required this.nodeId});

  @override
  ConsumerState<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends ConsumerState<TelemetryScreen> {
  /// Which series the chart plots. Null = pick the first available.
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(telemetryProvider(widget.nodeId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.telemetry ?? 'Telemetry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n?.refresh ?? 'Refresh',
            onPressed: () => ref.invalidate(telemetryProvider(widget.nodeId)),
          ),
        ],
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${l10n?.error ?? 'Error'}: $err',
                  textAlign: TextAlign.center),
            ),
          ),
          data: (data) {
            final points = _pointsOf(data);
            if (points.isEmpty) {
              return _EmptyState(l10n: l10n);
            }

            // Points arrive ascending by time, so the last one per param is the latest.
            final latest = <String, Map<String, dynamic>>{};
            for (final p in points) {
              latest[p['param_name'] as String] = p;
            }
            final params = latest.keys.toList()..sort();
            final selected = _selected ?? _preferred(params);
            final series =
                points.where((p) => p['param_name'] == selected).toList();

            return RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(telemetryProvider(widget.nodeId)),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('${l10n?.latestReadings ?? 'Latest readings'}'
                      '  ·  ${points.length} ${l10n?.samples ?? 'samples'}',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  _LatestGrid(latest: latest),
                  const SizedBox(height: 24),
                  Text(l10n?.trend ?? 'Trend',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final p in params)
                        ChoiceChip(
                          label: Text(p),
                          selected: p == selected,
                          onSelected: (_) => setState(() => _selected = p),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 220,
                    child: series.length < 2
                        ? Center(
                            child: Text(
                              l10n?.needMoreSamples ??
                                  'Need at least two samples to draw a trend.',
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : _TrendChart(series: series, unit: _unitOf(series)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static List<Map<String, dynamic>> _pointsOf(Map<String, dynamic> data) {
    final raw = data['points'];
    if (raw is List) {
      return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    return const [];
  }

  static String _unitOf(List<Map<String, dynamic>> series) =>
      (series.first['unit'] as String?) ?? '';

  /// Prefer RSSI (the most interesting to watch), else the first alphabetically.
  static String _preferred(List<String> params) =>
      params.contains('RSSI') ? 'RSSI' : (params.isEmpty ? '' : params.first);
}

class _LatestGrid extends StatelessWidget {
  final Map<String, Map<String, dynamic>> latest;

  const _LatestGrid({required this.latest});

  @override
  Widget build(BuildContext context) {
    final entries = latest.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        for (final e in entries)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.key, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  Text(
                    _format(e.value),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: SheTheme.brightSkyBlue,
                        ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _format(Map<String, dynamic> point) {
    final value = point['value'];
    final unit = (point['unit'] as String?) ?? '';
    if (value is num) {
      final text = value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toStringAsFixed(1);
      return unit.isEmpty ? text : '$text $unit';
    }
    return '$value';
  }
}

class _TrendChart extends StatelessWidget {
  final List<Map<String, dynamic>> series;
  final String unit;

  const _TrendChart({required this.series, required this.unit});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < series.length; i++) {
      final v = series[i]['value'];
      if (v is num) spots.add(FlSpot(i.toDouble(), v.toDouble()));
    }
    if (spots.isEmpty) return const SizedBox.shrink();

    final values = spots.map((s) => s.y);
    final minY = values.reduce((a, b) => a < b ? a : b);
    final maxY = values.reduce((a, b) => a > b ? a : b);
    // Pad a flat series so the line doesn't sit exactly on the axis.
    final pad = (maxY - minY).abs() < 0.001 ? 1.0 : (maxY - minY) * 0.15;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              getTitlesWidget: (value, meta) => Text(
                '${value.round()}$unit',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 2,
            color: SheTheme.brightSkyBlue,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: SheTheme.brightSkyBlue.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the node has reported no telemetry yet.
///
/// This is the normal state for a board without a PZEM/energy monitor: the
/// firmware publishes diagnostics over `params/local`, not the `telemetry`
/// topic, so `device_telemetry` stays empty. Point at the simulator rather than
/// leaving a blank screen with no explanation.
class _EmptyState extends StatelessWidget {
  final AppLocalizations? l10n;

  const _EmptyState({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.show_chart, size: 48),
            const SizedBox(height: 12),
            Text(
              l10n?.noTelemetryYet ?? 'No telemetry recorded for this node yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'The firmware does not publish the `telemetry` topic, so this stays empty '
              'unless something else does. Publish synthetic samples with:\n\n'
              'python scripts/simulate-telemetry.py --count 12 --interval 2',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
