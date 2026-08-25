# V3 — Architecture

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer

---

## 1. Purpose

This document defines the production architecture of the SHE V3 platform — a fully self-hosted IoT stack hosted in Addis Ababa (Ethio Telecom Cloud). It supersedes the earlier draft which (a) quoted Hetzner-grade VPS pricing (~$415/month) that does not reflect Ethiopian hosting reality, (b) stated the role count as 8 in two places (correct value: 10), and (c) omitted TimescaleDB compression policy details.

All hardware assumptions are defined in `V3-HARDWARE.md` (SHE-R4 = ESP32-C3, SHE-R8 / SHE-R16 = ESP32-S3). The device data model is defined in `V3-DEVICE-MODEL.md` (RainMaker hierarchy: Node → Device → Service → Parameter → Attribute — adopted as a conceptual model only; the cloud is fully self-hosted, no RainMaker cloud dependency).

---

## 2. Component overview

| Layer | Technology | Notes |
|---|---|---|
| Edge (ESP32) | ESP-IDF v5.1 / C on ESP32-C3 (R4) + ESP32-S3 (R8/R16) | BLE provisioning, mTLS MQTT, OTA, local control, PZEM energy, Picovoice voice (R16 only) |
| Messaging | EMQX 5.x (3-node cluster) | MQTTS port 8883 only, mutual-TLS, HTTP auth/ACL backend → Spring Boot |
| Application | Spring Boot 3.x / Java 21 (LTS) | 2+ instances, horizontal scaling via shared MQTT subscriptions |
| Relational data | PostgreSQL 16 + Row-Level Security | Multi-tenant isolation at the DB layer (ADR-003) |
| Time-series data | TimescaleDB 2.x (Postgres extension) | Energy + telemetry hypertables, segment-by + interval compression policy |
| Object storage | MinIO (single-node EC:4 in V3, expandable) | OTA firmware images, B2B white-label assets |
| Cache | Redis 7 (3-node sentinel cluster) | Sessions, JWT jti blacklist, RBAC cache, rate-limit counters, non-payment idempotency keys (payment idempotency is Postgres — see §5.3) |
| Mobile app | Flutter 3.22+ / Riverpod | Premium dark-mode Bento UI, BLE provisioning, offline cache |
| Admin web | Next.js 16 / React 19 / shadcn/ui | Platform + tenant admin consoles, ~9 screens |
| Edge / DDoS | Cloudflare Business | TLS termination, WAF, rate-limit, geo-block with explicit exceptions |
| Reverse proxy | Nginx 1.26 | `/api/*` → Spring Boot, `/ws/*` → WebSocket, `/admin/*` → Next.js, static assets |
| Payments | Chapa aggregator | Telebirr + CBE Birr + cards (no direct bank integration in V3 GA) |
| Voice | Picovoice (offline) | "Hey Sheba" wake word, Amharic + English intents on SHE-R16 |
| Hosting | Ethio Telecom Cloud (Addis Ababa, single-region) | PDPP data residency compliance (ADR-008) |
| CI/CD | GitHub Actions | Build → test → push image → deploy to staging; manual promote to prod |
| Monitoring | Prometheus + Grafana + Loki + Alertmanager | Metrics, structured logs, on-call alerting via PagerDuty (P1-29) |

---

## 3. System architecture diagram

```
========================================================================================
                    SMART HOME ETHIOPIA (SHE) V3 PLATFORM
                 Self-Hosted in Addis Ababa (Ethio Telecom Cloud)
========================================================================================

[ EXTERNAL NETWORK / INTERNET ]
     │
     │ HTTPS :443   WSS :443/ws   MQTTS :8883 (devices only)
     │
     ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              CLOUDFLARE (Business)                                   │
│  TLS 1.3 termination | DDoS | WAF | Rate limit | Bot mitigation                      │
│  Geo-block: ET only (+ whitelisted Chapa / FCM / APNs egress IPs — see §10)          │
└─────────────┬────────────────────────────────────────────────────────────────────────┘
              │ Origin pull over private fiber (no public origin exposure)
              ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                                       NGINX 1.26                                     │
│  /api/v3/*      → Spring Boot (round-robin upstream)                                 │
│  /ws/v3/*       → Spring Boot WebSocket (sticky by Sec-WebSocket-Protocol)           │
│  /admin/*       → Next.js admin app                                                  │
│  /static/*      → Nginx local (cache immutable assets 30d)                           │
└─────────────┬────────────────────────────────────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                          SPRING BOOT 3.x  (2+ instances)                              │
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐  │
│  │  SECURITY:  JWT (EdDSA/Ed25519, kid rotation) | RBAC (10 roles) | MFA (TOTP) | RLS | Audit          │  │
│  └────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                      │
│  ┌──────────────────────────┐   ┌──────────────────────────────────────────────────┐│
│  │  REST API  /api/v3/*     │   │  WebSocket  /ws/v3/*                             ││
│  │  auth home device auto   │   │  device.state   automation.triggered             ││
│  │  scene ota energy voice  │   │  notification.received   ota.status              ││
│  │  matter payment tenant   │   │  energy.update                                    ││
│  └──────────┬───────────────┘   └────────────────────┬─────────────────────────────┘│
│  ┌──────────┴────────────────────────────────────────┴─────────────────────────────┐│
│  │  SERVICE LAYER                                                                   ││
│  │  MultiTenantHomeService | EnergyService | VoiceService | MatterService           ││
│  │  PaymentService (Chapa) | WhiteLabelService | OTAService | MqttAuthService       ││
│  └──────┬───────────────────────────────────────────────────────┬───────────────────┘│
│  ┌──────┴──────────────────────┐    ┌───────────────────────────┴─────────────────┐│
│  │  REPOSITORY (JPA + RLS)     │    │  INTEGRATION                                   ││
│  │  + tenant_id session var    │    │  EMQX MqttClient (Paho) | MinIO S3 SDK        ││
│  │  + TimescaleDB native       │    │  Redis Cluster | Chapa REST | FCM | APNs      ││
│  └──────┬──────────────────────┘    └───────────────────────────┬──────────────────┘│
└─────────┼────────────────────────────────────────────────────────┼───────────────────┘
          │                                                        │
          ▼                                                        ▼
┌─────────────────────────┐                          ┌──────────────────────────────────┐
│   PostgreSQL 16         │                          │     EMQX Cluster (3 nodes)       │
│   + TimescaleDB ext     │   mTLS (HTTP auth/ACL)   │  node1 ◄──► node2 ◄──► node3     │
│   + Postgres RLS        │◄─────────────────────────│  MQTTS :8883 (devices)           │
│                         │                          │  Dashboard :18083                │
│  tenants, users, homes, │                          │  Mutual-TLS (own CA)             │
│  nodes, node_devices,   │                          │  HTTP auth+ACL → Spring Boot     │
│  node_params,           │                          │  Shared subs for backend         │
│  payments, ota_batches, │                          └──────────────┬───────────────────┘
│  audit_log              │                                         │ MQTTS :8883 (mutual TLS)
│  device_energy_readings (TS) │                                      ▼
│  device_telemetry (TS)  │                          ┌──────────────────────────────────┐
└─────────────────────────┘                          │   SHE ESP32 Devices              │
          │                                          │   (SHE-R4 / R8 / R16)            │
          ▼                                          │                                  │
┌─────────────────────────┐                          │  - X.509 cert in NVS (encrypted) │
│       Redis Cluster     │                          │  - BLE provisioning              │
│  (3 nodes + 3 sentinel) │                          │  - Ed25519 OTA verify            │
│  sessions, jti blacklist│                          │  - Local control via mDNS+HTTPS  │
│  RBAC cache, rate-limit │                          │  - PZEM-004T energy (R8/R16)     │
│  idempotency keys       │                          │  - Picovoice voice (R16)         │
└─────────────────────────┘                          └──────────────────────────────────┘
          │
          ▼
┌─────────────────────────┐
│       MinIO             │
│  firmware images (OTA)  │
│  B2B white-label assets │
│  audit CSV exports      │
└─────────────────────────┘
```

---

## 4. Core data flows

### 4.1 Command flow (app → device)

```
Flutter app
  → POST /api/v3/nodes/{nodeId}/devices/{deviceId}/params  body: {"Power": true}
  → Cloudflare (TLS terminate, geo-block check, WAF)
  → Nginx → Spring Boot (RBAC chokepoint, RLS tenant filter)
  → Spring Boot writes node_params.last_value (desired)
  → Spring Boot publishes to MQTT  she/{t}/{h}/{r}/{mac}/params/remote  QoS 1
  → EMQX routes to ESP32 (subscribed to its own /params/remote)
  → ESP32 toggles relay via PCF8574
  → ESP32 publishes  she/{t}/{h}/{r}/{mac}/params/local  QoS 0
  → Spring Boot (shared sub) updates node_params.last_value (reported)
  → Spring Boot pushes WebSocket event  device.state  → Flutter
  → UI updates (Bento card toggle)
```

End-to-end latency target: < 500 ms (p95) on a healthy connection.

### 4.2 Telemetry flow (device → app)

```
ESP32 (every 5 s, or on-change)
  → publishes  she/{t}/{h}/{r}/{mac}/params/local  QoS 0
  → EMQX shared subscription  $share/she-backend/she/+/+/+/+/params/local
  → Spring Boot (exactly one instance receives it)
  → UPSERT node_params.last_value + last_reported_at
  → WebSocket push  device.state  → all sessions for that home
  → Automation evaluator (inline, for DEVICE_STATE triggers)
```

### 4.3 Energy flow (device → app + DB)

```
PZEM-004T (every 5 s) → ESP32 UART
  → publish  she/{t}/{h}/{r}/{mac}/energy  QoS 0
     payload: {"v":220.5,"i":1.21,"p":267.0,"wh":12345.6,"pf":0.99,"freq":50.0}
  → EMQX → Spring Boot EnergyService (shared sub)
    → TimescaleDB INSERT  device_energy_readings  (hypertable, segmentby node_id)
    → ETB cost calc (EEU block tariff — see V3-ENERGY-MONITORING.md)
    → Update homes.energy_today_etb cache (Redis)
    → WebSocket push  energy.update  → Flutter (real-time gauge)
    → Anomaly detector (delta > 3σ over 24h rolling window → audit_log + push notification)
```

### 4.4 BLE provisioning flow (user site) + device cert flow (factory)

> **Canonical device cert model (P0-1, P0-2):** The ESP32 generates its **ECDSA P-256** keypair **on-chip at the factory** using mbedTLS (`mbedtls_ecdsa_genkey()`). The private key NEVER leaves the device — the factory workstation never sees it. The CSR is sent to **step-ca**, which signs it with the **intermediate CA (5-year validity)**. The signed cert + encrypted private key are stored in the `fctry` NVS partition (encrypted via Flash Encryption). **BLE provisioning (at user site) does NOT issue certs** — the cert is already on the device from the factory. BLE provisioning only transfers Wi-Fi creds + performs user-node mapping (challenge-response).

**Factory cert flow (per device, at factory workstation):**

```
1. ESP32 boots in factory mode (USB serial attached to factory workstation)
2. Firmware calls mbedtls_ecdsa_genkey() → generates P-256 keypair in RAM
3. Private key written to fctry NVS partition (encrypted via Flash Encryption)
4. Firmware generates CSR with CN={MAC_ADDRESS}
5. Factory workstation reads CSR from ESP32 over USB serial
6. Factory workstation sends CSR to step-ca: `step ca sign {csr} --not-after=43800h`
7. step-ca signs cert (intermediate CA, 5-year validity)
8. Cert returned to ESP32 over USB serial, stored in fctry NVS
9. Factory workstation logs cert fingerprint + MAC, but NEVER has the private key
```

**BLE provisioning flow (at user site, AFTER factory cert is already on device):**

```
1. User scans QR code on device box → opens Flutter app → "Add Device"
   (QR contains: MAC + 9-digit PoP number + claim_token URL — see §4.6)
2. Flutter BLE scan → discovers SHE-R8 (advertising service UUID 0000ffff-0000-1000-8000-00805f9b34fb)
3. Flutter connects to ESP32 over BLE (bonded, encrypted link)
4. Flutter writes Wi-Fi SSID+PSK + tenant_id + claim_token (10-min single-use JWT) + PoP
5. ESP32 verifies PoP against fctry NVS (challenge-response — see §4.6)
6. ESP32 connects to Wi-Fi → HTTPS POST /api/v3/provisioning/claim
     body: {mac, claim_token, pop_proof}    (NO CSR — cert already on device from factory)
7. Spring Boot:
   - verifies claim_token (Redis single-use)
   - verifies MAC not already provisioned
   - verifies PoP (challenge-response against factory-issued PoP in device record)
   - does NOT sign any cert (cert was signed by step-ca at factory)
   - creates nodes + node_devices rows, links device to user's home
8. ESP32 opens MQTTS (mutual TLS, cert from fctry NVS) to EMQX
9. Spring Boot publishes  config  retained topic
10. WebSocket push  device.added  → Flutter → device appears in Bento dashboard
```

### 4.5 OTA flow

```
Admin uploads firmware image (Ed25519-signed .bin) via Admin Console
  → POST /api/v3/ota/images  (MinIO PUT  s3://she-firmware/v1.5.0/SHE-R8.bin)
  → POST /api/v3/ota/batches  {image_id, target_sku, target_tenants, rollout_pct}
  → Spring Boot per-target-device:
      → publish  she/{t}/{h}/{r}/{mac}/ota/url  QoS 1
         payload: {"version":"1.5.0","url":"https://minio.she.et/she-firmware/v1.5.0/SHE-R8.bin",
                   "sig":"base64-ed25519-signature","size":1245184,"min_hw_rev":"rev-b"}
  → ESP32 downloads over HTTPS (chunked, resume-capable)
  → ESP32 verifies Ed25519 signature against OTA_SIGNING_PUBKEY burned in eFuse
  → ESP32 verifies secure version >= anti-rollback eFuse min (see V3-SECURITY-MODEL.md §5)
  → ESP32 writes to alternate OTA partition
  → Publishes  she/{t}/{h}/{r}/{mac}/ota/progress  QoS 0  (0→100)
  → Reboots into new partition
  → Health check window (5 min): must maintain Wi-Fi + MQTT + report telemetry
    → If pass:  esp_ota_mark_image_valid()  → publishes  ota/status = "complete"
    → If fail:  bootloader auto-rolls back to previous partition → publishes  ota/status = "rolled_back"
```

### 4.6 Local control flow (no internet)

```
Flutter app (same Wi-Fi as device)
  → mDNS discovery  _she-ctrl._tcp.local
  → ESP32 advertises hostname  she-r8-aabbcc.local  on port 4443
  → HTTPS to ESP32 (TLS cert is the same X.509 used for MQTT, presented via local server)
  → Auth: PoP (Proof of Possession) = factory-generated random 9-digit CSPRNG number
       stored in fctry NVS, scanned from QR code sticker on device box
       (P1-1: NOT HMAC-SHA256, NOT MAC-derived, NOT 8-char alphanumeric)
  → POST https://she-r8-aabbcc.local/api/local/devices/{id}/params  {"Power": true}
  → ESP32 toggles relay immediately (no cloud round-trip, < 50 ms)
  → ESP32 queues state change in NVS for MQTT publish when internet returns
  → On reconnect, ESP32 flushes queued telemetry → /params/local (QoS 1)
```

---

## 5. Storage layer

### 5.1 PostgreSQL 16 (relational store)

**Role:** System of record for tenants, users, homes, rooms, nodes, node_devices, node_params, payments, ota_batches, audit_log. See `V3-DATABASE-DESIGN.md` for full DDL.

**Multi-tenant isolation:** Row-Level Security (RLS) on every tenant-scoped table. The RLS policy itself checks the `app.tenant_id` GUC and a separate `app.is_platform_admin` GUC (canonical, per CANONICAL-DECISIONS.md P0-5) — there is **no** `app.bypass_rls` GUC and **no** `BYPASSRLS` role.

```sql
-- Canonical RLS policy (applied to every tenant-scoped table)
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON nodes
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );

-- Spring Boot TenantContextFilter sets these per request (derived from JWT):
SET LOCAL app.tenant_id = '6f1c...';
SET LOCAL app.user_id   = '8a3b...';

-- For PLATFORM_ADMIN / SUPER_ADMIN cross-tenant read-only ops:
SET LOCAL app.is_platform_admin = 'on';   -- the policy itself checks this GUC
-- (For non-admin users: SET LOCAL app.is_platform_admin = 'off';)
```

**Why this works (and why `she_app` does NOT need `BYPASSRLS`):**
- `current_setting('app.is_platform_admin', true)` returns `false` if the GUC is unset (the `true` = `missing_ok`).
- The RLS policy itself checks the flag — no `BYPASSRLS` privilege needed.
- `she_app` (the Spring Boot DB role) does NOT have `BYPASSRLS` (safer — no privilege escalation path).
- Auditable: the GUC is set per-transaction, visible in `pg_stat_statements`.

**Connection pool:** HikariCP, 20 connections per Spring Boot instance, pgBouncer in transaction mode in front of Postgres (max_connections = 200).

**Backup:** WAL archiving + nightly base backup to MinIO (3 copies). RPO ≤ 5 min, RTO ≤ 1 h.

### 5.2 TimescaleDB (time-series extension)

**Role:** Hypertables for `device_telemetry` (every param update, QoS 0/1) and `device_energy_readings` (every 5 s per device). Table name + columns are canonical (P1-20): `device_energy_readings` / `power_w` / `time`.

```sql
CREATE TABLE device_energy_readings (
    node_id      UUID NOT NULL,
    device_id    UUID NOT NULL,
    time         TIMESTAMPTZ NOT NULL,
    voltage      REAL,
    current      REAL,
    power_w      REAL,           -- canonical column name (was 'power')
    energy_wh    REAL,
    power_factor REAL,
    frequency    REAL
);
SELECT create_hypertable('device_energy_readings', 'time', chunk_time_interval => INTERVAL '1 day');

-- Compression policy: compress chunks older than 7 days, segment by node_id
ALTER TABLE device_energy_readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'node_id',
    timescaledb.compress_orderby   = 'time DESC'
);
SELECT add_compression_policy('device_energy_readings', INTERVAL '7 days');

-- Retention policy: drop chunks older than 365 days (canonical, P1-21)
SELECT add_retention_policy('device_energy_readings', INTERVAL '365 days');
```

**Compression ratio observed:** ~8-12× on energy data (segmentby node_id is high-cardinality but each chunk is node-localized).

**device_telemetry hypertable:** 30-day retention (raw), 30-day compressed (90 days total). Beyond that, aggregates only.

### 5.3 MinIO (object storage)

**Buckets:**

| Bucket | Contents | Lifecycle |
|---|---|---|
| `she-firmware` | OTA firmware images (Ed25519-signed .bin) | Versioned, never deleted |
| `she-b2b-assets` | Per-tenant logos, splash images, custom CSS | Versioned, deleted on tenant offboarding |
| `she-audit-exports` | CSV audit log exports | 30-day auto-expire |
| `she-wal-backups` | Postgres WAL archive | 7-day retention |

**Access:** Spring Boot uses S3 SDK with STS-style short-lived presigned URLs for OTA downloads (15-min TTL). Devices fetch directly from MinIO via the presigned URL — no proxy through Spring Boot.

### 5.4 Redis (cache + session store)

| Use case | TTL | Eviction |
|---|---|---|
| User session (JWT jti → user_id) | matches refresh token TTL | Volatile-LRU |
| JWT jti blacklist (rotated refresh tokens) | until access token expiry | Volatile-ttl |
| RBAC cache (user_id → roles + home_permissions) | 5 min | Volatile-LRU |
| Rate-limit counters (login attempts, API calls) | sliding 15-min window | Volatile-ttl |
| Idempotency keys (non-payment: command dedup, notification dedup) | 24 h | Volatile-ttl |
| Device online status cache | 60 s (refreshed by MQTT LWT) | Volatile-ttl |

**Persistence:** AOF every 1 s (no fsync), RDB every 1 h. Data is rebuildable from Postgres in < 10 min.

> **Payment idempotency exception:** Payment idempotency keys are NOT stored in Redis — they are stored in **Postgres** via a `UNIQUE(idempotency_key, tenant_id)` constraint on the `payments` table. Redis's 1-second AOF data-loss window is acceptable for sessions, rate-limit counters, and non-payment idempotency (rebuildable), but NOT for payment deduplication (real money impact). Redis is used as a **read cache** for payment idempotency (fast pre-check), but Postgres is the source of truth. See V3-PAYMENTS.md §6.4 for the full flow.

---

## 6. EMQX cluster topology

```
                  ┌─────────────────────┐
                  │   EMQX Node 1       │
                  │   Addis DC rack A   │
                  │   4 vCPU / 8 GB     │
                  └─────────┬───────────┘
                            │  Ekka Mnesia cluster mesh
              ┌─────────────┼─────────────┐
              │             │             │
              ▼             ▼             ▼
       ┌────────────┐  ┌────────────┐  ┌────────────┐
       │ EMQX Node 2│  │ EMQX Node 3│  │ Spring Boot│
       │ rack B     │  │ rack C     │  │ x2+ (Paho) │
       └─────┬──────┘  └────────────┘  └────────────┘
             │
             │ MQTTS :8883  mutual-TLS (own CA)
             │   HTTP auth  →  POST /internal/mqtt/auth  (Spring Boot)
             │   HTTP acl   →  POST /internal/mqtt/acl   (Spring Boot)
             ▼
   ┌──────────────────────────────────────────────┐
   │   SHE ESP32 Devices                          │
   │   - X.509 client cert in NVS                 │
   │   - Per-device ACL (MAC-scoped topic match)  │
   │   - Shared subscription for backend fan-out  │
   └──────────────────────────────────────────────┘
```

### 6.1 Cluster sizing

| Parameter | Value | Justification |
|---|---|---|
| Node count | 3 | Quorum for Mnesia, tolerates 1-node loss |
| Per-node spec | 4 vCPU, 8 GB RAM, 100 GB SSD | Handles 5,000 concurrent connections each, 15,000 total |
| Max concurrent MQTT connections | 15,000 (cluster) | Sufficient for V3 GA target (5,000 active devices + headroom) |
| Max message throughput | 50,000 msg/s (cluster) | Headroom over expected 5,000 devices × 4 msg/s = 20,000 msg/s |
| Listener | `ssl:default` on :8883 | MQTTS only; port 1883 disabled in production |

### 6.2 HTTP auth/ACL backend configuration (EMQX)

```yaml
# emqx.conf (excerpt)
listeners.ssl.default {
  bind = "0.0.0.0:8883"
  max_connections = 5000
  ssl_options {
    keyfile  = /etc/emqx/certs/server.key
    certfile = /etc/emqx/certs/server.crt
    cacertfile = /etc/emqx/certs/ca_bundle.pem   # root + BOTH intermediates
    verify   = verify_peer
    fail_if_no_peer_cert = true
  }
}

authentication = [
  {
    cache { ttl = 300s }   # P1-11: 5-minute cache (default is 60s) — see note below
    mechanism = password_based
    backend = http
    method = post
    url = "https://she-backend.internal:8080/internal/mqtt/auth"
    headers { content-type = "application/json" }
    body { clientid = "${clientid}" cn = "${peer_cert_cn}" fingerprint = "${peer_cert_fingerprint}" }
  }
]

authorization {
  sources = [
    {
      type = file
      enable = true
      rules = [
        # Backend service (cert-based, subscribed via shared sub)
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/telemetry" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/status" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/params/local" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/energy" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/ota/status" }
        { permission = allow, action = publish,   topic = "she/+/+/+/+/command" }
        { permission = allow, action = publish,   topic = "she/+/+/+/+/params/remote" }
        { permission = allow, action = publish,   topic = "she/+/+/+/+/ota/url" }
        # Devices (cert-based, per-device ACL via cert CN = clientid)
        { permission = allow, action = publish,   topic = "she/+/+/+/${clientid}/telemetry" }
        { permission = allow, action = publish,   topic = "she/+/+/+/${clientid}/status" }
        { permission = allow, action = publish,   topic = "she/+/+/+/${clientid}/params/local" }
        { permission = allow, action = publish,   topic = "she/+/+/+/${clientid}/energy" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/${clientid}/command" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/${clientid}/params/remote" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/${clientid}/ota/url" }
      ]
    }
  ]
}
```

> **P1-32 — EMQX 5.x authorization config:** Do NOT use the flattened env vars `EMQX_AUTHORIZATION__SOURCE = http` / `EMQX_AUTHORIZATION__URL = ...` (those were the EMQX 4.x style and do not work correctly on 5.x). Use the HOCON `authorization { sources = [ { type = file, ... } ] }` block above, configured via the `EMQX_AUTHORIZATION__SOURCES` env var (JSON array) or a `cluster-override.conf` file. The flattened env vars are deprecated and silently ignored on EMQX 5.x.

> **P1-11 — HTTP auth cache TTL:** The `authentication` block above uses `cache { ttl = 300s }` (5 minutes, not the EMQX default of 60s). With a 5-minute cache, if Spring Boot is down, devices with cached auth can reconnect for up to 5 minutes. For longer outages, EMQX falls back to **cert-fingerprint-only auth** — it validates the device cert chain against `ca_bundle.pem` without calling Spring Boot, but does NOT check revocation (acceptable for short outages; revoke propagation is bounded by the 6-hour CRL refresh — see V3-CONFIGURATION.md §3.5).

The `ca_bundle.pem` file contains the root CA cert + the current intermediate CA cert + the previously-rotated intermediate CA cert (during the yearly rotation overlap window — see `V3-SECURITY-MODEL.md` §3.3).

---

## 7. MQTT topic namespace

```
she/{tenant_id}/{home_id}/{room_id}/{node_mac}/{direction}
```

| Segment | Value | Notes |
|---|---|---|
| `tenant_id` | UUID (short form 8 chars) | Tenant isolation — enforced by ACL |
| `home_id` | UUID (short form 8 chars) | Home isolation within tenant |
| `room_id` | UUID or `unassigned` | Until device is assigned a room |
| `node_mac` | Normalized MAC (lowercase, no colons) | e.g., `aabbccddeeff` — must match cert CN |
| `direction` | see table below | Maps to RainMaker hierarchy levels (V3-DEVICE-MODEL.md) |

### 7.1 Directions + RainMaker hierarchy mapping

| Direction | QoS | Retained | Flow | RainMaker concept |
|---|---|---|---|---|
| `config` | 1 | Yes | Device → Server (on connect) | Node self-description (devices + services + params + attrs) |
| `command` | 1 | No | Server → Device | High-priority command (reboot, factory reset) |
| `params/local` | 0 | No | Device → Server | Reported state of Parameters (telemetry) |
| `params/remote` | 1 | No (but `desired` shadow is DB-backed) | Server → Device | Desired state of Parameters (write) |
| `telemetry` | 0 | No | Device → Server | High-frequency diagnostic stream (RSSI, heap) |
| `status` | 1 | Yes | Device → Server (LWT) | Node presence (online / offline) |
| `energy` | 0 | No | Device → Server | PZEM readings (Voltage, Current, Power, kWh) |
| `ota/url` | 1 | No | Server → Device | OTA trigger (URL + signature + version) |
| `ota/status` | 1 | No | Device → Server | OTA phase (downloading / flashing / complete / rolled_back) |
| `ota/progress` | 0 | No | Device → Server | 0-100 integer |

See `V3-MQTT-STANDARDS.md` for the full topic spec, payload JSON examples, and per-device ACL rules.

### 7.2 Shared subscription (backend horizontal scaling)

Spring Boot subscribes (per instance) to:

```
$share/she-backend/she/+/+/+/+/(telemetry|status|params/local|energy|ota/status|ota/progress)
```

EMQX distributes each message to exactly one Spring Boot instance within the `she-backend` group. Per-device topics (`command`, `params/remote`, `ota/url`, `config`) are published from any Spring Boot instance — no shared subscription needed because they are outbound.

---

## 8. Security layers (summary)

| Layer | Mechanism | Spec doc |
|---|---|---|
| Network edge | Cloudflare DDoS + WAF + geo-block (ET only, with exceptions) | §10 below |
| Transport | TLS 1.3 (HTTPS, WSS, MQTTS) — TLS 1.2 disabled at Nginx + EMQX | V3-SECURITY-MODEL.md §1 |
| API auth | JWT EdDSA (Ed25519) with `kid`-based multi-key rotation, USER refresh 30d, ADMIN 8h, SUPER 4h | V3-SECURITY-MODEL.md §1, CANONICAL-DECISIONS.md P1-6 |
| API authz | Multi-tenant RBAC, **10 roles**, Postgres RLS | V3-SECURITY-MODEL.md §2 |
| MFA | TOTP (RFC 6238) required for SUPER/PLATFORM/TENANT_ADMIN | V3-SECURITY-MODEL.md §6 |
| Device auth | X.509 client certs, own CA (root + intermediate) | V3-SECURITY-MODEL.md §3 |
| Device authz | Per-device ACL via EMQX HTTP backend → Spring Boot | V3-SECURITY-MODEL.md §4 |
| Firmware security | Secure Boot v2 + Flash Encryption + anti-rollback eFuses + Ed25519 OTA signing | V3-SECURITY-MODEL.md §5 |
| Data at rest | LUKS (dm-crypt) on Postgres + MinIO volumes; AES-GCM for TOTP/CA keys; BCrypt for user passwords | V3-SECURITY-MODEL.md §8 |
| Audit | All admin + security events logged, 2-year retention, CSV export | V3-SECURITY-MODEL.md §7 |
| Secrets | step-ca for CA, KEK in env var, JWT quarterly rotation | V3-CONFIGURATION.md |

---

## 9. Multi-tenant data isolation

SHE V3 uses **row-level multi-tenancy** — all tenants share one Postgres instance, but every tenant-scoped table has a `tenant_id` column enforced by RLS (ADR-003).

**10 roles** (corrected from earlier draft which stated 8 in two places):

| Scope | Roles | Count |
|---|---|---|
| Platform | USER, PLATFORM_ADMIN, SUPER_ADMIN | 3 |
| Tenant | TENANT_ADMIN, TENANT_INSTALLER, TENANT_VIEWER | 3 |
| Home | OWNER, ADMIN, MEMBER, GUEST | 4 |
| **Total** | | **10** |

Authorization chokepoint (single audit-able entry point):

```java
Home getAuthorizedHomeOrThrow(UUID requesterId, UUID homeId, HomeRole requiredRole);
```

Combines Postgres RLS (tenant isolation) + `home_permissions` table (home-level RBAC) in one call. See `V3-SECURITY-MODEL.md` §2 for the full role-capability matrix.

---

## 10. Cloudflare geo-block with exceptions

### 10.1 Block rule

Cloudflare WAF custom rule blocks all traffic originating outside Ethiopia (country code `ET`), applied at the zone level. This satisfies the PDPP data-residency intent (ADR-008) and limits attack surface.

```
(http.geoip.country ne "ET")
action: Block
```

### 10.2 Exception list (whitelisted egress IPs)

The geo-block would break inbound traffic from external SaaS providers that SHE depends on. The following IP ranges are explicitly allowed (Cloudflare WAF rule order: allow → block):

| Source | Purpose | IPs / ranges |
|---|---|---|
| Chapa webhook callbacks | Payment status notifications | `41.216.199.0/24` (Chapa primary), `196.188.124.0/24` (Chapa secondary) |
| Google FCM | Push notifications to Android devices | `35.191.0.0/16`, `130.211.0.0/22` (Google FCM egress per Google's published list) |
| Cloudflare health checks | Origin monitoring | `173.245.48.0/20`, `103.21.244.0/22`, `103.22.200.0/22`, `141.101.64.0/18`, `108.162.192.0/18`, `190.93.240.0/20`, `188.114.96.0/20`, `197.234.240.0/22`, `198.41.128.0/17`, `162.158.0.0/15`, `104.16.0.0/13`, `104.24.0.0/14`, `172.64.0.0/13`, `131.0.72.0/22` |
| SHE office VPN (Addis Ababa) | Internal admin access during incidents | `197.156.78.42/32` (office public NAT egress IP assigned by Ethio Telecom — Cloudflare sees public IPs, not private ranges; P1-31) |

> **P1-30 — APNs whitelist removed:** The previous draft listed `17.0.0.0/8` (Apple Inc. corporate range) as a whitelisted source for APNs callbacks. **APNs is a push service — Apple does not make inbound HTTP callbacks to your origin.** The whitelist was dead weight (it whitelisted 16M Apple corporate IPs that never initiate inbound HTTP to SHE). If delivery receipts are needed, configure a URL in the APNs payload (app-server endpoint) — that is an outbound HTTPS call FROM SHE TO Apple, not inbound. The rule has been removed.

### 10.3 Devices are not affected

ESP32 devices do NOT use Cloudflare — they connect directly to EMQX on port 8883 (MQTTS), which is exposed via the Ethio Telecom Cloud public IP, not proxied through Cloudflare. The geo-block applies only to HTTPS/WSS traffic on ports 443.

### 10.4 Cloudflare Workers (optional, V3.1)

For V3 GA, no Cloudflare Workers are deployed — all logic runs on Spring Boot. V3.1 may add a Worker for edge-side push notification batching (FCM/APNs) to reduce origin load.

### 10.5 DR site location

**V3 GA DR site: Adama** (160 km from Addis Ababa, same Ethiopian Rift seismic zone — **acknowledged limitation**, per P1-18). The offsite replica lives in Adama; this is close enough for low-latency async replication and satisfies the PDPP data-residency requirement (data stays within Ethiopia). The known risk is that Adama and Addis share the same seismic zone — a major Rift event could in principle affect both sites.

**V3.1 deliverable: Dire Dawa DR site** (different seismic zone, ~400 km from Addis Ababa) — provides true seismic-zone diversity. Tracked in V3-ROADMAP.md.

---

## 11. Production infrastructure — Ethio Telecom Cloud cost estimate

The earlier draft quoted ~$415/month, which was based on Hetzner Cloud (German provider) pricing. SHE V3 is hosted in Addis Ababa on Ethio Telecom Cloud, which has higher per-unit pricing but satisfies PDPP data-residency requirements.

| Component | Spec | Monthly cost (USD) |
|---|---|---|
| Compute VM × 3 (Spring Boot + Nginx + Admin web) | 8 vCPU, 16 GB RAM, 200 GB SSD each | $180 × 3 = $540 |
| Compute VM × 1 (Postgres 16 + TimescaleDB) | 8 vCPU, 32 GB RAM, 1 TB NVMe | $360 |
| Compute VM × 3 (EMQX cluster nodes) | 4 vCPU, 8 GB RAM, 100 GB SSD each | $90 × 3 = $270 |
| Compute VM × 1 (Redis + MinIO + monitoring) | 4 vCPU, 16 GB RAM, 2 TB SSD | $200 |
| Object storage (MinIO backend, 500 GB usable) | 500 GB | $40 |
| Cloudflare Business | DDoS + WAF + DNS | $250 (P1-16: Business plan, was $25/mo Pro price) |
| Ethio Telecom dedicated fiber (1 Gbps committed) | office + datacenter cross-link | (bundled with Ethio Telecom Cloud contract) |
| Ethio Telecom static IPs (5 IPs) | public IPs for EMQX + origin | (bundled) |
| Managed backup (offsite replication to DR site in Adama, 160km from Addis Ababa — same seismic zone, known limitation; Dire Dawa DR is V3.1) | 1 TB | (bundled) |
| **Total monthly (steady-state, reconciled P1-17)** | | **~$2,060** |
| **Range with usage variability** | | **$1,800 – $2,400/month** |

### 11.1 Reconciled monthly cost (canonical, P1-17)

The line-item table above rolls up to the **canonical $2,060/month** total reconciled in CANONICAL-DECISIONS.md P1-17:

| Line item | Monthly cost (USD) |
|---|---|
| Ethio Telecom Cloud VPS (5 servers: Spring Boot×2, Postgres, EMQX×3, Redis+MinIO+monitoring) | $1,500 |
| Cloudflare Business plan | $250 |
| Chapa payment fees (variable, ~1.5% of GMV) | $100 |
| DNS + domain registration | $20 |
| Monitoring (PagerDuty Business ~$21/user × 3 + Grafana Cloud + Loki) | $190 |
| **Total** | **$2,060** |

Break-even MRR at 60% gross margin on subscription: **$3,433/mo** (see V3-UNIT-ECONOMICS.md).

### 11.2 Scaling breakpoints

| Devices | Action | New monthly cost |
|---|---|---|
| 0 – 5,000 | Above baseline | $2,060 |
| 5,000 – 10,000 | Add 1 Spring Boot instance, +1 Postgres read replica | +$280 → ~$2,340 |
| 10,000 – 25,000 | Postgres vertical scale (16 vCPU, 64 GB), EMQX → 5 nodes | +$720 → ~$3,060 |
| 25,000+ | Re-architect: Postgres sharding by tenant_id, separate TimescaleDB cluster | Custom quote |

### 11.3 Why not Hetzner / AWS / GCP

| Provider | Why rejected |
|---|---|
| Hetzner | Servers in DE/FI/US — violates PDPP data residency (ADR-008) |
| AWS (me-south-1 Bahrain) | Closest AWS region; still leaves data outside Ethiopia, requires subprocessor agreement |
| GCP | No in-country region; same issue |
| Azure | No in-country region; same issue |
| Ethio Telecom Cloud | Only in-country option; satisfies PDPP; higher cost but no legal exposure |

---

## 12. Device data model — cross-reference

The full RainMaker hierarchy adoption is documented in `V3-DEVICE-MODEL.md`. The mapping to MQTT topics is summarized in §7 above; the mapping to Postgres tables (`nodes`, `node_devices`, `node_params`) is documented in `V3-DEVICE-MODEL.md` §6 and `V3-DATABASE-DESIGN.md` §3.

```
RainMaker hierarchy          →   MQTT topic                        →   Postgres table
─────────────────────────────────────────────────────────────────────────────────────────
Node (SHE-R8-AABBCC)         →   she/.../aabbccddeeff/config        →   nodes (1 row)
├── Device "Relay 1"         →   payload key "Relay 1"             →   node_devices (1 row)
│   ├── Parameter Power      →   params/local: {"Relay 1":{"Power":true}}
│   │                        →   params/remote: {"Relay 1":{"Power":true}}
│   │                                                         →   node_params (1 row, last_value)
│   └── Attribute Label      →   config payload                    →   node_devices.attributes JSONB
├── Service OTA              →   ota/url, ota/status, ota/progress
└── Service Diagnostics      →   telemetry: {"uptime":..., "rssi":...}
```

---

## 13. Observability

| Layer | Metric source | Dashboard |
|---|---|---|
| ESP32 devices | MQTT `telemetry` topic (uptime, RSSI, free_heap, reset_reason) | Grafana "Device Health" |
| EMQX | Built-in Prometheus exporter (port 8888) | Grafana "MQTT Broker" |
| Spring Boot | Micrometer → Prometheus (port 9090) | Grafana "Backend" |
| Postgres | `pg_stat_statements` + `timescaledb_info` views | Grafana "Database" |
| Redis | `redis_exporter` (port 9121) | Grafana "Cache" |
| Nginx | `nginx-prometheus-exporter` (port 9113) | Grafana "Edge" |
| Cloudflare | GraphQL analytics API → Prometheus | Grafana "Edge Security" |

**Alerting:** Alertmanager → **PagerDuty** (on-call rotation; P1-29 — was incorrectly listed as Telegram bot). PagerDuty Business plan (~$21/user/mo × 3 users = $63/mo) is included in the $190 monitoring line item in §11.1. Critical alerts:

- EMQX node down > 2 min
- Postgres replication lag > 60 s
- Spring Boot 5xx error rate > 1% over 5 min
- OTA failure rate > 10% over 1 h
- Device offline rate > 20% of fleet over 15 min (indicates widespread internet outage)

---

## 14. What changed from the V3 draft

| Issue in draft | Fix in this version |
|---|---|
| Role count stated as 8 in two places | Corrected to **10** (3 platform + 3 tenant + 4 home) |
| Infra cost quoted ~$415/month (Hetzner pricing) | Realistic Ethio Telecom Cloud cost: $2,060/month canonical (P1-17) |
| TimescaleDB compression policy not documented | Added §5.2 with segmentby + interval + retention policy |
| Cloudflare geo-block listed without exception list | Added §10.2 with Chapa / FCM / Cloudflare / office VPN whitelisted IPs (APNs rule removed per P1-30 — push services do not initiate inbound HTTP) |
| EMQX HTTP auth/ACL backend config not shown | Added §6.2 with full EMQX 5.x HOCON (auth cache TTL 300s per P1-11, authorization sources per P1-32) |
| Mentioned "Matter Border Router (Raspberry Pi 4)" in diagram | Removed — V3 uses Matter-over-Wi-Fi per-device (ADR-007), no Border Router |
| Status: Proposed | Status: **Locked** |

---

## 15. References

- `V3-OVERVIEW.md` — platform vision
- `V3-DEVICE-MODEL.md` — RainMaker hierarchy adoption
- `V3-HARDWARE.md` — ESP32-C3 (R4), ESP32-S3 (R8/R16) BOM + schematic + manufacturing
- `V3-SECURITY-MODEL.md` — full security spec, 10-role RBAC, Secure Boot v2, threat model
- `V3-MQTT-STANDARDS.md` — topic namespace, QoS matrix, payload examples
- `V3-DATABASE-DESIGN.md` — Postgres schema + RLS + TimescaleDB
- `V3-CONFIGURATION.md` — env var catalog, step-ca CA setup, secret rotation
- `V3-OPS-RUNBOOK.md` — deploy, monitor, incident response
- ADR-003 — multi-tenant RLS
- ADR-008 — Ethio Telecom Cloud hosting
- ADR-012 — ESP32 chip selection per SKU
- ADR-013 — firmware security (Secure Boot v2 + Flash Encryption)
