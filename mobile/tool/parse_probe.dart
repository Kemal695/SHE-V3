// Probe harness for the voice parser. Pure Dart — run with:
//   dart run tool/parse_probe.dart
// Replays real utterances against the REAL parser so we can see exactly what
// action/targets it produces, without a phone or a recognizer.
import 'package:she_mobile/features/robi/domain/voice_command.dart';

List<VoiceDevice> buildDevices() {
  final out = <VoiceDevice>[];
  for (var i = 1; i <= 16; i++) {
    out.add(VoiceDevice(
      nodeId: 'node-1',
      deviceId: 'light-$i',
      deviceName: 'Light $i',
    ));
  }
  for (var i = 1; i <= 8; i++) {
    out.add(VoiceDevice(
      nodeId: 'node-1',
      deviceId: 'socket-$i',
      deviceName: 'Socket $i',
    ));
  }
  return out;
}

void main() {
  final devices = buildDevices();
  final phrases = <String>[
    // state questions
    'is socket 2 on',
    'is socket 2 on?',
    'is socket 1 on',
    'is socket 2 off',
    'are lights on',
    'which lights are on',
    "what's on",
    // multi device
    'turn on socket 1',
    'turn on socket 1 and 2',
    'turn on socket 1 and socket 2',
    'turn on socket 1 socket 2 and light 1',
    'turn on socket 1, socket 2 and light 3',
    'turn on socket 1 and light 2',
    'turn off socket 1 socket 2',
    'turn on light 1 light 2 and socket 3',
    'switch on socket 3 and 4',
    'socket 2 on',
    // class
    'turn on all lights',
    'turn off all sockets',
  ];

  for (final p in phrases) {
    final intent = parseVoiceIntent(p, devices: devices);
    final targets =
        intent.devices.map((d) => d.label).join(' + ');
    print('IN : "$p"');
    print('OUT: action=${intent.action.name} '
        'targets=[${targets.isEmpty ? '-' : targets}] '
        'group=${intent.group ?? '-'} conf=${intent.confidence.toStringAsFixed(2)}');
    print('    describe: ${intent.describe()}');
    print('');
  }
}
