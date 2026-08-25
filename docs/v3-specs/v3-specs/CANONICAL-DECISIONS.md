# V3 — Canonical Decisions (Issue Resolution Reference)

**Status:** Locked
**Purpose:** Single source of truth for all decisions that were previously contradictory across V3 docs. Every other doc MUST cite this file. Generated in response to P0/P1 review.

---

## P0 — Critical Fixes

### P0-1: Device private key generation model

**Canonical decision:** ESP32 generates ECDSA P-256 keypair **on-chip** using mbedTLS. Private key never leaves the device. Factory workstation NEVER sees the private key.

**Flow:**
1. ESP32 boots in factory mode
2. Firmware calls `mbedtls_ecdsa_genkey()` → generates P-256 keypair in RAM
3. Private key written to `fctry` NVS partition (encrypted via Flash Encryption)
4. Firmware generates CSR with `CN={MAC_ADDRESS}`
5. Factory workstation reads CSR from ESP32 over USB serial
6. Factory workstation sends CSR to step-ca (`step ca sign {csr} --not-after=43800h`)
7. step-ca signs cert (intermediate CA, 5-year validity)
8. Cert returned to ESP32 over USB serial, stored in `fctry` NVS
9. Factory workstation logs cert fingerprint + MAC, but NEVER has the private key

**BLE provisioning (at user site) does NOT issue certs.** It only transfers Wi-Fi creds + performs user-node mapping (challenge-response). The cert is already on the device from factory.

**Docs that must align:** V3-SECURITY-MODEL.md §3.2 (authoritative), V3-ARCHITECTURE.md §4.4, V3-FIRMWARE.md §5.1, V3-FACTORY-OPS.md §3.1+§6.1

---

### P0-2: Device cert type, validity, and CA

**Canonical decision:**

| Cert | Key type | Validity | Signed by |
|---|---|---|---|
| Root CA | RSA 4096-bit | 20 years | Self-signed |
| Intermediate CA | RSA 4096-bit | 10 years | Root CA |
| Device cert | **ECDSA P-256** | **5 years** | Intermediate CA |

**Why ECDSA P-256 (not RSA-2048):**
- ESP32-C3 has no RSA hardware acceleration (software-only, 200-400ms per verify)
- ECDSA P-256 verify is ~50ms on C3 (hardware-assisted on S3)
- NIST SP 800-57 recommends ≥3072-bit RSA for protection beyond 2030
- ECDSA P-256 is NIST-approved through 2030+
- Smaller cert size (72 bytes vs 256 bytes for RSA-2048 signature)

**Cert is issued at FACTORY** (not during BLE provisioning). BLE provisioning only transfers Wi-Fi creds + does user-node mapping.

**Docs that must align:** V3-SECURITY-MODEL.md §3.1 (authoritative), V3-FACTORY-OPS.md §3.1, V3-FIRMWARE.md §5.1

---

### P0-3: eFuse burn sequence (ESP32-S3)

**Canonical sequence (in order, all via `espefuse.py`):**

```bash
# 1. Burn Secure Boot key (AES-256, used for Secure Boot v2 digest)
espefuse.py burn_key BLOCK_KEY0 secure_boot_key.bin SECURE_BOOT_DIGEST

# 2. Burn Flash Encryption HMAC key (used for flash encryption + NVS encryption)
espefuse.py burn_key BLOCK_KEY1 flash_enc_key.bin HMAC_DOWN_ENCRYPT

# 3. Burn Ed25519 OTA verification public key (immutable, used for OTA signature verify)
espefuse.py burn_key BLOCK_KEY2 ota_ed25519_pubkey.bin USER

# 4. Set initial SECURE_VERSION (anti-rollback, popcount semantics)
espefuse.py burn_efuse SECURE_VERSION 0x01

# 5. Disable JTAG (physical debug access)
espefuse.py burn_efuse DIS_PAD_JTAG 1
espefuse.py burn_efuse DIS_DOWNLOAD_JTAG 1

# 6. Disable download mode (UART flashing)
espefuse.py burn_efuse DIS_DOWNLOAD_MODE 1

# 7. Enable Secure Boot (IRREVERSIBLE — after this, only signed firmware boots)
espefuse.py burn_efuse SECURE_BOOT_EN 1

# 8. Enable Flash Encryption (IRREVERSIBLE — encrypts all flash on next boot)
#    On ESP32-S3, use esp_flash_encrypt from IDF (it handles FLASH_CRYPT_CNT correctly)
#    OR manually: espefuse.py burn_efuse FLASH_CRYPT_CNT 0xFF
esp_flash_encrypt
```

**For ESP32-C3 (SHE-R4):** Same sequence, but BLOCK_KEY2 (Ed25519 OTA pubkey) is NOT available on C3 — C3 has fewer eFuse key blocks. Instead, the Ed25519 pubkey is compiled into firmware (protected by Secure Boot, which prevents firmware substitution). This is a known C3 limitation, documented in ADR-012.

**Docs that must align:** V3-SECURITY-MODEL.md §5 (authoritative), V3-FACTORY-OPS.md §6.1

---

### P0-4: Anti-rollback eFuse math

**Canonical facts:**
- `SECURE_VERSION` is a 32-bit field with **popcount semantics** (each set bit = one version increment)
- Maximum: **32 versions** (not 4 billion)
- Once a bit is burned, it cannot be cleared (irreversible)

**Strategy:**
- Burn 1 bit per **major security release** (not every minor release)
- At 2 major security releases/year → 16-year budget (sufficient for 10-year device lifetime)
- Minor releases use **signed version comparison** in firmware (not eFuse)
- The bootloader compares the firmware's signed version against `SECURE_VERSION` eFuse — if firmware version < popcount(SECURE_VERSION), boot is rejected

**When to burn a bit:** Only for security-critical fixes (CVE patches, auth bypass fixes). Document each burn in `V3-SECURITY-CHANGELOG.md`.

**Docs that must align:** V3-SECURITY-MODEL.md §5.3 (authoritative), ADR-013

---

### P0-5: RLS bypass mechanism

**Canonical decision:** Use a **custom GUC checked by the RLS policy itself** (not BYPASSRLS, not a fictional `app.bypass_rls` GUC).

**RLS policy (every tenant-scoped table):**
```sql
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON nodes
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );
```

**Spring Boot `TenantContextFilter` (per request):**
```java
// For ALL users: set tenant_id
connection.createStatement().execute(
  "SET LOCAL app.tenant_id = '" + tenantId + "'"
);

// For PLATFORM_ADMIN / SUPER_ADMIN only: set bypass flag
if (user.hasRole(PLATFORM_ADMIN) || user.hasRole(SUPER_ADMIN)) {
  connection.createStatement().execute(
    "SET LOCAL app.is_platform_admin = 'on'"
  );
} else {
  connection.createStatement().execute(
    "SET LOCAL app.is_platform_admin = 'off'"
  );
}
```

**Why this works:**
- `current_setting('app.is_platform_admin', true)` returns `false` if the GUC is unset (the `true` = missing_ok)
- The RLS policy itself checks the flag — no BYPASSRLS privilege needed
- `she_app` role does NOT need BYPASSRLS (safer — no privilege escalation)
- Auditable: the GUC is set per-transaction, logged in `pg_stat_statements`

**Docs that must align:** V3-SECURITY-MODEL.md §10 (authoritative), V3-ARCHITECTURE.md §5.1, V3-DATABASE-DESIGN.md §4+§8, V3-CONFIGURATION.md §2.1.2+§5.1

---

## P1 — Major Fixes

### P1-1: Proof-of-Possession (PoP)

**Canonical:** Factory-generated random 9-digit CSPRNG number, stored in `fctry` NVS, printed on QR code sticker. App scans QR to get PoP. Used during BLE provisioning for user-node mapping.

**All other definitions (MAC-based, HMAC-based, 8-char alphanumeric) are WRONG.**

---

### P1-2: BLE Service UUID

**Canonical:** `0000ffff-0000-1000-8000-00805f9b34fb`

---

### P1-3: BLE provisioning endpoint

**Canonical:** `POST /api/v3/nodes/claim` (NOT `/api/v3/devices/claim`)

---

### P1-4: WebSocket events

**Canonical (aligns with V3-API-SPECIFICATION.md):**
- Path: `/ws/v3`
- Subprotocol: `bearer.<jwt>` (dot separator)
- Events: `node.state`, `node.telemetry`, `node.presence`, `ota.progress`
- (Mobile app doc must be updated to match)

---

### P1-5: Flash Encryption enable

**Canonical:** Use `esp_flash_encrypt` from ESP-IDF (handles platform differences correctly). On ESP32-S3, this sets `FLASH_CRYPT_CNT` to `0xFF` (all 8 bits). Do NOT manually burn `0x7F`.

---

### P1-6: JWT algorithm

**Canonical:** Switch from HS256 to **EdDSA (Ed25519)** with `kid` header for multi-key rotation. Spring Boot accepts a set of public keys during rotation window (no forced re-login).

---

### P1-7: eFuse field names (ESP32-S3, standard)

**Canonical (from `espefuse.py summary` on ESP32-S3):**
- `DIS_PAD_JTAG` (not `JTAG_DISABLE`)
- `DIS_DOWNLOAD_JTAG`
- `DIS_DOWNLOAD_MODE` (not `UART_DOWNLOAD_DIS`)
- `DIS_USB_JTAG`
- `DIS_DOWNLOAD_MANUAL_ENCRYPT`
- `DIS_DIRECT_BOOT`
- `SECURE_BOOT_EN`
- `SECURE_VERSION`
- `FLASH_CRYPT_CNT`

---

### P1-8: RSA-2048 device certs — resolved by P0-2

Device certs are now **ECDSA P-256, 5-year validity**. RSA-2048 is no longer used for device certs.

---

### P1-9: ESP32-C3 RSA acceleration — resolved by P0-2

ECDSA P-256 is used (not RSA), so C3's lack of RSA hardware is no longer an issue.

---

### P1-10: Backend MQTT superuser

**Canonical:** Remove blanket ACL bypass. Spring Boot connects with a **client cert** (not username/password) and has an **explicit ACL** listing allowed topics:
- Subscribe: `she/+/+/+/+/telemetry`, `she/+/+/+/+/status`, `she/+/+/+/+/params/local`, `she/+/+/+/+/energy`, `she/+/+/+/+/ota/status`
- Publish: `she/+/+/+/+/command`, `she/+/+/+/+/params/remote`, `she/+/+/+/+/ota/url`

No blanket bypass. If Spring Boot is compromised, it can command devices — but only within the documented topic structure (auditable).

---

### P1-11: EMQX HTTP auth backend — Spring Boot dependency

**Canonical:** Configure EMQX auth cache TTL to **300 seconds** (5 minutes, not the default 60s). If Spring Boot is down, devices with cached auth can still reconnect for up to 5 minutes. For longer outages, EMQX falls back to cert-fingerprint-only auth (validates the cert chain without calling Spring Boot, but doesn't check revocation — acceptable for short outages).

**Config (EMQX 5.x HOCON):**
```hocon
authentication {
  cache { ttl = 300s }
  mechanism = password_based
  backend = http
  method = post
  url = "http://spring-boot:8080/internal/mqtt/auth"
  ...
}
```

---

### P1-12: C snprintf bug in V3-FIRMWARE.md §9.1

**Canonical fix:**
```c
snprintf(payload, sizeof(payload),
    "{\"voltage\":%.1f,\"current\":%.2f,\"power\":%.1f,"
    "\"energy_wh\":%.2f,\"frequency\":%.1f,\"pf\":%.2f}",  // FIXED: added % before .1f and .2f
    voltage, current, power, energy_wh, frequency, pf);
```

Also: energy topic QoS is **0** (per V3-MQTT-STANDARDS.md), not QoS 1.

---

### P1-13: LWT payload format

**Canonical:** LWT payload is JSON: `{"status":"offline"}`. Spring Boot parses JSON, not plain string. V3-MQTT-STANDARDS.md §6.3 is updated to match.

---

### P1-14: BOM reconciliation

**Canonical (SHE-R8):** Recalculated line-item sum = **$32.47** (was incorrectly stated as $31.97). Update V3-HARDWARE.md §7.2 and V3-UNIT-ECONOMICS.md to reflect $32.47.

| Component | Cost |
|---|---|
| ESP32-S3-WROOM-1-N8 | $4.20 |
| PCF8574 | $0.45 |
| 8x Songle relay | $4.40 |
| 16x PC817 optocoupler | $1.28 |
| PZEM-004T v3 | $3.80 |
| HLK-5M05 AC-DC | $1.90 |
| AMS1117-3.3 | $0.12 |
| USB-C receptacle | $0.35 |
| CP2102N | $0.85 |
| SCT-013-100A | $2.10 |
| MOV 275V | $0.25 |
| Fuse 5A | $0.10 |
| 9x WAGO connectors | $3.60 |
| Capacitors (25) | $0.75 |
| Resistors (40) | $0.40 |
| 8x 1N4007 diodes | $0.32 |
| 10x LEDs | $0.60 |
| 2x switches | $0.20 |
| PCB (4-layer ENIG) | $2.80 |
| Enclosure | $1.50 |
| Assembly + testing | $2.20 |
| **TOTAL BOM** | **$32.47** |
| Shipping (Djibouti→Addis) | $0.80 |
| Customs duty (15%) | $4.99 |
| **Total delivered cost** | **$38.26** |
| Sale price (wholesale) | $75.00 |
| **Gross margin** | **49.0%** |

---

### P1-15: PCF8574 chip count

**Canonical:**
- SHE-R4: **1 chip** (4 of 8 channels used)
- SHE-R8: **1 chip** (8 of 8 channels used)
- SHE-R16: **2 chips** (16 of 16 channels used, addresses 0x20 + 0x21)

V3-DEVICE-MODEL.md had wrong counts (2 for R8, 4 for R16) — corrected.

---

### P1-16: Cloudflare plan + cost

**Canonical:** Cloudflare **Business** plan, **$250/month**. (Architecture doc had "$25/mo" which is Pro price — corrected.)

---

### P1-17: Monthly hosting cost reconciliation

**Canonical:** Total infra cost = **$2,060/month** (reconciled):
- Ethio Telecom Cloud VPS (5 servers): $1,500
- Cloudflare Business: $250
- Chapa payment fees: ~$100 (variable)
- DNS + domain: $20
- Monitoring (PagerDuty, etc.): $190
- **Total: $2,060/mo**

Break-even MRR (at 60% gross margin on subscription): **$3,433/mo** (was $2,500 — updated in V3-UNIT-ECONOMICS.md).

---

### P1-18: DR site location

**Canonical:** DR site in **Adama** (160km from Addis Ababa, same Ethiopian Rift seismic zone — acknowledged limitation). Dire Dawa is **V3.1** (different seismic zone, 400km away).

Note: Adama being in the same seismic zone as Addis is a known risk. Full DR to Dire Dawa (different seismic zone) is a V3.1 deliverable.

---

### P1-19: Audit log retention

**Canonical:**
- Storage: **TimescaleDB hypertable** (NOT pg_partman)
- 30 days raw, 2 years compressed, 7 years CSV archive (S3)
- Table: `audit_log` with `hash` + `prev_hash` columns (hash chain for tamper-evidence)

---

### P1-20: Energy table name + columns

**Canonical:**
- Table: `device_energy_readings`
- Power column: `power_w`
- Time column: `time`

V3-ARCHITECTURE.md §5.2 (had `energy_readings` / `power` / `ts`) is corrected.

---

### P1-21: Energy data retention

**Canonical:** **365 days** (not 13 months / 395 days). All docs updated.

---

### P1-22: CRL refresh interval

**Canonical:** CRL refreshed **every 6 hours** (not 24h). Revocation SLA: **<6 hours** (not <5 min). If emergency revocation is needed, push CRL ad-hoc + restart EMQX auth cache.

V3-SUCCESS-METRICS.md "Cert revocation latency < 5 min" is changed to "Cert revocation propagation < 6 hours (CRL refresh interval)".

---

### P1-23: Root CA validity

**Canonical:** Root CA = **RSA 4096-bit, 20 years** (not 25). V3-FACTORY-OPS.md corrected.

---

### P1-24: HSM for intermediate CA

**Canonical:** Intermediate CA key is **HSM-backed** (YubiHSM 2) in production. step-ca integrates with YubiHSM 2 via PKCS#11. Root CA key is air-gapped (offline laptop, brought online only for intermediate rotation).

V3-SECURITY-MODEL.md §3.1 (had "KEK-encrypted at rest") is corrected to "HSM-backed (YubiHSM 2)".

---

### P1-25: Java version

**Canonical:** **Java 21 LTS** (not Java 17). V3-DEVELOPER-SETUP.md corrected.

---

### P1-26: PoP format

**Canonical:** **9-digit numeric** (not 8-char alphanumeric). V3-MOBILE-APP.md corrected.

---

### P1-27: Ed25519 OTA pubkey location

**Canonical:** Burned into eFuse `BLOCK_KEY2` (KEY_PURPOSE = USER) on ESP32-S3. **NOT compiled into firmware** (firmware-embedded pubkey can be substituted if attacker flashes new bootloader — eFuse is immutable).

For ESP32-C3 (SHE-R4): C3 has fewer key blocks, so Ed25519 pubkey is compiled into firmware BUT protected by Secure Boot v2 (which prevents firmware substitution). This is a documented C3 tradeoff (ADR-012).

V3-FIRMWARE.md §6.2 is corrected to reference the eFuse on S3, firmware-embedded on C3.

---

### P1-28: SECURE_VERSION burn location

**Canonical:** Initial value (0x01) burned at **factory**. Subsequent burns happen **on OTA** (bootloader burns the next bit after successful OTA of a security-critical release). V3-FIRMWARE.md corrected.

---

### P1-29: Backend alerting tool

**Canonical:** **PagerDuty** (not Telegram). V3-ARCHITECTURE.md corrected. Ops cost includes PagerDuty Business plan (~$21/user/mo, 3 users = $63/mo — included in the $190 monitoring line item).

---

### P1-30: Cloudflare APNs IP whitelist

**Canonical:** **Remove the APNs whitelist rule.** APNs is a push service — Apple does not make inbound HTTP callbacks to your origin. The rule was dead weight whitelisting 16M Apple corporate IPs. If delivery receipts are needed, configure a URL in the APNs payload (app-server endpoint, not Cloudflare WAF rule).

---

### P1-31: SHE office VPN Cloudflare rule

**Canonical:** Use the **office's public NAT egress IP** (e.g., `197.156.78.42` — Ethio Telecom assigned), not the private `10.88.0.0/16` range. Cloudflare sees public IPs, not private ranges.

---

### P1-32: EMQX authorization config

**Canonical (EMQX 5.x HOCON, not flattened env vars):**
```hocon
authorization {
  sources = [
    {
      type = file
      enable = true
      rules = [
        # Backend service (cert-based)
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/telemetry" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/+/status" }
        { permission = allow, action = publish, topic = "she/+/+/+/+/command" }
        # Devices (cert-based, per-device ACL via cert CN)
        { permission = allow, action = publish, topic = "she/+/+/+/${clientid}/telemetry" }
        { permission = allow, action = publish, topic = "she/+/+/+/${clientid}/status" }
        { permission = allow, action = subscribe, topic = "she/+/+/+/${clientid}/command" }
      ]
    }
  ]
}
```

Configure via `EMQX_AUTHORIZATION__SOURCES` env var (JSON) or `cluster-override.conf` file. V3-CONFIGURATION.md updated with correct HOCON example.

---

## P2 — Follow-up review fixes (round 2)

### P2-1: JWT algorithm consistency across ALL docs

**Issue:** V3-ARCHITECTURE.md lines 73 + 508 still said `JWT (HS256)` while V3-SECURITY-MODEL.md, V3-CONFIGURATION.md, and this doc specified EdDSA/Ed25519.

**Resolution:** Both references in V3-ARCHITECTURE.md corrected to `JWT (EdDSA/Ed25519, kid rotation)`. Grep-verified: zero `HS256` references remain outside of intentional "replaced by" context in CANONICAL-DECISIONS.md + V3-CONFIGURATION.md.

### P2-2: KEK single-point-of-failure acknowledged as tech debt

**Issue:** Secrets management was presented as "solved" (env vars + one KEK + HSM for CA), but the KEK itself is a single point of catastrophic exposure. KEK rotation re-encrypts everything with one shared key.

**Resolution:** Added V3-CONFIGURATION.md §7.2 "Tech debt: KEK as single point of failure" — honestly flags this as workable-at-V3-scale but NOT a solved problem. Documents: (a) why it's acceptable for V3 GA, (b) why it's tech debt (dual-key exposure window, no per-secret ACL, no access audit), (c) V3.1+ migration path to HashiCorp Vault / AWS Secrets Manager, (d) triggers for migration (team >5, devices >10k, incident, SOC 2 requirement).

### P2-3: factory_audit_log vs audit_log partitioning explained

**Issue:** `factory_audit_log` uses `pg_partman` (quarterly native partitions) while `audit_log` uses a TimescaleDB hypertable with tamper-evident hash chain. A future engineer might "fix" this into inconsistency.

**Resolution:** Added a comparison table in V3-FACTORY-OPS.md explaining why the two audit tables intentionally use different partitioning strategies: factory audit is a trusted environment (no hash chain needed, bursty writes, batch lookups → pg_partman is sufficient); runtime audit needs tamper-evidence + continuous aggregates + compression (→ TimescaleDB). Explicit note: "Do not 'fix' these two tables to use the same partitioning strategy — they are intentionally different."

### P2-4: Payment idempotency moved to Postgres as source of truth

**Issue:** Redis AOF every 1s (no fsync) creates a 1-second data-loss window. For sessions/rate-limit/non-payment idempotency this is acceptable (rebuildable). For payment idempotency during Chapa webhook bursts, a 1-second loss could cause duplicate payment processing — real money impact.

**Resolution:**
- V3-API-SPECIFICATION.md §1: Idempotency row updated to "two-tier" — Redis cache for non-payment, **Postgres `UNIQUE(idempotency_key, tenant_id)` constraint on `payments` table** for payment idempotency
- V3-PAYMENTS.md §6.4 (new): Full flow documented — Redis pre-check (fast path) → Postgres INSERT with UNIQUE constraint (source of truth) → Redis cache populate. Schema included.
- V3-ARCHITECTURE.md §2 + §5.3: Redis component row + persistence note updated — "non-payment idempotency keys" + explicit callout that payment idempotency is Postgres, not Redis

---

## Cleanup items

- **Dates:** All "Last updated: 2024-Q4" → "Last updated: 2025-Q1"
- **"10/10" self-rating:** Removed from V3-README.md
- **New docs needed (V3.1):** DR runbook, SBOM/supply chain, mobile store compliance, she-admin CLI distribution — listed in V3-ROADMAP.md as V3.1 deliverables

---

## How to use this doc

Every V3 doc that references a security decision, cert model, eFuse, RLS, PoP, BLE UUID, WebSocket event, cost figure, or retention period MUST cite this file as the canonical source. If a doc contradicts this file, this file wins.
