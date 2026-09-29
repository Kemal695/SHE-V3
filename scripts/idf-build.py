#!/usr/bin/env python3
"""
Build the SHE V3 firmware from a bash/MSYS shell.

ESP-IDF 5.1's tools/idf.py refuses to run under MSYS:

    if 'MSYSTEM' in os.environ:
        print_warning('MSys/Mingw is no longer supported ...')
    elif ...:
    else:
        main()          # <- only reached when MSYSTEM is absent

Note the control flow: if MSYSTEM is present it prints the warning and then
falls through WITHOUT calling main(), so `idf.py build` silently does nothing.
`env -u MSYSTEM` does not help because bash keeps re-exporting the variable to
its children.

So we drop MSYSTEM from os.environ in-process and invoke idf.py directly.

Usage: idf-build.py <idf-args...>      e.g. idf-build.py build
"""
import os
import runpy
import sys


def _first_existing(*candidates):
    """Return the first candidate directory that exists, else the last one.

    Used for tool dirs whose version is not pinned by this repo (ninja). Falling
    back to the last candidate keeps the PATH entry present-but-wrong rather than
    dropping it, so the eventual error still names the tool.
    """
    for c in candidates:
        if os.path.isdir(c) and os.path.exists(os.path.join(c, "ninja.exe")):
            return c
    return candidates[-1]


IDF_PATH = r"C:\Espressif\frameworks\esp-idf-v5.1.4"
IDF_PY = os.path.join(IDF_PATH, "tools", "idf.py")

# Required toolchain on PATH (Windows-style, as the native tools expect).
TOOL_BINS = [
    r"C:\Espressif\tools\xtensa-esp32-elf\esp-12.2.0_20230208\xtensa-esp32-elf\bin",
    # 3.30.2, NOT 3.24.0: the older bundled cmake segfaults (exit 139 / 0xC0000005)
    # when spawned from this environment, which makes idf.py report
    # '"cmake" must be available on the PATH'.
    r"C:\Espressif\tools\cmake\3.30.2\bin",
    # Version is whatever this machine actually has. It was pinned to 1.12.1 but
    # only 1.10.2 is installed here, and a wrong path does not fail loudly: idf.py
    # reports `FileNotFoundError: [WinError 2] The system cannot find the file
    # specified` from deep inside asyncio's create_subprocess_exec, which reads
    # like a broken IDF install rather than one bad PATH entry. _first_existing()
    # below picks whichever is present so a version bump cannot reintroduce it.
    _first_existing(
        r"C:\Espressif\tools\ninja\1.12.1",
        r"C:\Espressif\tools\ninja\1.10.2",
    ),
]

os.environ["IDF_PATH"] = IDF_PATH
os.environ["IDF_TOOLS_PATH"] = r"C:\Espressif"
os.environ["PATH"] = os.pathsep.join(TOOL_BINS) + os.pathsep + os.environ.get("PATH", "")

# The whole point of this wrapper.
os.environ.pop("MSYSTEM", None)
os.environ.pop("OSTYPE", None)

# MSYS bash does not pass PROCESSOR_ARCHITECTURE through, which makes
# platform.machine() return '' and idf_tools.py compute PYTHON_PLATFORM
# as 'Windows-' -> "unknown platform: None". Detect the arch and restore it.
if not os.environ.get("PROCESSOR_ARCHITECTURE"):
    machine = os.environ.get("PROCESSOR_IDENTIFIER", "")
    if "ARM" in machine.upper():
        os.environ["PROCESSOR_ARCHITECTURE"] = "ARM64"
    else:
        # PROCESSOR_IDENTIFIER is also typically absent under MSYS; x86_64 is the
        # only sane default for an ESP-IDF toolchain install on this machine.
        os.environ["PROCESSOR_ARCHITECTURE"] = "AMD64"

# idf.py imports helpers (python_version_checker, etc.) from IDF's own tools/ dir.
# Running it as a script would put that dir on sys.path implicitly; runpy does not.
sys.path.insert(0, os.path.join(IDF_PATH, "tools"))

sys.argv = [IDF_PY] + sys.argv[1:]
runpy.run_path(IDF_PY, run_name="__main__")
