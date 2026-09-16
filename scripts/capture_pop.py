# Capture an ESP32 boot log and extract the factory PoP.
#
# Run with the managed python env (has pyserial 3.5):
#   C:\Users\kemal\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe capture_pop.py [PORT]
#
# If PORT is omitted it lists the available COM ports and exits.
# The PoP line looks like:
#   I (she_ble) PoP = 123456789 (source: fctry NVS) - type this into the app's PoP field
#
# NOTE: some boards (the COM4 DevKit) have a DEAD auto-reset circuit and ignore
# RTS/DTR, so the EN pulse below may not reboot them. If you see no boot log,
# power-cycle or press the EN button on the board while this script is listening.
import serial
import serial.tools.list_ports as lp
import sys
import time

BAUD = 115200
LISTEN_S = 30.0


def list_ports():
    ports = lp.comports()
    print("Available COM ports:")
    for p in ports:
        print("  %s | %s | %s" % (p.device, p.description, p.hwid))
    return ports


def main():
    if len(sys.argv) > 1:
        port = sys.argv[1]
    else:
        ports = list_ports()
        if not ports:
            print("No COM ports found. Plug the device in and retry.")
            return
        if len(ports) == 1:
            port = ports[0].device
            print("Auto-selected %s" % port)
        else:
            print("Multiple ports - pass one explicitly: capture_pop.py COMx")
            return

    listen = LISTEN_S
    if len(sys.argv) > 2:
        try:
            listen = float(sys.argv[2])
        except ValueError:
            pass
        ports = list_ports()
        if not ports:
            print("No COM ports found. Plug the device in and retry.")
            return
        if len(ports) == 1:
            port = ports[0].device
            print("Auto-selected %s" % port)
        else:
            print("Multiple ports - pass one explicitly: capture_pop.py COMx")
            return

    try:
        ser = serial.Serial(port, BAUD, timeout=1)
    except Exception as e:
        print("OPEN_FAIL %s: %s" % (port, e))
        return

    print("=== %s @ %d opened; pulsing EN then listening %.0fs ===" % (port, BAUD, listen), flush=True)
    # Try an EN pulse (RTS -> EN active-low). Harmless if the circuit is dead.
    try:
        ser.dtr = False
        ser.rts = False
        time.sleep(0.10)
        ser.rts = True   # EN low
        time.sleep(0.10)
        ser.rts = False  # EN high -> boot from flash
        time.sleep(0.30)
        ser.dtr = False
    except Exception as e:
        print("RESET_PULSE_WARN: %s" % e, flush=True)

    print("If the board has a dead auto-reset, press EN / power-cycle it now.", flush=True)
    end = time.time() + listen
    pop_lines = []
    while time.time() < end:
        try:
            raw = ser.readline()
        except Exception as e:  # serial dropped (flaky cable)
            print("READ ERROR: %s" % e, flush=True)
            break
        if not raw:
            continue
        line = raw.decode(errors="replace").rstrip()
        if line:
            print(line, flush=True)
            # PoP appears in two forms across the log
            if "PoP" in line:
                pop_lines.append(line)
    print("=== PoP lines ===", flush=True)
    for l in pop_lines:
        print(l, flush=True)
    if not pop_lines:
        print("(no PoP line captured - device may already be past BLE provisioning, or the link is dead)", flush=True)
    ser.close()


if __name__ == "__main__":
    main()
