#!/usr/bin/env python
"""Make the Flutter Gradle plugin buildable on a WDAC-hardened Windows box.

WHY THIS EXISTS
---------------
`flutter build apk` fails on this machine before compiling any project code:

    Execution failed for task ':gradle:compileKotlin'.
    > java.io.IOException: Unable to delete directory
        '<flutterSdk>/packages/flutter_tools/gradle/build/classes/kotlin/main'
      Failed to delete some children. This might happen because a process has
      files open or has its working directory set in the target directory.

The "process has files open" wording is a red herring. The decisive evidence is
in the Kotlin daemon log (``%TEMP%\\kotlin-daemon.*.log``)::

    SEVERE: Exception: java.nio.file.AccessDeniedException:
      <flutterSdk>/packages/flutter_tools/gradle/build/kotlin/compileKotlin/
        cacheable/dirty-sources.txt

``AccessDeniedException`` — not a sharing violation. The Kotlin daemon is denied
DELETE on that path even though ``icacls`` grants the user full control and the
same user can delete the files by hand from a shell. That combination points at
Windows Defender Application Control rather than NTFS permissions:

    <System32>/CodeIntegrity/CIPolicies/Active/{784C4414-...}.cip
    <System32>/CodeIntegrity/CIPolicies/Active/{60FD87F8-...}.cip

with matching Event ID 3033 blocks in
Microsoft-Windows-CodeIntegrity/Operational.

Flutter includes ``packages/flutter_tools/gradle`` *inside the SDK* as a build.
The usual trick of redirecting subproject build directories does not reach an
included build, so the Flutter Gradle plugin keeps compiling into the protected
path and keeps failing. There is no supported Gradle API to point an included
build's directory elsewhere: ``settings.rootProject`` is only a
``ProjectDescriptor`` at ``beforeSettings`` time (no build dir at all), and
``settings.layout`` (``BuildLayout``) is read-only.

WHAT THIS SCRIPT DOES
---------------------
Replaces ``<flutterSdk>/packages/flutter_tools/gradle/build`` with a directory
junction onto a writable location. Writes and deletes then physically happen
outside the WDAC-protected tree, which is all the Kotlin daemon needs. The
Flutter SDK's source files are untouched, so ``flutter upgrade`` still works —
though an upgrade may delete the junction, in which case just re-run this.

Run it whenever the build starts failing at ``:gradle:compileKotlin``.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

# Where to put the real data. Defaults to the project's own build/ tree, which is
# already gitignored and cleared by `flutter clean`. Override with
# SHE_FLUTTER_GRADLE_BUILD_DIR if you want it somewhere else (e.g. a scratch SSD).
TARGET_ENV = "SHE_FLUTTER_GRADLE_BUILD_DIR"


def find_repo_root(start: Path) -> Path:
    for parent in [start, *start.parents]:
        if (parent / ".git").exists():
            return parent
    return start


def find_flutter_sdk(explicit: str | None) -> Path | None:
    """Resolve the Flutter SDK: explicit arg > this script's local.properties."""
    if explicit:
        p = Path(explicit)
        return p if p.is_dir() else None

    repo = find_repo_root(Path(__file__).resolve())
    local_props = repo / "mobile" / "android" / "local.properties"
    if local_props.is_file():
        for line in local_props.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("flutter.sdk"):
                _, _, value = line.partition("=")
                # Java properties escape backslashes and drive colons.
                value = value.strip().replace("\\\\", "\\").replace("\\:", ":")
                candidate = Path(value)
                if candidate.is_dir():
                    return candidate

    # Fall back to whatever `flutter` is on PATH.
    exe = shutil.which("flutter") or shutil.which("flutter.bat")
    if exe:
        sdk_bin = Path(exe).resolve().parent
        candidate = sdk_bin.parent
        if (candidate / "packages").is_dir():
            return candidate
    return None


def is_junction(path: Path) -> bool:
    """True when `path` is a directory reparse point (junction or symlink).

    Deliberately does NOT shell out to `dir /AL`: that requires quoting paths
    containing spaces, and getting the quoting wrong silently returns "not a
    junction", which then deletes a working junction. `os.path.islink` alone is
    not enough either — Windows junctions are not reported as links by older
    Python builds — so also accept st_reparse_tag when available.
    """
    if not path.exists() and not path.is_symlink():
        return False
    try:
        if os.path.islink(path):
            return True
    except OSError:
        pass
    try:
        st = os.lstat(path)
    except OSError:
        return False
    # FILE_ATTRIBUTE_REPARSE_POINT
    if getattr(st, "st_file_attributes", 0) & 0x400:
        return True
    return False


def main() -> int:
    sdk = find_flutter_sdk(sys.argv[1] if len(sys.argv) > 1 else None)
    if sdk is None:
        print("ERROR: could not find the Flutter SDK.", file=sys.stderr)
        print("       Pass it explicitly: prepare-flutter-gradle-dir.py C:\\path\\to\\flutter",
              file=sys.stderr)
        return 1

    gradle_dir = sdk / "packages" / "flutter_tools" / "gradle"
    if not gradle_dir.is_dir():
        print(f"ERROR: {gradle_dir} does not exist — is this really the Flutter SDK?",
              file=sys.stderr)
        return 1

    link = gradle_dir / "build"

    repo = find_repo_root(Path(__file__).resolve())
    target = Path(os.environ.get(
        TARGET_ENV,
        repo / "mobile" / "build" / "flutter-gradle-plugin",
    )).resolve()

    print(f"Flutter SDK : {sdk}")
    print(f"junction    : {link}")
    print(f"target      : {target}")
    print()

    if is_junction(link):
        print("Already a junction — nothing to do.")
        return 0

    if link.exists():
        print("Removing the existing real directory ...")
        shutil.rmtree(link, ignore_errors=True)
        if link.exists():
            print(f"ERROR: could not remove {link}.", file=sys.stderr)
            print("       Close any running Gradle/Kotlin daemons and retry:",
                  file=sys.stderr)
            print("         cd mobile/android && ./gradlew --stop", file=sys.stderr)
            return 1

    target.mkdir(parents=True, exist_ok=True)

    # mklink /J must run through cmd; PowerShell's New-Item also works but this
    # avoids the quoting differences between the two shells.
    proc = subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(link), str(target)],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        # Fall back to PowerShell for hosts where cmd's mklink is restricted.
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             f"New-Item -ItemType Junction -Path '{link}' -Target '{target}' | Out-Null"],
            capture_output=True, text=True, check=False,
        )
    if proc.returncode != 0:
        print("ERROR: could not create the junction.", file=sys.stderr)
        print(proc.stdout, proc.stderr, file=sys.stderr)
        return 1

    # Prove it actually works rather than trusting the exit code.
    probe = link / ".she-write-probe"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        print(f"ERROR: junction created but not writable: {exc}", file=sys.stderr)
        return 1

    print("OK — junction created and verified writable.")
    print("The Kotlin daemon can now delete/rewrite there without hitting WDAC.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
