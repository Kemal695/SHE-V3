// =============================================================================
// SHE V3 — Offline banner (design sheet screen 22 — Offline state)
// =============================================================================
// V3-MOBILE-APP §7: an amber, dismissible connectivity banner that reads
// "You're offline. Showing cached data."
//
// Installed ONCE in MaterialApp.builder, so it floats above every route — the
// five shell tabs and the full-screen detail routes alike — without each screen
// having to opt in. It is an overlay (Stack), not a Column row, so showing and
// hiding it never reflows the screen underneath.
//
// WHY THE REACTION LIVES HERE, NOT IN A PROVIDER
// ----------------------------------------------
// The live-link state is `wsConnectedProvider` (a StateProvider the WS client
// mirrors). An earlier version reacted to it with `ref.listen` inside a
// Notifier's `build()`, and on-device that listener never fired — the socket
// dropped (the dashboard chip flipped Live -> Offline) yet the banner never
// appeared. Reacting from the widget layer with `ref.listenManual` (registered
// in initState, the documented API for this) plus a post-frame cold-start check
// is reliable, so the whole state machine lives here.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../network/dio_client.dart' show accessTokenProvider;
import '../network/ws_client.dart' show wsConnectedProvider, wsClientProvider;
import '../offline/command_queue.dart' show commandQueueProvider;
import '../offline/offline_automations.dart' show offlineAutomationServiceProvider;
import '../theme/v3_design_tokens.dart';

class OfflineBannerHost extends ConsumerStatefulWidget {
  const OfflineBannerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OfflineBannerHost> createState() => _OfflineBannerHostState();
}

class _OfflineBannerHostState extends ConsumerState<OfflineBannerHost> {
  /// How long the live link must stay down before we call it an outage. Long
  /// enough to ride out a normal reconnect / brief radio blip; short enough that
  /// a real outage is surfaced promptly.
  static const Duration _grace = Duration(seconds: 8);

  Timer? _graceTimer;
  bool _offline = false;

  /// Dismissed for the CURRENT outage only; re-armed when the link returns.
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();

    // Fire on every live-link change for this widget's lifetime. listenManual is
    // the supported way to react to a provider outside build().
    ref.listenManual<bool>(wsConnectedProvider, (_, up) => _onSocket(up));
    // Logging out has no socket by design — never read that as "offline".
    ref.listenManual<String?>(accessTokenProvider, (_, token) {
      if (token == null) _onSocket(true);
    });

    // Cold start: if the app launches while ALREADY offline there is no change
    // to react to, so evaluate once after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onSocket(ref.read(wsConnectedProvider));
    });
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  void _onSocket(bool up) {
    _graceTimer?.cancel();
    final authed = ref.read(accessTokenProvider) != null;

    if (!authed || up) {
      // Online (or logged out): clear the banner and re-arm it for next time.
      if (_offline) {
        setState(() {
          _offline = false;
          _dismissed = false;
        });
      }
      // The link just came back — replay anything queued while it was down
      // (design sheet #23). Driven from here so the replay does not depend on a
      // provider-level listener.
      if (up && authed) {
        ref.read(commandQueueProvider.notifier).flush();
        // Automations created while offline live on the device AND in Hive; push
        // them to the cloud now so they also exist server-side. Both flushes are
        // re-entrancy guarded and no-op when there is nothing to send, so calling
        // this on every evaluation is safe.
        ref.read(offlineAutomationServiceProvider).flushPending();
      }
      return;
    }

    // Socket down while authenticated: arm the grace window, then declare the
    // outage. If the socket recovers first the timer is cancelled above.
    _graceTimer = Timer(_grace, () {
      if (mounted && !_offline) setState(() => _offline = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = _offline && !_dismissed;

    return Stack(
      children: [
        widget.child,
        if (show)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: _OfflineBanner(
              onRetry: () => ref.read(wsClientProvider).reconnectNow(),
              onDismiss: () => setState(() => _dismissed = true),
            ),
          ),
      ],
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onRetry, required this.onDismiss});

  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Dark text on the amber fill (V3-DESIGN-SYSTEM: Warning = #F5B84B).
    final onAmber = V3Colors.night;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: V3Colors.warningAlt,
          borderRadius: BorderRadius.circular(V3Radius.lg),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 20, color: onAmber),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l?.offlineTitle ?? "You're offline",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: onAmber,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    l?.offlineBody ??
                        "Showing cached data. We'll reconnect automatically.",
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: onAmber.withValues(alpha: 0.8),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: onAmber,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(l?.offlineRetry ?? 'Retry'),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16),
              color: onAmber.withValues(alpha: 0.85),
              tooltip: l?.offlineDismiss ?? 'Dismiss',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}
