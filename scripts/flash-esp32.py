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
    python scripts/flash-esp32.py                 # flash COM3
    python scripts/flash-esp32.py --port COM7
    python scripts/flash-esp32.py --baud 115200   # if the cable is marginal
    python scripts/flash-esp32.py --erase         # full erase first
    python scripts/flash-esp32.py --check         # only test the link
    python scripts/flash-esp32.py --wait 180      # poll for MANUAL download mode
    python scripts/flash-esp32.py --no-reset      # chip is already in download mode

------------------------------------------------------------------------------
WHY THE AUTO-RESET IS UNRELIABLE ON THIS BOARD (learned the hard way, 2026-09-28)
------------------------------------------------------------------------------
The bench board is a classic ESP32-D0WD behind a CH340 (VID:PID 1A86:7523). Its
**BOOT button is on GPIO0**, and the CH340's DTR->IO0 half of the auto-reset
circuit is flaky: esptool's reset sequence frequently fails with
"Failed to connect to ESP32: No serial data received", and sometimes with
"Serial data stream stopped: Possible serial noise or corruption".

What actually works, in order of preference:

  1. `--wait <seconds>`: poll `esptool --before no_reset chip_id` until the chip
     answers, while you put it in download mode BY HAND:
         hold BOOT (GPIO0) -> tap EN/RST once -> release BOOT
     The board then sits SILENTLY in download mode (that silence is normal - the
     ROM prints nothing until it is contacted). Once the poll sees the chip, this
     script flashes immediately with --before no_reset.

  2. `--no-reset`: same thing, without the waiting loop, if you already did the
     button dance.

  3. Baud fallback: if the requested baud will not sync, 74880 is tried next -
     that is the rate that worked when 115200 would not. `--attempts` raises the
     number of sync attempts per baud (default 10; the default of ~7 is often not
     enough here).

Do NOT hand-poke DTR/RTS from pyserial to "help" - that is what strands the chip
in a state where nothing answers. Use the button sequence, or a power cycle
(unplug USB ~5 s) followed by the button sequence.

After a successful link the chip is left in download mode (we connect with
--after no_reset), so the flash step below also uses --before no_reset and does
not re-run the flaky reset. --after hard_reset at the end restarts the app
(RTS->EN IS wired; only the DTR->IO0 half is unreliable).
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ESPRESSIF = r"C:\Espressif"
# Match the toolchain the image was built with: the project targets ESP-IDF
# v5.1.x (LTS), so use the 5.1 python env — it carries pyserial + esptool.
# (esptool works from the 5.2 env too; this just keeps one story.)
IDF_PYTHON = rf"{ESPRESSIF}\python_env\idf5.1_py3.11_env\Scripts\python.exe"

# Derived from this file's location, not hardcoded. The checkout moved from
# D:\she-v3 to "D:\project X\she-v3", and a hardcoded build dir silently pointed
# at a path that no longer existed.
REPO_ROOT = Path(__file__).resolve().parent.parent
FIRMWARE_V3 = REPO_ROOT / "firmware" / "v3"
# idf.py writes to ./build by default; the esp32d devkit profile uses
# build-esp32d. Prefer whichever actually exists.
BUILD_DIR = next(
    (str(d) for d in (FIRMWARE_V3 / "build-esp32d", FIRMWARE_V3 / "build") if d.is_dir()),
    str(FIRMWARE_V3 / "build-esp32d"),
)

# Flash chip is written at 40m/dio per sdkconfig; the *serial* baud is ours.
DEFAULT_BAUD = 460800
# If a baud will not sync, try these next. 74880 is the ESP32 ROM's own default
# rate and is the one that succeeded here when 115200 would not.
BAUD_FALLBACKS = (460800, 115200, 74880)
DEFAULT_ATTEMPTS = 10


def load_flash_args(build_dir):
    path = os.path.join(build_dir, "flasher_args.json")
    if not os.path.isfile(path):
        sys.exit(f"Missing {path}. Build the firmware first.")
    with open(path) as fh:
        return json.load(fh)


def _esptool(args, cwd=None):
    """Run esptool via the IDF python env and return (returncode, output)."""
    cmd = [IDF_PYTHON, "-m", "esptool"] + args
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def try_link(port, baud, attempts, before):
    """One sync attempt at one baud. Returns True if the chip answered."""
    rc, out = _esptool([
        "--chip", "esp32", "--port", port, "--baud", str(baud),
        "--before", before, "--connect-attempts", str(attempts),
        "--after", "no_reset", "chip_id",
    ])
    ok = ("Chip is" in out) or ("MAC:" in out)
    if ok:
        mac = next((l.strip() for l in out.splitlines() if l.strip().startswith("MAC:")), "")
        print(f"      link OK at {baud} baud  {mac}")
    return ok


def find_link(port, bauds, attempts, before, wait=0):
    """Find a working (baud) for the chip.

    With wait=0 this is a single pass over the baud list. With wait>0 it keeps
    looping over the list until the deadline, which is what lets you do the
    manual BOOT/EN sequence while it is running.
    """
    deadline = time.time() + wait if wait else None
    pass_no = 0
    while True:
        pass_no += 1
        for baud in bauds:
            if try_link(port, baud, attempts, before):
                return baud
        if deadline is None or time.time() >= deadline:
            return None
        if pass_no == 1:
            print("      no chip yet - do: hold BOOT, tap EN/RST, release BOOT")
        time.sleep(1.5)


def main():
    ap = argparse.ArgumentParser()
    # COM3, not COM4: the bench CH340 (USB VID:PID=1A86:7523) enumerates as COM3 on
    # this machine. COM4 was the absent DevKit and every run failed with
    # "could not open port COM4". Confirm with pyserial before trusting a default —
    # note that Get-PnpDevice / `mode` / .NET SerialPort all return nothing in the
    # agent sandbox, so pyserial is the only reliable lister here.
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help=f"first baud to try (fallbacks: {BAUD_FALLBACKS})")
    ap.add_argument("--attempts", type=int, default=DEFAULT_ATTEMPTS,
                    help="sync attempts per baud (default 10; the esptool default is often too few)")
    ap.add_argument("--wait", type=int, default=0, metavar="SECONDS",
                    help="poll for the chip this long (use while entering manual download mode)")
    ap.add_argument("--no-reset", action="store_true",
                    help="chip is already in download mode; connect with --before no_reset")
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
    print(f"Port       : {args.port} @ {args.baud} (attempts={args.attempts})")
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

    # Build the baud list: requested first, then the fallbacks (de-duplicated).
    bauds = []
    for b in (args.baud,) + BAUD_FALLBACKS:
        if b not in bauds:
            bauds.append(b)

    before = "no_reset" if args.no_reset else "default_reset"
    print(f"\n[1/3] Testing link (before={before}, bauds={bauds})...")
    if args.wait:
        print(f"      polling for up to {args.wait}s - enter download mode by hand now:")
        print("      >>> hold BOOT, tap EN/RST, release BOOT <<<")
    good_baud = find_link(args.port, bauds, args.attempts, before, wait=args.wait)

    if good_baud is None:
        print("\n" + "=" * 70)
        print("LINK FAILED - cannot talk to the chip on", args.port)
        print("=" * 70)
        print("This is almost always the auto-reset, NOT the port. Work through:")
        print("  1. Enter download mode BY HAND: hold BOOT (GPIO0), tap EN/RST,")
        print("     release BOOT - then rerun with:  --wait 180")
        print("  2. Power-cycle first if it is wedged: unplug USB ~5 s, replug, then (1).")
        print("  3. Use a USB *data* cable and skip hubs; try another USB port.")
        print("  4. Confirm the port exists: python -c \"import serial.tools.list_ports")
        print("     as p; print([x.device for x in p.comports()])\"")
        print("  5. Reinstall the CH340 driver if the port appears but stays silent.")
        print()
        print("Do NOT hand-poke DTR/RTS - that strands the chip. Use (1) or (2).")
        return 1

    if args.check:
        print(f"\nLink OK at {good_baud} baud. Ready to flash.")
        return 0

    # After a successful link the chip is in download mode and stays there
    # (we connected with --after no_reset), so flash without re-running the
    # flaky reset.
    if args.erase:
        print("\n[2/3] Erasing flash...")
        rc, out = _esptool(["--chip", "esp32", "--port", args.port,
                            "--baud", str(good_baud), "--before", "no_reset",
                            "erase_flash"], cwd=os.path.dirname(bd))
        if rc != 0:
            print(out[-1500:])
            return rc
    else:
        print("\n[2/3] Skipping erase (--erase to force)")

    cmd = ["--chip", "esp32", "--port", args.port, "--baud", str(good_baud),
           "--before", "no_reset", "--after", "hard_reset",
           "write_flash", "--flash_size", args.flash_size]
    for off in sorted(files, key=lambda o: int(o, 16)):
        cmd += [off, files[off]]
    # Preserve the build's mode/freq; only the size is left to detection.
    wf = fa.get("write_flash_args", [])
    if "--flash_mode" in wf:
        cmd += ["--flash_mode", wf[wf.index("--flash_mode") + 1]]
    if "--flash_freq" in wf:
        cmd += ["--flash_freq", wf[wf.index("--flash_freq") + 1]]

    print("\n[3/3] Flashing:", " ".join(cmd[:12]), "...")
    rc, out = _esptool(cmd, cwd=bd)
    # Always surface the tail: a mid-flash abort ("The chip stopped responding")
    # leaves the app partition HALF-WRITTEN, which is worse than not flashing.
    for line in [l for l in out.splitlines()
                 if any(k in l for k in ("Hash of data verified", "Leaving",
                                         "Wrote", "A fatal", "stopped responding",
                                         "Hard resetting", "Writing at 0x0018"))][-8:]:
        print("   ", line)
    if rc != 0:
        print("\nFLASH FAILED. If it aborted mid-way the app partition is now corrupt:")
        print("  power-cycle, re-enter download mode, and rerun with --wait 180.")
        return rc

    print("\n" + "=" * 70)
    print("Flash complete. Monitor the boot log with:")
    print(f"  python scripts/run-idf.py -p {args.port} monitor")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
