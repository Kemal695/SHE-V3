#!/usr/bin/env python
"""Recover a SHE V3 device's 9-digit BLE PoP from its fctry NVS partition.

Background
----------
The PoP is a 9-digit numeric secret used for the BLE provisioning secure
session (V3-FIRMWARE §5, P1-26). It is written at the factory into the
`fctry` NVS partition and is the ONLY copy that exists in plaintext — the
backend stores just a SHA-256 hash (`pop_hash`), and the mobile app never
sees it until the operator types it in.

If the on-board USB-serial console is silent (common on bring-up boards),
you can still recover the PoP by reading the partition straight off flash
with esptool's stub loader. This script does exactly that:

  1. reads the on-device partition table at 0x8000 and locates `fctry`
     (so it works for both the classic-ESP32 and ESP32-S3 layouts),
  2. reads that partition,
  3. pulls the printable NVS entries out of the blob and prints them,
  4. highlights any bare 9-digit run as the candidate PoP.

Requires: an ESP-IDF python env (has esptool + pyserial), e.g.
  C:/Espressif/python_env/idf5.1_py3.11_env/Scripts/python.exe

Usage:
  python scripts/read-fctry-pop.py [PORT] [BAUD] [--dump FILE]
  python scripts/read-fctry-pop.py COM4 115200
"""
import argparse
import os
import re
import struct
import sys
import time

import esptool  # noqa: F401  (imported for its side effect of being present)
from esptool.targets.esp32 import ESP32ROM

PART_TABLE_ADDR = 0x8000
PART_MAGIC = 0x50AA
FCTRY_MAX = 0x10000


def find_fctry(blob):
    """Return (offset, size) of the `fctry` partition from a partition table."""
    for i in range(95):
        off = i * 32
        if off + 32 > len(blob):
            break
        magic, = struct.unpack_from("<H", blob, off)
        if magic != PART_MAGIC:
            break
        ptype, psub = struct.unpack_from("<BB", blob, off + 2)
        poff, psize = struct.unpack_from("<II", blob, off + 4)
        name = blob[off + 12:off + 28].split(b"\x00")[0].decode("latin-1")
        if name == "fctry":
            return poff, psize, (ptype, psub)
    return None, None, None


def connect(port, baud, attempts=8):
    last = None
    for n in range(1, attempts + 1):
        try:
            esp = ESP32ROM(port, baud)
            esp.connect()
            print(f"  connected: {esp.CHIP_NAME}  mac={esp.read_mac()}")
            return esp
        except Exception as exc:  # noqa: BLE001
            last = exc
            print(f"  connect attempt {n} failed: {type(exc).__name__}: {str(exc)[:100]}")
            time.sleep(1.5)
    raise SystemExit(f"could not open {port}: {last}")


def main():
    ap = argparse.ArgumentParser(description="Recover the SHE V3 BLE PoP from fctry NVS")
    ap.add_argument("port", nargs="?", default="COM4")
    ap.add_argument("baud", nargs="?", type=int, default=115200)
    ap.add_argument("--dump", default=None, help="also save the raw fctry image here")
    args = ap.parse_args()

    esp = connect(args.port, args.baud)
    stub = esp.run_stub()

    try:
        table = stub.read_flash(PART_TABLE_ADDR, 0x1000)
        off, size, meta = find_fctry(table)
        if off is None:
            raise SystemExit("no `fctry` partition found in the on-device partition table")
        print(f"  fctry partition: offset=0x{off:06X} size=0x{size:X} "
              f"(type/subtype={meta[0]}/{meta[1]})")

        size = min(size, FCTRY_MAX)
        blob = stub.read_flash(off, size)
        print(f"  read {len(blob)} bytes from fctry")
    finally:
        try:
            stub._port.close()
        except Exception:
            pass

    if args.dump:
        with open(args.dump, "wb") as fh:
            fh.write(blob)
        print(f"  raw dump -> {args.dump}")

    # NVS is log-structured: walk the printable runs. Keys and string values
    # both appear; the PoP is a bare 9-digit numeric run.
    text = blob.decode("latin-1")
    runs = re.findall(r"[ -~]{3,}", text)
    print("\n=== printable NVS entries ===")
    for r in runs:
        print(f"  {r!r}")

    nine = sorted({r.strip() for r in runs if re.fullmatch(r"\d{9}", r.strip())})
    print("\n=== candidate PoP (9-digit) ===")
    if nine:
        for n in nine:
            print(f"  >>> PoP = {n}")
        if len(nine) > 1:
            print("  NOTE: several candidates — pick the one stored under key `device_pop`.")
    else:
        print("  none found. The partition may be NVS-encrypted, or empty.")
        print("  If the console works, the firmware also prints it at boot:")
        print("      I (she_ble) PoP = XXXXXXXXX (source: fctry NVS)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
