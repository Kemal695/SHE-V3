# V3 — Security Model

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Security Reviewer

---

## 0. Scope

This document specifies the security architecture for the SHE V3 platform. It covers application security, multi-tenant RBAC, device authentication, MQTT broker security, **firmware security** (the most critical addition — was missing in the original draft), MFA, audit logging, secrets management, PDPP compliance, and threat model.

The architecture runs on ESP32-C3 (SHE-R4) and ESP32-S3 (SHE-R8 / SHE-R16), as defined in `V3-HARDWARE.md`. The device data model uses the RainMaker hierarchy — see `V3-DEVICE-MODEL.md`.

---

## 1. Application security (JWT)

### 1.1 Token specification

| Property | Value |
|---|---|
| Algorithm | **EdDSA (Ed25519)** — public key identified by `kid` header for multi-key rotation |
| Access token TTL | 15 min (all roles) |
| Refresh token TTL — USER | 30 days |
| Refresh token TTL — TENANT_ADMIN | 8 hours |
| Refresh token TTL — PLATFORM_ADMIN | 8 hours |
| Refresh token TTL — SUPER_ADMIN | 4 hours |
| Access token storage (client) | In-memory only (Flutter Riverpod provider, never persisted) |
| Refresh token storage (client) | Flutter secure storage (Keychain on iOS, EncryptedSharedPreferences on Android) |
| Rotation policy | Old refresh token `jti` blacklisted in Redis on every refresh, expires when access token would have expired |
| Revocation | JWT `jti` blacklist in Redis; refresh tokens revocable by user logout, admin force-logout, or password change |

**Multi-key rotation window:** Spring Boot accepts a **set** of Ed25519 public keys (each identified by `kid`) during a rotation window. Old tokens continue to validate against the previous `kid` until they expire; new tokens are signed with the new `kid`. **No forced re-login** for users during rotation. The active signing key + accepted verification keys are listed in a JWKS-like config (rotated quarterly — see §8.2).

### 1.2 JWT claims

```json
{
  "sub": "8a3b1c2e-...",            // user_id (UUID)
  "email": "user@example.et",
  "platform_role": "USER",          // USER | PLATFORM_ADMIN | SUPER_ADMIN
  "tenant_id": "6f1c...",            // null for pure B2C
  "tenant_role": null,              // TENANT_ADMIN | TENANT_INSTALLER | TENANT_VIEWER | null
  "home_roles": {                   // cached snapshot, refreshed every 5 min from Redis
    "9b2d...": "OWNER",
    "1c4e...": "MEMBER"
  },
  "jti": "uuid-v4",                 // unique token ID for blacklist
  "iat": 1732000000,
  "exp": 1732000900                 // 15 min from iat
}
```

### 1.3 Token issuance

```http
POST /api/v3/auth/login
Content-Type: application/json

{ "email": "user@example.et", "password": "...", "mfa_code": "123456" }

→ 200 OK
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "expires_in": 900,
  "token_type": "Bearer"
}
```

If MFA is enabled and `mfa_code` is missing or invalid, the response is `401 AUTH_MFA_REQUIRED`.

### 1.4 Refresh flow

```http
POST /api/v3/auth/refresh
{ "refresh_token": "eyJ..." }

→ Old refresh token jti blacklisted in Redis (TTL = access token TTL)
→ New access + refresh tokens issued (rotating refresh)
```

---

## 2. Multi-tenant RBAC — 10 roles

### 2.1 Platform-level roles (`users.platform_role`)

| Role | Scope | Capabilities |
|---|---|---|
| `USER` | Own home (B2C) | Default for B2C users. Full CRUD on own home + devices + scenes + automations. |
| `PLATFORM_ADMIN` | All tenants (read-only) | Read-only across all tenants for support/audit. Cannot create tenants or modify data. |
| `SUPER_ADMIN` | Platform | Everything — create tenants, manage admins, rotate CA, force-logout, impersonate. |

### 2.2 Tenant-level roles (`users.tenant_role`)

| Role | Scope | Capabilities |
|---|---|---|
| `TENANT_ADMIN` | Tenant | Manage tenant's users, devices, billing, branding. Cannot manage other tenants. |
| `TENANT_INSTALLER` | Tenant | Provision devices via BLE, assign to homes, no billing or user management. |
| `TENANT_VIEWER` | Tenant | Read-only access to tenant's devices + telemetry + audit logs. |

### 2.3 Home-level roles (`home_members.role`)

| Role | Capabilities |
|---|---|
| `OWNER` | Full CRUD + delete home + manage members + transfer ownership + enable local control |
| `ADMIN` | Full CRUD on devices, automations, scenes, node groups. Cannot manage members or delete home. |
| `MEMBER` | Control devices, activate scenes, trigger automations. Cannot create or delete devices. |
| `GUEST` | View-only — can see device state, cannot toggle. |

### 2.4 Role count: 10

| Scope | Count | Roles |
|---|---|---|
| Platform | 3 | USER, PLATFORM_ADMIN, SUPER_ADMIN |
| Tenant | 3 | TENANT_ADMIN, TENANT_INSTALLER, TENANT_VIEWER |
| Home | 4 | OWNER, ADMIN, MEMBER, GUEST |
| **Total** | **10** | |

> **Correction note:** the original draft stated "8 roles" in two places. The correct count is **10** (3 + 3 + 4). See `V3-OVERVIEW.md` §7.2.

### 2.5 Authorization chokepoint

All home-scoped access funnels through a single Spring Boot service method:

```java
/**
 * Verifies the requester has the required role on the given home.
 * Combines tenant RLS filter + home_members RBAC in one call.
 * Throws InsufficientPermissionException if denied.
 */
Home getAuthorizedHomeOrThrow(UUID requesterId, UUID homeId, HomeRole requiredRole);
```

Internal flow:
1. Set Postgres session var `app.tenant_id` from JWT (RLS active for all queries)
2. `SELECT * FROM homes JOIN home_members WHERE home_id = ? AND user_id = ?`
3. If `home_members.role` < `requiredRole` (per role hierarchy OWNER > ADMIN > MEMBER > GUEST), throw `InsufficientPermissionException` → logged to `audit_log` with `event = RBAC_DENIED`
4. Else return the Home entity (tenant-scoped via RLS)

This single chokepoint is what makes the audit story defensible — every privileged action passes through one audited call.

---

## 3. Device authentication (X.509 certificates)

### 3.1 Our Certificate Authority

SHE V3 operates its own PKI. No use of public CAs (Let's Encrypt, DigiCert, etc.) for device authentication. The PKI is managed with **step-ca** (Smallstep) — not raw OpenSSL CLI — for proper lifecycle management (see §8 and `V3-CONFIGURATION.md`).

| CA layer | Key | Validity | Storage | Purpose |
|---|---|---|---|---|
| Root CA | RSA 4096-bit | 20 years | Air-gapped offline laptop + offline USB backup (root key is offline; brought online only for intermediate rotation) | Signs intermediate CA only (1 cert) |
| Intermediate CA | RSA 4096-bit | 10 years | step-ca server — **HSM-backed (YubiHSM 2) in production** via PKCS#11 | Signs device certs |
| Device cert | **ECDSA P-256** | **5 years** | ESP32 `fctry` NVS partition (Flash-encrypted + NVS-encrypted) | Per-device mTLS identity |

**Why ECDSA P-256 (not RSA-2048) for device certs:**
1. ESP32-C3 has no RSA hardware acceleration (software-only RSA verify costs 200-400 ms on C3).
2. NIST SP 800-57 recommends ≥3072-bit RSA for protection beyond 2030; RSA-2048 is below that bar.
3. ECDSA P-256 verify is **~50 ms on C3** (hardware-assisted on S3) vs 200-400 ms for RSA-2048.
4. ECDSA P-256 is NIST-approved through 2030+.
5. Smaller cert + signature (72-byte signature vs 256-byte for RSA-2048).

**Why RSA 4096-bit for root/intermediate:** One-time signing operations only — the cost is paid once per cert issuance, not on every TLS handshake. 4096-bit provides a long security margin for the 10/20-year validity windows.

### 3.2 Device cert lifecycle

**Authoritative source — see `V3-FACTORY-OPS.md` §3.1 for the factory workflow.**

1. **Issuance** (during **FACTORY** provisioning — NOT during BLE provisioning):
   1. ESP32 boots in factory mode.
   2. Firmware calls `mbedtls_ecdsa_genkey()` → generates ECDSA P-256 keypair in RAM.
   3. Private key written to `fctry` NVS partition (encrypted via Flash Encryption — §5.2).
   4. **Private key NEVER leaves the device.**
   5. Firmware generates a PKCS#10 CSR with `CN = {MAC_ADDRESS}`.
   6. Factory workstation reads the CSR from ESP32 over USB serial.
   7. Factory workstation sends CSR to step-ca: `step ca sign {csr} --not-after=43800h` (5-year validity).
   8. step-ca signs the cert (intermediate CA, ECDSA P-256, 5-year validity).
   9. Cert returned to ESP32 over USB serial, stored in `fctry` NVS.
   10. Factory workstation logs cert fingerprint + MAC, but **NEVER has the private key**.

2. **Storage**: cert + private key in NVS partition `fctry`, protected by Flash Encryption (§5.2) + NVS Encryption (§5.2). On ESP32-C3 (R4) and ESP32-S3 (R8/R16), Flash Encryption is enabled in RELEASE mode.

3. **Usage**: device presents cert on every MQTT connection (mutual TLS to EMQX).

4. **Revocation**: if device is stolen/compromised, admin marks `device_certs.status = REVOKED` via Admin Console → CRL regenerated → Spring Boot `/internal/mqtt/auth` rejects → EMQX disconnects.

5. **Rotation**: device certs are **5-year validity**. End-of-life rotation = factory re-provisioning (new on-chip keypair, new cert issued by step-ca). Firmware OTA can ship a new CA bundle if needed.

> **Note:** BLE provisioning (at user site) does NOT issue certs. It only transfers Wi-Fi creds + performs user-node mapping (challenge-response). The cert is already on the device from factory — see `V3-FIRMWARE.md` §5.1.

### 3.3 Intermediate-CA rotation procedure

The intermediate CA is rotated yearly. Device certs are **5-year validity**, so a single device cert will cross ~5 intermediate rotations. Trust chain must be maintained across rotations.

**Rotation procedure (zero-downtime):**

1. **Day -7 (prep):** Generate new intermediate CA keypair via step-ca (signed by root CA, new 4096-bit RSA, 10-yr validity, **HSM-backed via YubiHSM 2**). Keep new intermediate cert in offline staging.

2. **Day 0 (deploy bundle):** Update `ca_bundle.pem` on all EMQX nodes to contain BOTH old + new intermediate certs:
   ```
   cat old_intermediate.crt new_intermediate.crt > ca_bundle.pem
   ```
   Rolling-restart EMQX nodes one at a time (cluster tolerates 1-node loss).

3. **Day 1+ (sign with new):** Spring Boot's step-ca config is updated to sign new device certs with the new intermediate CA. New devices provisioned after Day 1 get certs signed by the new intermediate.

4. **Existing device certs** remain signed by the old intermediate — they continue to validate via the bundle. No device-side action needed.

5. **Day 365+ (expire old):** The old intermediate CA's 10-year validity window eventually elapses. After its `notAfter` date, remove it from `ca_bundle.pem`. By that time, all device certs signed by it have also expired (since they're 5-year, signed during the old intermediate's validity window).

6. **CRL:** Each intermediate publishes its own CRL at `https://she.et/ca/{intermediate_id}/crl.pem`. EMQX checks both CRLs during the overlap window.

### 3.4 EMQX configuration (mutual-TLS)

```ini
# /etc/emqx/emqx.conf (excerpt)
listeners.ssl.default {
  bind = "0.0.0.0:8883"
  ssl_options {
    keyfile  = /etc/emqx/certs/server.key
    certfile = /etc/emqx/certs/server.crt
    cacertfile = /etc/emqx/certs/ca_bundle.pem   # root + BOTH intermediates (during overlap)
    verify   = verify_peer
    fail_if_no_peer_cert = true
    versions = [tlsv1.3, tlsv1.2]                # 1.3 preferred, 1.2 fallback for older ESP32 mbedTLS
  }
}
```

---

## 4. MQTT broker security (EMQX)

### 4.1 Transport

- MQTTS (port 8883) only — port 1883 disabled in production
- TLS 1.3 preferred (ESP32-S3 mbedTLS supports it); TLS 1.2 fallback for ESP32-C3
- Server cert: signed by our own CA (not Let's Encrypt — keeps trust within our PKI)
- Client cert verification: `verify_peer` + `fail_if_no_peer_cert = true`

### 4.2 HTTP auth backend

EMQX calls Spring Boot on every CONNECT:

```http
POST /internal/mqtt/auth
Content-Type: application/json

{
  "clientid": "aabbccddeeff",
  "cn": "aabbccddeeff",
  "fingerprint": "sha256:ab12cd34..."
}

→ 200 OK  { "result": "allow", "is_superuser": false }
→ 403     { "result": "deny",  "reason": "cert_revoked" }
```

Spring Boot verifies:
1. `fingerprint` matches a `device_certs` row (sha256 of DER cert)
2. `device_certs.status = ACTIVE` (not REVOKED or EXPIRED)
3. `nodes.is_quarantined = false` (admin can quarantine a compromised device)
4. CRL check — cert serial not in CRL of its signing intermediate

### 4.3 HTTP ACL backend

EMQX calls Spring Boot on every PUBLISH/SUBSCRIBE:

```http
POST /internal/mqtt/acl
Content-Type: application/json

{
  "clientid": "aabbccddeeff",
  "topic": "she/6f1c/9b2d/1c4e/aabbccddeeff/params/remote",
  "action": "subscribe"
}

→ 200 OK  { "result": "allow" }
→ 403     { "result": "deny",  "reason": "mac_mismatch" }
```

Spring Boot verifies (all must pass):
1. The `{node_mac}` segment in the topic matches `clientid` (which equals device MAC)
2. The `{tenant_id}` segment matches the device's actual tenant_id (from `device_certs JOIN nodes`)
3. The `{home_id}` segment matches the device's actual home_id
4. The `{direction}` is in the device's allowed list:

| Direction | Device can PUB | Device can SUB |
|---|---|---|
| `config` | Yes | No |
| `command` | No | Yes |
| `params/local` | Yes | No |
| `params/remote` | No | Yes |
| `telemetry` | Yes | No |
| `status` | Yes | No |
| `energy` | Yes | No |
| `ota/url` | No | Yes |
| `ota/status` | Yes | No |
| `ota/progress` | Yes | No |

### 4.4 Backend service connection

Spring Boot connects to EMQX with a **client cert** (mutual TLS, issued by the SHE intermediate CA — same PKI as devices) and an **explicit ACL** listing allowed topics. **No blanket ACL bypass, no superuser account.**

**Subscribe topics:**
- `she/+/+/+/+/telemetry`
- `she/+/+/+/+/status`
- `she/+/+/+/+/params/local`
- `she/+/+/+/+/energy`
- `she/+/+/+/+/ota/status`

**Publish topics:**
- `she/+/+/+/+/command`
- `she/+/+/+/+/params/remote`
- `she/+/+/+/+/ota/url`

The client cert + private key are loaded from env-var-configured paths (`MQTT_BACKEND_CERT` + `MQTT_BACKEND_KEY`); in production the private key is held in the HSM (YubiHSM 2) via PKCS#11. Spring Boot uses Paho MQTT client with shared subscriptions to fan-in device telemetry.

If Spring Boot is compromised, it can command devices — but only within the documented topic structure (auditable). There is no superuser account that bypasses ACL.

### 4.5 Rate limiting

EMQX per-client rate limits:
- Publish: max 20 msg/s per client (devices normally publish 1-2 msg/s)
- Subscribe: max 10 topics per client (devices normally subscribe 1-3)

---

## 5. Firmware security (CRITICAL)

> **Note:** This entire section was missing from the original draft. It is the most critical security control in the platform — without it, any attacker with physical access could reflash a device and use it as a rogue node on the MQTT cluster.

### 5.1 Secure Boot v2

**Hardware root of trust.** Implemented on both ESP32-C3 (R4) and ESP32-S3 (R8/R16) — both chips support Secure Boot v2 (the original WROOM-32 only supported the weaker v1, which is why V3 uses C3/S3 — see ADR-012).

| Property | Value |
|---|---|
| Algorithm | RSA-PSS 3072-bit (Secure Boot v2) |
| Public key digest | Burned into eFuse `SECURE_BOOT_EN` during factory provisioning |
| Bootloader verification | ROM verifies bootloader signature on every boot |
| Application verification | Bootloader verifies application signature on every boot |
| Failure mode | Refuse to boot — no fallback to unsigned image |

**Provisioning procedure (factory — see V3-FACTORY-OPS.md):**
1. Generate RSA-PSS 3072-bit keypair offline (HSM or air-gapped machine)
2. Burn public key digest into eFuse `SECURE_BOOT_EN` (one-time programmable — irreversible)
3. Configure `CONFIG_SECURE_BOOT_V2_ENABLED=y` in `sdkconfig`
4. Sign bootloader + application images with the private key
5. Private key never leaves the offline signing machine

### 5.2 Flash Encryption

**Protects cert + private key in NVS at rest.** If an attacker desolders the flash chip and reads it externally, the device cert + private key + Wi-Fi PSK + Chapa secrets are all AES-256-XTS encrypted.

| Property | Value |
|---|---|
| Algorithm | AES-256-XTS (NIST SP 800-38E) |
| Key derivation | eFuse `BLOCK_KEY1` (`KEY_PURPOSE=HMAC_DOWN_ENCRYPT`, 256-bit, factory-burned, read-protected) |
| Key generation mode | Random (not derived from device MAC — more secure) |
| Mode | RELEASE (`FLASH_ENCRYPTION_MODE_RELEASE`) — development mode disabled in production |
| Encrypted partitions | Bootloader, partition table, application, NVS (`fctry`, `nvs.net80211`) |
| Failure mode | If flash is read externally, ciphertext is unintelligible without the eFuse HMAC key |

**NVS encryption** (separate from Flash Encryption, additional layer for sensitive partitions):
- `fctry` partition (holding device cert + private key) uses NVS Encryption with a key stored in `nvs.keys` partition
- `nvs.keys` partition itself is in the Flash Encryption scope, so it's protected at-rest
- Result: device cert + private key are protected by two layers (Flash Encryption + NVS Encryption)

### 5.3 Anti-rollback eFuses

**Prevents downgrade to vulnerable firmware.** Each firmware release has a `secure_version` integer; the chip's eFuse `SECURE_VERSION` field is the minimum acceptable version.

| Property | Value |
|---|---|
| eFuse field | `SECURE_VERSION` (32-bit, one-time programmable per bit) |
| Bit semantics | **popcount semantics** — each set bit represents one version increment (NOT a 32-bit integer) |
| Maximum versions | **32** (not 4 billion — popcount, not integer value). Once a bit is burned, it cannot be cleared (irreversible). |
| OTA flow | Bootloader compares firmware's signed `secure_version` against `popcount(SECURE_VERSION)` |
| Update flow | After successful OTA of a **major security release**, bootloader burns the next eFuse bit |
| Minor releases | Use **signed version comparison** in firmware (no eFuse burn) |
| Failure mode | Bootloader refuses to boot firmware with `secure_version < popcount(SECURE_VERSION)` — prevents downgrade attack |

**Strategy:** Burn 1 bit per **major security release** (not every minor release). At 2 major security releases/year → **16-year budget** (sufficient for a 10-year device lifetime). Minor releases use signed version comparison in firmware.

**Example:** A security-critical patch (CVE fix) bumps `secure_version` from 5 to 6. Bootloader burns bit 6 in `SECURE_VERSION` after a successful OTA. If attacker tries to flash older firmware (popcount 5), bootloader refuses.

**When to burn a bit:** Only for security-critical fixes (CVE patches, auth bypass fixes). Document each burn in `V3-SECURITY-CHANGELOG.md`.

### 5.4 JTAG / UART disable in production

Standard ESP32-S3 eFuse field names (verified via `espefuse.py summary`):

| Interface | Development | Production |
|---|---|---|
| JTAG (pad) | Enabled | **Disabled** (eFuse `DIS_PAD_JTAG`) |
| JTAG (download mode) | Enabled | **Disabled** (eFuse `DIS_DOWNLOAD_JTAG`) |
| USB-Serial-JTAG (S3 only) | Enabled | **Disabled** (eFuse `DIS_USB_JTAG`) |
| Download mode (UART flashing) | Enabled | **Disabled** (eFuse `DIS_DOWNLOAD_MODE`) |
| Download manual encrypt | Enabled | **Disabled** (eFuse `DIS_DOWNLOAD_MANUAL_ENCRYPT`) |
| Direct boot | Enabled | **Disabled** (eFuse `DIS_DIRECT_BOOT`) |

Effect: after factory flashing + eFuse burn, the device's flash cannot be re-read or re-written without the boot message key (which is also burned into eFuse and not recoverable).

### 5.5 Ed25519 OTA signing

**Firmware images are signed, verified before flash.** Even if an attacker compromises the OTA distribution channel (MinIO + Spring Boot), they cannot sign a firmware image that the device will accept.

| Property | Value |
|---|---|
| Algorithm | Ed25519 (RFC 8032) |
| Key size | 256-bit private + 256-bit public |
| Signing key storage | Offline machine (air-gapped, KEK-encrypted USB backup) |
| Public key | **ESP32-S3:** burned into eFuse `BLOCK_KEY2` (`KEY_PURPOSE=USER`) during factory provisioning (immutable). **ESP32-C3:** compiled into firmware, protected by Secure Boot v2 (C3 has fewer eFuse key blocks — ADR-012). |
| Signature size | 64 bytes, appended to firmware image |
| Verification | Bootloader verifies signature against eFuse-burned public key before writing to OTA partition |
| Failure mode | Bootloader refuses to write unsigned or wrongly-signed image |

**Firmware image format:**

```
[she_firmware_header]
  magic: 0xSHE3
  version: "1.5.0"
  secure_version: 15  (for anti-rollback, §5.3)
  sku: "SHE-R8"
  size: 1245184
  sha256: ...
[she_firmware_body]
  ... binary ...
[ed25519_signature]
  64 bytes
```

ESP32 verifies: header magic → SHA-256(body) matches `sha256` field → Ed25519-verify(signature, hash, public_key_from_efuse) → secure_version >= efuse SECURE_VERSION → only then writes to OTA partition.

### 5.6 Summary table

| Control | Threat mitigated | Where enforced |
|---|---|---|
| Secure Boot v2 | Unsigned / tampered firmware | Bootloader (ROM-verified) |
| Flash Encryption | Physical flash dump → cert/key theft | ESP32 hardware |
| Anti-rollback eFuses | Downgrade to vulnerable version | Bootloader + eFuse |
| JTAG/UART disable | Physical debug interface abuse | eFuses (one-way) |
| Ed25519 OTA signing | Compromised OTA channel | Bootloader (signature verify) |

### 5.7 Factory provisioning order

The eFuses must be burned in the correct order during factory flashing (see `V3-FACTORY-OPS.md` §6.1). On **ESP32-S3**:

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

After step 7, the device's flash cannot be re-read via JTAG/UART. The only way to update is OTA (signed). If the device is bricked, it must be returned to factory for warranty replacement (not field-reflashable).

**For ESP32-C3 (SHE-R4):** Same sequence, but `BLOCK_KEY2` (Ed25519 OTA pubkey) is NOT available on C3 — C3 has fewer eFuse key blocks. Instead, the Ed25519 pubkey is compiled into firmware (protected by Secure Boot v2, which prevents firmware substitution). This is a documented C3 limitation (ADR-012).

---

## 6. MFA (TOTP)

### 6.1 Policy

| Role | MFA required |
|---|---|
| `SUPER_ADMIN` | Yes (mandatory) |
| `PLATFORM_ADMIN` | Yes (mandatory) |
| `TENANT_ADMIN` | Yes (mandatory) |
| `TENANT_INSTALLER` | Optional |
| `TENANT_VIEWER` | Optional |
| `USER` (B2C) | Optional |
| `OWNER` / `ADMIN` / `MEMBER` / `GUEST` (home) | Inherits from `platform_role` |

### 6.2 Implementation

- Algorithm: TOTP (RFC 6238), 30-second step, 6 digits, SHA-1
- Apps supported: Google Authenticator, Authy, Microsoft Authenticator, FreeOTP
- Secret: 20-byte base32, stored encrypted (`users.totp_secret_encrypted`, AES-256-GCM with KEK from env var)
- Enrollment: scan QR code (`otpauth://totp/SHE:user@example.et?secret=...&issuer=SmartHomeEthiopia`)
- Recovery: 10 one-time recovery codes generated at enrollment, stored hashed (bcrypt cost 10), single-use
- Enforcement: login returns `401 AUTH_MFA_REQUIRED` if MFA is enabled for the user but `mfa_code` is missing or invalid

### 6.3 Recovery codes

- 10 codes, each 8 chars (alphanumeric, ambiguous chars removed: no `0/O`, `1/I`)
- Stored as bcrypt hashes in `users.totp_recovery_codes` (JSON array)
- Each use: hash the supplied code, compare against array, remove the matched entry on success
- Regeneration: owner can request new recovery codes (invalidates all existing ones)

---

## 7. Audit logging

### 7.1 Retention

- All audit events stored in `audit_log` table — **TimescaleDB hypertable** (not pg_partman), partitioned by time.
- **Retention tiers:** 30 days raw + 2 years compressed (TimescaleDB native columnar compression) + 7 years CSV archive in MinIO (S3).
- CSV export to MinIO quarterly (7-year regulatory retention per PDPP).
- Beyond 7 years: shredded (automated retention policy via TimescaleDB `add_retention_policy`).
- **Tamper-evidence:** `audit_log` has `hash` + `prev_hash` columns forming a hash chain — each event's `hash = SHA-256(prev_hash || event_payload)`. Any tampering with a historical row breaks the chain (detectable via nightly verification job).

```sql
CREATE TABLE audit_log (
    id          BIGSERIAL,
    bucket_day  DATE NOT NULL,         -- hypertable partition key
    event       TEXT NOT NULL,
    actor_user_id UUID,
    payload     JSONB NOT NULL,
    prev_hash   BYTEA NOT NULL,        -- hash of previous row (chain link)
    hash        BYTEA NOT NULL,        -- SHA-256(prev_hash || canonical_json(payload))
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
SELECT create_hypertable('audit_log', 'created_at');
ALTER TABLE audit_log SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'event, actor_user_id'
);
SELECT add_compression_policy('audit_log', INTERVAL '30 days');
SELECT add_retention_policy('audit_log', INTERVAL '2 years');
```

### 7.2 Logged events

| Event | Fields logged |
|---|---|
| Login success | user_id, ip, user_agent, mfa_used, timestamp |
| Login failure | email_attempted, ip, user_agent, reason, timestamp |
| Logout | user_id, ip, timestamp |
| RBAC denied | user_id, home_id, required_role, endpoint, timestamp |
| Member invite / revoke | actor_user_id, target_user_id, home_id, role, timestamp |
| OTA batch create / abort | actor_user_id, batch_id, target_sku, rollout_pct, timestamp |
| OTA image upload | actor_user_id, image_id, sha256, version, sku, timestamp |
| Device cert issued | actor_user_id (=system during provisioning), device_id, cert_serial, intermediate_id, timestamp |
| Device cert revoked | actor_user_id, device_id, cert_serial, reason, timestamp |
| Impersonation started / ended | actor_user_id, target_user_id, duration, timestamp |
| Payment initiated / completed / refunded | tenant_id, amount_etb, chapa_ref, timestamp |
| Feature flag toggled | actor_user_id, flag_name, old_value, new_value, timestamp |
| CA rotation step | actor_user_id, intermediate_id, step (deploy_bundle/sign_new/expire_old), timestamp |
| User password changed | user_id, ip, mfa_used, timestamp |
| MFA enrolled / disabled | user_id, ip, timestamp |
| Admin API key created / revoked | actor_user_id, key_id, scopes, expires_at, timestamp |

### 7.3 Audit log access

- `SUPER_ADMIN`: read all audit events
- `PLATFORM_ADMIN`: read all audit events (no PII fields: email_attempted is masked)
- `TENANT_ADMIN`: read audit events for own tenant only (RLS-enforced)
- `USER`: read audit events for own user_id + own home_id only

### 7.4 CSV export

```http
POST /api/v3/admin/audit/export
Content-Type: application/json

{ "from": "2024-01-01", "to": "2024-03-31", "tenant_id": "..." }

→ 202 Accepted  { "export_id": "...", "eta_seconds": 30 }
→ Spring Boot generates CSV → uploads to MinIO  s3://she-audit-exports/{export_id}.csv
→ Push notification when ready → download URL emailed to requester
→ MinIO lifecycle rule deletes CSV after 30 days
```

---

## 8. Secrets management

### 8.1 CA management — step-ca (NOT raw OpenSSL)

The original draft specified raw OpenSSL CLI commands for CA generation. This is dangerous: no proper serial number tracking, no CRL automation, no key rotation workflow, no audit trail. SHE V3 uses **step-ca** (Smallstep) for the entire CA lifecycle.

**Why step-ca:**
- Automated CRL generation + publishing (every 24 h)
- JWK signer with KEK-protected key (AES-256-GCM)
- Audit log of every cert signing operation
- ACME server (for server cert issuance — used for EMQX, Spring Boot internal)
- REST API for Spring Boot to call during device provisioning (no shell exec)

**Setup:** See `V3-CONFIGURATION.md` §3 for the full step-ca initialization sequence (root CA bootstrap, intermediate CA signing, JWK provisioner, CA bundle generation).

### 8.2 Secret inventory

| Secret | Storage | Rotation |
|---|---|---|
| DB password (`SPRING_DATASOURCE_PASSWORD`) | Env var (systemd unit file, mode 0400) | Quarterly |
| Redis password | Env var | Quarterly |
| MQTT backend cert + key (`MQTT_BACKEND_CERT` + `MQTT_BACKEND_KEY`) | File path in env var (key in HSM via PKCS#11 in production) | Quarterly — cert re-issued by step-ca, key rotated in HSM |
| JWT signing key (Ed25519 private key) | Env-var-configured file path (HSM-backed via PKCS#11 in production) | Quarterly — uses multi-key rotation window (§1.1); old `kid` accepted until tokens expire |
| CA root private key | Offline air-gapped machine + offline USB backup (HSM if budget allows) | Never (20-year validity) |
| CA intermediate private key | step-ca signer — **HSM-backed (YubiHSM 2)** via PKCS#11 in production | Yearly (rotation procedure §3.3) |
| Ed25519 OTA signing key | Offline air-gapped machine + offline USB backup | On compromise only (rotation requires OTA to push new pubkey — but eFuse is immutable, so rotation is impossible without new hardware rev) |
| Secure Boot v2 private key (RSA-PSS 3072) | Offline air-gapped machine + offline USB backup | Never (eFuse-burned pubkey is immutable) |
| Flash Encryption key | Per-device, in eFuse (factory-burned, never extractable) | Never |
| KEK (encrypts TOTP + CA intermediate key) | Env var | Yearly (re-encrypt all encrypted columns via migration script) |
| Chapa API key | Env var | Per Chapa policy (typically yearly) |
| Chapa webhook secret | Env var | Per Chapa policy |
| FCM service account JSON | File path in env var, on disk (mode 0400) | Per Google policy (key rotation in Firebase console) |
| APNs key (.p8) | File path in env var, on disk (mode 0400) | Per Apple policy (max 2-yr validity, rotate before expiry) |
| SMTP password | Env var | Per IT policy |

### 8.3 KEK rotation procedure (yearly)

```bash
# 1. Generate new KEK
NEW_KEK=$(openssl rand -base64 32)

# 2. Run migration script (Spring Boot)
SPRING_PROFILES_ACTIVE=prod KEK=$OLD_KEK NEW_KEK=$NEW_KEK \
  java -jar she-backend.jar --run-rekek-migration

# Migration script:
#   - For each row in users with totp_secret_encrypted: decrypt with old KEK, re-encrypt with new
#   - For step-ca JWK signer: decrypt with old KEK, re-encrypt with new, restart step-ca
#   - Verify by running auth flow against a test user
#   - Atomic transaction: either all re-encryption succeeds, or rollback

# 3. Update env var on all Spring Boot instances + step-ca
systemctl set-environment KEK=$NEW_KEK
systemctl restart she-backend step-ca

# 4. Verify: login as a test user with TOTP, confirm MFA code accepted
```

---

## 9. PDPP compliance

Cross-references: `V3-PRIVACY-COMPLIANCE.md` (full PDPP analysis) and `V3-DPIA.md` (Data Protection Impact Assessment for cross-border transfers).

### 9.1 Data residency

- All PII stored in Postgres on Ethio Telecom Cloud (Addis Ababa) — never leaves Ethiopia
- All device telemetry + energy data on TimescaleDB on the same Postgres instance
- All device certs signed by our own CA (offline root, in-country intermediate)
- All audit logs in Postgres + MinIO (both in-country)

### 9.2 Subprocessors (limited data, in scope of DPIA)

| Subprocessor | Data shared | Out-of-country? | Lawful basis |
|---|---|---|---|
| Cloudflare | TLS termination (no PII stored); source IPs | Yes (edge POPs global) | Consent + legitimate interest (security) |
| Chapa | Payment amount, tenant_id, customer phone | Yes (Chapa infra in DE) | Contract performance (payment processing) |
| Google FCM | Push notification token + payload | Yes (Google infra global) | Consent |
| Apple APNs | Push notification token + payload | Yes (Apple infra US) | Consent |
| Ethio Telecom | All data (data center provider) | No | Contract performance |

Each subprocessor is documented in `V3-PRIVACY-COMPLIANCE.md` §4 with DPA status, retention terms, and breach-notification SLA.

### 9.3 Data subject rights

| Right | Implementation |
|---|---|
| Access | `GET /api/v3/me/data-export` → JSON dump of user + homes + devices + audit events |
| Rectification | `PUT /api/v3/me` for profile fields; device labels via `PUT /api/v3/nodes/...` |
| Erasure | `DELETE /api/v3/me` → cascading soft-delete + 30-day hard-delete job; cert revoked; MQTT access blocked |
| Portability | Same as Access — JSON export, machine-readable |
| Objection | User can disable push notifications, opt out of analytics, disable voice (SHE-R16) |

### 9.4 Breach response

Per PDPP §7.2 — 72-hour notification to ECA (Ethiopian Communications Authority) + affected data subjects. See `V3-PRIVACY-COMPLIANCE.md` §6 for the full runbook.

---

## 10. Threat model

### 10.1 Threat actors

| Actor | Capability | Motivation |
|---|---|---|
| Curious neighbor | Same Wi-Fi, basic tools | Curiosity, prank |
| Malicious co-tenant | Same home, app access as MEMBER | Harassment, control |
| Stolen-device attacker | Physical possession of one ESP32 | Lateral movement, cert theft |
| Compromised EMQX broker | Read/modify all MQTT traffic | Mass device control |
| Compromised Spring Boot | Full platform access (RLS bypass attempt) | Data exfiltration |
| Compromised CA key | Sign arbitrary device certs | Rogue device on cluster |
| Supply-chain attacker | Malicious firmware/library/dependency | Persistence |
| Insider (admin) | DB + env var access | Data theft |
| Firmware supply chain | Build pipeline compromise | Mass persistence |
| Physical device thief | Steals hardware from warehouse/shipment | Resell, exploit |

### 10.2 RainMaker account compromise — N/A

The original draft mentioned RainMaker account compromise as a threat. **This is N/A**: SHE V3 does not use RainMaker cloud (per ADR-001 + ADR-011). We only adopt the RainMaker *data model* (Node/Device/Service/Param/Attr) as a conceptual framework. There is no Espressif-hosted account that could be compromised.

### 10.3 Threat → Mitigation matrix

| Threat | Mitigation | Spec section |
|---|---|---|
| Neighbor sniffs MQTT traffic | MQTTS (TLS 1.3), cert pinning | §4 |
| Neighbor spoofs device topic | X.509 cert auth + per-device ACL | §3, §4.3 |
| Co-tenant accesses beyond their role | 10-role RBAC chokepoint, RLS | §2.5 |
| Stolen device — attacker extracts cert | Flash Encryption + NVS Encryption + JTAG/UART disable | §5.2, §5.4 |
| Stolen device — attacker reflashes | Secure Boot v2 + Ed25519 OTA signing + anti-rollback eFuses | §5.1, §5.3, §5.5 |
| Stolen device — attacker uses cert on rogue device | Cert is bound to MAC in CN; ACL verifies topic MAC = clientid MAC = cert CN | §3.2, §4.3 |
| Compromised device brute-forces broker | Cert-based auth (no passwords to brute-force); per-client rate limit | §3, §4.5 |
| Compromised EMQX reads MQTT traffic | TLS protects payload (mTLS with cert pinning); broker cannot read cert private keys (in NVS) | §4 |
| Compromised Spring Boot attempts RLS bypass | RLS is database-enforced (not app-enforced). App role (`she_app`) does NOT have `BYPASSRLS`. The RLS policy itself checks a per-transaction GUC `app.is_platform_admin` — no blanket bypass. `SUPER_ADMIN`/`PLATFORM_ADMIN` requests set the GUC; ordinary requests do not. See §10.5. | §2.5, §10.5, ADR-003 |
| **CA key compromise (root)** | Root key is offline (air-gapped); compromise requires physical access to offline machine. Mitigation: detect via audit_log of cert issuance anomalies. Recovery: full PKI rebuild + new hardware rev (eFuses burned with new root). | §3.1, §8.2 |
| **CA key compromise (intermediate)** | Intermediate CA key is **HSM-backed (YubiHSM 2)** via PKCS#11 in step-ca — extraction requires physical HSM access. Mitigation: revoke intermediate via CRL, deploy new intermediate via bundle rotation (§3.3). Recovery: <6h — all new device certs use new intermediate, existing certs continue to validate via bundle, revoked intermediate rejects future use. | §3.1, §3.3, §8.2 |
| **EMQX cluster compromise (1 node)** | Cluster tolerates 1-node loss (3-node quorum). Mitigation: revoke that node's server cert, remove from cluster, redeploy from clean image. Audit MQTT auth log for suspicious activity during compromise window. | §4 |
| **EMQX cluster compromise (2+ nodes)** | Full cluster rebuild from clean images, rotate MQTT backend cert + key, force all devices to reconnect (broadcast `command: reconnect`). No device certs compromised (they're in NVS, not broker). | §4 |
| **Spring Boot RLS bypass** | RLS is enforced by the database, not the app. App role (`she_app`) does NOT have `BYPASSRLS` privilege. The RLS policy itself checks a per-transaction GUC `app.is_platform_admin` — no blanket bypass. `SUPER_ADMIN`/`PLATFORM_ADMIN` requests set the GUC; ordinary requests do not. See §10.5. | §2.5, §10.5 |
| **Firmware supply chain attack** | Dependencies pinned (lockfile), CI runs `npm audit` / `mvn dependency-check`, firmware build is reproducible, Ed25519 OTA signing key is offline. SHA-256 of every firmware image recorded in audit_log. | §5.5, §8.2 |
| **Physical device theft (from shipment)** | Devices are inert until BLE-provisioned (no cert, no Wi-Fi creds). Stolen devices cannot connect to MQTT. Claim tokens are single-use + 10-min TTL. | §3.2 |
| **Insider reads encrypted secrets** | KEK is in env var, not in DB or code. Insider with DB access cannot decrypt TOTP secrets / CA keys without env var access. Insider with env var access cannot decrypt without DB access (defense in depth). | §8 |
| **BLE provisioning eavesdropping** | BLE pairing is encrypted (bonded, LE Secure Connections). Claim token is single-use + 10-min TTL + delivered over HTTPS to the Flutter app. | `V3-ARCHITECTURE.md` §4.4 |
| **Replay attack on MQTT command** | QoS 1 message IDs; idempotent state-based commands (toggle by ID, not by counter). `params/remote` carries monotonic `seq` field; Spring Boot rejects duplicates. | `V3-MQTT-STANDARDS.md` §6 |
| **Brute-force login** | Rate limit: 5 attempts per 15 min, then 1-hour lockout. Backoff: 5 → 15 → 60 → 360 min. | §1.3 |
| **JWT theft (refresh token)** | Refresh token rotation; old jti blacklisted; access token in-memory only (no localStorage). | §1.1, §1.4 |
| **MFA bypass via recovery code brute-force** | Recovery codes are bcrypt-hashed, single-use, 10 attempts max. After 3 wrong codes → 24h lockout. | §6.3 |

### 10.5 RLS bypass mechanism (canonical)

**Decision:** Use a custom GUC checked by the RLS policy itself (NOT `BYPASSRLS`, NOT a fictional `app.bypass_rls` GUC).

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
- `current_setting('app.is_platform_admin', true)` returns `false` if the GUC is unset (the `true` = `missing_ok`).
- The RLS policy itself checks the flag — **no `BYPASSRLS` privilege needed**.
- `she_app` role does NOT need `BYPASSRLS` (safer — no privilege escalation).
- Auditable: the GUC is set per-transaction, logged in `pg_stat_statements`.

### 10.4 Residual risk

| Risk | Likelihood | Impact | Accepted? | Mitigation |
|---|---|---|---|---|
| Ed25519 OTA key compromise | Low | High | Yes | Air-gapped storage + multi-approver signing; new hardware rev on compromise (eFuse pubkey immutable) |
| Secure Boot v2 key compromise | Very low | Catastrophic | Yes | Same as above; new hardware rev burns new pubkey into eFuse |
| Compromised Ethio Telecom insider | Low | High | Yes | Disk encryption (LUKS); app-layer encryption (KEK) for sensitive data |
| Datacenter outage (quake, unrest) | Low | Catastrophic | Partial | Offsite backup to DR site in Dire Dawa (planned V3.1) |

---

## 11. References

- `V3-ARCHITECTURE.md` — system architecture, data flows, EMQX topology
- `V3-DEVICE-MODEL.md` — RainMaker hierarchy adoption
- `V3-HARDWARE.md` — ESP32-C3 (R4), ESP32-S3 (R8/R16) — chip selection rationale
- `V3-MQTT-STANDARDS.md` — topic namespace, ACL rules
- `V3-CONFIGURATION.md` — env var catalog, step-ca CA setup, secret rotation schedule
- `V3-PRIVACY-COMPLIANCE.md` — PDPP analysis, subprocessors, breach response
- `V3-DPIA.md` — Data Protection Impact Assessment
- `V3-FACTORY-OPS.md` — factory flashing workflow, eFuse burn sequence
- `V3-OPS-RUNBOOK.md` — incident response runbook
- ADR-003 — multi-tenant RLS
- ADR-004 — cert-based MQTT auth
- ADR-012 — ESP32 chip selection (C3/S3 for Secure Boot v2)
- ADR-013 — firmware security (Secure Boot v2 + Flash Encryption)
