// =============================================================================
// SHE V3 — "Robi wake word" setting (Phase 4, Stage 2)
// =============================================================================
// Opt-in only, default OFF, with the privacy disclosure the spec requires
// (§11) shown BEFORE anything starts listening.
//
// The switch reflects the SERVICE, not the user's wish: it only shows ON once
// the detector reports `ready` (model present, microphone open). While the model
// downloads it shows progress and stays off, because a switch that looks on
// while nothing is listening is exactly the kind of lie this project keeps
// fixing.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/voice/robi_wake.dart';

class RobiWakeTile extends StatefulWidget {
  const RobiWakeTile({super.key});

  @override
  State<RobiWakeTile> createState() => _RobiWakeTileState();
}

class _RobiWakeTileState extends State<RobiWakeTile> {
  RobiWakeState _state = RobiWakeState.off;
  bool _busy = false;
  StreamSubscription<({String event, String? detail})>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = robiWake.events().listen(_onEvent);
    robiWake.isRunning().then((running) {
      if (!mounted) return;
      setState(() {
        _state = running
            ? const RobiWakeState(RobiWakePhase.starting)
            : RobiWakeState.off;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(({String event, String? detail}) e) {
    if (!mounted) return;
    setState(() {
      switch (e.event) {
        case 'downloading':
          _state = RobiWakeState(
            RobiWakePhase.downloading,
            detail: e.detail,
          );
        case 'ready':
          _state = const RobiWakeState(RobiWakePhase.listening);
        case 'hey_robi':
          // The phrase was heard. Nothing to do here — the app-level listener
          // opens the voice screen. Keep the tile showing the true state.
          break;
        case 'stopped':
          _state = RobiWakeState.off;
        case 'error':
        case 'model_missing':
          _state = RobiWakeState(RobiWakePhase.error, detail: e.detail);
      }
    });
  }

  Future<void> _toggle(bool wantOn) async {
    if (_busy) return;

    if (!wantOn) {
      setState(() => _busy = true);
      await robiWake.stop();
      if (!mounted) return;
      setState(() {
        _state = RobiWakeState.off;
        _busy = false;
      });
      return;
    }

    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable "Hey Robi"?'),
        content: const Text(
          'Robi listens for the phrase on this phone. Audio is analysed in '
          'memory and is never uploaded or saved.\n\n'
          'The first time, it downloads a 39 MB speech model over the internet.\n\n'
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

    setState(() {
      _busy = true;
      _state = const RobiWakeState(RobiWakePhase.starting);
    });
    final started = await robiWake.start();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!started) _state = RobiWakeState.off;
    });
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone and notification permissions are required for the '
            'wake word.',
          ),
        ),
      );
    }
  }

  String get _subtitle => switch (_state.phase) {
        RobiWakePhase.off =>
          'Say "Hey Robi" — downloads a 39 MB model on first use',
        RobiWakePhase.starting => 'Starting…',
        RobiWakePhase.downloading =>
          'Downloading speech model… ${_state.detail ?? '0'}%',
        RobiWakePhase.listening => 'Listening for "Hey Robi"',
        RobiWakePhase.error =>
          'Not listening: ${_state.detail ?? 'unknown error'}',
      };

  @override
  Widget build(BuildContext context) {
    final downloading = _state.phase == RobiWakePhase.downloading;
    final listening = _state.phase == RobiWakePhase.listening;

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
      subtitle: Text(
        _subtitle,
        style: TextStyle(
          color: _state.phase == RobiWakePhase.error
              ? V3Colors.error
              : V3Colors.textSecondary,
        ),
      ),
      trailing: (_busy || downloading)
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                // Real progress once we know it, indeterminate while starting.
                value: downloading && _state.detail != null
                    ? (int.tryParse(_state.detail!) ?? 0) / 100
                    : null,
              ),
            )
          : Switch(value: listening, onChanged: _toggle),
      onTap: () => _toggle(!listening),
    );
  }
}
