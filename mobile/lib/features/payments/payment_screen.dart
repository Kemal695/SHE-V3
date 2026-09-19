// =============================================================================
// SHE V3 — Payment Screen (Telebirr via Chapa)
// =============================================================================
// Premium plan cards. No overflow (ListView). Keyboard-safe.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import 'payment_service.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  final String plan;

  const PaymentScreen({super.key, required this.plan});

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  String? _checkoutUrl;

  @override
  void initState() {
    super.initState();
    _initiatePayment();
  }

  Future<void> _initiatePayment() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await ref.read(paymentServiceProvider).initiatePayment(plan: widget.plan);
      setState(() {
        _checkoutUrl = result['checkout_url'];
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().contains('502')
            ? 'Payment service not available. Please try again later.'
            : 'Failed to initiate payment. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _openCheckout() async {
    // TODO: integrate flutter_web_auth_2 to open checkout_url
    // For now, show success message and return to dashboard
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment initiated. Complete payment in your browser, then return to the app.'),
          duration: Duration(seconds: 4),
        ),
      );
      context.go('/dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    final planName = widget.plan == 'B2C_PREMIUM' ? 'Premium' : 'Family';
    final planPrice = widget.plan == 'B2C_PREMIUM' ? '150 ETB' : '300 ETB';

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: V3Colors.textPrimary),
            onPressed: () => context.go('/dashboard'),
          ),
          title: Text('Upgrade to $planName'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(V3Spacing.lg),
            children: [
              // ---- Plan summary card ----
              Card(
                child: Container(
                  padding: const EdgeInsets.all(V3Spacing.lg),
                  child: Column(
                    children: [
                      Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [V3Colors.primary, V3Colors.secondary],
                          ),
                          borderRadius: BorderRadius.circular(V3Radius.xl),
                          boxShadow: V3Colors.activeGlow(isOn: true),
                        ),
                        child: const Icon(Icons.workspace_premium, color: Colors.white, size: 28),
                      ),
                      const SizedBox(height: V3Spacing.md),
                      Text('SHE $planName', style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: V3Spacing.xs),
                      Text(planPrice, style: const TextStyle(
                        color: V3Colors.primary,
                        fontSize: V3Typography.titleSize,
                        fontWeight: FontWeight.w700,
                      )),
                      const SizedBox(height: V3Spacing.lg),
                      // Features
                      _featureRow('Unlimited devices'),
                      _featureRow('Automations + scenes'),
                      _featureRow('OTA updates'),
                      _featureRow('Energy monitoring'),
                      _featureRow('Anomaly alerts'),
                      if (widget.plan == 'B2C_FAMILY')
                        _featureRow('5 members + shared homes'),
                      if (widget.plan == 'B2C_FAMILY')
                        _featureRow('Priority support'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: V3Spacing.lg),

              // ---- Loading ----
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(V3Spacing.lg),
                  child: Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(color: V3Colors.primary, strokeWidth: 3),
                        SizedBox(height: V3Spacing.md),
                        Text('Initiating payment...'),
                      ],
                    ),
                  ),
                ),

              // ---- Error ----
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(V3Spacing.md),
                  margin: const EdgeInsets.only(bottom: V3Spacing.md),
                  decoration: BoxDecoration(
                    color: V3Colors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    border: Border.all(color: V3Colors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: V3Colors.error, size: 20),
                      const SizedBox(width: V3Spacing.sm),
                      Expanded(child: Text(_errorMessage!,
                          style: const TextStyle(color: V3Colors.error, fontSize: V3Typography.captionSize))),
                    ],
                  ),
                ),

              // ---- Pay button ----
              if (_checkoutUrl != null)
                ElevatedButton.icon(
                  onPressed: _openCheckout,
                  icon: const Icon(Icons.payment),
                  label: Text('Pay $planPrice via Telebirr'),
                ),

              if (_errorMessage != null)
                ElevatedButton(
                  onPressed: _initiatePayment,
                  child: const Text('Retry'),
                ),

              const SizedBox(height: V3Spacing.md),

              // ---- Payment methods ----
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.phone_android, size: 16, color: V3Colors.textSecondary),
                  SizedBox(width: V3Spacing.xs),
                  Text('Telebirr', style: TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.captionSize)),
                  SizedBox(width: V3Spacing.md),
                  Icon(Icons.account_balance, size: 16, color: V3Colors.textSecondary),
                  SizedBox(width: V3Spacing.xs),
                  Text('CBE Birr', style: TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.captionSize)),
                  SizedBox(width: V3Spacing.md),
                  Icon(Icons.credit_card, size: 16, color: V3Colors.textSecondary),
                  SizedBox(width: V3Spacing.xs),
                  Text('Cards', style: TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.captionSize)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: V3Spacing.xs),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: V3Colors.success, size: 18),
          const SizedBox(width: V3Spacing.sm),
          Expanded(child: Text(text, style: const TextStyle(
            color: V3Colors.textPrimary,
            fontSize: V3Typography.bodySize,
          ))),
        ],
      ),
    );
  }
}
