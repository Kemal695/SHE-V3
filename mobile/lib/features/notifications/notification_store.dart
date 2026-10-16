// =============================================================================
// SHE V3 — Notifications store (design sheet screen 15)
// =============================================================================
// WHY THIS IS DERIVED, NOT FETCHED
// ---------------------------------
// The design sheet shows a populated Notifications list, but the backend has no
// notification API: there is no NotificationController, no notification table,
// and `notification.received` is only ever *mentioned in a comment* in
// `WsEventBus.java` — nothing publishes it. A screen that waited for that event
// would be permanently empty.
//
// So this store is built from the events the backend DOES emit (verified by
// reading every `wsEventBus.publish*` call site):
//
//   node.presence          -> "X is offline" / "X is back online"
//   ota.progress           -> firmware update lifecycle
//   subscription_activated -> payment / plan change
//   node.state             -> security-relevant changes (gate, door, lock)
//
// `notification.received` is still handled, so the day the backend starts
// pushing real notifications they appear with no client change.
//
// Deliberately NOT derived from `energy.update` or generic `node.state`: those
// fire continuously (every relay toggle, every meter tick) and would bury the
// list in noise.
// =============================================================================

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

/// Which filter chip a notification belongs under (design sheet: System /
/// Devices / Security).
enum NotificationCategory { system, devices, security }

class AppNotification {
  /// Stable id so the list can key rows and dedupe repeats.
  final String id;

  /// Origin, e.g. `presence`, `ota`, `subscription`, `security`, `server`.
  /// Kept so the UI can pick an icon without re-parsing the title.
  final String kind;

  /// Headline. For `presence` this is generic ("Device offline") because the
  /// WS payload carries only a nodeId — the screen substitutes the real node
  /// name from [nodeId] once it has the home's node list.
  final String title;

  /// Supporting line, e.g. "Living Room · 10:45 AM".
  final String body;

  final NotificationCategory category;
  final DateTime at;
  final bool read;

  /// Set when the notification refers to a specific node, so the UI can resolve
  /// a human name lazily (see notifications_screen.dart).
  final String? nodeId;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.category,
    required this.at,
    this.read = false,
    this.nodeId,
  });

  AppNotification copyWith({bool? read}) => AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        category: category,
        at: at,
        read: read ?? this.read,
        nodeId: nodeId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'body': body,
        'category': category.name,
        'at': at.toIso8601String(),
        'read': read,
        if (nodeId != null) 'nodeId': nodeId,
      };

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id']?.toString() ?? '',
        kind: j['kind']?.toString() ?? 'generic',
        title: j['title']?.toString() ?? '',
        body: j['body']?.toString() ?? '',
        category: NotificationCategory.values.firstWhere(
          (c) => c.name == j['category'],
          orElse: () => NotificationCategory.system,
        ),
        at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
        read: j['read'] == true,
        nodeId: j['nodeId']?.toString(),
      );
}

/// The list itself. Newest first, capped so it cannot grow without bound.
final notificationStoreProvider =
    NotifierProvider<NotificationStore, List<AppNotification>>(
  NotificationStore.new,
);

/// Unread badge count for the dashboard bell.
///
/// A separate provider (rather than a getter on the notifier) because a getter
/// would not rebuild watchers when the list changes.
final unreadNotificationCountProvider = Provider<int>((ref) {
  return ref.watch(notificationStoreProvider).where((n) => !n.read).length;
});

class NotificationStore extends Notifier<List<AppNotification>> {
  /// The cache box is already opened in `main()` for exactly this kind of
  /// small, non-secret, restart-surviving data.
  static const _boxName = 'she_cache';
  static const _key = 'notifications';
  static const _cap = 100;

  @override
  List<AppNotification> build() {
    try {
      final raw = Hive.box(_boxName).get(_key);
      if (raw is String && raw.isNotEmpty) {
        return (jsonDecode(raw) as List<dynamic>)
            .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // Corrupt/absent cache is not fatal — start empty.
    }
    return const [];
  }

  /// Prepend [n]. Silently drops an exact repeat of the newest entry so a
  /// flapping device (offline/offline/offline) cannot flood the list.
  void add(AppNotification n) {
    if (state.isNotEmpty) {
      final head = state.first;
      if (head.kind == n.kind &&
          head.title == n.title &&
          head.nodeId == n.nodeId &&
          n.at.difference(head.at).inMinutes.abs() < 2) {
        return;
      }
    }
    state = [n, ...state].take(_cap).toList();
    _persist();
  }

  /// Merge persisted server notifications into the list.
  ///
  /// Server rows are the source of truth for HISTORY (they include events that
  /// happened while the app was closed); the live-derived rows are kept too,
  /// because a just-arrived event may not be persisted yet. Deduped by id, newest
  /// first, capped like everything else. Read-state is OR-ed so a row another
  /// device already read does not flip back to unread here.
  void merge(List<AppNotification> serverRows) {
    if (serverRows.isEmpty) return;
    final result = [...state];
    for (final n in serverRows) {
      // Skip a server row a live-derived row already represents. The live path
      // mints its own id, so an id-only merge would show every event twice;
      // match on content within a short window instead.
      final duplicate = result.any((e) =>
          e.kind == n.kind &&
          e.title == n.title &&
          e.nodeId == n.nodeId &&
          e.at.difference(n.at).inMinutes.abs() < 5);
      if (duplicate) continue;
      result.add(n);
    }
    result.sort((a, b) => b.at.compareTo(a.at));
    state = result.take(_cap).toList();
    _persist();
  }

  void markAllRead() {
    if (state.every((n) => n.read)) return;
    state = state.map((n) => n.read ? n : n.copyWith(read: true)).toList();
    _persist();
  }

  void markRead(String id) {
    state = state
        .map((n) => n.id == id ? n.copyWith(read: true) : n)
        .toList();
    _persist();
  }

  void clear() {
    state = const [];
    _persist();
  }

  void _persist() {
    try {
      Hive.box(_boxName).put(
        _key,
        jsonEncode(state.map((n) => n.toJson()).toList()),
      );
    } catch (_) {
      // Persistence is best-effort; the in-memory list is still correct.
    }
  }
}

/// Monotonic counter so two notifications created in the same millisecond get
/// distinct ids.
int _seq = 0;

String _nextId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

/// Translates a WebSocket event into a notification, or null when the event is
/// not worth surfacing.
///
/// Kept as a pure function (no `ref`) so the WS client stays the only thing that
/// knows about sockets and this stays trivially testable.
AppNotification? notificationFromWsEvent(
  String event,
  Map<String, dynamic> data,
) {
  final now = DateTime.now();

  switch (event) {
    case 'node.presence':
      final online = data['isOnline'] == true;
      return AppNotification(
        id: _nextId(),
        kind: 'presence',
        // Generic on purpose — the payload has no node name. The screen swaps
        // in the real name using `nodeId`.
        title: online ? 'Device back online' : 'Device offline',
        body: online
            ? 'Reconnected and reporting normally.'
            : 'Check power and network for this device.',
        category: NotificationCategory.devices,
        at: now,
        nodeId: data['nodeId']?.toString(),
      );

    case 'ota.progress':
      final status = (data['status']?.toString() ?? '').toUpperCase();
      final version = data['version']?.toString();
      final progress = data['progress'];

      // Only the milestones are interesting. A running percentage fires
      // repeatedly and belongs on the OTA screen, not in this list.
      final String title;
      if (status.contains('AVAILABLE')) {
        title = 'Firmware update available';
      } else if (status.contains('COMPLETE') ||
          status.contains('SUCCESS') ||
          status.contains('DONE')) {
        title = 'Firmware update complete';
      } else if (status.contains('FAIL')) {
        title = 'Firmware update failed';
      } else {
        return null;
      }

      return AppNotification(
        id: _nextId(),
        kind: 'ota',
        title: title,
        body: [
          if (version != null && version.isNotEmpty) version,
          if (progress != null) '$progress%',
        ].join(' · '),
        category: NotificationCategory.system,
        at: now,
      );

    case 'subscription_activated':
      final plan = data['plan']?.toString();
      return AppNotification(
        id: _nextId(),
        kind: 'subscription',
        title: 'Payment successful',
        body: plan == null || plan.isEmpty
            ? 'Your subscription is now active.'
            : '$plan is now active.',
        category: NotificationCategory.system,
        at: now,
      );

    case 'node.state':
      // Only security-relevant channels. Every light toggle also arrives as
      // node.state, and those must not generate notifications.
      final deviceName = data['deviceName']?.toString() ?? '';
      final n = deviceName.toLowerCase();
      final isSecurity = n.contains('gate') ||
          n.contains('door') ||
          n.contains('lock') ||
          n.contains('alarm');
      if (!isSecurity) return null;

      final param = data['paramName']?.toString() ?? '';
      final value = data['value'];
      return AppNotification(
        id: _nextId(),
        kind: 'security',
        title: 'Door Access',
        body: '$deviceName · $param ${_prettyValue(value)}',
        category: NotificationCategory.security,
        at: now,
        nodeId: data['nodeId']?.toString(),
      );

    case 'notification.received':
      // Emitted by the backend's NotificationService once an inbox row is
      // persisted, so a live client sees it without waiting for a refetch.
      // Honour the server's own `kind` so it collapses with the equivalent
      // live-derived entry (see NotificationStore.add) instead of duplicating.
      final title = data['title']?.toString();
      if (title == null || title.isEmpty) return null;
      final rawCat = data['category']?.toString().toLowerCase();
      return AppNotification(
        id: _nextId(),
        kind: data['kind']?.toString() ?? 'server',
        title: title,
        body: data['body']?.toString() ?? '',
        category: switch (rawCat) {
          'devices' || 'device' => NotificationCategory.devices,
          'security' => NotificationCategory.security,
          _ => NotificationCategory.system,
        },
        at: now,
        nodeId: data['nodeId']?.toString(),
      );

    default:
      return null;
  }
}

String _prettyValue(Object? v) {
  if (v == true) return 'On';
  if (v == false) return 'Off';
  return v?.toString() ?? '';
}
