// =============================================================================
// SHE V3 — App Shell (persistent 5-tab bottom navigation)
// =============================================================================
// Ports the prototype's `BottomNav` + screen router (page.tsx): Home, Devices,
// Automations, Energy, More. In the prototype these are state swaps inside one
// phone frame; here they are a go_router StatefulShellRoute, so each tab keeps
// its own navigation stack (pushing a device detail inside the Devices tab does
// not destroy the Home tab) — which is the behaviour the prototype simulates
// with its `nav()` store and what the old dashboard bottom bar could NOT do
// (it pushed routes onto a single stack, so Back walked through tabs).
//
// IMPORTANT — nothing about routing *targets* changed. Every existing path
// (/node/:id, /scenes, /automations, /voice, /settings, ...) still resolves to
// the same screen with the same params. Only the chrome around the roots is new.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/v3_design_tokens.dart';
import '../l10n/app_localizations.dart';

/// The five root destinations, in the prototype's order.
///
/// `family` lists the descendant route prefixes that should keep this tab lit —
/// mirrors `activeFamily()` in page.tsx.
enum ShellTab {
  home(
    path: '/dashboard',
    label: 'Home',
    icon: Icons.home_outlined,
    activeIcon: Icons.home,
    family: ['/dashboard'],
  ),
  devices(
    path: '/devices',
    label: 'Devices',
    icon: Icons.grid_view_outlined,
    activeIcon: Icons.grid_view,
    family: ['/devices', '/node', '/provisioning'],
  ),
  automations(
    path: '/automations',
    label: 'Automations',
    icon: Icons.account_tree_outlined,
    activeIcon: Icons.account_tree,
    family: ['/automations', '/scenes'],
  ),
  energy(
    path: '/energy',
    label: 'Energy',
    icon: Icons.bolt_outlined,
    activeIcon: Icons.bolt,
    family: ['/energy'],
  ),
  more(
    path: '/more',
    label: 'More',
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    family: ['/more', '/settings', '/voice', '/payments', '/home'],
  );

  const ShellTab({
    required this.path,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.family,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final List<String> family;
}

/// A `StatefulNavigationShell` is supplied as the `navigationShell` argument of
/// `StatefulShellRoute`. We render it inside a Scaffold that owns the bottom nav.
///
/// BACK-BUTTON CONTRACT (bugfix 2026-10-03)
/// ----------------------------------------
/// The shell is the single owner of the system Back gesture while a tab is
/// showing. Rationale: `StatefulShellRoute.indexedStack` keeps EVERY branch
/// mounted at once, so a `PopScope` inside one branch screen also intercepts
/// Back while the user is looking at a different branch. Letting each tab define
/// its own Back policy produced a bug where Back ejected the whole shell route
/// and dumped the user on /login ("pressing Back logs me out").
///
/// Behaviour implemented here:
///   * non-Home tab          -> switch to Home (never leave the app)
///   * Home tab, nested pop  -> pop the branch's own stack
///   * Home tab, stack empty -> stay in the app (never exits on Back)
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;

    return PopScope(
      // Never let the framework pop the shell. Blocking the pop WITHOUT a
      // handler is what once fell through to the root navigator and resolved
      // back to /splash; this handler always answers, so it cannot.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // A non-Home tab is showing. Back here means "go Home", like every
        // Android app — without this, Back from the Devices tab left the app
        // entirely, which reads as a crash.
        if (shell.currentIndex != 0) {
          shell.goBranch(0);
        }

        // On Home there is nothing to go back to, so do nothing.
        //
        // ⚠️ Do NOT try to pop history from here. `Navigator.of(context)` in
        // AppShell is the ROOT navigator, and its stack holds the shell route
        // itself — so `canPop()` is true and `pop()` tears the whole shell down.
        // go_router then re-resolves to its initialLocation
        // (/splash -> /onboarding -> /login), which is precisely the reported
        // "Back closes the app / logs me out". dashboard_screen.dart:93-106
        // documents the same trap from the other direction.
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Wide (tablet / foldable / desktop): move the five destinations into
          // a side rail and let the active branch fill the remaining width.
          // Narrow (phone): keep the prototype's bottom nav untouched.
          final wide = constraints.maxWidth >= V3Breakpoints.mobile;

          return Scaffold(
            backgroundColor: V3Colors.background,
            body: wide
                ? Row(
                    children: [
                      _SHENavRail(navigationShell: shell),
                       VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: V3Colors.border,
                      ),
                      Expanded(child: shell),
                    ],
                  )
                : shell,
            bottomNavigationBar:
                wide ? null : _SHEBottomNav(navigationShell: shell),
          );
        },
      ),
    );
  }
}

class _SHEBottomNav extends StatelessWidget {
  const _SHEBottomNav({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final tabs = ShellTab.values;
    final current = navigationShell.currentIndex;

    return Container(
      decoration: BoxDecoration(
        color: V3Colors.navBar, // themed (was a hardcoded dark literal)
        border: Border(top: BorderSide(color: V3Colors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(V3Spacing.sm, 6, V3Spacing.sm, 4),
          child: Row(
            children: [
              for (int i = 0; i < tabs.length; i++)
                Expanded(
                  child: _TabButton(
                    tab: tabs[i],
                    active: current == i,
                    // Initial location: tapping the active tab again pops that
                    // tab's stack back to its root, which is what users expect
                    // from a bottom nav.
                    onTap: () => navigationShell.goBranch(
                      i,
                      initialLocation: i == current,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final ShellTab tab;
  final bool active;
  final VoidCallback onTap;

  /// Localised label for the tab (see [_shellTabLabel]).
  String _label(BuildContext context) => _shellTabLabel(context, tab);

  @override
  Widget build(BuildContext context) {
    final label = _label(context);
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The prototype's active tab sits in a translucent primary pill.
            AnimatedContainer(
              duration: V3Duration.fast,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: active
                    ? V3Colors.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(V3Radius.md),
              ),
              child: Icon(
                active ? tab.activeIcon : tab.icon,
                size: 19,
                color: active ? V3Colors.primary : V3Colors.dim,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? V3Colors.primary : V3Colors.dim,
                fontSize: V3Typography.navLabel,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Localised label for a shell tab, shared by the bottom nav and the wide-screen
/// rail.
///
/// Uses the dedicated `nav*` keys. These were added because the tabs used to
/// reuse unrelated strings, which made the bar actively misleading:
/// Home rendered "My Home", the Automations tab rendered "Scenes", and the
/// More tab rendered "Settings" — so tapping "Settings" opened the More hub
/// and looked like a broken/blank screen.
///
/// (The keys are hand-written into the generated AppLocalizations classes
/// because `flutter gen-l10n` cannot run on this host — Dart spawns piped
/// children and dies with ERROR_PIPE_BUSY. Keep the three files in sync if
/// these are ever regenerated.)
String _shellTabLabel(BuildContext context, ShellTab tab) {
  final l = AppLocalizations.of(context);
  if (l == null) return tab.label;
  return switch (tab) {
    ShellTab.home => l.navHome,
    ShellTab.devices => l.navDevices,
    ShellTab.automations => l.navAutomations,
    ShellTab.energy => l.navEnergy,
    ShellTab.more => l.navMore,
  };
}

/// Wide-screen counterpart to [_SHEBottomNav]: the same five destinations in a
/// Material 3 [NavigationRail], shown once the window is at least
/// [V3Breakpoints.mobile] wide (tablet / foldable / desktop). Keeps the app's
/// dark palette so the rail reads as chrome rather than a Material default.
class _SHENavRail extends StatelessWidget {
  const _SHENavRail({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final tabs = ShellTab.values;
    final current = navigationShell.currentIndex;

    return NavigationRail(
      backgroundColor: V3Colors.navBar, // themed (matches the bottom nav)
      selectedIndex: current,
      onDestinationSelected: (i) => navigationShell.goBranch(
        i,
        initialLocation: i == current,
      ),
      labelType: NavigationRailLabelType.all,
      indicatorColor: V3Colors.primary.withValues(alpha: 0.15),
      selectedIconTheme:  IconThemeData(color: V3Colors.primary, size: 22),
      unselectedIconTheme:  IconThemeData(color: V3Colors.dim, size: 22),
      selectedLabelTextStyle:  TextStyle(
        color: V3Colors.primary,
        fontSize: V3Typography.navLabel,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle:  TextStyle(
        color: V3Colors.dim,
        fontSize: V3Typography.navLabel,
        fontWeight: FontWeight.w500,
      ),
      destinations: [
        for (final t in tabs)
          NavigationRailDestination(
            icon: Icon(t.icon),
            selectedIcon: Icon(t.activeIcon),
            label: Text(_shellTabLabel(context, t)),
          ),
      ],
    );
  }
}
