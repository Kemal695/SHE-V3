"""Turn Relay 1 ON via the API while capturing the ESP32 console on COM4.

Runs both halves in one process so there is no cross-process coordination
(which kept failing under Git Bash backgrounding).
"""
import json
import re
import sys
import threading
import time
import urllib.request

PORT = "COM4"
BAUD = 115200
CAPTURE_S = 30
API = "http://192.168.1.10:8080/api/v3"
EMAIL = "kemalai695@gmail.com"
PASSWORD = "SheV3Temp!2026"
NODE = "21404d07-d2d8-478c-afd2-cafda8da32e6"
RELAY1 = "2ec799dc-5b9f-4892-9b95-f003c7eee5ff"


def put_relay(on: bool) -> str:
    req = urllib.request.Request(
        API + "/auth/login",
        data=json.dumps({"email": EMAIL, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        tok = json.load(r)["data"]["access_token"]
    body = json.dumps({"Power": on}).encode()
    req = urllib.request.Request(
        f"{API}/nodes/{NODE}/devices/{RELAY1}/params",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {tok}"},
        method="PUT",
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return f"HTTP {r.status}: {r.read().decode()[:200]}"


def main() -> int:
    import serial

    ser = serial.Serial(PORT, BAUD, timeout=1)
    result = {}

    def fire():
        time.sleep(3)
        try:
            result["api"] = put_relay(True)
        except Exception as e:  # noqa: BLE001
            result["api"] = f"ERROR {e}"

    t = threading.Thread(target=fire, daemon=True)
    t.start()

    chunks = []
    end = time.time() + CAPTURE_S
    while time.time() < end:
        try:
            d = ser.read(8192)
        except Exception as e:  # noqa: BLE001
            result["read_error"] = str(e)
            break
        if d:
            chunks.append(d.decode("utf-8", "replace"))
    ser.close()

    text = "".join(chunks)
    with open(r"D:\she-v3\.workbuddy-ai\esp_relay.log", "w", encoding="utf-8") as f:
        f.write(text)

    print("captured_bytes", len(text))
    print("api:", result.get("api", "<none>"))
    if "read_error" in result:
        print("read_error:", result["read_error"])

    print("--- interesting lines ---")
    pat = re.compile(r"direct ch|relay|Relay|params|Power|she_mqtt", re.I)
    hits = [
        ln for ln in text.splitlines()
        if pat.search(ln) and "mqtt_client" not in ln and "transport_base" not in ln
    ]
    for ln in hits[:40]:
        print(ln)
    if not hits:
        tags = {}
        for m in re.finditer(r"^[DWIEV] \(\d+\) ([^:]+):", text, re.M):
            tags[m.group(1)] = tags.get(m.group(1), 0) + 1
        print("no relay lines; tags seen:", tags)
    return 0


if __name__ == "__main__":
    sys.exit(main())
