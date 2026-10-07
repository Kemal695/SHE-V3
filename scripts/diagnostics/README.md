# Diagnostics

## The `dart analyze` pipe failure

`dart analyze` / `flutter analyze` / `dart run` / `dart compile` all fail on this host with:

```
ProcessException: All pipe instances are busy (at ../../runtime/bin/process_win.cc:744)
```

These three scripts are the evidence that this is a **Dart SDK defect**, not host exhaustion
and not the tool sandbox.

| script | what it shows |
|---|---|
| `pipe_probe.py` | The OS creates **4000 uniquely-named pipes** with zero errors → no global exhaustion. |
| `pipe_list.py` | Only ~214 pipe **names** exist machine-wide, **1 instance each** → nothing saturated. |
| `pipe_probe2.py` | Anonymous `CreatePipe`, `OpenExisting`, and a Dart-shaped named pipe all succeed. |

The decisive isolation is a minimal Dart repro (not saved here — four lines):

```dart
Process.start('cmd.exe', ['/c','echo','hi'], mode: ProcessStartMode.inheritStdio); // OK
Process.start('cmd.exe', ['/c','echo','hi']);                                     // ERROR_PIPE_BUSY
```

`inheritStdio` allocates no pipes and works; the default (piped stdio) fails. So the bug is inside
Dart's own `CreatePipe` call on this Windows build.

**Workaround:** `mobile/scripts/analyze_flutter.py`, which drives
`frontend_server_aot.dart.snapshot` directly (we own the spawn, so no pipes) for full compile-time
analysis. Run `python scripts/diagnostics/pipe_probe.py` to re-confirm the environment is healthy
if you ever suspect this has changed.
