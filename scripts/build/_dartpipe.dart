import 'dart:io';
void main() {
  try {
    final r = Process.runSync('git.exe', ['--version']);
    print('DART PIPED SPAWN OK: ${r.stdout.toString().trim()}');
  } catch (e) {
    print('DART PIPED SPAWN FAIL: $e');
  }
}
