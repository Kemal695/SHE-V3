"""Locate the SHE V3 node on the LAN.

Two ways, in order of reliability:

1. **ARP table** — the device's MAC is known from NVS (`device_mac`), and ARP needs no
   TLS, no extra packages and no guessing. This is the primary method.
2. **Cert CN scan** — fall back to sweeping the /24 for :443 and matching the certificate
   CN (the lowercase colon-free MAC). Only attempted when the ARP lookup misses.

Why the cert path is NOT the default: the managed python has no `cryptography` package, so
every cert parse fails and the scan reports "could not parse cert" for *every* host. That
reads like "no device found" while actually being a silent false negative. If you need the
cert path, install `cryptography` first or use `openssl s_client`.
"""
import concurrent.futures as cf
import re
import socket
import subprocess
import sys

SUBNET = "192.168.1."
DEVICE_MAC = "10-06-1c-ae-53-28"    # from fctry NVS device_mac (10:06:1C:AE:53:28)
DEVICE_CN = "10061cae5328"          # same MAC, lowercased, no colons
PORT = 443


def from_arp():
    """Primary: read the OS ARP table. No packets, no TLS, no dependencies."""
    try:
        out = subprocess.run(["arp", "-a"], capture_output=True, text=True,
                             timeout=15).stdout
    except Exception as e:
        print(f"  arp -a failed: {e}")
        return None

    for line in out.splitlines():
        if DEVICE_MAC.lower() in line.lower():
            m = re.search(r"(\d+\.\d+\.\d+\.\d+)", line)
            if m:
                return m.group(1)
    return None


def cert_cn(host: str):
    """Return the peer cert CN via openssl, or None."""
    try:
        out = subprocess.run(
            ["openssl", "s_client", "-connect", f"{host}:{PORT}",
             "-servername", host, "-showcerts"],
            input="", capture_output=True, text=True, timeout=12,
        ).stdout
    except Exception:
        return None
    m = re.search(r"CN\s*=\s*([^\s,/]+)", out)
    return m.group(1) if m else None


def tcp_open(host: str) -> bool:
    try:
        with socket.create_connection((host, PORT), timeout=1.0):
            return True
    except Exception:
        return False


def scan():
    """Fallback: sweep :443 and match the cert CN."""
    hosts = [f"{SUBNET}{i}" for i in range(1, 255)]
    with cf.ThreadPoolExecutor(max_workers=64) as ex:
        open_hosts = [h for h, ok in zip(hosts, ex.map(tcp_open, hosts)) if ok]

    print(f"  :{PORT} open on {len(open_hosts)} host(s)")
    for h in open_hosts:
        cn = cert_cn(h)
        hit = "   <== SHE V3 DEVICE" if cn and DEVICE_CN in cn else ""
        print(f"    {h:15} CN={cn}{hit}")
        if hit:
            return h
    return None


def main() -> int:
    print("1) ARP table (primary)")
    ip = from_arp()
    if ip:
        print(f"   found {ip} (MAC {DEVICE_MAC})")
    else:
        print(f"   MAC {DEVICE_MAC} not in ARP table")

    if not ip:
        print("2) :443 cert-CN scan (fallback)")
        ip = scan()

    if not ip:
        print("\nDevice not found — powered off, or off Wi-Fi.")
        return 1

    print(f"\nDEVICE IP = {ip}")
    if tcp_open(ip):
        print(f"  :{PORT} reachable — try:  "
              f"curl -sk -H 'X-SHE-PoP: <pop>' https://{ip}/she/info")
    else:
        print(f"  :{PORT} NOT reachable — device is on the network but its local "
              f"control server may not have started.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
