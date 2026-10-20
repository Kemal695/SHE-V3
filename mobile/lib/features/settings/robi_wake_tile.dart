// =============================================================================
// SHE V3 — "Robi wake word" setting (Phase 4, Stage 1)
// =============================================================================
// Opt-in only, default OFF, with the privacy disclosure the spec requires
// (§11) shown BEFORE anything starts listening.
//
// Stage 1 honesty: the on-device speech model is not bundled yet, so enabling
// this starts the foreground service and then reports "model not installed".
// The switch refuses to stay on, because a switch that looks on while nothing is
// listening is exactly the kind of lie this project keeps fixing.
// =============================================================================

import 'package:flutter/material.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/voice/robi_wake.dart';

class RobiWakeTile extends StatefulWidget {
  const RobiWakeTile({super.key});

  @override
  State<RobiWakeTile> createState() => _RobiWakeTileState();
}

class _RobiWakeTileState extends State<RobiWakeTile> {
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    robiWake.isRunning().then((running) {
      if (mounted) setState(() => _enabled = running);
    });
  }

  Future<void> _toggle(bool wantOn) async {
    if (_busy) return;

    if (!wantOn) {
      setState(() => _busy = true);
      await robiWake.stop();
      if (!mounted) return;
      setState(() {
        _enabled = false;
        _busy = false;
      });
      return;
    }

    // Privacy disclosure first — never start a microphone without saying so.
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable "Hey Robi"?'),
        content: const Text(
          'Robi listens for the phrase on this phone. Audio is analysed in '
          'memory and is never uploaded or saved.\n\n'
          'A microphone indicator and a Robi notification stay visible while '
          'this is on. It stops when you turn it off, and it cannot keep '
          'listening after the app is force-stopped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;

    setState(() => _busy = true);
    final status = await robiWake.start();
    if (!mounted) return;

    setState(() {
      _busy = false;
      // Only a genuinely listening service may show the switch as ON.
      _enabled = status == RobiWakeStatus.listening;
    });

    final message = switch (status) {
      RobiWakeStatus.listening => 'Robi is listening for "Hey Robi"',
      RobiWakeStatus.modelMissing =>
        'The speech model is not installed yet, so Robi is not listening.',
      RobiWakeStatus.permissionDenied =>
        'Microphone permission is required for the wake word.',
      RobiWakeStatus.notificationDenied =>
        'Allow notifications — Android requires one while the microphone is on.',
      RobiWakeStatus.failed => 'Could not start the wake word service.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: V3Colors.primary.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(V3Radius.full),
        ),
        child:  Icon(Icons.graphic_eq, color: V3Colors.primary, size: 20),
      ),
      title: const Text('Robi wake word'),
      subtitle: const Text(
        'Say "Hey Robi" — requires the on-device speech model',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Switch(value: _enabled, onChanged: _toggle),
      onTap: () => _toggle(!_enabled),
    );
  }
}
