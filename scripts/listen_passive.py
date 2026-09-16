# Passive listener: open COM4, do NOT reset, just read whatever the device
# sends for 20s. Confirms whether the serial link is alive and at what baud.
import serial
import time

PORT = "COM4"
BAUD = 115200


def main():
    ser = serial.Serial(PORT, BAUD, timeout=1)
    ser.dtr = False
    ser.rts = False
    print("=== passive listen %s @ %d for 20s ===" % (PORT, BAUD), flush=True)
    end = time.time() + 20.0
    got = 0
    while time.time() < end:
        try:
            raw = ser.readline()
        except Exception as e:
            print("READ ERROR: %s" % e, flush=True)
            break
        if not raw:
            continue
        got += 1
        line = raw.decode(errors="replace").rstrip()
        print(line, flush=True)
    print("=== bytes/lines received: %d ===" % got, flush=True)
    ser.close()


if __name__ == "__main__":
    main()
