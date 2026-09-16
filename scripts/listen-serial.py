#!/usr/bin/env python3
"""
Listen on the ESP32 serial console and append everything to a file, flushing as it goes.

Flushing matters: if the process is killed before it finishes, whatever it already saw is
still on disk.

Usage: listen-serial.py [seconds] [outfile]
"""
import re
import sys
import time

import serial

PORT = "COM4"
BAUD = 115200
secs = int(sys.argv[1]) if len(sys.argv) > 1 else 90
out = sys.argv[2] if len(sys.argv) > 2 else r"D:\she-v3\scripts\_listen.txt"

try:
    s = serial.Serial(PORT, BAUD, timeout=0.2)
except Exception as e:
    print(f"open failed: {e}")
    raise SystemExit(1)

total = 0
t0 = time.time()
with open(out, "w", encoding="utf-8", errors="replace") as f:
    f.write(f"# listening on {PORT} @ {BAUD} for {secs}s\n")
    f.flush()
    while time.time() - t0 < secs:
        n = s.in_waiting
        if n:
            data = s.read(n)
            total += len(data)
            txt = data.decode("utf-8", "replace")
            txt = re.sub(r"\x1b\[[0-9;]*m", "", txt)
            txt = "".join(c if (c.isprintable() or c in "\r\n") else "." for c in txt)
            f.write(txt)
            f.flush()
        else:
            time.sleep(0.05)
    f.write(f"\n# total {total} bytes\n")
s.close()
print(f"done: {total} bytes -> {out}")
