#!/usr/bin/env python3
"""Sign a SHE V3 firmware image for OTA.

Produces the `sig` field the device expects in the `ota/url` payload.

## What exactly gets signed

V3-SECURITY-MODEL §5.5 specifies:

    ESP32 verifies: ... SHA-256(body) matches `sha256` field
                        → Ed25519-verify(signature, hash, public_key)

So the **signed message is the 32-byte SHA-256 digest of the image**, not the image
itself. The device streams the image from the OTA partition, hashes it, and calls
TweetNaCl's `crypto_sign_open(sig || digest, pubkey)`.

Signing the digest rather than the whole image keeps the tool cheap and matches the
spec. If you ever change this, change `verify_ed25519_signature()` in
`firmware/v3/main/ota_handler.c` in the same commit — the two must agree exactly.

## Usage

    scripts/sign-firmware.py firmware/v3/build-esp32/she-firmware.bin
    scripts/sign-firmware.py <image.bin> --key ota-keys/ota_signing.key --json
"""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile

DEFAULT_KEY = os.path.join("ota-keys", "ota_signing.key")


def sha256_file(path: str) -> bytes:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.digest()


def ed25519_sign_digest(key_path: str, digest: bytes) -> bytes:
    """Sign the raw digest with openssl.

    `-rawin` is essential: without it openssl treats the input differently and the
    device's crypto_sign_open will reject the result. Ed25519 signs the message
    directly, so the 32-byte digest IS the message here.
    """
    with tempfile.TemporaryDirectory() as td:
        dpath = os.path.join(td, "digest.bin")
        spath = os.path.join(td, "sig.bin")
        with open(dpath, "wb") as f:
            f.write(digest)

        cmd = [
            "openssl", "pkeyutl", "-sign",
            "-inkey", key_path,
            "-rawin",
            "-in", dpath,
            "-out", spath,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            sys.exit(f"openssl failed (rc={proc.returncode}):\n{proc.stderr.strip()}")

        with open(spath, "rb") as f:
            sig = f.read()

    if len(sig) != 64:
        sys.exit(f"Expected a 64-byte Ed25519 signature, got {len(sig)}")
    return sig


def public_key_hex(key_path: str) -> str:
    """The raw 32-byte public key, so it can be checked against the firmware array."""
    proc = subprocess.run(
        ["openssl", "pkey", "-in", key_path, "-pubout", "-outform", "DER"],
        capture_output=True,
    )
    if proc.returncode != 0:
        return "<could not derive>"
    return proc.stdout[-32:].hex()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="firmware .bin to sign")
    ap.add_argument("--key", default=DEFAULT_KEY, help=f"Ed25519 private key (default {DEFAULT_KEY})")
    ap.add_argument("--version", default="", help="version string for the ota/url payload")
    ap.add_argument("--json", action="store_true", help="emit the ota/url payload as JSON")
    args = ap.parse_args()

    if not os.path.isfile(args.image):
        sys.exit(f"No such image: {args.image}")
    if not os.path.isfile(args.key):
        sys.exit(f"No such key: {args.key}\n"
                 f"Generate one with:\n"
                 f"  mkdir -p ota-keys && openssl genpkey -algorithm ed25519 "
                 f"-out {args.key}")

    digest = sha256_file(args.image)
    sig = ed25519_sign_digest(args.key, digest)
    sig_b64 = base64.b64encode(sig).decode()
    size = os.path.getsize(args.image)

    if args.json:
        payload = {
            "version": args.version,
            "url": "<set this to the MinIO URL>",
            "sig": sig_b64,
            "size": size,
            "sha256": digest.hex(),
        }
        print(json.dumps(payload, indent=2))
    else:
        print(f"image      : {args.image}")
        print(f"size       : {size} bytes")
        print(f"sha256     : {digest.hex()}")
        print(f"pubkey     : {public_key_hex(args.key)}")
        print(f"sig (b64)  : {sig_b64}")
        print()
        print("The firmware embeds this public key. If it does not match "
              "ota_ed25519_pubkey[] in ota_handler.c, every OTA will be rejected.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
