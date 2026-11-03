import serial, time, sys
try:
    s = serial.Serial("COM3", 115200, timeout=0.5)
except Exception as e:
    print("OPEN_FAIL:", e); sys.exit(1)
end = time.time() + 12
while time.time() < end:
    l = s.readline()
    if l:
        sys.stdout.write(l.decode("utf-8", "replace")); sys.stdout.flush()
s.close()
