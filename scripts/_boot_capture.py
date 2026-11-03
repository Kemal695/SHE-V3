import serial, time, sys

PORT = "COM3"
DUR = 10
try:
    s = serial.Serial(PORT, 115200, timeout=0.5)
except Exception as e:
    print("OPEN_FAIL:", e)
    sys.exit(1)

# Hard-reset into RUN mode (IO0 high / EN pulse), then capture boot log.
try:
    s.setDTR(False)   # IO0 = HIGH  (normal boot, not download)
    s.setRTS(True)    # EN  = LOW   (assert reset)
    time.sleep(0.25)
    s.setRTS(False)   # EN  = HIGH  (release -> boot)
except Exception as e:
    print("RESET_FAIL:", e)

print(f"--- boot capture {PORT} @115200 for {DUR}s ---")
end = time.time() + DUR
got = False
while time.time() < end:
    line = s.readline()
    if line:
        got = True
        try:
            sys.stdout.write(line.decode("utf-8", "replace"))
            sys.stdout.flush()
        except Exception:
            pass
s.close()
print("--- end ---")
if not got:
    print("(still no output — BLE advertising is silent until a client connects)")
