// =============================================================================
// SHE V3 — Queued commands screen (design sheet screen 23)
// =============================================================================
// V3-MOBILE-APP §7: a command issued while offline queues in the
// `pending_commands` Hive box and flushes on reconnect, with a "Queued" badge on
// the command. This screen lists the backlog so the user can see / retry / clear
// it instead of it being invisible.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/offline/command_queue.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';

class QueuedCommandsScreen extends ConsumerWidget {
  const QueuedCommandsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final queue = ref.watch(commandQueueProvider);

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: Column(
          children: [
            SHEAppBar(
              title: l?.queuedTitle ?? 'Queued commands',
              subtitle: queue.isEmpty
                  ? null
                  : '${queue.length} · ${l?.queuedSubtitle ?? ''}'.trim(),
              onBack: () => context.pop(),
              trailing: queue.isEmpty
                  ? null
                  : SHEIconButton(
                      icon: Icons.send_rounded,
                      semanticLabel: l?.queuedSendAll ?? 'Send all',
                      onPressed: () =>
                          ref.read(commandQueueProvider.notifier).flush(),
                    ),
            ),
            Expanded(
              child: queue.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SHEEmptyState(
                          icon: Icons.schedule,
                          tone: V3Colors.dim,
                          title: l?.queuedEmptyTitle ?? 'Nothing queued',
                          body: l?.queuedEmptyBody ??
                              'Commands you send while offline wait here and go out automatically.',
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(V3Spacing.md,
                          V3Spacing.sm, V3Spacing.md, V3Spacing.xxl),
                      itemCount: queue.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        // Footer row: clear-all.
                        if (i == queue.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: V3Spacing.sm),
                            child: SHEButton(
                              label: l?.queuedClear ?? 'Clear',
                              variant: SHEButtonVariant.ghost,
                              onPressed: () =>
                                  ref.read(commandQueueProvider.notifier).clear(),
                            ),
                          );
                        }
                        return _QueuedTile(
                          cmd: queue[i],
                          onRemove: () => ref
                              .read(commandQueueProvider.notifier)
                              .remove(queue[i].id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedTile extends StatelessWidget {
  const _QueuedTile({required this.cmd, required this.onRemove});

  final PendingCommand cmd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final amharic = Localizations.localeOf(context).languageCode == 'am';

    return SHECard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: V3Colors.warningAlt.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
            child:
                 Icon(Icons.schedule, size: 19, color: V3Colors.warningAlt),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  cmd.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:  TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    SHEStatusBadge(cmdState: 'queued', amharic: amharic),
                    if (cmd.attempts > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${cmd.attempts}×',
                        style:  TextStyle(
                            color: V3Colors.dim, fontSize: V3Typography.micro),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
            color: V3Colors.dim,
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}
