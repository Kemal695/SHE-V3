#!/usr/bin/env python3
"""
Build the two NVS images a SHE V3 node needs to come online.

  fctry  @ 0x5C0000 (64 KB)  namespace "she_fctry" — PoP, MAC, SKU, node_id, client cert + key
  nvs    @ 0x9000   (24 KB)  namespace "she_nvs"  — tenant_id, home_id, mqtt_broker, api_base_url

Why two partitions:
  * fctry is factory-provisioned identity, written once (partition "fctry", namespace "she_fctry"
    — note they differ; the partition is "fctry", the NVS namespace inside it is "she_fctry").
  * she_nvs is the runtime/tenant config. NOTHING in the app-claims flow writes it today, which
    is exactly why the firmware logs:
        E she_mqtt: Failed to open NVS namespace she_nvs: ESP_ERR_NVS_NOT_FOUND
        E she_mqtt: Device not provisioned -- cannot start MQTT

Cert CN must be the MAC with colons stripped and lowercased (10061cae5328), because
she_mqtt.c uses that as the MQTT client_id and EMQX auth requires clientid == cn.

IMPORTANT: generating the nvs image replaces that whole partition, so Wi-Fi credentials are
wiped. The device must then be re-provisioned over BLE — which is the supported path and the
only way creds get stored (the ESP-IDF Wi-Fi creds are a driver-owned blob we cannot synthesize).

Usage:
  build-device-nvs.py --mac 10:06:1C:AE:53:28 --pop 123456789 \
      --cert scripts/device-certs/10061cae5328.cert.pem \
      --key  scripts/device-certs/10061cae5328.key.pem
"""
import argparse
import os
import pathlib
import re
import socket
import subprocess
import sys

IDF_PY = r"C:\Espressif\python_env\idf5.1_py3.11_env\Scripts\python.exe"
NVSTOOL = (r"C:\Espressif\frameworks\esp-idf-v5.1.4\components\nvs_flash"
           r"\nvs_partition_generator\nvs_partition_gen.py")

FCTRY_OFFSET, FCTRY_SIZE = 0x5C0000, 0x10000   # 64 KB
NVS_OFFSET, NVS_SIZE = 0x9000, 0x6000          # 24 KB

DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001"
# ⚠️ This must match the home the device is actually assigned to in the backend.
# It was stale (7600e8c7-…) while the node's real home was 69b4294f-…, and the
# mismatch is silent: the device connects, then publishes to a topic under a home
# the backend has no `homes` row for, so it never appears online and every
# command 404s. Always pass --home explicitly for a real device; this default is
# only a bring-up convenience.
DEFAULT_HOME = "69b4294f-c1bf-4a68-838e-b906892174ab"
# The CH340 on this bench enumerates as COM3. Every other script in scripts/
# still defaults to COM4 (the now-absent DevKit), which fails with
# "could not open port COM4". Change this if the board moves.
DEFAULT_PORT = "COM3"


def detect_lan_ip():
    """Best-effort primary LAN IPv4 address, or None.

    This exists so the default broker/API host is not a hardcoded address. It
    used to be `192.168.1.7`, which is not a placeholder — it was somebody's
    machine at one point. That value gets baked into the fctry partition at
    manufacturing time and the device dials it forever afterwards: when the
    router moved to 192.168.1.x the board spent its life failing to reach a host
    that no longer existed, and the only symptom was "device never appears in
    the app". A stale LAN IP is the worst kind of default — it looks valid.
    """
    try:
        # Connecting a UDP socket sends no packets; it just asks the OS which
        # local address would be used for an outbound route.
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return None


def resolve_endpoints(args):
    """Fill in --mqtt-broker / --api-base when they were not given.

    Order: explicit flag > environment variable > detected LAN IP > loopback.
    The resolved values are always printed, because this is exactly the setting
    that silently breaks a device later.
    """
    lan_ip = detect_lan_ip()

    if args.mqtt_broker is None:
        args.mqtt_broker = (
            os.environ.get("SHE_MQTT_BROKER")
            or (f"mqtts://{lan_ip}:8883" if lan_ip else "mqtts://mqtt.she.et:8883")
        )
    if args.api_base is None:
        args.api_base = (
            os.environ.get("SHE_API_BASE")
            or (f"http://{lan_ip}:8080" if lan_ip else "http://localhost:8080")
        )

    print(f"broker       : {args.mqtt_broker}")
    print(f"api base     : {args.api_base}")
    if lan_ip and lan_ip not in args.mqtt_broker:
        print(f"  ⚠ detected LAN IP is {lan_ip} but the broker points elsewhere — "
              f"make sure that host is reachable from the device's network.")


def normalize_mac(mac: str) -> str:
    clean = re.sub(r"[^0-9a-fA-F]", "", mac).lower()
    if len(clean) != 12:
        raise SystemExit(f"MAC must be 12 hex digits, got {len(clean)} from {mac!r}")
    return clean


def colon_mac(clean: str) -> str:
    """10:06:1C:AE:53:28 — the format firmware stores in device_mac."""
    return ":".join(clean[i:i + 2] for i in range(0, 12, 2)).upper()


def write_csv(path: pathlib.Path, namespace: str, rows):
    """rows: list of (key, datatype, encoding, value)."""
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write("# ESP-IDF NVS partition - generated by build-device-nvs.py\n")
        f.write("key,type,encoding,value\n")
        f.write(f"{namespace},namespace,,\n")
        for key, dt, enc, val in rows:
            f.write(f"{key},{dt},{enc},{val}\n")


def generate(csv_path: pathlib.Path, bin_path: pathlib.Path, size: int):
    r = subprocess.run(
        [IDF_PY, NVSTOOL, "generate", str(csv_path), str(bin_path), hex(size)],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not bin_path.exists():
        sys.stderr.write(r.stdout or "")
        sys.stderr.write(r.stderr or "")
        raise SystemExit(f"nvs_partition_gen failed for {csv_path.name}")
    return bin_path.stat().st_size


def main() -> int:
    here = pathlib.Path(__file__).parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True)
    ap.add_argument("--pop", default="123456789")
    ap.add_argument("--sku", default="SHE-R8")
    ap.add_argument("--node-id", default=None,
                    help="defaults to SHE-<R#>-<last6 of MAC>, e.g. SHE-8-AE5328")
    ap.add_argument("--hw-rev", default="rev-c")
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--tenant", default=DEFAULT_TENANT)
    ap.add_argument("--home", default=DEFAULT_HOME)
    ap.add_argument("--mqtt-broker", default=None,
                    help="defaults to $SHE_MQTT_BROKER, else mqtts://<detected LAN IP>:8883")
    ap.add_argument("--api-base", default=None,
                    help="defaults to $SHE_API_BASE, else http://<detected LAN IP>:8080")
    ap.add_argument("--fw-version", default="3.0.0")
    ap.add_argument("--mark-provisioned", action="store_true",
                    help="also set provisioned=1 in fctry, so re-flashing does not "
                         "kick an already-provisioned device back into BLE mode")
    ap.add_argument("--out", default=str(here / "nvs-build"))
    ap.add_argument("--port", default=DEFAULT_PORT,
                    help="serial port only used in the printed esptool hint")
    args = ap.parse_args()

    resolve_endpoints(args)

    clean = normalize_mac(args.mac)
    cmac = colon_mac(clean)
    node_id = args.node_id or f"SHE-{args.sku.split('-')[1][1:]}-{clean[-6:].upper()}"
    cert = pathlib.Path(args.cert).resolve()
    key = pathlib.Path(args.key).resolve()
    for p in (cert, key):
        if not p.exists():
            raise SystemExit(f"missing file: {p}")

    outdir = pathlib.Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    # ---- fctry: identity + mTLS material -------------------------------------
    # The connectivity config is written here TOO, not just to she_nvs: factory reset
    # calls nvs_flash_erase() on the default partition, which destroys she_nvs. With
    # this copy, a reset degrades to "re-provision Wi-Fi" rather than "never connect
    # to MQTT again". she_mqtt prefers she_nvs and falls back to these keys.
    fctry_csv = outdir / "fctry.csv"
    fctry_rows = [
        ("device_pop",  "data", "string", args.pop),
        ("device_mac",  "data", "string", cmac),
        ("device_sku",  "data", "string", args.sku),
        ("hw_rev",      "data", "string", args.hw_rev),
        ("node_id",     "data", "string", node_id),
        ("device_cert", "file", "string", str(cert)),
        ("device_key",  "file", "string", str(key)),
        ("tenant_id",   "data", "string", args.tenant),
        ("home_id",     "data", "string", args.home),
        ("mqtt_broker", "data", "string", args.mqtt_broker),
        ("api_base_url", "data", "string", args.api_base),
    ]
    # Re-flashing fctry also clears `provisioned`, which silently sends an already
    # working device back to BLE advertising — it drops off the LAN and looks like a
    # regression. --mark-provisioned writes the flag so a cert-only re-flash is
    # non-destructive (Wi-Fi creds live in the nvs partition and are untouched).
    if args.mark_provisioned:
        fctry_rows.append(("provisioned", "data", "u8", "1"))
    write_csv(fctry_csv, "she_fctry", fctry_rows)
    fctry_bin = outdir / "fctry.bin"
    fsz = generate(fctry_csv, fctry_bin, FCTRY_SIZE)

    # ---- nvs: tenant / broker config -----------------------------------------
    # `provisioned` is deliberately NOT set here: leaving it absent makes the firmware
    # take the BLE-provisioning branch on next boot, which is how Wi-Fi creds get in.
    nvs_csv = outdir / "nvs.csv"
    write_csv(nvs_csv, "she_nvs", [
        ("tenant_id",    "data", "string", args.tenant),
        ("home_id",      "data", "string", args.home),
        ("mqtt_broker",  "data", "string", args.mqtt_broker),
        ("api_base_url", "data", "string", args.api_base),
        ("fw_version",   "data", "string", args.fw_version),
        ("secure_version", "data", "u32", "1"),
    ])
    nvs_bin = outdir / "nvs.bin"
    nsz = generate(nvs_csv, nvs_bin, NVS_SIZE)

    print(f"node_id      : {node_id}")
    print(f"mac          : {cmac}  (client_id {clean})")
    print(f"fctry image  : {fctry_bin}  {fsz} bytes  -> flash @ {hex(FCTRY_OFFSET)}")
    print(f"nvs   image  : {nvs_bin}  {nsz} bytes  -> flash @ {hex(NVS_OFFSET)}")
    print()
    # `python -m esptool`, not `esptool.py`: the console script installed by the
    # IDF python env crashes with "module 'esptool' has no attribute '_main'",
    # which reads like a broken flash tool rather than a broken entry point.
    print("Flash with (device must be in download mode: hold BOOT, tap EN, release BOOT):")
    print(f'  "{IDF_PY}" -m esptool --chip esp32 --port {args.port} --baud 115200 '
          f"write_flash {hex(FCTRY_OFFSET)} {fctry_bin.as_posix()}")
    print()
    print("  ⚠ The nvs image is OPTIONAL and DESTRUCTIVE:")
    print(f"    it replaces the whole {hex(NVS_OFFSET)} partition, which also holds the")
    print("    Wi-Fi credentials written by provisioning. Flashing it logs the device")
    print("    off the network and forces a full re-provision.")
    print("    Only the fctry image is needed to change the broker / API address.")
    print(f'  "{IDF_PY}" -m esptool --chip esp32 --port {args.port} --baud 115200 '
          f"write_flash {hex(NVS_OFFSET)} {nvs_bin.as_posix()}   # ← wipes Wi-Fi creds")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
