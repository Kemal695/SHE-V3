#!/usr/bin/env python
"""Publish synthetic telemetry for a SHE V3 node — no sensor hardware required.

Why this exists
---------------
The firmware does **not** publish a `telemetry` topic. `mqtt_publish_energy()` is called only
from `energy_monitor.c`, which runs on SHE-R8/R16 builds with a PZEM fitted. So on a bare
DevKit (or any board without the energy monitor) the backend's
`MqttSubscriberService.handleTelemetry()` has no producer at all, and `device_telemetry` stays
empty. The 60 s main loop publishes diagnostics through `params/local` instead.

This script stands in for that missing producer. It speaks the real protocol over real mTLS to
the real EMQX, so it exercises the genuine ingestion path:

    MQTT she/<tenant>/<home>/<room>/<mac>/telemetry
      -> MqttSubscriberService.handleTelemetry()
      -> EnergyService.insertTelemetry() -> device_telemetry (TimescaleDB hypertable)
      -> WebSocket node.telemetry
      -> GET /api/v3/nodes/{id}/telemetry

Payload is the FLAT diagnostics shape from V3-MQTT-STANDARDS §8.5 — not {ts, params:{...}}:

    {"uptime_s":N,"rssi_dbm":N,"free_heap_bytes":N,"min_free_heap_bytes":N,
     "wifi_disconnects":N,"mqtt_reconnects":N,"reset_reason":"POWER_ON","ts":<epoch>}

Values follow a gentle random walk so the resulting charts show a trend instead of a flat line.

Note on timestamps: the backend stamps each row with `Instant.now()` and ignores the payload's
`ts`, so you cannot backfill history over MQTT. Publish over real time (default: 10 samples at
3 s) — or insert rows directly if you only need a pretty chart.

Usage
-----
    python scripts/simulate-telemetry.py                    # 10 samples, 3 s apart
    python scripts/simulate-telemetry.py --count 40 --interval 5
    python scripts/simulate-telemetry.py --mac 10061cae5328
    python scripts/simulate-telemetry.py --with-energy      # also publish `energy`
    python scripts/simulate-telemetry.py --dry-run          # print topic/payload only

Requires paho-mqtt (use the venv interpreter, not the bare managed one) and `openssl` on PATH.
"""
import argparse
import json
import os
import random
import ssl
import subprocess
import sys
import tempfile
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    sys.exit("paho-mqtt is missing. Run with:\n"
             r"  C:\Users\kemal\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe")

ENV_PATH = r"D:\she-v3\backend\.env"


def load_env(path):
    """Parse .env literally — never `source` it (JSON values get mangled by bash)."""
    cfg = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            cfg[key.strip()] = val.strip().strip('"').strip("'")
    return cfg


def psql(sql):
    """Query the DB as the RLS-bypassing superuser (the app role would hide rows)."""
    out = subprocess.run(
        ["docker", "exec", "she-postgres", "psql", "-U", "she_superuser",
         "-d", "she_v3", "-t", "-A", "-F", "|", "-c", sql],
        capture_output=True, text=True, check=True,
    )
    return [ln for ln in out.stdout.strip().splitlines() if ln]


def resolve_topic_prefix(mac):
    """Derive she/<tenant>/<home>/<room>/<mac> exactly as NodeServiceImpl.shortId() does.

    shortId() = first 8 hex chars of the UUID with dashes removed.
    """
    rows = psql(
        "SELECT substring(replace(tenant_id::text,'-',''),1,8), "
        "       coalesce(substring(replace(home_id::text,'-',''),1,8),'00000000'), "
        "       normalized_mac "
        "FROM nodes WHERE deleted_at IS NULL "
        + (f"AND normalized_mac='{mac}' " if mac else "")
        + "ORDER BY last_seen_at DESC NULLS LAST LIMIT 1;"
    )
    if not rows:
        sys.exit(f"No live node found{f' for mac {mac}' if mac else ''} in the DB.")
    tenant, home, node_mac = rows[0].split("|")
    # room_id is null on this deployment, which the backend renders as "unassigned"
    return f"she/{tenant}/{home}/unassigned/{node_mac}", node_mac


def decrypt_client_key(cfg, tmp_key):
    """The backend key is encrypted; paho's tls_set() cannot take a password."""
    subprocess.run(
        ["openssl", "pkey", "-in", cfg["MQTT_BACKEND_KEY"],
         "-passin", "pass:" + cfg["MQTT_KEY_PASSWORD"], "-out", tmp_key],
        check=True, capture_output=True,
    )
    return tmp_key


def make_client(cfg, tmp_key):
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1,
                             client_id="she-telemetry-sim", protocol=mqtt.MQTTv311)
    except AttributeError:      # older paho
        client = mqtt.Client(client_id="she-telemetry-sim", protocol=mqtt.MQTTv311)
    client.tls_set(ca_certs=cfg["MQTT_CA_BUNDLE"],
                   certfile=cfg["MQTT_BACKEND_CERT"],
                   keyfile=tmp_key,
                   tls_version=ssl.PROTOCOL_TLS_CLIENT)
    return client


def main():
    ap = argparse.ArgumentParser(description="Publish synthetic SHE V3 telemetry over MQTT.")
    ap.add_argument("--mac", help="normalized MAC (12 hex chars); default = most recently seen node")
    ap.add_argument("--count", type=int, default=10, help="number of samples (default 10)")
    ap.add_argument("--interval", type=float, default=3.0, help="seconds between samples (default 3)")
    ap.add_argument("--with-energy", action="store_true", help="also publish the `energy` topic")
    ap.add_argument("--dry-run", action="store_true", help="print topic + payload, publish nothing")
    args = ap.parse_args()

    prefix, mac = resolve_topic_prefix(args.mac)
    tele_topic = f"{prefix}/telemetry"
    energy_topic = f"{prefix}/energy"
    print(f"node mac : {mac}")
    print(f"telemetry: {tele_topic}")
    if args.with_energy:
        print(f"energy   : {energy_topic}")

    cfg = load_env(ENV_PATH)
    client = None
    tmp_key = os.path.join(tempfile.gettempdir(), "_she_sim_dec.key")

    if not args.dry_run:
        decrypt_client_key(cfg, tmp_key)
        client = make_client(cfg, tmp_key)
        client.connect("localhost", 8883, 30)
        client.loop_start()
        time.sleep(1.0)

    # Random-walk state so successive samples look like a real device.
    uptime = 86432
    rssi = -52.0
    heap = 142336.0
    min_heap = 98032.0
    wh = 1000.0

    sent = 0
    try:
        for i in range(args.count):
            uptime += args.interval
            rssi = max(-90.0, min(-30.0, rssi + random.uniform(-3, 3)))
            heap = max(60000.0, min(200000.0, heap + random.uniform(-2500, 2500)))
            min_heap = min(min_heap, heap)

            telemetry = {
                "uptime_s": int(uptime),
                "rssi_dbm": round(rssi),
                "free_heap_bytes": int(heap),
                "min_free_heap_bytes": int(min_heap),
                "wifi_disconnects": 2,
                "mqtt_reconnects": 1,
                "reset_reason": "POWER_ON",
                "ts": int(time.time()),
            }
            if args.dry_run:
                print(f"\n[{i + 1}/{args.count}] {tele_topic}\n  {json.dumps(telemetry)}")
            else:
                info = client.publish(tele_topic, json.dumps(telemetry), qos=1)
                info.wait_for_publish(timeout=10)
                print(f"[{i + 1}/{args.count}] telemetry rc={info.rc} uptime={int(uptime)} "
                      f"rssi={round(rssi)} heap={int(heap)}")

            if args.with_energy:
                wh += random.uniform(8, 20)
                energy = {"v": round(231.0 + random.uniform(-2, 2), 1),
                          "i": round(0.5 + random.uniform(-0.08, 0.08), 2),
                          "p": round(120.0 + random.uniform(-8, 8), 1),
                          "wh": round(wh, 2), "pf": 0.98, "freq": 50.0}
                if args.dry_run:
                    print(f"            {energy_topic}\n  {json.dumps(energy)}")
                else:
                    info = client.publish(energy_topic, json.dumps(energy), qos=0)
                    info.wait_for_publish(timeout=10)

            sent += 1
            if i < args.count - 1:
                time.sleep(args.interval)
    finally:
        if client is not None:
            client.loop_stop()
            client.disconnect()
        if os.path.exists(tmp_key):
            os.remove(tmp_key)

    if args.dry_run:
        print(f"\ndry run — would have published {sent} telemetry samples")
        return

    # Give the backend a moment to ingest before reporting.
    time.sleep(3)
    rows = psql(f"SELECT param_name, count(*) FROM device_telemetry t "
                f"JOIN nodes n ON n.id=t.node_id WHERE n.normalized_mac='{mac}' "
                f"GROUP BY param_name ORDER BY param_name;")
    print(f"\npublished {sent} samples. device_telemetry rows for {mac}:")
    for row in rows:
        print("  " + row.replace("|", " = "))
    print(f"\nRead it back with: GET /api/v3/nodes/{{node_id}}/telemetry?from=...&to=...&bucket=5m")


if __name__ == "__main__":
    main()
