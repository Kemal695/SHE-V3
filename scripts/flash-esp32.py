#!/usr/bin/env python
"""Flash the SHE V3 firmware to an ESP32-WROOM-32D.

Why this exists: `cmd //c` produces no output on this machine, and idf.py's
own flash step cannot be used interactively. This drives esptool directly
with the exact offsets recorded in the build's flasher_args.json.

Key safety choice: --flash_size detect.
The build was configured for 8 MB flash, but an ESP32-WROOM-32D is commonly
4 MB (part -N4) or 8 MB (part -N8). Passing a hard-coded size writes a wrong
image header on a mismatched part; `detect` asks the chip.

Usage:
    python scripts/flash-esp32.py                 # flash COM4 at 460800
    python scripts/flash-esp32.py --port COM7
    python scripts/flash-esp32.py --baud 115200   # if the cable is marginal
    python scripts/flash-esp32.py --erase         # full erase first
    python scripts/flash-esp32.py --check         # only test the link
"""
import argparse
import json
import os
import subprocess
import sys

ESPRESSIF = r"C:\Espressif"
# Match the toolchain the image was built with: the project targets ESP-IDF
# v5.1.x (LTS), so use the 5.1 python env — it carries pyserial + esptool.
# (esptool works from the 5.2 env too; this just keeps one story.)
IDF_PYTHON = rf"{ESPRESSIF}\python_env\idf5.1_py3.11_env\Scripts\python.exe"
BUILD_DIR = r"D:\she-v3\firmware\v3\build-esp32d"

# Flash chip is written at 40m/dio per sdkconfig; the *serial* baud is ours.
DEFAULT_BAUD = 460800


def load_flash_args(build_dir):
    path = os.path.join(build_dir, "flasher_args.json")
    if not os.path.isfile(path):
        sys.exit(f"Missing {path}. Build the firmware first.")
    with open(path) as fh:
        return json.load(fh)


def check_link(port, baud):
    """Ask the chip who it is. This is the real go/no-go test."""
    cmd = [
        IDF_PYTHON, "-m", "esptool",
        "--chip", "esp32", "--port", port, "--baud", str(baud),
        "--before", "default_reset", "--after", "no_reset",
        "chip_id",
    ]
    print("[1/3] Testing link:", " ".join(cmd[2:]))
    r = subprocess.run(cmd, cwd=os.path.dirname(BUILD_DIR))
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("--build-dir", default=BUILD_DIR)
    ap.add_argument("--erase", action="store_true", help="full chip erase first")
    ap.add_argument("--check", action="store_true", help="only test the link")
    ap.add_argument("--flash-size", default="detect",
                    help="'detect' (default, recommended) or an explicit size")
    args = ap.parse_args()

    fa = load_flash_args(args.build_dir)
    files = fa["flash_files"]
    bd = args.build_dir

    print(f"Build      : {bd}")
    print(f"Port       : {args.port} @ {args.baud}")
    print(f"Chip/flash : esp32, --flash_size {args.flash_size}")
    print("Image set  :")
    for off in sorted(files, key=lambda o: int(o, 16)):
        rel = files[off]
        full = os.path.join(bd, rel.replace("/", os.sep))
        ok = "OK " if os.path.isfile(full) else "MISSING"
        size = os.path.getsize(full) if os.path.isfile(full) else 0
        print(f"   {off:>10}  {rel:<40} {ok} {size:>9,} B")

    missing = [o for o in files
               if not os.path.isfile(os.path.join(bd, files[o].replace("/", os.sep)))]
    if missing:
        sys.exit("Refusing to flash: missing images listed above.")

    if not check_link(args.port, args.baud):
        print("\n" + "=" * 70)
        print("LINK FAILED - cannot talk to the chip on", args.port)
        print("=" * 70)
        print("Work through these in order:")
        print("  1. Use a USB *data* cable. Many cables are charge-only.")
        print("  2. Try a different USB port on the PC (skip hubs).")
        print("  3. Enter download mode by hand: hold BOOT, tap EN, release BOOT,")
        print("     then rerun with --baud 115200 --check")
        print("  4. Confirm the port: python scripts/esp32-listen.py COM4")
        print("     (press EN; you should see the ROM banner)")
        print("  5. Reinstall the CH340 driver if the port appears but stays silent.")
        return 1

    if args.check:
        print("\nLink OK. Ready to flash.")
        return 0

    if args.erase:
        print("\n[2/3] Erasing flash...")
        r = subprocess.run([IDF_PYTHON, "-m", "esptool", "--chip", "esp32",
                            "--port", args.port, "--baud", str(args.baud),
                            "erase_flash"], cwd=os.path.dirname(bd))
        if r.returncode != 0:
            return r.returncode
    else:
        print("\n[2/3] Skipping erase (--erase to force)")

    cmd = [IDF_PYTHON, "-m", "esptool", "--chip", "esp32",
           "--port", args.port, "--baud", str(args.baud),
           "--before", "default_reset", "--after", "hard_reset",
           "write_flash", "--flash_size", args.flash_size]
    for off in sorted(files, key=lambda o: int(o, 16)):
        cmd += [off, files[off]]
    # Preserve the build's mode/freq; only the size is left to detection.
    wf = fa.get("write_flash_args", [])
    if "--flash_mode" in wf:
        cmd += ["--flash_mode", wf[wf.index("--flash_mode") + 1]]
    if "--flash_freq" in wf:
        cmd += ["--flash_freq", wf[wf.index("--flash_freq") + 1]]

    print("\n[3/3] Flashing:", " ".join(cmd[2:]))
    r = subprocess.run(cmd, cwd=bd)
    if r.returncode != 0:
        return r.returncode

    print("\n" + "=" * 70)
    print("Flash complete. Monitor the boot log with:")
    print(f"  python scripts/run-idf.py -p {args.port} monitor")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
