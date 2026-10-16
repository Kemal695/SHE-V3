// =============================================================================
// SHE V3 — Notification service (design sheet screen 15)
// =============================================================================
// The server-side half of the Notifications screen. The client store
// (notification_store.dart) already derives LIVE notifications from WebSocket
// events; this fetches the PERSISTED inbox so (a) anything that happened while
// the app was closed still appears, and (b) read-state is shared across the
// user's devices.
//
// V3-API-SPECIFICATION §12. Backed by NotificationController.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';
import 'notification_store.dart';

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService(ref));

class NotificationService {
  final Ref ref;
  NotificationService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  /// GET /api/v3/notifications/recent?limit=50 — newest first.
  Future<List<AppNotification>> recent({int limit = 50}) async {
    final response = await _dio.get(
      ApiConstants.notificationsRecent,
      queryParameters: {'limit': limit},
    );
    final rows = response.data['data'] as List<dynamic>? ?? const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(_fromServer)
        .toList();
  }

  /// POST /api/v3/notifications/{id}/read
  Future<void> markRead(String id) async {
    await _dio.post(ApiConstants.notificationRead(id));
  }

  /// POST /api/v3/notifications/read-all
  Future<void> markAllRead() async {
    await _dio.post(ApiConstants.notificationsReadAll);
  }

  /// Server row → [AppNotification]. The server already maps `category` into the
  /// mobile vocabulary (system / devices / security); this tolerates either form.
  AppNotification _fromServer(Map<String, dynamic> j) {
    return AppNotification(
      id: j['id']?.toString() ?? '',
      kind: j['kind']?.toString() ?? 'server',
      title: j['title']?.toString() ?? '',
      body: j['body']?.toString() ?? '',
      category: switch ((j['category']?.toString() ?? '').toLowerCase()) {
        'devices' || 'device' => NotificationCategory.devices,
        'security' => NotificationCategory.security,
        _ => NotificationCategory.system,
      },
      // The server sends a UTC Instant; convert so the "time ago" label reads
      // against the device's local clock.
      at: DateTime.tryParse(j['at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      read: j['read'] == true,
      nodeId: j['nodeId']?.toString(),
    );
  }
}
