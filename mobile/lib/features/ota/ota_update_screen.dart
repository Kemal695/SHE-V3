// =============================================================================
// SHE V3 — OTA Update screen (design sheet screen 17)
// =============================================================================
// Shows the firmware version of each node in the home and the state of any
// rollout in flight, with Install / Abort controls.
//
// HOW PROGRESS IS OBTAINED — read this before "fixing" it to use WebSocket.
//
// The backend does publish an `ota.progress` event (mac, status, progress,
// version), but `WsClient` exposes NO public stream: it only invalidates
// Riverpod providers internally, and no screen currently consumes
// `WsEventTypes.otaProgress`. Wiring a stream would mean changing shared
// networking used by every other screen.
//
// So this screen POLLS, and only while something is actually moving:
//   - a rollout is ROLLING            -> refresh every 5s
//   - otherwise                       -> no timer at all
// That keeps the UI live where it matters without a permanent background poll,
// and pull-to-refresh covers the rest.
//
// PERMISSIONS (V3-API-SPECIFICATION §9): list/get are MEMBER, but start / abort
// / approve / decline are ADMIN+. The server enforces it; here the controls are
// hidden unless `_isAdmin` so a member never taps into a 403.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';
import '../dashboard/dashboard_screen.dart' show homeNodesProvider;
import '../device_detail/node_service.dart';
import 'ota_service.dart';

/// Resolves the user's first home. Same discovery pattern the Devices, More and
/// Notifications screens use; '' until it resolves.
final _firstHomeIdProvider = FutureProvider<String>((ref) async {
  try {
    final homes = await ref.read(nodeServiceProvider).listHomes();
    if (homes.isEmpty) return '';
    return (homes.first['id'] ?? homes.first['home_id'])?.toString() ?? '';
  } catch (_) {
    return '';
  }
});

/// nodeId -> display name.
final _nodeNamesProvider =
    FutureProvider.family<Map<String, String>, String>((ref, homeId) async {
  if (homeId.isEmpty) return const {};
  try {
    final nodes = await ref.watch(homeNodesProvider(homeId).future);
    final out = <String, String>{};
    for (final n in nodes) {
      final id = n['id']?.toString();
      if (id == null) continue;
      final name = n['display_name']?.toString() ??
          n['name']?.toString() ??
          n['node_id']?.toString();
      if (name != null && name.isNotEmpty) out[id] = name;
    }
    return out;
  } catch (_) {
    return const {};
  }
});

/// nodeId -> firmware version currently reported by that node.
final _nodeVersionsProvider =
    FutureProvider.family<Map<String, String>, String>((ref, homeId) async {
  if (homeId.isEmpty) return const {};
  try {
    final nodes = await ref.watch(homeNodesProvider(homeId).future);
    final out = <String, String>{};
    for (final n in nodes) {
      final id = n['id']?.toString();
      if (id == null) continue;
      out[id] = n['firmware_version']?.toString() ?? 'Unknown';
    }
    return out;
  } catch (_) {
    return const {};
  }
});

class OtaUpdateScreen extends ConsumerStatefulWidget {
  const OtaUpdateScreen({super.key, this.homeId, this.isAdmin = false});

  final String? homeId;

  /// Start / abort / approve / decline are ADMIN+ (§9).
  final bool isAdmin;

  @override
  ConsumerState<OtaUpdateScreen> createState() => _OtaUpdateScreenState();
}

class _OtaUpdateScreenState extends ConsumerState<OtaUpdateScreen> {
  List<OtaBatch> _batches = const [];
  List<OtaApproval> _approvals = const [];
  bool _loading = true;
  bool _acting = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Resolved explicitly rather than with `widget.homeId ?? await ...`, which
    // the analyzer still widens to String? here.
    var homeId = widget.homeId ?? '';
    if (homeId.isEmpty) {
      homeId = await ref.read(_firstHomeIdProvider.future);
    }
    if (homeId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final batches = await ref.read(otaServiceProvider).listBatches(homeId);
      // Most homes have at most one rollout in flight; show progress for the
      // newest non-finished one, falling back to the newest overall.
      final active = batches.firstWhere(
        (b) => !b.isFinished,
        orElse: () => batches.isEmpty
            ? const OtaBatch(
                id: '',
                firmwareVersion: '',
                targetSku: '',
                status: 'NONE',
                rolloutPercent: 0,
                autoApprove: false,
                approvalCount: 0,
              )
            : batches.first,
      );
      final approvals = active.id.isEmpty
          ? const <OtaApproval>[]
          : await ref.read(otaServiceProvider).listApprovals(active.id);
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _approvals = approvals;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
    _reschedulePoll();
  }

  /// Poll ONLY while a rollout is moving. See the file header for why this is
  /// polling and not a WebSocket stream.
  void _reschedulePoll() {
    _poll?.cancel();
    final rolling = _batches.any((b) => b.isRolling);
    if (!rolling) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  Future<void> _act(Future<void> Function() op) async {
    setState(() => _acting = true);
    try {
      await op();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  OtaBatch? get _active => _batches.isEmpty
      ? null
      : _batches.firstWhere((b) => !b.isFinished, orElse: () => _batches.first);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final homeId = widget.homeId ?? '';
    final names = homeId.isEmpty
        ? const <String, String>{}
        : ref.watch(_nodeNamesProvider(homeId)).valueOrNull ?? const {};
    final versions = homeId.isEmpty
        ? const <String, String>{}
        : ref.watch(_nodeVersionsProvider(homeId)).valueOrNull ?? const {};

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: Column(
          children: [
            SHEAppBar(
              title: l?.otaTitle ?? 'Firmware update',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: RefreshIndicator(
                color: V3Colors.primary,
                backgroundColor: V3Colors.surface,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(V3Spacing.md),
                  children: [
                    _buildStatusCard(),
                    const SizedBox(height: V3Spacing.lg),
                    SHESectionHeader(title: l?.otaDevices ?? 'Devices'),
                    const SizedBox(height: V3Spacing.sm),
                    ..._buildDeviceRows(names, versions),
                  ],
                ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final l = AppLocalizations.of(context);
    final batch = _active;
    final rolling = batch?.isRolling ?? false;
    final done = batch?.status == 'COMPLETED';
    final failed = batch?.status == 'FAILED' || batch?.status == 'ABORTED';

    final (Color tone, IconData icon, String headline, String detail) =
        switch (batch?.status) {
      'ROLLING' => (
          V3Colors.primary,
          Icons.system_update,
          l?.otaUpdating ?? 'Updating firmware',
          l?.otaRollingOut(batch!.firmwareVersion) ??
              'Version ${batch!.firmwareVersion} is rolling out. Keep the devices powered on.'
        ),
      'COMPLETED' => (
          V3Colors.successAlt,
          Icons.check_circle,
          l?.otaUpToDate ?? 'Up to date',
          l?.otaAllRunning(batch!.firmwareVersion) ??
              'Every device is running ${batch!.firmwareVersion}.'
        ),
      'FAILED' => (
          V3Colors.errorAlt,
          Icons.error_outline,
          l?.otaUpdateFailed ?? 'Update failed',
          _firstError() ??
              (l?.otaRolloutIncomplete ?? 'The rollout did not complete.')
        ),
      'ABORTED' => (
          V3Colors.errorAlt,
          Icons.error_outline,
          l?.otaUpdateAborted ?? 'Update aborted',
          _firstError() ??
              (l?.otaRolloutIncomplete ?? 'The rollout did not complete.')
        ),
      _ => (
          V3Colors.successAlt,
          Icons.verified,
          l?.otaUpToDate ?? 'Up to date',
          batch == null
              ? (l?.otaNoneAvailable ?? 'No firmware updates are available.')
              : (l?.otaReadyToInstall(batch.firmwareVersion) ??
                  'Version ${batch.firmwareVersion} is ready to install.')
        ),
    };

    final overall = _approvals.isEmpty
        ? (rolling ? 0.0 : 100.0)
        : _approvals.map((a) => a.progress).reduce((a, b) => a + b) /
            _approvals.length;

    return SHECard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(V3Radius.lg),
                ),
                child: Icon(icon, size: 20, color: tone),
              ),
              const SizedBox(width: V3Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style:  TextStyle(
                        color: V3Colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style:  TextStyle(
                          color: V3Colors.text2, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (rolling || (done && _approvals.isNotEmpty)) ...[
            const SizedBox(height: V3Spacing.md),
            SHEProgressBar(value: overall, tone: tone),
            const SizedBox(height: 6),
            Text(
              '${overall.round()}%',
              style:  TextStyle(
                  color: V3Colors.text2, fontSize: V3Typography.meta),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: V3Spacing.sm),
            Text(_error!,
                style:  TextStyle(
                    color: V3Colors.errorAlt, fontSize: 12.5)),
          ],
          if (failed && _isAdminList()) ...[
            const SizedBox(height: V3Spacing.sm),
            Text(
              l?.otaAdminHint ??
                  'An admin can start a new rollout from the admin console.',
              style:  TextStyle(
                  color: V3Colors.dim, fontSize: V3Typography.meta),
            ),
          ],
        ],
      ),
    );
  }

  bool _isAdminList() => widget.isAdmin;

  String? _firstError() {
    for (final a in _approvals) {
      if (a.lastError != null && a.lastError!.isNotEmpty) return a.lastError;
    }
    return null;
  }

  List<Widget> _buildDeviceRows(
      Map<String, String> names, Map<String, String> versions) {
    final l = AppLocalizations.of(context);
    if (_loading) {
      return const [SHESkeleton(height: 64), SHESkeleton(height: 64)];
    }
    if (_approvals.isEmpty) {
      // No rollout: still show what is installed, so the screen is not empty.
      final ids = versions.keys.toList()..sort();
      if (ids.isEmpty) {
        return [
          SHEEmptyState(
            icon: Icons.devices_other,
            title: l?.otaNoDevicesTitle ?? 'No devices',
            body: l?.otaNoDevicesBody ??
                'Devices appear here once they report to this home.',
            tone: V3Colors.dim,
          ),
        ];
      }
      return ids.map((id) => _row(id, names, versions, null)).toList();
    }
    return _approvals.map((a) => _row(a.nodeId, names, versions, a)).toList();
  }

  Widget _row(String nodeId, Map<String, String> names,
      Map<String, String> versions, OtaApproval? approval) {
    final l = AppLocalizations.of(context);
    final name = names[nodeId] ?? (l?.otaDeviceFallback ?? 'Device');
    final version = versions[nodeId] ?? (l?.otaUnknown ?? 'Unknown');
    final status = approval?.status ?? 'UP_TO_DATE';

    final (Color tone, String label) = switch (status) {
      'COMPLETED' => (V3Colors.successAlt, l?.otaStatusUpdated ?? 'Updated'),
      'IN_PROGRESS' => (V3Colors.primary,
          approval?.deploymentStatus ?? (l?.otaStatusUpdating ?? 'Updating')),
      'PENDING' =>
          (V3Colors.warningAlt, l?.otaStatusWaitingApproval ?? 'Waiting for approval'),
      'APPROVED' => (V3Colors.primary, l?.otaStatusApproved ?? 'Approved'),
      'DECLINED' => (V3Colors.dim, l?.otaStatusDeclined ?? 'Declined'),
      'FAILED' || 'ROLLED_BACK' =>
          (V3Colors.errorAlt, l?.otaStatusFailed ?? 'Failed'),
      _ => (V3Colors.dim, l?.otaStatusUpToDate ?? 'Up to date'),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: SHECard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                 Icon(Icons.memory, size: 18, color: V3Colors.primary),
                const SizedBox(width: V3Spacing.sm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                      color: V3Colors.ink,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(V3Radius.sm),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(color: tone, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l?.otaFirmware(version) ?? 'Firmware $version',
              style:  TextStyle(
                  color: V3Colors.text2, fontSize: 12.5),
            ),
            if (approval != null && approval.progress > 0) ...[
              const SizedBox(height: V3Spacing.sm),
              SHEProgressBar(value: approval.progress.toDouble(), tone: tone),
            ],
            if (approval?.lastError != null &&
                approval!.lastError!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                approval.lastError!,
                style:  TextStyle(
                    color: V3Colors.errorAlt, fontSize: 11.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionBar() {
    final l = AppLocalizations.of(context);
    final batch = _active;
    if (batch == null || !widget.isAdmin) return const SizedBox.shrink();

    if (batch.isRolling) {
      return Padding(
        padding: const EdgeInsets.all(V3Spacing.md),
        child: SHEButton(
          label: l?.otaAbort ?? 'Abort rollout',
          icon: Icons.stop_circle_outlined,
          variant: SHEButtonVariant.secondary,
          loading: _acting,
          onPressed: () => _act(
              () => ref.read(otaServiceProvider).abortBatch(batch.id)),
        ),
      );
    }
    if (batch.status == 'DRAFT' || batch.status == 'APPROVED') {
      return Padding(
        padding: const EdgeInsets.all(V3Spacing.md),
        child: SHEButton(
          label: l?.otaInstall(batch.firmwareVersion) ??
              'Install ${batch.firmwareVersion}',
          icon: Icons.system_update,
          loading: _acting,
          onPressed: () => _act(
              () => ref.read(otaServiceProvider).startBatch(batch.id)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
