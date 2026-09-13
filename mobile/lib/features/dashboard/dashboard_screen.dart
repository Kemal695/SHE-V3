// =============================================================================
// SHE V3 — Dashboard screen (Bento grid)
// =============================================================================
// V3-MOBILE-APP §5. ADR-009 (dark-mode first, Bento grid).
// Dynamic UI generation from node config payload (V3-MOBILE-APP §5.4).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_theme.dart';
import '../../core/network/ws_client.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/node_service.dart';
import 'widgets/dynamic_device_widget.dart';
import 'widgets/bento_grid.dart';

final homeNodesProvider = FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, homeId) => ref.read(nodeServiceProvider).listNodesByHome(homeId),
);

final homesProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.read(nodeServiceProvider).listHomes(),
);

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _selectedHomeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(wsClientProvider).connect();
    });
  }

  @override
  Widget build(BuildContext context) {
    final homesAsync = ref.watch(homesProvider);
    final l10n = AppLocalizations.of(context);

    return homesAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, _) => Scaffold(body: Center(child: Text('Error loading homes: $err'))),
      data: (homes) {
        if (homes.isEmpty) {
          return const Scaffold(body: Center(child: Text('No homes found')));
        }
        final addDeviceTip = l10n?.addDevice ?? 'Add Device';
        final homeId = _selectedHomeId ?? homes.first['id'];
        final nodesAsync = ref.watch(homeNodesProvider(homeId));

        return Scaffold(
          appBar: AppBar(
            title: DropdownButton<String>(
              value: homeId,
              dropdownColor: SheTheme.lighterNavy,
              underline: const SizedBox(),
              items: homes.map((h) => DropdownMenuItem<String>(
                value: h['id'],
                child: Text(h['name'] ?? 'Home', style: const TextStyle(color: Colors.white)),
              )).toList(),
              onChanged: (id) {
                if (id != null) setState(() => _selectedHomeId = id);
              },
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => context.push('/provisioning'),
                tooltip: addDeviceTip,
              ),
              IconButton(
                icon: const Icon(Icons.group_outlined),
                onPressed: () => context.push('/home/$homeId/members'),
                tooltip: l10n?.members ?? 'Members',
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => context.push('/settings'),
                tooltip: l10n?.settings ?? 'Settings',
              ),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(homeNodesProvider(homeId).future),
          child: nodesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            // M10 fix: error/empty states must be scrollable or
            // RefreshIndicator's pull-to-refresh never triggers.
            error: (err, _) => _scrollable(
              context,
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: SheTheme.error),
                  const SizedBox(height: 16),
                  Text('Failed to load devices', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('$err', style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => ref.refresh(homeNodesProvider(homeId)),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
            data: (nodes) {
              if (nodes.isEmpty) {
                return _scrollable(context, _emptyStateContent(context, l10n));
              }
              // ---- Bento grid of device cards ----
              return BentoGrid(
                children: nodes.map((node) {
                  return DynamicDeviceWidget(node: node);
                }).toList(),
              );
            },
          ),
        ),
      ),
    );
      },
    );
  }

  /// Wraps non-scrollable states so RefreshIndicator can always trigger (M10).
  Widget _scrollable(BuildContext context, Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }

  Widget _emptyStateContent(BuildContext context, AppLocalizations? l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.home_outlined, size: 64, color: SheTheme.textMuted),
            const SizedBox(height: 16),
            Text(
              l10n?.noDevices ?? 'No devices yet',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n?.addFirstDevice ?? 'Add your first SHE device to get started',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.push('/provisioning'),
              icon: const Icon(Icons.add),
              label: Text(l10n?.addDevice ?? 'Add Device'),
            ),
          ],
        ),
      ),
    );
  }
}
