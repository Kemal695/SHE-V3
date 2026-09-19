# SHE V3 — Phase 3 Integration Guide (Step-by-Step)

**Target:** Integrate Phase 3 (B2B multi-tenant + Chapa payments + admin API + Phase 4 premium UX + all bug fixes) into your existing `D:\she-v3` that has Phase 0 + 1 running.

**Time required:** ~30 minutes

---

## Pre-flight checklist

Before starting, verify your current `D:\she-v3` has:
- [x] Phase 0 + 1 running (Spring Boot 8080, Postgres, Redis, EMQX, step-ca, MinIO, CRL)
- [x] Flyway migrations V1-V3 applied (Phase 0) or V1-V31 applied (if Phase 1 integration done)
- [x] `infra/ca/keys/jwt_ed25519.pem` (your JWT signing key)
- [x] `infra/ca/step-ca-provisioner-password.txt`
- [x] `infra/ca/out/` (generated certs)
- [x] `backend/.env` (with all Phase 0/1 env vars)
- [x] `infra/.env` (docker-compose passwords)

**Extract the new tarball:**
```powershell
mkdir D:\she-v3-new
cd D:\she-v3-new
tar -xzf D:\Downloads\she-v3-phase0+1+3+4.tar.gz --strip-components=1
```

---

## Step 1: Backup (2 min)

```powershell
cd D:\
Copy-Item -Recurse she-v3 she-v3-backup-$(Get-Date -Format "yyyyMMdd")
Copy-Item she-v3\backend\.env D:\backend-env-backup-p3
Copy-Item she-v3\infra\.env D:\infra-env-backup-p3
```

---

## Step 2: Copy new Phase 3 backend packages (5 min)

These are entirely new Java packages from Phase 3:

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3

# Phase 3 packages (entirely new)
Copy-Item -Recurse payment D:\she-v3\backend\src\main\java\et\she\v3\payment
Copy-Item -Recurse tenant D:\she-v3\backend\src\main\java\et\she\v3\tenant
Copy-Item -Recurse admin D:\she-v3\backend\src\main\java\et\she\v3\admin
Copy-Item -Recurse billing D:\she-v3\backend\src\main\java\et\she\v3\billing
```

---

## Step 3: Copy new entities + repositories (3 min)

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3

# Phase 3 entities (new)
Copy-Item -Force entity\Payment.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\Subscription.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\ApiKey.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\FeatureFlag.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\AuditLog.java D:\she-v3\backend\src\main\java\et\she\v3\entity\

# Phase 3 repositories (new)
Copy-Item -Force repository\PaymentRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\SubscriptionRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\ApiKeyRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\FeatureFlagRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
Copy-Item -Force repository\AuditLogRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\

# Phase 3 + Phase 1 bug-fixed entities (overwrite)
Copy-Item -Force entity\Node.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force entity\User.java D:\she-v3\backend\src\main\java\et\she\v3\entity\
Copy-Item -Force repository\DeviceCertRepository.java D:\she-v3\backend\src\main\java\et\she\v3\repository\
```

---

## Step 4: Copy new Phase 3 controllers (3 min)

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3\controller

# Phase 3 controllers (new)
Copy-Item -Force PaymentController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force TenantController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force ApiKeyController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force ImpersonationController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AdminUserController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AdminDeviceController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AdminAuditLogController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AdminFeatureFlagController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AdminBillingController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\

# Bug-fixed Phase 0/1 controllers (overwrite)
Copy-Item -Force UsersController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force AuthController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force NodeController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force HomeController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force OtaController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
Copy-Item -Force EnergyController.java D:\she-v3\backend\src\main\java\et\she\v3\controller\
```

---

## Step 5: Copy new + fixed security + mqtt + ca (3 min)

```powershell
cd D:\she-v3-new\backend\src\main\java\et\she\v3

# Bug-fixed security (overwrite — includes TenantContextAspect)
Copy-Item -Force security\JwtService.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\JwtAuthenticationFilter.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\TenantContextAspect.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\TenantContextInterceptor.java D:\she-v3\backend\src\main\java\et\she\v3\security\
Copy-Item -Force security\AuthenticatedUser.java D:\she-v3\backend\src\main\java\et\she\v3\security\

# Bug-fixed MQTT (overwrite — includes topic parsing fix + quarantine check + NodeRepository injection)
Copy-Item -Force mqtt\MqttSubscriberService.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\MqttPublishService.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\MqttAuthController.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\
Copy-Item -Force mqtt\PemToKeyStore.java D:\she-v3\backend\src\main\java\et\she\v3\mqtt\

# Bug-fixed CA (overwrite — includes route rename + @Transactional + findActiveByCertSerial)
Copy-Item -Force ca\CaController.java D:\she-v3\backend\src\main\java\et\she\v3\ca\
Copy-Item -Force ca\StepCaClient.java D:\she-v3\backend\src\main\java\et\she\v3\ca\

# Bug-fixed config (overwrite)
Copy-Item -Force config\SecurityConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\JacksonConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\SheConfig.java D:\she-v3\backend\src\main\java\et\she\v3\config\
Copy-Item -Force config\SheProperties.java D:\she-v3\backend\src\main\java\et\she\v3\config\

# Bug-fixed errors (overwrite)
Copy-Item -Force errors\GlobalExceptionHandler.java D:\she-v3\backend\src\main\java\et\she\v3\errors\
Copy-Item -Force errors\SheException.java D:\she-v3\backend\src\main\java\et\she\v3\errors\
```

---

## Step 6: Copy new Flyway migrations V30-V31 (2 min)

These are the 2 bug-fix migrations (tenant plan underscores + nodes.is_quarantined):

```powershell
cd D:\she-v3-new\backend\src\main\resources\db\migration

Copy-Item -Force V30__tenants_plan_underscores.sql D:\she-v3\backend\src\main\resources\db\migration\
Copy-Item -Force V31__nodes_is_quarantined.sql D:\she-v3\backend\src\main\resources\db\migration\
```

---

## Step 7: Copy updated application.yml + pom.xml (1 min)

```powershell
cd D:\she-v3-new\backend

# Updated application.yml (has she.payment.chapa.* config block)
Copy-Item -Force src\main\resources\application.yml D:\she-v3\backend\src\main\resources\application.yml

# Updated pom.xml (BouncyCastle dep added in Phase 1)
Copy-Item -Force pom.xml D:\she-v3\backend\pom.xml
```

---

## Step 8: Copy Phase 4 mobile app (3 min)

```powershell
cd D:\she-v3-new

# Copy entire mobile directory (overwrites Phase 1 mobile with Phase 4 premium UX)
Copy-Item -Recurse -Force mobile D:\she-v3\mobile
```

---

## Step 9: Copy updated scripts + docs (1 min)

```powershell
cd D:\she-v3-new

# New scripts
Copy-Item -Force scripts\verify-phase3.sh D:\she-v3\scripts\
Copy-Item -Force scripts\verify-phase4.sh D:\she-v3\scripts\

# New docs
Copy-Item docs\PHASE3-SIGNOFF.md D:\she-v3\docs\
Copy-Item docs\PHASE1-INTEGRATION-GUIDE.md D:\she-v3\docs\
```

---

## Step 10: DO NOT overwrite secrets (IMPORTANT)

```powershell
# DO NOT copy these — keep your existing versions:
# D:\she-v3\infra\.env
# D:\she-v3\backend\.env
# D:\she-v3\infra\ca\keys\*
# D:\she-v3\infra\ca\step-ca-provisioner-password.txt
# D:\she-v3\infra\ca\out\*
# D:\she-v3\infra\ca\ca_bundle.pem
```

---

## Step 11: Add Phase 3 env vars to backend/.env (2 min)

Open `D:\she-v3\backend\.env` and append:

```bash
# ---- Phase 3: Chapa payment (Telebirr/CBE Birr aggregator) ----
CHAPA_API_BASE_URL=https://api.chapa.co/v1
CHAPA_SECRET_KEY=                          # Set after applying for Chapa sandbox
CHAPA_WEBHOOK_SECRET=                      # Set after applying for Chapa sandbox
CHAPA_CALLBACK_URL=http://localhost:8080/api/v3/payments/webhook
CHAPA_RETURN_URL=she-app://payments/success
CHAPA_WEBHOOK_IP_WHITELIST=41.216.199.0/24,196.188.124.0/24
```

---

## Step 12: Rebuild + restart Spring Boot (5 min)

```powershell
cd D:\she-v3\backend

# Stop running Spring Boot (Ctrl+C)

# Rebuild — Flyway will apply V30+V31 on startup
mvn clean compile
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

**Watch the logs:**
```
Flyway: Migrating schema "public" to version "V30 - tenants plan underscores"
Flyway: Migrating schema "public" to version "V31 - nodes is quarantined"
Flyway: Successfully applied 2 migrations
```

**Verify health:**
```powershell
curl http://localhost:8080/actuator/health | jq
# → {"status":"UP","components":{"db":{"status":"UP"},"redis":{"status":"UP"}}}
```

---

## Step 13: Generate Flutter l10n + run mobile app (3 min)

```powershell
cd D:\she-v3\mobile

# Generate AppLocalizations (required — C4 fix)
flutter pub get
flutter gen-l10n

# Run the app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

**Note:** Flutter 3.27+ is required (pubspec updated). If you have an older Flutter:
```powershell
flutter upgrade
```

---

## Step 14: Run Phase 3 verification (2 min)

```powershell
cd D:\she-v3
bash scripts/verify-phase3.sh local
# Expected: 13 PASS, 0 FAIL
```

---

## Step 15: Run Phase 4 verification (2 min)

```powershell
cd D:\she-v3
bash scripts/verify-phase4.sh
# Expected: 15+ PASS (design tokens, premium widgets, energy dashboard, voice screen, ARB coverage, Ethiopian calendar)
```

---

## Troubleshooting

### Spring Boot won't start?

| Error | Cause | Fix |
|---|---|---|
| `BeanCreationException: MqttAuthController` | Missing `NodeRepository` constructor param | Verify Step 5 copied `MqttAuthController.java` (4 constructor params now) |
| `IllegalStateException: Ambiguous mapping` | Old `CaController` still has `/factory/register-cert` route | Verify Step 5 copied `CaController.java` (renamed to `/ca/sign-and-register`) |
| `Flyway: V30 failed` | V1 CHECK constraint name mismatch | `docker exec she-postgres psql -U she_app -d she_v3 -c "ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;"` then restart |
| `DataIntegrityViolationException` on tenant create | Plan format mismatch (hyphens vs underscores) | Verify V30 migration ran — check `flyway_schema_history` |

### Flutter won't compile?

| Error | Cause | Fix |
|---|---|---|
| `Target of URI doesn't exist: 'l10n/app_localizations.dart'` | Generated file missing | Run `flutter pub get && flutter gen-l10n` |
| `Color.withValues isn't defined` | Flutter < 3.27 | Run `flutter upgrade` to 3.27+ |
| `CardThemeData isn't defined` | Flutter < 3.24 | Run `flutter upgrade` to 3.27+ |
| `et.she.v3... compile error` | Invalid Dart syntax in dashboard | Verify Step 8 copied latest `dashboard_screen.dart` |

### Payment webhook returns 500?

This is expected in local dev — `CHAPA_WEBHOOK_SECRET` is empty. The webhook endpoint works correctly:
- No secret configured → 500 (expected)
- With secret + valid HMAC → 200
- With secret + invalid HMAC → 401

To test with Chapa sandbox:
1. Apply at https://docs.chapa.co/
2. Set `CHAPA_SECRET_KEY` + `CHAPA_WEBHOOK_SECRET` in `backend/.env`
3. Restart Spring Boot

---

## What you now have (after all steps)

| Component | Before (Phase 0+1) | After Phase 3 integration |
|---|---|---|
| **Migrations** | V1-V31 (29 tables) | V1-V31 (31 migrations, 2 bug-fix columns) |
| **REST endpoints** | 76 | 104 (+28 admin/payment/tenant/API-key) |
| **Backend Java files** | ~80 | 101 |
| **Mobile** | Phase 1 basic UI | Phase 4 premium UX (11 rebuilt screens + 3 premium widgets) |
| **Payment** | — | Chapa integration (initiate + webhook + subscription + billing) |
| **Admin** | — | 9 admin controllers (users/devices/audit/billing/feature-flags/impersonation) |
| **Bug fixes** | Phase 0/1 fixes | +4 critical (payment status, plan format, quarantine, idempotency) + 6 mobile criticals |
