#!/usr/bin/env python
"""
Boot the ESP32 from flash and capture the log.

Why this exists: hand-rolled DTR/RTS pulses on this board produce nothing, and
esptool has already exited by the time you can attach a listener. This uses
esptool's OWN reset sequence (which demonstrably works — `--before no_reset`
fails while `--before default_reset` succeeds, proving the modem-control lines
do reach EN/IO0), then keeps the same open port and reads the boot output.

Usage: python esp32-boot-capture.py [PORT] [BAUD] [SECONDS]
"""
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
SECS = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0

try:
    import esptool
    from esptool.targets.esp32 import ESP32ROM
except Exception as exc:
    sys.exit(f"esptool unavailable: {exc}")

print(f"Connecting to {PORT} @ {BAUD} using esptool's reset sequence...")
esp = ESP32ROM(PORT, BAUD)
esp.connect()  # default_reset — this is the sequence that is known to work
print(f"Connected: {esp.CHIP_NAME}")

port = esp._port
port.timeout = 0.2

# Flush anything the ROM printed while syncing.
try:
    port.reset_input_buffer()
except Exception:
    pass

print("Issuing hard_reset — booting the application from flash...")
esp.hard_reset()

buf = bytearray()
t0 = time.time()
try:
    while time.time() - t0 < SECS:
        n = port.in_waiting
        if n:
            buf += port.read(n)
        else:
            time.sleep(0.02)
finally:
    try:
        port.close()
    except Exception:
        pass

txt = buf.decode("utf-8", "replace")
txt = "".join(ch if (ch.isprintable() or ch in "\r\n") else "." for ch in txt)

print("=" * 72)
print(txt if txt.strip() else f"(silent — {len(buf)} bytes)")
print("=" * 72)
print(f"{len(buf)} bytes in {SECS:.0f}s")
