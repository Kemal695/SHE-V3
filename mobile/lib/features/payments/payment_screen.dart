// =============================================================================
// SHE V3 — Payment screen (Telebirr via Chapa)
// =============================================================================
// V3-MOBILE-APP §10. V3-PAYMENTS §3.
// Flow: POST /payments/initiate → open checkout_url via flutter_web_auth_2
//       → user pays via Telebirr/CBE Birr → Chapa webhook → subscription activated
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_theme.dart';
import 'payment_service.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  final String plan;   // B2C_PREMIUM | B2C_FAMILY

  const PaymentScreen({super.key, required this.plan});

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  bool _isLoading = false;
  String? _error;
  String? _checkoutUrl;

  @override
  void initState() {
    super.initState();
    _initiatePayment();
  }

  Future<void> _initiatePayment() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await ref.read(paymentServiceProvider).initiatePayment(
        plan: widget.plan,
      );
      setState(() {
        _checkoutUrl = result['checkout_url'];
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openCheckout() async {
    if (_checkoutUrl == null) return;

    try {
      // Open Chapa checkout URL in in-app browser
      // V3-PAYMENTS §3.1 — flutter_web_auth_2 opens checkout_url
      // User pays via Telebirr/CBE Birr/card on Chapa-hosted page
      // Chapa redirects to return_url (she-app://payments/success)
      // + sends webhook to Spring Boot → subscription activated
      //
      // TODO: integrate flutter_web_auth_2
      // final result = await FlutterWebAuth2.authenticate(
      //   url: _checkoutUrl!,
      //   callbackUrlScheme: 'she-app',
      // );
      //
      // For Phase 3: show success + wait for WebSocket subscription_activated event

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment initiated. Complete payment in your browser, then return to the app.'),
            duration: Duration(seconds: 5),
          ),
        );
        // Return to dashboard — WebSocket push will unlock premium features
        context.go('/dashboard');
      }
    } catch (e) {
      setState(() => _error = 'Payment failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final planPrice = widget.plan == 'B2C_PREMIUM' ? '150 ETB/mo' : '300 ETB/mo';
    final planName = widget.plan == 'B2C_PREMIUM' ? 'Premium' : 'Family';

    return Scaffold(
      appBar: AppBar(title: Text('Upgrade to $planName')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Plan summary ----
              // Scrollable: with the error line shown (or in landscape) the fixed
              // Column used to overflow and clip the CTA.
              Expanded(
                child: SingleChildScrollView(
                  child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.workspace_premium, size: 48, color: SheTheme.brightSkyBlue),
                      const SizedBox(height: 16),
                      Text(
                        'SHE $planName',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        planPrice,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: SheTheme.brightSkyBlue,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Plan features
                      _planFeature(context, 'Unlimited devices'),
                      _planFeature(context, 'Automations + scenes'),
                      _planFeature(context, 'OTA updates'),
                      _planFeature(context, 'Energy monitoring'),
                      _planFeature(context, 'Anomaly alerts'),
                      if (widget.plan == 'B2C_FAMILY')
                        _planFeature(context, '5 home members + shared homes'),
                    ],
                  ),
                ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---- Loading ----
              if (_isLoading)
                const Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text('Initiating payment...'),
                    ],
                  ),
                ),

              // ---- Error ----
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!, style: const TextStyle(color: SheTheme.error)),
                ),

              // ---- Pay button ----
              if (_checkoutUrl != null)
                ElevatedButton.icon(
                  onPressed: _openCheckout,
                  icon: const Icon(Icons.payment),
                  label: Text('Pay $planPrice via Telebirr'),
                ),

              const SizedBox(height: 16),

              // ---- Payment methods ----
              Text(
                'Accepted: Telebirr, CBE Birr, Cards',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _planFeature(BuildContext context, String feature) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: SheTheme.success, size: 20),
          const SizedBox(width: 8),
          Text(feature, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
