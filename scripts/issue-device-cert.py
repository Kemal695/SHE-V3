#!/usr/bin/env python3
"""
Issue + register a device certificate for a SHE V3 node.

Generates an ECDSA P-256 keypair on this machine, builds a CSR with CN=<normalized MAC>,
and POSTs it to the backend's /internal/ca/sign-and-register, which forwards the CSR to
step-ca and records the result in `device_certs`.

The CN format matters and is easy to get wrong:
  * firmware `she_mqtt.c` derives its MQTT client_id from the node MAC as
    "lowercase, colons stripped"  ->  10:06:1C:AE:53:28  =>  10061cae5328
  * EMQX posts {clientid, cn, fingerprint:""} to /internal/mqtt/auth, and the backend
    requires clientid == cn, then looks the cert up by CN.
  So the CN MUST be the 12-char lowercase colon-free MAC.

Usage:
  issue-device-cert.py <MAC> [--tenant UUID] [--ca UUID] [--api http://host:8080]

Writes <MAC-clean>.key.pem and <MAC-clean>.cert.pem into ./device-certs/.
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

DEFAULT_API = "http://192.168.1.7:8080"
DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001"
DEFAULT_CA = "00000000-0000-0000-0000-000000000001"


def normalize_mac(mac: str) -> str:
    """Firmware format: lowercase, no separators. 10:06:1C:AE:53:28 -> 10061cae5328"""
    clean = re.sub(r"[^0-9a-fA-F]", "", mac).lower()
    if len(clean) != 12:
        raise SystemExit(f"MAC must be 12 hex digits, got {len(clean)} from {mac!r}")
    return clean


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mac", help="device MAC, any common format")
    ap.add_argument("--tenant", default=DEFAULT_TENANT)
    ap.add_argument("--ca", default=DEFAULT_CA)
    ap.add_argument("--api", default=DEFAULT_API)
    ap.add_argument("--out", default=str(pathlib.Path(__file__).parent / "device-certs"))
    args = ap.parse_args()

    cn = normalize_mac(args.mac)
    print(f"CN (normalized MAC): {cn}")

    # 1. ECDSA P-256 keypair — the only curve the firmware's mTLS stack is built for.
    key = ec.generate_private_key(ec.SECP256R1())
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        # SEC1 ("BEGIN EC PRIVATE KEY") rather than PKCS#8: the classic EC form that
        # mbedtls in ESP-IDF parses without ambiguity, and ~200 bytes smaller to store
        # in the NVS fctry partition.
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()

    # 2. CSR with CN = normalized MAC
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)]))
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    # 3. Sign + register
    body = json.dumps(
        {"csr_pem": csr_pem, "cn": cn, "tenant_id": args.tenant, "ca_id": args.ca}
    ).encode()
    req = urllib.request.Request(
        f"{args.api}/internal/ca/sign-and-register",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            resp = json.loads(r.read())
    except urllib.error.HTTPError as e:
        print("HTTP error:", e.status, e.read().decode()[:800], file=sys.stderr)
        return 1
    except Exception as e:
        print("request failed:", e, file=sys.stderr)
        return 1

    data = resp.get("data", {})
    cert_pem = data.get("cert_pem")
    if not cert_pem:
        print("no cert_pem in response:", json.dumps(resp)[:800], file=sys.stderr)
        return 1

    outdir = pathlib.Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    # step-ca returns PEM with CRLF line endings. That survives into the fctry NVS
    # image and breaks mbedtls's PEM parser on the ESP32 (OpenSSL tolerates it, which
    # is why a PC-side handshake test succeeds while the device fails with
    # MBEDTLS_ERR_SSL_INTERNAL_ERROR, -0x6C00). Write LF, with a trailing newline.
    def write_pem(path: pathlib.Path, pem: str) -> None:
        normalized = pem.replace("\r\n", "\n").replace("\r", "\n").strip() + "\n"
        path.write_bytes(normalized.encode("utf-8"))

    key_path = outdir / f"{cn}.key.pem"
    cert_path = outdir / f"{cn}.cert.pem"
    write_pem(key_path, key_pem)
    write_pem(cert_path, cert_pem)

    print(f"serial      : {data.get('serial')}")
    print(f"fingerprint : {data.get('fingerprint')}")
    print(f"expires_at  : {data.get('expires_at')}")
    print(f"wrote       : {outdir / f'{cn}.key.pem'}")
    print(f"wrote       : {outdir / f'{cn}.cert.pem'}")
    print(f"\nstored CN in device_certs: {cn}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
