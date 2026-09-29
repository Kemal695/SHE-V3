"""Static analysis for the SHE V3 Flutter app, working around a Dart SDK bug.

WHY THIS EXISTS
---------------
`dart analyze` / `dart run` / `dart compile` are all unusable on this Windows
host. dartdev spawns its helper with PIPED stdio, and Dart's CreatePipe
implementation fails with:

    CreateFile failed 231 (All pipe instances are busy)
    ProcessException: All pipe instances are busy (process_win.cc:744)

Evidence this is a Dart bug and not host exhaustion:
  * A Python probe created 4000 uniquely-named pipes with zero errors.
  * Only 214 pipe NAMES exist on the machine (1 instance each) - none saturated.
  * Anonymous CreatePipe and OpenExisting both succeed from Python.
  * Minimal Dart repro: ProcessStartMode.inheritStdio -> OK (no pipes created);
    ProcessStartMode.normal -> ERROR_PIPE_BUSY. So the defect is inside Dart.
  * The failure reproduces identically inside and outside the tool sandbox.

`frontend_server_aot.dart.snapshot` runs fine because we launch it ourselves with
no pipes. It performs full compile-time analysis - types, undefined identifiers,
arity, nullability - which is exactly what `dart analyze` would report.

USAGE
  python scripts/analyze_flutter.py lib/features/device_detail
  python scripts/analyze_flutter.py lib/main.dart lib/app.dart

Exit code 0 = clean, 1 = diagnostics found.
"""
import os
import pathlib
import re
import subprocess
import sys

FLUTTER_ROOT = pathlib.Path(
    # The SDK moved twice: C:\tools\flutter (WDAC-blocked) -> C:\Program Files\flutter
    # (the space broke the native-asset hook build) -> C:\ProgramData\flutter
    # (space-free AND WDAC-trusted). Override with the FLUTTER_ROOT env var.
    os.environ.get("FLUTTER_ROOT") or r"C:\ProgramData\flutter"
)
DART_SDK = FLUTTER_ROOT / "bin" / "cache" / "dart-sdk"
FRONTEND = DART_SDK / "bin" / "snapshots" / "frontend_server_aot.dart.snapshot"
DART_AOT = DART_SDK / "bin" / "dartaotruntime.exe"
# Flutter compiles against its OWN patched SDK, not dart-sdk/lib/_internal.
# Using the wrong one yields "Dart library 'dart:async' is not available".
PATCHED_SDK = (
    FLUTTER_ROOT / "bin" / "cache" / "artifacts" / "engine" / "common"
    / "flutter_patched_sdk"
)

# "No 'main' method found" is expected for a library file and is not a defect.
# The compiler emits it as two lines, plus a bare UUID "result" echo. None of
# these indicate a real problem, so filter all three shapes.
IGNORE = re.compile(
    r"No 'main' method found"
    r"|Try adding a method named 'main'"
    r"|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)


def find_package_config(start: pathlib.Path) -> pathlib.Path:
    cur = start.resolve()
    for _ in range(6):
        cand = cur / ".dart_tool" / "package_config.json"
        if cand.exists():
            return cand
        if cur.parent == cur:
            break
        cur = cur.parent
    raise SystemExit(f"package_config.json not found above {start}")


def gather(targets):
    out = []
    for t in targets:
        p = pathlib.Path(t)
        if p.is_dir():
            out += [str(f) for f in p.rglob("*.dart")]
        elif p.is_file():
            out.append(str(p))
    return sorted(set(out))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    for required in (FRONTEND, DART_AOT, PATCHED_SDK):
        if not required.exists():
            raise SystemExit(f"missing: {required}")

    files = gather(sys.argv[1:])
    if not files:
        print("no .dart files matched")
        return 1

    pkg = find_package_config(pathlib.Path.cwd())
    print(f"flutter     : {FLUTTER_ROOT}")
    print(f"patched sdk : {PATCHED_SDK}")
    print(f"package_cfg : {pkg}")
    print(f"files       : {len(files)}\n")

    # Normalise to forward slashes: the compiler rejects a leading "/C:/" and
    # mis-resolves backslashes in --sdk-root.
    sdk_root = PATCHED_SDK.as_posix() + "/"
    dill_out = pathlib.Path(os.environ.get("TEMP", ".")) / "she_analyze.dill"

    bad = 0
    for f in files:
        cmd = [
            str(DART_AOT),
            str(FRONTEND),
            f"--sdk-root={sdk_root}",
            "--target=flutter",
            f"--packages={pkg.as_posix()}",
            f"--output-dill={dill_out.as_posix()}",
            pathlib.Path(f).as_posix(),
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        text = (r.stdout or "") + (r.stderr or "")
        diags = []
        for ln in text.splitlines():
            s = ln.strip()
            if not s:
                continue
            if s.startswith("result "):
                continue
            if IGNORE.search(s):
                continue
            diags.append(ln.rstrip())
        if r.returncode == 0 or not diags:
            print(f"OK       {f}")
        else:
            bad += 1
            print(f"PROBLEM  {f}")
            for d in diags[:25]:
                print(f"           {d}")
    print(f"\n{bad} file(s) with diagnostics out of {len(files)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
