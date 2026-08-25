# V3 — Factory Operations

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Hardware Lead + Lead Engineer

---

## 1. Purpose

This document defines the end-to-end factory workflow for SHE V3 devices: certificate generation, factory flashing, provisioning QR code printing, QC testing, audit logging, and recovery. The workflow is designed for a single workstation operator to process **100 units/day** at a **90-second test cycle per unit**.

The factory operations bridge two systems:

1. **step-ca CA** — issues per-device X.509 certs (CN = MAC) signed by the SHE intermediate CA
2. **Spring Boot** — records the cert → node_id mapping via `/internal/factory/register-cert` (V3-API-SPECIFICATION.md §15)

All cert generation + flash events are logged to the `factory_audit_log` table with 10-year retention (PDPP + ECA compliance — V3-PRIVACY-COMPLIANCE.md).

---

## 2. Pre-requisites

### 2.1 step-ca CA

A running `step-ca` instance (the SHE intermediate CA) on the factory workstation or a dedicated CA server. See `V3-CONFIGURATION.md` §2 for setup.

```bash
# Verify step-ca is running
step ca health --ca-url https://ca.she.et:9000 --root /etc/step-ca/certs/root_ca.crt
# → {"status":"ok"}
```

Required CA artifacts:

| Artifact | Path | Notes |
|---|---|---|
| Root CA cert | `/etc/step-ca/certs/root_ca.crt` | Self-signed, RSA 4096-bit, **20-year validity** |
| Intermediate CA cert | `/etc/step-ca/certs/intermediate_ca.crt` | Signed by root, RSA 4096-bit, 10-year validity |
| Intermediate CA key | `/etc/step-ca/secrets/intermediate_ca_key` | **HSM-backed (YubiHSM 2)** in production via PKCS#11 |
| Provisioner password | `$STEP_CA_PROVISIONER_PASSWORD` env var | Used by `step ca sign` CLI (signs CSRs from devices) |

### 2.2 Admin CLI

The SHE Admin CLI (`she-admin`) wraps `step` + `esptool` + factory REST calls in a single tool:

```bash
# Install
pipx install she-admin==1.4.0

# Configure
she-admin config set --ca-url https://ca.she.et:9000 \
                     --api-url https://api.she.et \
                     --factory-token <long-lived-factory-jwt>

# Verify
she-admin factory doctor
# → CA: ok
# → API: ok
# → esptool: v4.7.0
# → QR generator: ok
```

### 2.3 Factory workstation hardware

| Item | Specification | Notes |
|---|---|---|
| Workstation PC | x86_64, Ubuntu 22.04 LTS, 16GB RAM | Lockdown profile, no internet browsing |
| USB-to-serial adapter | FT232RL or CP2102N | 3.3V logic level |
| ESP32 flashing jig | Custom pogo-pin fixture (6-pin: 3V3, GND, TX, RX, EN, GPIO0) | Holds PCB during flash + test |
| Test load board | 8× 10W LED bulbs + relay test points | For PZEM + relay QC |
| Label printer | Brother QL-820NWB | For QR code + serial number sticker |
| USB hub | Powered, 7-port | For parallel flashing (up to 4 units) |

### 2.4 ESP32 flashing toolchain

```bash
# esptool (Python)
pip install esptool==4.7.0

# Verify
esptool.py version
# → 4.7.0
```

---

## 3. Per-device cert generation (on-chip keypair)

**Canonical model (P0-1, P0-2):** ESP32 generates its ECDSA P-256 keypair **on-chip** using mbedTLS. The private key is written to the `fctry` NVS partition (encrypted via Flash Encryption) and **NEVER leaves the device**. The factory workstation reads the CSR from the ESP32 over USB serial, sends it to step-ca, and returns the signed cert to the ESP32. **The factory NEVER has the private key.**

### 3.1 Per-device flow

For a batch of N devices, the Admin CLI drives the per-unit CSR → sign → return-to-device flow (4 devices in parallel, bounded by workstation CPU + USB hub bandwidth):

```bash
she-admin factory generate-certs \
    --batch-id 2024-12-BATCH-001 \
    --sku SHE-R8 \
    --count 100 \
    --mac-range 24:6F:28:00:00:00-24:6F:28:00:00:63 \
    --output-dir /factory/batches/2024-12-BATCH-001/
```

Per-device, the Admin CLI:

1. Connects to the ESP32 over USB serial (factory mode firmware).
2. ESP32 (firmware) calls `mbedtls_ecdsa_genkey()` → generates ECDSA P-256 keypair in RAM.
3. ESP32 writes the private key to `fctry` NVS partition (encrypted via Flash Encryption).
4. ESP32 generates a PKCS#10 CSR with `CN = {MAC_ADDRESS}`.
5. Admin CLI reads the CSR from the ESP32 over USB serial.
6. Admin CLI sends the CSR to step-ca:
   ```bash
   step ca sign /tmp/246F28AABBCC_csr.pem \
       --ca-url https://ca.she.et:9000 \
       --root /etc/step-ca/certs/root_ca.crt \
       --provisioner factory-provisioner \
       --provisioner-password-file /etc/step-ca/provisioner_password \
       --not-after 43800h   # 5-year validity
   ```
7. step-ca signs the cert (intermediate CA, ECDSA P-256, 5-year validity).
8. Admin CLI returns the signed cert to the ESP32 over USB serial.
9. ESP32 stores the cert in `fctry` NVS.
10. Admin CLI logs `cert_serial` + `cert_fingerprint` + `mac` in the batch manifest + `factory_audit_log`. **No private key is ever stored on the workstation.**

Each cert has:

- **CN (Common Name):** MAC address (e.g., `24:6F:28:AA:BB:CC`)
- **SAN:** `DNS:SHE-R8-AABBCC` (matches `node_id` in V3-DEVICE-MODEL.md §2.2)
- **Validity:** 5 years (devices are expected to be returned for cert renewal — see §8)
- **Key type:** **ECDSA P-256** — generated on-chip, private key never leaves the device. ECDSA P-256 is used (not RSA-2048) because: (1) ESP32-C3 has no RSA hardware acceleration, (2) NIST SP 800-57 recommends ≥3072-bit RSA for protection beyond 2030, (3) ECDSA P-256 verify is ~50 ms on C3 vs 200-400 ms for RSA-2048.

> **Cross-ref:** `V3-SECURITY-MODEL.md` §3.2 (authoritative source) and `CANONICAL-DECISIONS.md` P0-1.

### 3.2 Output structure

```
/factory/batches/2024-12-BATCH-001/
├── manifest.json                 # Batch manifest (batch_id, sku, count, mac list)
├── certs/
│   ├── 246F28AABBCC_cert.pem     # X.509 cert (CN = MAC) — public, signed by step-ca
│   ├── 246F28AABBDD_cert.pem
│   └── ...
├── csrs/
│   ├── 246F28AABBCC_csr.pem      # PKCS#10 CSR (read from ESP32 over USB serial)
│   └── ...
├── pops/
│   ├── 246F28AABBCC_pop.txt      # 9-digit numeric PoP (proof of possession)
│   └── ...
└── qrcodes/
    ├── 246F28AABBCC_qr.png       # QR code (see §4)
    └── ...
```

> **Note:** There is **no `keys/` directory** — the ECDSA P-256 private key is generated on-chip by the ESP32 and never leaves the device. The factory workstation only ever sees the CSR and the signed cert.

The PoP is generated per-device as a cryptographically-random **9-digit numeric** number (CSPRNG) and never reused. It is the BLE provisioning PoP (V3-FIRMWARE.md §5).

### 3.3 Batch manifest

```json
{
  "batch_id": "2024-12-BATCH-001",
  "sku": "SHE-R8",
  "count": 100,
  "mac_range": ["24:6F:28:00:00:00", "24:6F:28:00:00:63"],
  "generated_at": "2024-12-15T08:00:00Z",
  "generated_by": "factory-operator-01",
  "ca_fingerprint": "sha256:abc123...",
  "key_generation": "on-chip (ESP32 mbedTLS ECDSA P-256) — private key never exported",
  "certs": [
    {
      "mac": "24:6F:28:AA:BB:CC",
      "node_id": "SHE-R8-AABBCC",
      "csr_path": "csrs/246F28AABBCC_csr.pem",
      "cert_path": "certs/246F28AABBCC_cert.pem",
      "pop_path": "pops/246F28AABBCC_pop.txt",
      "qr_path": "qrcodes/246F28AABBCC_qr.png",
      "cert_serial": "5A:7B:8C:9D:...",
      "cert_fingerprint": "sha256:def456...",
      "cert_expires_at": "2029-12-15T08:00:00Z"
    }
  ]
}
```

---

## 4. QR code generation

Each device gets a QR code printed on a sticker applied to the enclosure. The QR code contains a JSON payload with everything the mobile app needs to start BLE provisioning:

```json
{
  "ver": 1,
  "name": "SHE-R8-AABBCC",
  "pop": "482917305",
  "transport": "ble",
  "mac": "24:6F:28:AA:BB:CC",
  "sku": "SHE-R8",
  "url": "https://she.et/setup/SHE-R8-2024-00142"
}
```

| Field | Purpose |
|---|---|
| `ver` | QR payload schema version (for future compatibility) |
| `name` | BLE advertisement name (matches `node_id`) |
| `pop` | Proof-of-possession for BLE provisioning (V3-FIRMWARE.md §5) |
| `transport` | `ble` (V3) — future: `wifi-softap` |
| `mac` | For mDNS / local control PoP derivation |
| `sku` | For app to render correct device-type UI |
| `url` | Deep-link to setup page (Amharic + English quick-start) |

The QR is generated as a 300×300 PNG with error correction level H (30% redundancy — survives scratches on the enclosure). The sticker is 25×25mm weatherproof polyester.

```bash
she-admin factory generate-qrcodes \
    --batch-id 2024-12-BATCH-001 \
    --output-dir /factory/batches/2024-12-BATCH-001/qrcodes/ \
    --size 300 \
    --error-correction H
```

---

## 5. Cert registration

Before flashing, the cert → node_id mapping is recorded in the Spring Boot database via `/internal/factory/register-cert`:

### 5.1 Endpoint

```
POST /internal/factory/register-cert
Authorization: Bearer <factory-jwt>
Content-Type: application/json

{
  "batch_id": "2024-12-BATCH-001",
  "mac": "24:6F:28:AA:BB:CC",
  "node_id": "SHE-R8-AABBCC",
  "sku": "SHE-R8",
  "cert_pem": "-----BEGIN CERTIFICATE-----\n...",
  "cert_serial": "5A:7B:8C:9D:...",
  "cert_fingerprint": "sha256:def456...",
  "cert_expires_at": "2029-12-15T08:00:00Z",
  "pop_hash": "sha256:...",  // PoP hash (NOT the PoP itself — that's in fctry NVS only)
  "hardware_revision": "rev-c"
}
```

Response:

```json
{
  "data": {
    "node_db_id": "550e8400-e29b-41d4-a716-446655440000",
    "registered_at": "2024-12-15T08:00:00Z",
    "status": "PRE_PROVISIONED"
  }
}
```

Spring Boot:

1. Verifies the cert against the SHE CA (intermediate)
2. Inserts a row into `device_certs` (cert_serial, fingerprint, expiry, status = `PRE_PROVISIONED`)
3. Inserts a row into `nodes` with `tenant_id = NULL` (device is not yet claimed by any user — will be set during BLE provisioning)
4. Returns the `node_db_id` for audit trail

### 5.2 Bulk registration

```bash
she-admin factory register-certs \
    --batch-id 2024-12-BATCH-001 \
    --api-url https://api.she.et
# → Registered 100/100 certs
# → Failed: 0
```

This reads the batch manifest and POSTs each cert to `/internal/factory/register-cert` in parallel batches of 10.

---

## 6. Factory flashing

### 6.1 Flashing sequence

The factory operator places a bare PCB into the pogo-pin jig and runs:

```bash
she-admin factory flash \
    --mac 24:6F:28:AA:BB:CC \
    --batch-id 2024-12-BATCH-001 \
    --firmware /factory/firmware/v1.4.2-r8.bin \
    --fctry-nvs-template /factory/templates/r8_fctry.csv \
    --port /dev/ttyUSB0 \
    --baud 921600
```

This performs 3 operations:

#### Step 1: Generate fctry NVS partition (PoP + metadata only — NO cert, NO private key)

The Admin CLI generates a CSV file for the `fctry` NVS partition containing only the PoP + device metadata. **The cert and private key are NOT in this CSV** — they are written to `fctry` NVS later by the ESP32 firmware itself during the §3 on-chip keypair generation + CSR signing flow:

```csv
# fctry_nvs_246F28AABBCC.csv
key,type,encoding,value
node_id,data,string,SHE-R8-AABBCC
mac,data,string,24:6F:28:AA:BB:CC
sku,data,string,SHE-R8
hardware_rev,data,string,rev-c
serial,data,string,SHE-R8-2024-00142
pop,data,string,482917305
mqtt_broker,data,string,mqtts://mqtt-factory.she.et:8883
api_base_url,data,string,https://api.she.et
manufactured_at,data,string,2024-12-15T08:30:00Z
```

> **Note:** `cert_pem` and `key_pem` are intentionally absent. The ESP32 firmware will:
> 1. Generate the ECDSA P-256 private key on-chip (via `mbedtls_ecdsa_genkey()`) and write it to `fctry` NVS.
> 2. Generate a CSR, send it to the factory workstation over USB serial.
> 3. Receive the signed cert back from the factory workstation (via step-ca) and write it to `fctry` NVS.
>
> The factory workstation never has the private key, and never writes the cert via `esptool` — that would erase the private key the ESP32 just generated.

Then converts it to a binary NVS image:

```bash
python -m esp_idf_nvs_partition_util \
    --input /tmp/fctry_nvs_246F28AABBCC.csv \
    --output /tmp/fctry_nvs_246F28AABBCC.bin \
    --size 0x10000
```

#### Step 2: Flash firmware + fctry NVS

```bash
# Erase flash (clean slate)
esptool.py --port /dev/ttyUSB0 erase_flash

# Flash bootloader
esptool.py --port /dev/ttyUSB0 --baud 921600 \
    write_flash 0x0 /factory/firmware/v1.4.2-r8_bootloader.bin

# Flash partition table
esptool.py --port /dev/ttyUSB0 --baud 921600 \
    write_flash 0x8000 /factory/firmware/v1.4.2-r8_partitions.bin

# Flash application (factory partition)
esptool.py --port /dev/ttyUSB0 --baud 921600 \
    write_flash 0x10000 /factory/firmware/v1.4.2-r8.bin

# Flash fctry NVS (PoP + metadata only — cert + key are written by ESP32 firmware during factory mode)
esptool.py --port /dev/ttyUSB0 --baud 921600 \
    write_flash 0x510000 /tmp/fctry_nvs_246F28AABBCC.bin

# Burn eFuses in canonical order (see V3-SECURITY-MODEL.md §5.7 + CANONICAL-DECISIONS.md P0-3)
# 1. Burn Secure Boot key (AES-256, used for Secure Boot v2 digest)
espefuse.py --port /dev/ttyUSB0 burn_key BLOCK_KEY0 secure_boot_key.bin SECURE_BOOT_DIGEST

# 2. Burn Flash Encryption HMAC key (used for flash encryption + NVS encryption)
espefuse.py --port /dev/ttyUSB0 burn_key BLOCK_KEY1 flash_enc_key.bin HMAC_DOWN_ENCRYPT

# 3. Burn Ed25519 OTA verification public key (immutable, used for OTA signature verify)
espefuse.py --port /dev/ttyUSB0 burn_key BLOCK_KEY2 ota_ed25519_pubkey.bin USER

# 4. Set initial SECURE_VERSION (anti-rollback, popcount semantics — initial value 0x01)
espefuse.py --port /dev/ttyUSB0 burn_efuse SECURE_VERSION 0x01

# 5. Disable JTAG (physical debug access)
espefuse.py --port /dev/ttyUSB0 burn_efuse DIS_PAD_JTAG 1
espefuse.py --port /dev/ttyUSB0 burn_efuse DIS_DOWNLOAD_JTAG 1

# 6. Disable download mode (UART flashing)
espefuse.py --port /dev/ttyUSB0 burn_efuse DIS_DOWNLOAD_MODE 1

# 7. Enable Secure Boot v2 (IRREVERSIBLE — after this, only signed firmware boots)
espefuse.py --port /dev/ttyUSB0 burn_efuse SECURE_BOOT_EN 1

# 8. Enable Flash Encryption (IRREVERSIBLE — encrypts all flash on next boot)
#    On ESP32-S3, use esp_flash_encrypt from IDF (it handles FLASH_CRYPT_CNT correctly,
#    setting 0xFF on S3 — do NOT manually burn 0x7F).
#    For ESP32-C3, esp_flash_encrypt also handles platform differences correctly.
esp_flash_encrypt --port /dev/ttyUSB0
```

#### Step 3: Verify via serial monitor

```bash
# Reset + capture boot log (5 seconds)
she-admin factory verify-boot \
    --port /dev/ttyUSB0 \
    --timeout 5 \
    --expect "MQTT connected" \
    --expect "config published" \
    --expect "fctry NVS OK"
```

If all three expected lines appear in the boot log, the flash is marked successful. If any are missing, the unit is flagged for re-flash (see §8).

### 6.2 Factory broker

During factory flashing, the device connects to a **factory MQTT broker** (`mqtt-factory.she.et`) — separate from the production broker. This isolates pre-shipped devices from production traffic and lets the QC test verify MQTT connectivity without polluting production metrics.

The factory broker URL is in the `fctry` NVS as `mqtt_broker = mqtts://mqtt-factory.she.et:8883`. When the device is later provisioned by an end user, the BLE provisioning flow overwrites this with the production broker URL.

---

## 7. QC test

Every unit undergoes a 90-second QC test before being packed for shipment.

### 7.1 Test sequence

```bash
she-admin factory qc-test \
    --mac 24:6F:28:AA:BB:CC \
    --port /dev/ttyUSB0 \
    --test-load-board yes
```

| # | Test | Duration | Pass criteria |
|---|---|---|---|
| 1 | **Boot + MQTT connect** | 8s | Device boots, connects to factory broker within 8s, publishes `config` payload |
| 2 | **Cert validation** | 1s | EMQX auth backend accepts the cert (cert_fingerprint matches `device_certs` row) |
| 3 | **Relay click test** | 30s | Cycle each relay ON → OFF → ON; verify click sound + feedback circuit reads correctly |
| 4 | **PZEM reading test** (R8/R16 only) | 5s | Apply 220VAC test load, verify PZEM reports 220V ±5% + non-zero power |
| 5 | **Feedback circuit test** | 15s | For each channel: command OFF, verify feedback reads OFF; command ON, verify feedback reads ON |
| 6 | **Wi-Fi RSSI test** | 3s | Device reports RSSI ≥ -60dBm at 1m from factory AP |
| 7 | **BLE advertisement test** | 5s | Flutter app discovers device by name `SHE-R8-AABBCC` |
| 8 | **Memory + heap check** | 2s | `free_heap` ≥ 200KB (R8) / 250KB (R16) at idle |
| 9 | **Cert + PoP integrity** | 2s | Read `fctry` NVS, verify cert + key + PoP present + cert fingerprint matches DB |
| 10 | **Final report** | 1s | Generate `qc_report_246F28AABBCC.json` with pass/fail per test |

**Total:** ~72s test + ~18s handling = 90s per unit. With 2 parallel jigs, one operator processes ~80 units/hour → **~640 units/shift**, comfortably above the 100 units/day target.

### 7.2 QC report

```json
{
  "mac": "24:6F:28:AA:BB:CC",
  "node_id": "SHE-R8-AABBCC",
  "serial": "SHE-R8-2024-00142",
  "batch_id": "2024-12-BATCH-001",
  "tested_at": "2024-12-15T09:15:32Z",
  "tested_by": "factory-operator-01",
  "tests": [
    { "name": "boot_mqtt", "passed": true, "duration_ms": 7200 },
    { "name": "cert_validation", "passed": true },
    { "name": "relay_click", "passed": true, "channels": [0,1,2,3,4,5,6,7] },
    { "name": "pzem_reading", "passed": true, "voltage": 221.3, "current": 0.42 },
    { "name": "feedback_circuit", "passed": true, "channels_tested": 8 },
    { "name": "wifi_rssi", "passed": true, "rssi": -42 },
    { "name": "ble_advertisement", "passed": true },
    { "name": "memory_check", "passed": true, "free_heap_bytes": 248320 },
    { "name": "cert_pop_integrity", "passed": true },
    { "name": "final_report", "passed": true }
  ],
  "overall": "PASS",
  "firmware_version": "1.4.2",
  "hardware_revision": "rev-c"
}
```

### 7.3 Pack + ship

After QC PASS:

1. Apply QR code + serial number sticker (Brother QL-820NWB)
2. Apply green "PASSED" QC sticker
3. Place in anti-static bag + foam insert + retail box
4. Update `factory_audit_log` row with `qc_status = PASS, packed_at = now()`
5. Box moves to shipping pallet (20 units per carton — see `V3-HARDWARE.md` §7.4)

---

## 8. Audit trail

Every cert generation + flash event is logged to the `factory_audit_log` table with **10-year retention** (longer than the 2-year `audit_log` retention because factory events are needed for warranty + RMA investigations — see `V3-SUPPORT-RMA.md`).

### 8.1 Schema

```sql
CREATE TABLE factory_audit_log (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type      VARCHAR(30) NOT NULL,    -- CERT_GENERATED, FLASH_STARTED, FLASH_COMPLETED,
                                             -- QC_PASSED, QC_FAILED, CERT_REVOKED, REFLASHED
    batch_id        VARCHAR(50) NOT NULL,
    mac             VARCHAR(17) NOT NULL,
    node_id         VARCHAR(64) NOT NULL,
    sku             VARCHAR(20) NOT NULL,
    serial_number   VARCHAR(50),             -- assigned at pack time
    cert_serial     VARCHAR(64),
    cert_fingerprint VARCHAR(64),
    operator_id     VARCHAR(50) NOT NULL,    -- factory operator username
    workstation_id  VARCHAR(50) NOT NULL,    -- workstation hostname
    firmware_version VARCHAR(50),
    hardware_revision VARCHAR(20),
    qc_report       JSONB,                   -- full QC report (NULL if not yet tested)
    qc_status       VARCHAR(10),             -- PASS / FAIL / NULL
    failure_reason  TEXT,
    details         JSONB,                   -- additional context
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Partitioned by quarter for fast queries
CREATE EXTENSION IF NOT EXISTS pg_partman;
SELECT partman.create_parent('public.factory_audit_log', 'created_at', 'native', 'quarterly');
UPDATE partman.part_config
SET retention = '10 years', retention_keep_table = false
WHERE parent_table = 'public.factory_audit_log';

-- Indexes
CREATE INDEX ON factory_audit_log (batch_id, created_at DESC);
CREATE INDEX ON factory_audit_log (mac, created_at DESC);
CREATE INDEX ON factory_audit_log (node_id);
CREATE INDEX ON factory_audit_log (qc_status) WHERE qc_status IS NOT NULL;
CREATE INDEX ON factory_audit_log (event_type, created_at DESC);
```

Note: `factory_audit_log` is **NOT** tenant-scoped — devices are pre-tenant until claimed. RLS is therefore not applied. Access is restricted to `PLATFORM_ADMIN` + `TENANT_ADMIN` (post-claim, for support investigations).

**Why `factory_audit_log` uses `pg_partman` (quarterly native partitioning) while the runtime `audit_log` uses a TimescaleDB hypertable (P1-19):**

These are two different audit tables with two different threat models, and the partitioning strategy differs accordingly:

| Aspect | `factory_audit_log` (this table) | `audit_log` (V3-DATABASE-DESIGN.md §4.8) |
|---|---|---|
| **Partitioning** | `pg_partman`, quarterly native partitions | TimescaleDB hypertable |
| **Tamper-evidence** | Not required (factory is a trusted environment with physical access controls) | **Required** — `hash` + `prev_hash` + `sequence_number` columns form a tamper-evident hash chain (any in-place modification breaks the chain) |
| **Query pattern** | Batch lookups by `batch_id` / `mac` / `event_type` over 10-year window — partition pruning on `created_at` is sufficient | Time-range scans + continuous aggregates (monthly compliance reports) — TimescaleDB chunk exclusion + compression is optimized for this |
| **Retention** | 10 years (warranty + RMA investigations) | 30 days raw + 2 years compressed + 7 years CSV archive |
| **Write rate** | Bursty (100-500 rows/day during factory runs, 0 otherwise) | Continuous (every admin API call, every device command) |

TimescaleDB's hypertable model is overkill for the factory audit log — it adds compression overhead and the hash-chain columns are unnecessary in a trusted factory environment. Conversely, `pg_partman`'s simple quarterly partitions are insufficient for the runtime audit log, which needs tamper-evidence and continuous aggregates. **Do not "fix" these two tables to use the same partitioning strategy — they are intentionally different.**

### 8.2 Event types

| Event | When logged | Notes |
|---|---|---|
| `CERT_GENERATED` | After step-ca issues cert | Includes cert_serial, fingerprint, expiry |
| `CERT_REGISTERED` | After Spring Boot `/internal/factory/register-cert` returns 200 | Includes node_db_id |
| `FLASH_STARTED` | Before esptool erase_flash | Includes operator + workstation |
| `FLASH_COMPLETED` | After serial monitor verifies boot log | Includes firmware version burned |
| `QC_PASSED` | After all 10 QC tests pass | Includes full qc_report JSON |
| `QC_FAILED` | On any QC test failure | Includes failure_reason + failed test name |
| `CERT_REVOKED` | After step-ca cert revoke (recovery flow) | Includes revocation reason |
| `REFLASHED` | When a unit is re-flashed after QC fail | Links to original audit row via `details.original_audit_id` |
| `PACKED` | When unit is packed + sticker applied | Includes serial_number, carton_id |
| `SHIPPED` | When carton leaves factory | Includes tracking_number |

### 8.3 Audit query examples

```sql
-- Find all units from a batch that failed QC
SELECT mac, node_id, qc_report, failure_reason, created_at
FROM factory_audit_log
WHERE batch_id = '2024-12-BATCH-001' AND event_type = 'QC_FAILED'
ORDER BY created_at DESC;

-- Trace full lifecycle of one unit
SELECT event_type, created_at, operator_id, qc_status, details
FROM factory_audit_log
WHERE mac = '24:6F:28:AA:BB:CC'
ORDER BY created_at ASC;

-- Find all certs expiring in next 12 months (for renewal program)
SELECT mac, node_id, cert_serial, cert_fingerprint, details->>'cert_expires_at' AS expires_at
FROM factory_audit_log
WHERE event_type = 'CERT_GENERATED'
  AND details->>'cert_expires_at' < (now() + INTERVAL '12 months')::text
ORDER BY details->>'cert_expires_at';
```

---

## 9. Recovery (failed QC)

When a unit fails QC, the recovery flow depends on the failure type:

### 9.1 Re-flashable failures (firmware / NVS issue)

Failures like "MQTT connect timeout", "config not published", or "cert + PoP integrity" can be fixed by re-flashing:

```bash
she-admin factory reflash \
    --mac 24:6F:28:AA:BB:CC \
    --original-audit-id <uuid> \
    --reason "MQTT connect timeout" \
    --port /dev/ttyUSB0
```

This re-runs §6 (flash + verify) and creates a new `REFLASHED` audit entry. The original `FLASH_COMPLETED` row is preserved for traceability.

### 9.2 Hardware failures (relay / PZEM / feedback)

Failures like "relay click fail", "PZEM reading out of range", or "feedback circuit mismatch" indicate a hardware defect:

```bash
she-admin factory quarantine \
    --mac 24:6F:28:AA:BB:CC \
    --reason "Relay channel 3 click fail" \
    --disposition RMA
```

This:

1. Marks the unit as `QUARANTINED` in `factory_audit_log`
2. Revokes the cert via step-ca (see §9.3)
3. Moves the unit to the RMA bin for return to the PCB fabricator

### 9.3 Cert revocation

For quarantined + returned units, the cert is revoked so it cannot be used even if the hardware is salvaged:

```bash
# Revoke via step-ca
step ca revoke 5A:7B:8C:9D:... \
    --ca-url https://ca.she.et:9000 \
    --root /etc/step-ca/certs/root_ca.crt \
    --provisioner factory-provisioner \
    --reason "key_compromise"

# Notify Spring Boot to update device_certs.status = REVOKED
she-admin factory revoke-cert \
    --mac 24:6F:28:AA:BB:CC \
    --reason "QC failed - hardware defect"
```

EMQX periodically fetches the CRL (Certificate Revocation List) from step-ca and rejects connections from revoked certs (V3-SECURITY-MODEL.md §4.5).

### 9.4 Replacement unit

For each quarantined unit, a replacement is generated from the same batch (or a new batch if the original is exhausted):

```bash
she-admin factory generate-replacement \
    --for-mac 24:6F:28:AA:BB:CC \
    --original-audit-id <uuid>
```

This generates a new cert + new MAC + new PoP, registers it, and queues it for flashing. The replacement's `factory_audit_log` row references the original via `details.replaces_audit_id`.

---

## 10. Production rate

### 10.1 Target

| Metric | Target | Actual (target) |
|---|---|---|
| Units per workstation per day | 100 | 100-130 |
| Test cycle per unit | 90s | 72s test + 18s handling |
| Operator shift | 8 hours | 1 operator, 2 parallel jigs |
| Throughput per shift | 640 units max | ~250-300 typical (with breaks + setup) |

### 10.2 Bottlenecks

1. **PZEM test** (5s) — requires manual application of 220VAC test load; could be automated with relay-switched load board (planned for rev-d jig)
2. **Cert generation** (2s/unit) — bottlenecked by step-ca signing; addressed by bulk pre-generation (§3)
3. **Sticker printing** (3s/unit) — Brother QL-820NWB can print 1 sticker / 3s; parallel printers if needed

### 10.3 Scaling

For 500 units/day (B2B volume), the factory scales horizontally:

| Workstations | Units/day | Operators | Factory floor |
|---|---|---|---|
| 1 | 100 | 1 | 4 m² |
| 4 | 400 | 4 | 16 m² |
| 8 | 800 | 8 | 32 m² |

Each workstation has its own step-ca client + esptool + label printer; the shared resources are the CA server + Spring Boot API + MinIO firmware bucket. These handle 10+ concurrent workstation requests without degradation (benchmarked: 50 cert generations in 8s on a single step-ca instance).

---

## 11. Operator runbook (cheat sheet)

```
┌─────────────────────────────────────────────────────────────────┐
│  SHE V3 FACTORY OPERATOR — QUICK REFERENCE                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  DAILY STARTUP                                                  │
│  1. Power on workstation + jig + test load board                │
│  2. she-admin factory doctor          # verify all systems OK   │
│  3. she-admin factory pull-batch --sku SHE-R8 --count 100       │
│                                                                 │
│  PER-UNIT (90 seconds)                                          │
│  1. Place bare PCB in pogo-pin jig                              │
│  2. she-admin factory flash --mac <mac>                         │
│  3. she-admin factory qc-test --mac <mac>                       │
│  4. If PASS: print QR sticker + serial, apply to enclosure      │
│  5. Place in anti-static bag + retail box                       │
│  6. Repeat                                                      │
│                                                                 │
│  IF QC FAILS                                                    │
│  - Re-flashable: she-admin factory reflash --mac <mac>          │
│  - Hardware:    she-admin factory quarantine --mac <mac>        │
│                                                                 │
│  END OF SHIFT                                                   │
│  1. she-admin factory close-batch                               │
│  2. Print shift summary report                                  │
│  3. Move cartons to shipping pallet                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 12. References

- `V3-HARDWARE.md` §7 — manufacturing partner, BOM, test fixture, packaging
- `V3-SECURITY-MODEL.md` §4 — X.509 cert chain, step-ca CA setup, CRL
- `V3-CONFIGURATION.md` §2 — step-ca CA generation + provisioner setup
- `V3-FIRMWARE.md` §2.1 — `fctry` NVS partition layout
- `V3-FIRMWARE.md` §5 — BLE provisioning flow (consumes the PoP)
- `V3-FIRMWARE.md` §12 — Secure Boot + Flash Encryption (irreversible at factory)
- `V3-API-SPECIFICATION.md` §15 — `/internal/factory/register-cert` endpoint
- `V3-DATABASE-DESIGN.md` §8 — `factory_audit_log` table schema + retention
- `V3-SUPPORT-RMA.md` — warranty + RMA + return-to-factory flow
- `V3-PRIVACY-COMPLIANCE.md` — 10-year retention requirement for factory audit
- ADR-013 — firmware security (Secure Boot v2, Flash Encryption, anti-rollback)
- ADR-014 — factory flashing workflow (this document)
- step-ca docs: https://smallstep.com/docs/step-ca/
- esptool docs: https://docs.espressif.com/projects/esptool/
