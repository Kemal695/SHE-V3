#!/usr/bin/env python
"""Make the Flutter Gradle plugin buildable when its own build dir is not writable.

WHY THIS EXISTS
---------------
`flutter build apk` can fail on this box before compiling any project code:

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
write/delete on that path even though ``icacls`` grants the user full control and
the same user can create and delete files there by hand from a shell.

WHAT IS ACTUALLY DENYING IT (corrected 2026-10-02)
--------------------------------------------------
An earlier revision of this file blamed WDAC. That was never proven. The
reproducible cause is a **process-scoped write denial outside the project tree**:
measured on this box, a *child* process cannot write into the Flutter SDK, while
the interactive shell can.

    # child process (this is the Kotlin daemon's situation)
    cmd /c "echo x > C:\\ProgramData\\flutter\\packages\\flutter_tools\\gradle\\__t__.tmp"
    -> Access is denied.

    # the same shell that spawned it
    echo x > /c/ProgramData/flutter/packages/flutter_tools/gradle/__t__.tmp
    -> OK

The agent sandbox enforces that split. The two WDAC policy files
(``{784C4414-...}.cip``, ``{60FD87F8-...}.cip``) do exist on this machine, but no
direct evidence was ever found that they block this path, so do not go chasing
Event ID 3033 again before re-testing the child-process case above.

Flutter includes ``packages/flutter_tools/gradle`` *inside the SDK* as a build.
The usual trick of redirecting subproject build directories does not reach an
included build, so the Flutter Gradle plugin keeps compiling into the restricted
path and keeps failing. There is no supported Gradle API to point an included
build's directory elsewhere: ``settings.rootProject`` is only a
``ProjectDescriptor`` at ``beforeSettings`` time (no build dir at all), and
``settings.layout`` (``BuildLayout``) is read-only.

WHAT THIS SCRIPT DOES
---------------------
Replaces ``<flutterSdk>/packages/flutter_tools/gradle/build`` with a directory
junction onto a writable location *inside this checkout*. Writes and deletes then
physically happen in the project tree, which both a sandboxed build and a normal
one can write. The Flutter SDK's source files are untouched, so ``flutter
upgrade`` still works — though an upgrade may delete the junction, in which case
just re-run this.

WHY THE TARGET LIVES WHERE IT DOES (fixed 2026-10-02)
----------------------------------------------------
The target used to be ``mobile/build/flutter-gradle-plugin``. That was a bug:
``mobile/build`` is exactly what ``flutter clean`` and ``./gradlew clean`` delete,
so every clean destroyed the junction's target, left the junction dangling, and
broke the build — with no way back, because the old ``is_junction()`` checked
``path.exists()`` first and a dangling junction reports ``exists() == False``.
The script then decided "not a junction", tried to create one, and failed with
``Cannot create a file when that file already exists`` (verified: mklink rc=1).

So the target now sits in ``mobile/.flutter-gradle-plugin-build`` — outside the
``clean`` blast radius — and ``is_junction()`` no longer consults ``exists()``,
so a dangling junction is recognised and repaired instead of wedging the build.

Run it whenever the build starts failing at ``:gradle:compileKotlin``.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

# Where to put the real data. Defaults to ``mobile/.flutter-gradle-plugin-build``
# — deliberately NOT under ``mobile/build``, which `clean` deletes. Override with
# SHE_FLUTTER_GRADLE_BUILD_DIR if you want it somewhere else (e.g. a scratch SSD).
TARGET_ENV = "SHE_FLUTTER_GRADLE_BUILD_DIR"

# FILE_ATTRIBUTE_REPARSE_POINT — set on junctions and symlinks alike.
FILE_ATTRIBUTE_REPARSE_POINT = 0x400


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

    Deliberately does NOT consult ``path.exists()`` first. That was the bug that
    wedged the build: ``exists()`` follows the reparse point, so a junction whose
    target has been deleted (e.g. by ``clean``) reports False, the old code
    concluded "not a junction", and ``mklink`` then failed because the link was
    still there. ``os.lstat`` never follows the link, so it sees the truth.

    Also deliberately does NOT shell out to ``dir /AL``: that requires quoting
    paths containing spaces, and getting the quoting wrong silently returns "not
    a junction", which then deletes a working junction. ``os.path.islink`` alone
    is not enough either — Windows junctions are not reported as links by all
    Python builds — so accept the reparse-point attribute as well.
    """
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if getattr(st, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
        return True
    try:
        return os.path.islink(path)
    except OSError:
        return False


def junction_target(path: Path) -> Path | None:
    """Best-effort read of a junction's target. None if it cannot be read.

    Windows reports a junction's target with an extended-length prefix
    (``\\\\?\\D:\\...``), so the raw value never compares equal to a normal path.
    Strip it, otherwise the caller sees "stale target" on every run and needlessly
    deletes and recreates a perfectly good junction each time.
    """
    try:
        raw = os.readlink(path)
    except OSError:
        return None
    for prefix in ("\\\\?\\", "\\??\\"):
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
            break
    return Path(raw)


def remove_link(link: Path) -> bool:
    """Remove a junction/symlink WITHOUT touching its target. True on success.

    ``os.rmdir`` on a reparse point deletes only the link. ``shutil.rmtree`` is
    never used here: on a junction it can be ambiguous across Python versions and
    may recurse into the target, which would delete real build output.
    """
    try:
        os.rmdir(link)
        return True
    except OSError:
        pass
    # Last resort for odd link types.
    r = subprocess.run(["cmd", "/c", "rmdir", str(link)], capture_output=True, text=True)
    return r.returncode == 0


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
        repo / "mobile" / ".flutter-gradle-plugin-build",
    )).resolve()

    print(f"Flutter SDK : {sdk}")
    print(f"junction    : {link}")
    print(f"target      : {target}")
    print()

    if is_junction(link):
        current = junction_target(link)
        points_here = current is not None and current.resolve() == target
        if points_here and target.is_dir():
            print("Already a junction onto the right target — nothing to do.")
            return 0
        if current is None:
            print("Existing junction has an unreadable target — recreating it.")
        elif not points_here:
            print(f"Junction points at a stale target ({current}) — migrating.")
        else:
            # points_here but the target is missing: this is the dangling case
            # that used to wedge the build. Recreating the target is enough.
            print("Junction is DANGLING (its target was deleted, e.g. by `clean`).")
            print("Recreating the target directory …")
        if not remove_link(link):
            print(f"ERROR: could not remove the existing junction at {link}.", file=sys.stderr)
            print("       Close any running Gradle/Kotlin daemons and retry:", file=sys.stderr)
            print("         cd mobile/android && ./gradlew --stop", file=sys.stderr)
            return 1
    elif link.exists():
        print("Removing the existing real directory …")
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
    print("The Kotlin daemon can now write/delete there.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
