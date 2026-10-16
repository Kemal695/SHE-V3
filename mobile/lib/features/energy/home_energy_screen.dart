// =============================================================================
// SHE V3 — Home Energy screen (prototype `energy.tsx` · Energy dashboard)
// =============================================================================
// The Energy TAB is home-level. The existing EnergyScreen (features/energy/) is
// per-NODE and is reached from a device page — it is untouched and still served
// by /node/:id/energy.
//
// WHY THIS AGGREGATES CLIENT-SIDE
// -------------------------------
// `GET /api/v3/homes/{homeId}/energy/summary` exists but is a Phase 4 stub that
// returns only a note (see energy_summary_card.dart). Rather than show a fake
// number, this screen sums what the app CAN really read — each node's
// `getEnergyDaily()` — and labels the total as an aggregate across boards. When
// Phase 4 lands, only `_homeEnergyProvider` needs to change; the UI is already
// built around the same shape (daily totals + today's figure).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/utils/etb_formatter.dart';
import '../dashboard/dashboard_screen.dart' show homeNodesProvider;
import '../device_detail/node_service.dart';

/// One day of aggregated consumption across every board in the home.
class _DayTotal {
  final DateTime day;
  final double kwh;

  const _DayTotal(this.day, this.kwh);
}

class _HomeEnergy {
  final List<_DayTotal> days;   // oldest → newest, up to 7 entries
  final double todayKwh;
  final double weekKwh;
  final int nodeCount;
  final bool anyRealData;

  const _HomeEnergy({
    required this.days,
    required this.todayKwh,
    required this.weekKwh,
    required this.nodeCount,
    required this.anyRealData,
  });
}

final _homeEnergyProvider =
    FutureProvider.family<_HomeEnergy, String>((ref, homeId) async {
  final nodes = await ref.watch(homeNodesProvider(homeId).future);
  final service = ref.read(nodeServiceProvider);

  // date(YYYY-MM-DD) -> kWh
  final byDay = <String, double>{};
  var anyReal = false;

  for (final node in nodes) {
    final nodeId = node['id']?.toString();
    if (nodeId == null) continue;
    try {
      final rows = await service.getEnergyDaily(nodeId, days: 7);
      for (final r in rows) {
        // The endpoint has returned both `date`/`day` and `total_kwh`/`kwh`
        // spellings across revisions — accept either rather than silently
        // summing zeros.
        final rawDay = (r['date'] ?? r['day'])?.toString();
        final rawKwh = r['total_kwh'] ?? r['kwh'] ?? r['energy_kwh'];
        if (rawDay == null || rawKwh == null) continue;
        final kwh = double.tryParse(rawKwh.toString());
        if (kwh == null) continue;
        final key = rawDay.length >= 10 ? rawDay.substring(0, 10) : rawDay;
        byDay[key] = (byDay[key] ?? 0) + kwh;
        anyReal = true;
      }
    } catch (_) {
      // A board that cannot be read contributes nothing; the total is still a
      // truthful lower bound and `anyReal` tells the UI whether to say so.
    }
  }

  final sorted = byDay.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  final days = <_DayTotal>[];
  for (final e in sorted) {
    final parsed = DateTime.tryParse(e.key);
    if (parsed == null) continue;
    days.add(_DayTotal(parsed, e.value));
  }

  final today = DateTime.now();
  final todayKey =
      '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
  final todayKwh = byDay[todayKey] ??
      (days.isNotEmpty && days.last.day.day == today.day ? days.last.kwh : 0.0);
  final weekKwh = days.fold<double>(0, (s, d) => s + d.kwh);

  return _HomeEnergy(
    days: days,
    todayKwh: todayKwh,
    weekKwh: weekKwh,
    nodeCount: nodes.length,
    anyRealData: anyReal,
  );
});

class HomeEnergyScreen extends ConsumerStatefulWidget {
  const HomeEnergyScreen({super.key, this.homeId});

  /// Null when the shell route did not supply one; the screen then resolves the
  /// user's first home itself.
  final String? homeId;

  @override
  ConsumerState<HomeEnergyScreen> createState() => _HomeEnergyScreenState();
}

class _HomeEnergyScreenState extends ConsumerState<HomeEnergyScreen> {
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';
  late String _homeId;

  @override
  void initState() {
    super.initState();
    final initial = widget.homeId;
    _homeId = (initial != null && initial.isNotEmpty) ? initial : _defaultHomeId;
    if (initial == null || initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
  }

  Future<void> _resolveHome() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (homes.isNotEmpty && mounted) {
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) setState(() => _homeId = id);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_homeEnergyProvider(_homeId));

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: V3Colors.primary,
          backgroundColor: V3Colors.surface,
          onRefresh: () => ref.refresh(_homeEnergyProvider(_homeId).future),
          child: async.when(
            loading: () => ListView(
              children: const [
                SHEAppBar(title: 'Energy', large: true),
                Padding(
                  padding: EdgeInsets.all(V3Spacing.md),
                  child: SHESkeleton(height: 200),
                ),
              ],
            ),
            error: (e, _) => ListView(
              children: [
                const SHEAppBar(title: 'Energy', large: true),
                SHEEmptyState(
                  icon: Icons.bolt_outlined,
                  tone: V3Colors.warningAlt,
                  title: 'Energy unavailable',
                  body: '$e',
                  actionLabel: 'Retry',
                  // [_homeEnergyProvider] awaits `homeNodesProvider`, and Riverpod
                  // CACHES a provider's failure — invalidating only the downstream
                  // one re-throws that same cached error, so Retry never worked.
                  // Clear the upstream provider as well.
                  onAction: () {
                    ref.invalidate(homeNodesProvider(_homeId));
                    ref.invalidate(_homeEnergyProvider(_homeId));
                  },
                ),
              ],
            ),
            data: (energy) => _buildBody(energy),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(_HomeEnergy energy) {
    final costEtb = EtbFormatter.kwhToEtb(energy.todayKwh);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: V3Spacing.xxl),
      children: [
        const SHEAppBar(
          title: 'Energy',
          subtitle: 'Today · aggregated across boards',
          large: true,
        ),

        // ---- hero metric ----
        Padding(
          padding: const EdgeInsets.fromLTRB(
              V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.md),
          child: Container(
            padding: const EdgeInsets.all(V3Spacing.md),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  V3Colors.heroTop,
                  V3Colors.heroMid,
                  V3Colors.heroBottom,
                ],
              ),
              borderRadius: BorderRadius.circular(V3Radius.xl),
              border: Border.all(color: V3Colors.border, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SHEOverline('Energy today'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      energy.todayKwh.toStringAsFixed(1),
                      style: const TextStyle(
                        color: V3Colors.ink,
                        fontSize: V3Typography.metricLg,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'kWh',
                      style: TextStyle(
                        color: V3Colors.dim,
                        fontSize: V3Typography.body,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '≈ ${EtbFormatter.format(costEtb, 'am')} · estimated',
                  style: const TextStyle(
                    color: V3Colors.successAlt,
                    fontSize: V3Typography.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: V3Spacing.md),
                Row(
                  children: [
                    _Stat(
                      label: 'This week',
                      value: '${energy.weekKwh.toStringAsFixed(1)} kWh',
                    ),
                    const SizedBox(width: V3Spacing.lg),
                    _Stat(
                      label: 'Boards',
                      value: '${energy.nodeCount}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // ---- honest provenance note ----
        if (!energy.anyRealData)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                V3Spacing.md, 0, V3Spacing.md, V3Spacing.md),
            child: SHECard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 18, color: V3Colors.warningAlt),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'No per-board readings yet. Tap a board to see its own '
                      'energy history.',
                      style: TextStyle(
                        color: V3Colors.text2,
                        fontSize: V3Typography.meta,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ---- weekly bars ----
        if (energy.days.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
            child: SHEAppBar(title: '', transparent: true, large: false),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(V3Spacing.md, 0, V3Spacing.md, V3Spacing.sm),
            child: SHEOverline('Last 7 days'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
            child: SHECard(
              padding: const EdgeInsets.all(V3Spacing.md),
              child: _WeeklyBars(days: energy.days),
            ),
          ),
        ],

        const SizedBox(height: V3Spacing.lg),

        // ---- per-board breakdown ----
        const Padding(
          padding: EdgeInsets.fromLTRB(V3Spacing.md, 0, V3Spacing.md, V3Spacing.sm),
          child: SHEOverline('Per board'),
        ),
        _PerBoardList(homeId: _homeId),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: V3Colors.dim,
            fontSize: V3Typography.badge,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: V3Colors.ink,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Simple bar chart of the last 7 days — a direct port of the prototype's
/// `UsageBars`, including the highlighted most-recent bar and its value label.
class _WeeklyBars extends StatelessWidget {
  const _WeeklyBars({required this.days});

  final List<_DayTotal> days;

  static const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final data = days.length > 7 ? days.sublist(days.length - 7) : days;
    final max = data.fold<double>(0, (m, d) => d.kwh > m ? d.kwh : m);

    return SizedBox(
      height: 132,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < data.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: max <= 0 ? 0.02 : (data[i].kwh / max).clamp(0.02, 1.0),
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 26),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: i == data.length - 1
                                  ? const [V3Colors.sky, V3Colors.primary]
                                  : [
                                      V3Colors.primary.withValues(alpha: 0.55),
                                      V3Colors.primary.withValues(alpha: 0.16),
                                    ],
                            ),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                              bottom: Radius.circular(4),
                            ),
                            boxShadow: i == data.length - 1
                                ? V3Colors.cardGlow()
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _weekdayLabels[(data[i].day.weekday - 1) % 7],
                    style: const TextStyle(
                      color: V3Colors.dim,
                      fontSize: V3Typography.micro,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (i == data.length - 1)
                    Text(
                      '${data[i].kwh.toStringAsFixed(1)}kWh',
                      style: const TextStyle(
                        color: V3Colors.primary,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row per board with its latest daily reading, linking to that board's own
/// per-node Energy screen (/node/:id/energy) — which already existed.
class _PerBoardList extends ConsumerWidget {
  const _PerBoardList({required this.homeId});

  final String homeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodesAsync = ref.watch(homeNodesProvider(homeId));

    return nodesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(V3Spacing.md),
        child: SHESkeleton(height: 60),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (nodes) {
        if (nodes.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: V3Spacing.md),
            child: Text(
              'No boards yet.',
              style: TextStyle(color: V3Colors.dim, fontSize: V3Typography.body),
            ),
          );
        }
        return Column(
          children: [
            for (final n in nodes)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    V3Spacing.md, 0, V3Spacing.md, V3Spacing.sm),
                child: _BoardRow(node: n),
              ),
          ],
        );
      },
    );
  }
}

class _BoardRow extends ConsumerWidget {
  const _BoardRow({required this.node});

  final Map<String, dynamic> node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeId = node['id']?.toString() ?? '';
    final name = node['name']?.toString() ??
        node['node_id']?.toString() ??
        'Board';
    final isOnline = node['is_online'] == true;

    final dailyAsync = ref.watch(_nodeWeekProvider(nodeId));

    return SHECard(
      onTap: nodeId.isEmpty
          ? null
          : () => context.push('/node/$nodeId/energy'),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const DeviceIcon(kind: 'meter', on: true, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                SHEStatusBadge(online: isOnline),
              ],
            ),
          ),
          dailyAsync.when(
            loading: () => const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: V3Colors.primary),
            ),
            error: (_, __) => const Text(
              '—',
              style: TextStyle(color: V3Colors.dim, fontSize: 15),
            ),
            data: (kwh) => Text(
              '${kwh.toStringAsFixed(1)} kWh',
              style: const TextStyle(
                color: V3Colors.primary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: V3Spacing.xs),
          const Icon(Icons.chevron_right, size: 18, color: V3Colors.dim),
        ],
      ),
    );
  }
}

/// Sum of a single node's last 7 days, for the per-board row.
final _nodeWeekProvider = FutureProvider.family<double, String>((ref, nodeId) async {
  if (nodeId.isEmpty) return 0;
  try {
    final rows = await ref.read(nodeServiceProvider).getEnergyDaily(nodeId, days: 7);
    var total = 0.0;
    for (final r in rows) {
      final raw = r['total_kwh'] ?? r['kwh'] ?? r['energy_kwh'];
      final v = raw == null ? null : double.tryParse(raw.toString());
      if (v != null) total += v;
    }
    return total;
  } catch (_) {
    return 0;
  }
});
