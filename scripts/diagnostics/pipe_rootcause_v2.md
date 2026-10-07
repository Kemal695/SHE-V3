# Pipe `ERROR 231` — CORRECTED root cause (2026-09-27)

## Earlier (wrong) conclusion
"Dart SDK defect — Dart cannot spawn piped children."

## Corrected conclusion
**`ERROR_PIPE_BUSY (231)` on piped `CreateProcess` is a HOST/SESSION-level condition,
not a Dart bug.** It affects Dart and Node; Python is exempt.

### Evidence (all from the same session)
| Runtime | Piped spawn | Non-pipe spawn | Notes |
|---|---|---|---|
| Dart 3.13.4 (Flutter bundled) | FAIL `CreateFile failed 231` | OK | `detached`, `inheritStdio` both fine |
| Node 22.22.2 | FAIL `spawnSync EBUSY` (errno -4082) | OK | `{stdio:'inherit'}` fine |
| Python 3.13.12 | **OK — 40/40 consecutive** | OK | immune; different pipe mechanics |

Additional checks:
- `where git` / `git --version` run **directly in the shell** → OK (shell already owns pipes).
- Dart `ProcessStartMode.detached` → OK. `ProcessStartMode.inheritStdio` → OK.
- Dart `ServerSocket.bind` (TCP, not a pipe) → OK.
- **Detaching does NOT help.** A `DETACHED_PROCESS` Python child that then runs Dart →
  Dart still fails `231`. The restriction is inherited by the whole tree/session.
- **An independent `powershell.exe` child does NOT help** either — Dart run from it still
  fails `231`. So it is not merely "descendant of the agent shell".
- Opening a non-existent named pipe returns `err=2` (FILE_NOT_FOUND) rather than `231`,
  so the namespace is reachable; it is **pipe instance creation** that fails.

### Interpretation
Something shared at session/host level — most plausibly the Windows named-pipe instance
limit under a heavily-loaded pipe namespace, or a job/container pipe quota — is exhausted
for the code paths Dart and Node use, while Python's `CreatePipe` path still succeeds.

### Consequences for the build
- `dart analyze`, `dart run`, `dart compile` → fail (all pipe stdout).
- `flutter build apk` → `:app:compileFlutterBuildDebug` invokes `flutter.bat`, which spawns
  Dart **with pipes** → fails. **This is why the 1h20m run died at the final task.**
- Gradle itself is fine (daemon + socket transport, no per-task pipes).

### What still works (VALIDATED)
Drive the kernel compiler ourselves with `inheritStdio` + **file** redirection:
`mobile/scripts/analyze_flutter.py` → `frontend_server_aot.dart.snapshot`.
This owns the spawn and avoids pipes entirely. 49/49 files, 0 diagnostics.

### For the APK
Because detaching and independent shells both fail, the APK **cannot be produced from this
session**. It needs either:
  1. a **fresh user session / reboot** (likely clears the exhausted pipe state), or
  2. a machine where the condition is absent.
No in-session workaround exists. `scripts/build/build_apk.cmd` is prepared and correct —
it just must run in a clean session.
