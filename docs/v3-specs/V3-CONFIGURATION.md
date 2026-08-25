# V3 — Configuration Management

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Ops Lead

---

## 1. Purpose

Single source of truth for all V3 configuration: env var catalog (organized by service), secret generation procedures (using step-ca for CA management — NOT raw OpenSSL CLI as in the original draft), secret rotation schedule, per-environment overrides, and Cloudflare geo-block configuration with explicit exception list.

This document supersedes the original V3-CONFIGURATION.md, which:
- Listed raw OpenSSL CLI commands for CA generation (replaced with step-ca, §3)
- Was missing `SECURE_BOOT_KEY`, `FLASH_ENCRYPTION_KEY`, `OTA_SIGNING_KEY` env vars (added §2.1.4)
- Did not specify per-environment overrides (added §5)
- Did not document Cloudflare geo-block exception list (added §6)

---

## 2. Complete env var catalog

### 2.1 Spring Boot (application backend)

#### 2.1.1 Core

| Env var | Required | Default | Description |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | yes | `local` | Profile: `local`, `staging`, `prod` (see §5) |
| `SERVER_PORT` | no | `8080` | HTTP listen port |
| `MANAGEMENT_SERVER_PORT` | no | `9090` | Actuator + Prometheus metrics port |
| `JAVA_TOOL_OPTIONS` | no | `-XX:MaxRAMPercentage=75 -XX:+UseG1GC` | JVM tuning |

#### 2.1.2 Database (Postgres)

| Env var | Required | Default | Description |
|---|---|---|---|
| `SPRING_DATASOURCE_URL` | yes | `jdbc:postgresql://localhost:5432/she_v3` | Postgres JDBC URL |
| `SPRING_DATASOURCE_USERNAME` | yes | `she_app` | App role (NOT superuser — does NOT have `BYPASSRLS`; the canonical RLS policy checks the `app.is_platform_admin` GUC itself, see §5.1 + P0-5) |
| `SPRING_DATASOURCE_PASSWORD` | yes | — | DB password |
| `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` | no | `20` | Per-instance connection pool |
| `SPRING_JPA_PROPERTIES_HIBERNATE_DIALECT` | no | `org.hibernate.dialect.PostgreSQLDialect` | |

**Canonical RLS policy (P0-5):** Applied to every tenant-scoped table. There is **no** `app.bypass_rls` GUC and **no** `BYPASSRLS` role — the policy itself checks a separate `app.is_platform_admin` GUC, set per-transaction by Spring Boot:

```sql
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON nodes
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );

-- Spring Boot sets these per request (scoped to the current transaction):
SET LOCAL app.tenant_id = '6f1c...';
SET LOCAL app.is_platform_admin = 'off';   -- 'on' for PLATFORM_ADMIN / SUPER_ADMIN only
```

#### 2.1.3 Cache (Redis)

| Env var | Required | Default | Description |
|---|---|---|---|
| `SPRING_DATA_REDIS_HOST` | yes | `localhost` | Redis host (sentinel-aware via `REDIS_SENTINEL_*`) |
| `SPRING_DATA_REDIS_PORT` | no | `6379` | |
| `SPRING_DATA_REDIS_PASSWORD` | yes | — | Redis password |
| `REDIS_SENTINEL_MASTER` | no | — | Sentinel master name (prod only) |
| `REDIS_SENTINEL_NODES` | no | — | Comma-separated `host:port` list (prod only) |

#### 2.1.4 MQTT (EMQX)

| Env var | Required | Default | Description |
|---|---|---|---|
| `MQTT_BROKER_URL` | yes | `ssl://localhost:8883` | Paho scheme: `ssl://` (prod) or `tcp://` (local) |
| `MQTT_SUPERUSER_USERNAME` | yes | `she-backend` | Superuser username (ACL bypassed) |
| `MQTT_SUPERUSER_PASSWORD` | yes | — | Superuser password |
| `MQTT_SHARED_SUBSCRIPTION_GROUP` | no | `she-backend` | Shared subscription group name |
| `MQTT_CLIENT_ID_PREFIX` | no | `she-backend` | Appended with instance ID for `she-backend-1`, `-2`, etc. |

#### 2.1.5 Auth + secrets

| Env var | Required | Default | Description |
|---|---|---|---|
| `JWT_SIGNING_PRIVATE_KEY_PATH` | yes | `/etc/she/keys/jwt_ed25519.pem` | Ed25519 private key for JWT signing (PEM, PKCS#8) — replaces the legacy `JWT_SECRET` HMAC key (P1-6) |
| `JWT_SIGNING_PUBLIC_KEYS` | yes | — | JSON array of `{kid, public_key_pem}` entries — Spring Boot accepts all listed keys during the rotation window (P1-6, multi-key rotation, no forced re-login) |
| `JWT_SIGNING_KEY_ID` | yes | e.g., `2025q1` | `kid` JWT header value for the currently-signing key (must match one entry in `JWT_SIGNING_PUBLIC_KEYS`) |
| `KEK` | yes | — | Key Encryption Key (AES-256-GCM master key, base64) — encrypts TOTP secrets + CA intermediate key |
| `MFA_ISSUER_NAME` | no | `SmartHomeEthiopia` | TOTP issuer name in otpauth URI |

#### 2.1.6 CA + cert management (step-ca integration)

| Env var | Required | Default | Description |
|---|---|---|---|
| `STEP_CA_URL` | yes | `https://step-ca.internal:9000` | step-ca server URL (internal network only) |
| `STEP_CA_FINGERPRINT` | yes | — | Root CA fingerprint (for step-ca client bootstrap) |
| `STEP_CA_PROVISIONER_NAME` | yes | `she-device-provisioner` | JWK provisioner name |
| `STEP_CA_PROVISIONER_PASSWORD` | yes | — | JWK provisioner password (decrypts the provisioner key) |
| `CA_INTERMEDIATE_CERT_PATH` | yes | `/etc/she/ca/intermediate.crt` | Intermediate CA cert (bundled with root for EMQX) |
| `CA_BUNDLE_PATH` | yes | `/etc/she/ca/ca_bundle.pem` | Root + active intermediate + previous intermediate (during rotation overlap) |
| `CRL_PUBLISH_BASE_URL` | yes | `https://she.et/ca` | Public URL where CRLs are published |

> **Replaces:** the original draft specified `CA_ROOT_KEY_PATH` and `CA_INTERMEDIATE_KEY_PATH` env vars, implying Spring Boot would directly hold CA private keys. **This is removed.** CA private keys live inside step-ca — in production the **intermediate CA key is HSM-backed (YubiHSM 2)** via step-ca's PKCS#11 integration (P1-24 — not merely KEK-encrypted at rest). The root CA key is air-gapped (offline laptop, brought online only for intermediate rotation). Spring Boot calls step-ca's REST API to sign device certs — it never touches CA private keys directly.

#### 2.1.7 Firmware security keys (factory + OTA)

| Env var | Required | Default | Description |
|---|---|---|---|
| `SECURE_BOOT_KEY_PATH` | yes (factory only) | `/etc/she/keys/secure_boot_v2.pem` | RSA-PSS 3072-bit private key for Secure Boot v2 image signing — used ONLY by the factory signing workstation, never on the cloud |
| `SECURE_BOOT_PUBKEY_DIGEST` | yes (factory only) | — | SHA-256 digest of Secure Boot v2 public key (burned into eFuse — for verification) |
| `FLASH_ENCRYPTION_KEY_PATH` | no | — | Per-device Flash Encryption key (generated at factory, written to eFuse — not stored as env var) |
| `OTA_SIGNING_KEY_PATH` | yes | `/etc/she/keys/ota_signing_ed25519.pem` | Ed25519 private key for OTA image signing — used by OTA release pipeline only, never on production cloud |
| `OTA_SIGNING_PUBKEY` | yes | — | Ed25519 public key (base64) — embedded in firmware, burned into device eFuse `BLOCK_KEY_SECURE` |

> **Critical:** `SECURE_BOOT_KEY_PATH` and `OTA_SIGNING_KEY_PATH` are NEVER deployed to the production cloud. They live only on offline signing workstations (air-gapped). The cloud only ever sees the public keys. See `V3-SECURITY-MODEL.md` §5 + §8.2.

#### 2.1.8 Object storage (MinIO)

| Env var | Required | Default | Description |
|---|---|---|---|
| `OTA_FIRMWARE_STORAGE_URL` | yes | `https://minio.she.et` | MinIO endpoint |
| `OTA_FIRMWARE_BUCKET` | no | `she-firmware` | Bucket for OTA images |
| `OTA_FIRMWARE_ACCESS_KEY` | yes | — | MinIO access key (dedicated IAM user, scope: `she-firmware` bucket only) |
| `OTA_FIRMWARE_SECRET_KEY` | yes | — | MinIO secret key |
| `OTA_PRESIGNED_URL_TTL_SECONDS` | no | `900` | 15-minute TTL for presigned download URLs |
| `B2B_ASSETS_BUCKET` | no | `she-b2b-assets` | Bucket for tenant logos / branding |
| `AUDIT_EXPORT_BUCKET` | no | `she-audit-exports` | Bucket for CSV audit exports (30-day lifecycle) |

#### 2.1.9 Payments (Chapa)

| Env var | Required | Default | Description |
|---|---|---|---|
| `CHAPA_API_BASE_URL` | yes | `https://api.chapa.co/v1` | Chapa API base |
| `CHAPA_API_KEY` | yes | — | Chapa API key (from Chapa dashboard) |
| `CHAPA_WEBHOOK_SECRET` | yes | — | HMAC secret for verifying Chapa webhook signatures |
| `CHAPA_WEBHOOK_IP_WHITELIST` | yes | `41.216.199.0/24,196.188.124.0/24` | Comma-separated CIDR list — Chapa egress IPs (also in Cloudflare WAF, §6) |

#### 2.1.10 Push notifications

| Env var | Required | Default | Description |
|---|---|---|---|
| `FCM_SERVICE_ACCOUNT_PATH` | yes | `/etc/she/secrets/fcm-service-account.json` | Firebase service account JSON (file path on disk) |
| `FCM_PROJECT_ID` | yes | — | Firebase project ID |
| `APNS_KEY_ID` | yes | — | Apple APNs key ID (10-char) |
| `APNS_TEAM_ID` | yes | — | Apple Developer team ID |
| `APNS_KEY_PATH` | yes | `/etc/she/secrets/apns-key.p8` | Path to .p8 key file |
| `APNS_BUNDLE_ID` | yes | `et.smart-home.app` | App bundle ID |
| `APNS_PRODUCTION` | no | `true` | Use production APNs gateway (false = sandbox) |

#### 2.1.11 SMTP

| Env var | Required | Default | Description |
|---|---|---|---|
| `SMTP_HOST` | yes | — | SMTP server (e.g., `smtp.gmail.com` or Ethio Telecom SMTP) |
| `SMTP_PORT` | no | `587` | |
| `SMTP_USERNAME` | yes | — | |
| `SMTP_PASSWORD` | yes | — | |
| `SMTP_FROM` | yes | `noreply@she.et` | From address |
| `SMTP_FROM_NAME` | no | `Smart Home Ethiopia` | Display name |

#### 2.1.12 Voice (Picovoice, SHE-R16 only)

| Env var | Required | Default | Description |
|---|---|---|---|
| `PICOVOICE_ACCESS_KEY` | yes (factory only) | — | Picovoice SDK license key — baked into firmware at factory, NOT deployed to cloud |

### 2.2 EMQX (MQTT broker)

| Env var | Required | Default | Description |
|---|---|---|---|
| `EMQX_NODE__NAME` | yes | `emqx@10.0.0.11` | Erlang node name (unique per cluster node) |
| `EMQX_NODE__COOKIE` | yes | — | Erlang magic cookie (shared secret for cluster mesh) — same on all 3 nodes |
| `EMQX_DASHBOARD__DEFAULT_PASSWORD` | yes | — | Dashboard admin password (https://broker.she.et:18083) |
| `EMQX_LISTENER__SSL__DEFAULT__SSL_OPTIONS__KEYFILE` | yes | `/etc/emqx/certs/server.key` | Server private key |
| `EMQX_LISTENER__SSL__DEFAULT__SSL_OPTIONS__CERTFILE` | yes | `/etc/emqx/certs/server.crt` | Server cert (signed by our CA) |
| `EMQX_LISTENER__SSL__DEFAULT__SSL_OPTIONS__CACERTFILE` | yes | `/etc/emqx/certs/ca_bundle.pem` | CA bundle: root + BOTH intermediates (during rotation overlap) |
| `EMQX_AUTHENTICATION__HTTP__URL` | yes | `https://she-backend.internal:8080/internal/mqtt/auth` | Spring Boot auth endpoint |
| `EMQX_AUTHORIZATION__SOURCES` | yes | (JSON array, see below) | EMQX 5.x authorization sources — HOCON equivalent of `authorization { sources = [ { type = file, ... } ] }`. **Do NOT use the deprecated flattened `EMQX_AUTHORIZATION__SOURCE = http` / `EMQX_AUTHORIZATION__URL = ...` env vars** — they are EMQX 4.x style and silently ignored on 5.x (P1-32). |

**`EMQX_AUTHORIZATION__SOURCES` example value** (P1-32, EMQX 5.x HOCON serialized as JSON for env var injection):

```json
[
  {
    "type": "file",
    "enable": true,
    "rules": [
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/+/telemetry"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/+/status"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/+/params/local"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/+/energy"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/+/ota/status"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/+/command"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/+/params/remote"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/+/ota/url"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/${clientid}/telemetry"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/${clientid}/status"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/${clientid}/params/local"},
      {"permission":"allow","action":"publish","topic":"she/+/+/+/${clientid}/energy"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/${clientid}/command"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/${clientid}/params/remote"},
      {"permission":"allow","action":"subscribe","topic":"she/+/+/+/${clientid}/ota/url"}
    ]
  }
]
```

Alternatively, write the same HOCON to `/etc/emqx/cluster-override.conf` and let EMQX pick it up at boot. The full HOCON form (and the rationale) is documented in `V3-ARCHITECTURE.md` §6.2.

### 2.3 Postgres

| Env var | Required | Default | Description |
|---|---|---|---|
| `POSTGRES_DB` | yes | `she_v3` | Database name |
| `POSTGRES_USER` | yes | `she_app` | App role (NOT superuser) |
| `POSTGRES_PASSWORD` | yes | — | App role password |
| `POSTGRES_SUPERUSER_PASSWORD` | yes (ops only) | — | `postgres` superuser password — used only for migrations, NOT exposed to Spring Boot |
| `PGDATA` | no | `/var/lib/postgresql/data` | Data directory |
| `POSTGRES_INITDB_ARGS` | no | `--data-checksums` | Enable data checksums on initdb |

TimescaleDB extension config (in `postgresql.conf`, not env var):
```ini
timescaledb.max_background_workers = 8
timescaledb.telemetry_level = off
shared_preload_libraries = 'timescaledb,pg_stat_statements'
```

### 2.4 Redis

| Env var | Required | Default | Description |
|---|---|---|---|
| `REDIS_PASSWORD` | yes | — | Redis AUTH password |
| `REDIS_SENTINEL_QUORUM` | no | `2` | Sentinel quorum (3-node sentinel cluster) |
| `REDIS_MAXMEMORY` | no | `2gb` | Max memory per node |
| `REDIS_MAXMEMORY_POLICY` | no | `volatile-lru` | Eviction policy |

### 2.5 MinIO

| Env var | Required | Default | Description |
|---|---|---|---|
| `MINIO_ROOT_USER` | yes | — | Admin user (used only for bootstrapping) |
| `MINIO_ROOT_PASSWORD` | yes | — | Admin password |
| `MINIO_VOLUMES` | yes | `/data/minio` | Storage path |
| `MINIO_BROWSER_REDIRECT_URL` | yes | `https://minio-console.she.et` | Console URL |
| `MINIO_SERVER_URL` | yes | `https://minio.she.et` | API URL |

Per-bucket IAM users are created via `mc admin policy` — separate access keys per bucket (firmware, b2b-assets, audit-exports).

### 2.6 Cloudflare

| Env var | Required | Default | Description |
|---|---|---|---|
| `CLOUDFLARE_API_TOKEN` | yes (ops only) | — | API token for DNS + WAF rule management (scoped to single zone) |
| `CLOUDFLARE_ZONE_ID` | yes | — | Zone ID for `she.et` |
| `CLOUDFLARE_ORIGIN_CERT_PATH` | yes | `/etc/nginx/certs/origin.crt` | Cloudflare Origin CA cert (15-yr validity, free) |
| `CLOUDFLARE_ORIGIN_KEY_PATH` | yes | `/etc/nginx/certs/origin.key` | Origin private key |
| `CLOUDFLARE_AUTHENTICATED_ORIGIN_PULLS` | no | `true` | Require Cloudflare to present client cert on origin pull (mitigates direct-origin attacks) |

### 2.7 Nginx

| Env var | Required | Default | Description |
|---|---|---|---|
| `NGINX_UPSTREAM_SPRING_BOOT_1` | yes | `10.0.0.21:8080` | Spring Boot instance 1 |
| `NGINX_UPSTREAM_SPRING_BOOT_2` | yes | `10.0.0.22:8080` | Spring Boot instance 2 |
| `NGINX_UPSTREAM_ADMIN_WEB` | yes | `10.0.0.31:3000` | Next.js admin app |
| `NGINX_CLIENT_MAX_BODY_SIZE` | no | `50m` | Max upload size (firmware images up to 8 MB) |

---

## 3. CA management — step-ca setup (REPLACES raw OpenSSL)

> **Critical:** The original draft specified raw OpenSSL CLI for CA generation. **This is removed.** Raw OpenSSL has no proper serial number tracking, no CRL automation, no audit trail, no rotation workflow. SHE V3 uses **step-ca** (Smallstep) — a production-grade CA server.

### 3.1 Why step-ca

- Automated CRL generation + publishing (cron-driven, **every 6 hours** — P1-22)
- JWK signer with KEK-protected key (AES-256-GCM at rest)
- Audit log of every cert signing operation (who signed what, when)
- ACME server (for server cert issuance to EMQX, Spring Boot internal)
- REST API for Spring Boot to call during device provisioning (no shell exec)
- Two-step bootstrap (root CA offline, intermediate CA online)

### 3.2 Initial bootstrap (one-time, on air-gapped machine)

```bash
# 1. Install step-cli + step-ca on the air-gapped machine (no network)
#    https://smallstep.com/docs/step-ca/installation

# 2. Initialize step-ca with offline root CA (this generates root keypair ONCE)
step ca init \
  --name "Smart Home Ethiopia Production CA" \
  --dns "step-ca.internal.she.et" \
  --address ":9000" \
  --provisioner "she-device-provisioner" \
  --password-file /secure/step-ca-password.txt \
  --deployment-type standalone

# This creates:
#   $STEPPATH/certs/root_ca.crt     (RSA 4096, 20-yr validity, self-signed)
#   $STEPPATH/certs/root_ca_key.pem (RSA 4096, encrypted with password-file)
#   $STEPPATH/certs/intermediate_ca.crt  (RSA 4096, 10-yr, signed by root)
#   $STEPPATH/certs/intermediate_ca_key.pem (encrypted)
#   $STEPPATH/config/ca.json        (server config)
#   $STEPPATH/config/defaults.json  (client defaults)

# 3. Verify root CA
step certificate inspect $STEPPATH/certs/root_ca.crt

# 4. Move root key to offline storage (USB drive in safe)
mv $STEPPATH/certs/root_ca_key.pem /mnt/secure-usb/root_ca_key.pem
# (step-ca can run without root key after init — intermediate is sufficient for signing)

# 5. Copy intermediate cert + ca_bundle to EMQX nodes + Spring Boot
cat $STEPPATH/certs/root_ca.crt $STEPPATH/certs/intermediate_ca.crt > ca_bundle.pem
scp ca_bundle.pem emqx-1:/etc/emqx/certs/
scp ca_bundle.pem emqx-2:/etc/emqx/certs/
scp ca_bundle.pem emqx-3:/etc/emqx/certs/
scp ca_bundle.pem she-backend:/etc/she/ca/
```

### 3.3 Start step-ca server (on internal network)

```bash
# On step-ca.internal (internal-only IP, no public exposure)
step-ca $STEPPATH/config/ca.json --password-file /secure/step-ca-password.txt &

# Verify (from Spring Boot host):
step ca bootstrap \
  --ca-url https://step-ca.internal:9000 \
  --fingerprint $(step certificate fingerprint /etc/she/ca/ca_bundle.pem)

# Test signing a cert:
echo "CN=test.she.internal" | step certificate sign - \
  --ca-url https://step-ca.internal:9000 \
  --provisioner she-device-provisioner \
  --provisioner-password-file /secure/provisioner-password.txt
```

### 3.4 Spring Boot integration (device cert signing during BLE provisioning)

```java
// Spring Boot calls step-ca REST API to sign device cert
// (Spring Boot does NOT hold the CA private key — only the provisioner password)

@RestController
@RequestMapping("/internal/ca")
public class CaSignerController {

    @Value("${step.ca.url}")
    private String stepCaUrl;

    @Value("${step.ca.provisioner.name}")
    private String provisionerName;

    @Value("${step.ca.provisioner.password}")
    private String provisionerPassword;  // from env var, never logged

    @PostMapping("/sign-device")
    public SignedCert signDeviceCert(@RequestBody String csrPem) {
        // POST https://step-ca.internal:9000/sign
        //   body: { csr: "...", provisioner: "she-device-provisioner" }
        //   headers: { Authorization: ... }  (provisioner password is sent as Basic auth)
        SignedCert cert = stepCaClient.sign(csrPem, provisionerName, provisionerPassword);
        // cert.chain contains device cert + intermediate cert
        return cert;
    }
}
```

The full BLE provisioning flow is documented in `V3-ARCHITECTURE.md` §4.4.

### 3.5 CRL publishing

step-ca publishes CRLs at:
- `https://she.et/ca/{intermediate_id}/crl.pem`

EMQX + Spring Boot fetch CRLs **every 6 hours** (cron, P1-22 — was 24 h) and cache locally. Revocation SLA: propagation < 6 hours (bounded by the CRL refresh interval). If emergency revocation is needed sooner, push the CRL ad-hoc and restart EMQX auth cache. If a CRL fetch fails for > 48 h, EMQX enters "fail-closed" mode (rejects all new connections until CRL is fresh).

### 3.6 Intermediate-CA rotation (yearly)

See `V3-SECURITY-MODEL.md` §3.3 for the full procedure. Summary:
1. Generate new intermediate via step-ca (signed by root, 10-yr)
2. Deploy new `ca_bundle.pem` (root + old intermediate + new intermediate) to all EMQX nodes + Spring Boot
3. Rolling-restart EMQX nodes (cluster tolerates 1-node loss)
4. New device certs use new intermediate; existing device certs continue to validate via bundle
5. After 10 years (old intermediate's notAfter), remove old intermediate from bundle

---

## 4. Secret generation commands

### 4.1 JWT signing key (EdDSA / Ed25519, P1-6)

> **P1-6 — JWT algorithm rotation:** JWTs are now signed with **EdDSA (Ed25519)**, NOT HS256. Each key has a `kid` (key ID) header so Spring Boot can accept a set of public keys during the rotation window — **no forced re-login** when rotating. The legacy `JWT_SECRET` HMAC env var is replaced by `JWT_SIGNING_PRIVATE_KEY_PATH` + `JWT_SIGNING_PUBLIC_KEYS` + `JWT_SIGNING_KEY_ID` (see §2.1.5).

```bash
# Generate Ed25519 private key (offline signing workstation, then deployed to Spring Boot)
openssl genpkey -algorithm ed25519 -out /secure/keys/jwt_ed25519.pem

# Extract public key (PEM) — added to JWT_SIGNING_PUBLIC_KEYS JSON array on all Spring Boot instances
openssl pkey -in /secure/keys/jwt_ed25519.pem -pubout -out /secure/keys/jwt_ed25519.pub

# kid convention: <year>q<quarter> (e.g., 2025q1) — bumped on every rotation
```

Spring Boot's `JwtDecoder` is configured with a `Map<String, verifier>` keyed by `kid` — every key in `JWT_SIGNING_PUBLIC_KEYS` is accepted. New tokens are signed with the current `JWT_SIGNING_KEY_ID`; existing tokens continue to validate until their natural expiry.

### 4.2 KEK (Key Encryption Key — AES-256-GCM master key)

```bash
# 32 bytes of random = 256-bit AES key, base64-encoded
openssl rand -base64 32
# Output: e.g. "8jF1sT6yH0aZ3bU5iL+Kp9vW2xQ7mN4cR8jF1sT6y="

# Set as KEK env var. Used to encrypt:
#   - users.totp_secret_encrypted
#   - step-ca JWK provisioner key (already encrypted by step-ca itself)
```

### 4.3 Ed25519 OTA signing keypair

```bash
# Generate Ed25519 private key (offline signing workstation)
openssl genpkey -algorithm ed25519 -out /secure/keys/ota_signing_ed25519.pem

# Extract public key
openssl pkey -in /secure/keys/ota_signing_ed25519.pem -pubout -out /secure/keys/ota_signing_ed25519.pub

# Base64-encode the public key for embedding in firmware sdkconfig
openssl pkey -in /secure/keys/ota_signing_ed25519.pem -pubout -outform DER | base64 -w0
# Output: e.g. "MCowBQYDK2VwAyEA9k7..."

# Set OTA_SIGNING_PUBKEY env var (base64 public key — embedded in firmware)
# Set OTA_SIGNING_KEY_PATH = /secure/keys/ota_signing_ed25519.pem (offline signing workstation only)
```

### 4.4 Secure Boot v2 keypair (RSA-PSS 3072-bit)

```bash
# Generate RSA 3072-bit private key (offline signing workstation)
openssl genrsa -out /secure/keys/secure_boot_v2.pem 3072

# Extract public key
openssl rsa -in /secure/keys/secure_boot_v2.pem -pubout -out /secure/keys/secure_boot_v2.pub

# Compute digest of public key (this is what gets burned into eFuse SECURE_BOOT_EN)
openssl rsa -in /secure/keys/secure_boot_v2.pem -pubout -outform DER | \
  openssl dgst -sha256 -binary | xxd -p -c 32
# Output: e.g. "a3b1c4d2..."

# Set SECURE_BOOT_KEY_PATH = /secure/keys/secure_boot_v2.pem (offline signing workstation only)
# Set SECURE_BOOT_PUBKEY_DIGEST = a3b1c4d2... (used by esptool.py burn_key_digest)
```

### 4.5 step-ca root + intermediate (initial bootstrap)

See §3.2 above. step-ca generates both root + intermediate during `step ca init`. Do NOT use raw `openssl genrsa` for CA keys — step-ca manages the lifecycle (CRLs, audit, rotation).

### 4.6 Chapa webhook secret

```bash
openssl rand -base64 32
# Set as CHAPA_WEBHOOK_SECRET on Spring Boot AND configure in Chapa dashboard
```

### 4.7 Postgres passwords

```bash
# App role password (20-char alphanumeric)
openssl rand -base64 15 | tr -d '+/=' | head -c 20

# Superuser password (32-char alphanumeric — stronger)
openssl rand -base64 24 | tr -d '+/=' | head -c 32
```

### 4.8 Redis password, EMQX dashboard, MQTT superuser

```bash
openssl rand -base64 24 | tr -d '+/=' | head -c 24
```

---

## 5. Per-environment configuration

### 5.1 Development (`local` profile)

- Single machine, all services via `docker-compose up`
- Postgres + Redis + EMQX + MinIO + Spring Boot in containers
- No RLS enforcement (`SET LOCAL app.is_platform_admin = 'on'` for fast iteration — flagged in logs; canonical GUC per P0-5, the `she_app` role still does NOT have `BYPASSRLS`)
- Self-signed certs (or step-ca in local mode)
- No geo-block
- No Cloudflare (Nginx on localhost:8080)
- Mock Chapa + FCM + APNs endpoints
- Debug logging enabled
- Spring Boot DevTools hot-reload

`.env.local` example:
```bash
SPRING_PROFILES_ACTIVE=local
SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/she_v3
SPRING_DATASOURCE_USERNAME=she_app
SPRING_DATASOURCE_PASSWORD=dev-password-not-for-prod
JWT_SIGNING_PRIVATE_KEY_PATH=/etc/she/keys/jwt_ed25519.pem
JWT_SIGNING_PUBLIC_KEYS=[{"kid":"2025q1","public_key_pem":"-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA...\n-----END PUBLIC KEY-----\n"}]
JWT_SIGNING_KEY_ID=2025q1
KEK=devKekNotForProd000000000000000==
MQTT_BROKER_URL=tcp://localhost:1883
MQTT_SUPERUSER_USERNAME=she-backend
MQTT_SUPERUSER_PASSWORD=dev-mqtt-password
# Flash Encryption + Secure Boot DISABLED in dev (use ESP-IDF default config)
```

### 5.2 Staging (`staging` profile)

- Ethio Telecom Cloud, separate VMs from prod
- Full RLS enforcement (no bypass)
- step-ca with staging intermediate CA (separate from prod CA — different root)
- Self-signed server certs (no Let's Encrypt in staging — saves rate-limit budget)
- Cloudflare in front, with same geo-block as prod
- Real Chapa (sandbox mode) + FCM + APNs (sandbox)
- Info logging, full metrics
- Database seeded with synthetic test data (100 tenants, 5,000 devices)

### 5.3 Production (`prod` profile)

- Ethio Telecom Cloud, 6 VMs (see `V3-ARCHITECTURE.md` §11)
- Full RLS enforcement
- step-ca with production intermediate CA
- Server certs signed by our own CA (not Let's Encrypt — keeps trust within our PKI)
- Cloudflare Business in front, with geo-block + exception list (§6)
- Real Chapa (live mode) + FCM + APNs (production gateway)
- Warn logging, full metrics, structured logs to Loki
- TimescaleDB compression + retention policies active
- All Flash Encryption + Secure Boot + Ed25519 OTA signing enforced on devices

---

## 6. Cloudflare geo-block configuration

### 6.1 Block rule (WAF custom rule)

```
Rule name: Block non-ET traffic
Expression:
  (not ip.geoip.country in {"ET"})
Action: Block
Order: 2  (after exception rules)
```

Applied at zone level (`she.et`), covers all hostnames (`api.she.et`, `admin.she.et`, `app.she.et`).

### 6.2 Exception rules (allow before block)

These must be ordered BEFORE the block rule (Cloudflare evaluates rules in order).

```
Rule 1: Allow Chapa webhook egress
Expression:
  (ip.src in {41.216.199.0/24, 196.188.124.0/24})
  and (http.request.uri.path eq "/api/v3/payments/webhook/chapa")
Action: Allow
Order: 1

Rule 2: Allow Google FCM egress (server-to-server push)
Expression:
  (ip.src in {35.191.0.0/16, 130.211.0.0/22})
  and (http.request.uri.path eq "/api/v3/internal/push/fcm-callback")
Action: Allow
Order: 1

Rule 3: Allow SHE office VPN (Addis Ababa)
Expression:
  (ip.src in {197.156.78.42/32})
Action: Allow
Order: 1
```

> **P1-31 — Office VPN rule:** Cloudflare sees public IPs, not private ranges. The previous draft listed `10.88.0.0/16` (RFC 1918 private range) — Cloudflare would never observe that source IP on inbound traffic. Use the office's public NAT egress IP assigned by Ethio Telecom (example: `197.156.78.42/32`).
>
> **P1-30 — APNs whitelist removed:** The previous draft had a separate rule whitelisting `17.0.0.0/8` (Apple Inc. corporate range) for an `/api/v3/internal/push/apns-callback` endpoint. **APNs is a push service — Apple does not make inbound HTTP callbacks to your origin.** The whitelist was dead weight (16M Apple corporate IPs that never initiate inbound HTTP to SHE). The rule has been removed. If delivery receipts are needed, configure a URL in the APNs payload — that is an outbound HTTPS call FROM SHE TO Apple, not inbound.

### 6.3 Devices bypass Cloudflare entirely

ESP32 devices do NOT use Cloudflare. They connect directly to EMQX on port 8883 (MQTTS), exposed via the Ethio Telecom Cloud public IP (not proxied through Cloudflare). The geo-block applies only to HTTPS/WSS traffic on ports 443/80.

This is intentional:
- Cloudflare's TLS termination would break mutual-TLS (Cloudflare does not forward client certs in Business tier)
- MQTT traffic on Cloudflare requires Enterprise tier (Spectrum feature)
- Direct device → broker connection is more reliable (one fewer hop)

### 6.4 Authenticated Origin Pulls

To prevent attackers from bypassing Cloudflare and hitting the Nginx origin directly (e.g., by discovering the origin's public IP):

```
Nginx config:
  ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull.crt;
  ssl_verify_client on;
  ssl_verify_depth 2;
```

Cloudflare presents a client cert (from `cloudflare-origin-pull.crt` — published by Cloudflare at https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/) on every origin request. Nginx rejects any request that doesn't present this cert, blocking direct-origin attacks.

### 6.5 Cloudflare Workers (V3.1, optional)

For V3 GA, no Cloudflare Workers are deployed. V3.1 may add a Worker for edge-side push notification batching (FCM/APNs) to reduce origin load.

---

## 7. Secret rotation schedule

| Secret | Frequency | Impact | Procedure |
|---|---|---|---|
| JWT signing key (Ed25519) | Quarterly | **No forced re-login** — old key stays in `JWT_SIGNING_PUBLIC_KEYS` until existing tokens naturally expire (P1-6) | Generate new Ed25519 keypair with new `kid` (e.g., `2025q2`), add public key to `JWT_SIGNING_PUBLIC_KEYS` array on all Spring Boot instances, switch `JWT_SIGNING_KEY_ID` to new kid, rolling restart. Remove old key from the array only after the longest access-token TTL has elapsed (USER refresh 30d → wait 30d, ADMIN 8h → wait 8h, SUPER 4h → wait 4h). |
| `SPRING_DATASOURCE_PASSWORD` | Quarterly | Brief downtime (1-2 min per instance) | `ALTER USER she_app PASSWORD ...`, update env vars, rolling restart |
| `SPRING_DATA_REDIS_PASSWORD` | Quarterly | Brief downtime | `CONFIG SET requirepass ...`, update env vars, rolling restart |
| `MQTT_SUPERUSER_PASSWORD` | Quarterly | No downtime | Update EMQX dashboard user, update Spring Boot env, rolling restart |
| `STEP_CA_PROVISIONER_PASSWORD` | Yearly | No downtime | step-ca `step ca provisioner update` command, update Spring Boot env |
| Intermediate CA (step-ca) | Yearly | No downtime (overlap window — see `V3-SECURITY-MODEL.md` §3.3) | Generate new intermediate, deploy bundle, sign new certs with new intermediate |
| `KEK` | Yearly | No downtime (scripted re-encryption) | Generate new KEK, run `--run-rekek-migration`, update env, restart |
| Ed25519 OTA signing key | On compromise only | New devices only — existing devices cannot update OTA key (eFuse is immutable) | Generate new keypair, ship new firmware signed with both old + new keys (transition period), new hardware rev burns new pubkey into eFuse |
| Secure Boot v2 key | Never (irreversible) | — | eFuse is one-time programmable — once burned, cannot be rotated without new hardware rev |
| `CHAPA_API_KEY` | Per Chapa policy | Brief payment window downtime | Rotate in Chapa dashboard, update env, restart |
| `CHAPA_WEBHOOK_SECRET` | Per Chapa policy | Webhook signature verification fails until both ends updated | Coordinate with Chapa support, rotate simultaneously |
| FCM service account | Per Google policy (max 2-yr) | Push notifications fail until new key deployed | Rotate in Firebase console, download new JSON, update `FCM_SERVICE_ACCOUNT_PATH` |
| APNs key | Per Apple policy (max 2-yr) | Push notifications fail until new key deployed | Rotate in Apple Developer console, download new .p8, update `APNS_KEY_PATH` |
| `EMQX_NODE__COOKIE` | On cluster rebuild | Full cluster downtime | All nodes must share cookie — rotate by rebuilding cluster |

### 7.1 Rotation tracking

All secret rotations are tracked in `audit_log` (event type `SECRET_ROTATED`), with fields: `secret_name`, `rotated_by_user_id`, `old_version_hash` (sha256 of old value, not the value itself), `new_version_hash`, `timestamp`.

The `V3-OPS-RUNBOOK.md` includes a quarterly rotation checklist that ops runs as part of the release cadence.

### 7.2 Tech debt: KEK as single point of failure

**Honest acknowledgment:** The current secrets model — env vars encrypted at rest by a single KEK (AES-256-GCM) — is **workable at V3 scale (2-3 engineers, ≤10k devices) but is NOT a solved problem.** The KEK is a single point of catastrophic exposure: if the KEK is compromised, every encrypted secret in the environment (DB passwords, MQTT backend keys, TOTP secrets, JWT signing keys) is exposed simultaneously.

**Why it's acceptable for V3 GA:**
- The KEK itself is stored only in the systemd environment of the Spring Boot service user (`0400` permissions, not committed to git)
- HSM-backed (YubiHSM 2) for the CA intermediate key + MQTT backend key — the two highest-value secrets
- 2-3 engineer team with strict access controls — KEK is known to ≤2 people
- Yearly rotation limits exposure window

**Why it's tech debt, not a solution:**
- KEK rotation (`--run-rekek-migration`) re-encrypts everything with the new key — but the old KEK must remain accessible during the migration window, creating a dual-key exposure period
- No per-secret access control — anyone with the KEK can decrypt all secrets
- No audit trail for individual secret access (only rotation is logged)
- If the KEK is leaked, rotation doesn't help — the attacker who has the old KEK can still decrypt old env-var backups

**V3.1+ migration path:** Move to a real secrets manager (HashiCorp Vault, AWS Secrets Manager, or Doppler) with:
- Per-secret ACLs (Spring Boot can read `db/password` but not `ca/intermediate/key`)
- Dynamic secrets (DB credentials generated per-request, short TTL)
- Audit log for every secret access (not just rotation)
- KEK eliminated — the secrets manager IS the KEK, backed by HSM

**Trigger for migration:** Any of: (a) team grows beyond 5 engineers, (b) device count exceeds 10,000, (c) any security incident involving env-var access, (d) B2B customer requires SOC 2 Type II (which mandates per-secret access controls).

---

## 8. Deployment artifacts

### 8.1 Configuration file locations on production VMs

| Path | Contents | Permissions |
|---|---|---|
| `/etc/she/env/{spring-boot,emqx,postgres,redis,minio,nginx}.env` | Per-service env vars | `0400` (service user) |
| `/etc/she/ca/ca_bundle.pem` | Root + intermediates (public) | `0644 root:root` |
| `/etc/she/ca/intermediate.crt` | Active intermediate (public) | `0644 root:root` |
| `/etc/she/secrets/fcm-service-account.json` | FCM service account | `0400 she-app:she-app` |
| `/etc/she/secrets/apns-key.p8` | APNs key | `0400 she-app:she-app` |
| `/etc/emqx/certs/server.{crt,key}` | EMQX server cert/key | `0644` / `0400 emqx:emqx` |
| `/etc/nginx/certs/origin.{crt,key}` | Cloudflare Origin cert/key | `0644` / `0400 nginx:nginx` |
| `/etc/nginx/certs/cloudflare-origin-pull.crt` | Cloudflare Origin Pull CA | `0644 nginx:nginx` |

### 8.2 Secret deployment via systemd

Spring Boot deployed as systemd service, env vars loaded via `EnvironmentFile=`:

```ini
# /etc/systemd/system/she-backend.service
[Unit]
Description=SHE V3 Spring Boot Backend
After=network-online.target postgresql.service redis.service

[Service]
Type=simple
User=she-app
Group=she-app
WorkingDirectory=/opt/she-backend
EnvironmentFile=/etc/she/env/spring-backend.env
ExecStart=/usr/bin/java -jar /opt/she-backend/she-backend.jar
Restart=on-failure
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/she /var/cache/she
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

All `/etc/she/` files monitored via AIDE (Advanced Intrusion Detection Environment) — daily snapshot + alert on any change.

---

## 9. What changed from the V3 draft

| Issue in draft | Fix in this version |
|---|---|
| Used raw OpenSSL CLI for CA generation | Replaced with **step-ca** (§3) — proper lifecycle, CRL automation, audit trail; intermediate CA key is **HSM-backed (YubiHSM 2)** in production (P1-24) |
| Used HS256 JWT with shared `JWT_SECRET` HMAC key | Replaced with **EdDSA (Ed25519)** signing key + `kid` header + `JWT_SIGNING_PUBLIC_KEYS` array — multi-key rotation window, no forced re-login (P1-6) |
| CRL refresh interval was 24 h | Changed to **every 6 hours** (revocation SLA < 6 h, P1-22) |
| Listed `CA_ROOT_KEY_PATH` env var (Spring Boot would hold CA root key) | **Removed** — Spring Boot never touches CA private keys; calls step-ca REST API instead |
| Missing `SECURE_BOOT_KEY_PATH`, `FLASH_ENCRYPTION_KEY_PATH`, `OTA_SIGNING_KEY_PATH` env vars | Added §2.1.7 with note that signing keys live only on offline workstations |
| No per-environment config | Added §5 with `local`, `staging`, `prod` profiles |
| Cloudflare geo-block listed without exception list | Added §6 with Chapa / FCM / office VPN whitelisted IPs (APNs rule **removed** per P1-30 — push services do not initiate inbound HTTP; office VPN switched from private `10.88.0.0/16` to public NAT egress `197.156.78.42/32` per P1-31) |
| RLS bypass via `app.bypass_rls = 'on'` GUC + dedicated `app_bypass_rls` BYPASSRLS role | Replaced with canonical policy (P0-5) — `app.is_platform_admin` GUC checked by the policy itself; `she_app` does NOT have `BYPASSRLS` |
| EMQX authorization config used flattened `EMQX_AUTHORIZATION__SOURCE` / `EMQX_AUTHORIZATION__URL` env vars (4.x style) | Replaced with EMQX 5.x HOCON `authorization { sources = [ ... ] }` via `EMQX_AUTHORIZATION__SOURCES` JSON env var (P1-32) |
| Status: Proposed | Status: **Locked** |

---

## 10. References

- `V3-ARCHITECTURE.md` — system architecture, data flows, infra cost estimate
- `V3-SECURITY-MODEL.md` — full security spec, including firmware security (Secure Boot v2, Flash Encryption, Ed25519 OTA signing)
- `V3-MQTT-STANDARDS.md` — topic namespace, ACL rules
- `V3-HARDWARE.md` — ESP32-C3 / ESP32-S3 chip selection rationale (Secure Boot v2 requires C3/S3)
- `V3-FACTORY-OPS.md` — factory flashing workflow, eFuse burn sequence, signing workstation setup
- `V3-OPS-RUNBOOK.md` — quarterly rotation checklist, incident response
- `V3-PRIVACY-COMPLIANCE.md` — subprocessor inventory, data residency
- ADR-013 — firmware security (Secure Boot v2 + Flash Encryption)
- ADR-014 — factory flashing + cert generation
