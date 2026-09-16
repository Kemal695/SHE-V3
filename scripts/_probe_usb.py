import winreg, serial

# 1) What USB devices does Windows currently have enumerated?
base = r"SYSTEM\CurrentControlSet\Enum\USB"
try:
    k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, base)
except Exception as e:
    print("REG_OPEN_FAIL", e)
    k = None

print("=== USB devices (HKLM ... Enum/USB) ===")
if k:
    i = 0
    while True:
        try:
            vid = winreg.EnumKey(k, i)
        except OSError:
            break
        i += 1
        try:
            sk = winreg.OpenKey(k, vid)
        except OSError:
            continue
        j = 0
        while True:
            try:
                pid = winreg.EnumKey(sk, j)
            except OSError:
                break
            j += 1
            print("  ", vid, pid)

print()
print("=== Probe COM1..COM12 ===")
for n in range(1, 13):
    p = "COM%d" % n
    try:
        s = serial.Serial(p, 115200, timeout=0.3)
        s.close()
        print("OPEN_OK", p)
    except Exception:
        pass
print("(only ports that opened are listed above)")
