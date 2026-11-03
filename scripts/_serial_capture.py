import serial, time, sys, io

PORT = "COM3"
DUR = 200  # long window so the user can tap EN
OUT = r"D:/project X/SHE-V3/scripts/nvs-build/bootlog.txt"

try:
    s = serial.Serial(PORT, 115200, timeout=0.5)
except Exception as e:
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(f"OPEN_FAIL: {e}\n")
    sys.exit(1)

# Do not rely on DTR/RTS (this board has no auto-reset wiring). Just listen.
try:
    s.setDTR(False); s.setRTS(False)
except Exception:
    pass

end = time.time() + DUR
with open(OUT, "w", encoding="utf-8", buffering=1) as f:
    f.write(f"--- listening {PORT} @115200 for {DUR}s (waiting for EN tap) ---\n")
    while time.time() < end:
        line = s.readline()
        if line:
            try:
                f.write(line.decode("utf-8", "replace"))
            except Exception:
                pass
    f.write("--- end ---\n")
s.close()
