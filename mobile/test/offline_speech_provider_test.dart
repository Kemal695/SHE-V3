// =============================================================================
// Tests for the offline speech provider (Phase 3, Plan §D.9 — gated stub).
// =============================================================================
// The offline provider must never claim to be available while it is disabled,
// so wiring it in by mistake fails loudly rather than silently doing nothing.
// This test is host-safe: the provider imports only the pure recognition
// contract, not speech_to_text.
import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/robi/data/offline_speech_provider.dart';

void main() {
  group('OfflineSpeechProvider (gated stub)', () {
    test('reports unsupported while disabled', () async {
      final p = OfflineSpeechProvider();
      final availability = await p.probe();
      expect(availability.available, isFalse);
      expect(p.isListening, isFalse);
      expect(p.isAmharic, isFalse);
    });

    test('never claims to be listening', () {
      expect(OfflineSpeechProvider().isListening, isFalse);
    });

    test('master flag is off', () {
      expect(offlineAsrEnabled, isFalse);
    });
  });
}
