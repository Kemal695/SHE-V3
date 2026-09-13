#!/usr/bin/env python
"""
Passive serial listener for the ESP32.

Opens the port, asserts nothing, and prints anything that arrives with a
timestamp. Use it while physically pressing buttons on the board:

  - press and release EN        -> should print the ROM banner + app boot log
  - hold BOOT, tap EN, release  -> should print "waiting for download"

If this prints NOTHING while you press EN, the ESP->PC direction of the link
is dead (cable, or board not powered). If it prints but esptool cannot sync,
the PC->ESP32 direction is dead (charge-only cable) or you must enter
download mode manually.

Usage:  python esp32-listen.py [PORT] [BAUD] [SECONDS]
"""
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial not available")

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
SECS = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0

print(f"Listening on {PORT} @ {BAUD} for {SECS:.0f}s")
print("Press EN on the board now. Hold BOOT + tap EN for download mode.")
print("=" * 72)

try:
    ser = serial.Serial(PORT, BAUD, timeout=0.2, dsrdtr=False, rtscts=False)
except Exception as exc:
    sys.exit(f"Cannot open {PORT}: {exc}")

# Leave the control lines in the released state so we do not hold the chip
# in reset. On the common CH340 devkit network DTR-low / RTS-low = released.
try:
    ser.setDTR(False)
    ser.setRTS(False)
except Exception:
    pass

ser.reset_input_buffer()

start = time.time()
total = 0
last_report = start
try:
    while time.time() - start < SECS:
        n = ser.in_waiting
        if n:
            data = ser.read(n)
            total += n
            stamp = f"[{time.time() - start:7.2f}s]"
            txt = data.decode("utf-8", "replace")
            txt = txt.replace("\r", "\\r").replace("\n", "\n")
            for line in txt.split("\n"):
                if line.strip():
                    print(f"{stamp} {line}")
        else:
            time.sleep(0.02)
        # Heartbeat so you can tell it is alive
        if time.time() - last_report >= 10:
            last_report = time.time()
            print(f"[        ] ... {total} bytes so far, still listening")
except KeyboardInterrupt:
    print("\n(interrupted)")
finally:
    ser.close()

print("=" * 72)
if total == 0:
    print(f"RESULT: {total} bytes received. Board is silent -> ESP->PC link is dead.")
    print("        Check: is the board powered? Is it on this COM port?")
    print("        Try a different USB DATA cable (many are charge-only).")
else:
    print(f"RESULT: {total} bytes received. ESP->PC link WORKS.")
    print("        If esptool cannot sync, the PC->ESP32 direction is broken,")
    print("        or you must enter download mode manually (hold BOOT, tap EN).")
