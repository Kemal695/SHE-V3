// =============================================================================
// SHE V3 — Current subscription (Riverpod provider)
// =============================================================================
// V3-PAYMENTS §3. Holds the authenticated user's current subscription, fetched
// from GET /api/v3/subscriptions/current. It is invalidated by the WebSocket
// `subscription_activated` event (see ws_client.dart) so the UI reflects an
// upgrade/extension immediately, without a reconnect.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'payment_service.dart';

final currentSubscriptionProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.read(paymentServiceProvider).getCurrentSubscription();
});
