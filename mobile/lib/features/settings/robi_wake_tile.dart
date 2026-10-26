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

  /// Whether the detector should hold the microphone and run continuously.
  ///
  /// Off by default: holding the mic makes it exclusive, which stops the normal
  /// in-app voice commands from working at all.
  bool _continuous = false;
  StreamSubscription<({String event, String? detail})>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = robiWake.events().listen(_onEvent);
    _refresh();
  }

  /// Read the SERVICE's state rather than waiting for an event.
  ///
  /// If Robi was already running before this screen opened, no new event is ever
  /// emitted — the tile would sit on "Starting…" forever while the detector was
  /// in fact listening. Ask, don't wait.
  Future<void> _refresh() async {
    final running = await robiWake.isRunning();
    if (!mounted) return;
    if (!running) {
      setState(() => _state = RobiWakeState.off);
      return;
    }
    // Read the SERVICE's real continuous state. `_continuous` is widget-local
    // and resets to false whenever Settings is reopened; trusting it showed
    // "armed" (and the sub-switch OFF) while the detector was actually holding
    // the microphone, and the next main-switch toggle then silently disabled
    // continuous detection.
    final continuous = await robiWake.isContinuous();
    if (!mounted) return;
    setState(() {
      _continuous = continuous;
      _state = continuous
          ? const RobiWakeState(RobiWakePhase.listening)
          : const RobiWakeState(RobiWakePhase.armed);
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
        case 'armed':
          _state = const RobiWakeState(RobiWakePhase.armed);
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
        title: const Text('Enable Robi?'),
        content: Text(
          _continuous
              ? 'Robi will listen continuously for "Hey Robi". Audio is analysed '
                  'in memory and never uploaded.\n\n'
                  'WARNING: this takes the microphone, so the normal in-app voice '
                  'commands will STOP working while it is on.\n\n'
                  'The first time, it downloads a 39 MB speech model.'
              : 'Robi will show a notification you can tap to open the microphone '
                  'instantly, from any app.\n\n'
                  'It does NOT listen continuously and does NOT hold the '
                  'microphone, so your normal voice commands keep working.',
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
    final started = await robiWake.start(continuous: _continuous);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (started) {
        _state = _continuous
            ? const RobiWakeState(RobiWakePhase.starting)
            : const RobiWakeState(RobiWakePhase.armed);
      } else {
        _state = RobiWakeState.off;
      }
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
      return;
    }

    // Say how to use it. "Hey Robi" does NOT work in armed mode by design — the
    // service takes no microphone — and users reasonably expect the main switch
    // to make the wake word work.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _continuous
              ? 'Robi is listening for "Hey Robi".'
              : 'Robi is ready. Tap the Robi notification to speak, or turn on '
                  'Continuous "Hey Robi" below.',
        ),
      ),
    );
  }

  String get _subtitle => switch (_state.phase) {
        RobiWakePhase.off => 'Add a notification you can tap to speak',
        RobiWakePhase.starting => 'Starting…',
        RobiWakePhase.downloading =>
          'Downloading speech model… ${_state.detail ?? '0'}%',
        RobiWakePhase.armed => 'Tap the Robi notification to speak',
        RobiWakePhase.listening =>
          'Listening for "Hey Robi" — in-app voice is blocked while this is on',
        RobiWakePhase.error =>
          'Not listening: ${_state.detail ?? 'unknown error'}',
      };

  @override
  Widget build(BuildContext context) {
    final downloading = _state.phase == RobiWakePhase.downloading;
    // "On" means Robi is armed — with or without holding the microphone.
    final active = _state.phase == RobiWakePhase.armed ||
        _state.phase == RobiWakePhase.listening;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _mainTile(active: active, downloading: downloading),
        // Continuous detection is a separate, explicit choice: it is the one
        // option that takes the microphone and breaks normal voice commands.
        if (active) _continuousTile(),
      ],
    );
  }

  Widget _continuousTile() {
    return Padding(
      padding: const EdgeInsets.only(left: 72),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Continuous "Hey Robi"'),
        subtitle: Text(
          _continuous
              ? 'Holding the microphone — in-app voice is blocked'
              : 'Experimental: takes the mic and breaks voice commands',
          style: TextStyle(
            color: _continuous ? V3Colors.warning : V3Colors.textSecondary,
          ),
        ),
        trailing: Switch(
          value: _continuous,
          onChanged: (v) async {
            setState(() => _continuous = v);
            // No stop/start pair: the service releases the mic itself when it is
            // started with continuous=false. Stopping first raced with onDestroy
            // and could leave nothing running.
            final ok = await robiWake.start(continuous: v);
            if (!ok && mounted) {
              setState(() => _continuous = false);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Could not start continuous listening — microphone '
                    'permission is required.',
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _mainTile({required bool active, required bool downloading}) {
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
      title: const Text('Robi'),
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
          : Switch(value: active, onChanged: _toggle),
      onTap: () => _toggle(!active),
    );
  }
}
