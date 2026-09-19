# SHE V3 — Phase 1 Integration Guide (Step-by-Step)

**Target:** Integrate the Phase 1 codebase (firmware + mobile + backend Phase 1 modules + Phase 3 + all bug fixes) into your existing `D:\she-v3` that has Phase 0 running.

**Time required:** ~30 minutes

---

## Pre-flight checklist

Before starting, verify your current `D:\she-v3` has:
- [x] Phase 0 running (Spring Boot 8080, Postgres, Redis, EMQX, step-ca, MinIO, CRL)
- [x] `infra/ca/keys/jwt_ed25519.pem` (your JWT signing key)
- [x] `infra/ca/step-ca-provisioner-password.txt`
- [x] `infra/ca/out/` (generated certs: root_ca.crt, ca_bundle.pem, she-backend.crt/key)
- [x] `backend/.env` (with JWT_SIGNING_PUBLIC_KEYS + all Phase 0 env vars)
- [x] `infra/.env` (with docker-compose passwords)
- [x] Docker volumes intact (Postgres data, Redis data, EMQX data, step-ca data)

**Extract the new tarball to a temp folder:**
```powershell
mkdir D:\she-v3-new
cd D:\she-v3-new
tar -xzf D:\Downloads\she-v3-phase0+1+3.tar.gz --strip-components=1
```

---

## Step 1: Backup your current state (2 min)

```powershell
cd D:\

# Full backup (safety net)
Copy-Item -Recurse she-v3 she-v3-backup-$(Get-Date -Format "yyyyMMdd")

# Secrets-only backup (fast restore if needed)
Copy-Item she-v3\infra\ca\keys\jwt_ed25519.pem D:\jwt-key-backup.pem
Copy-Item she-v3\infra\.env D:\infra-env-backup
Copy-Item she-v3\backend\.env D:\backend-env-backup
Copy-Item she-v3\infra\ca\step-ca-provisioner-password.txt D:\provisioner-pw-backup.txt
```

---

## Step 2: Copy new Phase 1 directories (5 min)

These are entirely new — they don't exist in your Phase 0 project:

```powershell
cd D:\she-v3-new

# Firmware (ESP-IDF — entirely new)
Copy-Item -Recurse firmware D:\she-v3\firmware

# Mobile (Flutter — entirely new)
Copy-Item -Recurse mobile D:\she-v3\mobile

# Docs: ADRs + V3 specs (entirely new)
Copy-Item -Recurse docs\ADRs D:\she-v3\docs\ADRs
Copy-Item -Recurse docs\v3-specs D:\she-v3\docs\v3-specs
```

---

## Step 3: Copy new Flyway migrations V4-V31 (3 min)

Your Phase 0 has V1-V3 only. The new tarball has V4-V31 (29 new migrations):

```powershell
cd D:\she-v3-new

# Copy all new migration files (V4 through V31)
Copy-Item -Force backend\src\main\resources\db\migration\V4__homes.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V5__rooms.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V6__device_types.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V7__devices.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V8__home_members.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V9__automations.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V10__scenes.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V11__node_groups.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V12__notifications.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V13__user_devices.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V14__ota.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V15__payments.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V16__oauth_identities.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V17__blacklisted_tokens.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V18__audit_log.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V21__api_keys.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V22__feature_flags.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V23__device_telemetry.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V24__device_energy_readings.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V25__energy_hourly.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V26__energy_daily.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V27__nodes_hierarchy.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V28__backfill_and_drop_legacy.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V29__factory_audit_log.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V30__tenants_plan_underscores.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force backend\src\main\resources\db\migration\V31__nodes_is_quarantined.sql D:\she-v3\backend\src\main\resources\db\migration\

# Verify all migrations are present
dir D:\she-v3\backend\src\main\resources\db\migration\V*.sql | Measure-Object
# Expected: 29 files (V1-V31, skipping V19/V20)
```

---

## Step 4: Copy new backend Java packages (5 min)

These are entirely new Java packages from Phase 1 + Phase 3:

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3

# Phase 1 packages (entirely new)
Copy-Item -Recurse energy D:\she-v3\backend\src\main\java\et\she\v3\energy
Copy-Item -Recurse ota D:\she-v3\backend\src\main\java\et\she\v3\ota
Copy-Item -Recurse websocket D:\she-v3\backend\src\main\java\et\she\v3\websocket
Copy-Item -Recurse scheduled D:\she-v3\backend\src\main\java\et\she\v3\scheduled
Copy-Item -Recurse factory D:\she-v3\backend\src\main\java\et\she\v3\factory

# Phase 3 packages (entirely new)
Copy-Item -Recurse payment D:\she-v3\backend\src\main\java\et\she\v3\payment
Copy-Item -Recurse tenant D:\she-v3\backend\src\main\java\et\she\v3\tenant
Copy-Item -Recurse admin D:\she-v3\backend\src\main\java\et\she\v3\admin
Copy-Item -Recurse billing D:\she-v3\backend\src\main\java\et\she\v3\billing
```

---

## Step 5: Copy new + modified Java files (5 min)

New entities, repositories, DTOs, services, controllers — overwrite existing:

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3

# New entities (Phase 1 + Phase 3)
Copy-Item -Force entity\Home.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\Room.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\HomeMember.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\Node.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\NodeDevice.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\NodeParam.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\OtaBatch.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\OtaApproval.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\Payment.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\Subscription.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\ApiKey.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\FeatureFlag.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\AuditLog.java D:\she-v3\backend\src\main\java\et\she\v3\entity\

# New repositories
Copy-Item -Force repository\HomeRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\RoomRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\HomeMemberRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\NodeRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\NodeDeviceRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\NodeParamRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\OtaBatchRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\OtaApprovalRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\PaymentRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\SubscriptionRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\ApiKeyRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\FeatureFlagRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\AuditLogRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\DeviceCertRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\

# New DTOs
Copy-Item -Force dto\NodeDtos.java D:\she-v3\backend\src\main\java\et\she\v3\dto\
Copy-Item -Force dto\HomeDtos.java D:\she-v3\backend\src\main\java\et\she\v3\dto\
Copy-Item -Force dto\OtaDtos.java D:\she-v3\backend\src\main\java\et\she\v3\dto\

# New + modified services (overwrite)
Copy-Item -Force -Recurse service D:\she-v3\backend\src\main\java\et\she\v3\

# New + modified controllers (overwrite)
Copy-Item -Force controller\NodeController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\HomeController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\OtaController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\EnergyController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\PaymentController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\TenantController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\ApiKeyController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\ImpersonationController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\AdminUserController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\AdminDeviceController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\AdminAuditLogController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\AdminFeatureFlagController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force controller\AdminBillingController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\

# Bug-fixed Phase 0 files (overwrite)
Copy-Item -Force mqtt\PemToKeyStore.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\MqttSubscriberService.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\MqttPublishService.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\MqttAuthController.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force security\JwtService.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\JwtAuthenticationFilter.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\TenantContextAspect.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\TenantContextInterceptor.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\AuthenticatedUser.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force config\SecurityConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\JacksonConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\SheConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\SheProperties.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force errors\GlobalExceptionHandler.java D:\she-v3\backend\src\main\java\et\she\v3\errors\
Copy-Item -Force errors\SheException.java D:\she-v3\backend\src\main\java\et\she\v3\errors\
Copy-Item -Force entity\User.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force ca\CaController.java D:\she-v3\backend\src\main\java\et\she\v3\ca\
Copy-Item -Force ca\StepCaClient.java D:\she-v3\backend\src\main\java\et\she\v3\ca\
```

---

## Step 6: Copy updated config + infra files (2 min)

```powershell
cd D:\she-v3-new

# Updated application.yml (has she.payment.chapa.* config block)
Copy-Item -Force backend\src\main\resources\application.yml D:\she-v3\backend\src\main\resources\application.yml

# Updated docker-compose.yml (CRL volume mount fix)
Copy-Item -Force infra\docker-compose.yml D:\she-v3\infra\docker-compose.yml

# Updated nginx config (CRL ^~ prefix fix)
Copy-Item -Force infra\nginx\crl-server.conf D:\she-v3\infra\nginx\crl-server.conf

# Updated step-ca bootstrap (prod-guard for RSA 4096)
Copy-Item -Force infra\ca\bootstrap-ca.sh D:\she-v3\infra\ca\bootstrap-ca.sh

# Updated pom.xml (new dependencies for Phase 1/3)
Copy-Item -Force backend\pom.xml D:\she-v3\backend\pom.xml

# New scripts
Copy-Item -Force scripts\verify-phase1.sh D:\she-v3\scripts\
Copy-Item -Force scripts\verify-phase3.sh D:\she-v3\scripts\
Copy-Item -Force scripts\smoke-test-phase0.sh D:\she-v3\scripts\

# Updated docs
Copy-Item -Force docs\LOCK-MANIFEST.md D:\she-v3\docs\
Copy-Item docs\PHASE1-SIGNOFF.md D:\she-v3\docs\
Copy-Item docs\PHASE1-BUGFIX-REPORT.md D:\she-v3\docs\
Copy-Item docs\PHASE3-SIGNOFF.md D:\she-v3\docs\
```

---

## Step 7: DO NOT overwrite your local secrets (IMPORTANT)

These files contain YOUR locally-generated secrets — keep them:

```powershell
# DO NOT copy these from the tarball — keep your existing versions:
# D:\she-v3\infra\.env                    (your docker-compose passwords)
# D:\she-v3\backend\.env                  (your JWT_SIGNING_PUBLIC_KEYS + Phase 0 env vars)
# D:\she-v3\infra\ca\keys\*               (your JWT signing keypair)
# D:\she-v3\infra\ca\step-ca-provisioner-password.txt  (your provisioner password)
# D:\she-v3\infra\ca\out\*                (your generated certs)
# D:\she-v3\infra\ca\ca_bundle.pem        (your CA bundle)
```

---

## Step 8: Add Phase 1 + 3 env vars to `backend/.env` (3 min)

Open `D:\she-v3\backend\.env` and append these new variables:

```bash
# ---- Phase 1: MQTT backend cert (for mTLS subscriber/publisher) ----
MQTT_BROKER_URL=ssl://localhost:8883
MQTT_BACKEND_CERT=../infra/ca/out/devices/she-backend.crt
MQTT_BACKEND_KEY=../infra/ca/out/devices/she-backend.key
MQTT_CA_BUNDLE=../infra/ca/ca_bundle.pem
MQTT_SHARED_SUBSCRIPTION_GROUP=she-backend
MQTT_CLIENT_ID_PREFIX=she-backend-local
EMQX_INTERNAL_TOKEN=dev-internal-token-not-for-prod

# ---- Phase 1: step-ca client ----
STEP_CA_CLIENT_URL=http://localhost:9002
STEP_CA_CLIENT_PROVISIONER_NAME=she-device-provisioner
STEP_CA_CLIENT_PROVISIONER_PASSWORD_FILE=../infra/ca/step-ca-provisioner-password.txt
CA_INTERMEDIATE_CERT_PATH=../infra/ca/out/intermediate.crt
CA_BUNDLE_PATH=../infra/ca/ca_bundle.pem
CRL_PUBLISH_BASE_URL=http://localhost:8088/ca

# ---- Phase 3: Chapa payment (Telebirr/CBE Birr aggregator) ----
CHAPA_API_BASE_URL=https://api.chapa.co/v1
CHAPA_SECRET_KEY=                          # Set after applying for Chapa sandbox
CHAPA_WEBHOOK_SECRET=                      # Set after applying for Chapa sandbox
CHAPA_CALLBACK_URL=http://localhost:8080/api/v3/payments/webhook
CHAPA_RETURN_URL=she-app://payments/success
CHAPA_WEBHOOK_IP_WHITELIST=41.216.199.0/24,196.188.124.0/24
```

---

## Step 9: Restart infrastructure (3 min)

```powershell
cd D:\she-v3\infra

# Restart CRL server (picks up the volume mount fix)
docker compose down crl-server
docker compose up -d crl-server

# Verify CRL endpoint
curl http://localhost:8088/healthz
# → ok

# If you have the intermediate_id.txt:
$intId = Get-Content ..\infra\ca\out\intermediate_id.txt
curl http://localhost:8088/ca/$intId/crl.pem
# → should return 200 (CRL file)
```

---

## Step 10: Rebuild + restart Spring Boot (5 min)

```powershell
cd D:\she-v3\backend

# Stop the running Spring Boot (Ctrl+C in its terminal)

# Clean rebuild (Flyway will apply V4-V31 on startup)
mvn clean compile
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

**Watch the startup logs — you should see:**
```
Flyway: Migrating schema "public" to version "V4 - homes"
Flyway: Migrating schema "public" to version "V5 - rooms"
...
Flyway: Migrating schema "public" to version "V30 - tenants plan underscores"
Flyway: Migrating schema "public" to version "V31 - nodes is quarantined"
Flyway: Successfully applied 29 migrations
```

**Then verify health:**
```powershell
curl http://localhost:8080/actuator/health | jq
# → {"status":"UP","components":{"db":{"status":"UP"},"redis":{"status":"UP"}}}
```

---

## Step 11: Run Phase 0 smoke test (2 min)

Verify your Phase 0 flows still work:

```powershell
cd D:\she-v3
.\scripts\smoke-test-phase0.ps1
# Expected: 28 PASS, 0 FAIL
```

---

## Step 12: Run Phase 1 verification (2 min)

```powershell
cd D:\she-v3
bash scripts/verify-phase1.sh local
# Expected: 12+ PASS (backend health, EMQX mTLS, /nodes/claim, telemetry, OTA, WebSocket)
```

---

## Step 13: Run Phase 3 verification (2 min)

```powershell
cd D:\she-v3
bash scripts/verify-phase3.sh local
# Expected: 12+ PASS (RLS isolation, tenant branding, payment initiate, webhook HMAC, API keys)
```

---

## Step 14: Verify the mobile app compiles (optional, 3 min)

```powershell
cd D:\she-v3\mobile
flutter pub get
flutter analyze
# Expected: no errors (warnings OK)
```

---

## Step 15: Verify the firmware compiles (optional, 5 min)

```powershell
# Requires ESP-IDF v5.1+ installed
. $env:IDF_PATH\export.ps1

cd D:\she-v3\firmware\v3

# Copy your CA bundle
copy ..\..\infra\ca\ca_bundle.pem certs\ca.pem

# Build for SHE-R8 (default)
idf.py set-target esp32s3
idf.py -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.r8;sdkconfig.dev" build
# Expected: "Project build complete"
```

---

## Troubleshooting

### Spring Boot won't start?

| Error | Cause | Fix |
|---|---|---|
| `BeanCreationException: ... MqttAuthController` | Missing `NodeRepository` injection | Verify Step 5 copied `MqttAuthController.java` (it now has 4 constructor params, not 3) |
| `Flyway: Migration V30 failed` | V1 CHECK constraint name mismatch | Run: `docker exec she-postgres psql -U she_app -d she_v3 -c "ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;"` then restart |
| `BeanCreationException: ... PaymentService` | Missing `@Value` for webhook-secret | Verify Step 8 added `CHAPA_WEBHOOK_SECRET=` (even if empty) |
| `IllegalStateException: Ambiguous mapping` | Duplicate route `/internal/factory/register-cert` | Verify Step 5 copied `CaController.java` (route renamed to `/internal/ca/sign-and-register`) |

### Flyway migration fails?

```powershell
# Check which migration failed
docker exec she-postgres psql -U she_app -d she_v3 -c "SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank;"

# If a migration failed mid-way, fix the SQL then:
cd D:\she-v3\backend
mvn flyway:repair
# Then restart Spring Boot
```

### MQTT subscriber won't connect?

```powershell
# Check if backend cert exists
dir D:\she-v3\infra\ca\out\devices\she-backend.crt
# If missing, regenerate:
docker exec she-step-ca sh /bootstrap-ca.sh
```

### CRL endpoint still 404?

```powershell
# Full compose restart (picks up volume mount change)
cd D:\she-v3\infra
docker compose down crl-server
docker compose up -d crl-server

# Verify
$intId = Get-Content ..\infra\ca\out\intermediate_id.txt
curl http://localhost:8088/ca/$intId/crl.pem
```

---

## What you now have (after all steps)

| Component | Phase 0 (before) | After integration |
|---|---|---|
| **Migrations** | V1-V3 (3 tables) | V1-V31 (29 tables, 2 new columns) |
| **REST endpoints** | 21 | 104 |
| **Backend Java files** | ~30 | 101 |
| **MQTT** | EMQX cluster + mTLS | + Subscriber + Publisher (Paho, shared sub, mTLS) |
| **WebSocket** | — | /ws/v3 with bearer.<jwt> auth |
| **Firmware** | — | 26 ESP-IDF C/H files (14 modules) |
| **Mobile** | — | 22 Flutter Dart files (9 screens + l10n) |
| **Bug fixes** | 6 (Phase 0) | 30 (6 Phase 0 + 24 Phase 1/3 critical+high) |
| **Phase 3 (payments + admin)** | — | Chapa integration + 9 admin controllers + billing + impersonation |

---

## Next steps after integration

1. **Flash firmware to ESP32-S3 dev kit** + run 5 end-to-end device tests (BLE provisioning, telemetry, relay toggle, OTA, local control)
2. **Apply for Chapa sandbox account** at https://docs.chapa.co/ → set `CHAPA_SECRET_KEY` + `CHAPA_WEBHOOK_SECRET`
3. **Onboard first B2B tenant** via `POST /api/admin/tenants`
4. **Build Next.js admin console** (9 screens per V3-ADMIN-WEB-APP)
5. **Start Phase 4** (Premium UX + energy + voice + Amharic) after Phase 1 device testing passes
