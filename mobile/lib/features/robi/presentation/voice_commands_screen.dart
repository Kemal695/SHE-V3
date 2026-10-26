// =============================================================================
// SHE V3 — Voice commands reference (what Robi understands)
// =============================================================================
// The parser's vocabulary lives in voice_command.dart / device_resolver.dart /
// control_intents.dart; this screen is the human-facing mirror of it. A user who
// says something Robi does not understand can review the supported phrasings
// here instead of guessing.
//
// Keep this in sync when the vocabulary changes. It is deliberately plain and
// static — no network, no state — so it always renders.
// =============================================================================

import 'package:flutter/material.dart';

import '../../../core/theme/v3_design_tokens.dart';

class VoiceCommandsScreen extends StatelessWidget {
  const VoiceCommandsScreen({super.key});

  static const List<_Section> _sections = [
    _Section('Start', [
      _Cmd('"Hey Robi"',
          'Wake Robi. Needs Settings → Robi → Continuous "Hey Robi" ON.'),
      _Cmd('Tap the Robi notification',
          'Start listening without the wake word.'),
    ]),
    _Section('One device', [
      _Cmd('turn on socket 1  ·  socket one', 'Switch a single socket on.'),
      _Cmd('switch on / power on <device>', 'Same, other verbs.'),
      _Cmd('turn off socket 2  ·  socket two', 'Switch a single socket off.'),
      _Cmd('shut off / shut down <device>', 'Switch off, other verbs.'),
      _Cmd('turn on light 1  ·  light one', 'Switch a single light on.'),
      _Cmd('turn off light 12  ·  light twelve', 'Switch a single light off.'),
    ]),
    _Section('Several devices at once', [
      _Cmd('turn on socket 1 and 2', 'A bare number repeats the noun.'),
      _Cmd('turn on socket 1 and light 2', 'Mix sockets and lights.'),
      _Cmd('turn off socket 1, socket 2 and light 3', 'Commas or "and".'),
    ]),
    _Section('Ask about state', [
      _Cmd('is socket 1 on?', 'Robi answers, changes nothing.'),
      _Cmd('which lights are on?', 'Lists what is on and off.'),
      _Cmd('whats on?', 'Whole-home summary.'),
    ]),
    _Section('Brightness', [
      _Cmd('dim light 1', 'Sets 30%.'),
      _Cmd('brighten light 2', 'Sets 70%.'),
      _Cmd('set light 1 to 50 percent', 'An exact level.'),
    ]),
    _Section('A whole class', [
      _Cmd('turn on all lights', 'Every light on.'),
      _Cmd('turn off all sockets', 'Every socket off.'),
      _Cmd('turn on the lights', 'Lights on (no number).'),
      _Cmd('turn off everything', 'Everything off.'),
    ]),
    _Section('Scenes', [
      _Cmd('activate <scene name>', 'Run a scene by name.'),
      _Cmd('run / start / execute <scene>', 'Same, with other verbs.'),
    ]),
    _Section('Groups (rooms / zones)', [
      _Cmd('turn on living room', 'Every device in that group.'),
      _Cmd('turn off living room', 'Switch the group off.'),
      _Cmd('turn on living room lights', 'The group, not all lights.'),
    ]),
    _Section('Automations', [
      _Cmd('run morning routine', 'Run the automation now.'),
      _Cmd('trigger / start <automation>', 'Same, other verbs.'),
      _Cmd('enable / disable <automation>', 'Turn the rule on or off.'),
    ]),
    _Section('Answers', [
      _Cmd('yes  ·  no  ·  ok', 'Answer a confirmation.'),
      _Cmd('cancel  ·  stop  ·  nevermind', 'Abandon the command.'),
      _Cmd('undo', 'Reverse the last action.'),
      _Cmd('I meant <target>', 'Correct the target.'),
    ]),
    _Section('Your own commands', [
      _Cmd('Voice Control → list icon', 'Create your own phrases and macros.'),
      _Cmd('Hidden / Locked', 'Hide from the list / confirm before running.'),
      _Cmd('PIN (lock icon)', 'Lock the "My commands" page.'),
    ]),
    _Section('Language', [
      _Cmd('Settings → Language → English', 'For English commands.'),
      _Cmd('Settings → Language → አማርኛ', 'For Amharic commands.'),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        backgroundColor: V3Colors.background,
        title: const Text('Voice commands'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(V3Spacing.md),
        children: [
          Text(
            'Device names on this board: Light 1–16 and Socket 1–8. '
            'Speak the same language the app is set to.',
            style: TextStyle(
              color: V3Colors.text2,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: V3Spacing.md),
          for (final s in _sections) ...[
            Padding(
              padding: const EdgeInsets.only(top: V3Spacing.md, bottom: 4),
              child: Text(
                s.title,
                style: TextStyle(
                  color: V3Colors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            for (final c in s.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        c.text,
                        style: TextStyle(
                          color: V3Colors.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: Text(
                        c.note,
                        style: TextStyle(
                          color: V3Colors.dim,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Cmd {
  final String text;
  final String note;
  const _Cmd(this.text, this.note);
}

class _Section {
  final String title;
  final List<_Cmd> items;
  const _Section(this.title, this.items);
}
