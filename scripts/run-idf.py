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
IDF_VERSION = os.environ.get("IDF_VERSION", "esp-idf-v5.2.7")
IDF_PATH = rf"{ESPRESSIF}\frameworks\{IDF_VERSION}"
IDF_PYTHON = rf"{ESPRESSIF}\python_env\idf5.2_py3.11_env\Scripts\python.exe"

TOOL_DIRS = [
    rf"{ESPRESSIF}\tools\cmake\3.24.0\bin",
    rf"{ESPRESSIF}\tools\ninja\1.10.2",
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
    env["PATH"] = os.pathsep.join([d for d in TOOL_DIRS if os.path.isdir(d)] + [env.get("PATH", "")])

    cmd = [IDF_PYTHON, rf"{IDF_PATH}\tools\idf.py"] + args
    os.chdir(FIRMWARE_DIR)
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
