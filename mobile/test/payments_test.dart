// =============================================================================
// SHE V3 — Payments feature tests
// =============================================================================
// Covers the Phase 3 mobile payments wiring: the subscription provider and the
// PaymentScreen happy + failure paths.
//
// HTTP is mocked by swapping dio's HttpClientAdapter, so these tests need no
// network, no backend, and no mocking library (dio ships the adapter interface).
// =============================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:she_mobile/core/network/dio_client.dart';
import 'package:she_mobile/features/payments/payment_screen.dart';
import 'package:she_mobile/features/payments/subscription_provider.dart';

/// Minimal dio adapter that returns a canned JSON body (or a given status code).
class _MockAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, dynamic> body;

  _MockAdapter({this.statusCode = 200, required this.body});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _mockDio({int statusCode = 200, required Map<String, dynamic> body}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = _MockAdapter(statusCode: statusCode, body: body);
  return dio;
}

void main() {
  group('currentSubscriptionProvider', () {
    test('unwraps the subscription payload from GET /subscriptions/current',
        () async {
      final container = ProviderContainer(overrides: [
        dioProvider.overrideWithValue(_mockDio(body: {
          'data': {
            'plan': 'B2C_PREMIUM',
            'status': 'ACTIVE',
            'is_premium': true,
          },
        })),
      ]);
      addTearDown(container.dispose);

      final sub = await container.read(currentSubscriptionProvider.future);

      expect(sub['plan'], 'B2C_PREMIUM');
      expect(sub['status'], 'ACTIVE');
      expect(sub['is_premium'], isTrue);
    });

    test('reports the free plan for a default B2C user', () async {
      final container = ProviderContainer(overrides: [
        dioProvider.overrideWithValue(_mockDio(body: {
          'data': {'plan': 'B2C_FREE', 'status': 'ACTIVE', 'is_premium': false},
        })),
      ]);
      addTearDown(container.dispose);

      final sub = await container.read(currentSubscriptionProvider.future);

      expect(sub['plan'], 'B2C_FREE');
      expect(sub['is_premium'], isFalse);
    });
  });

  group('PaymentScreen', () {
    testWidgets('shows the plan and enables payment once initiated',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dioProvider.overrideWithValue(_mockDio(body: {
            'data': {'checkout_url': 'https://checkout.test/pay'},
          })),
        ],
        child: const MaterialApp(home: PaymentScreen(plan: 'B2C_PREMIUM')),
      ));

      await tester.pump(); // kicks off POST /payments/initiate
      await tester.pumpAndSettle(); // let the future complete

      expect(find.text('SHE Premium'), findsOneWidget);
      expect(find.text('150 ETB/mo'), findsOneWidget);
      expect(find.text('Pay 150 ETB/mo via Telebirr'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders the Family plan pricing', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dioProvider.overrideWithValue(_mockDio(body: {
            'data': {'checkout_url': 'https://checkout.test/pay'},
          })),
        ],
        child: const MaterialApp(home: PaymentScreen(plan: 'B2C_FAMILY')),
      ));

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('SHE Family'), findsOneWidget);
      expect(find.text('300 ETB/mo'), findsOneWidget);
      // Family adds the shared-homes bullet.
      expect(find.text('5 home members + shared homes'), findsOneWidget);
    });

    testWidgets('shows an error and no pay button when initiation fails',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dioProvider.overrideWithValue(_mockDio(
            statusCode: 500,
            body: {
              'error': {'code': 'INTERNAL_ERROR'},
            },
          )),
        ],
        child: const MaterialApp(home: PaymentScreen(plan: 'B2C_PREMIUM')),
      ));

      await tester.pump();
      await tester.pumpAndSettle();

      // Plan summary still renders...
      expect(find.text('SHE Premium'), findsOneWidget);
      // ...but there is no checkout URL, so no pay button.
      expect(find.text('Pay 150 ETB/mo via Telebirr'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
