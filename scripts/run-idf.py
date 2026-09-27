#!/usr/bin/env python
"""Run ESP-IDF (idf.py) for the SHE V3 firmware.

Why this exists: idf.py is normally launched from an ESP-IDF shell created by
`export.bat`, which is a .cmd script — and on this machine `cmd //c <script>`
produces no output at all. This sets up the same environment and runs idf.py
directly with the IDF python interpreter.

Usage:
    python scripts/run-idf.py set-target esp32
    python scripts/run-idf.py build
    python scripts/run-idf.py -p COM4 flash monitor
    python scripts/run-idf.py -p COM4 flash-id      # check flash size first!

Environment is derived from C:/Espressif; override IDF_VERSION to switch.
"""
import os
import subprocess
import sys
from pathlib import Path

# Installed per-machine; override with SHE_ESPRESSIF when it lives elsewhere.
ESPRESSIF = os.environ.get("SHE_ESPRESSIF", r"C:\Espressif")
# The project targets ESP-IDF v5.1.x (LTS) — firmware/v3/README.md and the
# v3 specs pin 5.1. Do NOT default to 5.2.7: build-esp32d's bootloader
# sub-build cache was generated against 5.1.4, and cmake aborts with
# "The source .../esp-idf-v5.2.7/components/bootloader/subproject/CMakeLists.txt
# does not match the source .../esp-idf-v5.1.4/... used to generate cache".
# Override with the IDF_VERSION env var if you really want another one, and
# wipe the build dir when you do.
IDF_VERSION = os.environ.get("IDF_VERSION", "esp-idf-v5.1.4")
IDF_PATH = rf"{ESPRESSIF}\frameworks\{IDF_VERSION}"
IDF_PYTHON = rf"{ESPRESSIF}\python_env\idf5.1_py3.11_env\Scripts\python.exe"

# Tool versions are DISCOVERED, not hardcoded.
#
# The offline installer ships a different tool set than the machine this list
# was originally written on: ninja 1.10.2 (not 1.12.1), ccache 4.8 (not 4.6.1),
# riscv32-esp-elf esp-12.2.0 (not esp-13.2.0), esp-rom-elfs 20230320 (not
# 20230305), openocd-esp32 v0.12.0-esp32-20230921 (not ...20240318), and no
# xtensa-esp-elf at all. Every one of those silently dropped out of PATH, which
# is why idf.py then reported '"cmake" must be available on the PATH'.
#
# Versions sort DESCENDING so the newest wins. That ordering is load bearing for
# cmake: 3.24.0 segfaults (0xC0000005) before printing anything, so idf.py's
# shutil.which() finds it, runs it, gets a crash, and reports cmake as missing.
# 3.30.2 must therefore be found first. Confirmed by running both binaries and
# comparing return codes (3.24.0 → exit 139, no output; 3.30.2 → prints version).
_TOOL_BIN_SUBPATHS = {
    "cmake": ("bin",),
    "ninja": (),
    "ccache": (),
    "idf-git": ("cmd",),
    "idf-python": (),
    "xtensa-esp32-elf": ("xtensa-esp32-elf", "bin"),
    "xtensa-esp32s3-elf": ("xtensa-esp32s3-elf", "bin"),
    "xtensa-esp-elf": ("xtensa-esp-elf", "bin"),
    "riscv32-esp-elf": ("riscv32-esp-elf", "bin"),
    "esp32ulp-elf": ("esp32ulp-elf", "bin"),
    "esp-rom-elfs": (),
    "openocd-esp32": ("openocd-esp32", "bin"),
    "dfu-util": (),  # unpacks as <version>/dfu-util-<version>-win64
}


def _version_key(name):
    """Newest-first ordering that tolerates names like 'v0.12.0-esp32-20230921'."""
    out = []
    for chunk in str(name).replace("_", ".").replace("-", ".").split("."):
        out.append((0, int(chunk), "") if chunk.isdigit() else (1, 0, chunk))
    return out


def _discover_tool_dirs():
    tools_root = Path(ESPRESSIF) / "tools"
    found = []
    for tool, sub in _TOOL_BIN_SUBPATHS.items():
        root = tools_root / tool
        if not root.is_dir():
            continue
        versions = sorted(
            (d for d in root.iterdir() if d.is_dir()),
            key=lambda d: _version_key(d.name),
            reverse=True,
        )
        for ver in versions:
            if tool == "dfu-util":
                cands = [d for d in ver.iterdir()
                         if d.is_dir() and d.name.startswith("dfu-util")]
            else:
                cands = [ver.joinpath(*sub)]
            found.extend(str(c) for c in cands if c.is_dir())
    return found


TOOL_DIRS = _discover_tool_dirs()

# Derived, not hardcoded — see the note in run-backend.py.
FIRMWARE_DIR = Path(__file__).resolve().parent.parent / "firmware" / "v3"


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2

    env = os.environ.copy()
    env["IDF_PATH"] = IDF_PATH
    # Tools live in C:\Espressif here, not the default %USERPROFILE%\.espressif.
    env["IDF_TOOLS_PATH"] = ESPRESSIF
    # ESP-IDF refuses to run under MSys/Mingw ("MSys/Mingw is no longer
    # supported") and it detects that purely from MSYSTEM, which Git Bash sets.
    # Clearing it makes idf.py treat this as a native Windows environment.
    for k in ("MSYSTEM", "MSYSCON", "MSYS2_ARG_CONV_EXCL"):
        env.pop(k, None)
    # idf_tools.py identifies the host as platform.system() + '-' + platform.machine().
    # platform.machine() is EMPTY in this shell (PROCESSOR_ARCHITECTURE is not
    # inherited), which makes idf.py die with "unknown platform: Windows-".
    # Supplying it restores 'Windows-AMD64'.
    env.setdefault("PROCESSOR_ARCHITECTURE", "AMD64")
    env.setdefault("PROCESSOR_IDENTIFIER", "Intel64 Family 6 Model 140 Stepping 1, GenuineIntel")
    # idf.py re-execs itself via this env; without it the re-exec loses PATH and
    # reports 'cmake must be available on the PATH'.
    env["IDF_PYTHON_ENV_PATH"] = rf"{ESPRESSIF}\python_env\idf5.1_py3.11_env"
    env.setdefault("PATHEXT", ".COM;.EXE;.BAT;.CMD;.VBS;.JS;.WSF;.WSH;.MSC")
    # The component manager is disabled by default.
    #
    # It runs `inject_requirements`, which bulk-deletes its own temp files in the
    # build dir. On this machine a host-level safe-delete guard refuses operations
    # touching more than ~50 files at once, the helper exits non-zero, and
    # component.cmake:250 re-raises that as:
    #   CMake Error ... [safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]
    # which fails the whole configure before a single file is compiled. Note the
    # guard is NOT the sandbox — disabling the sandbox does not bypass it.
    #
    # This project has no idf_component.yml and pulls in no managed components, so
    # nothing is lost. Set SHE_COMPONENT_MANAGER=1 to re-enable the manager (and
    # thereby resolve components from the registry) if that ever changes.
    if os.environ.get("SHE_COMPONENT_MANAGER", "0") != "1":
        env["IDF_COMPONENT_MANAGER"] = "0"
    env["PATH"] = os.pathsep.join([d for d in TOOL_DIRS if os.path.isdir(d)] + [env.get("PATH", "")])

    # Limit build parallelism.
    #
    # Measured: ninja reports "[default=6 on this system]" here — 6 parallel jobs
    # on a 2-core / 4-thread i5-6200U, i.e. 50% oversubscribed. This laptop has
    # hard-crashed four times (Event 41, no clean shutdown) under all-core load
    # while discharging, so the oversubscription matters.
    #
    # `idf.py` has no -j flag (verified against `idf.py build --help`), so the cap
    # goes in via CMAKE_BUILD_PARALLEL_LEVEL, which CMake's --build honours and
    # which the ninja generator picks up.
    #
    # Override per-run:  SHE_BUILD_JOBS=4 python scripts/run-idf.py build
    jobs = env.get("SHE_BUILD_JOBS", "2")
    env["CMAKE_BUILD_PARALLEL_LEVEL"] = jobs
    print(f"  build parallelism capped at {jobs} job(s) "
          f"(SHE_BUILD_JOBS to change; ninja would otherwise use 6)")

    cmd = [IDF_PYTHON, rf"{IDF_PATH}\tools\idf.py"] + args
    os.chdir(FIRMWARE_DIR)
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
