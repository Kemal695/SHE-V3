// =============================================================================
// SHE V3 — Payment service (Riverpod provider)
// =============================================================================
// V3-PAYMENTS §3. V3-API-SPECIFICATION §11.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';

final paymentServiceProvider = Provider<PaymentService>((ref) => PaymentService(ref));

class PaymentService {
  final Ref ref;
  PaymentService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  /// POST /api/v3/payments/initiate
  /// V3-PAYMENTS §3.1 — initiates Chapa transaction, returns checkout_url.
  Future<Map<String, dynamic>> initiatePayment({
    required String plan,   // B2C_PREMIUM | B2C_FAMILY | B2B_*
    String? idempotencyKey,
  }) async {
    final response = await _dio.post(ApiConstants.paymentsInitiate, data: {
      'plan': plan,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
    });
    return response.data['data'];
  }

  /// GET /api/v3/payments/verify/{txRef}
  Future<Map<String, dynamic>> verifyPayment(String txRef) async {
    final response = await _dio.get('${ApiConstants.paymentsVerify}/$txRef');
    return response.data['data'];
  }

  /// GET /api/v3/subscriptions/current
  Future<Map<String, dynamic>> getCurrentSubscription() async {
    final response = await _dio.get(ApiConstants.subscriptionsCurrent);
    return response.data['data'];
  }
}
