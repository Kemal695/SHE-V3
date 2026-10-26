// =============================================================================
// Voice diagnostics tests (Phase 6, §D.12) — privacy + fire-and-forget safety
// =============================================================================
// The Plan §3 guarantee: diagnostics capture latency/error categories only and
// NEVER send a raw audio buffer to the native side. These tests pin that, and
// that the calls are fire-and-forget when the platform side is missing.
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/robi/data/voice_diagnostics.dart';

void main() {
  const channel = MethodChannel('she/robi');

  group('no audio payload is ever sent to the native side', () {
    late List<Object?> payloads;
    setUp(() {
      payloads = [];
      TestWidgetsFlutterBinding.ensureInitialized();
      channel.setMockMethodCallHandler((call) async {
        payloads.add(call.arguments);
        return null;
      });
    });
    tearDown(() => channel.setMockMethodCallHandler(null));

    test('log / traceStage / traceError send only a string message', () {
      VoiceLog.log('heard="lights" amharic=true');
      VoiceDiagnostics.traceStage('parse', durationMs: 12);
      VoiceDiagnostics.traceStage('wake_to_capture');
      VoiceDiagnostics.traceError('mic', 'busy');

      expect(payloads, hasLength(4));
      for (final args in payloads) {
        final map = args as Map<Object?, Object?>;
        final msg = map['msg'];
        // The only thing we ever transmit is a short log string.
        expect(msg is String, isTrue);
        // And it is never an audio container of any kind.
        expect(msg is! List, isTrue);
        expect(msg is! Uint8List, isTrue);
        expect(msg is! Int8List, isTrue);
        expect(msg is! Int16List, isTrue);
        expect(msg is! Int32List, isTrue);
        expect(msg is! Float32List, isTrue);
        expect(msg is! Float64List, isTrue);
      }
    });
  });

  group('diagnostics are fire-and-forget', () {
    test('no throw and no unhandled error when the channel is missing', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      MethodChannel('she/robi').setMockMethodCallHandler(null);
      expect(
        () {
          VoiceLog.log('x');
          VoiceDiagnostics.traceStage('parse', durationMs: 3);
          VoiceDiagnostics.traceError('parse', 'ambiguous');
        },
        returnsNormally,
      );
    });
  });
}
