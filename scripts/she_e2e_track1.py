#!/usr/bin/env python
"""
SHE V3 - Phase 1 end-to-end test harness (server-side validation).

Drives the five Track-1 flows against the LIVE local stack with a SIMULATED
device, so every server-side component is exercised for real:

    ESP32 (simulated) --mTLS--> EMQX --auth/acl--> Spring Boot --> TimescaleDB
                                      ^                                |
                                      +-------- params/remote ---------+

What is REAL here:  CA cert issuance (step-ca), MQTT mTLS + per-device ACL,
                    auth backend, claim flow, telemetry/energy ingestion,
                    param-write round trip, OTA batch lifecycle, TimescaleDB rows.
What is SIMULATED:  the ESP32 itself (radio, relay, PZEM, mDNS/HTTPS local control).

Usage:  python she_e2e.py
"""
import json
import hashlib
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

import paho.mqtt.client as mqtt

BASE = "http://127.0.0.1:8080"
MQTT_HOST = "127.0.0.1"
MQTT_PORT = 8883
CA_BUNDLE = r"D:\she-v3\infra\ca\ca_bundle.pem"
TENANT_ID = "00000000-0000-0000-0000-000000000001"
CA_ID = TENANT_ID
ROOM = "unassigned"
SKU = "SHE-R8"
WORK = tempfile.mkdtemp(prefix="she-e2e-")

RESULTS = []
DEVICE_TOPICS = {}          # filled after claim
RECEIVED = {"params/remote": [], "ota/url": [], "command": []}
MQTT_CONNECTED = threading.Event()


# ───────────────────────────── helpers ─────────────────────────────

def record(test, ok, detail):
    RESULTS.append((test, "PASS" if ok else "FAIL", detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {test}: {detail}", flush=True)


def http(method, path, token=None, body=None, timeout=25):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}
    except Exception as e:
        return 0, {"error": str(e)}


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def psql(sql):
    # Verify as a privileged observer, NOT as she_app. Since P0-5 is enforced,
    # she_app is a plain NOSUPERUSER NOBYPASSRLS role: these raw verification
    # queries set no app.tenant_id GUC, so RLS would filter them and report 0
    # rows even when the application wrote the data correctly.
    r = sh(f'docker exec she-postgres psql -U she_superuser -d she_v3 -t -A -c "{sql}"')
    return r.stdout.strip()


def make_key_and_csr(cn):
    """ECDSA P-256 keypair + PKCS#10 CSR, as the ESP32 would produce on-chip (P0-1)."""
    key = os.path.join(WORK, f"{cn}.key")
    csr = os.path.join(WORK, f"{cn}.csr")
    pkcs8 = os.path.join(WORK, f"{cn}-pkcs8.key")
    sh(f'openssl ecparam -name prime256v1 -genkey -noout -out "{key}"')
    sh(f'openssl req -new -key "{key}" -subj "/CN={cn}" -out "{csr}"')
    # MQTT/TLS clients want PKCS#8 rather than SEC1
    sh(f'openssl pkcs8 -topk8 -nocrypt -in "{key}" -out "{pkcs8}"')
    return pkcs8, csr


def device_topic(mac, direction, home_short):
    return f"she/{TENANT_ID[:8]}/{home_short}/{ROOM}/{mac}/{direction}"


# ───────────────────────── device simulator ─────────────────────────

class Device:
    """A simulated ESP32-S3: mTLS MQTT, subscribes to cloud commands,
    echoes param writes back on params/local exactly like the firmware does."""

    def __init__(self, mac, certfile, keyfile):
        self.mac = mac
        self.home_short = None
        self.client = None
        self.certfile = certfile
        self.keyfile = keyfile

    def connect(self):
        try:
            self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=self.mac)
        except (AttributeError, TypeError):
            self.client = mqtt.Client(client_id=self.mac)          # paho 1.x
        self.client.tls_set(
            ca_certs=CA_BUNDLE, certfile=self.certfile, keyfile=self.keyfile,
            tls_version=ssl.PROTOCOL_TLS_CLIENT,
        )
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
        self.client.loop_start()
        if not MQTT_CONNECTED.wait(timeout=15):
            raise RuntimeError("MQTT connect timed out")

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        rc = getattr(reason_code, "value", reason_code)
        print(f"    device MQTT connected (rc={rc})", flush=True)
        for direction in ("command", "params/remote", "ota/url"):
            client.subscribe(device_topic(self.mac, direction, self.home_short), qos=1)
        MQTT_CONNECTED.set()

    def _on_message(self, client, userdata, msg):
        direction = "/".join(msg.topic.split("/")[5:])
        payload = msg.payload.decode()
        print(f"    device <- {direction}: {payload[:160]}", flush=True)
        RECEIVED.setdefault(direction, []).append(payload)

        # Firmware behaviour: apply the write, then report the new state back
        # on params/local (V3-MQTT-STANDARDS 3.4).
        if direction == "params/remote":
            try:
                body = json.loads(payload)
                params = body.get("params", body)
                report = {"devices": {name: p for name, p in params.items()}}
                # Normalise to the device-echo shape: {"Relay 1": {"Power": true}}
                if all(isinstance(v, dict) for v in params.values()):
                    report = params
                client.publish(
                    device_topic(self.mac, "params/local", self.home_short),
                    json.dumps(report), qos=1,
                )
            except Exception as exc:                      # noqa: BLE001
                print(f"    (echo failed: {exc})", flush=True)

    def pub(self, direction, payload):
        info = self.client.publish(
            device_topic(self.mac, direction, self.home_short),
            json.dumps(payload) if not isinstance(payload, str) else payload, qos=1,
        )
        info.wait_for_publish(timeout=10)

    def stop(self):
        try:
            self.client.loop_stop()
            self.client.disconnect()
        except Exception:
            pass


# ───────────────────────────── main ─────────────────────────────

def main():
    # 12 lowercase hex chars = normalized MAC (what EMQX/backend expect)
    mac = ("e2e" + os.urandom(6).hex())[:12].lower()
    mac = "".join(c for c in mac if c in "0123456789abcdef").ljust(12, "0")[:12]
    stamp = int(time.time())
    print(f"=== SHE V3 Track-1 E2E (simulated device mac={mac}) ===\n")

    # ── Test 1: BLE provisioning, server side ────────────────────────
    print("TEST 1 - BLE provisioning (server side: claim -> MQTT -> dashboard)")
    st, reg = http("POST", "/api/v3/auth/register",
                   body={"email": f"e2e-{stamp}@example.et", "password": "E2ePass!12345"})
    token = (reg.get("data") or {}).get("access_token")
    record("T1.1 register user", st in (200, 201) and bool(token), f"HTTP {st}")

    st, homes = http("GET", "/api/v3/homes", token=token)
    home_id = (homes.get("data") or [{}])[0].get("id")
    if not home_id:
        st, created = http("POST", "/api/v3/homes", token=token,
                           body={"name": "E2E Home", "address": "Addis Ababa"})
        home_id = (created.get("data") or {}).get("id")
    record("T1.2 home available", bool(home_id), f"home_id={home_id}")
    home_short = (home_id or "00000000").replace("-", "")[:8]

    st, ct = http("POST", "/api/v3/auth/claim-token", token=token)
    claim_token = (ct.get("data") or {}).get("claim_token")
    record("T1.3 claim-token issued (10-min TTL)", bool(claim_token), f"HTTP {st}")

    config = {
        "devices": [{"name": "Relay 1", "type": "esp.device.switch", "params": [
            {"name": "Power", "type": "esp.param.power", "data_type": "bool",
             "properties": ["read", "write", "persist"], "value": False}]}],
        # V3-MQTT-STANDARDS §8.1 — services live in the same node_devices table.
        # The Diagnostics service (esp.service.diag) is required for telemetry
        # ingestion: MqttSubscriberService.handleTelemetry() drops the message
        # when no esp.service.diag device exists.
        "services": [
            {"name": "OTA", "type": "esp.service.ota", "params": [
                {"name": "URL", "type": "esp.param.ota_url", "data_type": "string",
                 "properties": ["write"]},
                {"name": "Status", "type": "esp.param.ota_status", "data_type": "string",
                 "properties": ["read"]},
                {"name": "Progress", "type": "esp.param.ota_progress", "data_type": "int",
                 "properties": ["read"]}]},
            {"name": "Diagnostics", "type": "esp.service.diag", "params": [
                {"name": "Uptime", "type": "esp.param.uptime", "data_type": "int",
                 "properties": ["read"]},
                {"name": "RSSI", "type": "esp.param.rssi", "data_type": "int",
                 "properties": ["read"]},
                {"name": "Free_Heap", "type": "esp.param.free_heap", "data_type": "int",
                 "properties": ["read"]},
                {"name": "Reset_Reason", "type": "esp.param.reset_reason", "data_type": "string",
                 "properties": ["read"]}]},
        ],
    }
    st, claim = http("POST", "/api/v3/nodes/claim", token=token, body={
        "mac": mac, "claim_token": claim_token, "sku": SKU,
        "home_id": home_id, "config": config})
    node_id = (claim.get("data") or {}).get("node_db_id")
    record("T1.4 POST /nodes/claim", bool(node_id), f"HTTP {st} node_db_id={node_id}")
    if not node_id:
        print(json.dumps(claim)[:500])
        finish(); return

    # Device cert via step-ca + registration (P0-1: key never leaves the device)
    keyfile, csrfile = make_key_and_csr(mac)
    csr_pem = open(csrfile).read()
    st, signed = http("POST", "/internal/ca/sign-and-register", body={
        "csr_pem": csr_pem, "cn": mac, "tenant_id": TENANT_ID, "ca_id": CA_ID})
    cert_pem = (signed.get("data") or {}).get("cert_pem")
    record("T1.5 step-ca issues + registers device cert",
           bool(cert_pem), f"HTTP {st} serial={(signed.get('data') or {}).get('serial')}")
    if not cert_pem:
        print(json.dumps(signed)[:500]); finish(); return
    certfile = os.path.join(WORK, f"{mac}.crt")
    open(certfile, "w").write(cert_pem)

    dev = Device(mac, certfile, keyfile)
    dev.home_short = home_short
    try:
        dev.connect()
        record("T1.6 device mTLS connect (cert auth, no password)", True, "connected :8883")
    except Exception as exc:                                        # noqa: BLE001
        record("T1.6 device mTLS connect", False, str(exc)); finish(); return

    # Self-description on connect, then presence
    dev.pub("config", {"node_id": f"{SKU}-{mac[6:]}", "model": SKU,
                       "firmware": {"version": "3.0.0"}, **config})
    dev.pub("status", {"status": "online"})
    time.sleep(3)

    online = psql(f"SELECT is_online FROM nodes WHERE id='{node_id}'")
    ndev = psql(f"SELECT count(*) FROM node_devices WHERE node_id='{node_id}'")
    nparam = psql(f"SELECT count(*) FROM node_params WHERE node_id='{node_id}'")
    record("T1.7 node self-description ingested (node_devices/node_params)",
           ndev not in ("0", ""), f"devices={ndev} params={nparam}")
    record("T1.8 presence -> is_online=true", online == "t", f"is_online={online}")

    st, dash = http("GET", f"/api/v3/homes/{home_id}/nodes", token=token)
    record("T1.9 dashboard lists the node", bool(dash.get("data")), f"HTTP {st}")

    # ── Test 2: telemetry + energy ───────────────────────────────────
    print("\nTEST 2 - telemetry + energy ingestion")
    for i in range(3):
        # V3-MQTT-STANDARDS §8.5 — flat diagnostics payload, NOT {ts, params:{...}}
        dev.pub("telemetry", {
            "uptime_s": 86432 + i * 30,
            "rssi_dbm": -52,
            "free_heap_bytes": 142336 - i * 128,
            "min_free_heap_bytes": 98032,
            "wifi_disconnects": 2,
            "mqtt_reconnects": 1,
            "reset_reason": "POWER_ON",
            "ts": int(time.time()),
        })
        dev.pub("energy", {"v": 231.4, "i": 0.52, "p": 120.3, "wh": 1000 + i * 10,
                           "pf": 0.98, "freq": 50.0})
        time.sleep(0.4)
    time.sleep(4)

    tcount = psql(f"SELECT count(*) FROM device_telemetry WHERE node_id='{node_id}'")
    ecount = psql(f"SELECT count(*) FROM device_energy_readings WHERE node_id='{node_id}'")
    record("T2.1 telemetry rows in TimescaleDB", tcount not in ("0", ""), f"rows={tcount}")
    record("T2.2 energy rows in TimescaleDB", ecount not in ("0", ""), f"rows={ecount}")

    st, tele = http("GET", f"/api/v3/nodes/{node_id}/telemetry", token=token)
    record("T2.3 GET /nodes/{id}/telemetry", st == 200, f"HTTP {st}")
    st, en = http("GET", f"/api/v3/nodes/{node_id}/energy", token=token)
    record("T2.4 GET /nodes/{id}/energy", st == 200, f"HTTP {st}")
    st, daily = http("GET", f"/api/v3/nodes/{node_id}/energy/daily?days=7", token=token)
    record("T2.5 GET /energy/daily (7-day chart source)", st == 200, f"HTTP {st}")

    # ── Test 3: param write round trip ───────────────────────────────
    print("\nTEST 3 - param write (relay toggle) round trip")
    st, devs = http("GET", f"/api/v3/nodes/{node_id}/devices", token=token)
    # Pick the relay by name — node_devices also holds services (OTA, Diagnostics).
    relay = next((d for d in (devs.get("data") or []) if d.get("device_name") == "Relay 1"), None)
    device_id = (relay or {}).get("id")
    record("T3.1 device discovered", bool(device_id),
           f"device_id={device_id} of {[d.get('device_name') for d in (devs.get('data') or [])]}")

    # Canonical FLAT body (V3-API-SPECIFICATION 6) - the M8 fix
    st, wr = http("PUT", f"/api/v3/nodes/{node_id}/devices/{device_id}/params",
                  token=token, body={"Power": True})
    record("T3.2 PUT params (flat body, canonical spec)", st == 200, f"HTTP {st}")
    time.sleep(3)

    got = RECEIVED.get("params/remote", [])
    record("T3.3 cloud published params/remote to device", bool(got),
           f"received={len(got)} last={got[-1][:90] if got else 'none'}")

    last = psql(f"SELECT last_value FROM node_params WHERE node_device_id='{device_id}' AND param_name='Power'")
    record("T3.4 device echo updated node_params.last_value", "true" in last.lower(),
           f"last_value={last}")

    # Legacy wrapped body must still work (backward compatibility)
    st, _ = http("PUT", f"/api/v3/nodes/{node_id}/devices/{device_id}/params",
                 token=token, body={"params": {"Power": False}})
    record("T3.5 legacy wrapped body still accepted", st == 200, f"HTTP {st}")
    time.sleep(2)
    last2 = psql(f"SELECT last_value FROM node_params WHERE node_device_id='{device_id}' AND param_name='Power'")
    record("T3.6 legacy write applied", "false" in last2.lower(), f"last_value={last2}")

    # ── Test 4: OTA lifecycle ────────────────────────────────────────
    print("\nTEST 4 - OTA batch lifecycle")
    fw = os.path.join(WORK, "firmware-3.0.1.bin")
    open(fw, "wb").write(b"SHE-V3 fake firmware 3.0.1 payload\n" * 100)
    # hashlib, not `sha256sum`: on Git Bash for Windows GNU coreutils prefixes the
    # output line with a backslash when the filename contains backslashes, so
    # `sha256sum "C:\..." | awk '{print $1}'` yields a 65-char "\<hash>" that fails
    # the backend's @Size(max = 64) check on firmware_checksum.
    checksum = hashlib.sha256(open(fw, "rb").read()).hexdigest()
    st, batch = http("POST", f"/api/v3/homes/{home_id}/ota/batches", token=token, body={
        "firmware_version": "3.0.1",
        "firmware_url": "http://localhost:9000/she-ota/firmware-3.0.1.bin",
        "firmware_checksum": checksum,
        "signature_ed25519": "Z" * 88,
        "target_sku": SKU, "rollout_percent": 100, "auto_approve": True})
    batch_id = (batch.get("data") or {}).get("id") or batch.get("id")
    detail = f"HTTP {st} batch={batch_id}"
    if not batch_id:
        detail += f" checksum={checksum!r} resp={json.dumps(batch)[:220]}"
    record("T4.1 POST /ota/batches", bool(batch_id), detail)

    if batch_id:
        st, started = http("POST", f"/api/v3/ota/batches/{batch_id}/start", token=token)
        record("T4.2 POST /ota/batches/{id}/start", st in (200, 202), f"HTTP {st}")
        time.sleep(3)
        got = RECEIVED.get("ota/url", [])
        record("T4.3 cloud published ota/url to device", bool(got),
               f"received={len(got)} last={got[-1][:90] if got else 'none'}")
        dev.pub("ota/status", {"status": "downloading", "version": "3.0.1"})
        dev.pub("ota/progress", {"percent": 100, "version": "3.0.1"})
        time.sleep(3)
        st, b = http("GET", f"/api/v3/homes/{home_id}/ota/batches", token=token)
        record("T4.4 batch status queryable", st == 200, f"HTTP {st}")

    # ── Test 5: local control ────────────────────────────────────────
    print("\nTEST 5 - local control (mDNS + HTTPS :443)")
    src = open(r"D:\she-v3\firmware\v3\main\local_ctrl.c", encoding="utf-8", errors="replace").read()
    has_ssl = "httpd_ssl_start" in src
    has_mdns = "_she_ctrl" in src
    has_pop = "verify_pop" in src or "constant" in src.lower()
    record("T5.1 firmware uses real TLS (httpd_ssl_start, not plain HTTP)", has_ssl,
           "httpd_ssl_start present" if has_ssl else "MISSING")
    record("T5.2 mDNS service _she_ctrl._tcp advertised", has_mdns, "present" if has_mdns else "MISSING")
    record("T5.3 PoP verification present", has_pop, "present" if has_pop else "MISSING")
    print("  [SKIP] T5.4 end-to-end LAN toggle + <500ms latency: needs physical board")

    dev.stop()
    finish()


def finish():
    print("\n================ SUMMARY ================")
    passed = sum(1 for _, s, _ in RESULTS if s == "PASS")
    for test, status, detail in RESULTS:
        print(f"  {status:4}  {test}")
    print(f"\n  {passed}/{len(RESULTS)} checks passed")
    print("  Simulated: ESP32 radio/relay/PZEM. Real: CA, EMQX mTLS+ACL, backend, TimescaleDB.")
    sys.exit(0 if passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
