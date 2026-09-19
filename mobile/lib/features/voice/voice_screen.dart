// =============================================================================
// SHE V3 — Voice Control Screen (R16 only)
// =============================================================================
// Premium pulsing mic. No overflow (ListView). V3-VOICE-MATTER §1-2.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen>
    with TickerProviderStateMixin {
  bool _isListening = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: V3Colors.textPrimary),
            onPressed: () => context.go('/dashboard'),
          ),
          title: const Text('Voice Control'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(V3Spacing.lg),
            children: [
              const SizedBox(height: V3Spacing.xl),

              // ---- Pulsing mic button ----
              Center(
                child: GestureDetector(
                  onTap: () => setState(() => _isListening = !_isListening),
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) {
                      final scale = 1.0 + _pulseController.value * 0.15 * (_isListening ? 1 : 0);
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 120, height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isListening ? V3Colors.primary : V3Colors.surface,
                            boxShadow: _isListening
                                ? [
                                    BoxShadow(
                                      color: V3Colors.primary.withValues(alpha: 0.3 + _pulseController.value * 0.2),
                                      blurRadius: 30 + _pulseController.value * 20,
                                      spreadRadius: 5 + _pulseController.value * 10,
                                    ),
                                  ]
                                : [],
                          ),
                          child: Icon(
                            _isListening ? Icons.mic : Icons.mic_none,
                            size: 48,
                            color: _isListening ? Colors.white : V3Colors.textSecondary,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: V3Spacing.lg),

              // ---- Status text ----
              Center(
                child: Text(
                  _isListening ? 'Listening for "Hey Sheba"...' : 'Tap to start voice control',
                  style: TextStyle(
                    color: _isListening ? V3Colors.primary : V3Colors.textSecondary,
                    fontSize: V3Typography.bodySize,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: V3Spacing.xxl),

              // ---- Example commands card ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(V3Spacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.lightbulb_outline, color: V3Colors.warning, size: 20),
                          SizedBox(width: V3Spacing.sm),
                          Text('Example Commands', style: TextStyle(
                            color: V3Colors.textPrimary,
                            fontSize: V3Typography.titleSize - 2,
                            fontWeight: FontWeight.w600,
                          )),
                        ],
                      ),
                      const SizedBox(height: V3Spacing.md),
                      _commandRow('Hey Sheba, turn on the living room light'),
                      _commandRow('ሰበኣ የሳሎን ብርሃን አብር'),
                      _commandRow('Hey Sheba, turn off relay 3'),
                      _commandRow('ሰበኣ ሬሌ 3 አጥፋ'),
                      _commandRow('Hey Sheba, activate movie night scene'),
                      _commandRow('ሰበኣ የኃይል መጠን ስንት ነው'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: V3Spacing.lg),

              // ---- R16 notice ----
              Container(
                padding: const EdgeInsets.all(V3Spacing.md),
                decoration: BoxDecoration(
                  color: V3Colors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(V3Radius.md),
                  border: Border.all(color: V3Colors.warning.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: V3Colors.warning, size: 20),
                    SizedBox(width: V3Spacing.sm),
                    Expanded(
                      child: Text(
                        'Voice control is available on SHE-R16 only',
                        style: TextStyle(
                          color: V3Colors.warning,
                          fontSize: V3Typography.captionSize,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: V3Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.format_quote, size: 16, color: V3Colors.textSecondary),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Text(text, style: const TextStyle(
              color: V3Colors.textSecondary,
              fontSize: V3Typography.bodySize,
              height: 1.5,
            )),
          ),
        ],
      ),
    );
  }
}
