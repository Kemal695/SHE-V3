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

ESPRESSIF = r"C:\Espressif"
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

TOOL_DIRS = [
    # 3.30.2 MUST come before 3.24.0: the 3.24.0 binary in this install dies
    # with 0xC0000005 (access violation) before printing anything, so idf.py's
    # shutil.which() finds it, runs it, gets a crash, and reports
    # '"cmake" must be available on the PATH'. Confirmed by running both
    # directly and comparing return codes.
    rf"{ESPRESSIF}\tools\cmake\3.30.2\bin",
    rf"{ESPRESSIF}\tools\ninja\1.12.1",
    rf"{ESPRESSIF}\tools\ccache\4.6.1",
    rf"{ESPRESSIF}\tools\idf-git\2.44.0\cmd",
    rf"{ESPRESSIF}\tools\idf-python\3.11.2",
    rf"{ESPRESSIF}\tools\xtensa-esp32-elf\esp-12.2.0_20230208\xtensa-esp32-elf\bin",
    rf"{ESPRESSIF}\tools\xtensa-esp32s3-elf\esp-12.2.0_20230208\xtensa-esp32s3-elf\bin",
    rf"{ESPRESSIF}\tools\xtensa-esp-elf\esp-13.2.0_20240530\xtensa-esp-elf\bin",
    rf"{ESPRESSIF}\tools\riscv32-esp-elf\esp-13.2.0_20240530\riscv32-esp-elf\bin",
    rf"{ESPRESSIF}\tools\esp32ulp-elf\2.35_20220830\esp32ulp-elf\bin",
    rf"{ESPRESSIF}\tools\esp-rom-elfs\20230305",
    rf"{ESPRESSIF}\tools\openocd-esp32\v0.12.0-esp32-20240318\openocd-esp32\bin",
    rf"{ESPRESSIF}\tools\dfu-util\0.11\dfu-util-0.11-win64",
]

FIRMWARE_DIR = r"D:\she-v3\firmware\v3"


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
    env["PATH"] = os.pathsep.join([d for d in TOOL_DIRS if os.path.isdir(d)] + [env.get("PATH", "")])

    cmd = [IDF_PYTHON, rf"{IDF_PATH}\tools\idf.py"] + args
    os.chdir(FIRMWARE_DIR)
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
