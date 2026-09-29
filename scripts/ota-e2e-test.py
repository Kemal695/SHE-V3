#!/usr/bin/env python3
"""End-to-end OTA test against a real SHE V3 board, over MQTT.

Exercises the DEVICE path only: publish `ota/url` → the board downloads, verifies
(SHA-256 + Ed25519), writes the inactive slot, reboots, and — if the new image
stays healthy — publishes a terminal `ota/status`.

## Why this script exists (read before "fixing" it)

1. **Subscribe BEFORE publishing.** `ota/status` is QoS 1 and **not retained**, and
   the terminal `success` is emitted ~300 s after the reboot. Attach late and you
   simply never see it, which looks exactly like a failed rollout. This script
   waits for the SUBACK before it triggers.

2. **`{"status":"rebooting"}` is NOT success.** `ota_handler.c` publishes it after
   `verify_ed25519_signature()` + `esp_ota_set_boot_partition()`, so it proves the
   image downloaded, verified and was written — but not that it *booted*.
   `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` means a bad image panics and the
   bootloader silently reverts to the old slot; the board comes back **online
   either way**. Only the terminal `success` (emitted by `ota_health_check_task`
   in `main.c`, after `CONNECT_GRACE_S` + `STABLE_REQUIRED_S` of uninterrupted
   Wi-Fi+MQTT) proves the new slot is the one running.

3. **The reported version is PROJECT_VER**, not `CONFIG_SHE_FIRMWARE_VERSION`.
   With a bare `project(she-firmware)` this is a git-describe string, so it will
   NOT equal the `--version` you send. That is expected; the device never compares
   them. Compare against the image's own `esp_app_desc_t` instead (offset 0x20,
   magic 0xabcd5432).

4. **The backend key is passphrase-protected.** `infra/ca/stack/she-backend.key`
   has `Proc-Type: 4,ENCRYPTED`, and `paho.tls_set()` has no password parameter —
   it falls through to OpenSSL's interactive `Enter PEM pass phrase:` and hangs.
   Hence the hand-built `SSLContext` below.

This bypasses the backend batch/approval API (`ota_batches`/`ota_approvals`) on
purpose. Drive `POST /homes/{id}/ota/batches` → `.../start` to test that path.

## Usage

    scripts/ota-e2e-test.py --mac 10061cae5328 --image firmware/v3/build/she-firmware.bin
    scripts/ota-e2e-test.py --mac <mac> --url http://192.168.1.21:8000/she-firmware.bin \\
        --sig <base64> --size 1596848

Host the image over plain HTTP first, e.g.:
    python -m http.server 8000 --bind 192.168.1.21 --directory firmware/v3/build
"""
import argparse
import json
import os
import socket
import ssl
import subprocess
import sys
import time

import paho.mqtt.client as mqtt

socket.setdefaulttimeout(10)   # a dead broker must never hang this script

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CA = os.path.join(REPO, "infra", "ca", "stack", "ca_bundle.pem")
CERT = os.path.join(REPO, "infra", "ca", "stack", "she-backend.crt")
KEY = os.path.join(REPO, "infra", "ca", "stack", "she-backend.key")
PASS_FILE = os.path.join(REPO, "infra", "ca", "step-ca-provisioner-password.txt")
SIGNER = os.path.join(REPO, "scripts", "sign-firmware.py")


def sign_image(image: str):
    """Return (base64_sig, size_bytes) using the project's own signer."""
    proc = subprocess.run(
        [sys.executable, SIGNER, image, "--json"],
        capture_output=True, text=True, cwd=REPO,
    )
    if proc.returncode != 0:
        sys.exit(f"sign-firmware.py failed (rc={proc.returncode}):\n{proc.stderr.strip()}")
    # --json pretty-prints the whole payload, so parse all of stdout.
    out = json.loads(proc.stdout)
    return out["sig"], out["size"]


def build_client(client_id: str) -> mqtt.Client:
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=client_id)
    except AttributeError:                      # paho-mqtt < 2.0
        client = mqtt.Client(client_id=client_id)

    if not os.path.exists(PASS_FILE):
        sys.exit(f"missing passphrase file: {PASS_FILE}")

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # The backend cert's CN is "she-backend" while we dial 127.0.0.1, so hostname
    # verification cannot pass; the broker ACL is what authorises us here.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.load_cert_chain(CERT, KEY, password=open(PASS_FILE, encoding="utf-8").read().strip())
    client.tls_set_context(ctx)
    return client


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mac", required=True, help="device MAC, lowercase hex, no colons")
    ap.add_argument("--tenant", default="00000000", help="first 8 hex of tenant uuid")
    ap.add_argument("--home", default="69b4294f", help="first 8 hex of home uuid")
    ap.add_argument("--room", default="unassigned")
    ap.add_argument("--image", help="local .bin — signed automatically")
    ap.add_argument("--url", help="image URL (skip if --image is given)")
    ap.add_argument("--sig", help="base64 Ed25519 signature (with --url)")
    ap.add_argument("--size", type=int, help="image size in bytes (with --url)")
    ap.add_argument("--version", default="0.0.0", help="version label sent in the payload")
    ap.add_argument("--secure-version", type=int, default=1)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8883)
    ap.add_argument("--window", type=int, default=600, help="seconds to wait for a terminal status")
    args = ap.parse_args()

    if args.image:
        sig, size = sign_image(args.image)
    elif args.url and args.sig and args.size:
        sig, size = args.sig, args.size
    else:
        ap.error("give --image, or all of --url/--sig/--size")

    base = f"she/{args.tenant}/{args.home}/{args.room}/{args.mac}"
    topic_url, topic_status = f"{base}/ota/url", f"{base}/ota/status"

    payload = json.dumps({
        "version": args.version,
        "url": args.url,
        "sig": sig,
        "size": size,
        "secure_version": args.secure_version,
    })

    state = {"subacked": False, "seen": []}
    t0 = time.time()

    def on_connect(c, u, flags, rc):
        print(f"[+0.0s] connect rc={rc}", flush=True)
        c.subscribe(topic_status, qos=1)

    def on_subscribe(c, u, mid, granted):
        state["subacked"] = True
        print(f"[+{time.time()-t0:6.1f}s] SUBACK {granted}", flush=True)

    def on_message(c, u, msg):
        text = msg.payload.decode("utf-8", "replace")
        print(f"[+{time.time()-t0:6.1f}s] RX {text}", flush=True)
        state["seen"].append((time.time() - t0, text))

    client = build_client(f"she-ota-e2e-{args.mac}")
    client.on_connect, client.on_subscribe, client.on_message = on_connect, on_subscribe, on_message
    client.connect(args.host, args.port, 30)
    client.loop_start()

    # Never let the trigger race the subscription.
    while not state["subacked"] and time.time() - t0 < 15:
        time.sleep(0.05)
    if not state["subacked"]:
        client.loop_stop()
        return 1

    info = client.publish(topic_url, payload, qos=1)
    info.wait_for_publish(timeout=10)
    print(f"[+{time.time()-t0:6.1f}s] PUBLISHED {topic_url} rc={info.rc} size={size}", flush=True)

    terminal = None
    while time.time() - t0 < args.window and terminal is None:
        time.sleep(0.5)
        for el, text in state["seen"]:
            try:
                if json.loads(text).get("status") in ("success", "failed"):
                    terminal = (el, text)
            except ValueError:
                pass

    client.loop_stop()
    client.disconnect()

    print("=" * 66)
    print(f"STATUS MESSAGES: {len(state['seen'])}")
    for el, text in state["seen"]:
        print(f"  +{el:6.1f}s  {text}")
    print("TERMINAL:", terminal[1] if terminal else "NONE OBSERVED")
    if terminal and '"success"' in terminal[1]:
        print("RESULT: OTA OK — new image booted and passed the health check")
        return 0
    print("RESULT: NOT CONFIRMED — no terminal success within the window")
    return 2


if __name__ == "__main__":
    sys.exit(main())
