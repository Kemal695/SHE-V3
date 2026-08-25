# V3 — MQTT Standards

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer

---

## 1. Overview

SHE V3 uses a single self-hosted EMQX cluster (3 nodes, mutual-TLS, HTTP auth/ACL backend — see `V3-ARCHITECTURE.md` §6) for all device communication. No third-party cloud broker. No RainMaker cloud.

The topic namespace is designed to:
1. Encode the full RainMaker hierarchy (Node → Device → Service → Parameter → Attribute) — see `V3-DEVICE-MODEL.md`
2. Allow per-device ACL enforcement on a single MAC-scoped subtree (cert CN = topic segment)
3. Support shared subscriptions for Spring Boot horizontal scaling
4. Distinguish retained shadow state (desired/reported) from real-time telemetry

---

## 2. Topic namespace

```
she/{tenant_id}/{home_id}/{room_id}/{node_mac}/{direction}[/{sub}]
```

| Segment | Format | Example | Notes |
|---|---|---|---|
| `tenant_id` | Short UUID (8 chars, base32) | `6f1c8a2b` | Maps to `tenants.id` (Postgres UUID, shortened for topic brevity) |
| `home_id` | Short UUID (8 chars, base32) | `9b2d4e7f` | Maps to `homes.id` |
| `room_id` | Short UUID (8 chars) or `unassigned` | `1c4e8a90` | `unassigned` until device is assigned a room |
| `node_mac` | Normalized MAC (lowercase, colons stripped) | `aabbccddeeff` | Must equal cert CN + ACL `clientid` |
| `direction` | One of the directions in §3 | `params/local` | Routing + QoS hint |
| `sub` (optional) | Direction-specific subtopic | `url`, `status`, `progress` (for `ota/`) | Only used by `ota/*` |

### 2.1 Worked example

A SHE-R8 device (MAC `24:6F:28:AA:BB:CC`, normalized `246f28aabbcc`) in home `9b2d4e7f`, room `1c4e8a90`, tenant `6f1c8a2b` publishes telemetry to:

```
she/6f1c8a2b/9b2d4e7f/1c4e8a90/246f28aabbcc/params/local
```

---

## 3. Directions + RainMaker hierarchy mapping

| Direction | QoS | Retained | Flow | RainMaker concept | Description |
|---|---|---|---|---|---|
| `config` | 1 | Yes | Device → Server (on connect) | Node self-description | Full node config: devices, params, services, attributes |
| `command` | 1 | No | Server → Device | Out-of-band Node command | Reboot, factory reset, ping, time-sync |
| `params/local` | 0 | No | Device → Server | Reported Parameter state | Telemetry — what the device is currently doing |
| `params/remote` | 1 | No (shadow is DB-backed) | Server → Device | Desired Parameter state | Command — what the user wants the device to do |
| `telemetry` | 0 | No | Device → Server | Service diagnostics | High-frequency diagnostics (RSSI, heap, uptime) |
| `status` | 1 | Yes (LWT) | Device → Server | Node presence | JSON `{"status":"online"}` / `{"status":"offline"}` (LWT for offline) |
| `energy` | 0 | No | Device → Server | PZEM energy meter | Voltage, current, power, energy_wh, pf, freq |
| `ota/url` | 1 | No | Server → Device | OTA Service: URL param | Trigger OTA (URL + signature + version) |
| `ota/status` | 1 | No | Device → Server | OTA Service: Status param | `downloading` / `flashing` / `complete` / `rolled_back` / `failed` |
| `ota/progress` | 0 | No | Device → Server | OTA Service: Progress param | 0-100 integer |

### 3.1 Mapping diagram (RainMaker → MQTT → Postgres)

```
RainMaker hierarchy                →   MQTT topic                                  →   Postgres table
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
Node (SHE-R8-246F28AABBCC)         →   she/.../246f28aabbcc/config  (retained)      →   nodes (1 row)
│                                                                                       - id, tenant_id, home_id, room_id
│                                                                                       - mac_address, sku, firmware_version
│                                                                                       - is_online (updated by /status)
│
├── Device "Relay 1"               →   config payload: devices[0]                  →   node_devices (1 row)
│   │                                                                                   - device_name = "Relay 1"
│   │                                                                                   - device_type = "esp.device.switch"
│   │                                                                                   - display_name = "Kitchen Light"
│   │                                                                                   - channel_index = 0
│   │
│   ├── Parameter: Power            →   params/local: {"Relay 1":{"Power":true}}    →   node_params (1 row)
│   │   (esp.param.power, bool)     →   params/remote: {"Relay 1":{"Power":true}}      - param_name = "Power"
│   │                                                                                   - last_value (JSONB) = true
│   │                                                                                   - last_reported_at, last_commanded_at
│   │
│   └── Attribute: Label            →   config payload: attributes.Label            →   node_devices.attributes (JSONB)
│                                                                                         e.g. {"Label":"Kitchen Light","Channel":"0"}
│
├── Service: OTA                   →   ota/url, ota/status, ota/progress           →   (no direct table — OTA state is in
│   ├── Parameter: URL                 (server→device, device→server)                   ota_batches + ota_jobs tables)
│   ├── Parameter: Status
│   └── Parameter: Progress
│
└── Service: Diagnostics           →   telemetry                                   →   device_telemetry (TimescaleDB hypertable)
    ├── Parameter: Uptime                                                                 - node_id, ts, key, value
    ├── Parameter: RSSI                                                                  - 30-day raw + 30-day compressed
    ├── Parameter: Free_Heap
    └── Parameter: Reset_Reason
```

---

## 4. QoS + retained matrix

| Topic | QoS | Retained | Justification |
|---|---|---|---|
| `.../config` | 1 | Yes | Must arrive + new subscribers (Spring Boot restart) get last config |
| `.../command` | 1 | No | Must arrive, but not retained (transient commands) |
| `.../params/local` | 0 | No | Frequent (5-10 s), missing one is fine; QoS 0 saves broker CPU |
| `.../params/remote` | 1 | No | Must arrive; shadow state is DB-backed (Spring Boot re-publishes on device reconnect) |
| `.../telemetry` | 0 | No | Frequent diagnostics; QoS 0 acceptable |
| `.../status` | 1 | Yes (LWT) | Must arrive + retained (new subscribers get online/offline immediately) |
| `.../energy` | 0 | No | Frequent (5 s); QoS 0; aggregated in TimescaleDB |
| `.../ota/url` | 1 | No | Must arrive — OTA commands are critical |
| `.../ota/status` | 1 | No | Must arrive — Admin Console tracks progress |
| `.../ota/progress` | 0 | No | Frequent (every 5% during download); QoS 0 |

### 4.1 Why `params/remote` is NOT retained

The "desired state" shadow is stored in Postgres (`node_params.last_value` after a user command). When a device reconnects:
1. Device subscribes to `params/remote`
2. Spring Boot detects reconnect via `status = "online"` message
3. Spring Boot re-publishes the current desired state from Postgres to `params/remote` (QoS 1, not retained)
4. Device reconciles physical state to desired state

This avoids the problem of stale retained messages on the broker (broker restart, expired shadow) and keeps Postgres as the single source of truth.

---

## 5. Device shadow pattern

V3 implements a lightweight device shadow (akin to AWS IoT Device Shadow, but simpler):

### 5.1 State stores

| Store | Location | Authoritative for |
|---|---|---|
| Desired state (what user wants) | Postgres `node_params.last_value` (after a command) | "Should be" |
| Reported state (what device says) | Postgres `node_params.last_value` (after telemetry) + TimescaleDB `device_telemetry` (history) | "Actually is" |
| Real-time reported | MQTT topic `params/local` (QoS 0, ephemeral) | Live UI updates |

### 5.2 Command flow (desired → reported reconciliation)

```
1. User taps "Kitchen Light ON" in Flutter app
2. Flutter → POST /api/v3/nodes/{nodeId}/devices/{deviceId}/params
     body: {"Power": true}
3. Spring Boot:
   a. UPDATE node_params SET last_value = true, last_commanded_at = NOW()
      WHERE node_device_id = ? AND param_name = 'Power'  (tenant-scoped via RLS)
   b. PUBLISH she/.../{mac}/params/remote  QoS 1
      payload: {"Relay 1":{"Power":true}, "seq": 12345}
4. EMQX routes to ESP32 (subscribed to its own /params/remote)
5. ESP32 toggles relay via PCF8574 (active-low)
6. ESP32 reads feedback circuit (optocoupler) — verifies contact closed
7. ESP32 PUBLISH she/.../{mac}/params/local  QoS 0
     payload: {"Relay 1":{"Power":true}}
8. Spring Boot (shared sub) UPDATE node_params SET last_value = true, last_reported_at = NOW()
9. Spring Boot WebSocket push  device.state  → Flutter
10. Flutter Bento card toggle animates to ON
```

### 5.3 Reconnect reconciliation

When a device reconnects after being offline:

```
1. ESP32 connects to EMQX (mTLS, with LWT set to status="offline")
2. ESP32 PUBLISH status = "online"  (QoS 1, retained)
3. ESP32 SUBSCRIBE she/.../{mac}/params/remote  (QoS 1)
4. Spring Boot receives status=online (shared sub)
5. Spring Boot queries Postgres for all params where last_commanded_at > last_reported_at
   → if any, re-publishes each to /params/remote
6. ESP32 compares physical state (feedback circuit) to received /params/remote
7. ESP32 reconciles: if physical != desired, toggle relay to match
8. ESP32 PUBLISH params/local with current state
9. Spring Boot updates last_reported_at
```

This closes the "command sent while device was offline" gap.

---

## 6. LWT handling for presence detection

Every device sets an LWT at MQTT CONNECT time:

| Property | Value |
|---|---|
| LWT topic | `she/{tenant_id}/{home_id}/{room_id}/{node_mac}/status` |
| LWT payload | `{"status":"offline"}` (JSON) |
| QoS | 1 |
| Retain | true |

### 6.1 Disconnect behavior

When the device disconnects unexpectedly (power loss, Wi-Fi drop, ESP32 crash):
1. EMQX detects connection loss (TCP keepalive timeout, default 60 s)
2. EMQX publishes the LWT to the status topic (QoS 1, retained)
3. Spring Boot (shared sub on `status`) receives `{"status":"offline"}`:
   - `UPDATE nodes SET is_online = false, last_seen_at = NOW() WHERE mac_address = ?`
   - WebSocket push `node.presence` event → Flutter app shows device as offline (dimmed Bento card)
   - If device was in middle of OTA: mark OTA job as `interrupted` (not failed — will retry on reconnect)

### 6.2 Connect behavior

When the device connects:
1. ESP32 publishes `{"status":"online"}` to status topic (QoS 1, retained) — this overwrites the LWT
2. Spring Boot receives `{"status":"online"}`:
   - `UPDATE nodes SET is_online = true, last_seen_at = NOW() WHERE mac_address = ?`
   - Trigger reconnect reconciliation (§5.3)
   - WebSocket push `node.presence` event → Flutter app shows device as online

### 6.3 LWT payload format

The status topic uses a JSON payload, not a plain string:

- Online:  `{"status":"online"}`
- Offline: `{"status":"offline"}`

**Spring Boot parses the JSON payload, not a plain string.** The presence handler deserializes the JSON envelope and reads the `status` field, then updates `nodes.is_online` accordingly. Using JSON keeps the status topic extensible (future fields like `reason`, `firmware_version`, `rssi` can be added without breaking the wire format) and consistent with the JSON payloads used on every other direction in §3.

Note: the LWT payload is set at CONNECT time and cannot reference runtime state, so it is the static `{"status":"offline"}` string baked into the firmware at build time — Spring Boot does not infer a disconnect timestamp from the LWT payload; the disconnect time is taken from the broker's PUBLISH event (i.e., when EMQX fires the LWT).

---

## 7. Shared subscriptions (Spring Boot horizontal scaling)

When Spring Boot runs as multiple instances (2+ in production, see `V3-ARCHITECTURE.md`), each instance must NOT receive every telemetry message (that would double-process). EMQX shared subscriptions solve this.

### 7.1 Shared subscription topic

Each Spring Boot instance subscribes to:

```
$share/she-backend/she/+/+/+/+/(telemetry|status|params/local|energy|ota/status|ota/progress)
```

| Token | Meaning |
|---|---|
| `$share/she-backend/` | Shared subscription group named `she-backend` |
| `she/+/+/+/+/` | Match any tenant, home, room, MAC (single-level wildcards) |
| `(telemetry\|status\|params/local\|energy\|ota/status\|ota/progress)` | Match any of these device→server directions |

EMQX distributes each message within the `she-backend` group — each message goes to exactly one Spring Boot instance.

### 7.2 Why not shared-subscribe everything?

These directions are NOT in the shared subscription (they're server→device, published by Spring Boot):

| Direction | Why not shared |
|---|---|
| `config` | Published by device (one publisher), but consumed by Spring Boot for shadow updates — actually this CAN be shared, but the message rate is so low (only on connect) that it doesn't matter. Spring Boot additionally subscribes non-shared to `config` to ensure no misses during instance restart. |
| `command` | Server → device — published BY Spring Boot, not subscribed |
| `params/remote` | Server → device — published BY Spring Boot |
| `ota/url` | Server → device — published BY Spring Boot |

### 7.3 Backend client IDs

| Client type | Client ID | Auth |
|---|---|---|
| Spring Boot instance 1 | `she-backend-1` | Client cert (mTLS) + explicit ACL — **no blanket ACL bypass** |
| Spring Boot instance 2 | `she-backend-2` | Client cert (mTLS) + explicit ACL — **no blanket ACL bypass** |
| Spring Boot instance N | `she-backend-N` | Client cert (mTLS) + explicit ACL — **no blanket ACL bypass** |
| ESP32 device | Normalized MAC (`246f28aabbcc`) | X.509 client cert (mutual TLS) |

Spring Boot connects to EMQX with a **client cert** (not username/password) and an **explicit ACL** listing allowed topics — there is **no blanket ACL bypass** and **no `is_superuser = true` flag**. The Spring Boot cert CN (`she-backend`) is mapped by EMQX to the following ACL (see `V3-CONFIGURATION.md` and `V3-SECURITY-MODEL.md` §6):

- **Subscribe:** `she/+/+/+/+/telemetry`, `she/+/+/+/+/status`, `she/+/+/+/+/params/local`, `she/+/+/+/+/energy`, `she/+/+/+/+/ota/status`
- **Publish:** `she/+/+/+/+/command`, `she/+/+/+/+/params/remote`, `she/+/+/+/+/ota/url`

Rationale: if the Spring Boot service account is ever compromised, the blast radius is bounded to the documented command/param/OTA-URL topic structure (auditable per-tenant) — it cannot, for example, publish arbitrary `config` or `telemetry` messages impersonating a device, nor subscribe to other tenants' `energy` streams.

---

## 8. Payload format examples (JSON)

### 8.1 `config` topic (retained, published on connect)

```json
{
  "node_id": "SHE-R8-246F28AABBCC",
  "mac": "24:6F:28:AA:BB:CC",
  "model": "SHE-R8",
  "hw_rev": "rev-c",
  "firmware": {
    "version": "1.4.2",
    "secure_version": 14,
    "compiled_at": "2024-09-15T10:23:00Z"
  },
  "devices": [
    {
      "name": "Relay 1",
      "type": "esp.device.switch",
      "params": [
        {"name": "Power", "type": "esp.param.power", "data_type": "bool",
         "properties": ["read","write","persist"], "value": false}
      ],
      "attributes": {"Label": "Kitchen Light", "Channel": "0"}
    },
    {
      "name": "Relay 2",
      "type": "esp.device.switch",
      "params": [
        {"name": "Power", "type": "esp.param.power", "data_type": "bool",
         "properties": ["read","write","persist"], "value": true}
      ],
      "attributes": {"Label": "Living Room Fan", "Channel": "1"}
    }
  ],
  "services": [
    {"name": "OTA", "type": "esp.service.ota",
     "params": [
       {"name": "URL", "type": "esp.param.ota_url", "data_type": "string", "properties": ["write"]},
       {"name": "Status", "type": "esp.param.ota_status", "data_type": "string", "properties": ["read"]},
       {"name": "Progress", "type": "esp.param.ota_progress", "data_type": "int", "properties": ["read"]}
     ]},
    {"name": "Diagnostics", "type": "esp.service.diag",
     "params": [
       {"name": "Uptime", "type": "esp.param.uptime", "data_type": "int", "properties": ["read"]},
       {"name": "RSSI", "type": "esp.param.rssi", "data_type": "int", "properties": ["read"]},
       {"name": "Free_Heap", "type": "esp.param.free_heap", "data_type": "int", "properties": ["read"]},
       {"name": "Reset_Reason", "type": "esp.param.reset_reason", "data_type": "string", "properties": ["read"]}
     ]}
  ],
  "published_at": "2024-10-22T14:23:11Z"
}
```

### 8.2 `command` topic (server → device, QoS 1, not retained)

```json
{
  "cmd": "reboot",
  "reason": "user_initiated",
  "seq": 8392,
  "ts": "2024-10-22T14:23:11Z"
}
```

Supported `cmd` values: `reboot`, `factory_reset` (clears NVS, requires re-provisioning), `sync_time`, `ping`.

### 8.3 `params/local` topic (device → server, QoS 0, every 5 s)

```json
{
  "Relay 1": {"Power": true},
  "Relay 2": {"Power": false},
  "Relay 3": {"Power": true},
  "Diagnostics": {
    "Uptime": 86432,
    "RSSI": -52,
    "Free_Heap": 142336,
    "Reset_Reason": "POWER_ON"
  }
}
```

### 8.4 `params/remote` topic (server → device, QoS 1, not retained)

```json
{
  "Relay 1": {"Power": true},
  "Relay 3": {"Power": false},
  "seq": 12345,
  "ts": "2024-10-22T14:23:11Z"
}
```

`seq` is a per-device monotonic counter (maintained by Spring Boot) used for replay-attack protection — device rejects messages with `seq` <= last-applied.

### 8.5 `telemetry` topic (device → server, QoS 0, every 30 s)

```json
{
  "uptime_s": 86432,
  "rssi_dbm": -52,
  "free_heap_bytes": 142336,
  "min_free_heap_bytes": 98032,
  "wifi_disconnects": 2,
  "mqtt_reconnects": 1,
  "reset_reason": "POWER_ON",
  "ts": "2024-10-22T14:23:11Z"
}
```

### 8.6 `status` topic (retained, JSON)

```
{"status":"online"}
```

or

```
{"status":"offline"}
```

(JSON payload — see §6.3. Spring Boot parses JSON, not plain string.)

### 8.7 `energy` topic (device → server, QoS 0, every 5 s)

```json
{
  "v": 220.5,
  "i": 1.21,
  "p": 267.0,
  "wh": 12345.6,
  "pf": 0.99,
  "freq": 50.0,
  "ts": "2024-10-22T14:23:11Z"
}
```

| Field | Unit | Range |
|---|---|---|
| `v` | volts (AC RMS) | 80-260 |
| `i` | amps (AC RMS) | 0-100 |
| `p` | watts (real power) | 0-22000 |
| `wh` | watt-hours (cumulative) | monotonic, wraps at 1e9 |
| `pf` | power factor | 0.0-1.0 |
| `freq` | Hz | 45-65 |

### 8.8 `ota/url` topic (server → device, QoS 1)

```json
{
  "version": "1.5.0",
  "secure_version": 15,
  "url": "https://minio.she.et/she-firmware/v1.5.0/SHE-R8.bin?presigned=...",
  "sig": "base64-ed25519-signature-of-sha256-of-image",
  "size": 1245184,
  "min_hw_rev": "rev-b",
  "seq": 8393,
  "ts": "2024-10-22T14:23:11Z"
}
```

### 8.9 `ota/status` topic (device → server, QoS 1)

```json
{
  "status": "downloading",
  "version": "1.5.0",
  "error": null,
  "ts": "2024-10-22T14:23:11Z"
}
```

`status` values: `downloading`, `verifying`, `flashing`, `rebooting`, `complete`, `rolled_back`, `failed`.
If `status = "failed"`, `error` contains a code from `V3-ERROR-CODES.md` (e.g., `OTA_SIG_INVALID`, `OTA_ROLLBACK_BLOCKED`, `OTA_DOWNLOAD_TIMEOUT`).

### 8.10 `ota/progress` topic (device → server, QoS 0)

```json
{
  "percent": 47,
  "bytes_done": 585236,
  "bytes_total": 1245184,
  "ts": "2024-10-22T14:23:11Z"
}
```

Published every 5% increment during download phase, every 1% during flash phase.

---

## 9. Per-device ACL rules

### 9.1 ACL enforcement

EMQX calls Spring Boot's `/internal/mqtt/acl` on every PUBLISH/SUBSCRIBE (see `V3-SECURITY-MODEL.md` §4.3). The ACL is per-device, derived from the cert CN (= device MAC).

### 9.2 ACL rules table

| Client (cert CN = MAC) | Topic pattern | Allowed actions |
|---|---|---|
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/config` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/command` | SUBSCRIBE |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/params/local` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/params/remote` | SUBSCRIBE |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/telemetry` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/status` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/energy` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/ota/url` | SUBSCRIBE |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/ota/status` | PUBLISH |
| Device `246f28aabbcc` | `she/+/+/+/246f28aabbcc/ota/progress` | PUBLISH |
| Spring Boot (`she-backend`) | `she/+/+/+/+/telemetry`, `she/+/+/+/+/status`, `she/+/+/+/+/params/local`, `she/+/+/+/+/energy`, `she/+/+/+/+/ota/status` | SUBSCRIBE |
| Spring Boot (`she-backend`) | `she/+/+/+/+/command`, `she/+/+/+/+/params/remote`, `she/+/+/+/+/ota/url` | PUBLISH |

### 9.3 Wildcard rules

The `+` wildcards in tenant_id, home_id, room_id positions allow the device to publish without knowing its own tenant_id (it knows its MAC from the cert CN, but tenant_id is assigned by Spring Boot during provisioning). The ACL still verifies that the tenant_id in the topic matches the device's actual tenant (looked up by MAC in `device_certs JOIN nodes`).

### 9.4 Forbidden patterns

| Pattern | Why forbidden |
|---|---|
| `she/+/+/+/+/+/+` (multi-level wildcard) | Devices cannot subscribe to other devices' topics |
| `she/+/+/+/{other_mac}/#` | Cross-device snooping |
| `she/#` | Catch-all — explicitly denied |
| `$SYS/#` | EMQX system topics — devices have no reason to subscribe |

---

## 10. Client ID + cert binding

### 10.1 Client ID format

| Client | Client ID | Format |
|---|---|---|
| ESP32 device | Normalized MAC (lowercase, no colons) | `246f28aabbcc` |
| Spring Boot instance | `she-backend-{N}` where N is the instance ID (1, 2, ...) | `she-backend-1` |

### 10.2 Cert CN binding

The device's X.509 certificate has `CN = normalized MAC` (e.g., `CN=246f28aabbcc`). EMQX extracts the CN from the client cert and passes it to Spring Boot's `/internal/mqtt/auth` endpoint.

Spring Boot verifies:
1. `clientid` (in CONNECT packet) == `cn` (in cert)
2. `cn` matches `device_certs.cn` for an ACTIVE cert
3. The cert's `fingerprint` (sha256 of DER) matches the stored fingerprint

If any check fails, the connection is rejected.

This means a stolen device cannot change its `clientid` to spoof another device — the cert CN is cryptographically bound to the cert, and the cert is cryptographically bound to the private key in NVS (Flash-encrypted).

### 10.3 Mutual-TLS, no username/password

Device connections use **mutual-TLS only** — no MQTT username/password. The `username` field in CONNECT is left empty. Authentication is entirely via the client cert.

Spring Boot backend connections also use **mutual-TLS** (client cert with CN `she-backend`) — not username/password. The cert CN is mapped to an explicit ACL (see §7.3 and §9.2) listing only the subscribe/publish topics required for the backend role. There is **no `is_superuser = true` flag** and **no blanket ACL bypass** — if the backend is compromised, it can only operate within the documented topic structure.

---

## 11. Provisioning topics (pre-cert)

During BLE provisioning, the device does NOT have an X.509 cert yet, so it cannot use mTLS to EMQX. Instead, it uses a temporary HTTPS-based provisioning protocol (see `V3-ARCHITECTURE.md` §4.4):

```
POST /api/v3/provisioning/claim        (HTTPS, not MQTT)
  body: { mac, claim_token, csr }
  resp: { cert_chain, ca_bundle }
```

The `claim_token` is a 10-minute single-use JWT generated by Spring Boot when the Flutter app requests "Add Device". The token is delivered to the Flutter app (over the existing authenticated HTTPS session) and then transferred to the device over BLE.

After provisioning, the device disconnects from BLE, opens MQTTS (mutual TLS) using the new cert, and never uses the provisioning endpoint again.

There is no MQTT-based "provisioning topic" — this avoids the security risk of a pre-auth MQTT channel.

---

## 12. Backward compatibility + versioning

### 12.1 Topic namespace versioning

The `she/` prefix is fixed for V3. If a future V4 needs an incompatible topic change (e.g., adding a `home_id` segment between `tenant_id` and `room_id` for sharded multi-tenant), V4 devices would use `she2/...` and both V3 + V4 brokers can run side-by-side during migration.

### 12.2 Payload versioning

Each payload includes a `ts` field (ISO 8601 timestamp). If a payload schema changes in a future firmware version, Spring Boot's deserializer keys off the firmware version (from `nodes.firmware_version` column) and applies the correct parser.

If a future firmware introduces a new parameter type (e.g., `esp.param.color_temp` for a future smart-bulb SKU), the existing `params/local` payload format supports it without schema change — the JSON object is keyed by device name, and each device's value object can include arbitrary parameter key/value pairs.

### 12.3 Config payload compatibility

The `config` payload (§8.1) is the device's self-description. Spring Boot parses it loosely:
- Unknown `device.type` values → logged as warning, device still registered, but UI shows "Unsupported device type"
- Unknown `param.type` values → UI shows as read-only string (no widget)
- Unknown `service.type` values → ignored (but logged)

This means firmware can add new device/param/service types without requiring a Spring Boot upgrade — the dynamic UI generation (see `V3-DEVICE-MODEL.md` §8) handles unknowns gracefully.

---

## 13. Reference table — quick lookup

| Question | Answer |
|---|---|
| What port do devices connect on? | 8883 (MQTTS, mutual-TLS) |
| What is the device client ID? | Normalized MAC, e.g., `246f28aabbcc` |
| What is the cert CN? | Same as client ID — normalized MAC |
| How often does a device publish telemetry? | `params/local` every 5 s; `telemetry` every 30 s; `energy` every 5 s |
| What is the LWT payload? | `{"status":"offline"}` (JSON) |
| What is the retained shadow topic? | `status` is retained; `params/remote` is NOT retained (shadow is DB-backed) |
| What is the shared subscription group? | `she-backend` |
| What is the QoS for command? | 1 (must arrive) |
| What is the QoS for energy? | 0 (frequent, missing one is fine) |
| What is the QoS for OTA URL? | 1 (must arrive) |
| Can a device subscribe to another device's topic? | No — ACL verifies topic MAC = clientid MAC |

---

## 14. References

- `V3-ARCHITECTURE.md` — EMQX cluster topology, HTTP auth/ACL backend configuration
- `V3-SECURITY-MODEL.md` — X.509 cert details, ACL enforcement, MQTT broker security
- `V3-DEVICE-MODEL.md` — RainMaker hierarchy (Node/Device/Service/Parameter/Attribute)
- `V3-DATABASE-DESIGN.md` — `nodes`, `node_devices`, `node_params`, `device_telemetry`, `energy_readings` tables
- `V3-API-SPECIFICATION.md` — REST endpoints that publish to MQTT (e.g., POST `/api/v3/nodes/.../params` → publishes to `params/remote`)
- `V3-ERROR-CODES.md` — OTA failure codes referenced in `ota/status` payload
- ADR-004 — cert-based MQTT authentication
