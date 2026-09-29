#!/usr/bin/env python3
"""Exercise the SHE board's LOCAL control API (HTTPS :443) on the LAN.

This path is deliberately independent of MQTT/TLS-to-broker: it proves the board
is alive, its relay driver works, and state round-trips through its own NVS.

Usage:
    python scripts/board-local-ctl.py --host 192.168.1.24 --pop 123456789 info
    python scripts/board-local-ctl.py --host 192.168.1.24 --pop 123456789 on 1
    python scripts/board-local-ctl.py --host 192.168.1.24 --pop 123456789 off all
    python scripts/board-local-ctl.py --host 192.168.1.24 --pop 123456789 sweep
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request

# The board serves a self-signed cert from its fctry partition; identity is proven
# by the PoP header instead, so verification is intentionally disabled here.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def call(host, pop, path, body=None, timeout=10):
    url = f"https://{host}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data,
        headers={"X-SHE-PoP": pop, "Content-Type": "application/json"},
        method="POST" if data else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
    except Exception as e:
        return None, {"error": str(e)}


def info(host, pop):
    return call(host, pop, "/she/info")


def set_relay(host, pop, n, on):
    return call(host, pop, "/she/ctrl",
                {"device_name": f"Relay {n}", "params": {"Power": on}})


def show(host, pop):
    code, d = info(host, pop)
    if code != 200:
        print(f"  /she/info -> HTTP {code}: {d}")
        return None
    print(f"  node_id={d.get('node_id')}  sku={d.get('sku')}")
    for dev in d.get("devices", []):
        val = dev["params"][0]["value"] if dev.get("params") else "?"
        print(f"    ch{dev['channel']:<2} {dev['name']:<10} Power={val}")
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.24")
    ap.add_argument("--pop", default="123456789")
    ap.add_argument("cmd", choices=["info", "on", "off", "sweep"])
    ap.add_argument("target", nargs="?", default="all", help="relay number or 'all'")
    args = ap.parse_args()

    print(f"== board {args.host} — before ==")
    show(args.host, args.pop)

    if args.cmd == "info":
        return 0

    if args.cmd == "sweep":
        # Turn every relay ON, verify, then OFF, verify. Catches a channel whose
        # write is ACKed but does not stick (bad joint / driver latch).
        ok = True
        for on in (True, False):
            label = "ON" if on else "OFF"
            print(f"\n== setting all relays {label} ==")
            for n in range(1, 5):
                code, r = set_relay(args.host, args.pop, n, on)
                print(f"  Relay {n}: HTTP {code} {r}")
                if code != 200:
                    ok = False
            code, d = info(args.host, args.pop)
            vals = [dev["params"][0]["value"] for dev in d.get("devices", [])]
            print(f"  readback: {vals}  (expect all {on})")
            if any(v != on for v in vals):
                ok = False
                print("  !! MISMATCH — a channel did not hold")
        print("\n== after ==")
        show(args.host, args.pop)
        print("\nRESULT:", "PASS" if ok else "FAIL")
        return 0 if ok else 1

    on = args.cmd == "on"
    targets = range(1, 5) if args.target == "all" else [int(args.target)]
    for n in targets:
        code, r = set_relay(args.host, args.pop, n, on)
        print(f"  Relay {n} -> {'ON' if on else 'OFF'}: HTTP {code} {r}")

    print("\n== after ==")
    show(args.host, args.pop)
    return 0


if __name__ == "__main__":
    sys.exit(main())
