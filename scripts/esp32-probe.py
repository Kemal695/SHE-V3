#!/usr/bin/env python
"""
Exhaustive probe of an ESP32 on a serial port, without esptool.

Goal: establish which directions of the USB link actually work.
  ESP->PC : does the board print anything at all?
  PC->ESP : can we drive EN/IO0 and get the chip to react?

The CH340 + transistor reset network on most ESP32 devkits INVERTS the
control lines:
    DTR True  -> EN asserted (chip held in reset)
    DTR False -> EN released
    RTS True  -> IO0 asserted (bootloader select)
    RTS False -> IO0 released
We try both polarities, plus a no-touch read, plus forced download mode.
"""
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial not available")

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
BAUD = 115200


def drain(ser, seconds):
    end = time.time() + seconds
    buf = bytearray()
    while time.time() < end:
        n = ser.in_waiting
        if n:
            buf += ser.read(n)
        else:
            time.sleep(0.02)
    return bytes(buf)


def show(tag, raw):
    txt = "".join(ch if (ch.isprintable() or ch in "\r\n") else "." for ch in raw.decode("utf-8", "replace"))
    print(f"\n--- {tag} ---")
    print(txt if txt.strip() else f"(no output, {len(raw)} bytes)")
    return txt


def open_port():
    return serial.Serial(PORT, BAUD, timeout=0.3, dsrdtr=False, rtscts=False)


results = {}

print(f"Probing {PORT} @ {BAUD}")
print("=" * 72)

# --- Test 1: hands off. If an app is already running it will be chattering.
try:
    ser = open_port()
    time.sleep(0.3)
    ser.reset_input_buffer()
    raw = drain(ser, 3.0)
    results["idle"] = show("1. idle read, lines untouched", raw)
    ser.close()
except Exception as exc:
    print(f"1. FAILED: {exc}")

time.sleep(0.3)

# --- Test 2/3: reset pulse, both EN polarities, IO0 released (normal boot).
for inverted in (True, False):
    tag = "inverted (DTR high = reset)" if inverted else "normal (DTR low = reset)"
    try:
        ser = open_port()
        # Release state for this polarity, IO0 NOT asserted -> normal boot
        rel_en = False if inverted else True
        rst_en = True if inverted else False
        rel_io = False if inverted else True
        ser.setDTR(rel_en)
        ser.setRTS(rel_io)
        time.sleep(0.2)
        ser.reset_input_buffer()
        ser.setDTR(rst_en)      # assert reset
        time.sleep(0.20)
        ser.setDTR(rel_en)      # release
        raw = drain(ser, 3.0)
        results[f"boot_{inverted}"] = show(f"2. reset pulse, {tag}", raw)
        ser.close()
    except Exception as exc:
        print(f"2. FAILED ({tag}): {exc}")
    time.sleep(0.3)

# --- Test 4/5: forced download mode: IO0 held low while EN is released.
for inverted in (True, False):
    tag = "inverted (DTR high = reset)" if inverted else "normal (DTR low = reset)"
    try:
        ser = open_port()
        rel_en = False if inverted else True
        rst_en = True if inverted else False
        rel_io = False if inverted else True
        asr_io = True if inverted else False
        ser.setDTR(rst_en)      # hold in reset
        ser.setRTS(asr_io)      # assert IO0 BEFORE releasing reset
        time.sleep(0.15)
        ser.setDTR(rel_en)      # release reset -> boots into ROM download mode
        time.sleep(0.15)
        ser.setRTS(rel_io)      # release IO0 (rom already latched)
        raw = drain(ser, 3.0)
        results[f"dl_{inverted}"] = show(f"3. forced download mode, {tag}", raw)
        ser.close()
    except Exception as exc:
        print(f"3. FAILED ({tag}): {exc}")
    time.sleep(0.3)

print("\n" + "=" * 72)
any_out = any(v.strip() for v in results.values())
if any_out:
    print("RESULT: board transmits. ESP->PC direction WORKS.")
    print("        If esptool still cannot sync, the PC->ESP32 direction is")
    print("        broken -> almost always a charge-only or damaged USB cable.")
else:
    print("RESULT: board is silent on every probe.")
    print("        Either no firmware/boot ROM output reaches the PC, or the")
    print("        board is unpowered / not actually on this port.")
