import winreg

PORTS_CLASS = "{4d36e978-e325-11ce-bfc1-08002be10318}"
root = winreg.HKEY_LOCAL_MACHINE
usb_base = r"SYSTEM\CurrentControlSet\Enum\USB"

def read_val(key, name, default="<none>"):
    try:
        return winreg.QueryValueEx(key, name)[0]
    except OSError:
        return default

print("=== CH340 instance driver bindings ===")
try:
    vk = winreg.OpenKey(root, usb_base + r"\VID_1A86&PID_7523")
except OSError:
    print("no CH340 key"); raise SystemExit

i = 0
while True:
    try:
        inst = winreg.EnumKey(vk, i)
    except OSError:
        break
    i += 1
    ik = winreg.OpenKey(vk, inst)
    driver = read_val(ik, "Driver", None)
    print("\nInstance:", inst)
    print("  Driver   :", driver)
    if driver:
        # driver points to Control\Class\<class>\<NNNN>
        try:
            dk = winreg.OpenKey(root, "SYSTEM\\CurrentControlSet\\Control\\Class\\" + driver)
            print("  Service  :", read_val(dk, "Service"))
            print("  PortName :", read_val(dk, "PortName"))
            print("  Friendly :", read_val(dk, "FriendlyName"))
        except OSError as e:
            print("  (cannot open class key:", e, ")")
    # device parameters
    try:
        dpk = winreg.OpenKey(ik, "Device Parameters")
        print("  DP PortName:", read_val(dpk, "PortName"))
    except OSError:
        pass
